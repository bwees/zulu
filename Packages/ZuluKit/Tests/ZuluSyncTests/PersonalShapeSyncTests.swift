import Foundation
import GRDB
import Testing
import ZuluStore
@testable import ZuluSync

/// One iCloud account. Each device gets its own view of it, and a write from one reaches
/// the others as an external change, the way key-value storage delivers it.
@MainActor
private final class FakeICloud {
    var values: [String: Data] = [:]
    var devices: [Device] = []

    func device() -> Device {
        let device = Device(cloud: self)
        devices.append(device)
        return device
    }

    @MainActor
    final class Device: CloudDocumentStore {
        unowned let cloud: FakeICloud
        var handler: (@MainActor @Sendable () -> Void)?

        init(cloud: FakeICloud) { self.cloud = cloud }

        func data(forKey key: String) -> Data? { cloud.values[key] }

        func set(_ data: Data, forKey key: String) {
            cloud.values[key] = data
            for other in cloud.devices where other !== self { other.handler?() }
        }

        func onExternalChange(_ handler: @escaping @MainActor @Sendable () -> Void) {
            self.handler = handler
        }
    }
}

@MainActor
struct PersonalShapeSyncTests {
    private let realm = URL(string: "https://chat.example.com")!

    private func makeStore(channels: [Int] = [7, 8]) throws -> ZuluStore {
        let store = try ZuluStore(url: nil)
        try insertChannels(channels, into: store)
        return store
    }

    private func insertChannels(_ ids: [Int], into store: ZuluStore) throws {
        try store.writer.write { db in
            for id in ids {
                try db.execute(
                    sql: "INSERT INTO channel (id, name, isRestricted, isMuted, pinned) VALUES (?, ?, 0, 0, 0)",
                    arguments: [id, "channel \(id)"]
                )
            }
        }
    }

    private func eventually(_ condition: () throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while try !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("condition never became true")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func aGroupMadeOnOneDeviceAppearsOnTheOther() async throws {
        let cloud = FakeICloud()
        let phone = try makeStore()
        let mac = try makeStore()
        let phoneSync = PersonalShapeSync(store: phone, cloud: cloud.device(), realmURL: realm)
        let macSync = PersonalShapeSync(store: mac, cloud: cloud.device(), realmURL: realm)
        phoneSync.start()
        macSync.start()

        let group = try phone.createGroup(name: "Work")
        try phone.setChannels([7], inGroup: group.id)

        try await eventually { try mac.channelIDs(inGroup: group.id) == [7] }
    }

    @Test func aNewDeviceDoesNotEraseTheArrangementItHasYetToDownload() async throws {
        let cloud = FakeICloud()
        let phone = try makeStore()
        let phoneSync = PersonalShapeSync(store: phone, cloud: cloud.device(), realmURL: realm)
        phoneSync.start()
        try phone.createGroup(name: "Work")
        try await eventually { !cloud.values.isEmpty }
        let uploaded = cloud.values

        let mac = try makeStore()
        let macDevice = cloud.device()
        cloud.values = [:]
        let macSync = PersonalShapeSync(store: mac, cloud: macDevice, realmURL: realm)
        macSync.start()
        try await Task.sleep(for: .milliseconds(50))
        #expect(cloud.values.isEmpty)

        cloud.values = uploaded
        macDevice.handler?()
        #expect(try mac.groups().map(\.name) == ["Work"])
    }

    @Test func channelsThatArriveAfterTheDocumentPickUpTheirSettings() async throws {
        let cloud = FakeICloud()
        let phone = try makeStore()
        let phoneSync = PersonalShapeSync(store: phone, cloud: cloud.device(), realmURL: realm)
        phoneSync.start()
        try phone.setAlias("Eng", forChannel: 7)
        try await eventually { !cloud.values.isEmpty }

        let mac = try makeStore(channels: [])
        let macSync = PersonalShapeSync(store: mac, cloud: cloud.device(), realmURL: realm)
        macSync.start()
        try insertChannels([7, 8], into: mac)

        try await eventually { try mac.alias(forChannel: 7) == "Eng" }
    }

    @Test func aDeviceMissingAChannelKeepsAnotherDevicesSettingsForIt() async throws {
        let cloud = FakeICloud()
        let phone = try makeStore()
        let mac = try makeStore(channels: [7])
        let phoneSync = PersonalShapeSync(store: phone, cloud: cloud.device(), realmURL: realm)
        let macSync = PersonalShapeSync(store: mac, cloud: cloud.device(), realmURL: realm)
        phoneSync.start()
        macSync.start()

        try phone.setAlias("Side", forChannel: 8)
        try await eventually { !cloud.values.isEmpty }
        try mac.setAlias("Eng", forChannel: 7)

        try await eventually { try phone.alias(forChannel: 7) == "Eng" }
        #expect(try phone.alias(forChannel: 8) == "Side")
    }

    @Test func eachRealmKeepsItsOwnArrangement() async throws {
        let cloud = FakeICloud()
        let store = try makeStore()
        let sync = PersonalShapeSync(store: store, cloud: cloud.device(), realmURL: realm)
        sync.start()
        try store.createGroup(name: "Work")
        try await eventually { !cloud.values.isEmpty }

        let other = try makeStore()
        let otherSync = PersonalShapeSync(
            store: other, cloud: cloud.device(), realmURL: URL(string: "https://other.example.com")!
        )
        otherSync.start()

        #expect(try other.groups().isEmpty)
    }
}
