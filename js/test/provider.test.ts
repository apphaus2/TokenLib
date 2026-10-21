import { describe, expect, it } from 'vitest';
import {
  AnthropicProvider,
  ANTHROPIC_ENDPOINT,
  anthropicMessages,
  bodyJSON,
  Catalog,
  ChatMessage,
  COHERE_ENDPOINT,
  costMicros,
  DEEPSEEK_ENDPOINT,
  GeminiProvider,
  GROK_ENDPOINT,
  KIMI_ENDPOINT,
  LineSplitter,
  MISTRAL_ENDPOINT,
  OpenAIProvider,
  OPENROUTER_ENDPOINT,
  PROVIDER_KINDS,
  providerIsNative,
  providerNeedsKey,
  Providers,
  QWEN_ENDPOINT,
  type ChatRequest,
  type Provider,
  type StopReason,
  type Usage,
} from '../src';
import { Canned } from './fake-transport';

const chat: ChatRequest = { system: 'You are a bush.', messages: [ChatMessage.user('hello'), ChatMessage.assistant('hi'), ChatMessage.user('sing')] };

function collect(provider: Provider, body: string): { text: string; done?: { usage: Usage; stop: StopReason } } {
  const parser = provider.makeParser();
  let text = '';
  let done: { usage: Usage; stop: StopReason } | undefined;
  const splitter = new LineSplitter();
  const lines = splitter.append(new TextEncoder().encode(body));
  const last = splitter.flush();
  if (last !== undefined) lines.push(last);
  const handle = (events: ReturnType<typeof parser.feed>) => {
    for (const e of events) {
      if (e.type === 'text') text += e.text;
      else done = { usage: e.usage, stop: e.stop };
    }
  };
  for (const line of lines) handle(parser.feed(line));
  handle(parser.finish());
  return { text, done };
}

describe('AnthropicProvider', () => {
  const provider = new AnthropicProvider();

  it('builds the request and parses the stream', () => {
    const request = provider.request(chat, { model: Catalog.model('claude-opus-5-5')!, key: 'sk-test', profile: 'character' });
    expect(request.url).toBe(ANTHROPIC_ENDPOINT);
    expect(request.headers['x-api-key']).toBe('sk-test');
    expect(request.headers['anthropic-version']).toBe('2023-06-01');
    expect(request.headers['anthropic-beta']).toBe('server-side-fallback-2026-07-01');
    const body = bodyJSON(request)!;
    expect(body.model).toBe('claude-opus-5-5');
    expect(body.max_tokens).toBe(400);
    expect(body.stream).toBe(true);
    expect(body.system).toBe('You are a bush.');
    expect(body.fallbacks).toBe('default');
    expect((body.output_config as { effort: string }).effort).toBe('low');
    expect(body.temperature, 'sampling parameters are not sent to the 5-generation models').toBeUndefined();
    expect((body.messages as { role: string }[]).map((m) => m.role)).toEqual(['user', 'assistant', 'user']);
    const result = collect(provider, Canned.anthropic);
    expect(result.text).toBe('Ask, and the bush shall sing.');
    expect(result.done?.usage).toEqual({ promptTokens: 25, replyTokens: 9 });
    expect(result.done?.stop).toBe('end');
  });

  it('keeps temperature and sends no effort or fallbacks on Haiku', () => {
    const request = provider.request(chat, { model: Catalog.model('claude-haiku-4-5')!, key: 'k', profile: 'character' });
    const body = bodyJSON(request)!;
    expect(body.temperature).toBe(0.9);
    expect(body.output_config).toBeUndefined();
    expect(body.fallbacks).toBeUndefined();
    expect(request.headers['anthropic-beta']).toBeUndefined();
  });

  it('requires a key', () => {
    expect(() => provider.request(chat, { model: Catalog.model('claude-opus-5-5')!, profile: 'fast' })).toThrow(/no API key/);
  });

  it('merges adjacent roles and starts with user', () => {
    const merged = anthropicMessages([ChatMessage.assistant('a'), ChatMessage.user('b'), ChatMessage.user('c')]);
    expect(merged.map((m) => m.role)).toEqual(['user', 'assistant', 'user']);
    expect(merged[2]!.content).toBe('b\nc');
  });

  it('sends image parts as base64 blocks and a JSON schema as output_config.format', () => {
    const schema = { type: 'object', properties: { ok: { type: 'boolean' } }, required: ['ok'], additionalProperties: false };
    const request = provider.request(
      {
        messages: [ChatMessage.userParts([{ type: 'text', text: 'Photo 1' }, { type: 'image', mediaType: 'image/jpeg', data: 'AAAA' }, { type: 'text', text: 'Compare.' }])],
        jsonSchema: schema,
        maxTokens: 8000,
      },
      { model: Catalog.model('claude-opus-5-5')!, key: 'k', profile: 'vision' },
    );
    const body = bodyJSON(request)!;
    expect(body.max_tokens).toBe(8000);
    const content = (body.messages as { content: unknown[] }[])[0]!.content as { type: string; source?: { media_type: string } }[];
    expect(content.map((c) => c.type)).toEqual(['text', 'image', 'text']);
    expect(content[1]!.source!.media_type).toBe('image/jpeg');
    expect(body.output_config).toEqual({ effort: 'high', format: { type: 'json_schema', schema } });
  });

  it('reports a refusal stop', () => {
    const result = collect(provider, Canned.anthropicRefusal);
    expect(result.done?.stop).toBe('refusal');
    expect(result.text).toBe('');
  });
});

