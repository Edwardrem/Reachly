import Foundation
import Testing
@testable import ReachlyAgent

/// A send that failed before any reply leaves two user turns in a row; the
/// OpenAI-compatible wire format sends them as one, since some endpoints
/// (DeepSeek's reasoner) reject consecutive user messages.
@Suite("OpenAI-compatible user turn merge")
struct UserTurnMergeTests {
    @Test func consecutiveUserTextTurnsBecomeOne() {
        let json = OpenAICompatibleProvider.messagesJSON([.user("first"), .user("second")])
        #expect(json.count == 1)
        #expect(json.first?["role"]?.stringValue == "user")
        #expect(json.first?["content"]?.stringValue == "first\n\nsecond")
    }

    @Test func turnsSeparatedByAReplyStayApart() {
        let json = OpenAICompatibleProvider.messagesJSON([.user("first"), AgentMessage(role: .assistant, blocks: [.text("ok")]), .user("second")])
        #expect(json.map { $0["role"]?.stringValue } == ["user", "assistant", "user"])
    }

    @Test func partsAndTextMergeIntoOnePartList() throws {
        let image: JSONValue = ["type": "image_url", "image_url": ["url": "data:image/png;base64,AA=="]]
        let merged = OpenAICompatibleProvider.mergingConsecutiveUserTurns([
            ["role": "user", "content": .array([image])],
            ["role": "user", "content": "what is this?"],
        ])
        #expect(merged.count == 1)
        let parts = try #require(merged.first?["content"]?.arrayValue)
        #expect(parts.count == 2)
        #expect(parts[0]["type"]?.stringValue == "image_url")
        #expect(parts[1]["text"]?.stringValue == "what is this?")
    }

    @Test func toolMessagesAreNeverMerged() {
        let merged = OpenAICompatibleProvider.mergingConsecutiveUserTurns([
            ["role": "tool", "tool_call_id": "a", "content": "one"],
            ["role": "tool", "tool_call_id": "b", "content": "two"],
            ["role": "user", "content": "next"],
        ])
        #expect(merged.count == 3)
    }
}
