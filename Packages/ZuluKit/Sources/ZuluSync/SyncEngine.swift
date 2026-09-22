import Foundation
import ZulipAPI
import ZuluStore

public enum SyncStatus: Sendable, Equatable {
    case idle
    case connecting
    case live
    case failed(String)
}

/// Owns the event queue. Registers, long-polls, and writes what arrives into the store.
/// Nothing else talks to the events API.
public actor SyncEngine {
    private let client: ZulipClient
    private let store: ZuluStore
    private let selfUserID: Int

    private var queueID: String?
    private var lastEventID: Int = -1
    private var task: Task<Void, Never>?

    /// Consecutive transport failures, used only to space out retries.
    private var backoffStep = 0

    public private(set) var status: SyncStatus = .idle
    private var statusHandler: (@Sendable (SyncStatus) -> Void)?

    public init(client: ZulipClient, store: ZuluStore, selfUserID: Int) {
        self.client = client
        self.store = store
        self.selfUserID = selfUserID
    }

    public func onStatusChange(_ handler: @escaping @Sendable (SyncStatus) -> Void) {
        statusHandler = handler
        handler(status)
    }

    private func setStatus(_ new: SyncStatus) {
        guard status != new else { return }
        status = new
        statusHandler?(new)
    }

    public func start() {
        guard task == nil else { return }
        task = Task { [weak self] in await self?.run() }
    }

    public func stop() {
        task?.cancel()
        task = nil
        setStatus(.idle)
    }

    private func run() async {
        while !Task.isCancelled {
            do {
                if queueID == nil { try await registerQueue() }
                guard let queueID else { continue }

                let batch = try await client.events(queueID: queueID, lastEventID: lastEventID)
                try await apply(batch.events)
                lastEventID = max(lastEventID, batch.lastEventID)
                try store.saveSyncState(queueID: queueID, lastEventID: lastEventID)

                backoffStep = 0
                setStatus(.live)
            } catch let error as ZulipError where error.code == "BAD_EVENT_QUEUE_ID" {
                // The queue expired. There is no partial resync: re-register and refetch.
                queueID = nil
                lastEventID = -1
                setStatus(.connecting)
            } catch is CancellationError {
                return
            } catch {
                setStatus(.failed(error.localizedDescription))
                await backoff()
            }
        }
    }

    private func backoff() async {
        backoffStep = min(backoffStep + 1, 6)
        let seconds = min(pow(2.0, Double(backoffStep)), 60)
        try? await Task.sleep(for: .seconds(seconds))
    }

    private func registerQueue() async throws {
        setStatus(.connecting)
        let registration = try await client.register()
        queueID = registration.queue_id
        lastEventID = registration.last_event_id

        if let subscriptions = registration.subscriptions {
            try store.replaceChannels(subscriptions)
        }
        if let users = registration.realm_users {
            try store.saveUsers(users)
        }
        try store.saveSyncState(queueID: queueID, lastEventID: lastEventID)
        setStatus(.live)

        await refreshTopics()
        await loadRecentDirectMessages()
    }

    /// Topics are not in the register snapshot and there is no bulk endpoint, so each
    /// subscribed channel is asked individually. Cheap enough at realistic channel counts.
    public func refreshTopics() async {
        guard let channels = try? store.channels() else { return }
        for channel in channels {
            guard !Task.isCancelled else { return }
            if let topics = try? await client.topics(inChannel: channel.id) {
                try? store.saveTopics(topics, inChannel: channel.id)
            }
        }
    }

    private func apply(_ events: [ZulipEvent]) async throws {
        for event in events {
            switch event {
            case .message(let message):
                try store.save(messages: [message], selfUserID: selfUserID)

            case .deleteMessage(let ids):
                try store.deleteMessages(ids: ids)

            case .flags(let operation, let flag, let messageIDs) where flag == "read":
                try store.setRead(ids: messageIDs, read: operation == "add")

            case .updateMessage(let id, let renderedContent):
                if let renderedContent {
                    try store.updateRenderedContent(id: id, html: renderedContent)
                }

            case .reaction(let added, let messageID, let reaction):
                try store.setReaction(reaction, onMessage: messageID, added: added)

            case .subscriptionsChanged:
                if let subscriptions = try? await client.subscriptions() {
                    try store.replaceChannels(subscriptions)
                }

            case .flags, .heartbeat, .other:
                break
            }
        }
    }
}

extension SyncEngine {
    /// DM conversations are derived from the messages themselves — there is no endpoint
    /// that lists them. Without this initial fetch the DM list stays empty forever,
    /// because a conversation has to be listed before it can be opened and loaded.
    public func loadRecentDirectMessages(limit: Int = 300) async {
        guard let page = try? await client.messages(
            narrow: [.directMessages], anchor: .newest, before: limit
        ) else { return }
        try? store.save(messages: page.messages, selfUserID: selfUserID)
    }
}
