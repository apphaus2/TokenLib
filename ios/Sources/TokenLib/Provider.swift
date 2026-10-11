//
//  Provider.swift
//  TokenLib
//
//  A provider turns a ChatRequest into one HTTP request for its API and
//  turns the streamed body back into ChatEvents. Implementations are plain
//  HTTP: no vendor SDKs, so Swift and Kotlin behave the same.
//

import Foundation

public struct ProviderCall: Equatable {
    public var model: ModelInfo
    public var key: String?
    /// For `.local`: the server's base URL, e.g. `http://192.168.1.20:11434/v1`.
    public var baseURL: URL?
    public var profile: Profile
    public init(model: ModelInfo, key: String?, baseURL: URL? = nil, profile: Profile) { self.model = model; self.key = key; self.baseURL = baseURL; self.profile = profile }

    var maxTokens: Int { profile.maxTokens }
}

public protocol Provider {
    var kind: ProviderKind { get }
    /// Builds the HTTP request for a streaming reply.
    func request(_ chat: ChatRequest, call: ProviderCall) throws -> HttpRequest
    /// A fresh parser for the streamed body of one request.
    func makeParser() -> ProviderStreamParser
}

/// Consumes body lines and emits chat events. `finish` is called at the end of the body.
public protocol ProviderStreamParser {
    mutating func feed(_ line: String) -> [ChatEvent]
    mutating func finish() -> [ChatEvent]
}

public enum Providers {
    public static func provider(for kind: ProviderKind) -> Provider {
        switch kind {
        case .anthropic: return AnthropicProvider()
        case .gemini: return GeminiProvider()
        default: return OpenAIProvider(kind: kind)
        }
    }
}

// MARK: - Small JSON helpers shared by the providers

enum JSON {
    static func data(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
    static func object(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
