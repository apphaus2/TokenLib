/**
 * The client SDK: what a library or a screen holds. It knows a broker and nothing
 * else; sessions carry a consumer name, a profile and an optional budget of their own.
 *
 * Port of TokenLib `TokenClient.swift`.
 */
import type { Profile } from './catalog';
import { estimatedPromptTokens, TokenLibError, usageTotal, type ChatReply, type ChatRequest } from './chat';
import type { TokenBroker } from './server';

export class TokenClient {
  constructor(readonly broker: TokenBroker) {}

  isReady(): Promise<boolean> {
    return this.broker.isReady();
  }

  /**
   * Opens a session for `consumer` (an actor id, a screen) on a profile. `budget` caps the
   * tokens the session may spend in total; the broker's daily cap applies on top.
   */
  session(consumer: string, profile: Profile, budget?: number): TokenSession {
    return new TokenSession(this, consumer, profile, budget);
  }
}

export class TokenSession {
  spent = 0;
  requests = 0;

  constructor(
    readonly client: TokenClient,
    readonly consumer: string,
    readonly profile: Profile,
    readonly budget?: number,
  ) {}

  get remaining(): number | undefined {
    return this.budget === undefined ? undefined : Math.max(0, this.budget - this.spent);
  }

  get isExhausted(): boolean {
    const r = this.remaining;
    return r !== undefined && r <= 0;
  }

  /** Streams a reply: `onText` gets deltas as they arrive; resolves with the whole reply and usage. */
  async stream(request: ChatRequest, onText?: (delta: string) => void, signal?: AbortSignal): Promise<ChatReply> {
    const remaining = this.remaining;
    if (remaining !== undefined && (remaining <= 0 || estimatedPromptTokens(request) >= remaining)) throw TokenLibError.budgetExhausted();
    const reply = await this.client.broker.stream(request, {
      profile: this.profile,
      consumer: this.consumer,
      onEvent: (e) => {
        if (e.type === 'text') onText?.(e.text);
      },
      signal,
    });
    this.spent += usageTotal(reply.usage);
    this.requests += 1;
    return reply;
  }

  /** A whole reply at once. */
  send(request: ChatRequest, signal?: AbortSignal): Promise<ChatReply> {
    return this.stream(request, undefined, signal);
  }
}
