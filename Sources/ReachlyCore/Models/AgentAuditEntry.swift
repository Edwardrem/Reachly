import Foundation
import SwiftData

/// Who asked for an agent action.
public enum AgentActionSource: String, Codable, Sendable, CaseIterable {
    case agentPanel = "agent"
    case mcp
}

/// What the guardrails decided about an agent action.
///
/// Stored by raw value (`AgentAuditEntry.decisionRaw`) and exported as JSON:
/// add cases, never rename or remove one.
public enum AgentAuditDecision: String, Codable, Sendable, CaseIterable {
    /// Allowed by the host's mode without asking (read-only list or allowlist match).
    case autoAllowed = "auto-allowed"
    case approved
    /// The user changed the command in the approval sheet before running it.
    case edited
    case denied
    /// Refused by read-only mode or another rule; the user was not asked.
    case blocked
    case cancelled
    /// The user sent a comment back from the approval sheet instead of running
    /// the command. The comment is in the entry's decision detail.
    case changesRequested = "changes-requested"

    public var displayName: String {
        switch self {
        case .autoAllowed: "Auto-allowed"
        case .approved: "Approved"
        case .edited: "Edited"
        case .denied: "Denied"
        case .blocked: "Blocked"
        case .cancelled: "Cancelled"
        case .changesRequested: "Changes requested"
        }
    }

    public var ran: Bool {
        switch self {
        case .autoAllowed, .approved, .edited: true
        case .denied, .blocked, .cancelled, .changesRequested: false
        }
    }

    /// The labels inside a `changesRequestedDetail`, read back by `AgentAuditDetail`.
    static let commentMarker = "Comment: "
    static let suggestionMarker = "Suggested command: "

    /// The decision detail for `.changesRequested`: the guardrail reason, the
    /// suggested command when there is one, and the comment last (as typed, to
    /// the end). Every line before the comment that does not start a field is
    /// indented by two spaces, so the only line that starts with `Comment: ` is
    /// the comment's own, even when a suggested heredoc contains one.
    public static func changesRequestedDetail(guardrail: String, comment: String, suggestion: String?) -> String {
        var fields: [String] = []
        if !guardrail.isEmpty { fields.append(guardrail) }
        if let suggestion { fields.append(suggestionMarker + suggestion) }
        var lines = fields.flatMap { field in
            splitLines(field).enumerated().map { index, line in
                index == 0 && !startsWithMarker(line) ? line : "  " + line
            }
        }
        lines.append(commentMarker + comment)
        return lines.joined(separator: "\n")
    }

    /// The comment inside a `changesRequestedDetail`, or nil when there is none.
    public static func changesRequestedComment(in detail: String) -> String? {
        let lines = splitLines(detail)
        guard let index = lines.firstIndex(where: startsWithMarker) else { return nil }
        let first = String(lines[index].unicodeScalars.dropFirst(commentMarker.unicodeScalars.count))
        let comment = ([first] + lines[(index + 1)...]).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return comment.isEmpty ? nil : comment
    }

    /// The guardrail reason and suggested command inside a `changesRequestedDetail`,
    /// with the two-space indent of their continuation lines removed: the inverse
    /// of what `changesRequestedDetail` writes before the comment.
    static func changesRequestedHead(in detail: String) -> (guardrail: String, suggestion: String?) {
        let lines = splitLines(detail)
        let head = lines[..<(lines.firstIndex(where: startsWithMarker) ?? lines.endIndex)]
        var fields: [[String]] = []
        for line in head {
            if line.hasPrefix("  "), !fields.isEmpty {
                fields[fields.count - 1].append(String(line.dropFirst(2)))
            } else {
                // A field's first line; one that began with the comment marker was indented too.
                fields.append([line.hasPrefix("  ") ? String(line.dropFirst(2)) : line])
            }
        }
        var guardrail: [String] = []
        var suggestion: String?
        for field in fields {
            let text = field.joined(separator: "\n")
            if suggestion == nil, text.hasPrefix(suggestionMarker) {
                suggestion = String(text.dropFirst(suggestionMarker.count))
            } else {
                guardrail.append(text)
            }
        }
        return (guardrail.joined(separator: "\n"), suggestion)
    }

    /// Split at every "\n" code unit, CRLF included, so a split and a join round-trip.
    private static func splitLines(_ text: String) -> [String] {
        text.components(separatedBy: "\n")
    }

    private static func startsWithMarker(_ line: String) -> Bool {
        line.unicodeScalars.starts(with: commentMarker.unicodeScalars)
    }
}

