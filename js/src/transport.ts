/**
 * HTTP with streaming bodies, small enough to fake in tests. Providers build an
 * HttpRequest and read the body line by line (server-sent events and
 * newline-delimited JSON both arrive that way).
 *
 * Port of TokenLib `Transport.swift` on `fetch` + ReadableStream.
 */
import { TokenLibError } from './chat';

export interface HttpRequest {
  url: string;
  method: string;
  headers: Record<string, string>;
  body?: string;
}

export function httpRequest(url: string, headers: Record<string, string>, body: unknown, method = 'POST'): HttpRequest {
  return { url, method, headers, body: JSON.stringify(body) };
}

export function bodyJSON(request: HttpRequest): Record<string, unknown> | undefined {
  try {
    return request.body ? (JSON.parse(request.body) as Record<string, unknown>) : undefined;
  } catch {
    return undefined;
  }
}

export interface StreamHandlers {
  /** The HTTP status, once. */
  onStatus?: (status: number) => void;
  /** Each line of a 2xx body as it arrives (without the newline). */
  onLine: (line: string) => void;
}

export interface HttpTransport {
  /** Sends the request and streams the body; rejects with `TokenLibError.http` (whole body) when the status is not 2xx. */
  stream(request: HttpRequest, handlers: StreamHandlers, signal?: AbortSignal): Promise<void>;
}

/** Splits a byte stream into lines, holding back an incomplete last line. */
export class LineSplitter {
  private pending = '';
  private decoder = new TextDecoder();

  append(chunk: Uint8Array): string[] {
    this.pending += this.decoder.decode(chunk, { stream: true });
    const lines: string[] = [];
    let nl: number;
    while ((nl = this.pending.indexOf('\n')) >= 0) {
      let line = this.pending.slice(0, nl);
      if (line.endsWith('\r')) line = line.slice(0, -1);
      lines.push(line);
      this.pending = this.pending.slice(nl + 1);
    }
    return lines;
  }

  flush(): string | undefined {
    this.pending += this.decoder.decode();
    if (!this.pending) return undefined;
    const last = this.pending;
    this.pending = '';
    return last;
  }
}

export interface SSEEvent {
  name?: string;
  data: string;
}

/** Server-sent events: `event:` and `data:` lines, blank line ends an event. */
export class SSEParser {
  private name: string | undefined;
  private data: string[] = [];

  /** Feeds one line; returns the event it completed, if any. */
  feed(line: string): SSEEvent | undefined {
    if (line === '') {
      if (this.data.length === 0) {
        this.name = undefined;
        return undefined;
      }
      const event: SSEEvent = { name: this.name, data: this.data.join('\n') };
      this.name = undefined;
      this.data = [];
      return event;
    }
    if (line.startsWith(':')) return undefined;
    const colon = line.indexOf(':');
    let field: string;
    let value: string;
    if (colon >= 0) {
      field = line.slice(0, colon);
      value = line.slice(colon + 1);
      if (value.startsWith(' ')) value = value.slice(1);
    } else {
      field = line;
      value = '';
    }
    if (field === 'event') this.name = value;
    else if (field === 'data') this.data.push(value);
    return undefined;
  }
}

/** `fetch` based transport; streams the body through a reader. */
export class FetchTransport implements HttpTransport {
  constructor(private fetchImpl: typeof fetch = fetch) {}

  async stream(request: HttpRequest, handlers: StreamHandlers, signal?: AbortSignal): Promise<void> {
    let response: Response;
    try {
      response = await this.fetchImpl(request.url, { method: request.method, headers: request.headers, body: request.body, signal });
    } catch (e) {
      if (signal?.aborted) throw TokenLibError.cancelled();
      throw TokenLibError.transport(e instanceof Error ? e.message : String(e));
    }
    handlers.onStatus?.(response.status);
    if (response.status < 200 || response.status >= 300) {
      throw TokenLibError.http(response.status, await response.text().catch(() => ''));
    }
    if (!response.body) return;
    const reader = response.body.getReader();
    const splitter = new LineSplitter();
    try {
      for (;;) {
        const { value, done } = await reader.read();
        if (done) break;
        if (value) for (const line of splitter.append(value)) handlers.onLine(line);
      }
    } catch (e) {
      if (signal?.aborted) throw TokenLibError.cancelled();
      throw TokenLibError.transport(e instanceof Error ? e.message : String(e));
    }
    const last = splitter.flush();
    if (last !== undefined) handlers.onLine(last);
  }
}
