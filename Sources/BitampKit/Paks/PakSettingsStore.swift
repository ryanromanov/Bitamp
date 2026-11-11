import BitampPakProtocol
import Foundation
import Security

/// Where a third-party Pak's settings live: plain ones in UserDefaults, passwords in the
/// Keychain. Paks get them all in their `hello` and `configure` requests.
@MainActor
class PakSettingsStore {
    private let defaults: UserDefaults
    /// Passwords already read, so asking for settings every frame doesn't go to the Keychain.
    private var secrets: [String: String?] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Every setting the manifest lists, filled in from what's saved or its default.
    func values(for manifest: PakManifest) -> [String: String] {
        var values: [String: String] = [:]
        let saved = defaults.dictionary(forKey: Self.key(manifest.id)) as? [String: String] ?? [:]
        for setting in manifest.settings ?? [] {
            let value = setting.kind == .password ? rememberedSecret(manifest.id, setting.key) : saved[setting.key]
            if let value = value ?? setting.defaultValue { values[setting.key] = value }
        }
        return values
    }

    /// A plain setting as saved, without its default.
    func savedValue(_ key: String, for id: String) -> String? {
        (defaults.dictionary(forKey: Self.key(id)) as? [String: String])?[key]
    }

    func save(_ values: [String: String], for manifest: PakManifest) {
        var plain: [String: String] = [:]
        for setting in manifest.settings ?? [] {
            guard let value = values[setting.key] else { continue }
            if setting.kind == .password {
                secrets["\(manifest.id)/\(setting.key)"] = nil
                setSecret(value, manifest.id, setting.key)
            } else {
                plain[setting.key] = value
            }
        }
        defaults.set(plain, forKey: Self.key(manifest.id))
    }

    /// Forgets everything, for a Pak being removed.
    func remove(_ manifest: PakManifest) {
        defaults.removeObject(forKey: Self.key(manifest.id))
        for setting in manifest.settings ?? [] where setting.kind == .password {
            secrets["\(manifest.id)/\(setting.key)"] = nil
            setSecret(nil, manifest.id, setting.key)
        }
    }

    private static func key(_ id: String) -> String { "pakSettings.\(id)" }

    // MARK: - Keychain

    private func rememberedSecret(_ pak: String, _ key: String) -> String? {
        let id = "\(pak)/\(key)"
        if let known = secrets[id] { return known }
        let value = secret(pak, key)
        secrets[id] = .some(value)
        return value
    }

    /// Passwords, one generic Keychain item per setting. Overridden in tests.
    func secret(_ pak: String, _ key: String) -> String? {
        var query = Self.query(pak, key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func setSecret(_ value: String?, _ pak: String, _ key: String) {
        let query = Self.query(pak, key)
        SecItemDelete(query as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        let status = SecItemAdd(item as CFDictionary, nil)
        if status != errSecSuccess { NSLog("Bitamp: couldn't save a password for the \(pak) Pak (\(status))") }
    }

    private static func query(_ pak: String, _ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "Bitamp Pak \(pak)",
         kSecAttrAccount as String: key]
    }
}
