import Testing
@testable import ZuluStore

struct ChannelModeTests {

    @Test func noTopicsIsChat() {
        #expect(ChannelModeDetector.detectsAsForum(topicMaxIDs: []) == false)
    }

    @Test func oneTopicIsChat() {
        #expect(ChannelModeDetector.detectsAsForum(topicMaxIDs: [500]) == false)
    }

    /// Several topics all active around the same time — a real forum.
    @Test func interleavedTopicsAreAForum() {
        #expect(ChannelModeDetector.detectsAsForum(topicMaxIDs: [1000, 995, 990, 980]))
    }

    /// The long tail of dead topics a chat channel accumulates. The live topic has run away
    /// from every other one, which a plain topic count would misread as a forum.
    @Test func oneRunawayTopicIsChat() {
        #expect(ChannelModeDetector.detectsAsForum(topicMaxIDs: [9000, 120, 100]) == false)
    }

    @Test func aBurstAcrossTopicsAtTheSameIdIsAForum() {
        #expect(ChannelModeDetector.detectsAsForum(topicMaxIDs: [500, 500, 500]))
    }

    /// Exactly at the threshold counts as a forum, so a channel is only demoted to chat
    /// when one topic is clearly dominant.
    @Test func halfTheSpanIsStillAForum() {
        #expect(ChannelModeDetector.detectsAsForum(topicMaxIDs: [200, 150, 100]))
    }

    @Test func orderOfInputDoesNotMatter() {
        let scrambled = ChannelModeDetector.detectsAsForum(topicMaxIDs: [100, 9000, 120])
        let sorted = ChannelModeDetector.detectsAsForum(topicMaxIDs: [9000, 120, 100])
        #expect(scrambled == sorted)
    }
}
