import { describe, expect, it } from 'vitest';
import { FetchTransport, LineSplitter, SSEParser, TokenLibError } from '../src';

describe('LineSplitter / SSEParser', () => {
  it('splits lines across chunks and flushes the tail', () => {
    const s = new LineSplitter();
    const enc = (t: string) => new TextEncoder().encode(t);
    expect(s.append(enc('a\r\nb'))).toEqual(['a']);
    expect(s.append(enc('c\n\nd'))).toEqual(['bc', '']);
    expect(s.flush()).toBe('d');
    expect(s.flush()).toBeUndefined();
  });

  it('parses events and ignores comments', () => {
    const p = new SSEParser();
    expect(p.feed(': keep-alive')).toBeUndefined();
    expect(p.feed('event: ping')).toBeUndefined();
    expect(p.feed('data: {"a":1}')).toBeUndefined();
    expect(p.feed('data: more')).toBeUndefined();
    expect(p.feed('')).toEqual({ name: 'ping', data: '{"a":1}\nmore' });
    expect(p.feed(''), 'blank lines without data produce nothing').toBeUndefined();
  });
});

describe('FetchTransport', () => {
  it('streams a 2xx body line by line and raises http errors with the body', async () => {
    const fakeFetch: typeof fetch = async (_url, init) => {
      if (init?.method === 'POST' && init.body === '"fail"') return new Response('nope', { status: 401 });
      return new Response(new ReadableStream({
        start(c) {
          c.enqueue(new TextEncoder().encode('data: 1\n\nda'));
          c.enqueue(new TextEncoder().encode('ta: 2'));
          c.close();
        },
      }), { status: 200 });
    };
    const t = new FetchTransport(fakeFetch);
    const lines: string[] = [];
    let status = 0;
    await t.stream({ url: 'https://x/', method: 'POST', headers: {}, body: '{}' }, { onLine: (l) => lines.push(l), onStatus: (s) => (status = s) });
    expect(status).toBe(200);
    expect(lines).toEqual(['data: 1', '', 'data: 2']);
    await expect(t.stream({ url: 'https://x/', method: 'POST', headers: {}, body: '"fail"' }, { onLine: () => {} })).rejects.toMatchObject({ code: 'http', details: { status: 401, body: 'nope' } } satisfies Partial<TokenLibError>);
  });
});
