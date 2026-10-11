//
//  TokenServer.swift
//  TokenLib
//
//  The server side: owns the store, the cipher and the transport, knows the
//  keys, picks the model for a profile, enforces the daily cap and records
//  usage. Apps configure it (keys, active provider) and build their settings
//  screens on its query methods; consumers only ever hold a TokenClient.
//

import Foundation

/// What consumers see. In-process today; the protocol is the seam for a remote broker later.
public protocol TokenBroker: AnyObject {
    /// Whether requests can be served right now (a provider is active and, if it needs one, has a key).
    var isReady: Bool { get }
    /// Streams a reply. `consumer` names who asked (for usage rows); `budgetRemaining` is the session's own allowance, if any.
    @discardableResult
    func stream(_ request: ChatRequest, profile: Profile, consumer: String, onEvent: @escaping (ChatEvent) -> Void, completion: @escaping (Result<ChatReply, TokenLibError>) -> Void) -> Cancellable
}

public final class TokenServer: TokenBroker {
    public let store: TokenStore
    public let cipher: SecretCipher
    public let transport: HttpTransport
    /// Overrides the catalog's providers (tests inject fakes).
    public var providers: [ProviderKind: Provider] = [:]
    /// The start of "today" for the daily cap; midnight local time by default.
    public var dayStart: () -> Date = { Calendar.current.startOfDay(for: Date()) }
    private let lock = NSLock()

    public init(store: TokenStore, cipher: SecretCipher, transport: HttpTransport = URLSessionTransport()) {
        self.store = store; self.cipher = cipher; self.transport = transport
    }

    // MARK: - Configuration (the app's settings screens call these)

    public var settings: Settings { (try? store.settings()) ?? Settings() }

    public func update(_ change: (inout Settings) -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        var s = try store.settings()
        change(&s)
        try store.save(s)
    }

    public func setKey(_ key: String?, for provider: ProviderKind) throws {
        guard let key = key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { try store.setKeyData(nil, for: provider); return }
        try store.setKeyData(try cipher.encrypt(Data(key.utf8)), for: provider)
    }

    public func key(for provider: ProviderKind) throws -> String? {
        guard let data = try store.keyData(for: provider) else { return nil }
        return String(decoding: try cipher.decrypt(data), as: UTF8.self)
    }

    public func hasKey(for provider: ProviderKind) -> Bool { (try? store.keyData(for: provider)) != nil }

    public var configuredProviders: [ProviderKind] { (try? store.providersWithKeys()) ?? [] }

    /// Moves every stored key from `legacy` to this server's cipher: each key `legacy` can decrypt is
    /// re-encrypted with `cipher`, and keys it cannot read are left as they are. Returns the providers whose
    /// keys moved. For rotating the cipher key, or moving to a cipher under new identifiers.
    @discardableResult
    public func reencryptKeys(from legacy: SecretCipher) throws -> [ProviderKind] {
        lock.lock(); defer { lock.unlock() }
        var moved: [ProviderKind] = []
        for provider in try store.providersWithKeys() {
            guard let data = try store.keyData(for: provider), let plaintext = try? legacy.decrypt(data) else { continue }
            try store.setKeyData(try cipher.encrypt(plaintext), for: provider)
            moved.append(provider)
        }
        return moved
    }

    /// Whether every stored key decrypts with this server's cipher.
    public var keysReadable: Bool { configuredProviders.allSatisfy { (try? key(for: $0)) != nil } }

    /// Picks the provider and stores its key in one step.
    public func activate(_ provider: ProviderKind, key: String? = nil) throws {
        if let key = key { try setKey(key, for: provider) }
        try update { $0.activeProvider = provider }
    }

    public var isReady: Bool {
        guard let p = settings.activeProvider else { return false }
        if p == .local { return settings.localBaseURL != nil }
        return hasKey(for: p)
    }

    /// The model a profile will run on right now.
    public func model(for profile: Profile) -> ModelInfo? {
        guard let p = settings.activeProvider else { return nil }
        var m = Catalog.model(for: profile, provider: p)
        if p == .local, let name = settings.localModel { m.id = name; m.name = name }
        return m
    }

