// reachly-mcp: stdio bridge for the Model Context Protocol.
//
// Claude Desktop, Claude Code and other MCP clients launch this tool and talk
// JSON-RPC over stdin/stdout. It forwards every message to the Reachly
// app's local HTTP MCP server (port and token from mcp.json in Application
// Support), launching the app first when it is not running.
import Foundation
import Synchronization

struct BridgeConfig: Sendable {
    var port: Int
    var token: String

    static var url: URL {
        let base: URL
        if let override = Bridge.environment["REACHLY_DATA_DIR"], !override.isEmpty {
            base = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Reachly", directoryHint: .isDirectory)
        }
        return base.appending(path: "mcp.json")
    }

    static func load() -> BridgeConfig? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let port = object["port"] as? Int, let token = object["token"] as? String else { return nil }
        return BridgeConfig(port: port, token: token)
    }
}

enum PostResult: Sendable {
    case response(Data)
    case accepted
    case unreachable(String)
    case failed(Int, Data)
}

enum Bridge {
    static let environment = ProcessInfo.processInfo.environment

    /// Set by Reachly when it hands this bridge to an agent it runs itself (Qoder in the chat panel), so the app
    /// can say who asks in the approval sheet and audit the commands under that conversation. Only short plain
    /// values are passed on; the app takes only names and ids it knows.
    static let callerHeaders: [(String, String)] = {
        let plain = { (value: String) in value.count <= 64 && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") } }
        var headers: [(String, String)] = []
        if let client = environment["REACHLY_MCP_CLIENT"], plain(client) { headers.append(("X-Reachly-Client", client)) }
        if let conversation = environment["REACHLY_MCP_CONVERSATION"], plain(conversation) { headers.append(("X-Reachly-Conversation", conversation)) }
        return headers
    }()

    /// A bridge Reachly handed to an agent it runs never opens Reachly. If Reachly is gone, that agent outlived it
    /// (Reachly crashed, say), and launching the app again would hand an orphan the user's servers.
    static let launchesApp = environment["REACHLY_MCP_CLIENT"] == nil

    /// Requests that are safe to send again once Reachly is back (it restarted with a new port or token): they
    /// change nothing. A `tools/call` never is. It may have reached the app already, and sending it again could
    /// put the same command in a second approval sheet, or run it twice.
    static let resendable: Set<String> = [
        "initialize", "ping", "tools/list", "resources/list", "resources/templates/list", "prompts/list",
        "logging/setLevel", "notifications/initialized", "notifications/cancelled",
    ]

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 900
        configuration.timeoutIntervalForResource = 900
        return URLSession(configuration: configuration)
    }()

    struct State: Sendable {
        var config: BridgeConfig?
        /// The `Mcp-Session-Id` the server gave at `initialize`, sent with every later request so the server can
        /// tell which client a `notifications/cancelled` is from.
        var sessionID: String?
        var launched = false
    }

    static let state = Mutex(State())
    /// Messages being forwarded. Each one goes on its own, so a `notifications/cancelled` reaches the app while
    /// the `tools/call` it cancels is still waiting there for approval.
    static let inflight = DispatchGroup()
    /// One line of standard output at a time.
    static let output = NSLock()

    static func log(_ message: String) {
        FileHandle.standardError.write(Data("[reachly-mcp] \(message)\n".utf8))
    }

    /// The app bundle this tool was copied into, when it was.
    static func appBundleURL() -> URL? {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        // Reachly.app/Contents/MacOS/reachly-mcp
        let bundle = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return bundle.pathExtension == "app" ? bundle : nil
    }

