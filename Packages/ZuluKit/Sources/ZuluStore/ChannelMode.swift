import Foundation
import GRDB

/// Whether a channel reads as a forum or as a chat room.
///
/// Zulip does not answer this — every channel has topics whether or not anyone uses them —
/// so Zulu decides, and lets the person overrule it.
public enum ChannelMode: Int, Sendable, CaseIterable {
    case chat = 0
    case forum = 1

    public var label: String {
        switch self {
        case .chat: "Chat"
        case .forum: "Forum"
        }
    }
}

public enum ChannelModeDetector {

    /// Topic count alone is a bad signal: plenty of chat channels have accumulated a long
    /// tail of dead topics, and a strict "more than one topic" rule calls every one of them
    /// a forum.
    ///
    /// What separates them is whether more than one topic is *currently* live. Message ids
    /// rise monotonically across the realm, so a topic's newest id stands in for how
    /// recently it was touched. If the newest topic has run away from the rest — more than
    /// half the channel's whole id span ahead of the runner-up — then one conversation is
    /// absorbing the traffic and the channel is a chat room.
    public static func detectsAsForum(topicMaxIDs: [Int]) -> Bool {
        let sorted = topicMaxIDs.sorted(by: >)
        guard sorted.count > 1, let newest = sorted.first, let oldest = sorted.last else {
            return false
        }

        let span = newest - oldest
        // Several topics all at the same id means a burst across topics, not one thread.
        guard span > 0 else { return true }

        let lead = newest - sorted[1]
        return Double(lead) <= 0.5 * Double(span)
    }
}

extension ZuluStore {

    /// Recomputed whenever a channel's topics are refetched, and cached, so the sidebar
    /// does not re-derive it per row.
    public func refreshDetectedMode(forChannel id: Int) throws {
        try writer.write { db in
            let maxIDs = try Int.fetchAll(
                db, sql: "SELECT maxMessageID FROM topic WHERE channelID = ?", arguments: [id]
            )
            let isForum = ChannelModeDetector.detectsAsForum(topicMaxIDs: maxIDs)
            try db.execute(
                sql: "UPDATE channel SET detectedForum = ? WHERE id = ?", arguments: [isForum, id]
            )
        }
    }

    /// `nil` hands the channel back to the detector.
    public func setModeOverride(_ mode: ChannelMode?, forChannel id: Int) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE channel SET modeOverride = ? WHERE id = ?",
                arguments: [mode?.rawValue, id]
            )
        }
    }
}
