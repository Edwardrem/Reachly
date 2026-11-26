import Foundation

/// Drives an agent over the Agent Client Protocol, with Reachly as the client: it starts the agent process
/// on first use, initializes it, keeps one session per conversation, sends each user message as a
/// `session/prompt`, turns the agent's `session/update` notifications into transcript events, and asks the
/// user, through `permissionHandler`, when the agent wants to run one of its own tools.
///
/// Reachly hands the agent its own MCP bridge in every session's `mcpServers`, so the agent works on servers
/// with Reachly's tools, under the guardrails, the approval sheet and the audit log. It advertises no file
/// system and no terminal capability: the agent's own tools on this Mac stay its own.
@MainActor
public final class ACPAgent: ExternalAgent {
    public struct Configuration: Sendable {
        /// Who answers, in messages ("Qoder").
        public var name: String
        public var executable: String
        /// Tried in order until one answers `initialize`. Qoder's docs give `--acp`; Zed's listing gives `acp`.
        public var argumentSets: [[String]]
        public var environment: [String: String]
        /// The agent's working directory and every session's `cwd`: a folder Reachly owns, never the home folder.
        public var workingDirectory: URL
        /// The MCP servers for a conversation's session: Reachly's bridge.
        public var mcpServers: @Sendable (_ conversationKey: String) -> [ACPProtocol.StdioMCPServer]
        public var clientName: String
        public var clientVersion: String
        public var initializeTimeout: Duration
        public var sessionTimeout: Duration
        /// After Stop, how long the agent has to answer the prompt as cancelled before it is stopped.
        public var cancelGrace: Duration
        /// Where each conversation's session id is kept for `session/load`.
        public var sessionStore: ACPSessionStore?
        /// How to sign in, for the failure row when the agent says it needs authentication. Reachly never
        /// signs in for the agent and never sees its credentials.
        public var signInHint: String?

        public init(
            name: String,
            executable: String,
            argumentSets: [[String]],
            environment: [String: String],
            workingDirectory: URL,
            mcpServers: @escaping @Sendable (_ conversationKey: String) -> [ACPProtocol.StdioMCPServer],
            clientName: String = "Reachly",
            clientVersion: String,
            initializeTimeout: Duration = .seconds(30),
            sessionTimeout: Duration = .seconds(60),
            cancelGrace: Duration = .seconds(10),
            sessionStore: ACPSessionStore? = nil,
            signInHint: String? = nil
        ) {
            self.name = name
            self.executable = executable
            self.argumentSets = argumentSets
            self.environment = environment
            self.workingDirectory = workingDirectory
            self.mcpServers = mcpServers
            self.clientName = clientName
            self.clientVersion = clientVersion
            self.initializeTimeout = initializeTimeout
            self.sessionTimeout = sessionTimeout
            self.cancelGrace = cancelGrace
            self.sessionStore = sessionStore
            self.signInHint = signInHint
        }
    }

    public let configuration: Configuration
    public var name: String { configuration.name }

    /// Asks the user before one of the agent's own tools runs. With none, every request is rejected.
    public var permissionHandler: (@MainActor (AgentPermissionRequest) async -> AgentPermissionDecision)?
    /// Called with the conversation's key when a turn ends for any reason: answered, stopped, failed, or the
    /// agent gone. Stop calls it at once, without waiting for the agent to wind down. Whatever still waits on
    /// the turn elsewhere, such as an approval sheet for a server command the agent asked for through Reachly's
    /// MCP server, can then be taken down: nobody is left to use its answer.
    public var turnEndHandler: (@MainActor (_ conversationKey: String) -> Void)?

    /// What the agent said about itself, while it runs.
    public private(set) var agentInfo: ACPProtocol.AgentInfo?
    /// The arguments that started the running agent.
    public private(set) var launchArguments: [String]?
    /// The agent process is up and initialized.
    public var isConnected: Bool { connection?.isOpen == true && agentInfo != nil }
    /// A turn is in progress.
    public var isBusy: Bool { turn != nil }

