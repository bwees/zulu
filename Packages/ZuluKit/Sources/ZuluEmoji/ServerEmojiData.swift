import Foundation

/// The server's unicode emoji table, served as a static JSON file at the
/// `server_emoji_data_url` the register snapshot reports.
///
/// Shipping a copy instead would drift: the server rejects any name its own table does
/// not know, so the table has to come from the server that will validate against it.
public struct ServerEmojiData: Codable, Sendable, Equatable {
    /// Emoji code to its names. The canonical name is at index 0 and everything after
    /// it is an alias — including the CLDR keywords, which is why searching aliases
    /// gives keyword search for nothing.
    public let codeToNames: [String: [String]]

    enum CodingKeys: String, CodingKey {
        case codeToNames = "code_to_names"
    }

    public init(codeToNames: [String: [String]]) {
        self.codeToNames = codeToNames
    }
}

/// One fetch of the table, conditional on an ETag.
public struct ServerEmojiDataFetch: Sendable {
    /// `nil` when the server answered 304 and the cached copy is still current.
    public let data: ServerEmojiData?
    public let etag: String?

    public init(data: ServerEmojiData?, etag: String?) {
        self.data = data
        self.etag = etag
    }

    /// Fetches the table without credentials.
    ///
    /// The URL is a Django staticfiles path that may point off the realm entirely when
    /// the deployment serves static files from a CDN, so the account's API key must not
    /// ride along. The file is also outside Zulip's `{result, msg}` envelope, so a
    /// failure here looks nothing like an API error.
    public static func fetch(
        from url: URL,
        etag: String? = nil,
        userAgent: String,
        session: URLSession = .shared
    ) async throws -> ServerEmojiDataFetch {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }

        let (body, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        let newETag = http?.value(forHTTPHeaderField: "ETag") ?? etag

        if http?.statusCode == 304 {
            return ServerEmojiDataFetch(data: nil, etag: newETag)
        }
        let decoded = try JSONDecoder().decode(ServerEmojiData.self, from: body)
        return ServerEmojiDataFetch(data: decoded, etag: newETag)
    }
}
