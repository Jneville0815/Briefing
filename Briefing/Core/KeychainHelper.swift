//
//  KeychainHelper.swift
//  Briefing
//

import Foundation
import Security

struct KeychainHelper: Sendable {
    private static let service = "com.briefing.anthropic"
    private static let account = "api-key"

    func saveAPIKey(_ key: String) {
        guard let data = key.data(using: .utf8) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
        SecItemDelete(query as CFDictionary)

        var add = query
        add[kSecValueData as String] = data
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess {
            Logger.shared.error("Keychain save failed (OSStatus \(status))")
        }
    }

    func loadAPIKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status == errSecItemNotFound {
                Logger.shared.info(
                    "No API key in Keychain. Use \"Set API Key…\" from the menu bar, " +
                    "or set it via terminal: security add-generic-password -a api-key -s com.briefing.anthropic -w 'sk-ant-…'"
                )
            }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
