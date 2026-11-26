import AppKit
import SwiftUI
import ReachlyAgent

/// Settings › AI Integration › Found on this Mac: the detected providers, Check Again, and the setup sheet.
struct AIProvidersFoundSection: View {
    @Environment(MCPServerController.self) private var mcp
    @State private var detector = ProviderDetector.shared
    @State private var isShowingSetup = false

    var body: some View {
        Section {
            AIProviderRowsList()
            HStack(spacing: 8) {
                Text("Nothing is copied or changed until you click a button.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if detector.isChecking { ProgressView().controlSize(.small) }
                Button("Check Again") { Task { await detector.refresh() } }
                    .disabled(detector.isChecking)
                Button("Set Up AI Integration…") { isShowingSetup = true }
            }
            .task { await detector.refreshIfStale() }
            .sheet(isPresented: $isShowingSetup) {
                AIIntegrationSetupView(origin: .settings)
                    .environment(mcp)
                    .themedSheet()
            }
        } header: {
            Text("Found on this Mac")
        }
    }
}

/// The providers found on this Mac, each with its buttons. Shared by the Settings section and the setup sheet.
struct AIProviderRowsList: View {
    @Environment(MCPServerController.self) private var mcp
    @State private var detector = ProviderDetector.shared

    var body: some View {
        let reachly = detector.reachlyState(mcp: mcp)
        if let machine = detector.machine {
            let rows = AIProviderCatalogue.rows(machine: machine, reachly: reachly)
            if rows.isEmpty {
                Text("No AI tools were found on this Mac. The list below shows what can be set up.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(rows) { row in
                AIProviderRowView(row: row, machine: machine, reachly: reachly)
            }
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Looking for AI tools on this Mac…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// One detected provider: what was found, why something can't be used, its buttons and the last result.
struct AIProviderRowView: View {
    let row: AIProviderRow
    let machine: AIProviderMachineFacts
    let reachly: ReachlyAIState
    @Environment(MCPServerController.self) private var mcp
    @Environment(\.openURL) private var openURL
    @State private var detector = ProviderDetector.shared
    @State private var pending: PendingAction?

    /// A confirmation on screen: the action, what it says, and the models a local server offers.
    struct PendingAction: Identifiable {
        let id = UUID()
        let action: AIProviderAction
        let prompt: AIProviderPrompt
        let models: [String]
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 18)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(row.title).fontWeight(.medium)
                    if let badge {
                        Text(badge)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.green.opacity(0.15), in: Capsule())
                    }
                }
                Text(row.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let note = row.note {
                    Text(Self.codeSpans(note))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let quoted = row.quoted {
                    // Read from another app's file: shown exactly as written, never as Markdown or a link.
                    Text(verbatim: quoted)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                let links = row.actions.filter(\.isLink)
                if !links.isEmpty {
                    HStack(spacing: 12) {
                        ForEach(links, id: \.self) { action in
                            Button(action.title) { start(action) }
                                .buttonStyle(.link)
                        }
                    }
                    .font(.caption)
                }
                if let result = detector.results[row.id] {
                    Label(result.message, systemImage: result.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(result.isError ? Color.orange : Color.green)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            if detector.runningAction == row.id {
                ProgressView().controlSize(.small)
            }
            VStack(alignment: .trailing, spacing: 6) {
                ForEach(row.actions.filter { !$0.isLink }, id: \.self) { action in
                    Button(action.title) { start(action) }
                        .disabled(detector.runningAction != nil)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .sheet(item: $pending) { pending in
            AIProviderActionSheet(
                prompt: pending.prompt,
                models: pending.models,
                initialModel: reachly.model
            ) { model in
                Task { await detector.perform(pending.action, prompt: pending.prompt, row: row.id, model: model, mcp: mcp) }
            }
            .themedSheet()
        }
    }

    private func start(_ action: AIProviderAction) {
        if case .openLink(let link) = action {
            openURL(link.url)
            return
        }
        guard let prompt = AIProviderCatalogue.prompt(for: action, machine: machine, reachly: reachly, home: detector.home.path) else {
            // A copy changes nothing, so it needs no confirmation.
            Task { await detector.perform(action, prompt: nil, row: row.id, model: nil, mcp: mcp) }
            return
        }
        pending = PendingAction(action: action, prompt: prompt, models: models(for: action))
    }

    private func models(for action: AIProviderAction) -> [String] {
        guard case .useLocalServer(let server) = action, case .running(let models) = machine.server(server).state else { return [] }
        return OpenAIModelList.chatModels(models)
    }

    private var symbol: String {
        switch row.status {
        case .inUse: "checkmark.circle.fill"
        case .connected: "link.circle.fill"
        case .ready: "plus.circle"
        case .needsAction: "exclamationmark.circle"
        case .unavailable: "minus.circle"
        }
    }

    private var tint: Color {
        switch row.status {
        case .inUse, .connected: .green
        case .ready: .accentColor
        case .needsAction: .orange
        case .unavailable: .secondary
        }
    }

    private var badge: String? {
        switch row.status {
        case .inUse: "In use"
        case .connected: "Connected"
        default: nil
        }
    }

    /// Notes mark commands with backticks; those show as code and everything else exactly as written. No other
    /// syntax is read, so no text can turn into a link.
    static func codeSpans(_ text: String) -> AttributedString {
        var result = AttributedString()
        for (index, part) in text.split(separator: "`", omittingEmptySubsequences: false).enumerated() {
            var piece = AttributedString(String(part))
            if !index.isMultiple(of: 2) { piece.font = .caption.monospaced() }
            result += piece
        }
        return result
    }
}

/// What an action will do, said before it runs, with Cancel and the confirming button. For a local server it
/// also holds the model picker; for the Qoder app it lists the steps and copies the bridge path.
struct AIProviderActionSheet: View {
    let prompt: AIProviderPrompt
    let models: [String]
    let onConfirm: (String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var model: String
    @State private var copied = false

    init(prompt: AIProviderPrompt, models: [String], initialModel: String, onConfirm: @escaping (String?) -> Void) {
        self.prompt = prompt
        self.models = models
        self.onConfirm = onConfirm
        _model = State(initialValue: models.contains(initialModel) ? initialModel : (models.first ?? ""))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(prompt.title)
                .font(.title3.weight(.semibold))
            Text(prompt.message)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !prompt.steps.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(prompt.steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("\(index + 1).").monospacedDigit().foregroundStyle(.secondary)
                            Text(step).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            if let detail = prompt.detail {
                HStack(alignment: .top, spacing: 8) {
                    Text(detail)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(detail, forType: .string)
                        copied = true
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy")
                }
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            }
            if models.count > 1 {
                Picker("Model", selection: $model) {
                    ForEach(models, id: \.self) { Text($0).tag($0) }
                }
            } else if let only = models.first {
                LabeledContent("Model") {
                    Text(only).font(.body.monospaced())
                }
            }
            HStack {
                Spacer()
                if let confirmTitle = prompt.confirmTitle {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button(confirmTitle) {
                        onConfirm(models.isEmpty ? nil : model)
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 500)
    }
}
