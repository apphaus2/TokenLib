//
//  Catalog.swift
//  TokenLib
//
//  The opinionated part: which providers exist, which models each one
//  offers, what they cost, and the profiles an app asks for. Nothing here is
//  stored; the database only holds keys, a few settings and usage.
//

import Foundation

public enum ProviderKind: String, CaseIterable, Codable {
    case anthropic
    case openai
    case gemini
    /// DeepSeek's OpenAI-compatible API (api.deepseek.com).
    case deepseek
    /// Moonshot's Kimi platform, OpenAI-compatible (api.moonshot.ai).
    case kimi
    /// Alibaba Cloud Model Studio's Qwen models, OpenAI-compatible (dashscope-intl.aliyuncs.com).
    case qwen
    /// xAI's Grok, OpenAI-compatible (api.x.ai).
    case grok
    /// Mistral's La Plateforme, OpenAI-compatible (api.mistral.ai).
    case mistral
    /// Cohere's Command models through its OpenAI compatibility API (api.cohere.com/compatibility).
    case cohere
    /// OpenRouter: many vendors' models behind one key, OpenAI-compatible (openrouter.ai).
    case openrouter
    /// An OpenAI-compatible server on the local network (Ollama, LM Studio, vLLM); no key needed.
    case local

    public var displayName: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .openai: return "OpenAI"
        case .gemini: return "Google Gemini"
        case .deepseek: return "DeepSeek"
        case .kimi: return "Kimi (Moonshot)"
        case .qwen: return "Qwen (Alibaba)"
        case .grok: return "Grok (xAI)"
        case .mistral: return "Mistral"
        case .cohere: return "Cohere"
        case .openrouter: return "OpenRouter"
        case .local: return "Local server"
        }
    }

    public var needsKey: Bool { self != .local }
}

/// How capable (and expensive) a model is; profiles ask for a tier, the catalog picks the model.
public enum ModelTier: String, CaseIterable, Codable {
    case fast, balanced, best
}

public struct ModelInfo: Equatable, Codable {
    public var provider: ProviderKind
    public var id: String
    public var name: String
    public var tier: ModelTier
    /// USD per million tokens.
    public var inputPerMillion: Double
    public var outputPerMillion: Double
    public var contextTokens: Int
    public var vision: Bool

    public init(provider: ProviderKind, id: String, name: String, tier: ModelTier, inputPerMillion: Double, outputPerMillion: Double, contextTokens: Int, vision: Bool = true) {
        self.provider = provider; self.id = id; self.name = name; self.tier = tier
        self.inputPerMillion = inputPerMillion; self.outputPerMillion = outputPerMillion; self.contextTokens = contextTokens; self.vision = vision
    }

    /// Cost in micro-dollars for a usage, so the ledger can add integers.
    public func costMicros(promptTokens: Int, replyTokens: Int) -> Int64 {
        Int64((Double(promptTokens) * inputPerMillion + Double(replyTokens) * outputPerMillion).rounded())
    }
}

/// What an app asks for. A profile names an intent, not a model; the catalog and the
/// active provider decide what runs.
public enum Profile: String, CaseIterable, Codable {
    /// A character talking to a person: short replies, low effort, warm.
    case character
    /// General assistance: longer, careful answers.
    case assistant
    /// Cheap and quick: classification, extraction, short rewrites.
    case fast
    /// Requests that include images.
    case vision

    public var tier: ModelTier {
        switch self {
        case .character, .assistant, .vision: return .best
        case .fast: return .fast
        }
    }

    /// Thinking effort hint for providers that support it (Anthropic's `output_config.effort`).
    public var effort: String? {
        switch self {
        case .character, .fast: return "low"
        case .assistant, .vision: return "high"
        }
    }

    public var maxTokens: Int {
        switch self {
        case .character: return 400
        case .fast: return 1024
        case .assistant, .vision: return 4096
        }
    }

    public var temperature: Double? {
        switch self {
        case .character: return 0.9
        case .fast: return 0.2
        case .assistant, .vision: return nil
        }
    }

    public var needsVision: Bool { self == .vision }
}

