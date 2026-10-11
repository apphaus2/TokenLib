import { LineSplitter, TokenLibError, type HttpRequest, type HttpTransport, type StreamHandlers } from '../src';

/** Serves canned bodies by URL host, line by line, the way a streaming server would. */
export class FakeTransport implements HttpTransport {
  responses: Record<string, { status: number; body: string }> = {};
  requests: HttpRequest[] = [];
  failWith?: TokenLibError;

  async stream(request: HttpRequest, handlers: StreamHandlers): Promise<void> {
    this.requests.push(request);
    if (this.failWith) throw this.failWith;
    const host = new URL(request.url).host;
    const response = this.responses[host];
    if (!response) throw TokenLibError.http(404, `no canned response for ${request.url}`);
    handlers.onStatus?.(response.status);
    if (response.status < 200 || response.status >= 300) throw TokenLibError.http(response.status, response.body);
    const splitter = new LineSplitter();
    for (const line of splitter.append(new TextEncoder().encode(response.body))) handlers.onLine(line);
    const last = splitter.flush();
    if (last !== undefined) handlers.onLine(last);
  }
}

export const Canned = {
  anthropic: `event: message_start
data: {"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","usage":{"input_tokens":25,"output_tokens":1}}}

event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Ask, "}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"and the bush shall sing."}}

event: content_block_stop
data: {"type":"content_block_stop","index":0}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":9}}

event: message_stop
data: {"type":"message_stop"}
`,
  anthropicRefusal: `event: message_start
data: {"type":"message_start","message":{"id":"msg_2","type":"message","role":"assistant","usage":{"input_tokens":30,"output_tokens":0}}}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"refusal","stop_sequence":null},"usage":{"output_tokens":0}}

event: message_stop
data: {"type":"message_stop"}
`,
  openai: `data: {"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":null}]}

data: {"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"Hello"},"finish_reason":null}]}

data: {"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":" there"},"finish_reason":"stop"}]}

data: {"id":"c1","object":"chat.completion.chunk","choices":[],"usage":{"prompt_tokens":12,"completion_tokens":2,"total_tokens":14}}

data: [DONE]
`,
  gemini: `data: {"candidates":[{"content":{"parts":[{"text":"Woof"}],"role":"model"},"index":0}],"usageMetadata":{"promptTokenCount":7,"candidatesTokenCount":1}}

data: {"candidates":[{"content":{"parts":[{"text":"."}],"role":"model"},"finishReason":"STOP","index":0}],"usageMetadata":{"promptTokenCount":7,"candidatesTokenCount":2,"totalTokenCount":9}}
`,
};
