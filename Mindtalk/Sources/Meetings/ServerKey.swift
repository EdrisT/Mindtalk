import Foundation
import os

// MARK: - A server's API key
//
// oMLX keeps its model list, its load calls and its answers behind an API key; Ollama
// and LM Studio never ask for one, so for them this stays empty. The key goes to the
// login Keychain and nowhere else: the settings file is plain text, and a key written
// there would lie next to everything it guards.
//
// Read once per run and kept in memory, so a summary doesn't ask the Keychain for
// every token. Typing it in (or clearing it) updates that copy straight away.

enum ServerKey {
    nonisolated(unsafe) private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: String?] = [:]
    private static let service = "ai.mindact.mindtalk.server"
    private static let log = Logger(subsystem: "ai.mindact.mindtalk", category: "ServerKey")

    /// The key to send, or nil when the backend doesn't have one.
    static func key(_ backend: ServerBackend) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[backend.rawValue] { return cached }
        var query = base(backend)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var found: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &found)
        guard status == errSecSuccess, let data = found as? Data,
              let value = String(data: data, encoding: .utf8), !value.isEmpty else {
            cache[backend.rawValue] = nil
            return nil
        }
        cache[backend.rawValue] = value
        return value
    }

    static func isSet(_ backend: ServerBackend) -> Bool { key(backend) != nil }

    /// Saves what was typed; an empty field means the key is removed.
    static func set(_ backend: ServerBackend, _ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { clear(backend); return }
        remember(backend, trimmed)
        guard !Settings.previewing else { return }
        var attributes = base(backend)
        let update: [String: Any] = [kSecValueData as String: Data(trimmed.utf8)]
        var status = SecItemUpdate(attributes as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            attributes[kSecValueData as String] = Data(trimmed.utf8)
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(attributes as CFDictionary, nil)
        }
        if status != errSecSuccess {
            log.error("could not save the key for \(backend.name, privacy: .public): \(status, privacy: .public)")
        }
    }

    static func clear(_ backend: ServerBackend) {
        remember(backend, nil)
        guard !Settings.previewing else { return }
        let status = SecItemDelete(base(backend) as CFDictionary)
        if status != errSecSuccess, status != errSecItemNotFound {
            log.error("could not remove the key for \(backend.name, privacy: .public): \(status, privacy: .public)")
        }
    }

    /// What this run holds, after a write or a failed read.
    private static func remember(_ backend: ServerBackend, _ value: String?) {
        lock.lock()
        cache[backend.rawValue] = value
        lock.unlock()
    }

    private static func base(_ backend: ServerBackend) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: backend.rawValue,
         kSecUseDataProtectionKeychain as String: kCFBooleanTrue as Any]
    }
}
