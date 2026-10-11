/**
 * The repository pattern: keys, settings and usage behind small interfaces, with an
 * in-memory store for tests. Keys are stored as ciphertext; the cipher is the host's
 * (Keychain / Keystore on devices, a server secret in a Worker).
 *
 * Port of TokenLib `Store.swift`; every method is async so SQL-over-the-network stores fit.
 */
import { PROVIDER_KINDS, type Profile, type ProviderKind } from './catalog';
import type { StopReason } from './chat';

/** Encrypts API keys at rest. Hosts supply a platform cipher; `PlainCipher` is for tests only. */
export interface SecretCipher {
  encrypt(plaintext: Uint8Array): Promise<Uint8Array>;
  decrypt(ciphertext: Uint8Array): Promise<Uint8Array>;
}

export class PlainCipher implements SecretCipher {
  async encrypt(p: Uint8Array): Promise<Uint8Array> {
    return p;
  }
  async decrypt(c: Uint8Array): Promise<Uint8Array> {
    return c;
  }
}

export interface KeyRepository {
  /** The stored ciphertext for a provider's key. */
  keyData(provider: ProviderKind): Promise<Uint8Array | undefined>;
  setKeyData(provider: ProviderKind, data: Uint8Array | undefined): Promise<void>;
  providersWithKeys(): Promise<ProviderKind[]>;
}

/**
 * A provider balance the user read off the provider's billing page, and what TokenLib has
 * charged that provider since. Providers do not report balances to API keys, so this is
 * TokenLib's own count: use of the key elsewhere is not seen.
 */
export interface Credit {
  /** The balance entered, in millionths of a dollar. */
  micros: number;
  spentMicros: number;
}

export const Credit = {
  remainingMicros(c: Credit): number {
    return Math.max(0, c.micros - c.spentMicros);
  },
  remainingUSD(c: Credit): number {
    return Credit.remainingMicros(c) / 1_000_000;
  },
  totalUSD(c: Credit): number {
    return c.micros / 1_000_000;
  },
};

export interface Settings {
  /** The provider requests go to; `undefined` until the app picks one. */
  activeProvider?: ProviderKind;
  /** For `local`: the OpenAI-compatible server, e.g. `http://192.168.1.20:11434/v1`. */
  localBaseURL?: string;
  /** For `local`: the model name the server loads. */
  localModel?: string;
  /** Total tokens allowed per calendar day across every session; `undefined` is unlimited. */
  dailyTokenCap?: number;
  /** Whether prompts and replies are kept with the usage rows (off by default). */
  logPrompts: boolean;
  /** The balance entered per provider and the spend counted against it. */
  credits: Partial<Record<ProviderKind, Credit>>;
}

export function defaultSettings(): Settings {
  return { logPrompts: false, credits: {} };
}

/** Settings as flat key/value pairs, the shape the SQL stores keep (port of `SQLiteStore.save`). */
export function settingsToPairs(s: Settings): [string, string | undefined][] {
  const pairs: [string, string | undefined][] = [
    ['activeProvider', s.activeProvider],
    ['localBaseURL', s.localBaseURL],
    ['localModel', s.localModel],
    ['dailyTokenCap', s.dailyTokenCap === undefined ? undefined : String(s.dailyTokenCap)],
    ['logPrompts', s.logPrompts ? '1' : '0'],
  ];
  for (const p of PROVIDER_KINDS) {
    const c = s.credits[p];
    pairs.push([`credit.${p}`, c ? `${c.micros} ${c.spentMicros}` : undefined]);
  }
  return pairs;
}

