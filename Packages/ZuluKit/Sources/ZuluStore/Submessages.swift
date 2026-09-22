import Foundation
import GRDB
import ZulipAPI

/// One entry in a message's widget log, kept verbatim.
///
/// The log is the record and a poll's tally is only ever derived from it, so nothing here
/// interprets `content` — that belongs to whoever replays the log.
public struct SubmessageRecord: Codable, FetchableRecord, PersistableRecord, Sendable,
    Identifiable, Equatable
{
    public static let databaseTableName = "submessage"

    public var id: Int
    public var messageID: Int
    public var senderID: Int
    public var msgType: String
    public var content: String

    public init(id: Int, messageID: Int, senderID: Int, msgType: String, content: String) {
        self.id = id
        self.messageID = messageID
        self.senderID = senderID
        self.msgType = msgType
        self.content = content
    }

    public init(from submessage: Submessage) {
        self.init(
            id: submessage.id,
            messageID: submessage.message_id,
            senderID: submessage.sender_id,
            msgType: submessage.msg_type,
            content: submessage.content
        )
    }
}

extension ZuluStore {

    /// Applies one `submessage` event.
    ///
    /// The server sends these for messages this client has never fetched, because it does
    /// not track what anyone holds. Such an event is dropped: the log will arrive complete
    /// with the message itself.
    public func apply(_ submessage: Submessage) throws {
        try writer.write { db in
            guard try MessageRecord.exists(db, key: submessage.message_id) else { return }
            try SubmessageRecord(from: submessage).save(db)
            if submessage.msg_type == "widget" {
                try MessageRecord
                    .filter(Column("id") == submessage.message_id)
                    .updateAll(db, Column("isWidget").set(to: true))
            }
        }
    }

    public func observeSubmessages(forMessage id: Int)
        -> ValueObservation<ValueReducers.Fetch<[SubmessageRecord]>>
    {
        ValueObservation.tracking { db in
            try SubmessageRecord
                .filter(Column("messageID") == id)
                .order(Column("id"))
                .fetchAll(db)
        }
    }

    public func submessages(forMessage id: Int) throws -> [SubmessageRecord] {
        try writer.read { db in
            try SubmessageRecord
                .filter(Column("messageID") == id)
                .order(Column("id"))
                .fetchAll(db)
        }
    }
}
