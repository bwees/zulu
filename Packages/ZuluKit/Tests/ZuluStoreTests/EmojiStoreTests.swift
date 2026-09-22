import Foundation
import Testing
import ZulipAPI
import ZuluEmoji
@testable import ZuluStore

private func decode<T: Decodable>(_ json: String, as type: T.Type = T.self) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(json.utf8))
}

struct EmojiStoreTests {

    @Test func realmEmojiSurviveARoundTripThroughTheDatabase() throws {
        let store = try ZuluStore(url: nil)
        let emoji: [String: RealmEmoji] = try decode("""
            {"1": {"id": "1", "name": "green_tick",
                   "source_url": "/user_avatars/2/emoji/images/dbe43627.png",
                   "still_url": null, "deactivated": false, "author_id": 5},
             "2": {"id": "2", "name": "retired",
                   "source_url": "/user_avatars/2/emoji/images/aa11.png",
                   "deactivated": true, "author_id": 5}}
            """)
        try store.replaceRealmEmoji(emoji)

        let catalogue = EmojiCatalogue(realmEmoji: try store.realmEmoji().map(\.item))
        #expect(catalogue.resolve(name: "green_tick")?.imageURL
            == "/user_avatars/2/emoji/images/dbe43627.png")
        #expect(catalogue.resolve(name: "retired") == nil)
    }

    /// Animated emoji uploaded before Zulip 5 have no `still_url` at all, which the
    /// schema does not admit but the wire does.
    @Test func aMissingStillURLIsNotAFailure() throws {
        let emoji: RealmEmoji = try decode("""
            {"id": "3", "name": "parrot", "source_url": "/x.gif", "author_id": 1}
            """)
        #expect(emoji.still_url == nil)
        #expect(emoji.deactivated == nil)
        #expect(RealmEmojiRecord(from: emoji).deactivated == false)
    }

    @Test func theCachedUnicodeTableKeepsItsETagForTheNextFetch() throws {
        let store = try ZuluStore(url: nil)
        let json = Data(#"{"code_to_names": {"1f44d": ["+1", "thumbs_up"]}}"#.utf8)
        try store.saveServerEmojiData(url: "https://realm/static/emoji.json", etag: #"W/"abc""#, json: json)

        let cached = try #require(try store.cachedServerEmojiData())
        #expect(cached.etag == #"W/"abc""#)

        let table = try JSONDecoder().decode(ServerEmojiData.self, from: cached.json)
        #expect(EmojiCatalogue(unicode: table).resolve(name: "thumbs_up")?.code == "1f44d")
    }

    @Test func clearingTheStoreRemovesTheEmojiToo() throws {
        let store = try ZuluStore(url: nil)
        try store.saveServerEmojiData(url: "https://realm/e.json", etag: nil, json: Data("{}".utf8))
        try store.clearAll()
        #expect(try store.cachedServerEmojiData() == nil)
    }
}

struct UserGroupTests {

    private let groups: [RealmUserGroup] = try! decode("""
        [{"id": 1, "name": "support", "description": "", "members": [7],
          "direct_subgroup_ids": [], "is_system_group": false, "can_mention_group": 2},
         {"id": 2, "name": "staff", "description": "", "members": [7, 8],
          "direct_subgroup_ids": [], "is_system_group": false, "can_mention_group": 2},
         {"id": 3, "name": "leads", "description": "", "members": [9],
          "direct_subgroup_ids": [1], "is_system_group": false, "can_mention_group": 3},
         {"id": 4, "name": "nobody", "description": "", "members": [],
          "direct_subgroup_ids": [], "is_system_group": true,
          "can_mention_group": {"direct_members": [8], "direct_subgroups": []}}]
        """)

    @Test func membershipDecidesWhoMayMentionAGroupOutLoud() {
        #expect(RealmUserGroup.mentionable(among: groups, by: 8) == [1, 2, 4])
        // Nobody outside every group may mention any of them out loud.
        #expect(RealmUserGroup.mentionable(among: groups, by: 99).isEmpty)
    }

    /// A group's membership includes everyone in its subgroups, so being in `support`
    /// is being in `leads` — which is the whole reason this is resolved transitively
    /// rather than by reading `members`.
    @Test func subgroupMembershipCountsAsMembership() {
        #expect(RealmUserGroup.mentionable(among: groups, by: 7).contains(3))
        #expect(!RealmUserGroup.mentionable(among: groups, by: 8).contains(3))
    }

    /// An anonymous setting spells the permitted people out inline instead of naming a
    /// group, and has to decode either way.
    @Test func anAnonymousGroupSettingDecodes() {
        #expect(groups[3].can_mention_group == .anonymous(members: [8], subgroups: []))
        #expect(groups[0].can_mention_group == .group(2))
    }

    @Test func groupsAreStoredWithTheirMentionabilityAlreadyDecided() throws {
        let store = try ZuluStore(url: nil)
        try store.replaceUserGroups(groups, selfUserID: 7)
        let stored = try store.userGroups().sorted { $0.id < $1.id }
        #expect(stored.map(\.name) == ["support", "staff", "leads", "nobody"])
        #expect(stored.map(\.isMentionable) == [true, true, true, false])
    }
}
