/**
 * The request and the streamed reply, in TokenLib's own terms. Providers translate
 * these to their wire formats; consumers never see a provider.
 *
 * Port of TokenLib `Chat.swift`: text and image parts, and an optional JSON
 * schema for structured replies, the same as the Swift and Kotlin packages.
 */
import type { ProviderKind } from './catalog';

export type ImageMediaType = 'image/jpeg' | 'image/png' | 'image/webp' | 'image/gif';

export type ChatPart =
  | { type: 'text'; text: string }
  | { type: 'image'; mediaType: ImageMediaType; /** base64, no data: prefix */ data: string };

export type ChatRole = 'user' | 'assistant';

export interface ChatMessage {
  role: ChatRole;
  /** Plain text; when `parts` is set this is the concatenated text, kept for logging and estimates. */
  text: string;
  /** Multimodal content; when absent the message is `text` alone. */
  parts?: ChatPart[];
}

export const ChatMessage = {
  /** A user message: plain text, or text and image parts (the same as `userParts`). */
  user(content: string | ChatPart[]): ChatMessage {
    return typeof content === 'string' ? { role: 'user', text: content } : ChatMessage.userParts(content);
  },
  assistant(text: string): ChatMessage {
    return { role: 'assistant', text };
  },
  /** A user message made of text and image parts. */
  userParts(parts: ChatPart[]): ChatMessage {
    return { role: 'user', text: partsText(parts), parts };
  },
};

export function partsText(parts: ChatPart[]): string {
  return parts
    .filter((p): p is Extract<ChatPart, { type: 'text' }> => p.type === 'text')
    .map((p) => p.text)
    .join('\n');
}

export function messageParts(message: ChatMessage): ChatPart[] {
  return message.parts ?? [{ type: 'text', text: message.text }];
}

export function messageImageCount(message: ChatMessage): number {
  return message.parts?.filter((p) => p.type === 'image').length ?? 0;
}

export interface ChatRequest {
  system?: string;
  messages: ChatMessage[];
  /** Overrides the profile's defaults when set. */
  maxTokens?: number;
  temperature?: number;
  /**
   * Ask the provider for a reply that validates against this JSON schema (Anthropic
   * `output_config.format`, OpenAI `response_format`, Gemini `responseSchema`). The reply
   * text is then the JSON document. Providers that cannot enforce it still ask for JSON.
   */
  jsonSchema?: Record<string, unknown>;
}

/** Roughly four characters per token, plus ~1,600 per image; used before a request to check budgets. */
export function estimatedPromptTokens(request: ChatRequest): number {
  const chars = utf8Length(request.system ?? '') + request.messages.reduce((n, msg) => n + utf8Length(msg.text) + 8, 0);
  const images = request.messages.reduce((n, msg) => n + messageImageCount(msg), 0);
  return Math.floor((chars + 3) / 4) + images * 1600;
}

export function utf8Length(s: string): number {
  return new TextEncoder().encode(s).length;
}

export interface Usage {
  promptTokens: number;
  replyTokens: number;
}

export function usageTotal(u: Usage): number {
  return u.promptTokens + u.replyTokens;
}

export type StopReason = 'end' | 'maxTokens' | 'refusal' | 'other';

/** What a provider emits while a reply streams. */
export type ChatEvent = { type: 'text'; text: string } | { type: 'done'; usage: Usage; stop: StopReason };

export interface ChatReply {
  text: string;
  usage: Usage;
  stop: StopReason;
  /** The model id that answered, for the consumer's records (consumers still never choose it). */
  model: string;
  provider: ProviderKind;
}

export type TokenLibErrorCode =
  | 'noProvider'
  | 'missingKey'
  | 'budgetExhausted'
  | 'dailyCapReached'
  | 'http'
  | 'transport'
  | 'malformed'
  | 'cancelled';

export class TokenLibError extends Error {
  constructor(
    public code: TokenLibErrorCode,
    message: string,
    public details: { provider?: ProviderKind; status?: number; body?: string } = {},
  ) {
    super(message);
    this.name = 'TokenLibError';
  }

  static noProvider(): TokenLibError {
    return new TokenLibError('noProvider', 'no AI provider is configured');
  }
  static missingKey(provider: ProviderKind): TokenLibError {
    return new TokenLibError('missingKey', `no API key for ${provider}`, { provider });
  }
  static budgetExhausted(): TokenLibError {
    return new TokenLibError('budgetExhausted', "the session's token budget is spent");
  }
  static dailyCapReached(): TokenLibError {
    return new TokenLibError('dailyCapReached', 'the daily token cap is reached');
  }
  static http(status: number, body: string): TokenLibError {
    return new TokenLibError('http', `HTTP ${status}: ${body.slice(0, 200)}`, { status, body });
  }
  static transport(message: string): TokenLibError {
    return new TokenLibError('transport', `transport: ${message}`);
  }
  static malformed(message: string): TokenLibError {
    return new TokenLibError('malformed', `malformed reply: ${message}`);
  }
  static cancelled(): TokenLibError {
    return new TokenLibError('cancelled', 'cancelled');
  }
}