    public func usageToday() -> UsageTotals { (try? store.totals(since: dayStart(), consumer: nil)) ?? UsageTotals() }
    /// Records the balance the user read off the provider's billing page; spend is counted down from it. `nil` or zero forgets it.
    public func setCredit(_ micros: Int64?, for provider: ProviderKind) throws {
        try update { $0.credits[provider] = micros.flatMap { $0 > 0 ? Credit(micros: $0) : nil } }
    }

    /// The credit entered for a provider (the active one by default) and what is left of it; `nil` when none was entered.
    public func credit(for provider: ProviderKind? = nil) -> Credit? {
        let s = settings
        return (provider ?? s.activeProvider).flatMap { s.credits[$0] }
    }

    /// Tokens left under the daily cap today; `nil` when there is no cap.
    public func remainingToday() -> Int? { settings.dailyTokenCap.map { max(0, $0 - usageToday().totalTokens) } }
    public func usage(since date: Date, consumer: String? = nil) -> UsageTotals { (try? store.totals(since: date, consumer: consumer)) ?? UsageTotals() }
    public func recentUsage(limit: Int = 50, consumer: String? = nil) -> [UsageRecord] { (try? store.recent(limit: limit, consumer: consumer)) ?? [] }

    // MARK: - TokenBroker

    public func stream(_ request: ChatRequest, profile: Profile, consumer: String, onEvent: @escaping (ChatEvent) -> Void, completion: @escaping (Result<ChatReply, TokenLibError>) -> Void) -> Cancellable {
        let settings = self.settings
        guard let kind = settings.activeProvider else { return failed(.noProvider, completion) }
        if let cap = settings.dailyTokenCap, usageToday().totalTokens + request.estimatedPromptTokens >= cap { return failed(.dailyCapReached, completion) }
        let key: String?
        do { key = try self.key(for: kind) } catch { return failed(.transport("\(error)"), completion) }
        if kind.needsKey, key == nil { return failed(.missingKey(kind), completion) }
        guard let model = model(for: profile) else { return failed(.noProvider, completion) }
        let provider = providers[kind] ?? Providers.provider(for: kind)
        let call = ProviderCall(model: model, key: key, baseURL: settings.localBaseURL.flatMap(URL.init), profile: profile)
        let http: HttpRequest
        do { http = try provider.request(request, call: call) } catch let e as TokenLibError { return failed(e, completion) } catch { return failed(.transport("\(error)"), completion) }
        var parser = provider.makeParser()
        var text = ""
        var done: (Usage, StopReason)?
        let deliver: (ChatEvent) -> Void = { event in
            switch event {
            case .text(let t): text += t
            case .done(let usage, let stop): if done == nil { done = (usage, stop) }
            }
            onEvent(event)
        }
        return transport.stream(http, onStatus: { _ in }, onLine: { line in
            for event in parser.feed(line) { deliver(event) }
        }, completion: { [weak self] result in
            switch result {
            case .failure(let error): completion(.failure(error))
            case .success:
                for event in parser.finish() { deliver(event) }
                var usage = done?.0 ?? Usage()
                let stop = done?.1 ?? .other
                if usage.promptTokens == 0 { usage.promptTokens = request.estimatedPromptTokens }
                if usage.replyTokens == 0 { usage.replyTokens = (text.utf8.count + 3) / 4 }
                if let self = self {
                    let record = UsageRecord(consumer: consumer, profile: profile, provider: kind, model: model.id, promptTokens: usage.promptTokens, replyTokens: usage.replyTokens,
                                             costMicros: model.costMicros(promptTokens: usage.promptTokens, replyTokens: usage.replyTokens), stop: stop,
                                             prompt: settings.logPrompts ? request.messages.last?.text : nil, reply: settings.logPrompts ? text : nil)
                    _ = try? self.store.record(record)
                    if record.costMicros > 0, settings.credits[kind] != nil { try? self.update { $0.credits[kind]?.spentMicros += record.costMicros } }
                }
                completion(.success(ChatReply(text: text, usage: usage, stop: stop, model: model.id, provider: kind)))
            }
        })
    }

    private func failed(_ error: TokenLibError, _ completion: @escaping (Result<ChatReply, TokenLibError>) -> Void) -> Cancellable {
        completion(.failure(error))
        return NoopCancellable()
    }
}

struct NoopCancellable: Cancellable { func cancel() {} }