    static func launchApp() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        if let bundle = appBundleURL() {
            process.arguments = ["-g", bundle.path]
        } else {
            process.arguments = ["-g", "-b", "io.github.edwardrem.reachly"]
        }
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            log("could not launch Reachly: \(error.localizedDescription)")
        }
    }

    static func post(_ body: Data, config: BridgeConfig) -> PostResult {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(config.port)/mcp")!)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        for (name, value) in callerHeaders { request.setValue(value, forHTTPHeaderField: name) }
        if let sessionID = state.withLock({ $0.sessionID }) { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        let semaphore = DispatchSemaphore(value: 0)
        let result = Mutex<PostResult>(.unreachable("no response"))
        session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                result.withLock { $0 = .unreachable(error.localizedDescription) }
                return
            }
            guard let http = response as? HTTPURLResponse else {
                result.withLock { $0 = .unreachable("not an HTTP response") }
                return
            }
            if let sessionID = http.value(forHTTPHeaderField: "Mcp-Session-Id"), !sessionID.isEmpty {
                state.withLock { $0.sessionID = sessionID }
            }
            let answer: PostResult = switch http.statusCode {
            case 200: .response(data ?? Data())
            case 202, 204: .accepted
            default: .failed(http.statusCode, data ?? Data())
            }
            result.withLock { $0 = answer }
        }.resume()
        semaphore.wait()
        return result.withLock { $0 }
    }

    /// Waits for the app's server, launching the app once if needed (and allowed).
    static func waitForServer() -> BridgeConfig? {
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline {
            if let config = BridgeConfig.load() {
                let ping = Data(#"{"jsonrpc":"2.0","id":"bridge-ping","method":"ping"}"#.utf8)
                switch post(ping, config: config) {
                case .response:
                    state.withLock { $0.config = config }
                    return config
                case .failed(401, _):
                    log("the token in mcp.json was rejected; turn the MCP server off and on in Reachly → Settings → AI Integration")
                    return nil
                default:
                    break
                }
            }
            let launch = launchesApp && state.withLock { state in
                defer { state.launched = true }
                return !state.launched
            }
            if launch {
                log("Reachly is not running; launching it")
                launchApp()
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        log(launchesApp
            ? "Reachly's MCP server did not answer. Enable it in Reachly → Settings → AI Integration."
            : "Reachly's MCP server did not answer, and this bridge belongs to an agent Reachly started, so it does not open Reachly.")
        return nil
    }

    static func writeOut(_ data: Data) {
        var line = data
        line.append(0x0A)
        output.withLock { FileHandle.standardOutput.write(line) }
    }

    /// A JSON-RPC error answer for the request whose id is `idJSON` (its JSON text).
    static func errorResponse(idJSON: String, code: Int, message: String) -> Data {
        let quoted = (try? JSONSerialization.data(withJSONObject: message, options: [.fragmentsAllowed])).map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
        return Data(#"{"jsonrpc":"2.0","id":\#(idJSON),"error":{"code":\#(code),"message":\#(quoted)}}"#.utf8)
    }

    /// Sends one message on to the app and writes its answer.
    static func forward(_ body: Data, method: String?, idJSON: String?) {
        guard let config = state.withLock({ $0.config }) ?? waitForServer() else {
            if let idJSON { writeOut(errorResponse(idJSON: idJSON, code: -32000, message: "Reachly is not reachable.")) }
            return
        }
        var result = post(body, config: config)
        if case .unreachable = result, let method, resendable.contains(method) {
            // The app may have restarted with a new port or token.
            if let fresh = waitForServer() { result = post(body, config: fresh) }
        }
        switch result {
        case .response(let data):
            writeOut(data)
        case .accepted:
            break
        case .unreachable(let detail):
            guard let idJSON else { return }
            let retried = method.map(resendable.contains) == true ? "" : " It was not sent again, since it may already have reached Reachly."
            let reason = detail.hasSuffix(".") ? String(detail.dropLast()) : detail
            writeOut(errorResponse(idJSON: idJSON, code: -32000, message: "Reachly is not reachable: \(reason).\(retried)"))
        case .failed(let status, let data):
            if let idJSON { writeOut(errorResponse(idJSON: idJSON, code: -32000, message: "Reachly answered HTTP \(status): \(String(decoding: data.prefix(200), as: UTF8.self))")) }
        }
    }

    static func run() -> Never {
        guard waitForServer() != nil else { exit(1) }
        while let line = readLine(strippingNewline: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let body = Data(trimmed.utf8)
            let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            let method = object?["method"] as? String
            let idJSON = object?["id"].flatMap { id -> String? in
                guard !(id is NSNull), let data = try? JSONSerialization.data(withJSONObject: id, options: [.fragmentsAllowed]) else { return nil }
                return String(decoding: data, as: UTF8.self)
            }
            inflight.enter()
            DispatchQueue.global().async {
                defer { inflight.leave() }
                forward(body, method: method, idJSON: idJSON)
            }
        }
        // The client closed its end. Answers still on their way get a moment; a tool call still waiting for
        // approval does not hold the bridge open: when it exits, Reachly takes the request down.
        _ = inflight.wait(timeout: .now() + 5)
        exit(0)
    }
}

Bridge.run()