    /// A turn for this conversation (for any, with nil) is in progress and was not stopped: only then can a
    /// request the agent makes for it (a server command through the MCP server) still be answered.
    public func isAnswering(_ conversationKey: String?) -> Bool {
        guard let turn, !turn.cancelled else { return false }
        return conversationKey.map { $0 == turn.conversationKey } ?? true
    }

    /// Makes the transport for one launch; tests can hand in their own.
    var makeTransport: (Configuration, [String]) throws -> any ACPTransport = { configuration, arguments in
        try FileManager.default.createDirectory(at: configuration.workingDirectory, withIntermediateDirectories: true)
        return try ACPProcess(executable: configuration.executable, arguments: arguments, environment: configuration.environment, currentDirectory: configuration.workingDirectory)
    }

    private var connection: ACPConnection?
    /// The session each conversation uses in the running agent.
    private var liveSessions: [String: String] = [:]
    /// The session being restored with `session/load`: its replayed history is already in the transcript.
    private var replaying: String?
    private var turn: TurnState?

    private struct TurnState {
        let id = UUID()
        let sessionID: String
        let conversationKey: String
        let events: @MainActor (ExternalAgentEvent) -> Void
        var toolCalls: [String: AgentToolActivity] = [:]
        var permissionTasks: [UUID: Task<AgentPermissionDecision, Never>] = [:]
        var cancelled = false
    }

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    // MARK: Turn

    public func run(_ turn: ExternalAgentTurn, events: @escaping @MainActor (ExternalAgentEvent) -> Void) async throws -> ExternalAgentStopReason {
        guard self.turn == nil else {
            throw ExternalAgentFailure(kind: .setup, message: "\(name) is still answering another message.")
        }
        // However the turn ends, nothing may keep waiting on it.
        defer { turnEndHandler?(turn.conversationKey) }
        let connection = try await connect()
        events(.started(agent: agentInfo?.label))
        try Task.checkCancellation()
        let (sessionID, isNew) = try await session(for: turn.conversationKey, on: connection)
        if isNew, turn.hasEarlierTurns {
            events(.notice("\(name) started a new session, so it doesn't know the earlier messages in this conversation."))
        }
        try Task.checkCancellation()
        let info = agentInfo ?? ACPProtocol.AgentInfo()
        let content = ACPProtocol.promptContent(for: turn.message, context: isNew ? turn.context : nil, agent: info)

        let state = TurnState(sessionID: sessionID, conversationKey: turn.conversationKey, events: events)
        let turnID = state.id
        self.turn = state
        defer { endTurn(turnID) }
        do {
            let result = try await withTaskCancellationHandler {
                try await connection.request("session/prompt", params: ACPProtocol.promptParams(sessionID: sessionID, content: content))
            } onCancel: {
                Task { @MainActor [weak self] in self?.cancel(turnID) }
            }
            // Stop was pressed: the turn ends as stopped, even when the agent finished before it saw the cancel.
            let stop = self.turn?.cancelled == true ? .cancelled : try ACPProtocol.stopReason(from: result)
            if stop == .cancelled { markUnfinishedCalls(.cancelled) }
            return stop
        } catch {
            let wasCancelled = self.turn?.cancelled == true || Task.isCancelled
            markUnfinishedCalls(wasCancelled ? .cancelled : .failed)
            if wasCancelled { throw CancellationError() }
            throw failure(for: error, during: "the reply")
        }
    }

    /// Stops the agent process. The next turn starts it again, with new sessions (or restored ones, where the
    /// agent offers `session/load`).
    public func shutdown() {
        connection?.close()
        connection = nil
        agentInfo = nil
        launchArguments = nil
        liveSessions = [:]
    }

    /// The conversation's earlier turns no longer match the agent's session (a message was edited, or the
    /// conversation was deleted): its next turn starts a new session.
    public func forgetSession(for conversationKey: String) {
        liveSessions[conversationKey] = nil
        configuration.sessionStore?.set(nil, for: conversationKey)
    }

