import XCTest
@testable import TokenLib

final class ProviderTests: XCTestCase {
    let chat = ChatRequest(system: "You are a bush.", messages: [.user("hello"), .assistant("hi"), .user("sing")])

    func collect(_ provider: Provider, body: String) -> (text: String, done: (Usage, StopReason)?) {
        var parser = provider.makeParser()
        var text = ""
        var done: (Usage, StopReason)?
        var splitter = LineSplitter()
        var lines = splitter.append(Data(body.utf8))
        if let last = splitter.flush() { lines.append(last) }
        for line in lines { for e in parser.feed(line) { if case .text(let t) = e { text += t } else if case .done(let u, let s) = e { done = (u, s) } } }
        for e in parser.finish() { if case .text(let t) = e { text += t } else if case .done(let u, let s) = e { done = (u, s) } }
        return (text, done)
    }

    func testAnthropicRequestAndStream() throws {
        let provider = AnthropicProvider()
        let call = ProviderCall(model: Catalog.model(id: "claude-opus-5-5")!, key: "sk-test", profile: .character)
        let request = try provider.request(chat, call: call)
        XCTAssertEqual(request.url, AnthropicProvider.endpoint)
        XCTAssertEqual(request.headers["x-api-key"], "sk-test")
        XCTAssertEqual(request.headers["anthropic-version"], "2023-06-01")
        XCTAssertEqual(request.headers["anthropic-beta"], "server-side-fallback-2026-07-01")
        let body = request.bodyJSON!
        XCTAssertEqual(body["model"] as? String, "claude-opus-5-5")
        XCTAssertEqual(body["max_tokens"] as? Int, 400)
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["system"] as? String, "You are a bush.")
        XCTAssertEqual(body["fallbacks"] as? String, "default")
        XCTAssertEqual((body["output_config"] as? [String: Any])?["effort"] as? String, "low")
        XCTAssertNil(body["temperature"], "sampling parameters are not sent to the 5-generation models")
        let messages = body["messages"] as! [[String: Any]]
        XCTAssertEqual(messages.map { $0["role"] as! String }, ["user", "assistant", "user"])
        let result = collect(provider, body: Canned.anthropic)
        XCTAssertEqual(result.text, "Ask, and the bush shall sing.")
        XCTAssertEqual(result.done?.0, Usage(promptTokens: 25, replyTokens: 9))
        XCTAssertEqual(result.done?.1, .end)
        // Haiku keeps temperature and gets no effort or fallbacks
        let haikuRequest = try provider.request(chat, call: ProviderCall(model: Catalog.model(id: "claude-haiku-4-5")!, key: "k", profile: .character))
        let haiku = haikuRequest.bodyJSON!
        XCTAssertEqual(haiku["temperature"] as? Double, 0.9)
        XCTAssertNil(haiku["output_config"])
        XCTAssertNil(haiku["fallbacks"])
        XCTAssertNil(haikuRequest.headers["anthropic-beta"])
        // Sonnet 5.5 gets fallbacks too
        let sonnet = try provider.request(chat, call: ProviderCall(model: Catalog.model(id: "claude-sonnet-5-5")!, key: "k", profile: .assistant))
        XCTAssertEqual(sonnet.headers["anthropic-beta"], "server-side-fallback-2026-07-01")
        XCTAssertEqual(sonnet.bodyJSON?["fallbacks"] as? String, "default")
        XCTAssertThrowsError(try provider.request(chat, call: ProviderCall(model: call.model, key: nil, profile: .fast)))
    }

    func testAnthropicImagePartsAndJSONSchema() throws {
        let provider = AnthropicProvider()
        let schema: [String: Any] = ["type": "object", "properties": ["ok": ["type": "boolean"]], "required": ["ok"], "additionalProperties": false]
        let request = try provider.request(
            ChatRequest(messages: [.user(parts: [.text("Photo 1"), .image(data: "AAAA", mediaType: "image/jpeg"), .text("Compare.")])], maxTokens: 8000, jsonSchema: schema),
            call: ProviderCall(model: Catalog.model(id: "claude-opus-5-5")!, key: "k", profile: .vision))
        let body = request.bodyJSON!
        XCTAssertEqual(body["max_tokens"] as? Int, 8000)
        let content = (body["messages"] as! [[String: Any]])[0]["content"] as! [[String: Any]]
        XCTAssertEqual(content.map { $0["type"] as! String }, ["text", "image", "text"])
        let source = content[1]["source"] as! [String: Any]
        XCTAssertEqual(source["type"] as? String, "base64")
        XCTAssertEqual(source["media_type"] as? String, "image/jpeg")
        XCTAssertEqual(source["data"] as? String, "AAAA")
        let outputConfig = body["output_config"] as! [String: Any]
        XCTAssertEqual(outputConfig["effort"] as? String, "high")
        let format = outputConfig["format"] as! [String: Any]
        XCTAssertEqual(format["type"] as? String, "json_schema")
        XCTAssertEqual((format["schema"] as? [String: Any])?["required"] as? [String], ["ok"])
        // adjacent user turns with parts merge into one block list
        let merged = AnthropicProvider.messages([.user("first"), .user(parts: [.image(data: "BBBB", mediaType: "image/png")])])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual((merged[0]["content"] as! [[String: Any]]).map { $0["type"] as! String }, ["text", "image"])
    }

    func testAnthropicReportsRefusalStop() {
        let result = collect(AnthropicProvider(), body: Canned.anthropicRefusal)
        XCTAssertEqual(result.done?.1, .refusal)
        XCTAssertEqual(result.text, "")
    }

    func testAnthropicMergesAdjacentRoles() {
        let merged = AnthropicProvider.messages([.assistant("a"), .user("b"), .user("c")])
        XCTAssertEqual(merged.map { $0["role"] as! String }, ["user", "assistant", "user"])
        XCTAssertEqual(merged[2]["content"] as? String, "b\nc")
    }

    func testOpenAIRequestAndStream() throws {
        let provider = OpenAIProvider()
        let request = try provider.request(chat, call: ProviderCall(model: Catalog.model(id: "gpt-5-mini")!, key: "sk-o", profile: .fast))
        XCTAssertEqual(request.headers["Authorization"], "Bearer sk-o")
        let body = request.bodyJSON!
        XCTAssertEqual(body["max_completion_tokens"] as? Int, 1024)
        XCTAssertEqual((body["stream_options"] as? [String: Any])?["include_usage"] as? Bool, true)
        let messages = body["messages"] as! [[String: Any]]
        XCTAssertEqual(messages.first?["role"] as? String, "system")
        XCTAssertEqual(messages.count, 4)
        let result = collect(provider, body: Canned.openai)
        XCTAssertEqual(result.text, "Hello there")
        XCTAssertEqual(result.done?.0, Usage(promptTokens: 12, replyTokens: 2))
    }

    func testOpenAIImagePartsAndJSONSchema() throws {
        let provider = OpenAIProvider()
        let request = try provider.request(
            ChatRequest(messages: [.user(parts: [.text("What is this?"), .image(data: "AAAA", mediaType: "image/png")])], jsonSchema: ["type": "object"]),
            call: ProviderCall(model: Catalog.model(id: "gpt-5")!, key: "k", profile: .vision))
        let body = request.bodyJSON!
        let content = (body["messages"] as! [[String: Any]])[0]["content"] as! [[String: Any]]
        XCTAssertEqual(content.map { $0["type"] as! String }, ["text", "image_url"])
        XCTAssertEqual((content[1]["image_url"] as? [String: Any])?["url"] as? String, "data:image/png;base64,AAAA")
        let format = body["response_format"] as! [String: Any]
        XCTAssertEqual(format["type"] as? String, "json_schema")
        XCTAssertEqual((format["json_schema"] as? [String: Any])?["name"] as? String, "reply")
        XCTAssertEqual(((format["json_schema"] as? [String: Any])?["schema"] as? [String: Any])?["type"] as? String, "object")
        // text-only messages stay plain strings
        let plain = try provider.request(chat, call: ProviderCall(model: Catalog.model(id: "gpt-5")!, key: "k", profile: .fast)).bodyJSON!
        XCTAssertEqual((plain["messages"] as! [[String: Any]])[1]["content"] as? String, "hello")
        XCTAssertNil(plain["response_format"])
    }

    func testDeepSeekKimiQwenAreOpenAICompatible() throws {
        // DeepSeek: its own endpoint, max_tokens, temperature, thinking off for low effort, JSON mode with the schema in the prompt
        let deepseek = try OpenAIProvider(kind: .deepseek).request(ChatRequest(system: "bush", messages: [.user("sing")], jsonSchema: ["type": "object"]),
                                                                  call: ProviderCall(model: Catalog.model(id: "deepseek-flash")!, key: "ds", profile: .character))
        XCTAssertEqual(deepseek.url, OpenAIProvider.deepseekEndpoint)
        XCTAssertEqual(deepseek.headers["Authorization"], "Bearer ds")
        var body = deepseek.bodyJSON!
        XCTAssertEqual(body["model"] as? String, "deepseek-flash")
        XCTAssertEqual(body["max_tokens"] as? Int, 400)
        XCTAssertNil(body["max_completion_tokens"])
        XCTAssertEqual(body["temperature"] as? Double, 0.9)
        XCTAssertEqual((body["thinking"] as? [String: Any])?["type"] as? String, "disabled")
        XCTAssertEqual((body["response_format"] as? [String: Any])?["type"] as? String, "json_object")
        var messages = body["messages"] as! [[String: Any]]
        XCTAssertEqual(messages[0]["role"] as? String, "system")
        XCTAssertTrue((messages[0]["content"] as! String).hasPrefix("bush\n\nReply with a single JSON object that matches this JSON schema: {\"type\":\"object\"}"))
        // high effort turns thinking on
        body = try OpenAIProvider(kind: .deepseek).request(chat, call: ProviderCall(model: Catalog.model(id: "deepseek-v4-pro")!, key: "ds", profile: .assistant)).bodyJSON!
        XCTAssertEqual((body["thinking"] as? [String: Any])?["type"] as? String, "enabled")
        XCTAssertEqual((body["thinking"] as? [String: Any])?["reasoning_effort"] as? String, "high")
        XCTAssertNil(body["temperature"], "the assistant profile has no temperature")
        XCTAssertNil(body["response_format"])
        XCTAssertEqual((body["messages"] as! [[String: Any]]).count, 4)

        // Kimi: max_completion_tokens, no temperature, reasoning_effort on K3 and a thinking switch on K2, json_schema
        let kimi = try OpenAIProvider(kind: .kimi).request(ChatRequest(messages: [.user("sing")], jsonSchema: ["type": "object"]),
                                                          call: ProviderCall(model: Catalog.model(id: "kimi-k3")!, key: "mk", profile: .assistant))
        XCTAssertEqual(kimi.url, OpenAIProvider.kimiEndpoint)
        XCTAssertEqual(kimi.headers["Authorization"], "Bearer mk")
        body = kimi.bodyJSON!
        XCTAssertEqual(body["max_completion_tokens"] as? Int, 4096)
        XCTAssertNil(body["max_tokens"])
        XCTAssertNil(body["temperature"])
        XCTAssertEqual(body["reasoning_effort"] as? String, "high")
        XCTAssertNil(body["thinking"])
        XCTAssertEqual((body["response_format"] as? [String: Any])?["type"] as? String, "json_schema")
        messages = body["messages"] as! [[String: Any]]
        XCTAssertEqual(messages.count, 1, "no system prompt was added")
        body = try OpenAIProvider(kind: .kimi).request(chat, call: ProviderCall(model: Catalog.model(id: "kimi-k2.6")!, key: "mk", profile: .character)).bodyJSON!
        XCTAssertEqual((body["thinking"] as? [String: Any])?["type"] as? String, "disabled")
        XCTAssertNil(body["reasoning_effort"])
        XCTAssertNil(body["temperature"], "Kimi fixes the temperature per model")

        // Qwen: the international compatible-mode endpoint, max_tokens, temperature, enable_thinking, JSON mode
        let qwen = try OpenAIProvider(kind: .qwen).request(ChatRequest(messages: [.user("sing")], jsonSchema: ["type": "object"]),
                                                          call: ProviderCall(model: Catalog.model(id: "qwen3.8-flash")!, key: "qw", profile: .fast))
        XCTAssertEqual(qwen.url, OpenAIProvider.qwenEndpoint)
        XCTAssertEqual(qwen.headers["Authorization"], "Bearer qw")
        body = qwen.bodyJSON!
        XCTAssertEqual(body["max_tokens"] as? Int, 1024)
        XCTAssertEqual(body["temperature"] as? Double, 0.2)
        XCTAssertEqual(body["enable_thinking"] as? Bool, false)
        XCTAssertEqual((body["response_format"] as? [String: Any])?["type"] as? String, "json_object")
        XCTAssertEqual((body["messages"] as! [[String: Any]])[0]["role"] as? String, "system", "the schema needs a system prompt")
        body = try OpenAIProvider(kind: .qwen).request(chat, call: ProviderCall(model: Catalog.model(id: "qwen3.8-max")!, key: "qw", profile: .vision)).bodyJSON!
        XCTAssertEqual(body["enable_thinking"] as? Bool, true)

        // each needs its own key, and the stream parser is the OpenAI one
        for kind in [ProviderKind.deepseek, .kimi, .qwen] {
            XCTAssertThrowsError(try OpenAIProvider(kind: kind).request(chat, call: ProviderCall(model: Catalog.model(for: .fast, provider: kind), key: nil, profile: .fast))) { error in
                XCTAssertEqual(error as? TokenLibError, .missingKey(kind))
            }
            XCTAssertEqual(Providers.provider(for: kind).kind, kind)
            XCTAssertEqual(collect(Providers.provider(for: kind), body: Canned.openai).text, "Hello there")
        }
    }

    func testGrokMistralCohereOpenRouterAreOpenAICompatible() throws {
        let schema: [String: Any] = ["type": "object"]
        let withSchema = ChatRequest(system: "bush", messages: [.user("sing")], jsonSchema: schema)

        // Grok: api.x.ai, max_tokens, temperature, reasoning_effort scaled by the profile, json_schema, usage asked for in the stream
        let grok = try OpenAIProvider(kind: .grok).request(withSchema, call: ProviderCall(model: Catalog.model(id: "grok-4.7")!, key: "xk", profile: .character))
        XCTAssertEqual(grok.url, OpenAIProvider.grokEndpoint)
        XCTAssertEqual(grok.headers["Authorization"], "Bearer xk")
        var body = grok.bodyJSON!
        XCTAssertEqual(body["max_tokens"] as? Int, 400)
        XCTAssertEqual(body["temperature"] as? Double, 0.9)
        XCTAssertEqual(body["reasoning_effort"] as? String, "low")
        XCTAssertEqual((body["response_format"] as? [String: Any])?["type"] as? String, "json_schema")
        XCTAssertEqual((body["stream_options"] as? [String: Any])?["include_usage"] as? Bool, true)
        XCTAssertEqual((body["messages"] as! [[String: Any]])[0]["content"] as? String, "bush", "the schema is enforced, not prompted")
        body = try OpenAIProvider(kind: .grok).request(chat, call: ProviderCall(model: Catalog.model(id: "grok-4.3")!, key: "xk", profile: .assistant)).bodyJSON!
        XCTAssertEqual(body["reasoning_effort"] as? String, "high")

        // Mistral: api.mistral.ai, reasoning_effort none/high, json_schema
        let mistral = try OpenAIProvider(kind: .mistral).request(withSchema, call: ProviderCall(model: Catalog.model(id: "mistral-small-latest")!, key: "mk", profile: .fast))
        XCTAssertEqual(mistral.url, OpenAIProvider.mistralEndpoint)
        body = mistral.bodyJSON!
        XCTAssertEqual(body["model"] as? String, "mistral-small-latest")
        XCTAssertEqual(body["max_tokens"] as? Int, 1024)
        XCTAssertEqual(body["temperature"] as? Double, 0.2)
        XCTAssertEqual(body["reasoning_effort"] as? String, "none")
        XCTAssertEqual((body["response_format"] as? [String: Any])?["type"] as? String, "json_schema")
        body = try OpenAIProvider(kind: .mistral).request(chat, call: ProviderCall(model: Catalog.model(id: "mistral-large-latest")!, key: "mk", profile: .vision)).bodyJSON!
        XCTAssertEqual(body["reasoning_effort"] as? String, "high")

        // Cohere: the compatibility endpoint, the schema inside json_object, reasoning only on the reasoning models, no stream_options
        let cohere = try OpenAIProvider(kind: .cohere).request(withSchema, call: ProviderCall(model: Catalog.model(id: "command-a-plus-05-2026")!, key: "ck", profile: .assistant))
        XCTAssertEqual(cohere.url, OpenAIProvider.cohereEndpoint)
        body = cohere.bodyJSON!
        XCTAssertEqual(body["max_tokens"] as? Int, 4096)
        XCTAssertNil(body["temperature"], "the assistant profile has none")
        XCTAssertEqual(body["reasoning_effort"] as? String, "high")
        let format = body["response_format"] as! [String: Any]
        XCTAssertEqual(format["type"] as? String, "json_object")
        XCTAssertEqual((format["schema"] as? [String: Any])?["type"] as? String, "object")
        XCTAssertNil(body["stream_options"])
        XCTAssertEqual((body["messages"] as! [[String: Any]])[0]["content"] as? String, "bush", "the schema travels in response_format, not the prompt")
        body = try OpenAIProvider(kind: .cohere).request(chat, call: ProviderCall(model: Catalog.model(id: "command-r7b-12-2024")!, key: "ck", profile: .character)).bodyJSON!
        XCTAssertNil(body["reasoning_effort"], "R7B has no reasoning switch")
        XCTAssertEqual(body["temperature"] as? Double, 0.9)

        // OpenRouter: one key for many vendors, no temperature, the unified reasoning object, usage comes unasked
        let openrouter = try OpenAIProvider(kind: .openrouter).request(withSchema, call: ProviderCall(model: Catalog.model(id: "anthropic/claude-opus-5.5")!, key: "ok", profile: .character))
        XCTAssertEqual(openrouter.url, OpenAIProvider.openrouterEndpoint)
        body = openrouter.bodyJSON!
        XCTAssertEqual(body["model"] as? String, "anthropic/claude-opus-5.5")
        XCTAssertEqual(body["max_tokens"] as? Int, 400)
        XCTAssertNil(body["temperature"])
        XCTAssertEqual((body["reasoning"] as? [String: Any])?["enabled"] as? Bool, false)
        XCTAssertNil(body["stream_options"])
        XCTAssertEqual((body["response_format"] as? [String: Any])?["type"] as? String, "json_schema")
        body = try OpenAIProvider(kind: .openrouter).request(chat, call: ProviderCall(model: Catalog.model(id: "anthropic/claude-haiku-4.5")!, key: "ok", profile: .assistant)).bodyJSON!
        XCTAssertEqual((body["reasoning"] as? [String: Any])?["effort"] as? String, "high")

        for kind in [ProviderKind.grok, .mistral, .cohere, .openrouter] {
            XCTAssertThrowsError(try OpenAIProvider(kind: kind).request(chat, call: ProviderCall(model: Catalog.model(for: .fast, provider: kind), key: nil, profile: .fast))) { error in
                XCTAssertEqual(error as? TokenLibError, .missingKey(kind))
            }
            XCTAssertEqual(Providers.provider(for: kind).kind, kind)
            XCTAssertEqual(collect(Providers.provider(for: kind), body: Canned.openai).text, "Hello there")
        }
    }

    func testLocalServerUsesBaseURLAndNoKey() throws {
        let provider = OpenAIProvider(kind: .local)
        var model = Catalog.local[0]
        model.id = "llama3"
        let request = try provider.request(chat, call: ProviderCall(model: model, key: nil, baseURL: URL(string: "http://192.168.1.20:11434/v1"), profile: .character))
        XCTAssertEqual(request.url.absoluteString, "http://192.168.1.20:11434/v1/chat/completions")
        XCTAssertNil(request.headers["Authorization"])
        XCTAssertEqual(request.bodyJSON?["model"] as? String, "llama3")
        XCTAssertEqual(request.bodyJSON?["temperature"] as? Double, 0.9)
        XCTAssertThrowsError(try provider.request(chat, call: ProviderCall(model: model, key: nil, baseURL: nil, profile: .character)))
    }

    func testGeminiRequestAndStream() throws {
        let provider = GeminiProvider()
        let request = try provider.request(chat, call: ProviderCall(model: Catalog.model(id: "gemini-2.5-flash")!, key: "g", profile: .assistant))
        XCTAssertTrue(request.url.absoluteString.hasSuffix("gemini-2.5-flash:streamGenerateContent?alt=sse"))
        XCTAssertEqual(request.headers["x-goog-api-key"], "g")
        let body = request.bodyJSON!
        XCTAssertEqual((body["contents"] as! [[String: Any]]).map { $0["role"] as! String }, ["user", "model", "user"])
        XCTAssertNotNil(body["systemInstruction"])
        let result = collect(provider, body: Canned.gemini)
        XCTAssertEqual(result.text, "Woof.")
        XCTAssertEqual(result.done?.0, Usage(promptTokens: 7, replyTokens: 2))
        XCTAssertEqual(result.done?.1, .end)
    }

    func testGeminiImagePartsAndJSONSchema() throws {
        let provider = GeminiProvider()
        let request = try provider.request(
            ChatRequest(messages: [.user(parts: [.text("What is this?"), .image(data: "AAAA", mediaType: "image/webp")])], jsonSchema: ["type": "object"]),
            call: ProviderCall(model: Catalog.model(id: "gemini-2.5-pro")!, key: "g", profile: .vision))
        let body = request.bodyJSON!
        let parts = (body["contents"] as! [[String: Any]])[0]["parts"] as! [[String: Any]]
        XCTAssertEqual(parts[0]["text"] as? String, "What is this?")
        let inline = parts[1]["inlineData"] as! [String: Any]
        XCTAssertEqual(inline["mimeType"] as? String, "image/webp")
        XCTAssertEqual(inline["data"] as? String, "AAAA")
        XCTAssertEqual((body["generationConfig"] as? [String: Any])?["responseMimeType"] as? String, "application/json")
        let plain = try provider.request(chat, call: ProviderCall(model: Catalog.model(id: "gemini-2.5-pro")!, key: "g", profile: .fast)).bodyJSON!
        XCTAssertNil((plain["generationConfig"] as? [String: Any])?["responseMimeType"])
    }
}
