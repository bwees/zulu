import SwiftUI
import ZuluMarkup

/// Renders the blocks parsed out of Zulip's `rendered_content`.
struct MessageBody: View {
    let html: String
    @Environment(AppModel.self) private var model

    /// Realm custom emoji are images. They are loaded first so the text can be built with
    /// the picture in place rather than the `:name:` fallback.
    @State private var emoji: [String: EmojiFrames] = [:]

    /// Custom emoji arrive at whatever size they were uploaded at — often hundreds of
    /// pixels. `Text` uses an image's intrinsic size, so they are scaled to sit on the
    /// line rather than tower over it.
    private static let lineHeight: CGFloat = 20

    /// Fast enough that nothing looks like a slideshow, slow enough that a message full
    /// of emoji is not redrawn at display rate.
    private static let tick: TimeInterval = 1.0 / 15

    private var blocks: [MessageBlock] { MessageMarkup.blocks(from: html) }

    var body: some View {
        Group {
            // Redrawing on a clock is only worth it when something in here moves. An
            // animated emoji cannot live in a `Text`, so the paragraph around it is
            // rebuilt each tick with the frame for that moment.
            if emoji.values.contains(where: \.isAnimated) {
                TimelineView(.periodic(from: .now, by: Self.tick)) { context in
                    stack(at: context.date.timeIntervalSinceReferenceDate)
                }
            } else {
                stack(at: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: html) { await loadEmoji() }
    }

    private func stack(at time: TimeInterval) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(blocks) { block in
                BlockView(block: block, emoji: emoji, time: time)
            }
        }
    }

    private func loadEmoji() async {
        let urls = Set(blocks.flatMap(spans(in:)).compactMap(\.emojiURL))
        for url in urls where emoji[url] == nil {
            guard let data = await model.imageData(at: url) else { continue }
            emoji[url] = EmojiFrames.decode(data, height: Self.lineHeight)
        }
    }

    private func spans(in block: MessageBlock) -> [InlineSpan] {
        switch block {
        case .paragraph(let spans): spans
        case .bulletList(let items), .numberedList(let items): items.flatMap { $0 }
        case .quote(let inner): inner.flatMap(spans(in:))
        case .quotedReply(_, _, _, let quoted): quoted.flatMap(spans(in:))
        case .codeBlock, .image: []
        }
    }
}

struct BlockView: View {
    let block: MessageBlock
    let emoji: [String: EmojiFrames]
    /// Which moment of an animated emoji to draw. Constant for messages that have none.
    var time: TimeInterval = 0

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
                    ForEach(inner) { BlockView(block: $0, emoji: emoji, time: time) }
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

        case .image(let source, let link, let alt, let aspectRatio):
            RemoteImage(path: source, fullSize: link, alt: alt, aspectRatio: aspectRatio)

        case .quotedReply(let author, let authorID, _, let quoted):
            QuotedReplyView(
                author: author, authorID: authorID, quoted: quoted, emoji: emoji, time: time
            )
        }
    }

    /// Built by concatenating `Text`, which is the only way to put an image in the middle
    /// of a wrapping paragraph.
    private func styled(_ spans: [InlineSpan]) -> Text {
        spans.reduce(Text("")) { result, span in
            if let url = span.emojiURL {
                if let frames = emoji[url] {
                    return result + Text(frames.frame(at: time)).baselineOffset(-2)
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
    /// Comes from the silent mention's `data-user-id`, so the header can show the real
    /// picture of whoever is being answered.
    let authorID: Int?
    let quoted: [MessageBlock]
    let emoji: [String: EmojiFrames]
    let time: TimeInterval

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
                    SenderAvatar(name: author, userID: authorID, size: 16)
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
                        ForEach(quoted) { BlockView(block: $0, emoji: emoji, time: time) }
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
            case .image(_, _, let alt, _):
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
