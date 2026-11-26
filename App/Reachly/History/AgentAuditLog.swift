import AppKit
import SwiftData
import SwiftUI
import ReachlyCore

/// Actions on the whole agent audit log, shared by the AI History sidebar and
/// Settings › AI Integration.
@MainActor
enum AgentAuditLog {
    /// Asks where to save, then writes every entry, newest first, as JSON.
    /// Returns the number written, or nil when the save panel was cancelled.
    static func exportJSON(from context: ModelContext) throws -> Int? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Reachly-agent-audit-\(Date.now.formatted(.iso8601.year().month().day())).json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let entries = try context.fetch(FetchDescriptor<AgentAuditEntry>(sortBy: [SortDescriptor(\.timestamp, order: .reverse)]))
        let data = try AgentAuditRecord.exportJSON(entries.map(AgentAuditRecord.init))
        try data.write(to: url, options: [.atomic])
        return entries.count
    }

    /// The same, for places with nowhere to show a message: a failure goes to an alert.
    static func exportJSONReportingErrors(from context: ModelContext) {
        do {
            _ = try exportJSON(from: context)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// What to tell the user after an export.
    static func exportMessage(count: Int) -> String {
        count == 1 ? "Exported 1 entry." : "Exported \(count) entries."
    }

    static func clear(in context: ModelContext) {
        let entries = (try? context.fetch(FetchDescriptor<AgentAuditEntry>())) ?? []
        for entry in entries { context.delete(entry) }
        try? context.save()
    }
}

extension AgentAuditDecision {
    var symbolName: String {
        switch self {
        case .autoAllowed: "checkmark.circle"
        case .approved: "hand.thumbsup"
        case .edited: "pencil.circle"
        case .denied: "hand.raised"
        case .blocked: "nosign"
        case .cancelled: "stop.circle"
        case .changesRequested: "text.bubble"
        }
    }

    var tint: Color {
        switch self {
        case .autoAllowed, .approved, .edited: .green
        case .denied, .blocked: .red
        case .cancelled: .orange
        case .changesRequested: .blue
        }
    }
}
