import Foundation
import ReachlyCore

/// A saved host as the tools see it.
public struct AgentHostInfo: Sendable, Hashable, Identifiable, Codable {
    public var id: UUID
    public var name: String
    public var hostname: String
    public var port: Int
    public var username: String
    public var group: String?
    public var tags: [String]
    public var permission: AgentPermissionMode
    public var allowlist: [String]
    public var isConnected: Bool

    public init(id: UUID, name: String, hostname: String, port: Int = 22, username: String, group: String? = nil, tags: [String] = [], permission: AgentPermissionMode = .ask, allowlist: [String] = [], isConnected: Bool = false) {
        self.id = id
        self.name = name
        self.hostname = hostname
        self.port = port
        self.username = username
        self.group = group
        self.tags = tags
        self.permission = permission
        self.allowlist = allowlist
        self.isConnected = isConnected
    }

    public var target: String {
        port == 22 ? "\(username)@\(hostname)" : "\(username)@\(hostname):\(port)"
    }
}

/// Which way `sftp_transfer` copies.
public enum AgentTransferDirection: String, Codable, Sendable {
    case upload, download
}

/// Shown to the user before a command runs.
public struct AgentApprovalRequest: Sendable, Identifiable {
    public let id: UUID
    public var source: AgentActionSource
    public var host: AgentHostInfo
    public var tool: String
    /// The shell command about to run (editable in the sheet).
    public var command: String
    /// The model's one-line reason.
    public var reason: String
    /// Why the guardrails are asking (destructive pattern, mode).
    public var detail: String
    public var isDestructive: Bool

    public init(id: UUID = UUID(), source: AgentActionSource, host: AgentHostInfo, tool: String, command: String, reason: String, detail: String, isDestructive: Bool) {
        self.id = id
        self.source = source
        self.host = host
        self.tool = tool
        self.command = command
        self.reason = reason
        self.detail = detail
        self.isDestructive = isDestructive
    }

    /// Whether the user can edit `command`. Only run_command's text is the
    /// tool's real input. The other tools show a stand-in line (`cat > path  #
    /// upload 12 bytes from …`): editing it would not change what runs, and
    /// passing it back could lead the model to run it as a command. So for them
    /// the sheet shows it read-only, offers no Run Edited Command, sends a
    /// comment alone, and the runner refuses an `.edited` answer.
    public var isCommandEditable: Bool { tool == AgentToolName.runCommand.rawValue }
}

public enum AgentApprovalResponse: Sendable, Equatable {
    case approved
    /// The user changed the command; the new text runs instead. Only for
    /// requests whose command is editable (`isCommandEditable`).
    case edited(String)
    /// The user wants changes before anything runs. Nothing runs: the model
    /// gets the comment (and the edited command as a suggestion, when there is
    /// one) and can call the tool again with a revised command.
    case requestChanges(comment: String, editedCommand: String?)
    case denied

    /// The longest comment the approval sheet sends, in characters.
    public static let commentLimit = 2_000

    /// The comment as it is sent: trimmed and clipped to `commentLimit`.
    /// Nil when nothing is left, so an empty comment can't be sent.
    public static func normalizedComment(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(commentLimit)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The sheet's Send answer for a comment and the command as it stands in
    /// the editor. The edit is kept only when `includingEdit` (see
    /// `AgentApprovalRequest.isCommandEditable`) and it differs from the
    /// proposal by more than surrounding whitespace. Nil when the comment is empty.
    public static func changeRequest(comment: String, command: String, proposed: String, includingEdit: Bool = true) -> AgentApprovalResponse? {
        guard let comment = normalizedComment(comment) else { return nil }
        return .requestChanges(comment: comment, editedCommand: includingEdit ? suggestion(command, proposed: proposed) : nil)
    }

    /// The edited command this answer passes back to the model, if any.
    public var suggestedCommand: String? {
        if case .requestChanges(_, let edited) = self { return edited }
        return nil
    }

    /// The edited command worth passing back, or nil when it is empty or unchanged.
    static func suggestion(_ edited: String?, proposed: String) -> String? {
        guard let trimmed = edited?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty,
              trimmed != proposed.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return trimmed
    }
}

/// What a command produced.
public struct AgentCommandOutput: Sendable, Equatable {
    public var stdout: Data
    public var stderr: Data
    public var exitStatus: Int?
    public var signal: String?
    public var duration: Duration

    public init(stdout: Data, stderr: Data, exitStatus: Int?, signal: String? = nil, duration: Duration) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitStatus = exitStatus
        self.signal = signal
        self.duration = duration
    }

    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}

/// How much of a tool's command the agent log shows.
public enum AgentEchoMode: Sendable {
    /// The command and its output.
    case full
    /// The command and the exit status only (file contents stay out of the log).
    case commandOnly
}

/// What the app provides to the tools: the saved hosts, a way to run commands
/// on them, the approval sheet and the audit log.
@MainActor
public protocol AgentToolHost: AnyObject {
    func hosts() -> [AgentHostInfo]

    /// Asks the user. Implementations resume with `.denied` when the task is cancelled.
    func approve(_ request: AgentApprovalRequest) async -> AgentApprovalResponse

    /// Runs a command over an exec channel on the host, opening a connection
    /// (and the agent's log tab) when needed. `stdin` is written and closed.
    func execute(on host: AgentHostInfo, command: String, stdin: Data, timeout: Duration, echo: AgentEchoMode, source: AgentActionSource) async throws -> AgentCommandOutput

    /// The user's interactive terminal buffer on the host, newest lines last; nil when none is open.
    func terminalBuffer(on host: AgentHostInfo, maxLines: Int) -> String?

    func audit(_ record: AgentAuditRecord)
}