    // MARK: Connecting

    private func connect() async throws -> ACPConnection {
        if let connection, connection.isOpen, agentInfo != nil { return connection }
        shutdown()
        var problem = ""
        for arguments in configuration.argumentSets {
            try Task.checkCancellation()
            let transport: any ACPTransport
            do {
                transport = try makeTransport(configuration, arguments)
            } catch {
                throw ExternalAgentFailure(kind: .setup, message: "\(name) couldn't be started from \(configuration.executable). Check that it is still installed, then Retry.")
            }
            let connection = ACPConnection(transport: transport)
            connection.onNotification = { [weak self] method, params in self?.handleNotification(method, params) }
            connection.onRequest = { [weak self] method, params in
                guard let self else { throw JSONRPC.ErrorObject(code: JSONRPC.ErrorObject.internalError, message: "Reachly closed the session") }
                return try await self.handleRequest(method, params)
            }
            connection.onClose = { [weak self, weak connection] _ in
                guard let self, let connection, connection === self.connection else { return }
                self.connection = nil
                self.agentInfo = nil
                self.launchArguments = nil
                self.liveSessions = [:]
            }
            do {
                let result = try await setupRequest(
                    "initialize",
                    params: ACPProtocol.initializeParams(clientName: configuration.clientName, clientVersion: configuration.clientVersion),
                    timeout: configuration.initializeTimeout,
                    on: connection)
                agentInfo = try ACPProtocol.agentInfo(from: result)
                launchArguments = arguments
                self.connection = connection
                return connection
            } catch is CancellationError {
                connection.close()
                throw CancellationError()
            } catch {
                connection.close()
                if case ACPError.agentExited(let exit) = error {
                    problem = Self.errorSummary(exit.standardError).map { " It said: \($0)" } ?? ""
                } else if case ACPError.timedOut = error {
                    problem = " It didn't answer within \(configuration.initializeTimeout.components.seconds) seconds."
                } else {
                    problem = " " + (error.localizedDescription)
                }
            }
        }
        throw ExternalAgentFailure(kind: .setup, message: "\(name) didn't start in ACP mode.\(problem)")
    }

    /// The conversation's session in the running agent: the live one, the one it had before when the agent can
    /// load it, or a new one. True when the session is new, so it has none of the conversation's history.
    private func session(for conversationKey: String, on connection: ACPConnection) async throws -> (String, Bool) {
        if let live = liveSessions[conversationKey] { return (live, false) }
        let cwd = configuration.workingDirectory
        let servers = configuration.mcpServers(conversationKey)
        if agentInfo?.loadSession == true, let saved = configuration.sessionStore?.sessionID(for: conversationKey) {
            replaying = saved
            defer { replaying = nil }
            do {
                _ = try await setupRequest("session/load", params: ACPProtocol.loadSessionParams(sessionID: saved, cwd: cwd, mcpServers: servers), timeout: configuration.sessionTimeout, on: connection)
                liveSessions[conversationKey] = saved
                return (saved, false)
            } catch let error as ACPError {
                // Gone, expired or unreadable: start a new one, unless the agent itself went away.
                if case .agentExited = error { throw failure(for: error, during: "loading the session") }
            }
        }
        do {
            let result = try await setupRequest("session/new", params: ACPProtocol.newSessionParams(cwd: cwd, mcpServers: servers), timeout: configuration.sessionTimeout, on: connection)
            let id = try ACPProtocol.sessionID(from: result)
            liveSessions[conversationKey] = id
            configuration.sessionStore?.set(id, for: conversationKey)
            return (id, true)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw failure(for: error, during: "starting a session")
        }
    }

