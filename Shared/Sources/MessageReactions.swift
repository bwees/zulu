import GRDB
import SwiftUI
import ZulipAPI
import ZuluEmoji
import ZuluStore

/// The chips under a message.
struct MessageReactionsRow: View {
    let messageID: Int
    /// Passed in rather than fetched here: the conversation owns one observation for
    /// every message, so a row is never empty at the moment it is measured.
    let groups: [ReactionGroup]

    @Environment(AppModel.self) private var model
    @State private var showingReactors: ReactionGroup?
    #if os(macOS)
    @State private var hoveredGroup: String?
    @State private var hoverTask: Task<Void, Never>?
    #endif

    var body: some View {
        if !groups.isEmpty {
            FlowRow(spacing: 6) {
                ForEach(groups) { group in
                    chip(group)
                }
            }
            .padding(.top, 4)
        }
    }

    /// "You, Ada and Grace", the way a person would say it, with you first because the
    /// question a chip answers is usually "did I already?".
    private func reactorNames(of group: ReactionGroup) -> String {
        let selfID = model.selfUserID
        let others = group.userIDs.filter { $0 != selfID }.map(model.name(forUser:)).sorted()
        let names = (group.includesSelf ? ["You"] : []) + others
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        default: return names.dropLast().joined(separator: ", ") + " and " + names.last!
        }
    }
    private func chip(_ group: ReactionGroup) -> some View {
        Button {
            Task { await model.toggleReaction(
                emojiName: group.emojiName, emojiCode: group.emojiCode,
                reactionType: group.reactionType, onMessage: messageID
            ) }
        } label: {
            HStack(spacing: 4) {
                EmojiDisplayView(display: Self.display(of: group), size: 14)
                Text("\(group.count)")
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                group.includesSelf ? AnyShapeStyle(Color.accentColor.opacity(0.22))
                                   : AnyShapeStyle(.quaternary),
                in: Capsule()
            )
            .overlay {
                if group.includesSelf {
                    Capsule().strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1)
                }
            }
            .contentShape(.capsule)
        }
        // Plain and small: a glass capsule per reaction turned a row of chips into
        // a row of buttons competing with the message above them.
        .buttonStyle(.plain)
        #if os(macOS)
        // Hovering answers "who?" with a bubble above the chip. Drawn in the view
        // rather than as a popover, so the pointer resting on a reaction never takes
        // keyboard focus away from the composer.
        // Hung from the chip's leading edge rather than centred on it: chips sit at
        // the left of the column, and a centred bubble ran off the edge and was clipped.
        .overlay(alignment: .topLeading) {
            if hoveredGroup == group.id {
                ReactorBubble(names: reactorNames(of: group), emojiName: group.emojiName)
                    .alignmentGuide(.top) { $0[.bottom] + 6 }
                    .transition(.opacity)
            }
        }
        .onHover { inside in
            hoverTask?.cancel()
            if inside {
                hoverTask = Task {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeOut(duration: 0.12)) { hoveredGroup = group.id }
                }
            } else if hoveredGroup == group.id {
                withAnimation(.easeOut(duration: 0.12)) { hoveredGroup = nil }
            }
        }
        #else
        .help(reactorNames(of: group))
        #endif
        .onLongPressGesture { showingReactors = group }
        .popover(item: $showingReactors) { group in
            ReactorList(names: group.userIDs.map(model.name(forUser:)).sorted())
                .presentationCompactAdaptation(.popover)
        }
        .accessibilityLabel("\(group.emojiName), \(group.count)")
    }
}

#if os(macOS)
/// The hover bubble over a reaction chip: who, in bold, and with what.
private struct ReactorBubble: View {
    let names: String
    let emojiName: String

    var body: some View {
        (Text(names).fontWeight(.semibold) + Text(" reacted with :\(emojiName):"))
            .font(.callout)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 320)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
            .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
            .fixedSize()
            .allowsHitTesting(false)
    }
}
#endif

private struct ReactorList: View {
    let names: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(names, id: \.self) { name in
                Text(name).font(.callout)
            }
        }
        .padding(14)
        .frame(maxWidth: 260, alignment: .leading)
    }
}


