import Foundation
import Security
import ZulipAPI

/// The API key grants full account access, so it lives in the keychain and the rest of
/// the account lives in defaults beside it.
enum AccountStorage {
    private static let service = "com.bwees.zulu.apikey"
    private static let defaultsKey = "com.bwees.zulu.account"

    private struct Stored: Codable {
        let realmURL: URL
        let email: String
        let userID: Int
    }

    static func save(_ account: ZulipAccount) throws {
        let stored = Stored(realmURL: account.realmURL, email: account.email, userID: account.userID)
        UserDefaults.standard.set(try JSONEncoder().encode(stored), forKey: defaultsKey)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.email,
        ]
        SecItemDelete(query as CFDictionary)

        var insert = query
        insert[kSecValueData as String] = Data(account.apiKey.utf8)
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(insert as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    static func load() -> ZulipAccount? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let stored = try? JSONDecoder().decode(Stored.self, from: data)
        else { return nil }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: stored.email,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let keyData = result as? Data,
              let apiKey = String(data: keyData, encoding: .utf8)
        else { return nil }

        return ZulipAccount(
            realmURL: stored.realmURL, email: stored.email, apiKey: apiKey, userID: stored.userID
        )
    }

    static func clear() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: stored.email,
            ] as CFDictionary)
        }
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }
}