export function settingsFromPairs(rows: Iterable<[string, string | undefined | null]>): Settings {
  const s = defaultSettings();
  for (const [key, raw] of rows) {
    const value = raw ?? undefined;
    switch (key) {
      case 'activeProvider':
        s.activeProvider = (PROVIDER_KINDS as readonly string[]).includes(value ?? '') ? (value as ProviderKind) : undefined;
        break;
      case 'localBaseURL':
        s.localBaseURL = value;
        break;
      case 'localModel':
        s.localModel = value;
        break;
      case 'dailyTokenCap': {
        const n = value === undefined ? NaN : Number(value);
        s.dailyTokenCap = Number.isFinite(n) ? n : undefined;
        break;
      }
      case 'logPrompts':
        s.logPrompts = value === '1';
        break;
      default: {
        if (!key.startsWith('credit.')) break;
        const provider = key.slice(7);
        if (!(PROVIDER_KINDS as readonly string[]).includes(provider)) break;
        const parts = (value ?? '').split(' ').map(Number);
        if (parts.length === 2 && parts.every(Number.isFinite)) s.credits[provider as ProviderKind] = { micros: parts[0]!, spentMicros: parts[1]! };
      }
    }
  }
  return s;
}

export interface SettingsRepository {
  settings(): Promise<Settings>;
  save(settings: Settings): Promise<void>;
}

export interface UsageRecord {
  id?: number;
  /** ISO timestamp. */
  at: string;
  /** Who asked (an actor id, a screen name); free text. */
  consumer: string;
  profile: Profile;
  provider: ProviderKind;
  model: string;
  promptTokens: number;
  replyTokens: number;
  costMicros: number;
  stop: StopReason;
  /** Only when `Settings.logPrompts` is on. */
  prompt?: string;
  reply?: string;
}

export interface UsageTotals {
  requests: number;
  promptTokens: number;
  replyTokens: number;
  costMicros: number;
}

export const UsageTotals = {
  empty(): UsageTotals {
    return { requests: 0, promptTokens: 0, replyTokens: 0, costMicros: 0 };
  },
  totalTokens(t: UsageTotals): number {
    return t.promptTokens + t.replyTokens;
  },
  costUSD(t: UsageTotals): number {
    return t.costMicros / 1_000_000;
  },
};

export interface UsageRepository {
  record(usage: UsageRecord): Promise<UsageRecord>;
  /** Totals since `since` (ISO), optionally for one consumer. */
  totals(since: string, consumer?: string): Promise<UsageTotals>;
  /** Most recent rows first. */
  recent(limit: number, consumer?: string): Promise<UsageRecord[]>;
  deleteAll(): Promise<void>;
}

export type TokenStore = KeyRepository & SettingsRepository & UsageRepository;

// MARK: - In memory (tests, previews)

export class InMemoryStore implements TokenStore {
  private keys = new Map<ProviderKind, Uint8Array>();
  private current = defaultSettings();
  private usage: UsageRecord[] = [];
  private nextId = 1;

  async keyData(provider: ProviderKind): Promise<Uint8Array | undefined> {
    return this.keys.get(provider);
  }
  async setKeyData(provider: ProviderKind, data: Uint8Array | undefined): Promise<void> {
    if (data) this.keys.set(provider, data);
    else this.keys.delete(provider);
  }
  async providersWithKeys(): Promise<ProviderKind[]> {
    return PROVIDER_KINDS.filter((p) => this.keys.has(p));
  }
  async settings(): Promise<Settings> {
    return structuredClone(this.current);
  }
  async save(settings: Settings): Promise<void> {
    this.current = structuredClone(settings);
  }
  async record(record: UsageRecord): Promise<UsageRecord> {
    const r = { ...record, id: this.nextId++ };
    this.usage.push(r);
    return r;
  }
  async totals(since: string, consumer?: string): Promise<UsageTotals> {
    const t = UsageTotals.empty();
    for (const r of this.usage) {
      if (r.at < since || (consumer !== undefined && r.consumer !== consumer)) continue;
      t.requests += 1;
      t.promptTokens += r.promptTokens;
      t.replyTokens += r.replyTokens;
      t.costMicros += r.costMicros;
    }
    return t;
  }
  async recent(limit: number, consumer?: string): Promise<UsageRecord[]> {
    return this.usage
      .filter((r) => consumer === undefined || r.consumer === consumer)
      .slice(-limit)
      .reverse();
  }
  async deleteAll(): Promise<void> {
    this.usage = [];
  }
}
