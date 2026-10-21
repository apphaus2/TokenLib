//
//  Chat.swift
//  TokenLib
//
//  The request and the streamed reply, in TokenLib's own terms. Providers
//  translate these to their wire formats; consumers never see a provider.
//

import Foundation

/// One piece of a message: text, or an image carried inline as base64.
public enum ChatPart: Equatable, Codable {
    case text(String)
    /// `mediaType` is the MIME type (`image/jpeg`, `image/png`, `image/webp`, `image/gif`); `data` is base64 with no `data:` prefix.
    case image(data: String, mediaType: String)

    public var text: String? { if case .text(let t) = self { return t } else { return nil } }
    public var isImage: Bool { if case .image = self { return true } else { return false } }
}

public struct ChatMessage: Equatable, Codable {
    public enum Role: String, Codable { case user, assistant }
    public var role: Role
    /// Plain text; when `parts` is set this is the concatenated text, kept for logging and estimates.
    public var text: String
    /// Multimodal content; `nil` means the message is `text` alone.
    public var parts: [ChatPart]?

    public init(role: Role, text: String, parts: [ChatPart]? = nil) { self.role = role; self.text = text; self.parts = parts }
    public static func user(_ text: String) -> ChatMessage { ChatMessage(role: .user, text: text) }
    public static func assistant(_ text: String) -> ChatMessage { ChatMessage(role: .assistant, text: text) }
    /// A user message made of text and image parts.
    public static func user(parts: [ChatPart]) -> ChatMessage { ChatMessage(role: .user, text: ChatPart.joinedText(parts), parts: parts) }

    /// The parts providers send: `parts` when set, else the text alone.
    public var contentParts: [ChatPart] { parts ?? [.text(text)] }
    public var imageCount: Int { parts?.filter(\.isImage).count ?? 0 }
}

extension ChatPart {
    static func joinedText(_ parts: [ChatPart]) -> String { parts.compactMap(\.text).joined(separator: "\n") }
}

public struct ChatRequest: Equatable {
    public var system: String?
    public var messages: [ChatMessage]
    /// Overrides the profile's defaults when set.
    public var maxTokens: Int?
    public var temperature: Double?
    /// Ask the provider for a reply that validates against this JSON schema (Anthropic `output_config.format`,
    /// OpenAI `response_format`, Gemini `responseMimeType`). The reply text is then the JSON document.
    /// Providers that cannot enforce the schema still ask for JSON.
    public var jsonSchema: [String: Any]?

    public init(system: String? = nil, messages: [ChatMessage], maxTokens: Int? = nil, temperature: Double? = nil, jsonSchema: [String: Any]? = nil) {
        self.system = system; self.messages = messages; self.maxTokens = maxTokens; self.temperature = temperature; self.jsonSchema = jsonSchema
    }

    /// Roughly four characters per token, plus about 1,600 per image; used before a request to check budgets.
    public var estimatedPromptTokens: Int {
        let chars = (system?.utf8.count ?? 0) + messages.reduce(0) { $0 + $1.text.utf8.count + 8 }
        let images = messages.reduce(0) { $0 + $1.imageCount }
        return (chars + 3) / 4 + images * 1600
    }

    public static func == (a: ChatRequest, b: ChatRequest) -> Bool {
        a.system == b.system && a.messages == b.messages && a.maxTokens == b.maxTokens && a.temperature == b.temperature
            && a.jsonSchema.flatMap { try? JSON.data($0) } == b.jsonSchema.flatMap { try? JSON.data($0) }
    }
}

public struct Usage: Equatable, Codable {
    public var promptTokens: Int
    public var replyTokens: Int
    public init(promptTokens: Int = 0, replyTokens: Int = 0) { self.promptTokens = promptTokens; self.replyTokens = replyTokens }
    public var total: Int { promptTokens + replyTokens }
}

public enum StopReason: String, Codable {
    case end, maxTokens, refusal, other
}

/// What a provider emits while a reply streams.
public enum ChatEvent: Equatable {
    case text(String)
    case done(usage: Usage, stop: StopReason)
}

public struct ChatReply: Equatable {
    public var text: String
    public var usage: Usage
    public var stop: StopReason
    /// The model id and provider that answered, for the consumer's records (consumers still never choose them).
    public var model: String
    public var provider: ProviderKind
    public init(text: String, usage: Usage, stop: StopReason, model: String, provider: ProviderKind) {
        self.text = text; self.usage = usage; self.stop = stop; self.model = model; self.provider = provider
    }
}

public enum TokenLibError: Error, Equatable, CustomStringConvertible {
    /// `Settings.enabled` is off: nothing is sent anywhere.
    case disabled
    case noProvider
    case missingKey(ProviderKind)
    /// A native provider (Apple Intelligence) is active but cannot answer on this device or build.
    case unavailable(ProviderKind)
    case budgetExhausted
    case dailyCapReached
    case http(status: Int, body: String)
    case transport(String)
    case malformed(String)
    case cancelled

    public var description: String {
        switch self {
        case .disabled: return "AI is turned off"
        case .noProvider: return "no AI provider is configured"
        case .missingKey(let p): return "no API key for \(p.displayName)"
        case .unavailable(let p): return "\(p.displayName) is not available on this device"
        case .budgetExhausted: return "the session's token budget is spent"
        case .dailyCapReached: return "the daily token cap is reached"
        case .http(let s, let b): return "HTTP \(s): \(b.prefix(200))"
        case .transport(let m): return "transport: \(m)"
        case .malformed(let m): return "malformed reply: \(m)"
        case .cancelled: return "cancelled"
        }
    }
}
