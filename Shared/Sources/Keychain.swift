import CryptoKit
import Foundation
import Security
import ZulipAPI

/// The API key grants full account access, so it is kept out of defaults and stored
/// through `SecretStore`; the rest of the account lives in defaults beside it.
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
        try SecretStore.write(account.apiKey, service: service, account: account.email)
    }

    static func load() -> ZulipAccount? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let stored = try? JSONDecoder().decode(Stored.self, from: data),
              let apiKey = SecretStore.read(service: service, account: stored.email)
        else { return nil }

        return ZulipAccount(
            realmURL: stored.realmURL, email: stored.email, apiKey: apiKey, userID: stored.userID
        )
    }

    static func clear() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            SecretStore.delete(service: service, account: stored.email)
        }
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }
}

/// Where a secret goes, given what the build is actually allowed to use.
///
/// The keychain is the answer wherever the app can reach it: on iOS always, and on macOS
/// whenever the build carries a `keychain-access-groups` entitlement, which needs a real
/// provisioning profile.
///
/// A locally-built Mac app has no profile, and the two remaining options there are both
/// worse. The login keychain grants access to one exact signed binary, and every rebuild
/// produces a different one — which is why an unsigned debug build asked for the keychain
/// password on every single launch. Marking the item readable by all applications removes
/// the prompt but also removes the protection.
///
/// So an unentitled build writes the secret into the app's own sandbox container with
/// owner-only permissions instead. Inside the sandbox that is as private as the keychain
/// item would have been; outside it, any process already running as this user could read
/// either one. Nothing is given up that the prompt was protecting, and the prompt is gone.
enum SecretStore {

    static func write(_ secret: String, service: String, account: String) throws {
        delete(service: service, account: account)

        let status = SecItemAdd(
            query(service: service, account: account, extra: [
                kSecValueData as String: Data(secret.utf8),
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            ]),
            nil
        )
        if status == errSecSuccess { return }
        guard status == errSecMissingEntitlement else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        try writeToContainer(secret, service: service, account: account)
    }

    static func read(service: String, account: String) -> String? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(
            query(service: service, account: account, extra: [kSecReturnData as String: true]),
            &result
        )
        if status == errSecSuccess, let data = result as? Data {
            return String(data: data, encoding: .utf8)
        }
        guard let url = containerURL(service: service, account: account),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(service: String, account: String) {
        SecItemDelete(query(service: service, account: account))
        if let url = containerURL(service: service, account: account) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func query(
        service: String, account: String, extra: [String: Any] = [:]
    ) -> CFDictionary {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            // The login keychain is the thing being avoided, so ask for the other one
            // explicitly. Ignored on iOS, which has only this one.
            kSecUseDataProtectionKeychain as String: true,
        ]
        query.merge(extra) { _, new in new }
        return query as CFDictionary
    }

    private static func writeToContainer(
        _ secret: String, service: String, account: String
    ) throws {
        guard let url = containerURL(service: service, account: account) else {
            throw CocoaError(.fileNoSuchFile)
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(secret.utf8).write(to: url, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path(percentEncoded: false)
        )
    }

    /// One file per secret, named by a hash so an email address never lands on disk as a
    /// filename.
    private static func containerURL(service: String, account: String) -> URL? {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ) else { return nil }
        // SHA-256, not `hashValue`: Swift reseeds that per process, so the name would
        // change on every launch and the secret would look lost.
        let digest = SHA256.hash(data: Data("\(service)\u{1F}\(account)".utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return support
            .appending(path: "Zulu", directoryHint: .isDirectory)
            .appending(path: "secrets", directoryHint: .isDirectory)
            .appending(path: "\(name).key", directoryHint: .notDirectory)
    }
}
