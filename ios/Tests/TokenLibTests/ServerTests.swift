import XCTest
@testable import TokenLib

final class ServerTests: XCTestCase {
    var transport: FakeTransport!
    var server: TokenServer!

    override func setUp() {
        transport = FakeTransport()
        transport.responses["api.anthropic.com"] = (200, Canned.anthropic)
        transport.responses["api.openai.com"] = (200, Canned.openai)
        server = TokenServer(store: InMemoryStore(), cipher: PlainCipher(), transport: transport)
    }

    func stream(_ session: TokenSession, _ text: String = "sing") -> (Result<ChatReply, TokenLibError>?, [String]) {
        var result: Result<ChatReply, TokenLibError>?
        var deltas: [String] = []
        session.stream(ChatRequest(system: "bush", messages: [.user(text)]), onText: { deltas.append($0) }, completion: { result = $0 })
        return (result, deltas)
    }

    func testNotReadyWithoutProviderOrKey() throws {
        XCTAssertFalse(server.isReady)
        let client = TokenClient(broker: server)
        var (result, _) = stream(client.session(consumer: "bush", profile: .character))
        XCTAssertEqual(try? result?.get(), nil)
        if case .failure(let e)? = result { XCTAssertEqual(e, .noProvider) } else { XCTFail() }
        try server.update { $0.activeProvider = .anthropic }
        XCTAssertFalse(server.isReady)
        (result, _) = stream(client.session(consumer: "bush", profile: .character))
        if case .failure(let e)? = result { XCTAssertEqual(e, .missingKey(.anthropic)) } else { XCTFail() }
        try server.activate(.local)
        XCTAssertFalse(server.isReady, "local needs a base URL")
        try server.update { $0.localBaseURL = "http://h/v1" }
        XCTAssertTrue(server.isReady)
    }

    func testStreamsRecordsUsageAndEncryptsKeys() throws {
        struct Rot13: SecretCipher {
            func encrypt(_ p: Data) throws -> Data { Data(p.map { $0 ^ 0x2A }) }
            func decrypt(_ c: Data) throws -> Data { Data(c.map { $0 ^ 0x2A }) }
        }
        let store = InMemoryStore()
        server = TokenServer(store: store, cipher: Rot13(), transport: transport)
        try server.activate(.anthropic, key: " sk-live ")
        XCTAssertEqual(try store.keyData(for: .anthropic), Data("sk-live".utf8.map { $0 ^ 0x2A }), "stored as ciphertext, trimmed")
        XCTAssertEqual(try server.key(for: .anthropic), "sk-live")
        XCTAssertTrue(server.isReady)
        XCTAssertEqual(server.model(for: .character)?.id, "claude-opus-5-5")
        let client = TokenClient(broker: server)
        let session = client.session(consumer: "bush", profile: .character, budget: 1000)
        let (result, deltas) = stream(session)
        let reply = try XCTUnwrap(try result?.get())
        XCTAssertEqual(reply.text, "Ask, and the bush shall sing.")
        XCTAssertEqual(deltas, ["Ask, ", "and the bush shall sing."])
        XCTAssertEqual(reply.usage, Usage(promptTokens: 25, replyTokens: 9))
        XCTAssertEqual(reply.model, "claude-opus-5-5", "the reply says what answered")
        XCTAssertEqual(reply.provider, .anthropic)
        XCTAssertEqual(session.spent, 34)
        XCTAssertEqual(session.remaining, 966)
        XCTAssertEqual(transport.requests.last?.headers["x-api-key"], "sk-live")
        let usage = server.usageToday()
        XCTAssertEqual(usage.requests, 1)
        XCTAssertEqual(usage.totalTokens, 34)
        XCTAssertEqual(usage.costMicros, 25 * 4 + 9 * 20)
        let row = server.recentUsage().first!
        XCTAssertEqual(row.consumer, "bush")
        XCTAssertEqual(row.model, "claude-opus-5-5")
        XCTAssertNil(row.prompt, "prompts are not logged by default")
    }

