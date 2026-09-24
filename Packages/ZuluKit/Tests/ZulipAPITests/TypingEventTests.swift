import Foundation
import Testing
@testable import ZulipAPI

struct TypingEventTests {

    private func decode(_ json: String) throws -> ZulipEvent {
        try JSONDecoder().decode(EventEnvelope.self, from: Data(json.utf8)).decoded()
    }

    @Test func aDirectTypingEventNamesEveryoneInTheConversation() throws {
        let event = try decode("""
            {"type": "typing", "op": "start", "message_type": "direct", "id": 3,
             "sender": {"user_id": 10, "email": "a@example.com"},
             "recipients": [{"user_id": 8, "email": "b@example.com"},
                            {"user_id": 10, "email": "a@example.com"}]}
            """)

        guard case .typing(let typing) = event else {
            Issue.record("decoded as \(event.eventType)")
            return
        }
        #expect(typing == TypingEvent(
            op: .start, senderID: 10, channelID: nil, topic: nil, recipientIDs: [8, 10]
        ))
    }

    @Test func aChannelTypingEventNamesItsTopic() throws {
        let event = try decode("""
            {"type": "typing", "op": "stop", "message_type": "stream", "id": 4,
             "sender": {"user_id": 10, "email": "a@example.com"},
             "stream_id": 7, "topic": "lunch"}
            """)

        guard case .typing(let typing) = event else {
            Issue.record("decoded as \(event.eventType)")
            return
        }
        #expect(typing == TypingEvent(
            op: .stop, senderID: 10, channelID: 7, topic: "lunch", recipientIDs: []
        ))
    }

    /// `topic` is shared with `update_message`, which must still decode.
    @Test func aTopicMoveStillDecodes() throws {
        let event = try decode("""
            {"type": "update_message", "id": 5, "message_id": 42, "topic": "renamed",
             "rendered_content": "<p>hi</p>"}
            """)

        guard case .updateMessage(let id, _) = event else {
            Issue.record("decoded as \(event.eventType)")
            return
        }
        #expect(id == 42)
    }
}

struct ClientCapabilitiesTests {
    @Test func registerSendsTheCapabilityTheServerRequires() throws {
        let json = try JSONSerialization.jsonObject(
            with: Data(ZulipClient.json(ClientCapabilities()).utf8)
        ) as? [String: Bool]
        #expect(json?["notification_settings_null"] == false)
        #expect(json?["stream_typing_notifications"] == true)
    }
}
