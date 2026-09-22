import Foundation

public struct ExternalAuthMethod: Decodable, Sendable, Identifiable, Equatable {
    public let name: String
    public let display_name: String
    public let display_icon: String?
    public let login_url: String

    public var id: String { name }
}

public struct ServerSettings: Decodable, Sendable, Equatable {
    /// Realm-specific keys are absent when the request hits the root domain of a
    /// multi-realm server, so everything below the version fields is optional.
    public let zulip_version: String
    public let zulip_feature_level: Int
    public let realm_url: URL?
    public let realm_uri: URL?
    public let realm_name: String?
    public let realm_icon: String?
    public let email_auth_enabled: Bool?
    public let require_email_format_usernames: Bool?
    public let external_authentication_methods: [ExternalAuthMethod]?
    public let authentication_methods: [String: Bool]?
    public let push_notifications_enabled: Bool?

    /// `realm_uri` is the pre-9.0 spelling; new servers send `realm_url`.
    public func canonicalURL(fallback: URL) -> URL { realm_url ?? realm_uri ?? fallback }

    public var passwordAuthEnabled: Bool {
        (email_auth_enabled ?? false) || (authentication_methods?["ldap"] ?? false)
    }

    public var usernameIsEmail: Bool { require_email_format_usernames ?? true }

    public var externalMethods: [ExternalAuthMethod] { external_authentication_methods ?? [] }
}

private struct FetchAPIKeyResponse: Decodable {
    let api_key: String
    let email: String
    let user_id: Int
}

extension ZulipClient {

    /// Normalises what someone typed into a URL worth trying. Rejects anything that is not
    /// plain http(s), including the `zulip:` scheme and URLs carrying userinfo.
    public static func parseRealmURL(_ input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host() != nil,
              url.user() == nil, url.password() == nil
        else { return nil }
        return url
    }

    public static func serverSettings(realmURL: URL, session: URLSession = .shared) async throws -> ServerSettings {
        try await ZulipClient(realmURL: realmURL, session: session)
            .send(.get, "server_settings", as: ServerSettings.self)
    }

    /// Password and LDAP sign-in. Unauthenticated: no key exists yet.
    public static func signIn(
        realmURL: URL,
        username: String,
        password: String,
        session: URLSession = .shared
    ) async throws -> ZulipAccount {
        let response: FetchAPIKeyResponse = try await ZulipClient(realmURL: realmURL, session: session)
            .send(.post, "fetch_api_key", parameters: ["username": username, "password": password])
        return ZulipAccount(
            realmURL: realmURL,
            email: response.email,
            apiKey: response.api_key,
            userID: response.user_id
        )
    }
}

/// The browser round-trip Zulip uses for every external auth backend — SAML, OIDC, and
/// REMOTE_USER SSO all arrive through it. Undocumented upstream; read off the server.
public enum WebAuth {

    /// A 32-byte one-time pad, hex-encoded. The server rejects anything that is not
    /// exactly 64 hex characters.
    public static func generateOTP() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        for i in bytes.indices { bytes[i] = UInt8.random(in: .min ... .max) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    public static func authURL(realmURL: URL, method: ExternalAuthMethod, otp: String) -> URL? {
        guard let base = URL(string: method.login_url, relativeTo: realmURL) else { return nil }
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: true) else { return nil }
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "mobile_flow_otp", value: otp)]
        return components.url
    }

    public struct Payload: Sendable, Equatable {
        public let encryptedAPIKey: String
        public let email: String
        public let userID: Int
        public let realm: URL
    }

    /// The server redirects to `zulip://login?...`. The callback is attacker-reachable, so
    /// every field is validated and the realm is checked against the one being signed into.
    public static func parse(callback: URL) -> Payload? {
        guard callback.scheme?.lowercased() == "zulip", callback.host()?.lowercased() == "login",
              let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems
        else { return nil }

        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        guard let key = value("otp_encrypted_api_key"),
              key.count == 64,
              key.allSatisfy(\.isHexDigit),
              let email = value("email"),
              let userIDText = value("user_id"), let userID = Int(userIDText),
              let realmText = value("realm"), let realm = URL(string: realmText)
        else { return nil }

        return Payload(encryptedAPIKey: key, email: email, userID: userID, realm: realm)
    }

    /// The key is XORed with the pad as hex-encoded ASCII. The pad never leaves the device,
    /// so an app that merely intercepts the callback learns nothing.
    public static func decrypt(_ payload: Payload, otp: String) -> String? {
        guard payload.encryptedAPIKey.count == otp.count else { return nil }
        let a = Array(payload.encryptedAPIKey)
        let b = Array(otp)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(a.count / 2)
        var i = 0
        while i < a.count - 1 {
            guard let x = UInt8(String(a[i...i + 1]), radix: 16),
                  let y = UInt8(String(b[i...i + 1]), radix: 16)
            else { return nil }
            bytes.append(x ^ y)
            i += 2
        }
        return String(bytes: bytes, encoding: .ascii)
    }

    public static func account(from payload: Payload, otp: String, realmURL: URL) -> ZulipAccount? {
        guard payload.realm.host() == realmURL.host() else { return nil }
        guard let key = decrypt(payload, otp: otp) else { return nil }
        return ZulipAccount(realmURL: realmURL, email: payload.email, apiKey: key, userID: payload.userID)
    }
}