describe('OpenAIProvider', () => {
  it('builds the request and parses the stream', () => {
    const provider = new OpenAIProvider();
    const request = provider.request(chat, { model: Catalog.model('gpt-5-mini')!, key: 'sk-o', profile: 'fast' });
    expect(request.headers.Authorization).toBe('Bearer sk-o');
    const body = bodyJSON(request)!;
    expect(body.max_completion_tokens).toBe(1024);
    expect((body.stream_options as { include_usage: boolean }).include_usage).toBe(true);
    const messages = body.messages as { role: string }[];
    expect(messages[0]!.role).toBe('system');
    expect(messages).toHaveLength(4);
    const result = collect(provider, Canned.openai);
    expect(result.text).toBe('Hello there');
    expect(result.done?.usage).toEqual({ promptTokens: 12, replyTokens: 2 });
  });

  it('serves DeepSeek, Kimi and Qwen as OpenAI-compatible vendors', () => {
    // DeepSeek: its own endpoint, max_tokens, temperature, thinking off for low effort, JSON mode with the schema in the prompt
    const deepseek = new OpenAIProvider('deepseek').request(
      { system: 'bush', messages: [ChatMessage.user('sing')], jsonSchema: { type: 'object' } },
      { model: Catalog.model('deepseek-flash')!, key: 'ds', profile: 'character' },
    );
    expect(deepseek.url).toBe(DEEPSEEK_ENDPOINT);
    expect(deepseek.headers.Authorization).toBe('Bearer ds');
    let body = bodyJSON(deepseek)!;
    expect(body.model).toBe('deepseek-flash');
    expect(body.max_tokens).toBe(400);
    expect(body.max_completion_tokens).toBeUndefined();
    expect(body.temperature).toBe(0.9);
    expect(body.thinking).toEqual({ type: 'disabled' });
    expect(body.response_format).toEqual({ type: 'json_object' });
    let messages = body.messages as { role: string; content: string }[];
    expect(messages[0]!.role).toBe('system');
    expect(messages[0]!.content.startsWith('bush\n\nReply with a single JSON object that matches this JSON schema: {"type":"object"}')).toBe(true);
    body = bodyJSON(new OpenAIProvider('deepseek').request(chat, { model: Catalog.model('deepseek-v4-pro')!, key: 'ds', profile: 'assistant' }))!;
    expect(body.thinking).toEqual({ type: 'enabled', reasoning_effort: 'high' });
    expect(body.temperature).toBeUndefined();
    expect(body.response_format).toBeUndefined();
    expect(body.messages).toHaveLength(4);

    // Kimi: max_completion_tokens, no temperature, reasoning_effort on K3 and a thinking switch on K2, json_schema
    const kimi = new OpenAIProvider('kimi').request({ messages: [ChatMessage.user('sing')], jsonSchema: { type: 'object' } }, { model: Catalog.model('kimi-k3')!, key: 'mk', profile: 'assistant' });
    expect(kimi.url).toBe(KIMI_ENDPOINT);
    expect(kimi.headers.Authorization).toBe('Bearer mk');
    body = bodyJSON(kimi)!;
    expect(body.max_completion_tokens).toBe(4096);
    expect(body.max_tokens).toBeUndefined();
    expect(body.temperature).toBeUndefined();
    expect(body.reasoning_effort).toBe('high');
    expect(body.thinking).toBeUndefined();
    expect((body.response_format as { type: string }).type).toBe('json_schema');
    expect(body.messages).toHaveLength(1);
    body = bodyJSON(new OpenAIProvider('kimi').request(chat, { model: Catalog.model('kimi-k2.6')!, key: 'mk', profile: 'character' }))!;
    expect(body.thinking).toEqual({ type: 'disabled' });
    expect(body.reasoning_effort).toBeUndefined();
    expect(body.temperature, 'Kimi fixes the temperature per model').toBeUndefined();

    // Qwen: the international compatible-mode endpoint, max_tokens, temperature, enable_thinking, JSON mode
    const qwen = new OpenAIProvider('qwen').request({ messages: [ChatMessage.user('sing')], jsonSchema: { type: 'object' } }, { model: Catalog.model('qwen3.8-flash')!, key: 'qw', profile: 'fast' });
    expect(qwen.url).toBe(QWEN_ENDPOINT);
    expect(qwen.headers.Authorization).toBe('Bearer qw');
    body = bodyJSON(qwen)!;
    expect(body.max_tokens).toBe(1024);
    expect(body.temperature).toBe(0.2);
    expect(body.enable_thinking).toBe(false);
    expect(body.response_format).toEqual({ type: 'json_object' });
    expect((body.messages as { role: string }[])[0]!.role).toBe('system');
    body = bodyJSON(new OpenAIProvider('qwen').request(chat, { model: Catalog.model('qwen3.8-max')!, key: 'qw', profile: 'vision' }))!;
    expect(body.enable_thinking).toBe(true);

    // each needs its own key, and the stream parser is the OpenAI one
    for (const kind of ['deepseek', 'kimi', 'qwen'] as const) {
      expect(() => new OpenAIProvider(kind).request(chat, { model: Catalog.modelFor('fast', kind), profile: 'fast' })).toThrow(`no API key for ${kind}`);
      expect(Providers.for(kind).kind).toBe(kind);
      expect(collect(Providers.for(kind), Canned.openai).text).toBe('Hello there');
    }
  });

  it('serves Grok, Mistral, Cohere and OpenRouter as OpenAI-compatible vendors', () => {
    const schema = { type: 'object' };
    const withSchema: ChatRequest = { system: 'bush', messages: [ChatMessage.user('sing')], jsonSchema: schema };

    // Grok: api.x.ai, max_tokens, temperature, reasoning_effort scaled by the profile, json_schema, usage asked for in the stream
    const grok = new OpenAIProvider('grok').request(withSchema, { model: Catalog.model('grok-4.7')!, key: 'xk', profile: 'character' });
    expect(grok.url).toBe(GROK_ENDPOINT);
    expect(grok.headers.Authorization).toBe('Bearer xk');
    let body = bodyJSON(grok)!;
    expect(body.max_tokens).toBe(400);
    expect(body.temperature).toBe(0.9);
    expect(body.reasoning_effort).toBe('low');
    expect((body.response_format as { type: string }).type).toBe('json_schema');
    expect(body.stream_options).toEqual({ include_usage: true });
    expect((body.messages as { content: string }[])[0]!.content, 'the schema is enforced, not prompted').toBe('bush');
    body = bodyJSON(new OpenAIProvider('grok').request(chat, { model: Catalog.model('grok-4.3')!, key: 'xk', profile: 'assistant' }))!;
    expect(body.reasoning_effort).toBe('high');

    // Mistral: api.mistral.ai, reasoning_effort none/high, json_schema
    const mistral = new OpenAIProvider('mistral').request(withSchema, { model: Catalog.model('mistral-small-latest')!, key: 'mk', profile: 'fast' });
    expect(mistral.url).toBe(MISTRAL_ENDPOINT);
    body = bodyJSON(mistral)!;
    expect(body.model).toBe('mistral-small-latest');
    expect(body.max_tokens).toBe(1024);
    expect(body.temperature).toBe(0.2);
    expect(body.reasoning_effort).toBe('none');
    expect((body.response_format as { type: string }).type).toBe('json_schema');
    body = bodyJSON(new OpenAIProvider('mistral').request(chat, { model: Catalog.model('mistral-large-latest')!, key: 'mk', profile: 'vision' }))!;
    expect(body.reasoning_effort).toBe('high');

    // Cohere: the compatibility endpoint, the schema inside json_object, reasoning only on the reasoning models, no stream_options
    const cohere = new OpenAIProvider('cohere').request(withSchema, { model: Catalog.model('command-a-plus-05-2026')!, key: 'ck', profile: 'assistant' });
    expect(cohere.url).toBe(COHERE_ENDPOINT);
    body = bodyJSON(cohere)!;
    expect(body.max_tokens).toBe(4096);
    expect(body.temperature, 'the assistant profile has none').toBeUndefined();
    expect(body.reasoning_effort).toBe('high');
    expect(body.response_format).toEqual({ type: 'json_object', schema });
    expect(body.stream_options).toBeUndefined();
    expect((body.messages as { content: string }[])[0]!.content, 'the schema travels in response_format, not the prompt').toBe('bush');
    body = bodyJSON(new OpenAIProvider('cohere').request(chat, { model: Catalog.model('command-r7b-12-2024')!, key: 'ck', profile: 'character' }))!;
    expect(body.reasoning_effort, 'R7B has no reasoning switch').toBeUndefined();
    expect(body.temperature).toBe(0.9);

    // OpenRouter: one key for many vendors, no temperature, the unified reasoning object, usage comes unasked
    const openrouter = new OpenAIProvider('openrouter').request(withSchema, { model: Catalog.model('anthropic/claude-opus-5.5')!, key: 'ok', profile: 'character' });
    expect(openrouter.url).toBe(OPENROUTER_ENDPOINT);
    body = bodyJSON(openrouter)!;
    expect(body.model).toBe('anthropic/claude-opus-5.5');
    expect(body.max_tokens).toBe(400);
    expect(body.temperature).toBeUndefined();
    expect(body.reasoning).toEqual({ enabled: false });
    expect(body.stream_options).toBeUndefined();
    expect((body.response_format as { type: string }).type).toBe('json_schema');
    body = bodyJSON(new OpenAIProvider('openrouter').request(chat, { model: Catalog.model('anthropic/claude-haiku-4.5')!, key: 'ok', profile: 'assistant' }))!;
    expect(body.reasoning).toEqual({ effort: 'high' });

    for (const kind of ['grok', 'mistral', 'cohere', 'openrouter'] as const) {
      expect(() => new OpenAIProvider(kind).request(chat, { model: Catalog.modelFor('fast', kind), profile: 'fast' })).toThrow(`no API key for ${kind}`);
      expect(Providers.for(kind).kind).toBe(kind);
      expect(collect(Providers.for(kind), Canned.openai).text).toBe('Hello there');
    }
  });

  it('serves a local server from its base URL with no key', () => {
    const provider = new OpenAIProvider('local');
    const model = { ...Catalog.local[0]!, id: 'llama3' };
    const request = provider.request(chat, { model, baseURL: 'http://192.168.1.20:11434/v1', profile: 'character' });
    expect(request.url).toBe('http://192.168.1.20:11434/v1/chat/completions');
    expect(request.headers.Authorization).toBeUndefined();
    expect(bodyJSON(request)!.model).toBe('llama3');
    expect(bodyJSON(request)!.temperature).toBe(0.9);
    expect(() => provider.request(chat, { model, profile: 'character' })).toThrow(/no local server URL/);
  });
});

