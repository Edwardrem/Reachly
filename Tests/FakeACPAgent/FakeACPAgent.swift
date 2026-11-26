// fake-acp-agent: a scripted Agent Client Protocol agent for Reachly's tests. It speaks JSON-RPC over stdio,
// one message per line, and replays the session named by FAKE_ACP_SCENARIO. Every line it reads is appended to
// the file named by FAKE_ACP_LOG (after a first line with its arguments), so a test can check what the client
// sent. It never touches the user's files, and the network only to call the test's own MCP server on 127.0.0.1
// (FAKE_ACP_MCP_PORT and FAKE_ACP_MCP_TOKEN), the way a real agent calls Reachly's through the bridge.
import Foundation

/// Lines read from stdin by a reader thread, for the script on the main thread. Every access to `lines` and
/// `closed` holds `condition`'s lock, which is what makes the class safe to share between the two threads.
final class Inbox: @unchecked Sendable {
    private let condition = NSCondition()
    private var lines: [[String: Any]] = []
    private var closed = false

    func put(_ message: [String: Any]) {
        condition.lock()
        lines.append(message)
        condition.signal()
        condition.unlock()
    }

    func close() {
        condition.lock()
        closed = true
        condition.broadcast()
        condition.unlock()
    }

    /// The next message, waiting up to `timeout` seconds; nil on timeout, or once stdin closed and nothing is left.
    func next(timeout: TimeInterval = 30) -> [String: Any]? {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while lines.isEmpty && !closed {
            if !condition.wait(until: deadline) { return nil }
        }
        return lines.isEmpty ? nil : lines.removeFirst()
    }

    /// The next message, but only when one is already waiting.
    func poll() -> [String: Any]? {
        condition.lock()
        defer { condition.unlock() }
        return lines.isEmpty ? nil : lines.removeFirst()
    }
}

@main
enum FakeACPAgent {
    static let environment = ProcessInfo.processInfo.environment
    static let scenario = environment["FAKE_ACP_SCENARIO"] ?? "basic"
    static let arguments = Array(CommandLine.arguments.dropFirst())
    static let inbox = Inbox()
    static let logPath = environment["FAKE_ACP_LOG"]

    static func main() {
        log("ARGV " + arguments.joined(separator: " "))
        if scenario == "needs-subcommand", arguments.contains("--acp") {
            FileHandle.standardError.write(Data("error: unknown option '--acp'\n".utf8))
            exit(2)
        }
        Thread.detachNewThread {
            while let line = readLine(strippingNewline: true) {
                log(line)
                guard let data = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                inbox.put(object)
            }
            inbox.close()
        }
        serve()
    }

    static func serve() {
        var sessionCount = 0
        /// Each session's conversation, from the bridge's environment in `mcpServers`.
        var conversations: [String: String] = [:]
        while let message = inbox.next(timeout: 600) {
            guard let method = message["method"] as? String else { continue }
            let id = message["id"]
            let params = message["params"] as? [String: Any] ?? [:]
            switch method {
            case "initialize":
                guard let id else { continue }
                if scenario == "silent-init" { continue }
                respond(id, result: [
                    "protocolVersion": 1,
                    "agentCapabilities": ["loadSession": scenario == "loadable", "promptCapabilities": ["image": false, "audio": false, "embeddedContext": true]],
                    "agentInfo": ["name": "fake-acp", "title": "Fake ACP", "version": "0.0.1"],
                    "authMethods": [],
                ])
            case "session/new":
                guard let id else { continue }
                if scenario == "auth" {
                    respond(id, errorCode: -32000, message: "Authentication required")
                    continue
                }
                sessionCount += 1
                let servers = params["mcpServers"] as? [[String: Any]] ?? []
                let env = servers.first?["env"] as? [[String: Any]] ?? []
                conversations["sess-\(sessionCount)"] = env.first { $0["name"] as? String == "REACHLY_MCP_CONVERSATION" }?["value"] as? String
                respond(id, result: ["sessionId": "sess-\(sessionCount)"])
            case "session/load":
                guard let id else { continue }
                let session = params["sessionId"] as? String ?? ""
                update(session, ["sessionUpdate": "user_message_chunk", "content": ["type": "text", "text": "replayed question"]])
                text(session, "replayed answer")
                respond(id, result: [:])
            case "session/prompt":
                guard let id else { continue }
                let session = params["sessionId"] as? String ?? ""
                runPrompt(id: id, session: session, conversation: conversations[session])
            default:
                if let id { respond(id, errorCode: -32601, message: "Method not found: \(method)") }
            }
        }
    }