    func testSessionBudgetAndDailyCap() throws {
        try server.activate(.anthropic, key: "k")
        let client = TokenClient(broker: server)
        let small = client.session(consumer: "bush", profile: .character, budget: 36)
        var (result, _) = stream(small)
        XCTAssertNotNil(try? result?.get())
        XCTAssertEqual(small.remaining, 2, "34 of 36 spent; the next prompt would not fit")
        XCTAssertFalse(small.isExhausted)
        (result, _) = stream(small)
        if case .failure(let e)? = result { XCTAssertEqual(e, .budgetExhausted) } else { XCTFail() }
        XCTAssertNil(server.remainingToday(), "no cap, nothing to count down")
        try server.update { $0.dailyTokenCap = 100 }
        XCTAssertEqual(server.remainingToday(), 66, "34 of 100 spent today")
        try server.update { $0.dailyTokenCap = 20 }
        XCTAssertEqual(server.remainingToday(), 0, "never below zero")
        try server.update { $0.dailyTokenCap = 36 }
        let other = client.session(consumer: "snoopy", profile: .fast)
        (result, _) = stream(other)
        if case .failure(let e)? = result { XCTAssertEqual(e, .dailyCapReached) } else { XCTFail("the day's 34 tokens plus this prompt exceed the cap") }
    }

    func testCreditCountsDownAndSurvivesClearingUsage() throws {
        try server.activate(.anthropic, key: "k")
        XCTAssertNil(server.credit(), "nothing entered yet")
        try server.setCredit(50_000_000, for: .anthropic)
        let session = TokenClient(broker: server).session(consumer: "bush", profile: .character)
        _ = stream(session)
        XCTAssertEqual(server.credit(), Credit(micros: 50_000_000, spentMicros: 280), "25 in at $4 and 9 out at $20 per million")
        XCTAssertEqual(server.credit()?.remainingMicros, 49_999_720)
        try server.store.deleteAll()
        _ = stream(session)
        XCTAssertEqual(server.credit()?.spentMicros, 560, "the count is the credit's own, not the usage log's")
        XCTAssertNil(server.credit(for: .openai), "per provider")
        try server.setCredit(100, for: .anthropic)
        _ = stream(session)
        XCTAssertEqual(server.credit()?.remainingMicros, 0, "never below zero")
        try server.setCredit(nil, for: .anthropic)
        XCTAssertNil(server.credit())
    }

    func testSwitchingProviderAndLoggingPrompts() throws {
        try server.activate(.anthropic, key: "a")
        try server.activate(.openai, key: "o")
        try server.update { $0.logPrompts = true }
        XCTAssertEqual(server.configuredProviders, [.anthropic, .openai])
        XCTAssertEqual(server.model(for: .fast)?.id, "gpt-5-nano")
        let (result, _) = stream(TokenClient(broker: server).session(consumer: "x", profile: .fast), "hello?")
        XCTAssertEqual(try result?.get().text, "Hello there")
        let row = server.recentUsage().first!
        XCTAssertEqual(row.provider, .openai)
        XCTAssertEqual(row.prompt, "hello?")
        XCTAssertEqual(row.reply, "Hello there")
    }

    func testOpenAICompatibleVendorsServeProfiles() throws {
        transport.responses["api.deepseek.com"] = (200, Canned.openai)
        transport.responses["api.moonshot.ai"] = (200, Canned.openai)
        transport.responses["dashscope-intl.aliyuncs.com"] = (200, Canned.openai)
        transport.responses["api.x.ai"] = (200, Canned.openai)
        transport.responses["api.mistral.ai"] = (200, Canned.openai)
        transport.responses["api.cohere.com"] = (200, Canned.openai)
        transport.responses["openrouter.ai"] = (200, Canned.openai)
        for (kind, model) in [(ProviderKind.deepseek, "deepseek-v4-pro"), (.kimi, "kimi-k3"), (.qwen, "qwen3.8-max"), (.grok, "grok-4.7"),
                              (.mistral, "mistral-large-latest"), (.cohere, "command-a-plus-05-2026"), (.openrouter, "anthropic/claude-opus-5.5")] {
            try server.activate(kind, key: "k-\(kind.rawValue)")
            XCTAssertTrue(server.isReady)
            XCTAssertEqual(server.model(for: .character)?.id, model)
            let (result, _) = stream(TokenClient(broker: server).session(consumer: "bush", profile: .character))
            let reply = try XCTUnwrap(try result?.get())
            XCTAssertEqual(reply.text, "Hello there")
            XCTAssertEqual(reply.provider, kind)
            XCTAssertEqual(reply.model, model)
            XCTAssertEqual(transport.requests.last?.headers["Authorization"], "Bearer k-\(kind.rawValue)")
            XCTAssertEqual(server.recentUsage().first?.provider, kind)
        }
        XCTAssertEqual(server.configuredProviders, [.deepseek, .kimi, .qwen, .grok, .mistral, .cohere, .openrouter])
        XCTAssertEqual(server.usageToday().requests, 7)
    }

