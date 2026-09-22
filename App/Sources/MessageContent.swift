import Foundation
import SwiftUI

/// Zulip renders markdown server-side and the client is expected to display that HTML.
///
/// This converts it with the system's HTML importer, which is a stopgap: it is slow, it
/// drops Zulip-specific structure like spoilers and code-block languages, and the research
/// says a native parse of `rendered_content` into a view tree is what the real client needs.
/// Good enough to read messages with; not what ships.
enum MessageContent {

    @MainActor private static var cache: [Int: AttributedString] = [:]

    @MainActor
    static func attributed(html: String, messageID: Int) -> AttributedString {
        if let cached = cache[messageID] { return cached }

        let styled = """
            <style>body{font-family:-apple-system;font-size:16px;} \
            code{font-family:ui-monospace;font-size:15px;}</style>\(html)
            """
        guard let data = styled.data(using: .utf8),
              let ns = try? NSAttributedString(
                  data: data,
                  options: [.documentType: NSAttributedString.DocumentType.html,
                            .characterEncoding: String.Encoding.utf8.rawValue],
                  documentAttributes: nil
              )
        else {
            let fallback = AttributedString(stripTags(html))
            cache[messageID] = fallback
            return fallback
        }

        var result = AttributedString(ns)
        result.foregroundColor = nil
        cache[messageID] = result
        return result
    }

    /// Last resort when the importer fails, so a message is never simply blank.
    static func stripTags(_ html: String) -> String {
        var output = ""
        var insideTag = false
        for character in html {
            switch character {
            case "<": insideTag = true
            case ">": insideTag = false
            default: if !insideTag { output.append(character) }
            }
        }
        return output
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