/// Draws whichever of the three shapes an emoji resolved to. Realm custom emoji and
/// `:zulip:` are images on the realm, so they load through the signed-in client.
struct EmojiDisplayView: View {
    let display: EmojiDisplay
    var size: CGFloat = 16

    @Environment(AppModel.self) private var model
    @State private var frames: EmojiFrames?

    /// A unicode emoji drawn at point size N occupies noticeably more than N points — the
    /// glyph overshoots its em box. An image sized to exactly N therefore looks smaller
    /// than the emoji beside it, so custom emoji are scaled to match what the glyph does.
    private var imageSide: CGFloat { size * 1.28 }

    var body: some View {
        switch display {
        case .glyph(let glyph):
            Text(glyph).font(.system(size: size))
        case .image(let url, _):
            // The animated URL, not the still: an animated custom emoji that does
            // not move is just a worse version of itself.
            imageView(path: url)
        case .text(let fallback):
            Text(fallback)
                .font(.system(size: size * 0.7))
                .lineLimit(1)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func imageView(path: String) -> some View {
        if let frames {
            AnimatedEmojiView(frames: frames)
        } else {
            Color.clear
                .frame(width: imageSide, height: imageSide)
                .task(id: path) {
                    guard let data = await model.imageData(at: path) else { return }
                    frames = EmojiFrames.decode(data, height: imageSide)
                }
        }
    }
}

/// Chips wrap onto as many lines as they need. `Layout` rather than a `LazyVGrid`
/// because every chip is a different width and a grid would either clip the wide ones or
/// leave a column of air beside the narrow ones.
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var rows: [CGFloat] = [0]
        var used: CGFloat = 0
        var height: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if used > 0, used + spacing + size.width > width {
                height += rowHeight + spacing
                rows.append(0)
                used = 0
                rowHeight = 0
            }
            used += (used > 0 ? spacing : 0) + size.width
            rowHeight = max(rowHeight, size.height)
            rows[rows.count - 1] = used
        }
        return CGSize(width: rows.max() ?? 0, height: height + rowHeight)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

extension MessageReactionsRow {
    static func display(of group: ReactionGroup) -> EmojiDisplay {
        EmojiCatalogueLoader.shared.catalogue.display(
            reactionType: group.reactionType, code: group.emojiCode, name: group.emojiName
        )
    }
}

// MARK: - Reactions

extension AppModel {

    func reactionObservation(forMessage id: Int)
        -> ValueObservation<ValueReducers.Fetch<[ReactionRecord]>>?
    {
        storeForReading?.observeReactions(forMessage: id)
    }

    /// Written locally before the server is asked, and unwound if the server refuses.
    ///
    /// The event queue echoes the same change back keyed on the same four columns, so the
    /// echo lands on top of the guess rather than beside it.
    func toggleReaction(
        emojiName: String, emojiCode: String, reactionType: String, onMessage id: Int
    ) async -> String? {
        guard let account, let store = storeForReading else { return "Not signed in." }

        let toggle = ReactionGroup.toggle(
            emojiName: emojiName, emojiCode: emojiCode, reactionType: reactionType,
            in: (try? store.reactions(forMessage: id)) ?? [], by: account.userID
        )
        try? store.setReaction(
            onMessage: id, emojiName: toggle.emojiName, emojiCode: toggle.emojiCode,
            reactionType: toggle.reactionType, userID: account.userID, present: toggle.adds
        )

        let client = ZulipClient(account: account)
        do {
            if toggle.adds {
                try await client.addReaction(
                    toMessage: id, emojiName: toggle.emojiName,
                    emojiCode: toggle.emojiCode, reactionType: toggle.reactionType
                )
            } else {
                try await client.removeReaction(
                    fromMessage: id, emojiName: toggle.emojiName,
                    emojiCode: toggle.emojiCode, reactionType: toggle.reactionType
                )
            }
            return nil
        } catch let error as ZulipError where error.leavesReactionAsRequested {
            return nil
        } catch {
            try? store.setReaction(
                onMessage: id, emojiName: toggle.emojiName, emojiCode: toggle.emojiCode,
                reactionType: toggle.reactionType, userID: account.userID, present: !toggle.adds
            )
            return Self.describe(error)
        }
    }
}

private struct ReactionsKey: Equatable {
    let messageID: Int
    let ready: Bool
}