    /// A request made before the prompt (initialize, session/new, session/load). ACP has no way to cancel
    /// these, so Stop while one waits stops the agent instead of leaving the user waiting for its timeout.
    private func setupRequest(_ method: String, params: JSONValue, timeout: Duration, on connection: ACPConnection) async throws -> JSONValue {
        do {
            return try await withTaskCancellationHandler {
                try await connection.request(method, params: params, timeout: timeout)
            } onCancel: {
                Task { @MainActor in connection.close() }
            }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    // MARK: Cancelling

    /// Stop: tells the agent with `session/cancel`, answers its waiting permission requests as cancelled, and
    /// marks the calls still running as cancelled (Prompt Turn › Cancellation). An agent that has not answered
    /// the prompt within `cancelGrace` is stopped.
    private func cancel(_ turnID: UUID) {
        guard let state = turn, state.id == turnID, !state.cancelled else { return }
        turn?.cancelled = true
        connection?.notify("session/cancel", params: ACPProtocol.cancelParams(sessionID: state.sessionID))
        for task in state.permissionTasks.values { task.cancel() }
        markUnfinishedCalls(.cancelled)
        turnEndHandler?(state.conversationKey)
        let grace = configuration.cancelGrace
        Task { [weak self] in
            try? await Task.sleep(for: grace)
            guard let self, self.turn?.id == turnID else { return }
            self.shutdown()
        }
    }

    /// The turn is over: a permission request still waiting (the agent answered the prompt without waiting for
    /// it, or went away) is answered as cancelled, so its sheet goes.
    private func endTurn(_ turnID: UUID) {
        guard let state = turn, state.id == turnID else { return }
        turn = nil
        for task in state.permissionTasks.values { task.cancel() }
    }

    private func markUnfinishedCalls(_ status: AgentToolActivity.Status) {
        guard let state = turn else { return }
        for (id, call) in state.toolCalls where !call.status.isFinished {
            var finished = call
            finished.status = status
            turn?.toolCalls[id] = finished
            state.events(.toolCall(finished))
        }
    }

    // MARK: From the agent

    private func handleNotification(_ method: String, _ params: JSONValue?) {
        guard method == "session/update" else { return }
        let sessionID = params?["sessionId"]?.stringValue
        // A `session/load` replays the whole conversation, which the transcript already shows.
        if let replaying, sessionID == nil || sessionID == replaying { return }
        guard let state = turn, sessionID == nil || sessionID == state.sessionID,
              let update = ACPProtocol.update(from: params) else { return }
        switch update {
        case .text(let text, let messageID):
            if !text.isEmpty { state.events(.text(text, messageID: messageID)) }
        case .thought(let text, let messageID):
            if !text.isEmpty { state.events(.thinking(text, messageID: messageID)) }
        case .toolCall(let patch):
            let call = patch.applied(to: state.toolCalls[patch.id])
            turn?.toolCalls[patch.id] = call
            state.events(.toolCall(call))
        case .plan(let entries):
            state.events(.plan(entries))
        case .mode(let mode):
            state.events(.notice("\(name) switched to its \(mode) mode."))
        case .userEcho, .ignored:
            break
        }
    }

    private func handleRequest(_ method: String, _ params: JSONValue?) async throws -> JSONValue {
        switch method {
        case "session/request_permission":
            return try await requestPermission(params)
        default:
            // fs/* and terminal/* were not advertised, so an agent following ACP never asks for them.
            throw JSONRPC.ErrorObject(code: JSONRPC.ErrorObject.methodNotFound, message: "Method not found: \(method)")
        }
    }

    private func requestPermission(_ params: JSONValue?) async throws -> JSONValue {
        guard let parsed = ACPProtocol.permissionRequest(from: params) else {
            throw JSONRPC.ErrorObject(code: JSONRPC.ErrorObject.invalidParams, message: "session/request_permission needs a toolCall with a toolCallId")
        }
        let cancelled: JSONValue = ["outcome": ["outcome": "cancelled"]]
        // Nothing to ask about outside a turn, or once Stop was pressed.
        guard let state = turn, !state.cancelled, parsed.sessionID == nil || parsed.sessionID == state.sessionID else { return cancelled }
        let turnID = state.id
        var call = parsed.toolCall.applied(to: state.toolCalls[parsed.toolCall.id])
        turn?.toolCalls[call.id] = call
        state.events(.toolCall(call))

        let request = AgentPermissionRequest(agentName: name, toolCall: call, options: parsed.options)
        let handler = permissionHandler
        let ask = Task { @MainActor in await handler?(request) ?? .dismissed }
        turn?.permissionTasks[request.id] = ask
        let answer = await withTaskCancellationHandler { await ask.value } onCancel: { ask.cancel() }
        let stillCurrent = turn?.id == turnID && turn?.cancelled == false
        if turn?.id == turnID { turn?.permissionTasks[request.id] = nil }
        let decision: AgentPermissionDecision = stillCurrent ? answer : .cancelled
        let outcome = ACPProtocol.permissionOutcome(decision, request: request)

        call = turn?.toolCalls[call.id] ?? call
        call.permission = Self.permissionNote(decision, chosen: outcome.chosen)
        if turn?.id == turnID {
            turn?.toolCalls[call.id] = call
            state.events(.toolCall(call))
        }
        return outcome.result
    }

    /// What the tool row says about the answer.
    static func permissionNote(_ decision: AgentPermissionDecision, chosen: AgentPermissionRequest.Option?) -> String {
        switch decision {
        case .selected:
            guard let chosen else { return "Rejected." }
            return (chosen.kind?.allows == true ? "Allowed: " : "Rejected: ") + chosen.name
        case .dismissed:
            return chosen.map { "Closed without a choice, so rejected (\($0.name))." } ?? "Closed without a choice, so rejected."
        case .cancelled:
            return "Not answered: the reply was stopped."
        }
    }

    // MARK: Errors

    private func failure(for error: any Error, during step: String) -> ExternalAgentFailure {
        if let failure = error as? ExternalAgentFailure { return failure }
        switch error as? ACPError {
        case .rpc(_, let code, let message)? where code == ACPError.authRequiredCode:
            let hint = configuration.signInHint ?? "Sign in with \(name)'s own command line tool, then Retry."
            return ExternalAgentFailure(kind: .setup, message: "\(name) isn't signed in (\(message)). \(hint)")
        case .rpc(_, let code, let message)?:
            return ExternalAgentFailure(kind: .error, message: "\(name) reported an error while \(step): \(message) (\(code)).")
        case .agentExited(let exit)?:
            if exit.wasStopped { return ExternalAgentFailure(kind: .error, message: "\(name) was stopped before it finished.") }
            let status = exit.status.map { " (exit status \($0))" } ?? ""
            let said = Self.errorSummary(exit.standardError).map { " It said: \($0)" } ?? ""
            return ExternalAgentFailure(kind: .error, message: "\(name) stopped unexpectedly\(status).\(said)")
        case .timedOut?:
            return ExternalAgentFailure(kind: .error, message: "\(name) didn't answer in time while \(step).")
        case .invalidResponse(let detail)?:
            return ExternalAgentFailure(kind: .error, message: "\(name)'s answer couldn't be read: \(detail)")
        case nil:
            return ExternalAgentFailure(kind: .error, message: error.localizedDescription)
        }
    }

    /// The last few lines the agent logged, short enough for the failure row, with anything that looks like a
    /// token masked: the row is saved with the conversation.
    nonisolated static func errorSummary(_ standardError: String, lines: Int = 3, characters: Int = 400) -> String? {
        let kept = standardError
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .suffix(lines)
        guard !kept.isEmpty else { return nil }
        var text = kept.joined(separator: " · ")
        text = text.replacingOccurrences(of: #"[A-Za-z0-9_\-+]{32,}"#, with: "…", options: .regularExpression)
        if text.count > characters { text = "…" + text.suffix(characters - 1) }
        return text
    }
}