public enum Catalog {
    /// Anthropic: ids and prices from the 2026 model table (Claude Opus 5.5 / Sonnet 5.5 / Haiku 4.5).
    public static let anthropic: [ModelInfo] = [
        ModelInfo(provider: .anthropic, id: "claude-opus-5-5", name: "Claude Opus 5.5", tier: .best, inputPerMillion: 4, outputPerMillion: 20, contextTokens: 1_000_000),
        ModelInfo(provider: .anthropic, id: "claude-sonnet-5-5", name: "Claude Sonnet 5.5", tier: .balanced, inputPerMillion: 2, outputPerMillion: 10, contextTokens: 1_000_000),
        ModelInfo(provider: .anthropic, id: "claude-haiku-4-5", name: "Claude Haiku 4.5", tier: .fast, inputPerMillion: 1, outputPerMillion: 5, contextTokens: 200_000),
    ]
    public static let openai: [ModelInfo] = [
        ModelInfo(provider: .openai, id: "gpt-5", name: "GPT-5", tier: .best, inputPerMillion: 1.25, outputPerMillion: 10, contextTokens: 400_000),
        ModelInfo(provider: .openai, id: "gpt-5-mini", name: "GPT-5 mini", tier: .balanced, inputPerMillion: 0.25, outputPerMillion: 2, contextTokens: 400_000),
        ModelInfo(provider: .openai, id: "gpt-5-nano", name: "GPT-5 nano", tier: .fast, inputPerMillion: 0.05, outputPerMillion: 0.4, contextTokens: 400_000),
    ]
    public static let gemini: [ModelInfo] = [
        ModelInfo(provider: .gemini, id: "gemini-2.5-pro", name: "Gemini 2.5 Pro", tier: .best, inputPerMillion: 1.25, outputPerMillion: 10, contextTokens: 1_000_000),
        ModelInfo(provider: .gemini, id: "gemini-2.5-flash", name: "Gemini 2.5 Flash", tier: .balanced, inputPerMillion: 0.3, outputPerMillion: 2.5, contextTokens: 1_000_000),
        ModelInfo(provider: .gemini, id: "gemini-2.5-flash-lite", name: "Gemini 2.5 Flash-Lite", tier: .fast, inputPerMillion: 0.1, outputPerMillion: 0.4, contextTokens: 1_000_000),
    ]
    /// DeepSeek: V4 Pro and Flash at peak rates; only Flash takes images.
    public static let deepseek: [ModelInfo] = [
        ModelInfo(provider: .deepseek, id: "deepseek-v4-pro", name: "DeepSeek V4 Pro", tier: .best, inputPerMillion: 1.32, outputPerMillion: 3.96, contextTokens: 1_000_000, vision: false),
        ModelInfo(provider: .deepseek, id: "deepseek-flash", name: "DeepSeek Flash", tier: .fast, inputPerMillion: 0.30, outputPerMillion: 1.20, contextTokens: 1_000_000),
    ]
    /// Kimi (Moonshot): K3 and K2.6; both take images.
    public static let kimi: [ModelInfo] = [
        ModelInfo(provider: .kimi, id: "kimi-k3", name: "Kimi K3", tier: .best, inputPerMillion: 3, outputPerMillion: 15, contextTokens: 1_000_000),
        ModelInfo(provider: .kimi, id: "kimi-k2.6", name: "Kimi K2.6", tier: .balanced, inputPerMillion: 0.95, outputPerMillion: 4, contextTokens: 256_000),
    ]
    /// Qwen (Alibaba Cloud Model Studio, international): the 3.8 / 3.7 line, all multimodal, base-tier prices.
    public static let qwen: [ModelInfo] = [
        ModelInfo(provider: .qwen, id: "qwen3.8-max", name: "Qwen 3.8 Max", tier: .best, inputPerMillion: 2, outputPerMillion: 6, contextTokens: 1_000_000),
        ModelInfo(provider: .qwen, id: "qwen3.7-plus", name: "Qwen 3.7 Plus", tier: .balanced, inputPerMillion: 0.4, outputPerMillion: 1.6, contextTokens: 1_000_000),
        ModelInfo(provider: .qwen, id: "qwen3.8-flash", name: "Qwen 3.8 Flash", tier: .fast, inputPerMillion: 0.15, outputPerMillion: 0.47, contextTokens: 1_000_000),
    ]
    /// xAI: Grok 4.7 and the cheaper Grok 4.3, prices for prompts under 200k tokens; both take images.
    public static let grok: [ModelInfo] = [
        ModelInfo(provider: .grok, id: "grok-4.7", name: "Grok 4.7", tier: .best, inputPerMillion: 2, outputPerMillion: 6, contextTokens: 500_000),
        ModelInfo(provider: .grok, id: "grok-4.3", name: "Grok 4.3", tier: .fast, inputPerMillion: 1.25, outputPerMillion: 2.5, contextTokens: 1_000_000),
    ]
    /// Mistral: the `-latest` aliases of Large 4, Medium 3.5 and Small 4, all multimodal.
    public static let mistral: [ModelInfo] = [
        ModelInfo(provider: .mistral, id: "mistral-large-latest", name: "Mistral Large", tier: .best, inputPerMillion: 0.5, outputPerMillion: 1.5, contextTokens: 512_000),
        ModelInfo(provider: .mistral, id: "mistral-medium-latest", name: "Mistral Medium", tier: .balanced, inputPerMillion: 1.5, outputPerMillion: 7.5, contextTokens: 256_000),
        ModelInfo(provider: .mistral, id: "mistral-small-latest", name: "Mistral Small", tier: .fast, inputPerMillion: 0.15, outputPerMillion: 0.6, contextTokens: 256_000),
    ]
    /// Cohere: Command A+ (images, reasoning), Command A and Command R7B.
    public static let cohere: [ModelInfo] = [
        ModelInfo(provider: .cohere, id: "command-a-plus-05-2026", name: "Command A+", tier: .best, inputPerMillion: 0.3, outputPerMillion: 1.5, contextTokens: 128_000),
        ModelInfo(provider: .cohere, id: "command-a-03-2025", name: "Command A", tier: .balanced, inputPerMillion: 2.5, outputPerMillion: 10, contextTokens: 256_000, vision: false),
        ModelInfo(provider: .cohere, id: "command-r7b-12-2024", name: "Command R7B", tier: .fast, inputPerMillion: 0.0375, outputPerMillion: 0.15, contextTokens: 128_000, vision: false),
    ]
    /// OpenRouter: the same opinion as the Anthropic catalog, through one OpenRouter key; prices as OpenRouter lists them.
    public static let openrouter: [ModelInfo] = [
        ModelInfo(provider: .openrouter, id: "anthropic/claude-opus-5.5", name: "Claude Opus 5.5 via OpenRouter", tier: .best, inputPerMillion: 4, outputPerMillion: 20, contextTokens: 1_000_000),
        ModelInfo(provider: .openrouter, id: "anthropic/claude-sonnet-5.5", name: "Claude Sonnet 5.5 via OpenRouter", tier: .balanced, inputPerMillion: 2, outputPerMillion: 10, contextTokens: 1_000_000),
        ModelInfo(provider: .openrouter, id: "anthropic/claude-haiku-4.5", name: "Claude Haiku 4.5 via OpenRouter", tier: .fast, inputPerMillion: 1, outputPerMillion: 5, contextTokens: 200_000),
    ]
    /// A local server serves whatever model is loaded; the id is the settings' `localModel`.
    public static let local: [ModelInfo] = [
        ModelInfo(provider: .local, id: "local", name: "Local model", tier: .balanced, inputPerMillion: 0, outputPerMillion: 0, contextTokens: 32_000, vision: false),
    ]

    public static func models(for provider: ProviderKind) -> [ModelInfo] {
        switch provider {
        case .anthropic: return anthropic
        case .openai: return openai
        case .gemini: return gemini
        case .deepseek: return deepseek
        case .kimi: return kimi
        case .qwen: return qwen
        case .grok: return grok
        case .mistral: return mistral
        case .cohere: return cohere
        case .openrouter: return openrouter
        case .local: return local
        }
    }

    public static var all: [ModelInfo] { ProviderKind.allCases.flatMap(models(for:)) }

    public static func model(id: String) -> ModelInfo? { all.first { $0.id == id } }

    /// The model a provider runs for a profile: the profile's tier, or the nearest one the provider has.
    public static func model(for profile: Profile, provider: ProviderKind) -> ModelInfo {
        let models = models(for: provider)
        let order: [ModelTier] = profile.tier == .fast ? [.fast, .balanced, .best] : profile.tier == .balanced ? [.balanced, .best, .fast] : [.best, .balanced, .fast]
        for tier in order {
            if let m = models.first(where: { $0.tier == tier && (!profile.needsVision || $0.vision) }) { return m }
        }
        return models[0]
    }
}
