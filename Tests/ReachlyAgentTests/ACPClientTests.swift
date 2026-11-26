import Foundation
import Synchronization
import Testing
import ReachlyCore
@testable import ReachlyAgent

// MARK: - Framing

@Suite("ACP stdio framing")
struct ACPFramingTests {
    @Test func messagesSplitAcrossChunksComeOutWhole() {
        var framer = ACPLineFramer()
        #expect(framer.append(Data(#"{"a":"#.utf8)).isEmpty)
        #expect(framer.append(Data(#"1}"#.utf8)).isEmpty, "no newline yet")
        let lines = framer.append(Data("\n{\"b\":2}\n{\"c\"".utf8))
        #expect(lines.map { String(decoding: $0, as: UTF8.self) } == [#"{"a":1}"#, #"{"b":2}"#])
        #expect(framer.append(Data(":3}\n".utf8)).map { String(decoding: $0, as: UTF8.self) } == [#"{"c":3}"#])
    }

    @Test func carriageReturnsAndBlankLinesAreDropped() {
        var framer = ACPLineFramer()
        let lines = framer.append(Data("{\"a\":1}\r\n\n   \n{\"b\":2}\n".utf8))
        #expect(lines.map { String(decoding: $0, as: UTF8.self) } == [#"{"a":1}"#, #"{"b":2}"#])
    }

    @Test func aLastLineWithoutNewlineComesOutAtTheEnd() {
        var framer = ACPLineFramer()
        #expect(framer.append(Data(#"{"a":1}"#.utf8)).isEmpty)
        #expect(framer.finish().map { String(decoding: $0, as: UTF8.self) } == #"{"a":1}"#)
        #expect(framer.finish() == nil)
    }

    @Test func anOverlongLineIsDroppedUpToItsNewline() {
        var framer = ACPLineFramer(maximumLineLength: 8)
        #expect(framer.append(Data("0123456789".utf8)).isEmpty)
        #expect(framer.append(Data("abc".utf8)).isEmpty, "still inside the long line")
        let lines = framer.append(Data("def\n{\"ok\":1}\n".utf8))
        #expect(lines.map { String(decoding: $0, as: UTF8.self) } == [#"{"ok":1}"#], "the next line is read normally")
        #expect(framer.droppedLines == 1)
        _ = framer.append(Data("123456789\n".utf8))
        #expect(framer.droppedLines == 2, "a long line inside one chunk is dropped too")
    }

    @Test func aFramedMessageHasNoNewlineButItsEnd() throws {
        let framed = ACPLineFramer.frame(["text": "line one\nline two", "n": 1])
        #expect(framed.last == 0x0A)
        #expect(framed.dropLast().contains(0x0A) == false, "newlines inside strings are escaped")
        let parsed = try JSONValue.parse(framed.dropLast())
        #expect(parsed["text"]?.stringValue == "line one\nline two")
    }
}

// MARK: - Protocol

@Suite("ACP messages and updates")
struct ACPProtocolTests {
    @Test func initializeAdvertisesNoFileSystemAndNoTerminal() {
        let params = ACPProtocol.initializeParams(clientName: "Reachly", clientVersion: "1.2")
        #expect(params["protocolVersion"]?.intValue == 1)
        #expect(params["clientCapabilities"]?["fs"]?["readTextFile"]?.boolValue == false)
        #expect(params["clientCapabilities"]?["fs"]?["writeTextFile"]?.boolValue == false)
        #expect(params["clientCapabilities"]?["terminal"]?.boolValue == false)
        #expect(params["clientInfo"]?["title"]?.stringValue == "Reachly")
        #expect(params["clientInfo"]?["version"]?.stringValue == "1.2")
    }

    @Test func agentInfoIsRead() throws {
        let result: JSONValue = [
            "protocolVersion": 1,
            "agentCapabilities": ["loadSession": true, "promptCapabilities": ["image": true, "embeddedContext": false]],
            "agentInfo": ["name": "qodercli", "title": "Qoder CLI", "version": "0.9.1"],
            "authMethods": [["id": "qoder-login", "name": "Log in"]],
        ]
        let info = try ACPProtocol.agentInfo(from: result)
        #expect(info.loadSession)
        #expect(info.acceptsImages)
        #expect(!info.acceptsEmbeddedContext)
        #expect(info.authMethods == ["qoder-login"])
        #expect(info.label == "Qoder CLI 0.9.1")
        #expect(throws: ACPError.self) { try ACPProtocol.agentInfo(from: "nope") }
        let bare = try ACPProtocol.agentInfo(from: [:])
        #expect(!bare.loadSession, "capabilities left out are off")
        #expect(bare.label == nil)
    }

    @Test func sessionNewCarriesTheCwdAndStdioServersWithEnvAsAList() {
        let server = ACPProtocol.StdioMCPServer(name: "reachly", command: "/Applications/Reachly.app/Contents/MacOS/reachly-mcp", environment: [("REACHLY_MCP_CLIENT", "qoder")])
        let params = ACPProtocol.newSessionParams(cwd: URL(fileURLWithPath: "/Users/me/Library/Application Support/Reachly/Agent/ACP/Workspace"), mcpServers: [server])
        #expect(params["cwd"]?.stringValue == "/Users/me/Library/Application Support/Reachly/Agent/ACP/Workspace")
        let sent = params["mcpServers"]?.arrayValue?.first
        #expect(sent?["name"]?.stringValue == "reachly")
        #expect(sent?["command"]?.stringValue == "/Applications/Reachly.app/Contents/MacOS/reachly-mcp")
        #expect(sent?["args"]?.arrayValue?.isEmpty == true)
        #expect(sent?["env"]?.arrayValue?.first?["name"]?.stringValue == "REACHLY_MCP_CLIENT")
        #expect(sent?["env"]?.arrayValue?.first?["value"]?.stringValue == "qoder")
        let load = ACPProtocol.loadSessionParams(sessionID: "s1", cwd: URL(fileURLWithPath: "/tmp/w"), mcpServers: [server])
        #expect(load["sessionId"]?.stringValue == "s1")
        #expect(load["mcpServers"]?.arrayValue?.count == 1)
    }

