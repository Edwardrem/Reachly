import Foundation
import Testing
import ReachlyCore
@testable import ReachlyAgent

// MARK: - Transcript blocks

@Suite("Agent activity in the transcript")
struct AgentActivityTranscriptTests {
    private var call: AgentToolActivity {
        AgentToolActivity(id: "c1", title: "reachly: run_command", kind: "execute", status: .completed, output: "ok", locations: ["/etc/hosts:3"], input: "{}", permission: "Allowed: Allow once")
    }

    @Test func theNewBlocksAreSavedAndRead() throws {
        let messages = [
            AgentMessage.user("check"),
            AgentMessage(role: .assistant, blocks: [.notice("Qoder started a new session."), .agentToolCall(call), .plan([AgentPlanEntry(content: "Check", priority: "high", status: .completed)]), .text("Done.")], model: "Qoder CLI 0.9"),
        ]
        let decoded = try AgentTranscript.decode(AgentTranscript.encode(messages))
        #expect(decoded.map(\.blocks) == messages.map(\.blocks))
    }

    @Test func activityIsShownButNeverSentToAModel() {
        let messages = [
            AgentMessage.user("check"),
            AgentMessage(role: .assistant, blocks: [.agentToolCall(call), .text("Root is at 91%."), .plan([AgentPlanEntry(content: "Check")])]),
            AgentMessage(role: .assistant, blocks: [.notice("Qoder switched to its architect mode.")]),
            AgentMessage.user("and now?"),
        ]
        let sent = AgentTranscript.repaired(messages)
        let blocks = sent.flatMap(\.blocks)
        #expect(!blocks.contains { $0.isDisplayOnly })
        #expect(sent.contains { $0.role == .assistant && $0.blocks == [.text("Root is at 91%.")] })
        #expect(AgentTranscript.healed(messages).flatMap(\.blocks).contains(.agentToolCall(call)), "the saved transcript keeps it")
    }

    @Test func plainTextNamesTheToolCalls() {
        let text = AgentTranscript.plainText([AgentMessage(role: .assistant, blocks: [.agentToolCall(call), .text("Done.")])], assistantName: "Qoder")
        #expect(text.contains("[reachly: run_command]"))
        #expect(text.contains("Done."))
    }

    @Test func aRecordedActivityDecodesLeniently() throws {
        let json = Data(#"{"id":"c1","title":"Read","status":"something_new"}"#.utf8)
        let decoded = try JSONDecoder().decode(AgentToolActivity.self, from: json)
        #expect(decoded.kind == "other")
        #expect(decoded.output.isEmpty)
    }
}

// MARK: - The panel's session with an ACP agent

@Suite("Chat session with an ACP agent", .serialized)
@MainActor
struct AgentSessionExternalAgentTests {
    private func makeSession(_ run: FakeACPRun) -> (AgentSession, FakeProvider) {
        let provider = FakeProvider(responses: [])
        let session = AgentSession(provider: provider, systemPrompt: "Reachly context", toolRunner: AgentToolRunner(host: FakeToolHost(hosts: []), source: .agentPanel))
        session.externalAgent = run.agent
        return (session, provider)
    }

    private func waitUntilDone(_ session: AgentSession) async {
        await waitFor(.seconds(20)) { !session.isRunning }
        #expect(!session.isRunning)
    }

    @Test func theReplyBecomesOneMessageInTheOrderItCame() async throws {
        let run = FakeACPRun("basic")
        defer { run.finish() }
        let (session, provider) = makeSession(run)
        session.send("is web-01 low on disk?")
        await waitUntilDone(session)
        #expect(provider.requests.isEmpty, "the model provider is never asked")
        #expect(session.messages.count == 2)
        let reply = session.messages[1]
        #expect(reply.role == .assistant)
        #expect(reply.model == "Fake ACP 0.0.1")
        guard reply.blocks.count == 5 else {
            Issue.record("unexpected blocks: \(reply.blocks)")
            return
        }
        #expect(reply.blocks[0] == .thinking(text: "Looking at the disk.", signature: nil))
        #expect(reply.blocks[1] == .text("Root is at 91%."))
        if case .agentToolCall(let call) = reply.blocks[2] {
            #expect(call.status == .completed)
            #expect(call.output == "/dev/sda1 80G 73G 91% /")
        } else {
            Issue.record("expected the tool call third")
        }
        if case .plan(let entries) = reply.blocks[3] {
            #expect(entries.count == 2)
        } else {
            Issue.record("expected the plan fourth")
        }
        #expect(reply.blocks[4] == .text("Done."))
        #expect(session.streamingBlocks.isEmpty)
        #expect(session.lastError == nil)
    }

