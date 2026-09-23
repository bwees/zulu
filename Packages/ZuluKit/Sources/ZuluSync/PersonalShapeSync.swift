import Foundation
import GRDB
import ZuluStore

/// Where the personal-shape document is kept between devices.
@MainActor
public protocol CloudDocumentStore: AnyObject {
    func data(forKey key: String) -> Data?
    func set(_ data: Data, forKey key: String)
    /// Called whenever another device, or iCloud itself, changes what is stored.
    func onExternalChange(_ handler: @escaping @MainActor @Sendable () -> Void)
}

/// iCloud key-value storage. It keeps a local copy when iCloud is signed out, so the
/// arrangement goes on working on this device and catches up once iCloud returns.
@MainActor
public final class UbiquitousDocumentStore: CloudDocumentStore {
    private let store = NSUbiquitousKeyValueStore.default
    private var token: (any NSObjectProtocol)?

    public init() {}

    public func data(forKey key: String) -> Data? { store.data(forKey: key) }

    public func set(_ data: Data, forKey key: String) { store.set(data, forKey: key) }

    public func onExternalChange(_ handler: @escaping @MainActor @Sendable () -> Void) {
        token = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { handler() }
        }
        store.synchronize()
    }
}

/// Keeps the viewer's groups, filing, aliases, modes, hiding, order and promotions the
/// same on every device they use. The whole document is one value, so the last device to
/// write wins, which is enough for one person editing their own sidebar.
@MainActor
public final class PersonalShapeSync {
    static let keyPrefix = "personalShape:"

    private let store: ZuluStore
    private let cloud: any CloudDocumentStore
    /// Per realm, because channel ids mean nothing on another server.
    private let key: String
    private var observation: AnyDatabaseCancellable?
    private var knownChannelIDs: Set<Int> = []

    public init(store: ZuluStore, cloud: any CloudDocumentStore, realmURL: URL) {
        self.store = store
        self.cloud = cloud
        key = Self.keyPrefix + realmURL.absoluteString
    }

    public func start() {
        cloud.onExternalChange { [weak self] in self?.pull() }
        pull()
        knownChannelIDs = (try? store.localPersonalShape().knownChannelIDs) ?? []
        observation = store.observeLocalPersonalShape()
            .removeDuplicates()
            .start(in: store.writer, onError: { _ in }) { [weak self] local in
                self?.localDidChange(local)
            }
    }

    public func stop() {
        observation = nil
    }

    private var remote: PersonalShape? {
        cloud.data(forKey: key)
            .flatMap { try? JSONDecoder().decode(PersonalShape.self, from: $0) }?
            .normalized()
    }

    private func pull() {
        guard let remote else { return }
        try? store.apply(remote)
    }

    private func localDidChange(_ local: LocalPersonalShape) {
        let remote = remote
        let arrived = local.knownChannelIDs.subtracting(knownChannelIDs)
        let previous = LocalPersonalShape(shape: local.shape, knownChannelIDs: knownChannelIDs)
        knownChannelIDs = local.knownChannelIDs

        if let remote, remote.mentions(anyOf: arrived) {
            try? store.apply(previous.document(carryingOver: remote))
            return
        }

        let document = local.document(carryingOver: remote)
        guard document != remote else { return }
        // A new device has nothing to say yet, and saying it would erase the arrangement
        // iCloud is still downloading.
        if remote == nil, document.isEmpty { return }
        guard let data = try? JSONEncoder().encode(document) else { return }
        cloud.set(data, forKey: key)
    }
}

extension PersonalShape {
    func mentions(anyOf channelIDs: Set<Int>) -> Bool {
        channels.contains { channelIDs.contains($0.channelID) }
            || promotions.contains { channelIDs.contains($0.channelID) }
    }
}
