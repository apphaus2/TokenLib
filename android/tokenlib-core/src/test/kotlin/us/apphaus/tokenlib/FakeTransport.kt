package us.apphaus.tokenlib

import java.net.URI

/** Serves canned bodies by URL host, line by line, the way a streaming server would. */
class FakeTransport : HttpTransport {
    val responses = HashMap<String, Pair<Int, String>>()
    val requests = ArrayList<HttpRequest>()
    var failWith: TokenLibException? = null

    override fun stream(request: HttpRequest, onStatus: (Int) -> Unit, onLine: (String) -> Unit, completion: (Result<Unit>) -> Unit): Cancellable {
        requests += request
        failWith?.let { completion(Result.failure(it)); return NoopCancellable }
        val host = runCatching { URI(request.url).host }.getOrNull() ?: ""
        val (status, body) = responses[host] ?: run { completion(Result.failure(TokenLibException.Http(404, "no canned response for ${request.url}"))); return NoopCancellable }
        onStatus(status)
        if (status in 200..299) {
            body.split("\n").let { lines -> lines.forEachIndexed { i, line -> if (i < lines.size - 1 || line.isNotEmpty()) onLine(line) } }
            completion(Result.success(Unit))
        } else completion(Result.failure(TokenLibException.Http(status, body)))
        return NoopCancellable
    }
}

object Canned {
    val anthropic = """
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

""".trimStart()

    val anthropicRefusal = """
event: message_start
data: {"type":"message_start","message":{"id":"msg_2","type":"message","role":"assistant","usage":{"input_tokens":30,"output_tokens":0}}}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"refusal","stop_sequence":null},"usage":{"output_tokens":0}}

event: message_stop
data: {"type":"message_stop"}
"""

    val openai = """
data: {"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":null}]}

data: {"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"Hello"},"finish_reason":null}]}

data: {"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":" there"},"finish_reason":"stop"}]}

data: {"id":"c1","object":"chat.completion.chunk","choices":[],"usage":{"prompt_tokens":12,"completion_tokens":2,"total_tokens":14}}

data: [DONE]

""".trimStart()

    val gemini = """
data: {"candidates":[{"content":{"parts":[{"text":"Woof"}],"role":"model"},"index":0}],"usageMetadata":{"promptTokenCount":7,"candidatesTokenCount":1}}

data: {"candidates":[{"content":{"parts":[{"text":"."}],"role":"model"},"finishReason":"STOP","index":0}],"usageMetadata":{"promptTokenCount":7,"candidatesTokenCount":2,"totalTokenCount":9}}
""".trimStart()
}
