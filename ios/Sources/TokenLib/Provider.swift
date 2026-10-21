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

/// A provider that answers in-process instead of over HTTP: Apple's on-device model, registered on the
/// server by the platform bootstrap (`TokenServer.nativeProviders`). It streams `ChatEvent`s itself; the
/// server still does the accounting. The core knows the kind (`ProviderKind.apple`) and this seam only.
public protocol NativeProvider: AnyObject {
    var kind: ProviderKind { get }
    /// Whether the model can answer right now (the device is eligible, the feature is on, the model is downloaded).
    var isAvailable: Bool { get }
    /// Why not, in words for a settings screen; `nil` when available.
    var unavailableReason: String? { get }
    /// Streams the reply as `.text` deltas and ends with `.done`; `completion` then reports success or a `TokenLibError`.
    func stream(_ chat: ChatRequest, call: ProviderCall, onEvent: @escaping (ChatEvent) -> Void, completion: @escaping (Result<Void, TokenLibError>) -> Void) -> Cancellable
}

public enum Providers {
    /// The HTTP provider for a kind; native kinds have none (`NativeProvider`).
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
