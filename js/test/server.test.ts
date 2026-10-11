import { beforeEach, describe, expect, it } from 'vitest';
import {
  AesGcmCipher,
  bytes,
  ChatMessage,
  Credit,
  estimatedPromptTokens,
  InMemoryStore,
  PlainCipher,
  TokenClient,
  TokenServer,
  TokenLibError,
  UsageTotals,
  type ChatRequest,
  type SecretCipher,
} from '../src';
import { Canned, FakeTransport } from './fake-transport';

const request = (text = 'sing'): ChatRequest => ({ system: 'bush', messages: [ChatMessage.user(text)] });

async function failure(p: Promise<unknown>): Promise<TokenLibError> {
  try {
    await p;
  } catch (e) {
    if (e instanceof TokenLibError) return e;
    throw e;
  }
  throw new Error('expected a failure');
}

describe('TokenServer', () => {
  let transport: FakeTransport;
  let server: TokenServer;

  beforeEach(() => {
    transport = new FakeTransport();
    transport.responses['api.anthropic.com'] = { status: 200, body: Canned.anthropic };
    transport.responses['api.openai.com'] = { status: 200, body: Canned.openai };
    server = new TokenServer(new InMemoryStore(), new PlainCipher(), transport);
  });

  it('is not ready without a provider or key', async () => {
    expect(await server.isReady()).toBe(false);
    const client = new TokenClient(server);
    expect((await failure(client.session('bush', 'character').send(request()))).code).toBe('noProvider');
    await server.update((s) => {
      s.activeProvider = 'anthropic';
    });
    expect(await server.isReady()).toBe(false);
    expect((await failure(client.session('bush', 'character').send(request()))).code).toBe('missingKey');
    await server.activate('local');
    expect(await server.isReady(), 'local needs a base URL').toBe(false);
    await server.update((s) => {
      s.localBaseURL = 'http://h/v1';
    });
    expect(await server.isReady()).toBe(true);
  });

  it('streams, records usage and encrypts keys', async () => {
    const xor: SecretCipher = {
      async encrypt(p) {
        return p.map((b) => b ^ 0x2a);
      },
      async decrypt(c) {
        return c.map((b) => b ^ 0x2a);
      },
    };
    const store = new InMemoryStore();
    server = new TokenServer(store, xor, transport);
    await server.activate('anthropic', ' sk-live ');
    expect(Array.from((await store.keyData('anthropic'))!), 'stored as ciphertext, trimmed').toEqual(Array.from(bytes.fromUtf8('sk-live').map((b) => b ^ 0x2a)));
    expect(await server.key('anthropic')).toBe('sk-live');
    expect(await server.isReady()).toBe(true);
    expect((await server.model('character'))?.id).toBe('claude-opus-5-5');
    const session = new TokenClient(server).session('bush', 'character', 1000);
    const deltas: string[] = [];
    const reply = await session.stream(request(), (d) => deltas.push(d));
    expect(reply.text).toBe('Ask, and the bush shall sing.');
    expect(deltas).toEqual(['Ask, ', 'and the bush shall sing.']);
    expect(reply.usage).toEqual({ promptTokens: 25, replyTokens: 9 });
    expect(reply.model).toBe('claude-opus-5-5');
    expect(session.spent).toBe(34);
    expect(session.remaining).toBe(966);
    expect(transport.requests.at(-1)?.headers['x-api-key']).toBe('sk-live');
    const usage = await server.usageToday();
    expect(usage.requests).toBe(1);
    expect(UsageTotals.totalTokens(usage)).toBe(34);
    expect(usage.costMicros).toBe(25 * 4 + 9 * 20);
    const row = (await server.recentUsage())[0]!;
    expect(row.consumer).toBe('bush');
    expect(row.model).toBe('claude-opus-5-5');
    expect(row.prompt, 'prompts are not logged by default').toBeUndefined();
  });

  it('enforces the session budget and the daily cap', async () => {
    await server.activate('anthropic', 'k');
    const client = new TokenClient(server);
    const small = client.session('bush', 'character', 36);
    await small.send(request());
    expect(small.remaining, '34 of 36 spent; the next prompt would not fit').toBe(2);
    expect(small.isExhausted).toBe(false);
    expect((await failure(small.send(request()))).code).toBe('budgetExhausted');
    expect(await server.remainingToday(), 'no cap, nothing to count down').toBeUndefined();
    await server.update((s) => {
      s.dailyTokenCap = 100;
    });
    expect(await server.remainingToday()).toBe(66);
    await server.update((s) => {
      s.dailyTokenCap = 20;
    });
    expect(await server.remainingToday(), 'never below zero').toBe(0);
    await server.update((s) => {
      s.dailyTokenCap = 36;
    });
    expect((await failure(client.session('snoopy', 'fast').send(request()))).code).toBe('dailyCapReached');
  });

  it('counts credit down and survives clearing usage', async () => {
    await server.activate('anthropic', 'k');
    expect(await server.credit()).toBeUndefined();
    await server.setCredit('anthropic', 50_000_000);
    const session = new TokenClient(server).session('bush', 'character');
    await session.send(request());
    expect(await server.credit()).toEqual({ micros: 50_000_000, spentMicros: 280 });
    expect(Credit.remainingMicros((await server.credit())!)).toBe(49_999_720);
    await server.store.deleteAll();
    await session.send(request());
    expect((await server.credit())?.spentMicros, "the count is the credit's own, not the usage log's").toBe(560);
    expect(await server.credit('openai')).toBeUndefined();
    await server.setCredit('anthropic', 100);
    await session.send(request());
    expect(Credit.remainingMicros((await server.credit())!)).toBe(0);
    await server.setCredit('anthropic', undefined);
    expect(await server.credit()).toBeUndefined();
  });

  it('switches providers and logs prompts when asked', async () => {
    await server.activate('anthropic', 'a');
    await server.activate('openai', 'o');
    await server.update((s) => {
      s.logPrompts = true;
    });
    expect(await server.configuredProviders()).toEqual(['anthropic', 'openai']);
    expect((await server.model('fast'))?.id).toBe('gpt-5-nano');
    const reply = await new TokenClient(server).session('x', 'fast').send(request('hello?'));
    expect(reply.text).toBe('Hello there');
    const row = (await server.recentUsage())[0]!;
    expect(row.provider).toBe('openai');
    expect(row.prompt).toBe('hello?');
    expect(row.reply).toBe('Hello there');
  });

  it('serves profiles from the OpenAI-compatible vendors', async () => {
    transport.responses['api.deepseek.com'] = { status: 200, body: Canned.openai };
    transport.responses['api.moonshot.ai'] = { status: 200, body: Canned.openai };
    transport.responses['dashscope-intl.aliyuncs.com'] = { status: 200, body: Canned.openai };
    transport.responses['api.x.ai'] = { status: 200, body: Canned.openai };
    transport.responses['api.mistral.ai'] = { status: 200, body: Canned.openai };
    transport.responses['api.cohere.com'] = { status: 200, body: Canned.openai };
    transport.responses['openrouter.ai'] = { status: 200, body: Canned.openai };
    for (const [kind, model] of [
      ['deepseek', 'deepseek-v4-pro'], ['kimi', 'kimi-k3'], ['qwen', 'qwen3.8-max'], ['grok', 'grok-4.7'],
      ['mistral', 'mistral-large-latest'], ['cohere', 'command-a-plus-05-2026'], ['openrouter', 'anthropic/claude-opus-5.5'],
    ] as const) {
      await server.activate(kind, `k-${kind}`);
      expect(await server.isReady()).toBe(true);
      expect((await server.model('character'))?.id).toBe(model);
      const reply = await new TokenClient(server).session('bush', 'character').send(request());
      expect(reply.text).toBe('Hello there');
      expect(reply.provider).toBe(kind);
      expect(reply.model).toBe(model);
      expect(transport.requests.at(-1)?.headers.Authorization).toBe(`Bearer k-${kind}`);
      expect((await server.recentUsage())[0]!.provider).toBe(kind);
    }
    expect(await server.configuredProviders()).toEqual(['deepseek', 'kimi', 'qwen', 'grok', 'mistral', 'cohere', 'openrouter']);
    expect((await server.usageToday()).requests).toBe(7);
  });

  it('re-encrypts keys from a legacy cipher', async () => {
    // A cipher that marks its output, so a wrong key fails the way AES-GCM's tag check does.
    const tagged = (tag: number): SecretCipher => ({
      async encrypt(p) {
        return new Uint8Array([tag, ...p]);
      },
      async decrypt(c) {
        if (c[0] !== tag) throw new Error('wrong key');
        return c.slice(1);
      },
    });
    const store = new InMemoryStore();
    const old = new TokenServer(store, tagged(1), transport);
    await old.setKey('anthropic', 'sk-a');
    await old.setKey('openai', 'sk-o');
    const server = new TokenServer(store, tagged(2), transport);
    expect(await server.keysReadable(), 'the new cipher cannot read the old keys').toBe(false);
    expect(await server.reencryptKeys(tagged(1))).toEqual(['anthropic', 'openai']);
    expect(await server.keysReadable()).toBe(true);
    expect(await server.key('anthropic')).toBe('sk-a');
    expect(await server.key('openai')).toBe('sk-o');
    expect(await server.reencryptKeys(tagged(1)), 'a second run moves nothing').toEqual([]);
    expect(await server.key('anthropic')).toBe('sk-a');
  });

  it('surfaces HTTP errors and charges nothing for them', async () => {
    await server.activate('anthropic', 'k');
    transport.responses['api.anthropic.com'] = { status: 401, body: '{"error":{"message":"invalid x-api-key"}}' };
    const e = await failure(new TokenClient(server).session('x', 'character').send(request()));
    expect(e.code).toBe('http');
    expect(e.details.status).toBe(401);
    expect((await server.usageToday()).requests).toBe(0);
  });

  it('reports refusals as a stop reason, not an error', async () => {
    await server.activate('anthropic', 'k');
    transport.responses['api.anthropic.com'] = { status: 200, body: Canned.anthropicRefusal };
    const reply = await new TokenClient(server).session('x', 'vision').send(request());
    expect(reply.stop).toBe('refusal');
  });

  it('estimates images at ~1,600 tokens each', () => {
    const r: ChatRequest = { messages: [ChatMessage.userParts([{ type: 'image', mediaType: 'image/png', data: 'AAAA' }])] };
    expect(estimatedPromptTokens(r)).toBeGreaterThanOrEqual(1600);
  });
});

describe('AesGcmCipher', () => {
  it('round-trips with a generated secret and rejects bad keys', async () => {
    const secret = AesGcmCipher.generateSecret();
    const cipher = new AesGcmCipher(secret);
    const ct = await cipher.encrypt(bytes.fromUtf8('sk-live-123'));
    expect(bytes.toUtf8(ct)).not.toContain('sk-live');
    expect(bytes.toUtf8(await cipher.decrypt(ct))).toBe('sk-live-123');
    expect(() => new AesGcmCipher('c2hvcnQ=')).toThrow(/16 or 32 bytes/);
    await expect(new AesGcmCipher(AesGcmCipher.generateSecret()).decrypt(ct)).rejects.toBeDefined();
  });
});
