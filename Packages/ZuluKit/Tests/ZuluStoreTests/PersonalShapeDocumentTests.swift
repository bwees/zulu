import Foundation
import GRDB
import Testing
@testable import ZuluStore

@MainActor
struct PersonalShapeDocumentTests {

    private func makeStore(channels: [Int] = [7, 8]) throws -> ZuluStore {
        let store = try ZuluStore(url: nil)
        try store.writer.write { db in
            for id in channels {
                try db.execute(
                    sql: "INSERT INTO channel (id, name, isRestricted, isMuted, pinned) VALUES (?, ?, 0, 0, 0)",
                    arguments: [id, "channel \(id)"]
                )
                try db.execute(
                    sql: "INSERT INTO topic (channelID, name, maxMessageID) VALUES (?, 'standup', 10)",
                    arguments: [id]
                )
            }
        }
        return store
    }

    private func arrange(_ store: ZuluStore) throws -> ChannelGroupRecord {
        let group = try store.createGroup(name: "Work")
        try store.setChannels([7], inGroup: group.id)
        try store.setAlias("Eng", forChannel: 7)
        try store.setHidden(true, forChannel: 8)
        try store.setModeOverride(.chat, forChannel: 8)
        try store.promote(topic: "standup", inChannel: 7)
        try store.setAlias("Daily", forPromotedTopic: "standup", inChannel: 7)
        return group
    }

    @Test func anArrangementSurvivesTheTripToAnotherDevice() throws {
        let source = try makeStore()
        _ = try arrange(source)
        let destination = try makeStore()

        try destination.apply(source.localPersonalShape().shape)

        #expect(try destination.localPersonalShape() == source.localPersonalShape())
    }

    @Test func applyingKeepsThisDevicesIcon() throws {
        let store = try makeStore()
        let group = try arrange(store)
        try store.updateGroup(id: group.id, icon: Data([1, 2, 3]))

        var shape = try store.localPersonalShape().shape
        shape.groups[0].name = "Renamed"
        try store.apply(shape)

        let applied = try #require(try store.groups().first)
        #expect(applied.name == "Renamed")
        #expect(applied.icon == Data([1, 2, 3]))
    }

    @Test func applyingRemovesWhatTheDocumentNoLongerHolds() throws {
        let store = try makeStore()
        _ = try arrange(store)

        try store.apply(PersonalShape())

        #expect(try store.localPersonalShape().shape.isEmpty)
    }

    @Test func aChannelThisDeviceLacksIsPassedAlongUntouched() throws {
        let source = try makeStore()
        _ = try arrange(source)
        let remote = try source.localPersonalShape().shape
        let lacking = try makeStore(channels: [7])
        try lacking.apply(remote)

        let document = try lacking.localPersonalShape().document(carryingOver: remote)

        #expect(document == remote)
    }

    @Test func aChannelThatArrivesLaterIsFilledInByApplyingAgain() throws {
        let source = try makeStore()
        _ = try arrange(source)
        let remote = try source.localPersonalShape().shape
        let lacking = try makeStore(channels: [])
        try lacking.apply(remote)

        try lacking.writer.write { db in
            for id in [7, 8] {
                try db.execute(
                    sql: "INSERT INTO channel (id, name, isRestricted, isMuted, pinned) VALUES (?, ?, 0, 0, 0)",
                    arguments: [id, "channel \(id)"]
                )
            }
        }
        try lacking.apply(remote)

        #expect(try lacking.localPersonalShape().shape == remote)
    }

    @Test func aCarriedPromotionWhoseGroupWasDeletedHereIsUnfiled() throws {
        let source = try makeStore()
        let group = try arrange(source)
        let remote = try source.localPersonalShape().shape
        let lacking = try makeStore(channels: [])
        try lacking.apply(remote)
        try lacking.deleteGroup(id: group.id)

        let document = try lacking.localPersonalShape().document(carryingOver: remote)

        #expect(document.promotions.map(\.groupID) == [nil])
    }
}