    // MARK: Scripts

    static func runPrompt(id: Any, session: String, conversation: String?) {
        switch scenario {
        case "basic", "needs-subcommand", "loadable":
            update(session, ["sessionUpdate": "agent_thought_chunk", "content": ["type": "text", "text": "Looking at the disk."]])
            text(session, "Root is ", messageID: "m1")
            text(session, "at 91%.", messageID: "m1")
            update(session, ["sessionUpdate": "tool_call", "toolCallId": "call-1", "title": "reachly: run_command", "kind": "execute", "status": "pending", "rawInput": ["host": "web-01", "command": "df -h"]])
            update(session, ["sessionUpdate": "tool_call_update", "toolCallId": "call-1", "status": "in_progress"])
            update(session, ["sessionUpdate": "tool_call_update", "toolCallId": "call-1", "status": "completed", "content": [["type": "content", "content": ["type": "text", "text": "/dev/sda1 80G 73G 91% /"]]], "locations": [["path": "/etc/fstab", "line": 3]]])
            update(session, ["sessionUpdate": "plan", "entries": [["content": "Check the disk", "priority": "high", "status": "completed"], ["content": "Write it up", "priority": "medium", "status": "in_progress"]]])
            update(session, ["sessionUpdate": "user_message_chunk", "content": ["type": "text", "text": "an echo the client must not show"]])
            update(session, ["sessionUpdate": "available_commands_update", "availableCommands": [["name": "init", "description": "Write AGENTS.md"]]])
            text(session, "Done.", messageID: "m2")
            respond(id, result: ["stopReason": "end_turn"])
        case "permission":
            update(session, ["sessionUpdate": "tool_call", "toolCallId": "call-p", "title": "Edit notes.txt", "kind": "edit", "status": "pending"])
            send(["jsonrpc": "2.0", "id": "perm-1", "method": "session/request_permission", "params": [
                "sessionId": session,
                "toolCall": ["toolCallId": "call-p", "title": "Edit notes.txt", "kind": "edit", "rawInput": ["path": "/tmp/notes.txt"]],
                "options": [["optionId": "allow", "name": "Allow once", "kind": "allow_once"], ["optionId": "reject", "name": "Reject", "kind": "reject_once"]],
            ] as [String: Any]])
            let (answer, cancelled) = waitForAnswer(to: "perm-1")
            let outcome = (answer?["result"] as? [String: Any])?["outcome"] as? [String: Any]
            let kind = outcome?["outcome"] as? String ?? "none"
            let option = outcome?["optionId"] as? String
            text(session, "permission: \(kind)" + (option.map { " \($0)" } ?? ""))
            update(session, ["sessionUpdate": "tool_call_update", "toolCallId": "call-p", "status": option == "allow" ? "completed" : "failed"])
            respond(id, result: ["stopReason": cancelled ? "cancelled" : "end_turn"])
        case "slow", "ignore-cancel":
            update(session, ["sessionUpdate": "tool_call", "toolCallId": "call-s", "title": "Long task", "kind": "execute", "status": "in_progress"])
            for index in 0..<200 {
                text(session, "tick \(index) ")
                Thread.sleep(forTimeInterval: 0.05)
                while let message = inbox.poll() {
                    if message["method"] as? String == "session/cancel" {
                        if scenario == "ignore-cancel" { continue }
                        respond(id, result: ["stopReason": "cancelled"])
                        return
                    }
                }
            }
            respond(id, result: ["stopReason": "end_turn"])
        case "error":
            text(session, "Partial ")
            respond(id, errorCode: -32603, message: "model overloaded")
        case "crash":
            text(session, "Starting ")
            update(session, ["sessionUpdate": "tool_call", "toolCallId": "call-c", "title": "Read config", "kind": "read", "status": "in_progress"])
            FileHandle.standardError.write(Data("loading\npanic: index out of range\ntoken=abcdefghijklmnopqrstuvwxyz0123456789ABCDEF\n".utf8))
            Thread.sleep(forTimeInterval: 0.1)
            exit(3)
        case "permission-answered", "permission-crash":
            // Asks, then does not wait for the answer: it answers the prompt, or dies.
            send(["jsonrpc": "2.0", "id": "perm-2", "method": "session/request_permission", "params": [
                "sessionId": session,
                "toolCall": ["toolCallId": "call-q", "title": "Write notes.txt", "kind": "edit"],
                "options": [["optionId": "allow", "name": "Allow once", "kind": "allow_once"], ["optionId": "reject", "name": "Reject", "kind": "reject_once"]],
            ] as [String: Any]])
            Thread.sleep(forTimeInterval: 0.3)
            if scenario == "permission-crash" { exit(3) }
            respond(id, result: ["stopReason": "end_turn"])
        case "mcp-call", "mcp-crash":
            // Calls Reachly's run_command over MCP, as Qoder does through the bridge, and waits for its answer.
            update(session, ["sessionUpdate": "tool_call", "toolCallId": "call-m", "title": "reachly: run_command", "kind": "execute", "status": "in_progress"])
            postToolCall(conversation: conversation)
            if scenario == "mcp-crash" {
                // Dies once the test has seen the approval sheet, which it says by creating FAKE_ACP_TRIGGER.
                let trigger = environment["FAKE_ACP_TRIGGER"] ?? ""
                while !FileManager.default.fileExists(atPath: trigger) { Thread.sleep(forTimeInterval: 0.02) }
                exit(3)
            }
            var answered = false
            while let message = inbox.next() {
                switch message["method"] as? String {
                case "session/cancel":
                    if !answered { respond(id, result: ["stopReason": "cancelled"]) }
                    answered = true
                case "fake/http-answered":
                    if !answered { respond(id, result: ["stopReason": "end_turn"]) }
                    return
                default:
                    continue
                }
            }
        case "fsprobe":
            send(["jsonrpc": "2.0", "id": "fs-1", "method": "fs/read_text_file", "params": ["sessionId": session, "path": "/etc/hosts"]])
            let (answer, _) = waitForAnswer(to: "fs-1")
            let code = (answer?["error"] as? [String: Any])?["code"] as? Int
            text(session, "fs: \(code.map(String.init) ?? "answered")")
            respond(id, result: ["stopReason": "end_turn"])
        case "maxtokens":
            text(session, "Half a reply")
            respond(id, result: ["stopReason": "max_tokens"])
        case "refusal":
            respond(id, result: ["stopReason": "refusal"])
        default:
            respond(id, result: ["stopReason": "end_turn"])
        }
    }

