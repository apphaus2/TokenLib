/** Anthropic Messages API over HTTPS with server-sent events. Port of `AnthropicProvider.swift`. */
import { ProfileInfo } from '../catalog';
import { messageParts, type ChatEvent, type ChatMessage, type ChatRequest, type StopReason, type Usage } from '../chat';
import { TokenLibError } from '../chat';
import { callMaxTokens, callTemperature, num, obj, parseJSONObject, str, type Provider, type ProviderCall, type ProviderStreamParser } from '../provider';
import { httpRequest, SSEParser, type HttpRequest } from '../transport';

export const ANTHROPIC_ENDPOINT = 'https://api.anthropic.com/v1/messages';
export const ANTHROPIC_VERSION = '2023-06-01';
/** Server-side refusal fallbacks (`fallbacks: "default"`) for the models that run safety classifiers. */
const FALLBACK_BETA = 'server-side-fallback-2026-07-01';

const isFiveGeneration = (id: string) => id.startsWith('claude-opus-5') || id.startsWith('claude-sonnet-5') || id.startsWith('claude-fable-5');
const supportsFallbacks = (id: string) => id.startsWith('claude-opus-5') || id.startsWith('claude-sonnet-5-5') || id.startsWith('claude-fable-5');

export class AnthropicProvider implements Provider {
  readonly kind = 'anthropic' as const;

  request(chat: ChatRequest, call: ProviderCall): HttpRequest {
    if (!call.key) throw TokenLibError.missingKey('anthropic');
    const body: Record<string, unknown> = {
      model: call.model.id,
      max_tokens: callMaxTokens(call, chat),
      stream: true,
      messages: anthropicMessages(chat.messages),
    };
    if (chat.system) body.system = chat.system;
    const five = isFiveGeneration(call.model.id);
    const t = callTemperature(call, chat);
    // Sampling parameters are rejected on the 5-generation models; thinking effort takes their place there.
    if (t !== undefined && !five) body.temperature = t;
    const outputConfig: Record<string, unknown> = {};
    const effort = ProfileInfo.effort(call.profile);
    if (effort && five) outputConfig.effort = effort;
    if (chat.jsonSchema) outputConfig.format = { type: 'json_schema', schema: chat.jsonSchema };
    if (Object.keys(outputConfig).length) body.output_config = outputConfig;
    const headers: Record<string, string> = {
      'Content-Type': 'application/json',
      'x-api-key': call.key,
      'anthropic-version': ANTHROPIC_VERSION,
      Accept: 'text/event-stream',
    };
    if (supportsFallbacks(call.model.id)) {
      headers['anthropic-beta'] = FALLBACK_BETA;
      body.fallbacks = 'default';
    }
    return httpRequest(ANTHROPIC_ENDPOINT, headers, body);
  }

  makeParser(): ProviderStreamParser {
    return new AnthropicParser();
  }
}

type Block = { type: 'text'; text: string } | { type: 'image'; source: { type: 'base64'; media_type: string; data: string } };

function toBlocks(message: ChatMessage): Block[] {
  return messageParts(message).map((p) =>
    p.type === 'text' ? { type: 'text', text: p.text } : { type: 'image', source: { type: 'base64', media_type: p.mediaType, data: p.data } },
  );
}

/** Anthropic requires alternating roles starting with `user`; adjacent same-role turns are merged. */
export function anthropicMessages(messages: ChatMessage[]): { role: string; content: string | Block[] }[] {
  const out: { role: string; content: string | Block[] }[] = [];
  for (const m of messages) {
    const last = out[out.length - 1];
    if (last && last.role === m.role) {
      if (typeof last.content === 'string' && !m.parts) last.content = `${last.content}\n${m.text}`;
      else {
        const prev: Block[] = typeof last.content === 'string' ? [{ type: 'text', text: last.content }] : last.content;
        last.content = [...prev, ...toBlocks(m)];
      }
    } else {
      out.push({ role: m.role, content: m.parts ? toBlocks(m) : m.text });
    }
  }
  if (out[0]?.role !== 'user') out.unshift({ role: 'user', content: '(start)' });
  return out;
}

export function anthropicStop(reason: string): StopReason {
  switch (reason) {
    case 'end_turn':
    case 'stop_sequence':
      return 'end';
    case 'max_tokens':
      return 'maxTokens';
    case 'refusal':
      return 'refusal';
    default:
      return 'other';
  }
}

class AnthropicParser implements ProviderStreamParser {
  private sse = new SSEParser();
  private usage: Usage = { promptTokens: 0, replyTokens: 0 };
  private stop: StopReason = 'end';
  private finished = false;

  feed(line: string): ChatEvent[] {
    const event = this.sse.feed(line);
    if (!event) return [];
    const json = parseJSONObject(event.data);
    if (!json) return [];
    switch (json.type) {
      case 'message_start': {
        const u = obj(obj(json.message)?.usage);
        if (u) this.usage.promptTokens = num(u.input_tokens) ?? 0;
        break;
      }
      case 'content_block_delta': {
        const delta = obj(json.delta);
        if (delta?.type === 'text_delta') {
          const text = str(delta.text);
          if (text) return [{ type: 'text', text }];
        }
        break;
      }
      case 'message_delta': {
        const u = obj(json.usage);
        const out = num(u?.output_tokens);
        if (out !== undefined) this.usage.replyTokens = out;
        const reason = str(obj(json.delta)?.stop_reason);
        if (reason) this.stop = anthropicStop(reason);
        break;
      }
      case 'message_stop':
        this.finished = true;
        return [{ type: 'done', usage: { ...this.usage }, stop: this.stop }];
      case 'error': {
        const message = str(obj(json.error)?.message) ?? 'error';
        this.finished = true;
        return [{ type: 'done', usage: { ...this.usage }, stop: 'other' }, { type: 'text', text: message }];
      }
      default:
        break;
    }
    return [];
  }

  finish(): ChatEvent[] {
    // A body that ends without a blank line still holds its last event.
    const out = this.feed('');
    if (this.finished) return out;
    this.finished = true;
    out.push({ type: 'done', usage: { ...this.usage }, stop: this.stop });
    return out;
  }
}
