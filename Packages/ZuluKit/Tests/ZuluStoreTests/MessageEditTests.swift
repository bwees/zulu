import Foundation
import GRDB
import Testing
@testable import ZuluStore

struct MessageEditTests {

    private let me = 1
    private let someoneElse = 2

    private func store(_ messages: [MessageRecord]) throws -> ZuluStore {
        let store = try ZuluStore(url: nil)
        try store.writer.write { db in
            for message in messages { try message.insert(db) }
        }
        return store
    }

    private func message(
        _ id: Int, from sender: Int, topic: String = "lunch", isWidget: Bool = false
    ) -> MessageRecord {
        MessageRecord(
            id: id, channelID: 7, topic: topic, senderID: sender, senderName: "",
            renderedContent: "<p>\(id)</p>", timestamp: id, isWidget: isWidget
        )
    }

    @Test func upArrowFindsMyNewestMessageInTheTopic() throws {
        let store = try store([
            message(1, from: me),
            message(2, from: me),
            message(3, from: someoneElse),
            message(4, from: me, topic: "elsewhere"),
        ])
        #expect(try store.latestMessage(from: me, channelID: 7, topic: "lunch")?.id == 2)
    }

    @Test func aPollIsNeverTheOneEdited() throws {
        let store = try store([message(1, from: me), message(2, from: me, isWidget: true)])
        #expect(try store.latestMessage(from: me, channelID: 7, topic: "lunch")?.id == 1)
    }

    @Test func anEditMarksTheMessageEdited() throws {
        let store = try store([message(1, from: me)])
        try store.updateRenderedContent(id: 1, html: "<p>fixed</p>", editedAt: 99)
        let edited = try store.writer.read { db in try MessageRecord.fetchOne(db, key: 1) }
        #expect(edited?.renderedContent == "<p>fixed</p>")
        #expect(edited?.editedAt == 99)
    }
}