    /// Posts one `tools/call` to the test's MCP server, as the bridge would, naming the caller the way the bridge
    /// does. Its answer is logged as `HTTP <body>` and then put in the inbox as `fake/http-answered`.
    static func postToolCall(conversation: String?) {
        guard let port = environment["FAKE_ACP_MCP_PORT"], let token = environment["FAKE_ACP_MCP_TOKEN"],
              let url = URL(string: "http://127.0.0.1:\(port)/mcp") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("qoder", forHTTPHeaderField: "X-Reachly-Client")
        if let conversation { request.setValue(conversation, forHTTPHeaderField: "X-Reachly-Conversation") }
        request.httpBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"run_command","arguments":{"host":"web-01","command":"rm -rf /var/cache/nginx","reason":"Clear the cache"}}}"#.utf8)
        URLSession.shared.dataTask(with: request) { data, _, error in
            log("HTTP " + (data.map { String(decoding: $0, as: UTF8.self) } ?? "failed: \(error?.localizedDescription ?? "no answer")"))
            inbox.put(["method": "fake/http-answered"])
        }.resume()
    }

    /// Waits for the answer to a request the agent sent, noting any cancel that came meanwhile.
    static func waitForAnswer(to id: String) -> (answer: [String: Any]?, cancelled: Bool) {
        var cancelled = false
        while let message = inbox.next() {
            if message["method"] as? String == "session/cancel" {
                cancelled = true
                continue
            }
            if message["id"] as? String == id, message["method"] == nil { return (message, cancelled) }
        }
        return (nil, cancelled)
    }

    // MARK: Wire

    static func log(_ line: String) {
        guard let logPath else { return }
        let data = Data((line + "\n").utf8)
        if let handle = FileHandle(forWritingAtPath: logPath) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: logPath, contents: data)
        }
    }

    static func send(_ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }

    static func respond(_ id: Any, result: Any) {
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    static func respond(_ id: Any, errorCode: Int, message: String) {
        send(["jsonrpc": "2.0", "id": id, "error": ["code": errorCode, "message": message] as [String: Any]])
    }

    static func update(_ session: String, _ update: [String: Any]) {
        send(["jsonrpc": "2.0", "method": "session/update", "params": ["sessionId": session, "update": update] as [String: Any]])
    }

    static func text(_ session: String, _ text: String, messageID: String? = nil) {
        var chunk: [String: Any] = ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": text]]
        if let messageID { chunk["messageId"] = messageID }
        update(session, chunk)
    }
}