    @Test func thePromptStartsWithTheContextThenFilesThenText() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "reachly-acp-prompt-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let logURL = directory.appending(path: "app.log")
        try Data("line 1\nline 2\n".utf8).write(to: logURL)
        let imageURL = directory.appending(path: "shot.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: imageURL)
        let log = AgentAttachment(fileName: "app.log", mediaType: "text/plain", byteCount: 14, path: logURL.path)
        let image = AgentAttachment(fileName: "shot.png", mediaType: "image/png", byteCount: 4, path: imageURL.path)
        let message = AgentMessage.user("why is it failing?", attachments: [log, image])

        let embedded = ACPProtocol.promptContent(for: message, context: "ctx", agent: ACPProtocol.AgentInfo(acceptsImages: false, acceptsEmbeddedContext: true))
        #expect(embedded.map { $0["type"]?.stringValue } == ["text", "resource", "text", "text"])
        #expect(embedded[0]["text"]?.stringValue == "ctx")
        #expect(embedded[1]["resource"]?["text"]?.stringValue == "line 1\nline 2\n")
        #expect(embedded[2]["text"]?.stringValue?.contains("doesn't accept images") == true)
        #expect(embedded.last?["text"]?.stringValue == "why is it failing?")

        let plain = ACPProtocol.promptContent(for: message, context: nil, agent: ACPProtocol.AgentInfo(acceptsImages: true, acceptsEmbeddedContext: false))
        #expect(plain.map { $0["type"]?.stringValue } == ["text", "image", "text"], "no context once the session has it")
        #expect(plain[0]["text"]?.stringValue?.contains("<attachment name=\"app.log\"") == true)
        #expect(plain[1]["mimeType"]?.stringValue == "image/png")
        #expect(plain[1]["data"]?.stringValue == Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString())
    }

    @Test func eachUpdateKindIsRead() {
        func update(_ value: JSONValue) -> ACPProtocol.Update? {
            ACPProtocol.update(from: ["sessionId": "s", "update": value])
        }
        #expect(update(["sessionUpdate": "agent_message_chunk", "messageId": "m1", "content": ["type": "text", "text": "Hi"]]) == .text("Hi", messageID: "m1"))
        #expect(update(["sessionUpdate": "agent_thought_chunk", "content": ["type": "text", "text": "Hmm"]]) == .thought("Hmm", messageID: nil))
        #expect(update(["sessionUpdate": "agent_message_chunk", "content": ["type": "image", "mimeType": "image/png", "data": ""]]) == .text("[image]", messageID: nil))
        #expect(update(["sessionUpdate": "agent_message_chunk", "content": ["type": "resource_link", "uri": "file:///a", "name": "a.txt"]]) == .text("[a.txt]", messageID: nil))
        #expect(update(["sessionUpdate": "user_message_chunk", "content": ["type": "text", "text": "echo"]]) == .userEcho)
        #expect(update(["sessionUpdate": "plan", "entries": [["content": "Check", "priority": "high", "status": "in_progress"], ["content": "Fix"]]])
            == .plan([AgentPlanEntry(content: "Check", priority: "high", status: .inProgress), AgentPlanEntry(content: "Fix", priority: "medium", status: .pending)]))
        #expect(update(["sessionUpdate": "current_mode_update", "currentModeId": "architect"]) == .mode("architect"))
        #expect(update(["sessionUpdate": "available_commands_update", "availableCommands": []]) == .ignored("available_commands_update"))
        #expect(update(["sessionUpdate": "usage_update", "used": 10]) == .ignored("usage_update"))
        #expect(update(["sessionUpdate": "something_new"]) == .ignored("something_new"), "a later kind is ignored, not an error")
        #expect(update(["sessionUpdate": "tool_call_update"]) == .ignored("tool_call_update"), "a call without an id")
        #expect(ACPProtocol.update(from: ["sessionId": "s"]) == nil)
    }

    @Test func aToolCallUpdateChangesOnlyWhatItCarries() {
        let created = ACPProtocol.toolCallPatch([
            "toolCallId": "c1", "title": "reachly: run_command", "kind": "execute",
            "rawInput": ["host": "web-01", "command": "df -h"],
            "content": [["type": "content", "content": ["type": "text", "text": "first"]]],
        ], isCreation: true)
        var call = created!.applied(to: nil)
        #expect(call.status == .pending, "a new call without a status is pending")
        #expect(call.kind == "execute")
        #expect(call.output == "first")
        #expect(call.input?.contains("\"command\" : \"df -h\"") == true)

        call = ACPProtocol.toolCallPatch(["toolCallId": "c1", "status": "in_progress"], isCreation: false)!.applied(to: call)
        #expect(call.status == .inProgress)
        #expect(call.title == "reachly: run_command", "fields left out stay")
        #expect(call.output == "first")

        call = ACPProtocol.toolCallPatch([
            "toolCallId": "c1", "status": "completed",
            "content": [
                ["type": "content", "content": ["type": "text", "text": "second"]],
                ["type": "diff", "path": "/etc/hosts", "oldText": "a", "newText": "b"],
                ["type": "diff", "path": "/tmp/new", "oldText": nil, "newText": "c"],
                ["type": "terminal", "terminalId": "t1"],
            ],
            "locations": [["path": "/etc/hosts", "line": 4], ["path": "/tmp/new"]],
        ], isCreation: false)!.applied(to: call)
        #expect(call.status == .completed)
        #expect(call.output == "second\nEdit /etc/hosts:\nb\nCreate /tmp/new:\nc\n[Terminal t1]", "new content replaces the old")
        #expect(call.locations == ["/etc/hosts:4", "/tmp/new"])

        let unseen = ACPProtocol.toolCallPatch(["toolCallId": "c9", "status": "failed"], isCreation: false)!.applied(to: nil)
        #expect(unseen.title == "Tool call")
        #expect(unseen.status == .failed)
    }

    @Test func aToolCallsOutputIsCapped() {
        let long = String(repeating: "x", count: AgentToolActivity.textLimit + 500)
        let call = ACPProtocol.toolCallPatch(["toolCallId": "c1", "content": [["type": "content", "content": ["type": "text", "text": .string(long)]]]], isCreation: true)!.applied(to: nil)
        #expect(call.output.count <= AgentToolActivity.textLimit + 100)
    }

    @Test func permissionAnswersDefaultToRejecting() {
        let call = AgentToolActivity(id: "c1", title: "Edit notes.txt", kind: "edit")
        let options: [AgentPermissionRequest.Option] = [
            .init(id: "always", name: "Always allow", kind: .allowAlways),
            .init(id: "once", name: "Allow", kind: .allowOnce),
            .init(id: "no-forever", name: "Never", kind: .rejectAlways),
            .init(id: "no", name: "Reject", kind: .rejectOnce),
        ]
        let request = AgentPermissionRequest(agentName: "Qoder", toolCall: call, options: options)
        #expect(request.defaultRejectOption?.id == "no", "reject once before reject always")

        let selected = ACPProtocol.permissionOutcome(.selected("once"), request: request)
        #expect(selected.result["outcome"]?["outcome"]?.stringValue == "selected")
        #expect(selected.result["outcome"]?["optionId"]?.stringValue == "once")

        let dismissed = ACPProtocol.permissionOutcome(.dismissed, request: request)
        #expect(dismissed.result["outcome"]?["optionId"]?.stringValue == "no")
        #expect(dismissed.chosen?.kind == .rejectOnce)

        let unknown = ACPProtocol.permissionOutcome(.selected("made-up"), request: request)
        #expect(unknown.result["outcome"]?["optionId"]?.stringValue == "no", "an id the agent did not offer rejects")

        let cancelled = ACPProtocol.permissionOutcome(.cancelled, request: request)
        #expect(cancelled.result["outcome"]?["outcome"]?.stringValue == "cancelled")
        #expect(cancelled.result["outcome"]?["optionId"] == nil)

        let onlyAllow = AgentPermissionRequest(agentName: "Qoder", toolCall: call, options: [.init(id: "once", name: "Allow", kind: .allowOnce), .init(id: "x", name: "Odd", kind: nil)])
        #expect(onlyAllow.defaultRejectOption == nil)
        #expect(ACPProtocol.permissionOutcome(.dismissed, request: onlyAllow).result["outcome"]?["outcome"]?.stringValue == "cancelled", "with no way to reject, nothing is allowed")
    }

    @Test func permissionRequestsAreRead() {
        let parsed = ACPProtocol.permissionRequest(from: [
            "sessionId": "s1",
            "toolCall": ["toolCallId": "c1", "title": "Run ls", "kind": "execute"],
            "options": [["optionId": "a", "name": "Allow", "kind": "allow_once"], ["optionId": "r", "kind": "reject_once"], ["name": "no id"]],
        ])
        #expect(parsed?.sessionID == "s1")
        #expect(parsed?.toolCall.id == "c1")
        #expect(parsed?.options.map(\.id) == ["a", "r"])
        #expect(parsed?.options.last?.name == "r", "an option without a name shows its id")
        #expect(ACPProtocol.permissionRequest(from: ["toolCall": ["title": "no id"]]) == nil)
    }

    @Test func stopReasonsAreRead() throws {
        #expect(try ACPProtocol.stopReason(from: ["stopReason": "end_turn"]) == .endTurn)
        #expect(try ACPProtocol.stopReason(from: ["stopReason": "cancelled"]) == .cancelled)
        #expect(try ACPProtocol.stopReason(from: ["stopReason": "max_tokens"]) == .maxTokens)
        #expect(try ACPProtocol.stopReason(from: ["stopReason": "a_new_reason"]) == .endTurn)
        #expect(throws: ACPError.self) { try ACPProtocol.stopReason(from: [:]) }
    }

    @Test func theErrorSummaryIsShortAndMasksTokens() {
        let summary = ACPAgent.errorSummary("starting\n\nloading config\npanic: index out of range\nQODER_PERSONAL_ACCESS_TOKEN=abcdefghijklmnopqrstuvwxyz0123456789ABCDEF\n")
        #expect(summary == "loading config · panic: index out of range · QODER_PERSONAL_ACCESS_TOKEN=…")
        #expect(ACPAgent.errorSummary("  \n") == nil)
        #expect((ACPAgent.errorSummary(String(repeating: "word ", count: 400)) ?? "").count <= 400)
    }
}

