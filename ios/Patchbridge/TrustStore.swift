import Foundation
import Security

/// Mac-issued trust tokens by Mac ID, kept in the Keychain on this device only.
/// A token stops working when its Mac revokes trust.
enum TrustStore {
    private static let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                               kSecAttrService as String: "com.arjunakankipati.patchbridge.trust",
                                               kSecAttrAccount as String: "macs"]
    static func load() -> [String: String] {
        var item: CFTypeRef?
        var search = query; search[kSecReturnData as String] = true
        guard SecItemCopyMatching(search as CFDictionary, &item) == errSecSuccess, let data = item as? Data,
              let tokens = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return tokens
    }
    static func save(_ tokens: [String: String]) {
        SecItemDelete(query as CFDictionary)
        guard !tokens.isEmpty, let data = try? JSONEncoder().encode(tokens) else { return }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }
}
