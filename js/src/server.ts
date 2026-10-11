/**
 * The server side: owns the store, the cipher and the transport, knows the keys, picks
 * the model for a profile, enforces the daily cap and records usage. Hosts configure it
 * (keys, active provider) and build their settings screens on its query methods;
 * consumers only ever hold a TokenClient.
 *
 * Port of TokenLib `TokenServer.swift`.
 */
import { Catalog, costMicros, providerNeedsKey, type ModelInfo, type Profile, type ProviderKind } from './catalog';
import { estimatedPromptTokens, TokenLibError, type ChatEvent, type ChatReply, type ChatRequest, type StopReason, type Usage } from './chat';
import { bytes } from './cipher';
import type { Provider } from './provider';
import { Providers } from './providers';
import { FetchTransport, type HttpTransport } from './transport';
import { UsageTotals, type Credit, type SecretCipher, type Settings, type TokenStore, type UsageRecord } from './store';

export interface StreamOptions {
  profile: Profile;
  /** Who asked (for usage rows). */
  consumer: string;
  onEvent?: (event: ChatEvent) => void;
  signal?: AbortSignal;
}

/** What consumers see. In-process today; the interface is the seam for a remote broker later. */
export interface TokenBroker {
  /** Whether requests can be served right now (a provider is active and, if it needs one, has a key). */
  isReady(): Promise<boolean>;
  /** Streams a reply and resolves with the whole of it; rejects with a `TokenLibError`. */
  stream(request: ChatRequest, options: StreamOptions): Promise<ChatReply>;
}

export class TokenServer implements TokenBroker {
  /** Overrides the catalog's providers (tests inject fakes). */
  providers: Partial<Record<ProviderKind, Provider>> = {};
  /** The start of "today" for the daily cap, as ISO; midnight UTC by default. */
  dayStart: () => string = () => {
    const d = new Date();
    d.setUTCHours(0, 0, 0, 0);
    return d.toISOString();
  };
  now: () => string = () => new Date().toISOString();

  constructor(
    readonly store: TokenStore,
    readonly cipher: SecretCipher,
    readonly transport: HttpTransport = new FetchTransport(),
  ) {}

  // MARK: - Configuration (the host's settings screens call these)

  settings(): Promise<Settings> {
    return this.store.settings();
  }

  async update(change: (s: Settings) => void): Promise<Settings> {
    const s = await this.store.settings();
    change(s);
    await this.store.save(s);
    return s;
  }

  async setKey(provider: ProviderKind, key: string | undefined): Promise<void> {
    const trimmed = key?.trim();
    if (!trimmed) {
      await this.store.setKeyData(provider, undefined);
      return;
    }
    await this.store.setKeyData(provider, await this.cipher.encrypt(bytes.fromUtf8(trimmed)));
  }

  async key(provider: ProviderKind): Promise<string | undefined> {
    const data = await this.store.keyData(provider);
    if (!data) return undefined;
    return bytes.toUtf8(await this.cipher.decrypt(data));
  }

  async hasKey(provider: ProviderKind): Promise<boolean> {
    return (await this.store.keyData(provider)) !== undefined;
  }

  configuredProviders(): Promise<ProviderKind[]> {
    return this.store.providersWithKeys();
  }

  /**
   * Moves every stored key from `legacy` to this server's cipher: each key `legacy` can decrypt is
   * re-encrypted with `cipher`, and keys it cannot read are left as they are. Resolves with the providers
   * whose keys moved. For rotating the `AesGcmCipher` secret, or moving to a cipher under new identifiers.
   */
  async reencryptKeys(legacy: SecretCipher): Promise<ProviderKind[]> {
    const moved: ProviderKind[] = [];
    for (const provider of await this.store.providersWithKeys()) {
      const data = await this.store.keyData(provider);
      if (!data) continue;
      let plaintext: Uint8Array;
      try {
        plaintext = await legacy.decrypt(data);
      } catch {
        continue;
      }
      await this.store.setKeyData(provider, await this.cipher.encrypt(plaintext));
      moved.push(provider);
    }
    return moved;
  }

  /** Whether every stored key decrypts with this server's cipher. */
  async keysReadable(): Promise<boolean> {
    for (const provider of await this.configuredProviders()) {
      try {
        await this.key(provider);
      } catch {
        return false;
      }
    }
    return true;
  }

  /** Picks the provider and stores its key in one step. */
  async activate(provider: ProviderKind, key?: string): Promise<void> {
    if (key !== undefined) await this.setKey(provider, key);
    await this.update((s) => {
      s.activeProvider = provider;
    });
  }

