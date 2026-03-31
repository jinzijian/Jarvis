import Foundation
import os.log
import Security

private let logger = Logger(subsystem: "com.speakflow", category: "Keychain")

/// Token storage using the macOS Keychain.
final class KeychainService {
    static let shared = KeychainService()
    private let service = Constants.keychainServiceName
    private let legacyService = "com.speakflow"
    private let legacyPrefix = "com.speakflow.token."

    private init() {
        migrateFromUserDefaultsIfNeeded()
    }

    // MARK: - Migration

    /// One-time migration from UserDefaults to Keychain.
    private func migrateFromUserDefaultsIfNeeded() {
        let defaults = UserDefaults.standard
        let migrationKey = "com.speakflow.keychainMigrated"
        guard !defaults.bool(forKey: migrationKey) else { return }

        let keys = ["access_token", "refresh_token", "expires_at", "user_email"]
        var migrated = false
        for key in keys {
            if let value = defaults.string(forKey: legacyPrefix + key) {
                save(key: key, value: value)
                migrated = true
            } else if key == "expires_at", let interval = defaults.object(forKey: legacyPrefix + key) as? Double {
                save(key: key, value: String(interval))
                migrated = true
            }
        }

        if migrated {
            logger.info("Migrated tokens from UserDefaults to Keychain")
            for key in keys {
                defaults.removeObject(forKey: legacyPrefix + key)
            }
        }
        defaults.set(true, forKey: migrationKey)
    }

    // MARK: - Token Accessors

    var accessToken: String? {
        read("access_token")
    }

    var refreshToken: String? {
        read("refresh_token")
    }

    var isTokenExpired: Bool {
        guard let raw = read("expires_at"), let interval = Double(raw) else {
            return true
        }
        return Date().timeIntervalSince1970 >= interval
    }

    func isTokenExpiringSoon(withinSeconds seconds: TimeInterval = 60) -> Bool {
        guard let raw = read("expires_at"), let interval = Double(raw) else {
            return true
        }
        return Date().addingTimeInterval(seconds).timeIntervalSince1970 >= interval
    }

    // MARK: - User Info

    var userEmail: String? {
        get { read("user_email") }
        set {
            if let value = newValue {
                save(key: "user_email", value: value)
            } else {
                delete("user_email")
            }
        }
    }

    // MARK: - Save/Delete

    func saveTokens(response: AuthResponse) {
        save(key: "access_token", value: response.access_token)
        save(key: "refresh_token", value: response.refresh_token)
        let expiresAt = Date().addingTimeInterval(Double(response.expires_in)).timeIntervalSince1970
        save(key: "expires_at", value: String(expiresAt))
        logger.info("Tokens saved (expires in \(response.expires_in)s)")
    }

    func deleteAll() {
        logger.info("Deleting all stored tokens")
        delete("access_token")
        delete("refresh_token")
        delete("expires_at")
        delete("user_email")
    }

    // MARK: - Keychain Helpers

    private func read(_ account: String) -> String? {
        if let value = read(account, service: service) {
            return value
        }

        // One-way migration from legacy service namespace.
        if service != legacyService, let legacyValue = read(account, service: legacyService) {
            save(key: account, value: legacyValue)
            delete(account, service: legacyService)
            return legacyValue
        }

        return nil
    }

    private func read(_ account: String, service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            if status != errSecItemNotFound {
                logger.error("Read failed for \(service)/\(account): \(status)")
            }
            return nil
        }
        return string
    }

    private func save(key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]

        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]

        // Update existing entry first to avoid recreating keychain ACL each refresh.
        let updateStatus = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }

        if updateStatus == errSecItemNotFound {
            let addQuery = query.merging(attrs) { _, new in new }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus != errSecSuccess {
                logger.error("Add failed for \(self.service)/\(key): \(addStatus)")
            }
            return
        }

        // If ACL got stale after identity changes, recreate once.
        if updateStatus == errSecAuthFailed || updateStatus == errSecInteractionNotAllowed {
            delete(key, service: service)
            let addQuery = query.merging(attrs) { _, new in new }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus != errSecSuccess {
                logger.error("Recreate failed for \(self.service)/\(key): update=\(updateStatus), add=\(addStatus)")
            }
            return
        }

        logger.error("Update failed for \(self.service)/\(key): \(updateStatus)")
    }

    private func delete(_ account: String) {
        delete(account, service: service)
        if service != legacyService {
            delete(account, service: legacyService)
        }
    }

    private func delete(_ account: String, service: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            logger.error("Delete failed for \(service)/\(account): \(status)")
        }
    }
}
