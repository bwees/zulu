import AuthenticationServices
import Foundation
import GRDB
import Observation
import SwiftUI
import ZulipAPI
import ZuluStore
import ZuluSync

/// Everything the shell needs to know, in one place. Views read from it and call it;
/// they never talk to the API or the database themselves.
@MainActor
@Observable
final class AppModel {

    enum Phase: Equatable {
        case loading
        case signedOut
        case signedIn
    }

    enum Destination: Equatable, Hashable {
        case channel(Int)
        case dm(String)
    }

    private(set) var phase: Phase = .loading
    private(set) var account: ZulipAccount?
    private(set) var status: SyncStatus = .idle

    private(set) var allChannels: [ChannelSummary] = []
    private(set) var groups: [ChannelGroupSummary] = []
    fileprivate(set) var unfiledChannels: [ChannelSummary] = []
    fileprivate(set) var recentTopics: [Int: [TopicSummary]] = [:]
    fileprivate var sidebarObserversStarted = false
    private(set) var dms: [DMSummary] = []
    private(set) var users: [Int: UserRecord] = [:]

    var destination: Destination?
    var signInError: String?
    /// Set when a freshly made group should open its editor straight away.
    var pendingGroupToEdit: String?
    var isWorking = false

    fileprivate var store: ZuluStore?
    fileprivate var client: ZulipClient?
    private var sync: SyncEngine?
    fileprivate var observers: [AnyDatabaseCancellable] = []

    // MARK: lifecycle

    func bootstrap() async {
        guard phase == .loading else { return }
        if let saved = AccountStorage.load() {
            await activate(saved)
        } else {
            phase = .signedOut
        }
    }

    private func activate(_ account: ZulipAccount) async {
        do {
            let store = try ZuluStore(url: try ZuluStore.defaultURL())
            let client = ZulipClient(account: account)
            let sync = SyncEngine(client: client, store: store, selfUserID: account.userID)

            self.account = account
            self.store = store
            self.client = client
            RealmContext.realmURL = account.realmURL
            self.sync = sync

            observe(store)
            startSidebarObservations()
            phase = .signedIn

            await sync.onStatusChange { [weak self] status in
                Task { @MainActor in self?.status = status }
            }
            await sync.start()
        } catch {
            signInError = error.localizedDescription
            phase = .signedOut
        }
    }

    private func observe(_ store: ZuluStore) {
        observers.removeAll()
        observers.append(
            store.observeChannels().start(in: store.writer, onError: { _ in }) { [weak self] rows in
                self?.allChannels = rows
            }
        )
        observers.append(
            store.observeGroups().start(in: store.writer, onError: { _ in }) { [weak self] rows in
                self?.groups = rows
            }
        )
        observers.append(
            store.observeDMs().start(in: store.writer, onError: { _ in }) { [weak self] rows in
                self?.dms = rows
            }
        )
        observers.append(
            store.observeUsers().start(in: store.writer, onError: { _ in }) { [weak self] rows in
                self?.users = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
            }
        )
    }

    // MARK: sign in

    func serverSettings(for input: String) async throws -> (URL, ServerSettings) {
        guard let typed = ZulipClient.parseRealmURL(input) else {
            throw ZulipError(kind: .badResponse, message: "That does not look like a server address.")
        }
        let settings = try await ZulipClient.serverSettings(realmURL: typed)
        // The server's own URL is canonical from here on; what was typed may differ.
        return (settings.canonicalURL(fallback: typed), settings)
    }

    func signIn(realmURL: URL, username: String, password: String) async {
        isWorking = true
        signInError = nil
        defer { isWorking = false }
        do {
            let account = try await ZulipClient.signIn(
                realmURL: realmURL, username: username, password: password
            )
            try AccountStorage.save(account)
            await activate(account)
        } catch {
            signInError = Self.describe(error)
        }
    }

    func signInWithBrowser(realmURL: URL, method: ExternalAuthMethod) async {
        isWorking = true
        signInError = nil
        defer { isWorking = false }

        let otp = WebAuth.generateOTP()
        guard let url = WebAuth.authURL(realmURL: realmURL, method: method, otp: otp) else {
            signInError = "That sign-in method has an address Zulu could not use."
            return
        }
        do {
            let callback = try await WebAuthSession.run(url: url, callbackScheme: "zulip")
            guard let payload = WebAuth.parse(callback: callback),
                  let account = WebAuth.account(from: payload, otp: otp, realmURL: realmURL)
            else {
                signInError = "The server sent back a sign-in reply Zulu could not verify."
                return
            }
            try AccountStorage.save(account)
            await activate(account)
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            return
        } catch {
            signInError = Self.describe(error)
        }
    }

