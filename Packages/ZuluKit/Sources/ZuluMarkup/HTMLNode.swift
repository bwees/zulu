import Foundation

/// A very small HTML reader, scoped to what Zulip's markdown pipeline emits.
/// It is not a general parser: unknown elements keep their children and lose themselves,
/// which is how the client survives a server that renders something it has never seen.
enum HTMLNode {
    case text(String)
    case element(Element)

    struct Element {
        let name: String
        let attributes: [String: String]
        let children: [HTMLNode]

        func attribute(_ key: String) -> String? { attributes[key] }

        var classes: [String] {
            (attributes["class"] ?? "").split(separator: " ").map(String.init)
        }
    }
}

enum HTMLParser {

    /// Elements that never have a closing tag.
    private static let voidElements: Set<String> = ["br", "img", "hr", "input", "meta", "link"]

    static func parse(_ html: String) -> [HTMLNode] {
        var scanner = Scanner(html)
        return scanner.parseNodes(until: nil)
    }

    private struct Scanner {
        let characters: [Character]
        var index = 0

        init(_ html: String) { characters = Array(html) }

        var isAtEnd: Bool { index >= characters.count }

        mutating func parseNodes(until closingTag: String?) -> [HTMLNode] {
            var nodes: [HTMLNode] = []
            while !isAtEnd {
                if characters[index] == "<" {
                    if peekIsClosingTag() {
                        let name = readClosingTag()
                        // A stray close for something else is dropped rather than
                        // unwinding the whole document.
                        if name == closingTag { return nodes }
                        continue
                    }
                    if let element = readElement() {
                        nodes.append(.element(element))
                    }
                } else {
                    let text = readText()
                    if !text.isEmpty { nodes.append(.text(text)) }
                }
            }
            return nodes
        }

        private func peekIsClosingTag() -> Bool {
            index + 1 < characters.count && characters[index + 1] == "/"
        }

        private mutating func readClosingTag() -> String {
            index += 2 // "</"
            var name = ""
            while !isAtEnd, characters[index] != ">" {
                name.append(characters[index])
                index += 1
            }
            if !isAtEnd { index += 1 }
            return name.trimmingCharacters(in: .whitespaces).lowercased()
        }

        private mutating func readText() -> String {
            var text = ""
            while !isAtEnd, characters[index] != "<" {
                text.append(characters[index])
                index += 1
            }
            return HTMLEntities.decode(text)
        }

        private mutating func readElement() -> HTMLNode.Element? {
            index += 1 // "<"
            var name = ""
            while !isAtEnd, !characters[index].isWhitespace, characters[index] != ">", characters[index] != "/" {
                name.append(characters[index])
                index += 1
            }
            name = name.lowercased()

            var attributes: [String: String] = [:]
            var selfClosing = false

            while !isAtEnd, characters[index] != ">" {
                if characters[index] == "/" {
                    selfClosing = true
                    index += 1
                    continue
                }
                if characters[index].isWhitespace {
                    index += 1
                    continue
                }
                let (key, value) = readAttribute()
                if !key.isEmpty { attributes[key] = value }
            }
            if !isAtEnd { index += 1 } // ">"

            guard !name.isEmpty else { return nil }
            if selfClosing || voidElements.contains(name) {
                return .init(name: name, attributes: attributes, children: [])
            }
            let children = parseNodes(until: name)
            return .init(name: name, attributes: attributes, children: children)
        }

        private mutating func readAttribute() -> (String, String) {
            var key = ""
            while !isAtEnd, !characters[index].isWhitespace, characters[index] != "=", characters[index] != ">" {
                key.append(characters[index])
                index += 1
            }
            guard !isAtEnd, characters[index] == "=" else { return (key.lowercased(), "") }
            index += 1

            var value = ""
            if !isAtEnd, characters[index] == "\"" || characters[index] == "'" {
                let quote = characters[index]
                index += 1
                while !isAtEnd, characters[index] != quote {
                    value.append(characters[index])
                    index += 1
                }
                if !isAtEnd { index += 1 }
            } else {
                while !isAtEnd, !characters[index].isWhitespace, characters[index] != ">" {
                    value.append(characters[index])
                    index += 1
                }
            }
            return (key.lowercased(), HTMLEntities.decode(value))
        }
    }
}

enum HTMLEntities {
    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "mdash": "—", "ndash": "–", "hellip": "…", "copy": "©", "reg": "®", "trade": "™",
    ]

    static func decode(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var output = ""
        var iterator = text.startIndex

        while iterator < text.endIndex {
            guard text[iterator] == "&",
                  let semicolon = text[iterator...].firstIndex(of: ";"),
                  text.distance(from: iterator, to: semicolon) <= 10
            else {
                output.append(text[iterator])
                iterator = text.index(after: iterator)
                continue
            }

            let body = String(text[text.index(after: iterator)..<semicolon])
            if let replacement = named[body] {
                output.append(replacement)
            } else if body.hasPrefix("#x") || body.hasPrefix("#X"),
                      let value = UInt32(body.dropFirst(2), radix: 16),
                      let scalar = Unicode.Scalar(value) {
                output.append(Character(scalar))
            } else if body.hasPrefix("#"),
                      let value = UInt32(body.dropFirst()),
                      let scalar = Unicode.Scalar(value) {
                output.append(Character(scalar))
            } else {
                output.append(contentsOf: text[iterator...semicolon])
            }
            iterator = text.index(after: semicolon)
        }
        return output
    }
}