describe('GeminiProvider', () => {
  it('builds the request and parses the stream', () => {
    const provider = new GeminiProvider();
    const request = provider.request(chat, { model: Catalog.model('gemini-2.5-flash')!, key: 'g', profile: 'assistant' });
    expect(request.url.endsWith('gemini-2.5-flash:streamGenerateContent?alt=sse')).toBe(true);
    expect(request.headers['x-goog-api-key']).toBe('g');
    const body = bodyJSON(request)!;
    expect((body.contents as { role: string }[]).map((c) => c.role)).toEqual(['user', 'model', 'user']);
    expect(body.systemInstruction).toBeDefined();
    const result = collect(provider, Canned.gemini);
    expect(result.text).toBe('Woof.');
    expect(result.done?.usage).toEqual({ promptTokens: 7, replyTokens: 2 });
    expect(result.done?.stop).toBe('end');
  });
});

describe('Catalog', () => {
  it('picks the nearest tier and honours vision', () => {
    expect(Catalog.modelFor('character', 'anthropic').id).toBe('claude-opus-5-5');
    expect(Catalog.modelFor('fast', 'openai').id).toBe('gpt-5-nano');
    expect(Catalog.modelFor('vision', 'local').id, 'local has no vision model; falls back to the only one').toBe('local');
    expect(Catalog.modelFor('character', 'deepseek').id).toBe('deepseek-v4-pro');
    expect(Catalog.modelFor('vision', 'deepseek').id, 'V4 Pro has no vision; Flash does').toBe('deepseek-flash');
    expect(Catalog.modelFor('fast', 'kimi').id, 'no fast tier; the nearest is balanced').toBe('kimi-k2.6');
    expect(Catalog.modelFor('vision', 'kimi').id).toBe('kimi-k3');
    expect(Catalog.modelFor('fast', 'qwen').id).toBe('qwen3.8-flash');
    expect(Catalog.modelFor('vision', 'qwen').id).toBe('qwen3.8-max');
    expect(Catalog.modelFor('fast', 'grok').id).toBe('grok-4.3');
    expect(Catalog.modelFor('vision', 'grok').id).toBe('grok-4.7');
    expect(Catalog.modelFor('character', 'mistral').id).toBe('mistral-large-latest');
    expect(Catalog.modelFor('fast', 'mistral').id).toBe('mistral-small-latest');
    expect(Catalog.modelFor('vision', 'cohere').id).toBe('command-a-plus-05-2026');
    expect(Catalog.modelFor('fast', 'cohere').id).toBe('command-r7b-12-2024');
    expect(Catalog.modelFor('character', 'openrouter').id).toBe('anthropic/claude-opus-5.5');
    expect(Catalog.modelFor('fast', 'openrouter').id).toBe('anthropic/claude-haiku-4.5');
    expect([...PROVIDER_KINDS]).toEqual(['anthropic', 'openai', 'gemini', 'deepseek', 'kimi', 'qwen', 'grok', 'mistral', 'cohere', 'openrouter', 'apple', 'local']);
    expect(Catalog.modelFor('assistant', 'apple').id, 'one model serves every profile').toBe('apple-on-device');
    expect(Catalog.modelFor('vision', 'apple').vision).toBe(false);
    expect(costMicros(Catalog.model('apple-on-device')!, 1000, 1000)).toBe(0);
    expect(providerNeedsKey('apple')).toBe(false);
    expect(PROVIDER_KINDS.filter(providerIsNative)).toEqual(['apple']);
  });
});
