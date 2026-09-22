import Foundation

public struct UploadedFile: Sendable, Equatable {
    /// Realm-relative, e.g. `/user_uploads/2/ab/xyz/photo.jpg`.
    public let path: String
    public let filename: String

    /// Zulip embeds uploads as ordinary markdown. Images get the image form, which only
    /// works for files already uploaded to the realm.
    public func markdown(isImage: Bool) -> String {
        "\(isImage ? "!" : "")[\(filename)](\(path))"
    }
}

private struct UploadResponse: Decodable {
    /// `url` arrived at feature level 272; `uri` is the older spelling still sent by
    /// every server that predates it.
    let url: String?
    let uri: String?
    let filename: String?
}

extension ZulipClient {

    public func upload(
        _ data: Data,
        filename: String,
        contentType: String
    ) async throws -> UploadedFile {
        let boundary = "zulu.\(UUID().uuidString)"
        var body = Data()

        func append(_ text: String) { body.append(Data(text.utf8)) }

        append("--\(boundary)\r\n")
        // The server takes whichever single file is attached; the field name is ignored.
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: \(contentType)\r\n\r\n")
        body.append(data)
        append("\r\n--\(boundary)--\r\n")

        let url = realmURL.appending(path: "api/v1/user_uploads")
        var request = URLRequest(url: url, timeoutInterval: 300)
        request.httpMethod = "POST"
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let account {
            let pair = "\(account.email):\(account.apiKey)"
            request.setValue("Basic \(Data(pair.utf8).base64EncodedString())", forHTTPHeaderField: "Authorization")
        }

        let responseData: Data
        do {
            (responseData, _) = try await URLSession.shared.upload(for: request, from: body)
        } catch {
            throw ZulipError(kind: .transport, message: error.localizedDescription)
        }

        if let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: responseData),
           envelope.result == "error" {
            throw ZulipError.api(
                code: envelope.code ?? "BAD_REQUEST",
                status: 400,
                message: envelope.msg ?? "The upload was rejected."
            )
        }

        guard let decoded = try? JSONDecoder().decode(UploadResponse.self, from: responseData),
              let path = decoded.url ?? decoded.uri
        else {
            throw ZulipError(kind: .decoding, message: "The server's upload reply could not be read.")
        }
        return UploadedFile(path: path, filename: decoded.filename ?? filename)
    }
}

struct ErrorEnvelope: Decodable {
    let result: String
    let msg: String?
    let code: String?
}
