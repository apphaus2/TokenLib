//
//  KeychainCipher.swift
//  TokenLibApple
//
//  AES-GCM at rest for API keys: the symmetric key lives in the Keychain
//  (device only, not backed up), the ciphertext in the SQLite store.
//

import Foundation
import TokenLib
#if canImport(CryptoKit) && canImport(Security)
import CryptoKit
import Security

public final class KeychainCipher: SecretCipher {
    public enum KeychainError: Error { case status(OSStatus) }

    private let service: String
    private let account: String
    private var cached: SymmetricKey?
    private let lock = NSLock()

    /// `service` and `account` name the Keychain item that holds the 256-bit key.
    public init(service: String = "us.apphaus.tokenlib", account: String = "secret-key") {
        self.service = service; self.account = account
    }

    /// Whether the Keychain item exists, without creating it (encrypting or decrypting creates it on first use).
    public var hasKey: Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// Removes the Keychain item. Anything encrypted with it can no longer be read.
    public func deleteKey() throws {
        lock.lock(); defer { lock.unlock() }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) }
        cached = nil
    }

    public func encrypt(_ plaintext: Data) throws -> Data {
        let sealed = try AES.GCM.seal(plaintext, using: try key())
        guard let combined = sealed.combined else { throw KeychainError.status(errSecParam) }
        return combined
    }

    public func decrypt(_ ciphertext: Data) throws -> Data {
        try AES.GCM.open(try AES.GCM.SealedBox(combined: ciphertext), using: try key())
    }

    private func key() throws -> SymmetricKey {
        lock.lock(); defer { lock.unlock() }
        if let k = cached { return k }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecReturnData as String: true]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data {
            let k = SymmetricKey(data: data)
            cached = k
            return k
        }
        guard status == errSecItemNotFound else { throw KeychainError.status(status) }
        let k = SymmetricKey(size: .bits256)
        let data = k.withUnsafeBytes { Data($0) }
        let add: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
                                  kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else { throw KeychainError.status(added) }
        cached = k
        return k
    }
}
#endif
