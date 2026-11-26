import Foundation
import SwiftData

/// Which audit entries the AI History sidebar shows.
public enum AgentAuditFilter: String, CaseIterable, Sendable, Identifiable {
    case all
    case ran
    /// Denied, blocked, cancelled or sent back with a comment.
    case notRun = "not-run"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: "All"
        case .ran: "Ran"
        case .notRun: "Not run"
        }
    }

    public func includes(_ decision: AgentAuditDecision) -> Bool {
        switch self {
        case .all: true
        case .ran: decision.ran
        case .notRun: !decision.ran
        }
    }

    /// Stored raw values of the decisions that ran. A raw value this build does
    /// not know counts as not run, as `AgentAuditEntry.decision` reads it as blocked.
    static let ranDecisionValues = AgentAuditDecision.allCases.filter(\.ran).map(\.rawValue)
}

/// The AI History search field.
public enum AgentAuditSearch {
    /// The text to look for, or nil when the field holds only whitespace.
    public static func normalized(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Whether the query appears in the command, the host's name or address, or
    /// the model's reason, ignoring case and accents. A blank query matches everything.
    public static func matches(_ query: String, command: String, hostName: String, hostTarget: String, reason: String) -> Bool {
        guard let query = normalized(query) else { return true }
        return command.localizedStandardContains(query)
            || hostName.localizedStandardContains(query)
            || hostTarget.localizedStandardContains(query)
            || reason.localizedStandardContains(query)
    }

    public static func matches(_ query: String, _ entry: AgentAuditEntry) -> Bool {
        matches(query, command: entry.command, hostName: entry.hostName, hostTarget: entry.hostTarget, reason: entry.reason)
    }
}

/// Entries from one calendar day, in the order they were given.
public struct AgentAuditDay<Item>: Identifiable {
    public enum Label: Hashable, Sendable {
        case today
        case yesterday
        /// Any other day, as the start of that day.
        case date(Date)
    }

    /// The start of the day in the calendar used for grouping.
    public var start: Date
    public var label: Label
    public var items: [Item]

    public var id: Date { start }
}

extension AgentAuditDay: Equatable where Item: Equatable {}
extension AgentAuditDay: Sendable where Item: Sendable {}

public enum AgentAuditHistory {
    /// Entries loaded at first, and added by each "Show More".
    public static let pageSize = 300

    /// Groups items into calendar days, keeping their order. Days come in the
    /// order their first item appears, so a newest-first list gives newest-first days.
    public static func groupedByDay<Item>(_ items: [Item], date: (Item) -> Date, calendar: Calendar, now: Date) -> [AgentAuditDay<Item>] {
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today).map { calendar.startOfDay(for: $0) }
        var days: [AgentAuditDay<Item>] = []
        var indexByStart: [Date: Int] = [:]
        for item in items {
            let start = calendar.startOfDay(for: date(item))
            if let index = indexByStart[start] {
                days[index].items.append(item)
                continue
            }
            let label: AgentAuditDay<Item>.Label = start == today ? .today : start == yesterday ? .yesterday : .date(start)
            indexByStart[start] = days.count
            days.append(AgentAuditDay(start: start, label: label, items: [item]))
        }
        return days
    }

    /// The newest entries that pass the filter and the search, newest first.
    /// It narrows in the store, so a search reaches entries older than the
    /// loaded page. It matches `AgentAuditFilter.includes` and `AgentAuditSearch.matches`.
    public static func fetchDescriptor(filter: AgentAuditFilter, search: String, limit: Int?) -> FetchDescriptor<AgentAuditEntry> {
        var descriptor = FetchDescriptor<AgentAuditEntry>(sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
        descriptor.fetchLimit = limit
        let ran = AgentAuditFilter.ranDecisionValues
        let query = AgentAuditSearch.normalized(search)
        switch (filter, query) {
        case (.all, nil):
            break
        case (.all, let query?):
            descriptor.predicate = #Predicate { entry in
                entry.command.localizedStandardContains(query)
                    || entry.hostName.localizedStandardContains(query)
                    || entry.hostTarget.localizedStandardContains(query)
                    || entry.reason.localizedStandardContains(query)
            }
        case (.ran, nil):
            descriptor.predicate = #Predicate { entry in ran.contains(entry.decisionRaw) }
        case (.notRun, nil):
            descriptor.predicate = #Predicate { entry in !ran.contains(entry.decisionRaw) }
        case (.ran, let query?):
            descriptor.predicate = #Predicate { entry in
                ran.contains(entry.decisionRaw)
                    && (entry.command.localizedStandardContains(query)
                        || entry.hostName.localizedStandardContains(query)
                        || entry.hostTarget.localizedStandardContains(query)
                        || entry.reason.localizedStandardContains(query))
            }
        case (.notRun, let query?):
            descriptor.predicate = #Predicate { entry in
                !ran.contains(entry.decisionRaw)
                    && (entry.command.localizedStandardContains(query)
                        || entry.hostName.localizedStandardContains(query)
                        || entry.hostTarget.localizedStandardContains(query)
                        || entry.reason.localizedStandardContains(query))
            }
        }
        return descriptor
    }

    /// "850 ms", "1.2 s", "2 min 5 s".
    public static func durationText(milliseconds: Int) -> String {
        let milliseconds = max(0, milliseconds)
        if milliseconds < 1000 { return "\(milliseconds) ms" }
        let tenths = (milliseconds + 50) / 100
        if tenths < 600 {
            return tenths % 10 == 0 ? "\(tenths / 10) s" : "\(tenths / 10).\(tenths % 10) s"
        }
        let seconds = (milliseconds + 500) / 1000
        return seconds % 60 == 0 ? "\(seconds / 60) min" : "\(seconds / 60) min \(seconds % 60) s"
    }
}

/// An audit entry's decision detail split for display: why the guardrails
/// decided, and for a change request the user's suggested command and comment.
public struct AgentAuditDetail: Equatable, Sendable {
    public var guardrail: String
    public var suggestion: String?
    public var comment: String?

    public init(guardrail: String, suggestion: String? = nil, comment: String? = nil) {
        self.guardrail = guardrail
        self.suggestion = suggestion
        self.comment = comment
    }

    /// Reads `AgentAuditDecision.changesRequestedDetail` back into its parts.
    /// Any other decision's detail is all guardrail.
    public init(decision: AgentAuditDecision, detail: String) {
        guard decision == .changesRequested else {
            self.init(guardrail: detail.trimmingCharacters(in: .whitespacesAndNewlines))
            return
        }
        let comment = AgentAuditDecision.changesRequestedComment(in: detail)
        let (guardrail, suggestion) = AgentAuditDecision.changesRequestedHead(in: detail)
        self.init(
            guardrail: guardrail.trimmingCharacters(in: .whitespacesAndNewlines),
            suggestion: suggestion.flatMap { $0.isEmpty ? nil : $0 },
            comment: comment)
    }
}

extension AgentAuditEntry {
    /// The decision detail split into guardrail, suggestion and comment.
    public var detailParts: AgentAuditDetail { AgentAuditDetail(decision: decision, detail: decisionDetail) }
}

extension AgentActionSource {
    /// Where a command came from, for lists.
    public var displayName: String {
        switch self {
        case .agentPanel: "Chat panel"
        case .mcp: "MCP client"
        }
    }
}
