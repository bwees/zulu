import Testing
import ZulipAPI
@testable import ZuluStore

struct SubmessageStoreTests {

    private func store(withMessage id: Int) throws -> ZuluStore {
        let store = try ZuluStore(url: nil)
        try store.writer.write { db in
            try MessageRecord(
                id: id, channelID: 1, topic: "polls", senderID: 58, senderName: "Ada",
                renderedContent: "<p>/poll Tea or coffee?</p>", timestamp: 0
            ).save(db)
        }
        return store
    }

    private func submessage(id: Int, messageID: Int = 10, content: String = "{}") -> Submessage {
        Submessage(id: id, message_id: messageID, sender_id: 58, msg_type: "widget", content: content)
    }

    @Test func anEventIsStoredAndMarksItsMessageAsAWidget() throws {
        let store = try store(withMessage: 10)
        try store.apply(submessage(id: 1))

        #expect(try store.submessages(forMessage: 10).map(\.id) == [1])
        #expect(try store.writer.read { db in try MessageRecord.fetchOne(db, key: 10)?.isWidget } == true)
    }

    /// The same submessage arrives twice as a matter of course — once inside GET /messages,
    /// once from the event queue.
    @Test func applyingTheSameEventTwiceLeavesOneRow() throws {
        let store = try store(withMessage: 10)
        try store.apply(submessage(id: 1))
        try store.apply(submessage(id: 1))

        #expect(try store.submessages(forMessage: 10).count == 1)
    }

    /// The server fans these out to everyone who can see the message, without knowing which
    /// messages this client holds.
    @Test func anEventForAnUnknownMessageIsDropped() throws {
        let store = try store(withMessage: 10)
        try store.apply(submessage(id: 1, messageID: 999))

        #expect(try store.submessages(forMessage: 999).isEmpty)
    }

    @Test func theLogIsReadBackInIDOrder() throws {
        let store = try store(withMessage: 10)
        for id in [4, 1, 3] { try store.apply(submessage(id: id)) }

        #expect(try store.submessages(forMessage: 10).map(\.id) == [1, 3, 4])
    }
}
