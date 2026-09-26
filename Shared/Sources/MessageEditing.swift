import Foundation
import ZulipAPI
import ZuluStore

/// A message already sent, open in the composer to be changed.
struct EditDraft: Equatable {
    let messageID: Int
    /// The markdown as the server has it, so saving an unchanged edit costs nothing.
    let original: String
}

extension AppModel {
    /// Only for your own messages. Whether the realm still allows it, after its edit
    /// window has passed, is the server's call, and its refusal is shown as it comes.
    func isOwn(_ message: MessageRecord) -> Bool { message.senderID == selfUserID }

    /// Fetches the markdown, since the store only keeps the rendered HTML, and hands it
    /// to the composer for that conversation.
    func beginEditing(_ message: MessageRecord) async -> String? {
        guard let account else { return "Not signed in." }
        do {
            let raw = try await ZulipClient(account: account).rawContent(ofMessage: message.id)
            ComposerInbox.shared.deliver(
                edit: EditDraft(messageID: message.id, original: raw), to: ConversationKey.of(message)
            )
            return nil
        } catch {
            return Self.describe(error)
        }
    }

    /// What pressing up in an empty composer does.
    func beginEditingLatestMessage(in source: ConversationSource) async {
        guard let store = storeForReading, let selfUserID else { return }
        let latest: MessageRecord?? = switch source {
        case .topic(let channelID, let name, _):
            try? store.latestMessage(from: selfUserID, channelID: channelID, topic: name)
        case .dm(let key):
            try? store.latestMessage(from: selfUserID, dmKey: key)
        }
        guard let message = latest.flatMap({ $0 }) else { return }
        _ = await beginEditing(message)
    }

    /// The store is left alone: the server's `update_message` event carries the newly
    /// rendered HTML, which is the only rendering of the markdown there is.
    func save(_ edit: EditDraft, as content: String) async -> String? {
        guard let account else { return "Not signed in." }
        do {
            try await ZulipClient(account: account).editMessage(edit.messageID, content: content)
            return nil
        } catch {
            return Self.describe(error)
        }
    }

    func delete(_ message: MessageRecord) async -> String? {
        guard let account else { return "Not signed in." }
        do {
            try await ZulipClient(account: account).deleteMessage(message.id)
            // Without waiting for the event, so the row goes the moment it is confirmed.
            try? storeForReading?.deleteMessages(ids: [message.id])
            return nil
        } catch {
            return Self.describe(error)
        }
    }
}

/// A composer taken over to change a message already sent. Whatever was being typed is
/// put aside and handed back once the edit is saved or cancelled.
@MainActor
@Observable
final class ComposerEditMode {
    private(set) var editing: EditDraft?
    private(set) var isSaving = false

    private var setAside = SetAside()

    struct SetAside {
        var text = ""
        var reply: ReplyDraft?
    }

    private let model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    var isEditing: Bool { editing != nil }

    /// Editing a second message while already editing one keeps the first thing put
    /// aside, which is what was being typed before any of it.
    func begin(_ edit: EditDraft, settingAside text: String, reply: ReplyDraft?) {
        if editing == nil { setAside = SetAside(text: text, reply: reply) }
        editing = edit
    }

    func cancel() -> SetAside {
        editing = nil
        defer { setAside = SetAside() }
        return setAside
    }

    /// Stays in edit mode when the server refuses, so the changed text is not lost.
    func save(_ text: String) async -> Result<SetAside, EditError> {
        guard let editing, !isSaving else { return .failure(.busy) }
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return .failure(.empty) }
        guard content != editing.original.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return .success(cancel())
        }

        isSaving = true
        defer { isSaving = false }
        if let reason = await model.save(editing, as: content) { return .failure(.refused(reason)) }
        return .success(cancel())
    }

    enum EditError: Error {
        case busy
        case empty
        case refused(String)

        var message: String? {
            switch self {
            case .busy: nil
            case .empty: "A message cannot be empty. Delete it instead."
            case .refused(let reason): reason
            }
        }
    }
}
