//
//  GeminiProvider.swift
//  TokenLib
//
//  Google Gemini generateContent over HTTPS with server-sent events.
//

import Foundation

public struct GeminiProvider: Provider {
    public static let base = "https://generativelanguage.googleapis.com/v1beta/models/"

    public var kind: ProviderKind { .gemini }
    public init() {}

    public func request(_ chat: ChatRequest, call: ProviderCall) throws -> HttpRequest {
        guard let key = call.key, !key.isEmpty else { throw TokenLibError.missingKey(.gemini) }
        var body: [String: Any] = [
            "contents": chat.messages.map { ["role": $0.role == .user ? "user" : "model", "parts": GeminiProvider.parts($0)] },
        ]
        if let system = chat.system, !system.isEmpty { body["systemInstruction"] = ["parts": [["text": system]]] }
        var config: [String: Any] = ["maxOutputTokens": chat.maxTokens ?? call.maxTokens]
        if let t = chat.temperature ?? call.profile.temperature { config["temperature"] = t }
        if chat.jsonSchema != nil { config["responseMimeType"] = "application/json" }
        body["generationConfig"] = config
        let url = URL(string: GeminiProvider.base + call.model.id + ":streamGenerateContent?alt=sse")!
        return HttpRequest(url: url, headers: ["Content-Type": "application/json", "x-goog-api-key": key, "Accept": "text/event-stream"], body: try JSON.data(body))
    }

    /// Text parts and `inlineData` image parts.
    static func parts(_ message: ChatMessage) -> [[String: Any]] {
        message.contentParts.map { part in
            switch part {
            case .text(let t): return ["text": t]
            case .image(let data, let mediaType): return ["inlineData": ["mimeType": mediaType, "data": data]]
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
            guard let event = sse.feed(line), let json = JSON.object(event.data) else { return [] }
            var out: [ChatEvent] = []
            if let u = json["usageMetadata"] as? [String: Any] {
                usage = Usage(promptTokens: u["promptTokenCount"] as? Int ?? usage.promptTokens, replyTokens: u["candidatesTokenCount"] as? Int ?? usage.replyTokens)
            }
            for candidate in json["candidates"] as? [[String: Any]] ?? [] {
                for part in ((candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? [] {
                    if let text = part["text"] as? String, !text.isEmpty { out.append(.text(text)) }
                }
                if let reason = candidate["finishReason"] as? String {
                    stop = reason == "MAX_TOKENS" ? .maxTokens : reason == "SAFETY" ? .refusal : .end
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