    /// A cipher that marks its output, so a wrong key fails the way AES-GCM's tag check does.
    struct Tagged: SecretCipher {
        struct WrongKey: Error {}
        let tag: UInt8
        func encrypt(_ p: Data) throws -> Data { Data([tag]) + p }
        func decrypt(_ c: Data) throws -> Data { guard c.first == tag else { throw WrongKey() }; return Data(c.dropFirst()) }
    }

    func testReencryptKeysMovesKeysToANewCipher() throws {
        let store = InMemoryStore()
        let old = TokenServer(store: store, cipher: Tagged(tag: 1), transport: transport)
        try old.setKey("sk-a", for: .anthropic)
        try old.setKey("sk-o", for: .openai)
        let server = TokenServer(store: store, cipher: Tagged(tag: 2), transport: transport)
        XCTAssertFalse(server.keysReadable, "the new cipher cannot read the old keys")
        XCTAssertEqual(try server.reencryptKeys(from: Tagged(tag: 1)), [.anthropic, .openai])
        XCTAssertTrue(server.keysReadable)
        XCTAssertEqual(try server.key(for: .anthropic), "sk-a")
        XCTAssertEqual(try server.key(for: .openai), "sk-o")
        XCTAssertEqual(try server.reencryptKeys(from: Tagged(tag: 1)), [], "a second run moves nothing")
        XCTAssertEqual(try server.key(for: .anthropic), "sk-a")
    }

    func testHttpErrorsSurface() throws {
        try server.activate(.anthropic, key: "k")
        transport.responses["api.anthropic.com"] = (401, "{\"error\":{\"message\":\"invalid x-api-key\"}}")
        let (result, _) = stream(TokenClient(broker: server).session(consumer: "x", profile: .character))
        if case .failure(let e)? = result { XCTAssertEqual(e, .http(status: 401, body: "{\"error\":{\"message\":\"invalid x-api-key\"}}")) } else { XCTFail() }
        XCTAssertEqual(server.usageToday().requests, 0, "failed requests are not charged")
    }

    func testRefusalIsAStopReasonNotAnError() throws {
        try server.activate(.anthropic, key: "k")
        transport.responses["api.anthropic.com"] = (200, Canned.anthropicRefusal)
        let (result, _) = stream(TokenClient(broker: server).session(consumer: "x", profile: .vision))
        XCTAssertEqual(try result?.get().stop, .refusal)
        XCTAssertEqual(server.usageToday().requests, 1, "a refusal still used prompt tokens")
    }

    func testImagePartsCountAgainstBudget() throws {
        try server.activate(.anthropic, key: "k")
        let session = TokenClient(broker: server).session(consumer: "eye", profile: .vision, budget: 1000)
        var result: Result<ChatReply, TokenLibError>?
        let request = ChatRequest(messages: [.user(parts: [.text("look"), .image(data: "AAAA", mediaType: "image/png")])])
        session.send(request) { result = $0 }
        if case .failure(let e)? = result { XCTAssertEqual(e, .budgetExhausted, "an image is about 1,600 tokens; the budget is 1,000") } else { XCTFail() }
        XCTAssertTrue(transport.requests.isEmpty, "nothing was sent")
    }
}
