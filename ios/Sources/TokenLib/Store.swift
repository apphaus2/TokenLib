//
//  Store.swift
//  TokenLib
//
//  The repository pattern: keys, settings and usage behind small protocols,
//  with an in-memory store for tests and a SQLite store for apps. Keys are
//  stored as ciphertext; the cipher (Keychain, Keystore) is the platform's.
//

import Foundation

/// Encrypts API keys at rest. Apps supply a platform cipher; `PlainCipher` is for tests only.
public protocol SecretCipher {
    func encrypt(_ plaintext: Data) throws -> Data
    func decrypt(_ ciphertext: Data) throws -> Data
}

public struct PlainCipher: SecretCipher {
    public init() {}
    public func encrypt(_ plaintext: Data) throws -> Data { plaintext }
    public func decrypt(_ ciphertext: Data) throws -> Data { ciphertext }
}

public protocol KeyRepository {
    /// The stored ciphertext for a provider's key.
    func keyData(for provider: ProviderKind) throws -> Data?
    func setKeyData(_ data: Data?, for provider: ProviderKind) throws
    func providersWithKeys() throws -> [ProviderKind]
}

/// A provider balance the user read off the provider's billing page, and what TokenLib has charged that provider since.
/// Providers do not report balances to API keys, so this is TokenLib's own count: use of the key elsewhere is not seen.
public struct Credit: Equatable, Codable {
    /// The balance entered, in millionths of a dollar.
    public var micros: Int64
    public var spentMicros: Int64

    public init(micros: Int64, spentMicros: Int64 = 0) { self.micros = micros; self.spentMicros = spentMicros }

    public var remainingMicros: Int64 { max(0, micros - spentMicros) }
    public var remainingUSD: Double { Double(remainingMicros) / 1_000_000 }
    public var totalUSD: Double { Double(micros) / 1_000_000 }
}

public struct Settings: Equatable, Codable {
    /// The master switch: off means no request is sent anywhere, whatever else is configured (on by default).
    public var enabled: Bool
    /// The provider requests go to; `nil` until the app picks one.
    public var activeProvider: ProviderKind?
    /// For `.local`: the OpenAI-compatible server, e.g. `http://192.168.1.20:11434/v1`.
    public var localBaseURL: String?
    /// For `.local`: the model name the server loads.
    public var localModel: String?
    /// Total tokens allowed per calendar day across every session; `nil` is unlimited.
    public var dailyTokenCap: Int?
    /// Whether prompts and replies are kept with the usage rows (off by default).
    public var logPrompts: Bool
    /// The balance entered per provider and the spend counted against it; empty until the user enters one.
    public var credits: [ProviderKind: Credit]

    public init(enabled: Bool = true, activeProvider: ProviderKind? = nil, localBaseURL: String? = nil, localModel: String? = nil, dailyTokenCap: Int? = nil, logPrompts: Bool = false, credits: [ProviderKind: Credit] = [:]) {
        self.enabled = enabled; self.activeProvider = activeProvider; self.localBaseURL = localBaseURL; self.localModel = localModel; self.dailyTokenCap = dailyTokenCap; self.logPrompts = logPrompts; self.credits = credits
    }
}

public protocol SettingsRepository {
    func settings() throws -> Settings
    func save(_ settings: Settings) throws
}

public struct UsageRecord: Equatable, Codable {
    public var id: Int64?
    public var at: Date
    /// Who asked (an actor id, a screen name); free text.
    public var consumer: String
    public var profile: Profile
    public var provider: ProviderKind
    public var model: String
    public var promptTokens: Int
    public var replyTokens: Int
    public var costMicros: Int64
    public var stop: StopReason
    /// Only when `Settings.logPrompts` is on.
    public var prompt: String?
    public var reply: String?

    public init(id: Int64? = nil, at: Date = Date(), consumer: String, profile: Profile, provider: ProviderKind, model: String, promptTokens: Int, replyTokens: Int, costMicros: Int64, stop: StopReason, prompt: String? = nil, reply: String? = nil) {
        self.id = id; self.at = at; self.consumer = consumer; self.profile = profile; self.provider = provider; self.model = model
        self.promptTokens = promptTokens; self.replyTokens = replyTokens; self.costMicros = costMicros; self.stop = stop; self.prompt = prompt; self.reply = reply
    }

    public var totalTokens: Int { promptTokens + replyTokens }
}

public struct UsageTotals: Equatable {
    public var requests: Int
    public var promptTokens: Int
    public var replyTokens: Int
    public var costMicros: Int64
    public init(requests: Int = 0, promptTokens: Int = 0, replyTokens: Int = 0, costMicros: Int64 = 0) { self.requests = requests; self.promptTokens = promptTokens; self.replyTokens = replyTokens; self.costMicros = costMicros }
    public var totalTokens: Int { promptTokens + replyTokens }
    public var costUSD: Double { Double(costMicros) / 1_000_000 }
}

public protocol UsageRepository {
    @discardableResult
    func record(_ usage: UsageRecord) throws -> UsageRecord
    /// Totals since `date`, optionally for one consumer.
    func totals(since date: Date, consumer: String?) throws -> UsageTotals
    /// Most recent rows first.
    func recent(limit: Int, consumer: String?) throws -> [UsageRecord]
    func deleteAll() throws
}

public typealias TokenStore = KeyRepository & SettingsRepository & UsageRepository

// MARK: - In memory (tests, previews)

public final class InMemoryStore: TokenStore {
    private var keys: [ProviderKind: Data] = [:]
    private var current = Settings()
    private var usage: [UsageRecord] = []
    private var nextId: Int64 = 1
    private let lock = NSLock()

    public init() {}

    public func keyData(for provider: ProviderKind) throws -> Data? { lock.lock(); defer { lock.unlock() }; return keys[provider] }
    public func setKeyData(_ data: Data?, for provider: ProviderKind) throws { lock.lock(); keys[provider] = data; lock.unlock() }
    public func providersWithKeys() throws -> [ProviderKind] { lock.lock(); defer { lock.unlock() }; return ProviderKind.allCases.filter { keys[$0] != nil } }
    public func settings() throws -> Settings { lock.lock(); defer { lock.unlock() }; return current }
    public func save(_ settings: Settings) throws { lock.lock(); current = settings; lock.unlock() }

    public func record(_ record: UsageRecord) throws -> UsageRecord {
        lock.lock(); defer { lock.unlock() }
        var r = record
        r.id = nextId
        nextId += 1
        usage.append(r)
        return r
    }

    public func totals(since date: Date, consumer: String?) throws -> UsageTotals {
        lock.lock(); defer { lock.unlock() }
        var t = UsageTotals()
        for r in usage where r.at >= date && (consumer == nil || r.consumer == consumer) {
            t.requests += 1; t.promptTokens += r.promptTokens; t.replyTokens += r.replyTokens; t.costMicros += r.costMicros
        }
        return t
    }

    public func recent(limit: Int, consumer: String?) throws -> [UsageRecord] {
        lock.lock(); defer { lock.unlock() }
        return Array(usage.filter { consumer == nil || $0.consumer == consumer }.suffix(limit).reversed())
    }

    public func deleteAll() throws { lock.lock(); usage.removeAll(); lock.unlock() }
}
