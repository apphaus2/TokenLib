/** Google Gemini generateContent over HTTPS with server-sent events. Port of `GeminiProvider.swift`. */
import { messageParts, type ChatEvent, type ChatMessage, type ChatRequest, type StopReason, type Usage } from '../chat';
import { TokenLibError } from '../chat';
import { arr, callMaxTokens, callTemperature, num, obj, parseJSONObject, str, type Provider, type ProviderCall, type ProviderStreamParser } from '../provider';
import { httpRequest, SSEParser, type HttpRequest } from '../transport';

export const GEMINI_BASE = 'https://generativelanguage.googleapis.com/v1beta/models/';

function parts(message: ChatMessage): unknown[] {
  return messageParts(message).map((p) => (p.type === 'text' ? { text: p.text } : { inlineData: { mimeType: p.mediaType, data: p.data } }));
}

export class GeminiProvider implements Provider {
  readonly kind = 'gemini' as const;

  request(chat: ChatRequest, call: ProviderCall): HttpRequest {
    if (!call.key) throw TokenLibError.missingKey('gemini');
    const body: Record<string, unknown> = {
      contents: chat.messages.map((m) => ({ role: m.role === 'user' ? 'user' : 'model', parts: parts(m) })),
    };
    if (chat.system) body.systemInstruction = { parts: [{ text: chat.system }] };
    const config: Record<string, unknown> = { maxOutputTokens: callMaxTokens(call, chat) };
    const t = callTemperature(call, chat);
    if (t !== undefined) config.temperature = t;
    if (chat.jsonSchema) config.responseMimeType = 'application/json';
    body.generationConfig = config;
    const url = `${GEMINI_BASE}${call.model.id}:streamGenerateContent?alt=sse`;
    return httpRequest(url, { 'Content-Type': 'application/json', 'x-goog-api-key': call.key, Accept: 'text/event-stream' }, body);
  }

  makeParser(): ProviderStreamParser {
    return new GeminiParser();
  }
}

class GeminiParser implements ProviderStreamParser {
  private sse = new SSEParser();
  private usage: Usage = { promptTokens: 0, replyTokens: 0 };
  private stop: StopReason = 'end';
  private finished = false;

  feed(line: string): ChatEvent[] {
    const event = this.sse.feed(line);
    if (!event) return [];
    const json = parseJSONObject(event.data);
    if (!json) return [];
    const out: ChatEvent[] = [];
    const u = obj(json.usageMetadata);
    if (u) {
      this.usage = { promptTokens: num(u.promptTokenCount) ?? this.usage.promptTokens, replyTokens: num(u.candidatesTokenCount) ?? this.usage.replyTokens };
    }
    for (const c of arr(json.candidates)) {
      const candidate = obj(c);
      for (const p of arr(obj(candidate?.content)?.parts)) {
        const text = str(obj(p)?.text);
        if (text) out.push({ type: 'text', text });
      }
      const reason = str(candidate?.finishReason);
      if (reason) this.stop = reason === 'MAX_TOKENS' ? 'maxTokens' : reason === 'SAFETY' ? 'refusal' : 'end';
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