    func signOut() async {
        await sync?.stop()
        observers.removeAll()
        try? store?.clearAll()
        AccountStorage.clear()
        account = nil
        store = nil
        client = nil
        sync = nil
        allChannels = []
        groups = []
        unfiledChannels = []
        recentTopics = [:]
        sidebarObserversStarted = false
        dms = []
        users = [:]
        destination = nil
        phase = .signedOut
    }

    // MARK: reading

    func channel(_ id: Int) -> ChannelSummary? { allChannels.first { $0.id == id } }

    func topics(inChannel id: Int) -> ValueObservation<ValueReducers.Fetch<[TopicSummary]>>? {
        store?.observeTopics(inChannel: id)
    }

    var databaseWriter: (any DatabaseWriter)? { store?.writer }

    func name(forUser id: Int) -> String { users[id]?.fullName ?? "User \(id)" }

    /// Names a DM by its other participants, so a conversation is labelled the way a
    /// person would label it.
    func title(forDM key: String) -> String {
        guard let selfID = account?.userID else { return key }
        let others = key.split(separator: ",").compactMap { Int($0) }.filter { $0 != selfID }
        if others.isEmpty { return "Notes to self" }
        return others.map(name(forUser:)).sorted().joined(separator: ", ")
    }

    /// Backfills a conversation that the event queue alone would not have filled, since
    /// the queue only carries what arrives after registration.
    func loadHistory(channelID: Int, topic: String) async {
        guard let client, let store, let account else { return }
        let narrow = [NarrowFilter.channel(channelID), .topic(topic)]
        if let page = try? await client.messages(narrow: narrow, anchor: .newest, before: 100) {
            try? store.save(messages: page.messages, selfUserID: account.userID)
        }
    }

    func loadHistory(dmKey: String) async {
        guard let client, let store, let account else { return }
        let ids = dmKey.split(separator: ",").compactMap { Int($0) }
        if let page = try? await client.messages(narrow: [.dm(ids)], anchor: .newest, before: 100) {
            try? store.save(messages: page.messages, selfUserID: account.userID)
        }
    }

    func refreshTopics() async { await sync?.refreshTopics() }

    // MARK: sending

    func send(_ text: String, toChannel id: Int, topic: String) async -> String? {
        guard let client else { return "Not signed in." }
        do {
            _ = try await client.sendMessage(toChannel: id, topic: topic, content: text)
            return nil
        } catch {
            return Self.describe(error)
        }
    }

    func send(_ text: String, toDM key: String) async -> String? {
        guard let client, let selfID = account?.userID else { return "Not signed in." }
        let recipients = key.split(separator: ",").compactMap { Int($0) }.filter { $0 != selfID }
        do {
            _ = try await client.sendMessage(toUsers: recipients.isEmpty ? [selfID] : recipients, content: text)
            return nil
        } catch {
            return Self.describe(error)
        }
    }


    static func describe(_ error: Error) -> String {
        guard let zulip = error as? ZulipError else { return error.localizedDescription }
        return switch zulip.code {
        case "AUTHENTICATION_FAILED": "That username or password was not accepted."
        case "USER_DEACTIVATED": "That account has been deactivated."
        case "REALM_DEACTIVATED": "That organization has been deactivated."
        case "PASSWORD_AUTH_DISABLED": "This organization does not allow password sign-in."
        case "RATE_LIMIT_HIT": "Too many attempts. Wait a few minutes and try again."
        default: zulip.message
        }
    }
}

/// `ASWebAuthenticationSession` as an async call.
enum WebAuthSession {
    @MainActor
    static func run(url: URL, callbackScheme: String) async throws -> URL {
        final class Anchor: NSObject, ASWebAuthenticationPresentationContextProviding {
            func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
                UIApplication.shared.connectedScenes
                    .compactMap { ($0 as? UIWindowScene)?.keyWindow }
                    .first ?? ASPresentationAnchor()
            }
        }
        let anchor = Anchor()
        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url, callbackURLScheme: callbackScheme
            ) { callback, error in
                if let callback {
                    continuation.resume(returning: callback)
                } else {
                    continuation.resume(throwing: error ?? CancellationError())
                }
            }
            session.presentationContextProvider = anchor
            session.prefersEphemeralWebBrowserSession = false
            _ = withExtendedLifetime(anchor) { session.start() }
        }
    }
}

extension AppModel {
    /// Views observe the database directly; they still never write to it.
    var storeForReading: ZuluStore? { store }
}

// MARK: - Media

extension AppModel {
    /// Fetches an upload or proxied external image. Realm-relative paths go through the
    /// authenticated client; anything already absolute is fetched plainly, so the API key
    /// never leaves the realm's origin.
    func imageData(at path: String) async -> Data? {
        if let cached = await Self.imageCache.value(for: path) { return cached }

        let data: Data?
        if path.hasPrefix("/") {
            data = try? await client?.media(at: path)
        } else if let url = URL(string: path), url.scheme == "http" || url.scheme == "https" {
            data = try? await URLSession.shared.data(from: url).0
        } else {
            data = nil
        }

        guard let data, !data.isEmpty else { return nil }
        await Self.imageCache.insert(data, for: path)
        return data
    }

