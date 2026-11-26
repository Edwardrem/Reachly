import Foundation
import Testing
import ReachlyCore
@testable import ReachlyAgent

@Suite("MCP server")
struct MCPServerTests {
    private struct Client {
        let port: Int
        var token: String
        var extraHeaders: [String: String] = [:]

        func post(_ body: String) async throws -> (Int, JSONValue?, [String: String]) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
            request.httpMethod = "POST"
            request.httpBody = Data(body.utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            for (name, value) in extraHeaders { request.setValue(value, forHTTPHeaderField: name) }
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as! HTTPURLResponse
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields { headers[String(describing: key).lowercased()] = String(describing: value) }
            return (http.statusCode, data.isEmpty ? nil : try? JSONValue.parse(data), headers)
        }

        func call(_ id: Int, _ method: String, _ params: JSONValue = [:]) async throws -> JSONValue? {
            let body = JSONValue.object(["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params]).text
            let (status, json, _) = try await post(body)
            #expect(status == 200)
            return json
        }
    }

    @MainActor
    private func startServer() async throws -> (MCPServer, FakeToolHost, Client) {
        let host = FakeToolHost(hosts: [FakeToolHost.web, FakeToolHost.db])
        let server = MCPServer(toolHost: host, token: "secret-token", serverVersion: "test")
        let port = try await server.start(port: 0)
        return (server, host, Client(port: port, token: "secret-token"))
    }

    @Test func handshakeListAndCall() async throws {
        let (server, host, client) = try await startServer()
        defer { Task { await server.stop() } }

        let (status, initialize, headers) = try await client.post(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#)
        #expect(status == 200)
        #expect(initialize?["result"]?["protocolVersion"]?.stringValue == "2025-03-26")
        #expect(initialize?["result"]?["serverInfo"]?["name"]?.stringValue == "Reachly")
        #expect(initialize?["result"]?["capabilities"]?["tools"] != nil)
        #expect(headers["mcp-session-id"] != nil)

        let (notificationStatus, body, _) = try await client.post(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        #expect(notificationStatus == 202)
        #expect(body == nil)

        let tools = try await client.call(2, "tools/list")
        let names = tools?["result"]?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
        #expect(names == AgentToolName.allCases.map(\.rawValue))
        #expect(tools?["result"]?["tools"]?.arrayValue?.first?["inputSchema"]?["type"]?.stringValue == "object")

        let list = try await client.call(3, "tools/call", ["name": "list_hosts", "arguments": [:]])
        let text = list?["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
        #expect(text.contains("web-01"))
        #expect(list?["result"]?["isError"]?.boolValue == false)

        let run = try await client.call(4, "tools/call", ["name": "run_command", "arguments": ["host": "db-01", "command": "uptime", "reason": "load"]])
        #expect(run?["result"]?["isError"]?.boolValue == false)
        await MainActor.run {
            #expect(host.executed.map(\.command) == ["uptime"])
            #expect(host.auditRecords.first?.source == .mcp)
            #expect(host.auditRecords.first?.decision == .autoAllowed)
        }

        let blocked = try await client.call(5, "tools/call", ["name": "run_command", "arguments": ["host": "db-01", "command": "reboot", "reason": "r"]])
        #expect(blocked?["result"]?["isError"]?.boolValue == true)

        let unknown = try await client.call(6, "no/such")
        #expect(unknown?["error"]?["code"]?.intValue == -32601)
        let ping = try await client.call(7, "ping")
        #expect(ping?["result"]?.objectValue?.isEmpty == true)
    }

    @Test func qoderInThePanelIsNamedInTheSheetAndAuditedUnderItsConversation() async throws {
        let (server, host, plain) = try await startServer()
        defer { Task { await server.stop() } }
        let conversation = UUID()
        var qoder = plain
        qoder.extraHeaders = [MCPServer.clientHeader: "qoder", MCPServer.conversationHeader: conversation.uuidString]

        // web-01 asks for every command, so the request reaches the approval sheet.
        _ = try await qoder.call(1, "tools/call", ["name": "run_command", "arguments": ["host": "web-01", "command": "df -h", "reason": "disk"]])
        _ = try await plain.call(2, "tools/call", ["name": "run_command", "arguments": ["host": "web-01", "command": "uptime", "reason": "load"]])
        var spoofed = plain
        spoofed.extraHeaders = [MCPServer.clientHeader: "Totally Legit", MCPServer.conversationHeader: conversation.uuidString]
        _ = try await spoofed.call(3, "tools/call", ["name": "run_command", "arguments": ["host": "web-01", "command": "whoami", "reason": "who"]])
        await MainActor.run {
            #expect(host.approvalRequests.map(\.requester) == ["Qoder", nil, nil], "only a name Reachly knows is shown")
            #expect(host.approvalRequests.allSatisfy { $0.source == .mcp }, "the same guardrails as any MCP client")
            #expect(host.auditRecords.map(\.conversationID) == [conversation, nil, nil])
            #expect(host.executed.map(\.command) == ["df -h", "uptime", "whoami"])
        }
    }

    /// web-01 asks before every command; the sheets wait.
    @MainActor
    private func startWaitingServer() async throws -> (MCPServer, FakeToolHost, WaitingApprovals, Client) {
        let host = FakeToolHost(hosts: [FakeToolHost.web])
        let approvals = WaitingApprovals()
        host.approval = { request in await approvals.ask(request) }
        let server = MCPServer(toolHost: host, token: "secret-token", serverVersion: "test")
        let port = try await server.start(port: 0)
        return (server, host, approvals, Client(port: port, token: "secret-token"))
    }

    private static let waitingCall = #"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"run_command","arguments":{"host":"web-01","command":"rm -rf /srv/old","reason":"clean up"}}}"#

    @Test @MainActor func aDroppedConnectionDeniesTheCallItWasWaitingOn() async throws {
        let (server, host, approvals, client) = try await startWaitingServer()
        defer { Task { await server.stop() } }
        // A client that sends the call and goes away, as a bridge does when its agent is killed.
        let socket = try RawHTTPClient(port: client.port)
        socket.send("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer secret-token\r\nContent-Type: application/json\r\nContent-Length: \(Self.waitingCall.utf8.count)\r\n\r\n\(Self.waitingCall)")
        await waitFor { !approvals.waiting.isEmpty }
        #expect(approvals.waiting.count == 1)
        socket.close()
        // The denial is audited after the sheet goes, on the call's own task: wait for both, or a loaded
        // machine sees the sheet gone before the record is written.
        await waitFor(.seconds(5)) { approvals.waiting.isEmpty && !host.auditRecords.isEmpty }
        #expect(approvals.waiting.isEmpty, "the sheet goes with the connection")
        #expect(approvals.answers == [.denied])
        #expect(host.executed.isEmpty)
        #expect(host.auditRecords.map(\.decision) == [.cancelled])
    }

    @Test @MainActor func notificationsCancelledStopsTheCallItNames() async throws {
        let (server, host, approvals, client) = try await startWaitingServer()
        defer { Task { await server.stop() } }
        var sessionA = client
        sessionA.extraHeaders = ["Mcp-Session-Id": "session-a"]
        var sessionB = client
        sessionB.extraHeaders = ["Mcp-Session-Id": "session-b"]
        let call = Task { try await sessionA.post(Self.waitingCall) }
        await waitFor { !approvals.waiting.isEmpty }
        #expect(server.runningCallCount == 1)

        // Another client's cancel for the same id does nothing.
        let (otherStatus, _, _) = try await sessionB.post(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":9}}"#)
        #expect(otherStatus == 202)
        try await Task.sleep(for: .milliseconds(200))
        #expect(approvals.waiting.count == 1)

        let (status, _, _) = try await sessionA.post(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":9,"reason":"user stopped"}}"#)
        #expect(status == 202)
        let (callStatus, answer, _) = try await call.value
        #expect(callStatus == 200)
        #expect(answer?["result"]?["isError"]?.boolValue == true)
        #expect(approvals.answers == [.denied])
        #expect(host.executed.isEmpty)
        #expect(host.auditRecords.map(\.decision) == [.cancelled])
        #expect(server.runningCallCount == 0)
    }

    @Test func batchesAuthAndOrigin() async throws {
        let (server, _, client) = try await startServer()
        defer { Task { await server.stop() } }

        let (batchStatus, batch, _) = try await client.post(#"[{"jsonrpc":"2.0","id":"a","method":"ping"},{"jsonrpc":"2.0","method":"notifications/initialized"},{"jsonrpc":"2.0","id":"b","method":"tools/list"}]"#)
        #expect(batchStatus == 200)
        #expect(batch?.arrayValue?.count == 2)
        #expect(batch?.arrayValue?.first?["id"]?.stringValue == "a")

        var wrongToken = client
        wrongToken.token = "nope"
        let (unauthorized, _, _) = try await wrongToken.post(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#)
        #expect(unauthorized == 401)

        var remoteOrigin = client
        remoteOrigin.extraHeaders["Origin"] = "https://evil.example"
        let (forbidden, _, _) = try await remoteOrigin.post(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#)
        #expect(forbidden == 403)

        var localOrigin = client
        localOrigin.extraHeaders["Origin"] = "http://localhost:3000"
        let (ok, _, _) = try await localOrigin.post(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#)
        #expect(ok == 200)

        let (bad, parse, _) = try await client.post("{not json")
        #expect(bad == 400)
        #expect(parse?["error"]?["code"]?.intValue == -32700)

        var get = URLRequest(url: URL(string: "http://127.0.0.1:\(client.port)/mcp")!)
        get.setValue("Bearer secret-token", forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.shared.data(for: get)
        #expect((response as? HTTPURLResponse)?.statusCode == 405)
    }
}

/// A bare TCP connection to the test server, so a test can drop it mid-request.
final class RawHTTPClient {
    struct ConnectFailed: Error {}
    private let descriptor: Int32

    init(port: Int) throws {
        descriptor = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard descriptor >= 0, connected == 0 else {
            Darwin.close(descriptor)
            throw ConnectFailed()
        }
    }

    func send(_ text: String) {
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
    }

    func close() {
        Darwin.close(descriptor)
    }
}