    @Test func stopLeavesAStoppedRowAndTheAgentRunning() async throws {
        let run = FakeACPRun("slow")
        defer { run.finish() }
        let (session, _) = makeSession(run)
        session.send("long job")
        await waitFor { session.streamingText.count > 10 }
        session.stop()
        await waitUntilDone(session)
        #expect(session.messages.last?.failure?.kind == .stopped)
        #expect(session.messages.contains { $0.role == .assistant && $0.failure == nil && $0.text.hasPrefix("tick 0") }, "what streamed stays")
        #expect(run.received("session/cancel").count == 1)
        #expect(session.canRetry)
    }

    @Test func aCrashLeavesAFailureRowThatRetries() async throws {
        let run = FakeACPRun("crash")
        defer { run.finish() }
        let (session, _) = makeSession(run)
        session.send("read the config")
        await waitUntilDone(session)
        let row = try #require(session.messages.last)
        #expect(row.failure?.kind == .error)
        #expect(row.failure?.message.contains("exit status 3") == true)
        #expect(row.blocks.contains(.text("Starting ")), "what came before the crash stays in the row")
        #expect(row.blocks.contains { if case .agentToolCall(let call) = $0 { call.status == .failed } else { false } })
        #expect(session.canRetry)
        #expect(session.retry())
        await waitUntilDone(session)
        #expect(run.launches.count == 2, "Retry starts the agent again")
    }

    @Test func theOutputLimitAndRefusalLeaveRows() async throws {
        let run = FakeACPRun("maxtokens")
        defer { run.finish() }
        let (session, _) = makeSession(run)
        session.send("write a lot")
        await waitUntilDone(session)
        #expect(session.messages.map(\.failure?.kind) == [nil, nil, .cutOff])
        #expect(session.messages[1].text == "Half a reply")

        let refusing = FakeACPRun("refusal")
        defer { refusing.finish() }
        let (other, _) = makeSession(refusing)
        other.send("something")
        await waitUntilDone(other)
        #expect(other.messages.last?.failure?.kind == .refusal)
        #expect(other.messages[1].blocks == [.notice("Qoder finished without a reply.")])
    }

    private static let newSessionNotice = AgentContentBlock.notice("Qoder started a new session, so it doesn't know the earlier messages in this conversation.")

    /// A session saved to the agent's store, with a conversation id as the panel gives it, and a model provider
    /// for the turns another provider answers.
    private func makeStoredSession(_ run: FakeACPRun, replies: [String]) -> AgentSession {
        let provider = FakeProvider(responses: replies.map { FakeProvider.reply($0) })
        let session = AgentSession(provider: provider, systemPrompt: "Reachly context", toolRunner: AgentToolRunner(host: FakeToolHost(hosts: []), source: .agentPanel, conversationID: UUID()))
        session.externalAgent = run.agent
        session.externalSessionStore = run.agent.configuration.sessionStore
        return session
    }

    /// Another provider answers: the agent process goes, as it does in the panel.
    private func switchAway(_ session: AgentSession, _ run: FakeACPRun) {
        session.externalAgent = nil
        run.agent.shutdown()
    }

    @Test func aSessionThatMissedAnotherProvidersTurnIsNotLoadedAgain() async throws {
        let run = FakeACPRun("loadable", store: true)
        defer { run.finish() }
        let session = makeStoredSession(run, replies: ["From the other provider."])
        session.send("first")
        await waitUntilDone(session)

        switchAway(session, run)
        session.send("second")
        await waitUntilDone(session)
        #expect(session.messages.last?.text == "From the other provider.")

        session.externalAgent = run.agent
        session.send("third")
        await waitUntilDone(session)
        #expect(run.received("session/load").isEmpty, "the saved session never saw the second message")
        #expect(run.received("session/new").count == 2)
        #expect(session.messages.last?.blocks.contains(Self.newSessionNotice) == true, "the transcript says so")
        let prompt = try #require(run.received("session/prompt").last)
        #expect(prompt["params"]?["prompt"]?.arrayValue?.first?["text"]?.stringValue == "Reachly context", "a new session gets the context")
    }

