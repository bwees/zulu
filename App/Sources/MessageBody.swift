import SwiftUI
import ZuluMarkup

/// Renders the blocks parsed out of Zulip's `rendered_content`.
struct MessageBody: View {
    let html: String
    @Environment(AppModel.self) private var model

    /// Realm custom emoji are images. They are loaded first so the text can be built with
    /// the picture in place rather than the `:name:` fallback.
    @State private var emoji: [String: Image] = [:]

    private var blocks: [MessageBlock] { MessageMarkup.blocks(from: html) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(blocks) { block in
                BlockView(block: block, emoji: emoji)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: html) { await loadEmoji() }
    }

    private func loadEmoji() async {
        let urls = Set(blocks.flatMap(spans(in:)).compactMap(\.emojiURL))
        for url in urls where emoji[url] == nil {
            if let data = await model.imageData(at: url), let image = UIImage(data: data) {
                emoji[url] = Image(uiImage: Self.scaledToLineHeight(image))
            }
        }
    }

    /// Custom emoji arrive at whatever size they were uploaded at — often hundreds of
    /// pixels. `Text` uses an image's intrinsic size, so they have to be resized to sit
    /// on the line rather than tower over it.
    private static func scaledToLineHeight(_ image: UIImage) -> UIImage {
        let height: CGFloat = 20
        guard image.size.height > 0 else { return image }
        let width = image.size.width * (height / image.size.height)
        let size = CGSize(width: width, height: height)
        return UIGraphicsImageRenderer(size: size).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    private func spans(in block: MessageBlock) -> [InlineSpan] {
        switch block {
        case .paragraph(let spans): spans
        case .bulletList(let items), .numberedList(let items): items.flatMap { $0 }
        case .quote(let inner): inner.flatMap(spans(in:))
        case .quotedReply(_, _, let quoted): quoted.flatMap(spans(in:))
        case .codeBlock, .image: []
        }
    }
}

struct BlockView: View {
    let block: MessageBlock
    let emoji: [String: Image]

    var body: some View {
        switch block {
        case .paragraph(let spans):
            styled(spans)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .quote(let inner):
            HStack(alignment: .top, spacing: 8) {
                Capsule().fill(.tertiary).frame(width: 3)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(inner) { BlockView(block: $0, emoji: emoji) }
                }
                .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)

        case .codeBlock(let language, let code):
            VStack(alignment: .leading, spacing: 4) {
                if let language {
                    Text(language).font(.caption2).foregroundStyle(.secondary)
                }
                ScrollView(.horizontal) {
                    Text(code)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(10)
                }
                .scrollIndicators(.hidden)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

        case .bulletList(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, spans in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•")
                        styled(spans)
                    }
                }
            }

        case .numberedList(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, spans in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1).").monospacedDigit()
                        styled(spans)
                    }
                }
            }

        case .image(let source, let link, let alt):
            RemoteImage(path: source, fullSize: link, alt: alt)

        case .quotedReply(let author, _, let quoted):
            QuotedReplyView(author: author, quoted: quoted, emoji: emoji)
        }
    }

    /// Built by concatenating `Text`, which is the only way to put an image in the middle
    /// of a wrapping paragraph.
    private func styled(_ spans: [InlineSpan]) -> Text {
        spans.reduce(Text("")) { result, span in
            if let url = span.emojiURL {
                if let image = emoji[url] {
                    return result + Text(image).baselineOffset(-2)
                }
                return result + Text(span.text).foregroundColor(.secondary)
            }
            return result + text(for: span)
        }
    }

    private func text(for span: InlineSpan) -> Text {
        var attributed = AttributedString(span.text)
        if span.bold { attributed.font = .body.bold() }
        if span.italic { attributed.font = (span.bold ? Font.body.bold() : Font.body).italic() }
        if span.code {
            attributed.font = .system(.callout, design: .monospaced)
            attributed.backgroundColor = .secondary.opacity(0.18)
        }
        if span.strikethrough { attributed.strikethroughStyle = .single }
        if span.mention {
            attributed.font = .body.weight(.semibold)
            attributed.foregroundColor = .accentColor
        }
        if let link = span.link, let url = URL(string: link, relativeTo: RealmContext.realmURL) {
            attributed.link = url
        }
        return Text(attributed)
    }
}

/// The realm the app is signed into, so relative links and image paths can resolve.
enum RealmContext {
    @MainActor static var realmURL: URL?
}

/// A reply, drawn the way Discord draws one: a single compact line above the message
/// naming who is being answered and showing a taste of what they said. Tapping expands
/// it, because a one-line preview is not always enough to follow the thread.
private struct QuotedReplyView: View {
    let author: String
    let quoted: [MessageBlock]
    let emoji: [String: Image]

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrowshape.turn.up.left.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Avatar(name: author, size: 16)
                    Text(author)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if !expanded {
                        Text(preview)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if expanded {
                HStack(alignment: .top, spacing: 8) {
                    Capsule().fill(.tertiary).frame(width: 3)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(quoted) { BlockView(block: $0, emoji: emoji) }
                    }
                    .foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The first line of what was quoted, with images named rather than drawn.
    private var preview: String {
        for block in quoted {
            switch block {
            case .paragraph(let spans):
                let text = spans.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { return text }
            case .image(_, _, let alt):
                return alt ?? "Image"
            case .codeBlock(_, let code):
                return code
            case .bulletList(let items), .numberedList(let items):
                if let first = items.first { return first.map(\.text).joined() }
            case .quote, .quotedReply:
                continue
            }
        }
        return ""
    }
}
