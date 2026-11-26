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
