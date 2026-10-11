//
//  TokenClient.swift
//  TokenLib
//
//  The client SDK: what a library or a screen holds. It knows a broker and
//  nothing else; sessions carry a consumer name, a profile and an optional
//  budget of their own.
//

import Foundation

public final class TokenClient {
    public let broker: TokenBroker

    public init(broker: TokenBroker) { self.broker = broker }

    public var isReady: Bool { broker.isReady }

    /// Opens a session for `consumer` (an actor id, a screen) on a profile. `budget` caps the tokens the
    /// session may spend in total; the broker's daily cap applies on top.
    public func session(consumer: String, profile: Profile, budget: Int? = nil) -> TokenSession {
        TokenSession(client: self, consumer: consumer, profile: profile, budget: budget)
    }
}

public final class TokenSession {
    public let client: TokenClient
    public let consumer: String
    public let profile: Profile
    public let budget: Int?
    public private(set) var spent = 0
    public private(set) var requests = 0
    private let lock = NSLock()

    init(client: TokenClient, consumer: String, profile: Profile, budget: Int?) {
        self.client = client; self.consumer = consumer; self.profile = profile; self.budget = budget
    }

    public var remaining: Int? { budget.map { max(0, $0 - spent) } }
    public var isExhausted: Bool { remaining.map { $0 <= 0 } ?? false }

    /// Streams a reply: `onText` gets deltas as they arrive, `completion` the whole reply with usage.
    @discardableResult
    public func stream(_ request: ChatRequest, onText: @escaping (String) -> Void, completion: @escaping (Result<ChatReply, TokenLibError>) -> Void) -> Cancellable {
        if let remaining = remaining, remaining <= 0 || request.estimatedPromptTokens >= remaining {
            completion(.failure(.budgetExhausted))
            return NoopCancellable()
        }
        return client.broker.stream(request, profile: profile, consumer: consumer, onEvent: { event in
            if case .text(let t) = event { onText(t) }
        }, completion: { [weak self] result in
            if let self = self, case .success(let reply) = result {
                self.lock.lock(); self.spent += reply.usage.total; self.requests += 1; self.lock.unlock()
            }
            completion(result)
        })
    }

    /// A whole reply at once.
    @discardableResult
    public func send(_ request: ChatRequest, completion: @escaping (Result<ChatReply, TokenLibError>) -> Void) -> Cancellable {
        stream(request, onText: { _ in }, completion: completion)
    }
}