    @Test func anEditWhileAnotherProviderAnswersForgetsTheSavedSession() async throws {
        let run = FakeACPRun("loadable", store: true)
        defer { run.finish() }
        let session = makeStoredSession(run, replies: [])
        let key = session.externalConversationKey
        session.send("first")
        await waitUntilDone(session)
        session.send("second")
        await waitUntilDone(session)
        #expect(run.agent.configuration.sessionStore?.sessionID(for: key) == "sess-1")

        switchAway(session, run)
        let second = try #require(session.messages.last { $0.role == .user && $0.text == "second" })
        session.rewind(to: second.id)
        #expect(run.agent.configuration.sessionStore?.sessionID(for: key) == nil, "forgotten with no agent running")

        session.externalAgent = run.agent
        session.send("second, edited")
        await waitUntilDone(session)
        #expect(run.received("session/load").isEmpty)
        #expect(run.received("session/new").count == 2)
        #expect(session.messages.last?.blocks.contains(Self.newSessionNotice) == true)
    }

    @Test func aSessionIsUsedAgainOnlyWhenItSawEverythingBefore() {
        let first = AgentMessage.user("first")
        let second = AgentMessage.user("second")
        let turn = ExternalAgentTurn(conversationKey: "A", message: second, context: "", hasEarlierTurns: true, previousUserMessageID: first.id)
        #expect(ACPAgent.knowsEverythingBefore(turn, lastMessage: first.id))
        #expect(ACPAgent.knowsEverythingBefore(turn, lastMessage: second.id), "Retry sends the same message again")
        #expect(!ACPAgent.knowsEverythingBefore(turn, lastMessage: UUID()), "it missed a message")
        #expect(!ACPAgent.knowsEverythingBefore(turn, lastMessage: nil), "saved before Reachly kept the message, or never sent one")
        let opening = ExternalAgentTurn(conversationKey: "A", message: first, context: "", hasEarlierTurns: false)
        #expect(ACPAgent.knowsEverythingBefore(opening, lastMessage: nil))
    }

    @Test func theSameAgentAnsweringEveryTurnLoadsItsSessionBack() async throws {
        let run = FakeACPRun("loadable", store: true)
        defer { run.finish() }
        let session = makeStoredSession(run, replies: [])
        session.send("first")
        await waitUntilDone(session)
        run.agent.shutdown()
        session.send("second")
        await waitUntilDone(session)
        #expect(run.received("session/load").count == 1, "nothing was missed, so the session comes back")
        #expect(!(session.messages.last?.blocks.contains(Self.newSessionNotice) ?? true))
    }

    @Test func editingAnEarlierMessageStartsANewAgentSession() async throws {
        let run = FakeACPRun("basic")
        defer { run.finish() }
        let (session, _) = makeSession(run)
        session.send("first")
        await waitUntilDone(session)
        let first = try #require(session.messages.first)
        session.rewind(to: first.id)
        session.send("first, edited")
        await waitUntilDone(session)
        #expect(run.received("session/new").count == 2)
    }
}

// MARK: - Server commands a turn asked for

@Suite("Server commands an ACP agent asked for", .serialized)
@MainActor
struct ExternalAgentApprovalTests {
    /// Reachly's MCP server with web-01, which asks before every command, and sheets that wait.
    private func startServer() async throws -> (MCPServer, FakeToolHost, WaitingApprovals, Int) {
        let host = FakeToolHost(hosts: [FakeToolHost.web])
        let approvals = WaitingApprovals()
        host.approval = { request in await approvals.ask(request) }
        let server = MCPServer(toolHost: host, token: "secret-token", serverVersion: "test")
        let port = try await server.start(port: 0)
        return (server, host, approvals, port)
    }

    @Test func stopTakesDownTheSheetForACommandTheAgentAskedFor() async throws {
        let (server, host, approvals, port) = try await startServer()
        defer { Task { await server.stop() } }
        let run = FakeACPRun("mcp-call", environment: ["FAKE_ACP_MCP_PORT": "\(port)", "FAKE_ACP_MCP_TOKEN": "secret-token"])
        defer { run.finish() }
        run.agent.turnEndHandler = { key in approvals.withdraw(from: "Qoder", conversationKey: key) }
        let conversation = UUID()
        let task = Task { try await run.run(run.turn(key: conversation.uuidString)) }
        await waitFor { !approvals.waiting.isEmpty }
        #expect(approvals.waiting.first?.request.requester == "Qoder")
        #expect(approvals.waiting.first?.request.conversationID == conversation)

        task.cancel()
        // Taken down at Stop, without waiting for the agent to answer the prompt.
        await waitFor(.seconds(2)) { approvals.waiting.isEmpty }
        #expect(approvals.waiting.isEmpty)
        #expect(try await task.value == .cancelled)
        if case .withdrawn = approvals.answers.first {} else { Issue.record("expected the sheet withdrawn, got \(approvals.answers)") }
        await waitFor { !run.httpAnswers.isEmpty }
        #expect(run.httpAnswers.first?.contains("Not run") == true, "the agent hears that nothing ran")
        #expect(host.executed.isEmpty, "clicking Run afterwards can't run it: the sheet is gone")
        #expect(host.auditRecords.map(\.decision) == [.cancelled])
        #expect(host.auditRecords.first?.conversationID == conversation)
    }