/// One line of the agent audit log: every command or file change the agent
/// asked for, where, when, what was decided and how it ended.
@Model
public final class AgentAuditEntry {
    @Attribute(.unique) public var uuid: UUID
    public var timestamp: Date
    public var sourceRaw: String
    public var hostID: UUID?
    public var hostName: String
    public var hostTarget: String
    /// Tool name: run_command, write_file, sftp_transfer, …
    public var tool: String
    /// The command (or action) as it ran, after any edit.
    public var command: String
    /// The command as the model proposed it, when the user edited it.
    public var proposedCommand: String?
    public var reason: String
    public var decisionRaw: String
    /// Why the guardrails decided what they did (e.g. the destructive pattern matched).
    public var decisionDetail: String
    public var exitStatus: Int?
    public var durationMilliseconds: Int?
    public var outputExcerpt: String
    public var conversationID: UUID?

    public init(
        uuid: UUID = UUID(),
        timestamp: Date = .now,
        source: AgentActionSource,
        hostID: UUID?,
        hostName: String,
        hostTarget: String,
        tool: String,
        command: String,
        proposedCommand: String? = nil,
        reason: String,
        decision: AgentAuditDecision,
        decisionDetail: String = "",
        exitStatus: Int? = nil,
        durationMilliseconds: Int? = nil,
        outputExcerpt: String = "",
        conversationID: UUID? = nil
    ) {
        self.uuid = uuid
        self.timestamp = timestamp
        self.sourceRaw = source.rawValue
        self.hostID = hostID
        self.hostName = hostName
        self.hostTarget = hostTarget
        self.tool = tool
        self.command = command
        self.proposedCommand = proposedCommand
        self.reason = reason
        self.decisionRaw = decision.rawValue
        self.decisionDetail = decisionDetail
        self.exitStatus = exitStatus
        self.durationMilliseconds = durationMilliseconds
        self.outputExcerpt = outputExcerpt
        self.conversationID = conversationID
    }

    public var source: AgentActionSource {
        get { AgentActionSource(rawValue: sourceRaw) ?? .agentPanel }
        set { sourceRaw = newValue.rawValue }
    }

    public var decision: AgentAuditDecision {
        get { AgentAuditDecision(rawValue: decisionRaw) ?? .blocked }
        set { decisionRaw = newValue.rawValue }
    }

    /// What the user wrote when they asked for changes; nil for every other decision.
    public var changesRequestedComment: String? {
        decision == .changesRequested ? AgentAuditDecision.changesRequestedComment(in: decisionDetail) : nil
    }
}

/// The exportable form of an audit entry.
public struct AgentAuditRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var timestamp: Date
    public var source: AgentActionSource
    public var hostID: UUID?
    public var hostName: String
    public var hostTarget: String
    public var tool: String
    public var command: String
    public var proposedCommand: String?
    public var reason: String
    public var decision: AgentAuditDecision
    public var decisionDetail: String
    public var exitStatus: Int?
    public var durationMilliseconds: Int?
    public var outputExcerpt: String
    public var conversationID: UUID?

    public init(
        id: UUID = UUID(),
        timestamp: Date = .now,
        source: AgentActionSource,
        hostID: UUID?,
        hostName: String,
        hostTarget: String,
        tool: String,
        command: String,
        proposedCommand: String? = nil,
        reason: String,
        decision: AgentAuditDecision,
        decisionDetail: String = "",
        exitStatus: Int? = nil,
        durationMilliseconds: Int? = nil,
        outputExcerpt: String = "",
        conversationID: UUID? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.source = source
        self.hostID = hostID
        self.hostName = hostName
        self.hostTarget = hostTarget
        self.tool = tool
        self.command = command
        self.proposedCommand = proposedCommand
        self.reason = reason
        self.decision = decision
        self.decisionDetail = decisionDetail
        self.exitStatus = exitStatus
        self.durationMilliseconds = durationMilliseconds
        self.outputExcerpt = outputExcerpt
        self.conversationID = conversationID
    }

    @MainActor
    public init(_ entry: AgentAuditEntry) {
        self.init(
            id: entry.uuid, timestamp: entry.timestamp, source: entry.source, hostID: entry.hostID,
            hostName: entry.hostName, hostTarget: entry.hostTarget, tool: entry.tool, command: entry.command,
            proposedCommand: entry.proposedCommand, reason: entry.reason, decision: entry.decision,
            decisionDetail: entry.decisionDetail, exitStatus: entry.exitStatus,
            durationMilliseconds: entry.durationMilliseconds, outputExcerpt: entry.outputExcerpt,
            conversationID: entry.conversationID)
    }

    /// Pretty JSON with ISO 8601 dates, newest first as given.
    public static func exportJSON(_ records: [AgentAuditRecord]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(records)
    }
}
