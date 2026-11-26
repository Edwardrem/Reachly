import Foundation

/// Why an ACP exchange failed.
public enum ACPError: LocalizedError, Equatable {
    /// The agent answered the request with a JSON-RPC error.
    case rpc(method: String, code: Int, message: String)
    /// The agent went away before it answered.
    case agentExited(ACPExit)
    /// The agent did not answer in time.
    case timedOut(String)
    /// The agent's answer was not what ACP describes.
    case invalidResponse(String)

    /// ACP's "authentication required" error code.
    public static let authRequiredCode = -32000

    public var errorDescription: String? {
        switch self {
        case .rpc(let method, let code, let message): "\(method) failed: \(message) (\(code))"
        case .agentExited(let exit): "The agent stopped" + (exit.status.map { " with status \($0)" } ?? "") + "."
        case .timedOut(let method): "The agent didn't answer \(method) in time."
        case .invalidResponse(let detail): "The agent's answer couldn't be read: \(detail)"
        }
    }
}

/// JSON-RPC 2.0 over an `ACPTransport`, in both directions: Reachly sends requests and notifications to the
/// agent, and the agent sends its own requests (`session/request_permission`) and notifications
/// (`session/update`) back.
///
/// Every incoming message is parsed off the main actor and then handled on it, one at a time, in the order the
/// agent wrote it, so all the `session/update` notifications the agent sent before answering `session/prompt`
/// have been handled by the time that answer resumes its caller (ACP sends a turn's updates before its
/// response). An agent request runs in a task of its own, so a permission sheet that waits for the user does not
/// hold up the updates. Each message is reported handled to the transport, which stops reading an agent that
/// gets too far ahead.
@MainActor
public final class ACPConnection {
    /// Handles a request from the agent and returns its result. A thrown `JSONRPC.ErrorObject` is sent as that
    /// error; anything else as an internal error. With no handler, every request is "method not found".
    public var onRequest: (@MainActor (_ method: String, _ params: JSONValue?) async throws -> JSONValue)?
    /// Handles a notification from the agent.
    public var onNotification: (@MainActor (_ method: String, _ params: JSONValue?) -> Void)?
    /// Called once, when the agent is gone.
    public var onClose: (@MainActor (ACPExit) -> Void)?

    /// Set once the transport has closed.
    public private(set) var exit: ACPExit?
    /// Lines that were not JSON-RPC messages, which the agent should never write to its output.
    public private(set) var unreadableLines = 0

    private let transport: any ACPTransport
    private var nextID = 0
    private var pending: [Int: (method: String, continuation: CheckedContinuation<JSONValue, any Error>)] = [:]
    private var reader: Task<Void, Never>?

    public init(transport: any ACPTransport) {
        self.transport = transport
        let events = transport.events
        reader = Task.detached { [weak self, transport] in
            for await event in events {
                switch event {
                case .message(let line):
                    // A large line is parsed here, not on the main actor.
                    let message = try? JSONValue.parse(line)
                    guard let self else { return }
                    await self.handle(message)
                    transport.didHandle(byteCount: line.count)
                case .closed(let exit):
                    guard let self else { return }
                    await self.closed(exit)
                }
            }
        }
    }

    /// A connection nobody holds can't answer the agent any more, so the agent is stopped: it would otherwise
    /// wait for a reader that never comes back.
    deinit {
        transport.close()
    }

    public var isOpen: Bool { exit == nil }

    /// Sends a request and waits for its answer. Fails with `.agentExited` when the agent goes away first, and
    /// with `.timedOut` after `timeout`. Cancelling the calling task does not end the wait: an ACP request is
    /// cancelled with a method of its own, such as `session/cancel`, and the agent still answers.
    public func request(_ method: String, params: JSONValue, timeout: Duration? = nil) async throws -> JSONValue {
        if let exit { throw ACPError.agentExited(exit) }
        nextID += 1
        let id = nextID
        let message: JSONValue = ["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params]
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = (method, continuation)
            transport.send(ACPLineFramer.frame(message))
            if let timeout {
                Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    self?.fail(id, with: ACPError.timedOut(method))
                }
            }
        }
    }

    /// Sends a notification, which has no answer.
    public func notify(_ method: String, params: JSONValue) {
        guard exit == nil else { return }
        transport.send(ACPLineFramer.frame(["jsonrpc": "2.0", "method": .string(method), "params": params]))
    }

    /// Stops the agent. Waiting requests fail with `.agentExited` once it is gone.
    public func close() {
        transport.close()
    }

    /// Ends the wait for one request now, with `error`. Its answer, should it come later, is ignored.
    public func fail(_ id: Int, with error: any Error) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        entry.continuation.resume(throwing: error)
    }

    /// The id the next request will get, so a caller can name a request it is about to make.
    public var lastRequestID: Int { nextID }

    // MARK: Incoming

    private func handle(_ parsed: JSONValue?) {
        guard let message = parsed, message.objectValue != nil else {
            unreadableLines += 1
            return
        }
        if let method = message["method"]?.stringValue {
            let params = message["params"]
            if let id = message["id"], !id.isNull {
                answer(id: id, method: method, params: params)
            } else {
                onNotification?(method, params)
            }
            return
        }
        guard let id = message["id"]?.intValue, let entry = pending.removeValue(forKey: id) else {
            // An answer to nothing we are waiting for (it timed out), or not a message at all.
            if message["result"] == nil && message["error"] == nil { unreadableLines += 1 }
            return
        }
        if let error = message["error"] {
            entry.continuation.resume(throwing: ACPError.rpc(
                method: entry.method,
                code: error["code"]?.intValue ?? JSONRPC.ErrorObject.internalError,
                message: error["message"]?.stringValue ?? "no message"))
        } else {
            entry.continuation.resume(returning: message["result"] ?? .null)
        }
    }

    private func answer(id: JSONValue, method: String, params: JSONValue?) {
        guard let onRequest else {
            reply(id: id, error: JSONRPC.ErrorObject(code: JSONRPC.ErrorObject.methodNotFound, message: "Method not found: \(method)"))
            return
        }
        Task { [weak self] in
            do {
                let result = try await onRequest(method, params)
                self?.reply(id: id, result: result)
            } catch let error as JSONRPC.ErrorObject {
                self?.reply(id: id, error: error)
            } catch {
                self?.reply(id: id, error: JSONRPC.ErrorObject(code: JSONRPC.ErrorObject.internalError, message: error.localizedDescription))
            }
        }
    }

    private func reply(id: JSONValue, result: JSONValue) {
        guard exit == nil else { return }
        transport.send(ACPLineFramer.frame(JSONRPC.response(id: id, result: result)))
    }

    private func reply(id: JSONValue, error: JSONRPC.ErrorObject) {
        guard exit == nil else { return }
        transport.send(ACPLineFramer.frame(JSONRPC.response(id: id, error: error)))
    }

    private func closed(_ exit: ACPExit) {
        guard self.exit == nil else { return }
        self.exit = exit
        let waiting = pending
        pending = [:]
        for entry in waiting.values {
            entry.continuation.resume(throwing: ACPError.agentExited(exit))
        }
        onClose?(exit)
    }
}
