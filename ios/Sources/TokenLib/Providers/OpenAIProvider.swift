//
//  OpenAIProvider.swift
//  TokenLib
//
//  OpenAI chat completions over HTTPS with server-sent events. The same code
//  serves every OpenAI-compatible vendor (DeepSeek, Kimi, Qwen, Grok, Mistral,
//  Cohere, OpenRouter) at its own endpoint, each with a small dialect: which
//  token parameter it takes, whether it takes a temperature, how it reports
//  usage, how it takes a JSON schema and how its reasoning is switched. It
//  also serves `.local`: an OpenAI-compatible server (Ollama, LM Studio, vLLM)
//  at a base URL from the settings, with no key.
//

import Foundation

public struct OpenAIProvider: Provider {
    public static let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!
    public static let deepseekEndpoint = URL(string: "https://api.deepseek.com/chat/completions")!
    public static let kimiEndpoint = URL(string: "https://api.moonshot.ai/v1/chat/completions")!
    public static let qwenEndpoint = URL(string: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1/chat/completions")!
    public static let grokEndpoint = URL(string: "https://api.x.ai/v1/chat/completions")!
    public static let mistralEndpoint = URL(string: "https://api.mistral.ai/v1/chat/completions")!
    public static let cohereEndpoint = URL(string: "https://api.cohere.com/compatibility/v1/chat/completions")!
    public static let openrouterEndpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!

    /// How a vendor takes a JSON schema.
    public enum Structured: Equatable {
        /// `response_format: json_schema`, enforced by the vendor.
        case schema
        /// `response_format: json_object` with the schema appended to the system prompt (these APIs also require the prompt to mention JSON).
        case object
        /// Cohere's `response_format: {type: json_object, schema}`.
        case objectWithSchema
    }

    /// The vendor's variations on the chat completions request.
    public struct Dialect {
        /// The hosted endpoint; `nil` for `.local`, whose base URL comes from the settings.
        public var endpoint: URL?
        /// `max_completion_tokens` where `max_tokens` is retired, `max_tokens` elsewhere.
        public var maxTokensKey: String
        /// Whether the vendor takes sampling parameters (OpenAI's current models reject them; Kimi fixes them per model; OpenRouter's depend on the model).
        public var temperature: Bool
        /// Whether to ask for usage in the stream with `stream_options.include_usage` (OpenRouter always sends it; Cohere does not document it).
        public var streamUsage: Bool
        public var structured: Structured
        /// Extra body fields that set the vendor's reasoning from the profile's effort (`low` or `high`) for a model id; empty when the vendor has no switch.
        public var reasoning: (_ effort: String, _ modelId: String) -> [String: Any]
    }

    public static func dialect(for kind: ProviderKind) -> Dialect {
        switch kind {
        case .openai:
            return Dialect(endpoint: endpoint, maxTokensKey: "max_completion_tokens", temperature: false, streamUsage: true, structured: .schema, reasoning: { _, _ in [:] })
        case .deepseek:
            // Thinking is on by default; low effort turns it off.
            return Dialect(endpoint: deepseekEndpoint, maxTokensKey: "max_tokens", temperature: true, streamUsage: true, structured: .object,
                           reasoning: { effort, _ in ["thinking": effort == "low" ? ["type": "disabled"] : ["type": "enabled", "reasoning_effort": effort]] })
        case .kimi:
            // K3 takes reasoning_effort; K2 has a thinking switch.
            return Dialect(endpoint: kimiEndpoint, maxTokensKey: "max_completion_tokens", temperature: false, streamUsage: true, structured: .schema,
                           reasoning: { effort, id in id.hasPrefix("kimi-k3") ? ["reasoning_effort": effort] : ["thinking": ["type": effort == "low" ? "disabled" : "enabled"]] })
        case .qwen:
            return Dialect(endpoint: qwenEndpoint, maxTokensKey: "max_tokens", temperature: true, streamUsage: true, structured: .object,
                           reasoning: { effort, _ in ["enable_thinking": effort != "low"] })
        case .grok:
            // Grok 4 reasons always; the effort scales it.
            return Dialect(endpoint: grokEndpoint, maxTokensKey: "max_tokens", temperature: true, streamUsage: true, structured: .schema,
                           reasoning: { effort, _ in ["reasoning_effort": effort] })
        case .mistral:
            return Dialect(endpoint: mistralEndpoint, maxTokensKey: "max_tokens", temperature: true, streamUsage: true, structured: .schema,
                           reasoning: { effort, _ in ["reasoning_effort": effort == "low" ? "none" : "high"] })
        case .cohere:
            // Only the reasoning models take the switch, and only `none` or `high`.
            return Dialect(endpoint: cohereEndpoint, maxTokensKey: "max_tokens", temperature: true, streamUsage: false, structured: .objectWithSchema,
                           reasoning: { effort, id in id.hasPrefix("command-a-plus") || id.hasPrefix("command-a-reasoning") ? ["reasoning_effort": effort == "low" ? "none" : "high"] : [:] })
        case .openrouter:
            return Dialect(endpoint: openrouterEndpoint, maxTokensKey: "max_tokens", temperature: false, streamUsage: false, structured: .schema,
                           reasoning: { effort, _ in ["reasoning": effort == "low" ? ["enabled": false] : ["effort": effort]] })
        default:
            return Dialect(endpoint: nil, maxTokensKey: "max_tokens", temperature: true, streamUsage: true, structured: .schema, reasoning: { _, _ in [:] })
        }
    }

    public let kind: ProviderKind
    public init(kind: ProviderKind = .openai) { self.kind = kind }

    /// The hosted endpoint for a kind; `nil` for `.local`.
    public static func endpoint(for kind: ProviderKind) -> URL? { dialect(for: kind).endpoint }

    public func request(_ chat: ChatRequest, call: ProviderCall) throws -> HttpRequest {
        let dialect = OpenAIProvider.dialect(for: kind)
        var system = chat.system ?? ""
        var body: [String: Any] = ["model": call.model.id, "stream": true]
        if dialect.streamUsage { body["stream_options"] = ["include_usage": true] }
        body[dialect.maxTokensKey] = chat.maxTokens ?? call.maxTokens
        if dialect.temperature, let t = chat.temperature ?? call.profile.temperature { body["temperature"] = t }
        if let effort = call.profile.effort {
            for (key, value) in dialect.reasoning(effort, call.model.id) { body[key] = value }
        }
        if let schema = chat.jsonSchema {
            switch dialect.structured {
            case .schema:
                body["response_format"] = ["type": "json_schema", "json_schema": ["name": "reply", "schema": schema]]
            case .objectWithSchema:
                body["response_format"] = ["type": "json_object", "schema": schema]
            case .object:
                body["response_format"] = ["type": "json_object"]
                let text = String(decoding: try JSON.data(schema), as: UTF8.self)
                system += (system.isEmpty ? "" : "\n\n") + "Reply with a single JSON object that matches this JSON schema: " + text
            }
        }
        var messages: [[String: Any]] = []
        if !system.isEmpty { messages.append(["role": "system", "content": system]) }
        messages += chat.messages.map { ["role": $0.role.rawValue, "content": OpenAIProvider.content($0)] }
        body["messages"] = messages
        var headers = ["Content-Type": "application/json", "Accept": "text/event-stream"]
        let url: URL
        if kind == .local {
            guard let base = call.baseURL else { throw TokenLibError.transport("no local server URL") }
            url = base.appendingPathComponent("chat/completions")
        } else {
            guard let key = call.key, !key.isEmpty else { throw TokenLibError.missingKey(kind) }
            guard let hosted = dialect.endpoint else { throw TokenLibError.transport("no endpoint for \(kind.rawValue)") }
            headers["Authorization"] = "Bearer \(key)"
            url = hosted
        }
        return HttpRequest(url: url, headers: headers, body: try JSON.data(body))
    }

    /// A plain string for text-only messages; text and `image_url` data-URI parts otherwise.
    static func content(_ message: ChatMessage) -> Any {
        guard message.parts != nil else { return message.text }
        return message.contentParts.map { part -> [String: Any] in
            switch part {
            case .text(let t): return ["type": "text", "text": t]
            case .image(let data, let mediaType): return ["type": "image_url", "image_url": ["url": "data:\(mediaType);base64,\(data)"]]
            }
        }
    }

    public func makeParser() -> ProviderStreamParser { Parser() }

    struct Parser: ProviderStreamParser {
        var sse = SSEParser()
        var usage = Usage()
        var stop: StopReason = .end
        var finished = false

        mutating func feed(_ line: String) -> [ChatEvent] {
            guard let event = sse.feed(line) else { return [] }
            if event.data == "[DONE]" {
                finished = true
                return [.done(usage: usage, stop: stop)]
            }
            guard let json = JSON.object(event.data) else { return [] }
            var out: [ChatEvent] = []
            if let u = json["usage"] as? [String: Any] {
                usage = Usage(promptTokens: u["prompt_tokens"] as? Int ?? usage.promptTokens, replyTokens: u["completion_tokens"] as? Int ?? usage.replyTokens)
            }
            for choice in json["choices"] as? [[String: Any]] ?? [] {
                if let text = (choice["delta"] as? [String: Any])?["content"] as? String, !text.isEmpty { out.append(.text(text)) }
                if let reason = choice["finish_reason"] as? String {
                    stop = reason == "length" ? .maxTokens : reason == "content_filter" ? .refusal : .end
                }
            }
            return out
        }

        mutating func finish() -> [ChatEvent] {
            // A body that ends without a blank line still holds its last event.
            var out = feed("")
            guard !finished else { return out }
            finished = true
            out.append(.done(usage: usage, stop: stop))
            return out
        }
    }
}
