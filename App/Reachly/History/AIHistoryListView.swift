import AppKit
import SwiftData
import SwiftUI
import ReachlyAgent
import ReachlyCore
import ReachlyTerminal

/// Sidebar list of the commands the AI assistant ran or proposed, from the chat
/// panel and from MCP clients, newest first and grouped by day. It reads the
/// agent audit log, so entries cannot be deleted one at a time.
struct AIHistoryListView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @State private var search = ""
    @State private var filter = AgentAuditFilter.all
    @State private var limit = AgentAuditHistory.pageSize

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter AI history", text: $search)
                    .textFieldStyle(.plain)
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            Picker("Show", selection: $filter) {
                ForEach(AgentAuditFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .padding(.horizontal, 10)
            .padding(.bottom, 7)
            Divider()
            AIHistoryResultsView(search: AgentAuditSearch.normalized(search), filter: filter, limit: limit) {
                limit += AgentAuditHistory.pageSize
            }
        }
        .navigationTitle("AI History")
        .onChange(of: search) { _, _ in limit = AgentAuditHistory.pageSize }
        .onChange(of: filter) { _, _ in limit = AgentAuditHistory.pageSize }
        .confirmationDialog("Clear the AI history?", isPresented: Bindable(appState).isConfirmingClearAIHistory, titleVisibility: .visible) {
            Button("Clear AI History", role: .destructive) { AgentAuditLog.clear(in: modelContext) }
        } message: {
            Text("Every command the AI assistant ran or proposed, on every host, is removed from the audit log. Conversations are kept.")
        }
    }
}

