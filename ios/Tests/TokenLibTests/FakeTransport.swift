import Foundation
@testable import TokenLib

/// Serves canned bodies by URL host, line by line, the way a streaming server would.
final class FakeTransport: HttpTransport {
    var responses: [String: (status: Int, body: String)] = [:]
    var requests: [HttpRequest] = []
    var failWith: TokenLibError?

    func stream(_ request: HttpRequest, onStatus: @escaping (Int) -> Void, onLine: @escaping (String) -> Void, completion: @escaping (Result<Void, TokenLibError>) -> Void) -> Cancellable {
        requests.append(request)
        if let error = failWith { completion(.failure(error)); return NoopCancellable() }
        guard let response = responses[request.url.host ?? ""] else { completion(.failure(.http(status: 404, body: "no canned response for \(request.url)"))); return NoopCancellable() }
        onStatus(response.status)
        if (200..<300).contains(response.status) {
            var splitter = LineSplitter()
            for line in splitter.append(Data(response.body.utf8)) { onLine(line) }
            if let last = splitter.flush() { onLine(last) }
            completion(.success(()))
        } else {
            completion(.failure(.http(status: response.status, body: response.body)))
        }
        return NoopCancellable()
    }
}

enum Canned {
    static let anthropic = """
    event: message_start
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

    """

    static let anthropicRefusal = """
    event: message_start
    data: {"type":"message_start","message":{"id":"msg_2","type":"message","role":"assistant","usage":{"input_tokens":30,"output_tokens":0}}}

    event: message_delta
    data: {"type":"message_delta","delta":{"stop_reason":"refusal","stop_sequence":null},"usage":{"output_tokens":0}}

    event: message_stop
    data: {"type":"message_stop"}

    """

    static let openai = """
    data: {"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":null}]}

    data: {"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"Hello"},"finish_reason":null}]}

    data: {"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":" there"},"finish_reason":"stop"}]}

    data: {"id":"c1","object":"chat.completion.chunk","choices":[],"usage":{"prompt_tokens":12,"completion_tokens":2,"total_tokens":14}}

    data: [DONE]

    """

    static let gemini = """
    data: {"candidates":[{"content":{"parts":[{"text":"Woof"}],"role":"model"},"index":0}],"usageMetadata":{"promptTokenCount":7,"candidatesTokenCount":1}}

    data: {"candidates":[{"content":{"parts":[{"text":"."}],"role":"model"},"finishReason":"STOP","index":0}],"usageMetadata":{"promptTokenCount":7,"candidatesTokenCount":2,"totalTokenCount":9}}

    """
}
