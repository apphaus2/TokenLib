//
//  TokenLibModel.swift
//  TokenLibApple
//
//  What a host app holds: `TokenLib.standard(appId:)` builds a server in the
//  app's private storage with the Keychain cipher, and `TokenLibModel` wraps a
//  server as an observable object for settings screens (TokenLibUI's or the
//  app's own).
//

import Foundation
import TokenLib
#if canImport(Combine)
import Combine

public enum TokenLibBootstrap {
    /// The database file and Keychain service suffix from before the rename to TokenLib. An install that
    /// still has them is moved over on its first launch after the update; see `standard(appId:transport:)`.
    public static let legacyDatabase = "tokenx.sqlite"
    public static let legacyKeySuffix = ".tokenx"

    /// A server backed by `Application Support/<appId>/tokenlib.sqlite` and a Keychain-held cipher key
    /// (service `<appId>.tokenlib`). Falls back to an in-memory store if the file cannot be opened, so the
    /// app keeps running. Data left under the TokenX names is moved first: the database file is renamed,
    /// stored keys are re-encrypted with the new cipher key, and the old Keychain item is removed once
    /// every key reads back, so a launch that cannot reach the Keychain retries next time.
    public static func standard(appId: String, transport: HttpTransport = URLSessionTransport()) -> TokenServer {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent(appId, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("tokenlib.sqlite").path
        _ = try? SQLiteStore.moveDatabase(from: directory.appendingPathComponent(legacyDatabase).path, to: path)
        let store: TokenStore = (try? SQLiteStore(path: path)) ?? InMemoryStore()
        #if canImport(CryptoKit) && canImport(Security)
        let cipher: SecretCipher = KeychainCipher(service: appId + ".tokenlib")
        let server = TokenServer(store: store, cipher: cipher, transport: transport)
        let legacy = KeychainCipher(service: appId + legacyKeySuffix)
        if legacy.hasKey {
            _ = try? server.reencryptKeys(from: legacy)
            if server.keysReadable { try? legacy.deleteKey() }
        }
        #else
        let server = TokenServer(store: store, cipher: PlainCipher(), transport: transport)
        #endif
        registerPlatformProviders(on: server)
        return server
    }

    /// Registers the providers this platform answers in-process: Apple's on-device model (`ProviderKind.apple`)
    /// where the Foundation Models framework exists (iOS 26, macOS 26, visionOS 26). `standard` calls this;
    /// an app that composes its own server calls it once after construction.
    public static func registerPlatformProviders(on server: TokenServer) {
        #if canImport(FoundationModels) && (os(iOS) || os(macOS) || os(visionOS))
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) { server.nativeProviders[.apple] = AppleProvider() }
        #endif
    }
}

/// The server as an observable object: settings, configured providers, today's usage, and the commands a settings screen needs.
@MainActor
public final class TokenLibModel: ObservableObject {
    public let server: TokenServer
    public let client: TokenClient

    @Published public private(set) var settings: Settings
    @Published public private(set) var configured: [ProviderKind] = []
    @Published public private(set) var usageToday = UsageTotals()
    /// Tokens left under the daily cap today; `nil` when there is no cap.
    @Published public private(set) var remainingToday: Int?
    /// The credit entered for the active provider and what is left of it; `nil` when none was entered.
    @Published public private(set) var credit: Credit?
    @Published public private(set) var recent: [UsageRecord] = []
    @Published public var lastError: String?

    public init(server: TokenServer) {
        self.server = server
        self.client = TokenClient(broker: server)
        self.settings = server.settings
        refresh()
    }

    /// `TokenLib.standard(appId:)` wrapped in a model.
    public convenience init(appId: String) { self.init(server: TokenLibBootstrap.standard(appId: appId)) }

    public var isReady: Bool { server.isReady }
    public var isEnabled: Bool { settings.enabled }
    public var activeProvider: ProviderKind? { settings.activeProvider }
    /// The kinds to offer on this device (`TokenServer.availableProviders`).
    public var availableProviders: [ProviderKind] { server.availableProviders }
    /// Why a native provider cannot answer right now, for the settings footer; `nil` when it can.
    public func unavailableReason(for provider: ProviderKind) -> String? { server.unavailableReason(for: provider) }

    /// The model a profile runs on right now, for display.
    public func modelName(for profile: Profile) -> String? { server.model(for: profile).map { "\($0.name) (\($0.provider.displayName))" } }

    public func hasKey(_ provider: ProviderKind) -> Bool { configured.contains(provider) }

    public func refresh() {
        settings = server.settings
        configured = server.configuredProviders
        usageToday = server.usageToday()
        remainingToday = server.remainingToday()
        credit = server.credit()
        recent = server.recentUsage(limit: 20)
    }

    /// Stores the key (when given) and makes the provider active.
    public func activate(_ provider: ProviderKind, key: String? = nil) {
        run { try server.activate(provider, key: key?.isEmpty == false ? key : nil) }
    }

    public func removeKey(for provider: ProviderKind) { run { try server.setKey(nil, for: provider) } }

    /// The master switch: off means no request is sent anywhere.
    public func setEnabled(_ on: Bool) { run { try server.setEnabled(on) } }

    public func update(_ change: (inout Settings) -> Void) { run { try server.update(change) } }

    public func setLocalServer(url: String?, model: String?) {
        run { try server.update { $0.localBaseURL = url?.isEmpty == false ? url : nil; $0.localModel = model?.isEmpty == false ? model : nil } }
    }

    /// The balance read off the provider's billing page, in dollars; `nil` or zero forgets it.
    public func setCredit(_ dollars: Double?, for provider: ProviderKind) {
        run { try server.setCredit(dollars.map { Int64(($0 * 1_000_000).rounded()) }, for: provider) }
    }

    public func clearUsage() { run { try server.store.deleteAll() } }

    private func run(_ body: () throws -> Void) {
        do { try body(); lastError = nil } catch { lastError = "\(error)" }
        refresh()
    }
}
#endif