    private static let imageCache = ImageCache()
}

extension AppModel {
    enum UploadOutcome {
        case success(String)
        case failure(String)
    }

    func upload(_ data: Data, filename: String, contentType: String) async -> UploadOutcome {
        guard let client else { return .failure("Not signed in.") }
        do {
            let file = try await client.upload(data, filename: filename, contentType: contentType)
            return .success(file.markdown(isImage: contentType.hasPrefix("image/")))
        } catch {
            return .failure(Self.describe(error))
        }
    }
}

// MARK: - Read state

extension AppModel {
    /// Clears the messages locally and tells the server, so the same messages read here
    /// stop being unread everywhere else too.
    func markRead(_ ids: [Int]) async {
        guard !ids.isEmpty else { return }
        try? store?.clearUnread(ids: ids)
        try? store?.setRead(ids: ids, read: true)
        // A failure here is not worth surfacing: the next register snapshot re-reads the
        // server's own view and the counts correct themselves.
        try? await client?.markRead(messageIDs: ids)
    }
}

// MARK: - Channel groups

extension AppModel {
    var groupObservation: ValueObservation<ValueReducers.Fetch<[ChannelGroupSummary]>>? {
        store?.observeGroups()
    }

    func channelObservation(inGroup id: String?)
        -> ValueObservation<ValueReducers.Fetch<[ChannelSummary]>>?
    {
        store?.observeChannels(inGroup: id)
    }

    func createGroup(named name: String) {
        guard let group = try? store?.createGroup(name: name) else { return }
        pendingGroupToEdit = group.id
    }

    func renameGroup(id: String, to name: String) {
        try? store?.updateGroup(id: id, name: name)
    }

    func setGroupIcon(id: String, icon: Data?) {
        try? store?.updateGroup(id: id, icon: .some(icon))
    }

    func deleteGroup(id: String) {
        try? store?.deleteGroup(id: id)
    }

    func channelIDs(inGroup id: String) -> [Int] {
        (try? store?.channelIDs(inGroup: id)) ?? []
    }

    func setChannels(_ ids: [Int], inGroup groupID: String) {
        try? store?.setChannels(ids, inGroup: groupID)
    }
}

// MARK: - History

extension AppModel {
    /// Fetches the page of messages older than `oldestHeld`, and reports whether anything
    /// older still exists.
    ///
    /// End of history is `found_oldest`, never an empty page: a narrow that matches nothing
    /// returns zero messages and both flags true, which is a different thing entirely.
    /// `history_limited` is its own answer — more once existed, but retention removed it.
    func loadOlder(channelID: Int, topic: String, before oldestHeld: Int) async -> Bool {
        await loadOlder(narrow: [.channel(channelID), .topic(topic)], before: oldestHeld)
    }

    func loadOlder(dmKey: String, before oldestHeld: Int) async -> Bool {
        let ids = dmKey.split(separator: ",").compactMap { Int($0) }
        return await loadOlder(narrow: [.dm(ids)], before: oldestHeld)
    }

    private func loadOlder(narrow: [NarrowFilter], before oldestHeld: Int) async -> Bool {
        guard let client, let store, let account else { return false }
        guard let page = try? await client.messages(
            narrow: narrow, anchor: .id(oldestHeld), before: 50, after: 0, includeAnchor: false
        ) else { return false }

        try? store.save(messages: page.messages, selfUserID: account.userID)
        return !page.found_oldest && !(page.history_limited ?? false)
    }
}

// MARK: - Sidebar extras

extension AppModel {
    /// Kept observed rather than fetched on demand, because the rail shows whether the
    /// unfiled channels have anything unread even while a group is selected.
    func startSidebarObservations() {
        guard let store, sidebarObserversStarted == false else { return }
        sidebarObserversStarted = true

        observers.append(
            store.observeChannels(inGroup: nil).start(in: store.writer, onError: { _ in }) {
                [weak self] rows in
                self?.unfiledChannels = rows
            }
        )
        observers.append(
            store.observeRecentTopics().start(in: store.writer, onError: { _ in }) { [weak self] rows in
                self?.recentTopics = Dictionary(grouping: rows, by: \.channelID)
            }
        )
    }
}

// MARK: - Channel render mode

extension AppModel {
    /// `nil` hands the channel back to the detector.
    func setMode(_ mode: ChannelMode?, forChannel id: Int) {
        try? store?.setModeOverride(mode, forChannel: id)
    }

    func modeOverride(forChannel id: Int) -> ChannelMode? {
        guard let record = try? store?.channels().first(where: { $0.id == id }),
              let raw = record.modeOverride
        else { return nil }
        return ChannelMode(rawValue: raw)
    }
}
