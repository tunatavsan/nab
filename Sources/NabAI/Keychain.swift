import Foundation
import NabCore
import Security

/// API keys live in the login keychain, one item per provider, never in defaults.
public enum Keychain {
    /// `dev.tavsan.nab`, or `$NAB_KEYCHAIN_SERVICE` when set, so test builds never see or change the real keys.
    public static let service = service(in: ProcessInfo.processInfo.environment)

    static func service(in environment: [String: String]) -> String {
        guard let custom = environment["NAB_KEYCHAIN_SERVICE"], !custom.isEmpty else { return "dev.tavsan.nab" }
        return custom
    }

    public static func key(for kind: ProviderKind) -> String? {
        var query = base(kind)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Replaces the stored key; an empty value removes it.
    public static func setKey(_ value: String, for kind: ProviderKind) throws {
        let deleted = SecItemDelete(base(kind) as CFDictionary)
        guard deleted == errSecSuccess || deleted == errSecItemNotFound else { throw failure(deleted) }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var item = base(kind)
        item[kSecValueData as String] = Data(trimmed.utf8)
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw failure(added) }
    }

    private static func failure(_ status: OSStatus) -> NabError {
        let reason = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
        return NabError("The keychain refused the key: \(reason)")
    }

    private static func base(_ kind: ProviderKind) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: kind.rawValue,
        ]
    }
}
