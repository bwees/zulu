import ZuluCompose
import ZuluStore

/// One conversation: a channel topic, or a DM.
///
/// Shared rather than owned by a view, because both shells navigate by it and the
/// model layer under them keys drafts, history and read state on it.
enum ConversationSource: Equatable, Hashable {
    case topic(channelID: Int, name: String, channelName: String)
    case dm(key: String)
}


/// The message a composer is about to answer.
///
/// Held as the original message rather than as quote markdown: the markdown is built at
/// send time, so the person sees who they are replying to instead of a wall of fenced
/// quote syntax in the field they are typing into.
struct ReplyDraft: Equatable, Identifiable {
    let messageID: Int
    let author: String
    let authorID: Int?
    let preview: String

    var id: Int { messageID }

    @MainActor
    init(message: MessageRecord) {
        messageID = message.id
        author = message.senderName
        authorID = message.senderID
        preview = MessageActionsController.plainText(of: message.renderedContent)
    }
}

extension ReplyDraft {
    init(_ saved: SavedReply) {
        messageID = saved.messageID
        author = saved.author
        authorID = saved.authorID
        preview = saved.preview
    }

    var saved: SavedReply {
        SavedReply(messageID: messageID, author: author, authorID: authorID, preview: preview)
    }
}

extension AppModel {
    func savedDraft(in source: ConversationSource) -> (text: String, reply: ReplyDraft?)? {
        guard let saved = drafts?.draft(for: ConversationKey.of(source)) else { return nil }
        return (saved.text, saved.reply.map(ReplyDraft.init))
    }

    func saveDraft(_ text: String, replyingTo reply: ReplyDraft?, in source: ConversationSource) {
        drafts?.save(SavedDraft(text: text, reply: reply?.saved), for: ConversationKey.of(source))
    }
}