// MARK: - JSON-RPC connection

/// Stands in for the agent's pipes: the test writes what the agent says and reads what the client sent.
final class MemoryTransport: ACPTransport {
    let events: AsyncStream<ACPTransportEvent>
    private let continuation: AsyncStream<ACPTransportEvent>.Continuation
    private let sentLines = Mutex<[Data]>([])

    init() {
        (events, continuation) = AsyncStream.makeStream()
    }

    var sent: [JSONValue] { sentLines.withLock { $0 }.compactMap { try? JSONValue.parse($0.dropLast()) } }

    func send(_ framed: Data) {
        sentLines.withLock { $0.append(framed) }
    }

    func close() {
        continuation.yield(.closed(ACPExit(status: 0, wasStopped: true)))
        continuation.finish()
    }

    func deliver(_ line: String) {
        continuation.yield(.message(Data(line.utf8)))
    }

    func exit(status: Int32, standardError: String) {
        continuation.yield(.closed(ACPExit(status: status, standardError: standardError)))
        continuation.finish()
    }
}

@MainActor
func waitFor(_ timeout: Duration = .seconds(10), _ condition: () -> Bool) async {
    let deadline = ContinuousClock.now + timeout
    while !condition(), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(10))
    }
}

@Suite("ACP connection")
@MainActor
struct ACPConnectionTests {
    final class Seen {
        var updates: [String] = []
    }