  async isReady(): Promise<boolean> {
    const s = await this.settings();
    if (!s.activeProvider) return false;
    if (s.activeProvider === 'local') return !!s.localBaseURL;
    return this.hasKey(s.activeProvider);
  }

  /** The model a profile will run on right now. */
  async model(profile: Profile): Promise<ModelInfo | undefined> {
    const s = await this.settings();
    return modelFor(s, profile);
  }

  usageToday(): Promise<UsageTotals> {
    return this.store.totals(this.dayStart());
  }

  /** Records the balance the user read off the provider's billing page; spend is counted down from it. `undefined` or zero forgets it. */
  async setCredit(provider: ProviderKind, micros: number | undefined): Promise<void> {
    await this.update((s) => {
      if (micros && micros > 0) s.credits[provider] = { micros, spentMicros: 0 };
      else delete s.credits[provider];
    });
  }

  /** The credit entered for a provider (the active one by default) and what is left of it. */
  async credit(provider?: ProviderKind): Promise<Credit | undefined> {
    const s = await this.settings();
    const p = provider ?? s.activeProvider;
    return p ? s.credits[p] : undefined;
  }

  /** Tokens left under the daily cap today; `undefined` when there is no cap. */
  async remainingToday(): Promise<number | undefined> {
    const s = await this.settings();
    if (s.dailyTokenCap === undefined) return undefined;
    return Math.max(0, s.dailyTokenCap - UsageTotals.totalTokens(await this.usageToday()));
  }

  usage(since: string, consumer?: string): Promise<UsageTotals> {
    return this.store.totals(since, consumer);
  }

  recentUsage(limit = 50, consumer?: string): Promise<UsageRecord[]> {
    return this.store.recent(limit, consumer);
  }

  // MARK: - TokenBroker

  async stream(request: ChatRequest, options: StreamOptions): Promise<ChatReply> {
    const settings = await this.settings();
    const kind = settings.activeProvider;
    if (!kind) throw TokenLibError.noProvider();
    if (settings.dailyTokenCap !== undefined) {
      const today = UsageTotals.totalTokens(await this.usageToday());
      if (today + estimatedPromptTokens(request) >= settings.dailyTokenCap) throw TokenLibError.dailyCapReached();
    }
    const key = await this.key(kind);
    if (providerNeedsKey(kind) && !key) throw TokenLibError.missingKey(kind);
    const model = modelFor(settings, options.profile);
    if (!model) throw TokenLibError.noProvider();
    const provider = this.providers[kind] ?? Providers.for(kind);
    const http = provider.request(request, { model, key, baseURL: settings.localBaseURL, profile: options.profile });
    const parser = provider.makeParser();
    let text = '';
    let done: { usage: Usage; stop: StopReason } | undefined;
    const deliver = (event: ChatEvent) => {
      if (event.type === 'text') text += event.text;
      else if (!done) done = { usage: event.usage, stop: event.stop };
      options.onEvent?.(event);
    };
    await this.transport.stream(http, { onLine: (line) => parser.feed(line).forEach(deliver) }, options.signal);
    parser.finish().forEach(deliver);
    const usage: Usage = { ...(done?.usage ?? { promptTokens: 0, replyTokens: 0 }) };
    const stop = done?.stop ?? 'other';
    if (usage.promptTokens === 0) usage.promptTokens = estimatedPromptTokens(request);
    if (usage.replyTokens === 0) usage.replyTokens = Math.floor((new TextEncoder().encode(text).length + 3) / 4);
    const record: UsageRecord = {
      at: this.now(),
      consumer: options.consumer,
      profile: options.profile,
      provider: kind,
      model: model.id,
      promptTokens: usage.promptTokens,
      replyTokens: usage.replyTokens,
      costMicros: costMicros(model, usage.promptTokens, usage.replyTokens),
      stop,
      prompt: settings.logPrompts ? request.messages[request.messages.length - 1]?.text : undefined,
      reply: settings.logPrompts ? text : undefined,
    };
    try {
      await this.store.record(record);
      if (record.costMicros > 0 && settings.credits[kind]) {
        await this.update((s) => {
          const c = s.credits[kind];
          if (c) c.spentMicros += record.costMicros;
        });
      }
    } catch {
      // Usage accounting must never fail the reply.
    }
    return { text, usage, stop, model: model.id, provider: kind };
  }
}

export function modelFor(settings: Settings, profile: Profile): ModelInfo | undefined {
  const p = settings.activeProvider;
  if (!p) return undefined;
  const m = { ...Catalog.modelFor(profile, p) };
  if (p === 'local' && settings.localModel) {
    m.id = settings.localModel;
    m.name = settings.localModel;
  }
  return m;
}
