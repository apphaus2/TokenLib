/**
 * A provider turns a ChatRequest into one HTTP request for its API and turns the
 * streamed body back into ChatEvents. Implementations are plain HTTP: no vendor
 * SDKs, so this port behaves like the Swift and Kotlin originals.
 *
 * Port of TokenLib `Provider.swift`.
 */
import type { ModelInfo, Profile, ProviderKind } from './catalog';
import { ProfileInfo } from './catalog';
import type { ChatEvent, ChatRequest } from './chat';
import type { HttpRequest } from './transport';

export interface ProviderCall {
  model: ModelInfo;
  key?: string;
  /** For `local`: the server's base URL, e.g. `http://192.168.1.20:11434/v1`. */
  baseURL?: string;
  profile: Profile;
}

export function callMaxTokens(call: ProviderCall, chat: ChatRequest): number {
  return chat.maxTokens ?? ProfileInfo.maxTokens(call.profile);
}

export function callTemperature(call: ProviderCall, chat: ChatRequest): number | undefined {
  return chat.temperature ?? ProfileInfo.temperature(call.profile);
}

/** Consumes body lines and emits chat events. `finish` is called at the end of the body. */
export interface ProviderStreamParser {
  feed(line: string): ChatEvent[];
  finish(): ChatEvent[];
}

export interface Provider {
  readonly kind: ProviderKind;
  /** Builds the HTTP request for a streaming reply. */
  request(chat: ChatRequest, call: ProviderCall): HttpRequest;
  /** A fresh parser for the streamed body of one request. */
  makeParser(): ProviderStreamParser;
}

/**
 * A provider that answers in-process instead of over HTTP (Apple's on-device model on Apple platforms), registered
 * on the server per platform (`TokenServer.nativeProviders`). It streams `ChatEvent`s itself; the server still does
 * the accounting. This port knows the kind (`apple`) and this seam only; no JavaScript host fills it.
 */
export interface NativeProvider {
  readonly kind: ProviderKind;
  /** Whether the model can answer right now. */
  readonly isAvailable: boolean;
  /** Why not, in words for a settings screen; `undefined` when available. */
  readonly unavailableReason?: string;
  /** Streams the reply as `text` events and ends with `done`; rejects with a `TokenLibError`. */
  stream(chat: ChatRequest, call: ProviderCall, onEvent: (event: ChatEvent) => void, signal?: AbortSignal): Promise<void>;
}

export function parseJSONObject(text: string): Record<string, unknown> | undefined {
  try {
    const v = JSON.parse(text) as unknown;
    return v && typeof v === 'object' && !Array.isArray(v) ? (v as Record<string, unknown>) : undefined;
  } catch {
    return undefined;
  }
}

export const num = (v: unknown): number | undefined => (typeof v === 'number' ? v : undefined);
export const str = (v: unknown): string | undefined => (typeof v === 'string' ? v : undefined);
export const obj = (v: unknown): Record<string, unknown> | undefined =>
  v && typeof v === 'object' && !Array.isArray(v) ? (v as Record<string, unknown>) : undefined;
export const arr = (v: unknown): unknown[] => (Array.isArray(v) ? v : []);