    @Test func updatesSentBeforeTheAnswerAreHandledFirst() async throws {
        let transport = MemoryTransport()
        let connection = ACPConnection(transport: transport)
        let seen = Seen()
        connection.onNotification = { _, params in seen.updates.append(params?["n"]?.stringValue ?? "?") }
        let reply = Task { try await connection.request("session/prompt", params: ["sessionId": "s"]) }
        await waitFor { transport.sent.count == 1 }
        #expect(transport.sent.first?["method"]?.stringValue == "session/prompt")
        #expect(transport.sent.first?["jsonrpc"]?.stringValue == "2.0")
        transport.deliver(#"{"jsonrpc":"2.0","method":"session/update","params":{"n":"a"}}"#)
        transport.deliver(#"{"jsonrpc":"2.0","method":"session/update","params":{"n":"b"}}"#)
        transport.deliver(#"{"jsonrpc":"2.0","id":1,"result":{"stopReason":"end_turn"}}"#)
        let result = try await reply.value
        #expect(seen.updates == ["a", "b"])
        #expect(result["stopReason"]?.stringValue == "end_turn")
    }

    @Test func anErrorAnswerThrowsWithItsCode() async {
        let transport = MemoryTransport()
        let connection = ACPConnection(transport: transport)
        let reply = Task { try await connection.request("session/new", params: [:]) }
        await waitFor { transport.sent.count == 1 }
        transport.deliver(#"{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"Authentication required"}}"#)
        await #expect(throws: ACPError.rpc(method: "session/new", code: -32000, message: "Authentication required")) { try await reply.value }
    }

    @Test func theAgentsRequestsAreAnswered() async {
        let transport = MemoryTransport()
        let connection = ACPConnection(transport: transport)
        connection.onRequest = { method, params in
            ["echo": .string(method), "id": params?["x"] ?? .null]
        }
        transport.deliver(#"{"jsonrpc":"2.0","id":"p1","method":"session/request_permission","params":{"x":7}}"#)
        await waitFor { !transport.sent.isEmpty }
        #expect(transport.sent.first?["id"]?.stringValue == "p1")
        #expect(transport.sent.first?["result"]?["echo"]?.stringValue == "session/request_permission")
        #expect(transport.sent.first?["result"]?["id"]?.intValue == 7)
    }

    @Test func withoutAHandlerARequestIsMethodNotFound() async {
        let transport = MemoryTransport()
        let connection = ACPConnection(transport: transport)
        transport.deliver(#"{"jsonrpc":"2.0","id":5,"method":"terminal/create","params":{}}"#)
        await waitFor { !transport.sent.isEmpty }
        #expect(transport.sent.first?["error"]?["code"]?.intValue == JSONRPC.ErrorObject.methodNotFound)
        #expect(transport.sent.first?["id"]?.intValue == 5)
        withExtendedLifetime(connection) {}
    }

    @Test func aRequestFailsWhenTheAgentExits() async {
        let transport = MemoryTransport()
        let connection = ACPConnection(transport: transport)
        let reply = Task { try await connection.request("session/prompt", params: [:]) }
        await waitFor { transport.sent.count == 1 }
        transport.exit(status: 3, standardError: "panic")
        await #expect(throws: ACPError.agentExited(ACPExit(status: 3, standardError: "panic"))) { try await reply.value }
        #expect(!connection.isOpen)
        await #expect(throws: ACPError.self) { try await connection.request("session/new", params: [:]) }
    }

    @Test func aRequestTimesOut() async {
        let transport = MemoryTransport()
        let connection = ACPConnection(transport: transport)
        await #expect(throws: ACPError.timedOut("initialize")) {
            try await connection.request("initialize", params: [:], timeout: .milliseconds(100))
        }
    }

    @Test func linesThatAreNotMessagesAreCounted() async {
        let transport = MemoryTransport()
        let connection = ACPConnection(transport: transport)
        transport.deliver("Loading model...")
        transport.deliver(#"{"jsonrpc":"2.0","id":99,"result":{}}"#)
        transport.deliver("[1,2]")
        await waitFor { connection.unreadableLines == 2 }
        #expect(connection.unreadableLines == 2, "an answer to nothing is not counted")
    }
}

// MARK: - A fake agent process

/// The `fake-acp-agent` test tool, next to the test bundle in the build products.
enum FakeACPAgentTool {
    static let path: String = {
        let fileManager = FileManager.default
        var candidates = Bundle.allBundles.filter { $0.bundlePath.hasSuffix(".xctest") }.map {
            $0.bundleURL.deletingLastPathComponent().appending(path: "fake-acp-agent").path
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        candidates += [".build/out/Products/Debug", ".build/debug", ".build/arm64-apple-macosx/debug", ".build/x86_64-apple-macosx/debug"].map {
            root.appending(path: $0).appending(path: "fake-acp-agent").path
        }
        return candidates.first { fileManager.isExecutableFile(atPath: $0) } ?? candidates.last ?? "fake-acp-agent"
    }()
}

/// One fake agent: its scratch folder, the log of what it read, and an `ACPAgent` driving it.
@MainActor
final class FakeACPRun {
    let directory: URL
    let logURL: URL
    let agent: ACPAgent
    var events: [ExternalAgentEvent] = []

    init(_ scenario: String, cancelGrace: Duration = .seconds(5), initializeTimeout: Duration = .seconds(10), store: Bool = false, directory: URL? = nil, environment: [String: String] = [:], argumentSets: [[String]] = [["--acp"], ["acp"]], fallbackNotices: [String: String] = [:]) {
        let directory = directory ?? FileManager.default.temporaryDirectory.appending(path: "reachly-acp-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        logURL = directory.appending(path: "agent-\(UUID().uuidString).log")
        let configuration = ACPAgent.Configuration(
            name: "Qoder",
            executable: FakeACPAgentTool.path,
            argumentSets: argumentSets,
            fallbackNotices: fallbackNotices,
            environment: environment.merging(["FAKE_ACP_SCENARIO": scenario, "FAKE_ACP_LOG": logURL.path]) { _, fixed in fixed },
            workingDirectory: directory.appending(path: "Workspace", directoryHint: .isDirectory),
            mcpServers: { key in
                [ACPProtocol.StdioMCPServer(name: "reachly", command: "/Applications/Reachly.app/Contents/MacOS/reachly-mcp", environment: [("REACHLY_MCP_CLIENT", "qoder"), ("REACHLY_MCP_CONVERSATION", key)])]
            },
            clientVersion: "test",
            initializeTimeout: initializeTimeout,
            sessionTimeout: .seconds(10),
            cancelGrace: cancelGrace,
            sessionStore: store ? ACPSessionStore(url: directory.appending(path: "sessions.json")) : nil,
            signInHint: "Run `qoder login` in Terminal, then Retry.")
        agent = ACPAgent(configuration: configuration)
    }

    /// The last message each conversation sent, so a turn with `earlier` follows it as in a real transcript.
    private var lastSent: [String: UUID] = [:]

    func turn(_ text: String = "is web-01 low on disk?", key: String = "conversation-1", earlier: Bool = false) -> ExternalAgentTurn {
        let message = AgentMessage.user(text)
        defer { lastSent[key] = message.id }
        return ExternalAgentTurn(conversationKey: key, message: message, context: "Reachly context", hasEarlierTurns: earlier, previousUserMessageID: earlier ? lastSent[key] : nil)
    }

    func run(_ turn: ExternalAgentTurn? = nil) async throws -> ExternalAgentStopReason {
        try await agent.run(turn ?? self.turn()) { [weak self] event in self?.events.append(event) }
    }

    /// Every line the fake agent read, as JSON, and the argument lines.
    var received: [JSONValue] {
        lines.filter { !$0.hasPrefix("ARGV") && !$0.hasPrefix("HTTP ") }.compactMap { try? JSONValue.parse(Data($0.utf8)) }
    }

    var launches: [String] {
        lines.filter { $0.hasPrefix("ARGV") }
    }

    /// The answers the fake agent got from the test's MCP server.
    var httpAnswers: [String] {
        lines.filter { $0.hasPrefix("HTTP ") }.map { String($0.dropFirst(5)) }
    }

    private var lines: [String] {
        ((try? String(contentsOf: logURL, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    func received(_ method: String) -> [JSONValue] {
        received.filter { $0["method"]?.stringValue == method }
    }

    var toolCalls: [AgentToolActivity] {
        events.compactMap { if case .toolCall(let call) = $0 { call } else { nil } }
    }

    var texts: [String] {
        events.compactMap { if case .text(let text, _) = $0 { text } else { nil } }
    }

    func finish() {
        agent.shutdown()
        try? FileManager.default.removeItem(at: directory)
    }
}

@Suite("ACP agent against a fake agent process", .serialized)
@MainActor
struct ACPAgentProcessTests {
    @Test func aTurnStreamsTextReasoningToolCallsAndAPlan() async throws {
        let run = FakeACPRun("basic")
        defer { run.finish() }
        let stop = try await run.run()
        #expect(stop == .endTurn)
        #expect(run.events.first == .started(agent: "Fake ACP 0.0.1"))
        #expect(run.events.contains(.thinking("Looking at the disk.", messageID: nil)))
        #expect(run.texts == ["Root is ", "at 91%.", "Done."], "the user echo and the command list are not shown")
        #expect(run.toolCalls.map(\.status) == [.pending, .inProgress, .completed])
        let last = run.toolCalls.last
        #expect(last?.title == "reachly: run_command")
        #expect(last?.kind == "execute")
        #expect(last?.output == "/dev/sda1 80G 73G 91% /")
        #expect(last?.locations == ["/etc/fstab:3"])
        #expect(last?.input?.contains("df -h") == true, "the input stays from the first update")
        #expect(run.events.contains(.plan([AgentPlanEntry(content: "Check the disk", priority: "high", status: .completed), AgentPlanEntry(content: "Write it up", priority: "medium", status: .inProgress)])))
        #expect(run.agent.launchArguments == ["--acp"])
        #expect(run.agent.isConnected)
        #expect(!run.agent.isBusy)
    }

    @Test func reachlyAdvertisesNoFileSystemOrTerminalAndHandsOverItsMCPBridge() async throws {
        let run = FakeACPRun("basic")
        defer { run.finish() }
        _ = try await run.run(run.turn(key: "conv-A"))
        let initialize = try #require(run.received("initialize").first)
        #expect(initialize["params"]?["clientCapabilities"]?["fs"]?["readTextFile"]?.boolValue == false)
        #expect(initialize["params"]?["clientCapabilities"]?["fs"]?["writeTextFile"]?.boolValue == false)
        #expect(initialize["params"]?["clientCapabilities"]?["terminal"]?.boolValue == false)
        let new = try #require(run.received("session/new").first)
        #expect(new["params"]?["cwd"]?.stringValue == run.directory.appending(path: "Workspace").path, "the cwd is Reachly's own folder")
        #expect(new["params"]?["cwd"]?.stringValue != FileManager.default.homeDirectoryForCurrentUser.path)
        let server = new["params"]?["mcpServers"]?.arrayValue?.first
        #expect(server?["name"]?.stringValue == "reachly")
        #expect(server?["command"]?.stringValue?.hasSuffix("/Contents/MacOS/reachly-mcp") == true)
        #expect(server?["env"]?.arrayValue?.map { $0["value"]?.stringValue ?? "" } == ["qoder", "conv-A"])
        let prompt = try #require(run.received("session/prompt").first)
        let blocks = prompt["params"]?["prompt"]?.arrayValue ?? []
        #expect(blocks.map { $0["text"]?.stringValue } == ["Reachly context", "is web-01 low on disk?"], "the context goes first in a new session")
    }

    @Test func aConversationKeepsItsSessionAndTheContextIsSentOnce() async throws {
        let run = FakeACPRun("basic")
        defer { run.finish() }
        _ = try await run.run(run.turn("first", key: "A"))
        _ = try await run.run(run.turn("second", key: "A", earlier: true))
        _ = try await run.run(run.turn("other", key: "B"))
        #expect(run.received("session/new").count == 2, "one session per conversation")
        #expect(run.launches.count == 1, "one agent process for all of them")
        let prompts = run.received("session/prompt")
        #expect(prompts.map { $0["params"]?["sessionId"]?.stringValue } == ["sess-1", "sess-1", "sess-2"])
        #expect(prompts[1]["params"]?["prompt"]?.arrayValue?.map { $0["text"]?.stringValue } == ["second"])
        #expect(!run.events.contains { if case .notice = $0 { true } else { false } })
    }

    @Test func aNewSessionForAnOngoingConversationSaysSo() async throws {
        let run = FakeACPRun("basic")
        defer { run.finish() }
        _ = try await run.run(run.turn("later", key: "A", earlier: true))
        #expect(run.events.contains(.notice("Qoder started a new session, so it doesn't know the earlier messages in this conversation.")))
    }

    @Test func aSavedSessionIsLoadedWhenTheAgentOffersItAndItsReplayIsNotShownAgain() async throws {
        let first = FakeACPRun("loadable", store: true)
        defer { first.finish() }
        _ = try await first.run(first.turn("first", key: "A"))
        first.agent.shutdown()
        first.events = []
        _ = try await first.run(first.turn("second", key: "A", earlier: true))
        #expect(first.launches.count == 2, "the agent started again")
        let load = try #require(first.received("session/load").first)
        #expect(load["params"]?["sessionId"]?.stringValue == "sess-1")
        #expect(load["params"]?["mcpServers"]?.arrayValue?.count == 1, "a loaded session gets the bridge too")
        #expect(!first.texts.contains("replayed answer"), "the transcript already shows the history")
        #expect(!first.events.contains { if case .notice = $0 { true } else { false } })
        let prompt = try #require(first.received("session/prompt").last)
        #expect(prompt["params"]?["sessionId"]?.stringValue == "sess-1")
        #expect(prompt["params"]?["prompt"]?.arrayValue?.map { $0["text"]?.stringValue } == ["second"], "no context for a loaded session")
    }

    @Test func forgettingASessionStartsANewOne() async throws {
        let run = FakeACPRun("loadable", store: true)
        defer { run.finish() }
        _ = try await run.run(run.turn("first", key: "A"))
        run.agent.forgetSession(for: "A")
        run.agent.shutdown()
        _ = try await run.run(run.turn("edited", key: "A", earlier: true))
        #expect(run.received("session/load").isEmpty)
        #expect(run.received("session/new").count == 2)
    }

    @Test func stopSendsCancelAndTheTurnEndsCancelled() async throws {
        let run = FakeACPRun("slow")
        defer { run.finish() }
        let task = Task { try await run.run() }
        await waitFor { run.texts.count >= 3 }
        task.cancel()
        let stop = try await task.value
        #expect(stop == .cancelled)
        #expect(run.received("session/cancel").first?["params"]?["sessionId"]?.stringValue == "sess-1")
        #expect(run.received("session/cancel").first?["id"] == nil, "a notification, not a request")
        #expect(run.toolCalls.last?.status == .cancelled, "the running call is marked cancelled")
        #expect(run.agent.isConnected, "the agent stays up for the next message")
        #expect(!run.agent.isBusy)
    }

    @Test func anAgentThatIgnoresStopIsStoppedAfterTheGrace() async throws {
        let run = FakeACPRun("ignore-cancel", cancelGrace: .milliseconds(500))
        defer { run.finish() }
        let task = Task { try await run.run() }
        await waitFor { run.texts.count >= 2 }
        let started = ContinuousClock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(!run.agent.isConnected)
        #expect(!run.agent.isBusy)
    }

    @Test func aCrashMidTurnFailsWithWhatTheAgentSaid() async throws {
        let run = FakeACPRun("crash")
        defer { run.finish() }
        await #expect {
            _ = try await run.run()
        } throws: { error in
            guard let failure = error as? ExternalAgentFailure else { return false }
            return failure.kind == .error
                && failure.message.contains("Qoder stopped unexpectedly (exit status 3)")
                && failure.message.contains("panic: index out of range")
                && !failure.message.contains("abcdefghijklmnopqrstuvwxyz0123456789")
        }
        #expect(run.texts == ["Starting "])
        #expect(run.toolCalls.last?.status == .failed, "a call the crash cut short is marked failed")
        #expect(!run.agent.isConnected)
        // The next turn starts the agent again.
        await #expect(throws: ExternalAgentFailure.self) { _ = try await run.run() }
        #expect(run.launches.count == 2)
    }

    @Test func anErrorAnswerFailsTheTurn() async throws {
        let run = FakeACPRun("error")
        defer { run.finish() }
        await #expect(throws: ExternalAgentFailure(kind: .error, message: "Qoder reported an error while the reply: model overloaded (-32603).")) {
            _ = try await run.run()
        }
        #expect(run.texts == ["Partial "])
        #expect(run.agent.isConnected, "an error answer does not stop the agent")
    }

    @Test func notSignedInSaysHowToSignIn() async throws {
        let run = FakeACPRun("auth")
        defer { run.finish() }
        await #expect {
            _ = try await run.run()
        } throws: { error in
            guard let failure = error as? ExternalAgentFailure else { return false }
            return failure.kind == .setup && failure.message == "Qoder isn't signed in (Authentication required). Run `qoder login` in Terminal, then Retry."
        }
        #expect(run.received("session/prompt").isEmpty)
    }

    @Test func theSubcommandFormIsTriedWhenTheFlagIsRefused() async throws {
        let run = FakeACPRun("needs-subcommand")
        defer { run.finish() }
        _ = try await run.run()
        #expect(run.launches == ["ARGV --acp", "ARGV acp"])
        #expect(run.agent.launchArguments == ["acp"])
        #expect(run.texts.last == "Done.")
    }

    /// What the chat panel runs Qoder with.
    static let panelArguments = [["--acp", "--permission-mode", "default"], ["--acp"], ["acp", "--permission-mode", "default"], ["acp"]]
    static let panelNotices = ["--permission-mode": "Qoder didn't accept --permission-mode default, so it runs in the permission mode its own settings choose."]

    @Test func qoderStartsInItsDefaultPermissionMode() async throws {
        let run = FakeACPRun("basic", argumentSets: Self.panelArguments, fallbackNotices: Self.panelNotices)
        defer { run.finish() }
        _ = try await run.run()
        #expect(run.launches == ["ARGV --acp --permission-mode default"])
        #expect(!run.events.contains { if case .notice = $0 { true } else { false } })
    }

    @Test func aQoderThatRefusesThePermissionModeRunsWithoutItAndSaysSo() async throws {
        let run = FakeACPRun("no-permission-mode", argumentSets: Self.panelArguments, fallbackNotices: Self.panelNotices)
        defer { run.finish() }
        _ = try await run.run()
        #expect(run.launches == ["ARGV --acp --permission-mode default", "ARGV --acp"])
        #expect(run.events.contains(.notice(Self.panelNotices["--permission-mode"]!)))
        run.events = []
        _ = try await run.run(run.turn("again", earlier: true))
        #expect(!run.events.contains { if case .notice = $0 { true } else { false } }, "said once per start")

        let subcommand = FakeACPRun("needs-subcommand", argumentSets: Self.panelArguments, fallbackNotices: Self.panelNotices)
        defer { subcommand.finish() }
        _ = try await subcommand.run()
        #expect(subcommand.launches == ["ARGV --acp --permission-mode default", "ARGV acp --permission-mode default"], "the mode is kept when only --acp was refused")
        #expect(!subcommand.events.contains { if case .notice = $0 { true } else { false } })
    }

    @Test func theAgentGetsOnlyTheEnvironmentItNeeds() async throws {
        let inherited = [
            "HOME": "/Users/me", "USER": "me", "LOGNAME": "me", "SHELL": "/bin/zsh", "TMPDIR": "/var/folders/xy/T/",
            "LANG": "en_GB.UTF-8", "LC_ALL": "en_GB.UTF-8", "PATH": "/usr/bin:/bin",
            "QODER_PERSONAL_ACCESS_TOKEN": "qoder-sign-in",
            "ANTHROPIC_API_KEY": "sk-ant-secret", "OPENAI_API_KEY": "sk-secret", "SSH_AUTH_SOCK": "/private/tmp/ssh-agent.sock",
            "FOO_TOKEN": "t", "AWS_SECRET_ACCESS_KEY": "k", "GITHUB_TOKEN": "g", "DYLD_INSERT_LIBRARIES": "/tmp/x.dylib",
        ]
        let environment = ACPLaunch.environment(inherited: inherited, executables: ["/Users/me/.local/bin/qoder", "/Users/me/.qoder/versions/1/qodercli"], home: "/Users/me")
        #expect(environment["PATH"]?.hasPrefix("/Users/me/.local/bin:/Users/me/.qoder/versions/1:") == true, "the agent's own folders first")
        #expect(environment["NO_COLOR"] == "1")
        #expect(environment["QODER_PERSONAL_ACCESS_TOKEN"] == "qoder-sign-in", "Qoder's own sign-in reaches it")

        // What the agent process actually sees.
        let run = FakeACPRun("env", environment: environment)
        defer { run.finish() }
        _ = try await run.run()
        let names = Set((run.texts.first ?? "").split(separator: ",").map(String.init))
        for name in ["ANTHROPIC_API_KEY", "OPENAI_API_KEY", "SSH_AUTH_SOCK", "FOO_TOKEN", "AWS_SECRET_ACCESS_KEY", "GITHUB_TOKEN", "DYLD_INSERT_LIBRARIES"] {
            #expect(!names.contains(name), "\(name) must not reach the agent")
        }
        #expect(names.isSuperset(of: ["HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "LC_ALL", "PATH", "NO_COLOR", "QODER_PERSONAL_ACCESS_TOKEN"]))
        let unexpected = names.filter { !$0.hasPrefix("FAKE_ACP_") && !$0.hasPrefix("__CF") && !ACPLaunch.environmentNames.contains($0) && !ACPLaunch.environmentPrefixes.contains(where: $0.hasPrefix) && !["PATH", "NO_COLOR"].contains($0) }
        #expect(unexpected.isEmpty, "nothing else: \(unexpected)")
    }

    @Test func anAgentThatNeverInitializesIsASetupFailureAndIsNotTriedAgain() async throws {
        let run = FakeACPRun("silent-init", initializeTimeout: .seconds(1))
        defer { run.finish() }
        await #expect {
            _ = try await run.run()
        } throws: { error in
            guard let failure = error as? ExternalAgentFailure else { return false }
            return failure.kind == .setup && failure.message.contains("didn't start in ACP mode") && failure.message.contains("within 1 seconds")
        }
        #expect(run.launches == ["ARGV --acp"], "a timeout is not a refused argument")
    }

    @Test func aCrashOrASignInErrorAtStartIsNotTriedAgain() async throws {
        let crash = FakeACPRun("init-crash")
        defer { crash.finish() }
        await #expect {
            _ = try await crash.run()
        } throws: { error in
            guard let failure = error as? ExternalAgentFailure else { return false }
            return failure.kind == .setup && failure.message.contains("exit status 1") && failure.message.contains("the config file is broken")
        }
        #expect(crash.launches == ["ARGV --acp"])

        let auth = FakeACPRun("init-auth")
        defer { auth.finish() }
        await #expect {
            _ = try await auth.run()
        } throws: { error in
            (error as? ExternalAgentFailure)?.message == "Qoder isn't signed in (Authentication required). Run `qoder login` in Terminal, then Retry."
        }
        #expect(auth.launches == ["ARGV --acp"])
    }

    @Test func aRefusedArgumentIsReadFromWhatTheAgentSaid() {
        let sets = ["--acp", "--permission-mode", "default"]
        #expect(ACPLaunch.refusedArgument(in: "error: unknown option '--acp'\n", among: ["--acp"]) == "--acp")
        #expect(ACPLaunch.refusedArgument(in: "error: unexpected argument '--acp' found\n\nUsage: qoder [OPTIONS]", among: ["--acp"]) == "--acp")
        #expect(ACPLaunch.refusedArgument(in: "Error: unknown flag: --permission-mode", among: sets) == "--permission-mode")
        #expect(ACPLaunch.refusedArgument(in: "error: unknown command 'acp'", among: ["acp"]) == "acp")
        #expect(ACPLaunch.refusedArgument(in: "Unknown arguments: acp, foo", among: ["acp"]) == "acp")
        #expect(ACPLaunch.refusedArgument(in: "panic: index out of range", among: ["--acp"]) == nil, "a crash is not a refusal")
        #expect(ACPLaunch.refusedArgument(in: "Authentication required", among: ["--acp"]) == nil)
        #expect(ACPLaunch.refusedArgument(in: "error: unknown option '--verbose'", among: ["--acp"]) == nil, "it must name one of ours")
        #expect(ACPLaunch.refusedArgument(in: "warning: --acp is unrecognised here", among: ["acp", "--acp"]) == "--acp", "the longest match wins")
    }

    @Test func anAppBundleIsNeverRunEvenThroughALink() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "reachly-launch-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let launcher = directory.appending(path: "Qoder.app/Contents/Resources/app/bin/qoder")
        try FileManager.default.createDirectory(at: launcher.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: launcher.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        let cli = directory.appending(path: "cli/qoder")
        try FileManager.default.createDirectory(at: cli.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: cli.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        let link = directory.appending(path: "bin/qoder")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: cli.path)

        let resolvedCLI = cli.resolvingSymlinksInPath().standardizedFileURL.path
        #expect(ACPLaunch.resolveExecutable(link.path) == .success(resolvedCLI), "the file that runs is the link's target")
        // The link is pointed into the editor's bundle later: the next start refuses it.
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: launcher.path)
        guard case .failure(.insideAppBundle(let resolved)) = ACPLaunch.resolveExecutable(link.path) else {
            Issue.record("a link into Qoder.app must be refused")
            return
        }
        #expect(resolved.hasSuffix("Qoder.app/Contents/Resources/app/bin/qoder"))
        #expect(ACPLaunch.resolveExecutable(launcher.path) == .failure(.insideAppBundle(resolved: launcher.resolvingSymlinksInPath().standardizedFileURL.path)), "typed in directly too")
        #expect(ACPLaunch.resolveExecutable(directory.appending(path: "nothing").path) == .failure(.missing))
        #expect(ACPLaunch.resolveExecutable(directory.path) == .failure(.notExecutable))
    }

    @Test func appBundlesAreFoundByWholePathComponentsInAnyCase() {
        #expect(AIProviderLocations.isInsideAppBundle("/Applications/Qoder.app/Contents/Resources/app/bin/qoder"))
        #expect(AIProviderLocations.isInsideAppBundle("/Applications/QODER.APP/Contents/MacOS/qoder"))
        #expect(AIProviderLocations.isInsideAppBundle("/Users/me/Applications/Qoder.app/bin/qoder"), "with or without Contents")
        #expect(!AIProviderLocations.isInsideAppBundle("/opt/my.apps/bin/qoder"))
        #expect(!AIProviderLocations.isInsideAppBundle("/Users/me/.local/bin/qoder"))
        #expect(!AIProviderLocations.isInsideAppBundle("/usr/local/bin/qoder.app"), "only folders on the way count")
    }

    @Test func stopWhileTheAgentStartsEndsAtOnce() async throws {
        let run = FakeACPRun("silent-init", initializeTimeout: .seconds(20))
        defer { run.finish() }
        let task = Task { try await run.run() }
        await waitFor { run.launches.count == 1 }
        let started = ContinuousClock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(ContinuousClock.now - started < .seconds(5), "Stop does not wait for the start-up timeout")
        #expect(run.launches.count == 1, "the other form is not tried after Stop")
        #expect(!run.agent.isConnected)
    }

    @Test func aMissingExecutableIsASetupFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "reachly-acp-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let agent = ACPAgent(configuration: .init(
            name: "Qoder", executable: directory.appending(path: "no-such-qoder").path, argumentSets: [["--acp"]], environment: [:],
            workingDirectory: directory, mcpServers: { _ in [] }, clientVersion: "test"))
        await #expect {
            _ = try await agent.run(ExternalAgentTurn(conversationKey: "A", message: .user("hi"), context: "", hasEarlierTurns: false)) { _ in }
        } throws: { error in
            (error as? ExternalAgentFailure)?.kind == .setup
        }
    }

    @Test func theAgentCannotUseTheFileSystemMethods() async throws {
        let run = FakeACPRun("fsprobe")
        defer { run.finish() }
        _ = try await run.run()
        #expect(run.texts == ["fs: -32601"], "fs/read_text_file is method not found")
    }

    @Test func aPermissionRequestAsksAndSendsTheChoice() async throws {
        let run = FakeACPRun("permission")
        defer { run.finish() }
        var asked: [AgentPermissionRequest] = []
        run.agent.permissionHandler = { request in
            asked.append(request)
            return .selected("allow")
        }
        _ = try await run.run()
        #expect(asked.count == 1)
        #expect(asked.first?.agentName == "Qoder")
        #expect(asked.first?.toolCall.title == "Edit notes.txt")
        #expect(asked.first?.toolCall.input?.contains("/tmp/notes.txt") == true)
        #expect(asked.first?.options.map(\.kind) == [.allowOnce, .rejectOnce])
        #expect(run.texts == ["permission: selected allow"])
        #expect(run.toolCalls.last?.status == .completed)
        #expect(run.toolCalls.contains { $0.permission == "Allowed: Allow once" })
    }

    @Test func aPermissionRequestWithNoOneToAskIsRejected() async throws {
        let run = FakeACPRun("permission")
        defer { run.finish() }
        _ = try await run.run()
        #expect(run.texts == ["permission: selected reject"])
        #expect(run.toolCalls.last?.status == .failed)
    }

    @Test func aClosedPermissionSheetRejects() async throws {
        let run = FakeACPRun("permission")
        defer { run.finish() }
        run.agent.permissionHandler = { _ in .dismissed }
        _ = try await run.run()
        #expect(run.texts == ["permission: selected reject"])
        #expect(run.toolCalls.contains { $0.permission == "Closed without a choice, so rejected (Reject)." })
    }

    @Test func stopWhileAPermissionRequestWaitsAnswersItCancelled() async throws {
        let run = FakeACPRun("permission")
        defer { run.finish() }
        var waiting = false
        run.agent.permissionHandler = { _ in
            waiting = true
            // Waits for the user until the turn is stopped.
            try? await Task.sleep(for: .seconds(30))
            return .selected("allow")
        }
        let task = Task { try await run.run() }
        await waitFor { waiting }
        task.cancel()
        let stop = try await task.value
        #expect(stop == .cancelled)
        let answer = run.received.first { $0["id"]?.stringValue == "perm-1" }
        #expect(answer?["result"]?["outcome"]?["outcome"]?.stringValue == "cancelled", "a stopped turn never allows")
    }

    @Test func everyEndOfATurnIsReportedAndStopReportsItAtOnce() async throws {
        let answered = FakeACPRun("basic")
        defer { answered.finish() }
        var ended: [String] = []
        answered.agent.turnEndHandler = { ended.append($0) }
        _ = try await answered.run(answered.turn(key: "A"))
        #expect(ended == ["A"])

        let crashed = FakeACPRun("crash")
        defer { crashed.finish() }
        var crashEnds: [String] = []
        crashed.agent.turnEndHandler = { crashEnds.append($0) }
        _ = try? await crashed.run(crashed.turn(key: "B"))
        #expect(crashEnds == ["B"])

        // An agent that ignores Stop still has its turn reported as over when Stop is pressed.
        let stopped = FakeACPRun("ignore-cancel", cancelGrace: .seconds(10))
        defer { stopped.finish() }
        var stopEnds: [String] = []
        stopped.agent.turnEndHandler = { stopEnds.append($0) }
        let task = Task { try await stopped.run(stopped.turn(key: "C")) }
        await waitFor { stopped.texts.count >= 2 }
        #expect(stopped.agent.isAnswering("C"))
        #expect(!stopped.agent.isAnswering("D"))
        task.cancel()
        await waitFor { !stopEnds.isEmpty }
        #expect(stopEnds == ["C"])
        #expect(stopped.agent.isBusy, "the agent has not answered yet")
        #expect(!stopped.agent.isAnswering("C"), "but nothing it asks for now can be answered")
        stopped.agent.shutdown()
        _ = try? await task.value
    }

    @Test func aPermissionSheetGoesWhenTheAgentAnswersWithoutWaitingOrDies() async throws {
        for scenario in ["permission-answered", "permission-crash"] {
            let run = FakeACPRun(scenario)
            defer { run.finish() }
            var asked = false
            var sawCancel = false
            run.agent.permissionHandler = { _ in
                asked = true
                // The sheet stays up until the user answers it, or its task is cancelled.
                do { try await Task.sleep(for: .seconds(30)) } catch { sawCancel = true }
                return .cancelled
            }
            let started = ContinuousClock.now
            _ = try? await run.run()
            await waitFor { sawCancel }
            #expect(asked, "\(scenario)")
            #expect(sawCancel, "\(scenario): the sheet is taken down when the turn ends")
            #expect(ContinuousClock.now - started < .seconds(10))
        }
    }

    @Test func aSecondTurnWhileOneRunsIsRefused() async throws {
        let run = FakeACPRun("slow")
        defer { run.finish() }
        let task = Task { try await run.run() }
        await waitFor { run.agent.isBusy }
        await #expect(throws: ExternalAgentFailure.self) { _ = try await run.agent.run(run.turn(key: "B")) { _ in } }
        task.cancel()
        _ = try? await task.value
    }
}
