import Foundation
import Testing
import ReachlyCore
@testable import ReachlyAgent

/// A reply that fails leaves a failure row in the transcript, where it failed:
/// kept and saved, never sent, and the latest one can be retried.
@Suite("Failed replies in the transcript")
@MainActor
struct AgentSessionFailureTests {
    private func makeSession(_ provider: FakeProvider, host: FakeToolHost = FakeToolHost(hosts: [])) -> AgentSession {
        AgentSession(provider: provider, systemPrompt: "sys", toolRunner: AgentToolRunner(host: host, source: .agentPanel))
    }

    private func waitUntilDone(_ session: AgentSession) async {
        await waitFor { !session.isRunning }
        #expect(!session.isRunning)
    }

    @Test func failureIsRecordedWithWhatStreamedBeforeIt() async {
        let provider = FakeProvider(responses: [])
        provider.failures[0] = FakeStreamFailure(thinking: "Checking the disk first.", text: "Root is at", error: LLMError.api(type: "overloaded_error", message: "Overloaded"))
        let session = makeSession(provider)
        var saved: [AgentMessage] = []
        session.transcriptDidChange = { saved = session.messages }

        session.send("is web-01 low on disk?")
        await waitUntilDone(session)

        #expect(session.messages.count == 2)
        let row = session.messages[1]
        #expect(row.role == .assistant)
        #expect(row.blocks == [
            .thinking(text: "Checking the disk first.", signature: nil),
            .text("Root is at"),
            .failure(AgentFailure(kind: .error, message: "Overloaded (overloaded_error)")),
        ], "the reasoning and text that streamed stay, in order, above the failure")
        #expect(row.failure?.summary == "The request failed: Overloaded (overloaded_error)")
        #expect(session.lastError == "Overloaded (overloaded_error)")
        #expect(saved == session.messages, "the row is saved with the conversation")
        #expect(session.streamingText.isEmpty)
        #expect(session.streamingThinking.isEmpty)
        #expect(session.canRetry)
    }

    @Test func failureRowsAreNeverSentToTheModel() async {
        let provider = FakeProvider(responses: [FakeProvider.reply("Root is at 91%.")])
        provider.failures[0] = FakeStreamFailure(thinking: "private reasoning", text: "half a sentence", error: LLMError.httpStatus(529, "Overloaded"))
        let session = makeSession(provider)

        session.send("first")
        await waitUntilDone(session)
        session.send("second")
        await waitUntilDone(session)

        #expect(session.messages.map(\.failure?.kind) == [nil, .error, nil, nil], "the row stays after later messages")
        #expect(!session.canRetry, "only a row at the end of the conversation can be retried")
        let sent = provider.requests[1].messages
        #expect(sent.allSatisfy { $0.failure == nil })
        #expect(sent.map(\.text) == ["first", "second"], "neither the row nor its partial reply is sent")
        #expect(!sent.contains { $0.blocks.contains(.thinking(text: "private reasoning", signature: nil)) })
    }

    @Test func retryRunsTheTurnAgainWithoutRepeatingTheMessage() async {
        let provider = FakeProvider(responses: [FakeProvider.reply("Disk is fine.")])
        provider.failures[0] = FakeStreamFailure(text: "Let me", error: URLError(.networkConnectionLost))
        let session = makeSession(provider)
        var saved: [AgentMessage] = []
        session.transcriptDidChange = { saved = session.messages }

        session.send("check the disk")
        await waitUntilDone(session)
        #expect(session.messages.last?.failure?.kind == .error)

        session.retry()
        await waitUntilDone(session)
        #expect(provider.requests.count == 2)
        #expect(provider.requests[1].messages.map(\.text) == ["check the disk"])
        #expect(session.messages.map(\.text) == ["check the disk", "Disk is fine."])
        #expect(session.messages.allSatisfy { $0.failure == nil }, "the retried row is gone")
        #expect(saved == session.messages)
        #expect(session.lastError == nil)
        #expect(!session.canRetry)

        // Nothing to retry: the call does nothing.
        session.retry()
        #expect(!session.isRunning)
        #expect(provider.requests.count == 2)
    }

    @Test func retryAfterAToolRoundKeepsTheRoundAndAsksAgain() async {
        let host = FakeToolHost(hosts: [FakeToolHost.web])
        let provider = FakeProvider(responses: [
            FakeProvider.toolCall(.runCommand, ["host": "web-01", "command": "df -h", "reason": "disk"]),
            FakeProvider.reply("Disk is fine."),
        ])
        provider.failures[1] = FakeStreamFailure(error: LLMError.httpStatus(500, ""))
        let session = makeSession(provider, host: host)

        session.send("check the disk")
        await waitUntilDone(session)
        #expect(session.messages.map(\.role) == [.user, .assistant, .user, .assistant])
        #expect(session.messages.last?.blocks == [.failure(AgentFailure(kind: .error, message: "The API returned HTTP 500."))], "nothing streamed, so the row holds only the failure")

        session.retry()
        await waitUntilDone(session)
        #expect(host.executed.map(\.command) == ["df -h"], "the finished tool round does not run again")
        #expect(provider.requests.count == 3)
        #expect(provider.requests[2].messages.count == 3)
        #expect(toolPairingIsValid(provider.requests[2].messages))
        #expect(session.messages.last?.text == "Disk is fine.")
        #expect(session.messages.allSatisfy { $0.failure == nil })
        #expect(toolPairingIsValid(session.messages))
    }

    @Test func retryAfterACutOffReplyAsksAgainInPlaceOfIt() async {
        let provider = FakeProvider(responses: [
            FakeProvider.reply("A long answer", stop: .maxTokens),
            FakeProvider.reply("A shorter answer."),
        ])
        let session = makeSession(provider)

        session.send("explain")
        await waitUntilDone(session)
        #expect(session.messages.map(\.failure?.kind) == [nil, nil, .cutOff])
        #expect(session.messages[1].text == "A long answer", "the cut-off reply stays in view")

        session.retry()
        await waitUntilDone(session)
        #expect(provider.requests[1].messages.map(\.text) == ["explain"], "the request ends with the user's turn, not the cut-off reply")
        #expect(session.messages.map(\.text) == ["explain", "A shorter answer."])
    }

    @Test func refusalLeavesARow() async {
        let provider = FakeProvider(responses: [LLMResponse(message: AgentMessage(role: .assistant, blocks: []), stopReason: .refusal, model: "m", usage: LLMUsage(), refusalCategory: "cyber")])
        let session = makeSession(provider)
        session.send("hi")
        await waitUntilDone(session)
        #expect(session.messages.last?.failure == AgentFailure(kind: .refusal, message: "The model declined to continue (cyber)."))
        #expect(session.canRetry)
    }

    @Test func stopKeepsTheStreamedReplyAndAddsARow() async throws {
        let provider = FakeProvider(responses: [FakeProvider.reply("Root is at 91%"), FakeProvider.reply("Root is at 91%, /data at 42%.")])
        provider.holdBeforeDone = { try? await Task.sleep(for: .seconds(2)) }
        let session = makeSession(provider)

        session.send("check the disk")
        await waitFor { session.streamingText.contains("91%") }
        session.stop()
        await waitUntilDone(session)

        try #require(session.messages.count == 3, "the stop came before the reply streamed")
        #expect(session.messages[1].role == .assistant)
        #expect(session.messages[1].failure == nil, "streamed text is a reply the model sees next time, as before")
        #expect(session.messages[1].text.hasPrefix("Root is at 91%"))
        #expect(session.messages[2].blocks == [.failure(AgentFailure(kind: .stopped, message: "Stopped."))])
        #expect(session.lastError == "Stopped.")

        // Retry asks again in place of the stopped reply.
        provider.holdBeforeDone = nil
        session.retry()
        await waitUntilDone(session)
        #expect(provider.requests.last?.messages.map(\.text) == ["check the disk"])
        #expect(session.messages.map(\.text) == ["check the disk", "Root is at 91%, /data at 42%."])
    }

    @Test func toolRoundLimitLeavesARowThatRetryContinues() async {
        let host = FakeToolHost(hosts: [FakeToolHost.web])
        let provider = FakeProvider(responses: [
            FakeProvider.toolCall(.runCommand, ["host": "web-01", "command": "uptime", "reason": "load"]),
            FakeProvider.reply("Load is low."),
        ])
        let session = makeSession(provider, host: host)
        session.maxToolRounds = 1

        session.send("check the load")
        await waitUntilDone(session)
        #expect(session.messages.last?.failure == AgentFailure(kind: .toolRounds, message: "Stopped after 1 rounds of tool calls. Send a message to continue."))
        #expect(toolPairingIsValid(AgentTranscript.repaired(session.messages)))

        session.retry()
        await waitUntilDone(session)
        #expect(session.messages.last?.text == "Load is low.")
        #expect(session.messages.filter { $0.role == .user && !$0.text.isEmpty }.count == 1, "the user's message is not repeated")
        #expect(host.executed.map(\.command) == ["uptime"])
    }

    @Test func setupFailureKeepsTheMessageAndItsFiles() async {
        let provider = FakeProvider(responses: [FakeProvider.reply("Got it.")])
        let session = makeSession(provider)
        var saves = 0
        session.transcriptDidChange = { saves += 1 }
        let file = AgentAttachment(fileName: "notes.txt", mediaType: "text/plain", byteCount: 5, path: "/tmp/reachly-notes.txt")
        let reason = "Add your Caimex API key in Settings › AI Integration to start."

        session.recordUnsent("  read this  ", attachments: [file], reason: reason)
        #expect(!session.isRunning)
        #expect(provider.requests.isEmpty, "nothing was sent")
        #expect(session.messages.count == 2)
        #expect(session.messages[0].role == .user)
        #expect(session.messages[0].text == "read this")
        #expect(session.messages[0].attachments == [file], "the files stay with the message")
        #expect(session.messages[1].failure == AgentFailure(kind: .setup, message: reason))
        #expect(session.messages[1].failure?.summary == "Not sent: \(reason)")
        #expect(session.lastError == reason)
        #expect(saves == 1, "saved once, so a new conversation is created with the message in it")
        #expect(session.canRetry)

        // A retry that cannot start either updates the row instead of adding another.
        session.recordSetupFailure("Touch ID was cancelled.")
        #expect(session.messages.count == 2)
        #expect(session.messages[1].failure == AgentFailure(kind: .setup, message: "Touch ID was cancelled."))
        #expect(saves == 2)

        session.retry()
        await waitUntilDone(session)
        #expect(provider.requests.count == 1)
        #expect(provider.requests[0].messages.count == 1)
        #expect(provider.requests[0].messages[0].attachments == [file])
        #expect(session.messages.map(\.text) == ["read this", "Got it."])
        #expect(session.messages.filter { $0.role == .user }.count == 1)
    }

    @Test func retryThatCannotStartKeepsTheReplyThatFailed() async {
        let provider = FakeProvider(responses: [])
        provider.failures[0] = FakeStreamFailure(thinking: "Looking first.", text: "Root is at", error: LLMError.api(type: "overloaded_error", message: "Overloaded"))
        let session = makeSession(provider)
        session.send("check the disk")
        await waitUntilDone(session)

        #expect(session.recordSetupFailure("Touch ID was cancelled."))
        let row = session.messages[1]
        #expect(session.messages.count == 2, "no second row")
        #expect(Array(row.blocks.prefix(2)) == [.thinking(text: "Looking first.", signature: nil), .text("Root is at")])
        #expect(row.failure == AgentFailure(kind: .error, message: "Overloaded (overloaded_error)", retryError: "Touch ID was cancelled."), "the reply did fail; it is not called unsent")
        #expect(row.failure?.summary == "The request failed: Overloaded (overloaded_error). Retry did not start: Touch ID was cancelled.")
        #expect(session.lastError == "Touch ID was cancelled.")

        // A second failed retry replaces the reason rather than adding to it.
        session.recordSetupFailure("Add your Caimex API key in Settings › AI Integration to start.")
        #expect(session.messages[1].failure?.retryError == "Add your Caimex API key in Settings › AI Integration to start.")
        #expect(session.messages[1].failure?.message == "Overloaded (overloaded_error)")
        #expect(session.canRetry)
    }

    @Test func retryThatCannotStartAfterACutOffReplyKeepsTheCutOff() async {
        let provider = FakeProvider(responses: [FakeProvider.reply("A long answer", stop: .maxTokens)])
        let session = makeSession(provider)
        session.send("explain")
        await waitUntilDone(session)

        session.recordSetupFailure("Touch ID was cancelled.")
        #expect(session.messages.last?.failure?.kind == .cutOff)
        #expect(session.messages.last?.failure?.summary == "The reply was cut off at the model's output limit. Send \"continue\" to go on. Retry did not start: Touch ID was cancelled.")
    }

    @Test func retryStartedInAnotherConversationChangesNothing() async {
        let provider = FakeProvider(responses: [FakeProvider.reply("for A")])
        provider.failures[0] = FakeStreamFailure(error: LLMError.httpStatus(503, ""))
        let session = makeSession(provider)
        session.send("question in A")
        await waitUntilDone(session)
        #expect(session.canRetry)
        let inA = session.conversationToken

        // While Retry waited on Touch ID, B was opened from History. It ends in a row of its own.
        let b: [AgentMessage] = [.user("question in B"), AgentMessage(failure: AgentFailure(kind: .error, message: "Overloaded"))]
        session.replace(messages: b)
        var saves = 0
        session.transcriptDidChange = { saves += 1 }
        #expect(session.conversationToken != inA)

        #expect(!session.retry(in: inA), "A's retry does not run B's turn")
        #expect(!session.recordSetupFailure("Touch ID was cancelled.", in: inA), "nor rewrite B's row")
        #expect(!session.isRunning)
        #expect(provider.requests.count == 1)
        #expect(session.messages == b)
        #expect(saves == 0, "nothing was saved into B")

        // B's own token acts on B.
        #expect(session.retry(in: session.conversationToken))
        await waitUntilDone(session)
        #expect(session.messages.map(\.text) == ["question in B", "for A"])
    }

    @Test func messageWrittenInAnotherConversationIsNotDelivered() async {
        let provider = FakeProvider(responses: [FakeProvider.reply("ok")])
        let session = makeSession(provider)
        let inA = session.conversationToken
        let file = AgentAttachment(fileName: "notes.txt", mediaType: "text/plain", byteCount: 5, path: "/tmp/reachly-notes.txt")

        session.replace(messages: [.user("B"), AgentMessage(role: .assistant, blocks: [.text("hello from B")])])
        let inB = session.conversationToken
        var saves = 0
        session.transcriptDidChange = { saves += 1 }

        #expect(!session.send("typed in A", attachments: [file], in: inA))
        #expect(!session.recordUnsent("typed in A", attachments: [file], reason: "No key", in: inA))
        #expect(session.messages.map(\.text) == ["B", "hello from B"])
        #expect(!session.messages.contains { !$0.attachments.isEmpty })
        #expect(provider.requests.isEmpty)
        #expect(saves == 0)

        // Work in the conversation that is still showing keeps its token throughout.
        #expect(session.send("typed in B", in: inB))
        await waitUntilDone(session)
        #expect(session.conversationToken == inB)
        #expect(session.rewind(to: session.messages[2].id) != nil)
        #expect(session.recordUnsent("again in B", reason: "No key", in: inB))
        #expect(session.retry(in: inB))
        await waitUntilDone(session)
        #expect(session.conversationToken == inB)
        #expect(session.messages.map(\.text) == ["B", "hello from B", "again in B", "(no scripted reply)"])
    }

    @Test func emptyUnsentMessageIsIgnored() {
        let session = makeSession(FakeProvider(responses: []))
        session.recordUnsent("   ", reason: "No key")
        #expect(session.messages.isEmpty)
        #expect(!session.canRetry)
    }

    @Test func failureRowsSurviveReplaceAndRewind() async {
        let provider = FakeProvider(responses: [FakeProvider.reply("one"), FakeProvider.reply("two")])
        provider.failures[1] = FakeStreamFailure(error: LLMError.httpStatus(503, ""))
        let session = makeSession(provider)
        session.send("first")
        await waitUntilDone(session)
        session.send("second")
        await waitUntilDone(session)
        let stored = try? AgentTranscript.decode(AgentTranscript.encode(session.messages))
        #expect(stored?.last?.failure?.kind == .error)

        // Reopening from History shows the row again.
        session.replace(messages: [])
        session.replace(messages: stored ?? [])
        #expect(session.messages.map(\.failure?.kind) == [nil, nil, nil, .error])
        #expect(session.canRetry)

        // Editing the failed message drops its row with it.
        let dropped = session.rewind(to: session.messages[2].id)
        #expect(dropped?.text == "second")
        #expect(session.messages.map(\.text) == ["first", "one"])
        #expect(session.messages.allSatisfy { $0.failure == nil })
    }
}
