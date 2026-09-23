import Foundation
import ZulipAPI

/// The one call the app makes to zulu-notifyd. Registering again with the same token is
/// how the service expects to hear from a device on every launch.
struct NotificationServiceClient {
    static let infoKey = "ZuluNotificationServiceURL"
    static let platform = "ios"

    #if DEBUG
    static let apnsEnvironment = "sandbox"
    #else
    static let apnsEnvironment = "production"
    #endif

    let baseURL: URL

    static var configured: NotificationServiceClient? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: infoKey) as? String,
              let url = URL(string: raw)
        else { return nil }
        return NotificationServiceClient(baseURL: url)
    }

    private struct Registration: Encodable {
        let realmUrl: String
        let email: String
        let apiKey: String
        let deviceToken: String
        let platform: String
        let environment: String
        let appVersion: String
    }

    struct Failure: LocalizedError {
        let status: Int
        let body: String
        var errorDescription: String? { "notification service answered \(status): \(body)" }
    }

    func register(account: ZulipAccount, deviceToken: String) async throws {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let registration = Registration(
            realmUrl: account.realmURL.absoluteString,
            email: account.email,
            apiKey: account.apiKey,
            deviceToken: deviceToken,
            platform: Self.platform,
            environment: Self.apnsEnvironment,
            appVersion: version ?? ""
        )

        var request = URLRequest(url: baseURL.appending(path: "v1/devices"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(registration)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw Failure(status: status, body: String(decoding: data, as: UTF8.self))
        }
    }
}