    @Test func aCrashTakesDownTheSheetForACommandTheAgentAskedFor() async throws {
        let (server, host, approvals, port) = try await startServer()
        defer { Task { await server.stop() } }
        let directory = FileManager.default.temporaryDirectory.appending(path: "reachly-acp-\(UUID().uuidString)", directoryHint: .isDirectory)
        let trigger = directory.appending(path: "crash-now")
        let run = FakeACPRun("mcp-crash", directory: directory, environment: ["FAKE_ACP_MCP_PORT": "\(port)", "FAKE_ACP_MCP_TOKEN": "secret-token", "FAKE_ACP_TRIGGER": trigger.path])
        defer { run.finish() }
        run.agent.turnEndHandler = { key in approvals.withdraw(from: "Qoder", conversationKey: key) }
        let task = Task { try await run.run(run.turn(key: UUID().uuidString)) }
        await waitFor { !approvals.waiting.isEmpty }
        #expect(approvals.waiting.count == 1)
        FileManager.default.createFile(atPath: trigger.path, contents: Data())
        await #expect(throws: ExternalAgentFailure.self) { _ = try await task.value }
        await waitFor(.seconds(5)) { approvals.waiting.isEmpty }
        #expect(approvals.waiting.isEmpty)
        #expect(host.executed.isEmpty)
        #expect(host.auditRecords.map(\.decision) == [.cancelled])
    }

    @Test func aRequestFromTheAgentIsMatchedToItsConversation() {
        let conversation = UUID()
        let request = AgentApprovalRequest(source: .mcp, host: FakeToolHost.web, tool: "run_command", command: "df -h", reason: "", detail: "", isDestructive: false, requester: "Qoder", conversationID: conversation)
        #expect(request.isFrom("Qoder", conversationKey: conversation.uuidString))
        #expect(!request.isFrom("Qoder", conversationKey: UUID().uuidString))
        #expect(!request.isFrom("Claude", conversationKey: conversation.uuidString))
        var plain = request
        plain.requester = nil
        #expect(!plain.isFrom("Qoder", conversationKey: conversation.uuidString), "another MCP client's sheet stays")
        var unnamed = request
        unnamed.conversationID = nil
        #expect(unnamed.isFrom("Qoder", conversationKey: conversation.uuidString))
    }
}

// MARK: - MCP callers

@Suite("MCP callers Reachly started")
struct MCPCallerTests {
    @Test func onlyKnownClientsAndWellFormedIdsAreTaken() {
        let id = UUID()
        #expect(MCPServer.caller(client: "qoder", conversation: id.uuidString) == MCPServer.Caller(requester: "Qoder", conversationID: id))
        #expect(MCPServer.caller(client: "someone-else", conversation: id.uuidString) == .unknown, "an unknown client is an ordinary MCP client")
        #expect(MCPServer.caller(client: "QODER", conversation: "not-a-uuid") == MCPServer.Caller(requester: "Qoder", conversationID: nil))
        #expect(MCPServer.caller(client: nil, conversation: id.uuidString) == .unknown)
    }
}

@Suite("Context for an external agent")
struct ExternalAgentContextTests {
    @Test func externalAgentContextNamesTheMCPServerAndTheHosts() {
        let host = AgentHostInfo(id: UUID(), name: "web-01", hostname: "10.0.0.5", port: 22, username: "deploy", group: "prod", permission: .ask)
        let context = AgentSystemPrompt.externalAgentContext(hosts: [host], focus: host, agentName: "Qoder")
        #expect(context.contains("MCP server named \"reachly\""))
        #expect(context.contains("- web-01: deploy@10.0.0.5, ask, group prod"))
        #expect(context.contains("about the host \"web-01\""))
        #expect(context.contains("Do not reach these servers any other way"))
    }
}
