/**
 * OpenAI chat completions over HTTPS with server-sent events. The same code serves
 * every OpenAI-compatible vendor (DeepSeek, Kimi, Qwen, Grok, Mistral, Cohere,
 * OpenRouter) at its own endpoint, each with a small dialect: which token parameter
 * it takes, whether it takes a temperature, how it reports usage, how it takes a
 * JSON schema and how its reasoning is switched. It also serves `local`: an
 * OpenAI-compatible server (Ollama, LM Studio, vLLM) at a base URL from the
 * settings, with no key. Port of `OpenAIProvider.swift`.
 */
import { ProfileInfo, type ProviderKind } from '../catalog';
import { messageParts, type ChatEvent, type ChatMessage, type ChatRequest, type StopReason, type Usage } from '../chat';
import { TokenLibError } from '../chat';
import { arr, callMaxTokens, callTemperature, num, obj, parseJSONObject, str, type Provider, type ProviderCall, type ProviderStreamParser } from '../provider';
import { httpRequest, SSEParser, type HttpRequest } from '../transport';

export const OPENAI_ENDPOINT = 'https://api.openai.com/v1/chat/completions';
export const DEEPSEEK_ENDPOINT = 'https://api.deepseek.com/chat/completions';
export const KIMI_ENDPOINT = 'https://api.moonshot.ai/v1/chat/completions';
export const QWEN_ENDPOINT = 'https://dashscope-intl.aliyuncs.com/compatible-mode/v1/chat/completions';
export const GROK_ENDPOINT = 'https://api.x.ai/v1/chat/completions';
export const MISTRAL_ENDPOINT = 'https://api.mistral.ai/v1/chat/completions';
export const COHERE_ENDPOINT = 'https://api.cohere.com/compatibility/v1/chat/completions';
export const OPENROUTER_ENDPOINT = 'https://openrouter.ai/api/v1/chat/completions';

/**
 * How a vendor takes a JSON schema: `schema` is `response_format: json_schema`, enforced by the vendor;
 * `object` is `response_format: json_object` with the schema appended to the system prompt (these APIs also
 * require the prompt to mention JSON); `objectWithSchema` is Cohere's `{type: json_object, schema}`.
 */
export type Structured = 'schema' | 'object' | 'objectWithSchema';

/** The vendor's variations on the chat completions request. */
export interface Dialect {
  /** The hosted endpoint; `undefined` for `local`, whose base URL comes from the settings. */
  endpoint?: string;
  /** `max_completion_tokens` where `max_tokens` is retired, `max_tokens` elsewhere. */
  maxTokensKey: 'max_tokens' | 'max_completion_tokens';
  /** Whether the vendor takes sampling parameters (OpenAI's current models reject them; Kimi fixes them per model; OpenRouter's depend on the model). */
  temperature: boolean;
  /** Whether to ask for usage in the stream with `stream_options.include_usage` (OpenRouter always sends it; Cohere does not document it). */
  streamUsage: boolean;
  structured: Structured;
  /** Extra body fields that set the vendor's reasoning from the profile's effort (`low` or `high`) for a model id; empty when the vendor has no switch. */
  reasoning: (effort: string, modelId: string) => Record<string, unknown>;
}

const none = () => ({});

export function openAIDialect(kind: ProviderKind): Dialect {
  switch (kind) {
    case 'openai':
      return { endpoint: OPENAI_ENDPOINT, maxTokensKey: 'max_completion_tokens', temperature: false, streamUsage: true, structured: 'schema', reasoning: none };
    case 'deepseek':
      // Thinking is on by default; low effort turns it off.
      return {
        endpoint: DEEPSEEK_ENDPOINT, maxTokensKey: 'max_tokens', temperature: true, streamUsage: true, structured: 'object',
        reasoning: (effort) => ({ thinking: effort === 'low' ? { type: 'disabled' } : { type: 'enabled', reasoning_effort: effort } }),
      };
    case 'kimi':
      // K3 takes reasoning_effort; K2 has a thinking switch.
      return {
        endpoint: KIMI_ENDPOINT, maxTokensKey: 'max_completion_tokens', temperature: false, streamUsage: true, structured: 'schema',
        reasoning: (effort, id) => (id.startsWith('kimi-k3') ? { reasoning_effort: effort } : { thinking: { type: effort === 'low' ? 'disabled' : 'enabled' } }),
      };
    case 'qwen':
      return { endpoint: QWEN_ENDPOINT, maxTokensKey: 'max_tokens', temperature: true, streamUsage: true, structured: 'object', reasoning: (effort) => ({ enable_thinking: effort !== 'low' }) };
    case 'grok':
      // Grok 4 reasons always; the effort scales it.
      return { endpoint: GROK_ENDPOINT, maxTokensKey: 'max_tokens', temperature: true, streamUsage: true, structured: 'schema', reasoning: (effort) => ({ reasoning_effort: effort }) };
    case 'mistral':
      return { endpoint: MISTRAL_ENDPOINT, maxTokensKey: 'max_tokens', temperature: true, streamUsage: true, structured: 'schema', reasoning: (effort) => ({ reasoning_effort: effort === 'low' ? 'none' : 'high' }) };
    case 'cohere':
      // Only the reasoning models take the switch, and only `none` or `high`.
      return {
        endpoint: COHERE_ENDPOINT, maxTokensKey: 'max_tokens', temperature: true, streamUsage: false, structured: 'objectWithSchema',
        reasoning: (effort, id) => (id.startsWith('command-a-plus') || id.startsWith('command-a-reasoning') ? { reasoning_effort: effort === 'low' ? 'none' : 'high' } : {}),
      };
    case 'openrouter':
      return {
        endpoint: OPENROUTER_ENDPOINT, maxTokensKey: 'max_tokens', temperature: false, streamUsage: false, structured: 'schema',
        reasoning: (effort) => ({ reasoning: effort === 'low' ? { enabled: false } : { effort } }),
      };
    default:
      return { maxTokensKey: 'max_tokens', temperature: true, streamUsage: true, structured: 'schema', reasoning: none };
  }
}