private struct AIHistoryResultsView: View {
    let search: String?
    let filter: AgentAuditFilter
    let limit: Int
    let showMore: () -> Void
    @Environment(AppState.self) private var appState
    @Environment(Workspace.self) private var workspace
    @Environment(AgentPanelController.self) private var agent
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openSettings) private var openSettings
    /// One more than the page, so the list knows whether there is more to show.
    @Query private var entries: [AgentAuditEntry]
    @Query private var hosts: [SSHHost]
    @Query private var conversations: [AgentConversation]
    @State private var selection: UUID?
    @State private var pendingRun: PendingRun?

    /// A destructive command waiting for the user to confirm running it again.
    struct PendingRun: Identifiable {
        let id = UUID()
        let command: String
        let target: SnippetTarget
        let targetName: String
        let pattern: String
    }

    init(search: String?, filter: AgentAuditFilter, limit: Int, showMore: @escaping () -> Void) {
        self.search = search
        self.filter = filter
        self.limit = limit
        self.showMore = showMore
        _entries = Query(AgentAuditHistory.fetchDescriptor(filter: filter, search: search ?? "", limit: limit + 1))
        // Titles only: transcripts stay on disk.
        var saved = FetchDescriptor<AgentConversation>()
        saved.propertiesToFetch = [\.uuid, \.title]
        _conversations = Query(saved)
    }

    var body: some View {
        let shown = Array(entries.prefix(limit))
        let days = AgentAuditHistory.groupedByDay(shown, date: \.timestamp, calendar: .current, now: .now)
        let titles = Dictionary(conversations.map { ($0.uuid, $0.title) }, uniquingKeysWith: { first, _ in first })
        List(selection: $selection) {
            ForEach(days) { day in
                Section(title(of: day.label)) {
                    ForEach(day.items) { entry in
                        AIHistoryRow(
                            entry: entry,
                            isExpanded: selection == entry.uuid,
                            conversationTitle: entry.conversationID.flatMap { titles[$0] },
                            openConversation: { openConversation(entry) })
                            .tag(entry.uuid)
                            .contextMenu { menu(for: entry, conversationExists: entry.conversationID.map { titles[$0] != nil } ?? false) }
                    }
                }
            }
            if entries.count > limit {
                Button("Show More", action: showMore)
                    .buttonStyle(.link)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .selectionDisabled()
            }
        }
        .listStyle(.sidebar)
        .themedList()
        .onKeyPress(.return, phases: .down) { press in
            guard press.modifiers.contains(.command), let entry = selectedEntry, Self.canRunAgain(entry) else { return .ignored }
            requestRun(entry, on: .currentTab)
            return .handled
        }
        .onCopyCommand {
            guard let entry = selectedEntry else { return [] }
            return [NSItemProvider(object: entry.command as NSString)]
        }
        .overlay {
            if entries.isEmpty { emptyState }
        }
        .confirmationDialog(
            "Run a destructive command again?",
            isPresented: Binding(get: { pendingRun != nil }, set: { if !$0 { pendingRun = nil } }),
            titleVisibility: .visible,
            presenting: pendingRun
        ) { run in
            Button(run.target == .currentTab ? "Run in Current Tab" : "Run on \(run.targetName)", role: .destructive) {
                SnippetRunner.run(run.command, on: run.target, workspace: workspace, context: modelContext)
            }
            Button("Cancel", role: .cancel) {}
        } message: { run in
            Text("\(run.command)\n\nThis matches a destructive pattern (\(run.pattern)). It runs as typed, without the approval sheet.")
        }
    }

    private var selectedEntry: AgentAuditEntry? {
        entries.prefix(limit).first { $0.uuid == selection }
    }

    private func title(of label: AgentAuditDay<AgentAuditEntry>.Label) -> String {
        switch label {
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .date(let date):
            let sameYear = Calendar.current.isDate(date, equalTo: .now, toGranularity: .year)
            return sameYear
                ? date.formatted(.dateTime.weekday(.wide).day().month(.wide))
                : date.formatted(.dateTime.day().month(.wide).year())
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        let total = (try? modelContext.fetchCount(FetchDescriptor<AgentAuditEntry>())) ?? 0
        if total == 0 {
            ContentUnavailableView {
                Label("No AI History Yet", systemImage: "wand.and.sparkles")
            } description: {
                Text("Commands the AI assistant runs or proposes appear here, from the chat panel and from MCP clients, with what happened to each one.")
            } actions: {
                Button("AI Integration Settings…") { SettingsNavigation.shared.show(SettingsNavigation.aiIntegration, using: openSettings) }
            }
        } else if let search {
            ContentUnavailableView {
                Label("No Results for “\(search)”", systemImage: "magnifyingglass")
            } description: {
                Text(filter == .all
                    ? "Search looks in commands, host names and the assistant's reasons."
                    : "Search looks only at commands shown by the \(filter.title) filter. Choose All to search every command.")
            }
        } else {
            ContentUnavailableView {
                Label(filter == .ran ? "Nothing Ran" : "Everything Ran", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text(filter == .ran
                    ? "Every command in the AI history was denied, blocked, cancelled or sent back. Choose All to see them."
                    : "Every command in the AI history ran. Choose All to see them.")
            }
        }
    }

    @ViewBuilder
    private func menu(for entry: AgentAuditEntry, conversationExists: Bool) -> some View {
        if Self.canRunAgain(entry) {
            Button("Run Again in Current Tab") { requestRun(entry, on: .currentTab) }
                .disabled(workspace.focusedSession?.isConnected != true)
            if let hostID = entry.hostID, let host = hosts.first(where: { $0.uuid == hostID }) {
                Button("Run Again on \(host.name)") { requestRun(entry, on: .host(hostID)) }
            }
            Divider()
        }
        Button("Copy Command") { copy(entry.command) }
        if !entry.outputExcerpt.isEmpty {
            Button("Copy Output") { copy(entry.outputExcerpt) }
        }
        if Self.canRunAgain(entry) {
            Button("Save as Snippet…") { appState.snippetEditor = .create(folder: nil, command: entry.command) }
        }
        if conversationExists {
            Divider()
            Button("Open Conversation") { openConversation(entry) }
        }
    }

    /// Only shell commands go back to a terminal; file writes and transfers are
    /// recorded as a description of what the tool did.
    static func canRunAgain(_ entry: AgentAuditEntry) -> Bool {
        entry.tool == AgentToolName.runCommand.rawValue
    }

    /// Runs the command again, asking first when it matches a destructive pattern.
    private func requestRun(_ entry: AgentAuditEntry, on target: SnippetTarget) {
        if target == .currentTab, workspace.focusedSession?.isConnected != true {
            NSSound.beep()
        } else if let pattern = CommandGuard.destructiveMatch(entry.command) {
            pendingRun = PendingRun(command: entry.command, target: target, targetName: target.title(in: modelContext), pattern: pattern)
        } else {
            SnippetRunner.run(entry.command, on: target, workspace: workspace, context: modelContext)
        }
    }

    private func openConversation(_ entry: AgentAuditEntry) {
        guard let id = entry.conversationID, agent.open(conversationID: id) else {
            NSSound.beep()
            return
        }
        appState.isShowingAgentPanel = true
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// One command: decision, command, host, time and source; the details when selected.
struct AIHistoryRow: View {
    let entry: AgentAuditEntry
    let isExpanded: Bool
    let conversationTitle: String?
    let openConversation: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: entry.decision.symbolName)
                .foregroundStyle(entry.decision.tint)
                .font(.body)
                .frame(width: 20)
                .padding(.top, 2)
                .help(entry.decision.displayName)
                .accessibilityLabel(entry.decision.displayName)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(entry.command)
                        .font(.body.monospaced())
                        .lineLimit(isExpanded ? nil : 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let status = entry.exitStatus, status != 0 {
                        Text(String(status))
                            .font(.caption.monospacedDigit().bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 3)
                            .background(Color.red, in: RoundedRectangle(cornerRadius: 3))
                            .help("Exit status \(status)")
                    }
                }
                HStack(spacing: 4) {
                    Text(entry.hostName)
                    Text("·")
                    Text(entry.timestamp, format: .dateTime.hour().minute())
                    Text("·")
                    Text(entry.source.displayName)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                if isExpanded {
                    AIHistoryDetails(entry: entry, conversationTitle: conversationTitle, openConversation: openConversation)
                        .padding(.top, 4)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// What the model asked for and why, what the user and the guardrails decided, and what came back.
private struct AIHistoryDetails: View {
    let entry: AgentAuditEntry
    let conversationTitle: String?
    let openConversation: () -> Void

    var body: some View {
        let parts = entry.detailParts
        VStack(alignment: .leading, spacing: 6) {
            Text(summary)
                .font(.callout)
                .foregroundStyle(.secondary)
            if !entry.reason.isEmpty {
                field("Reason") { Text(entry.reason) }
            }
            if let proposed = entry.proposedCommand {
                field("Proposed") { Text(proposed).font(.callout.monospaced()) }
            }
            if let suggestion = parts.suggestion {
                field("Your suggestion") { Text(suggestion).font(.callout.monospaced()) }
            }
            if let comment = parts.comment {
                field("Your comment") { Text(comment) }
            }
            if !parts.guardrail.isEmpty {
                field("Guardrail") { Text(parts.guardrail) }
            }
            if !entry.outputExcerpt.isEmpty {
                field("Output") {
                    Text(entry.outputExcerpt)
                        .font(.caption.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                        // A hierarchical fill, so the text stays readable on the selected row's highlight.
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                }
            }
            if let conversationTitle {
                field("Conversation") { Text(conversationTitle) }
                // Bordered, so it stays visible on the selected row's highlight.
                Button("Open Conversation", action: openConversation)
                    .controlSize(.small)
            }
        }
    }

    /// The decision, exit status, duration, full time, tool (when not run_command) and address on one line.
    private var summary: String {
        var parts = [entry.decision.displayName]
        if let status = entry.exitStatus { parts.append("exit \(status)") }
        if let milliseconds = entry.durationMilliseconds { parts.append(AgentAuditHistory.durationText(milliseconds: milliseconds)) }
        parts.append(entry.timestamp.formatted(date: .abbreviated, time: .standard))
        if entry.tool != AgentToolName.runCommand.rawValue { parts.append(entry.tool) }
        if entry.hostTarget != entry.hostName { parts.append(entry.hostTarget) }
        return parts.joined(separator: " · ")
    }

    private func field(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            content()
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
