import Foundation
import os
import Security

struct StoredCredentials: Codable, Equatable {
    var refreshToken: String
    var accessToken: String?
    var accessTokenExpiry: Date?
    var email: String?
    var grantedScopes: String?

    var hasUsableAccessToken: Bool {
        guard accessToken != nil, let expiry = accessTokenExpiry else { return false }
        // Refresh a minute early so a request never races the expiry.
        return expiry.timeIntervalSinceNow > 60
    }
}

/// Persists the Google refresh token.
///
/// Prefers the Keychain. Locally-signed builds (no Developer ID / team) can be denied
/// a keychain access group, so a 0600 file inside the app's own container is used as a
/// fallback rather than leaving the user unable to stay signed in.
final class TokenStore {
    static let shared = TokenStore()

    private let service = "com.valorstudio.MeetingMinder.google-oauth"
    private let account = "default"
    private let lock = NSLock()

    private(set) var isUsingFileFallback = false

    private init() {}

    // MARK: - Public API

    func load() -> StoredCredentials? {
        lock.lock()
        defer { lock.unlock() }

        if let data = keychainRead(), let creds = decode(data) {
            return creds
        }
        if let data = try? Data(contentsOf: fallbackURL), let creds = decode(data) {
            isUsingFileFallback = true
            return creds
        }
        return nil
    }

    func save(_ credentials: StoredCredentials) {
        lock.lock()
        defer { lock.unlock() }

        guard let data = try? JSONEncoder().encode(credentials) else { return }

        if keychainWrite(data) {
            isUsingFileFallback = false
            try? FileManager.default.removeItem(at: fallbackURL)
        } else {
            isUsingFileFallback = true
            writeFallback(data)
        }
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        try? FileManager.default.removeItem(at: fallbackURL)
        isUsingFileFallback = false
    }

    // MARK: - Keychain

    private func keychainRead() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            if status != errSecItemNotFound {
                Log.auth.error("Keychain read failed: \(status, privacy: .public)")
            }
            return nil
        }
        return item as? Data
    }

    private func keychainWrite(_ data: Data) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }

        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery.merge(attributes) { current, _ in current }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus == errSecSuccess { return true }
            Log.auth.error("Keychain add failed: \(addStatus, privacy: .public) — using file fallback")
            return false
        }

        Log.auth.error("Keychain update failed: \(updateStatus, privacy: .public) — using file fallback")
        return false
    }

    // MARK: - File fallback

    private var fallbackURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("Meeting Minder", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return dir.appendingPathComponent("credentials.json")
    }

    private func writeFallback(_ data: Data) {
        let url = fallbackURL
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            Log.auth.error("Could not persist credentials: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func decode(_ data: Data) -> StoredCredentials? {
        try? JSONDecoder().decode(StoredCredentials.self, from: data)
    }
}