/** The hosted endpoint for a kind; `undefined` for `local`. */
export const openAIEndpoint = (kind: ProviderKind): string | undefined => openAIDialect(kind).endpoint;

/** A plain string for text-only messages; text and `image_url` data-URI parts otherwise. */
function content(message: ChatMessage): string | unknown[] {
  if (!message.parts) return message.text;
  return messageParts(message).map((p) =>
    p.type === 'text' ? { type: 'text', text: p.text } : { type: 'image_url', image_url: { url: `data:${p.mediaType};base64,${p.data}` } },
  );
}

export class OpenAIProvider implements Provider {
  constructor(readonly kind: ProviderKind = 'openai') {}

  request(chat: ChatRequest, call: ProviderCall): HttpRequest {
    const kind = this.kind;
    const dialect = openAIDialect(kind);
    let system = chat.system ?? '';
    const body: Record<string, unknown> = { model: call.model.id, stream: true };
    if (dialect.streamUsage) body.stream_options = { include_usage: true };
    body[dialect.maxTokensKey] = callMaxTokens(call, chat);
    const t = callTemperature(call, chat);
    if (dialect.temperature && t !== undefined) body.temperature = t;
    const effort = ProfileInfo.effort(call.profile);
    if (effort) Object.assign(body, dialect.reasoning(effort, call.model.id));
    if (chat.jsonSchema) {
      switch (dialect.structured) {
        case 'schema':
          body.response_format = { type: 'json_schema', json_schema: { name: 'reply', schema: chat.jsonSchema } };
          break;
        case 'objectWithSchema':
          body.response_format = { type: 'json_object', schema: chat.jsonSchema };
          break;
        case 'object':
          body.response_format = { type: 'json_object' };
          system += `${system ? '\n\n' : ''}Reply with a single JSON object that matches this JSON schema: ${JSON.stringify(chat.jsonSchema)}`;
          break;
      }
    }
    const messages: unknown[] = [];
    if (system) messages.push({ role: 'system', content: system });
    for (const m of chat.messages) messages.push({ role: m.role, content: content(m) });
    body.messages = messages;
    const headers: Record<string, string> = { 'Content-Type': 'application/json', Accept: 'text/event-stream' };
    let url: string;
    if (kind === 'local') {
      if (!call.baseURL) throw TokenLibError.transport('no local server URL');
      url = `${call.baseURL.replace(/\/+$/, '')}/chat/completions`;
    } else {
      if (!call.key) throw TokenLibError.missingKey(kind);
      if (!dialect.endpoint) throw TokenLibError.transport(`no endpoint for ${kind}`);
      headers.Authorization = `Bearer ${call.key}`;
      url = dialect.endpoint;
    }
    return httpRequest(url, headers, body);
  }

  makeParser(): ProviderStreamParser {
    return new OpenAIParser();
  }
}

class OpenAIParser implements ProviderStreamParser {
  private sse = new SSEParser();
  private usage: Usage = { promptTokens: 0, replyTokens: 0 };
  private stop: StopReason = 'end';
  private finished = false;

  feed(line: string): ChatEvent[] {
    const event = this.sse.feed(line);
    if (!event) return [];
    if (event.data === '[DONE]') {
      this.finished = true;
      return [{ type: 'done', usage: { ...this.usage }, stop: this.stop }];
    }
    const json = parseJSONObject(event.data);
    if (!json) return [];
    const out: ChatEvent[] = [];
    const u = obj(json.usage);
    if (u) {
      this.usage = { promptTokens: num(u.prompt_tokens) ?? this.usage.promptTokens, replyTokens: num(u.completion_tokens) ?? this.usage.replyTokens };
    }
    for (const c of arr(json.choices)) {
      const choice = obj(c);
      const text = str(obj(choice?.delta)?.content);
      if (text) out.push({ type: 'text', text });
      const reason = str(choice?.finish_reason);
      if (reason) this.stop = reason === 'length' ? 'maxTokens' : reason === 'content_filter' ? 'refusal' : 'end';
    }
    return out;
  }

  finish(): ChatEvent[] {
    const out = this.feed('');
    if (this.finished) return out;
    this.finished = true;
    out.push({ type: 'done', usage: { ...this.usage }, stop: this.stop });
    return out;
  }
}
