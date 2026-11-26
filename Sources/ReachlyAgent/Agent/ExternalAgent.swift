import Foundation

/// An agent that runs its own loop and its own tools, such as an ACP agent (Qoder). Reachly sends it the
/// user's message and shows what it reports; it is not asked for one model reply at a time the way an
/// `LLMProvider` is, and Reachly's tool runner does not run its tools. It reaches the user's servers through
/// Reachly's MCP server, so every command there still goes through the guardrails, the approval sheet and the
/// audit log.
@MainActor
public protocol ExternalAgent: AnyObject {
    /// Who answers, for messages about it ("Qoder").
    var name: String { get }

    /// Runs one turn and returns how it ended. Progress is reported through `events` on the main actor, in
    /// the order the agent sent it, and always before this returns. Cancelling the calling task asks the agent
    /// to stop: the call then returns `.cancelled` once the agent has wound down, or throws
    /// `CancellationError` when it does not answer in time. Any other error is an `ExternalAgentFailure`.
    func run(_ turn: ExternalAgentTurn, events: @escaping @MainActor (ExternalAgentEvent) -> Void) async throws -> ExternalAgentStopReason

    /// The conversation no longer matches what the agent was told (an earlier message was edited, or the
    /// conversation was cleared): its next turn starts a new agent session.
    func forgetSession(for conversationKey: String)
}

/// One user turn for an external agent.
public struct ExternalAgentTurn: Sendable {
    /// Names the conversation, so the agent can keep one session per conversation.
    public var conversationKey: String
    /// The user's message: its text and attachments.
    public var message: AgentMessage
    /// Reachly's context for the agent (the hosts in scope and how to reach them), sent at the start of a
    /// new agent session, where a system prompt would go.
    public var context: String
    /// The conversation had turns before this one, so a new agent session would not know them.
    public var hasEarlierTurns: Bool

    public init(conversationKey: String, message: AgentMessage, context: String, hasEarlierTurns: Bool) {
        self.conversationKey = conversationKey
        self.message = message
        self.context = context
        self.hasEarlierTurns = hasEarlierTurns
    }
}

/// What an external agent reports while a turn runs.
public enum ExternalAgentEvent: Sendable, Equatable {
    /// The agent is up; `agent` names it and its version for the status line.
    case started(agent: String?)
    /// Something the reader should know that is not part of the reply, such as a new session.
    case notice(String)
    /// A piece of the reply. A new `messageID` starts a new message.
    case text(String, messageID: String?)
    /// A piece of the agent's reasoning.
    case thinking(String, messageID: String?)
    /// A tool call the agent started, or its new state. Always the whole call, merged with earlier updates.
    case toolCall(AgentToolActivity)
    /// The agent's plan for the turn. Each one replaces the one before.
    case plan([AgentPlanEntry])
}

/// How an external agent's turn ended (ACP `StopReason`).
public enum ExternalAgentStopReason: String, Sendable, Equatable {
    case endTurn = "end_turn"
    case maxTokens = "max_tokens"
    case maxTurnRequests = "max_turn_requests"
    case refusal
    case cancelled
}

/// Why an external agent's turn could not run or did not finish, in words for the failure row.
public struct ExternalAgentFailure: LocalizedError, Equatable {
    /// `.setup` when nothing was sent (the agent would not start, is not signed in, or the MCP server is off);
    /// `.error` when the agent failed or stopped during the turn.
    public var kind: AgentFailure.Kind
    public var message: String

    public init(kind: AgentFailure.Kind, message: String) {
        self.kind = kind
        self.message = message
    }

    public var errorDescription: String? { message }
}

/// An external agent asks before one of its own tools runs (ACP `session/request_permission`). Its tools run
/// on this Mac under its own rules; Reachly's tools, which it reaches over MCP, ask through Reachly's own
/// approval sheet instead.
public struct AgentPermissionRequest: Sendable, Identifiable, Equatable {
    public struct Option: Sendable, Equatable, Hashable, Identifiable {
        public enum Kind: String, Sendable, Equatable, Hashable {
            case allowOnce = "allow_once"
            case allowAlways = "allow_always"
            case rejectOnce = "reject_once"
            case rejectAlways = "reject_always"

            public var allows: Bool { self == .allowOnce || self == .allowAlways }
        }

        public var id: String
        public var name: String
        /// Nil for a kind this version does not know; shown, but never chosen by default.
        public var kind: Kind?

        public init(id: String, name: String, kind: Kind?) {
            self.id = id
            self.name = name
            self.kind = kind
        }
    }

    public let id: UUID
    /// Who is asking ("Qoder").
    public var agentName: String
    /// The tool call it wants to run, as the transcript shows it.
    public var toolCall: AgentToolActivity
    /// The agent's own options, in its order.
    public var options: [Option]

    public init(id: UUID = UUID(), agentName: String, toolCall: AgentToolActivity, options: [Option]) {
        self.id = id
        self.agentName = agentName
        self.toolCall = toolCall
        self.options = options
    }

    /// The option a dismissed or unanswered request takes: rejecting once, else rejecting always. Nil when the
    /// agent offered no way to reject, so the request is answered as cancelled instead.
    public var defaultRejectOption: Option? {
        options.first { $0.kind == .rejectOnce } ?? options.first { $0.kind == .rejectAlways }
    }
}

/// The user's answer to an `AgentPermissionRequest`.
public enum AgentPermissionDecision: Sendable, Equatable {
    /// One of the agent's options, by id.
    case selected(String)
    /// The sheet was closed without a choice: the request is rejected.
    case dismissed
    /// The turn was stopped while the request waited.
    case cancelled
}
