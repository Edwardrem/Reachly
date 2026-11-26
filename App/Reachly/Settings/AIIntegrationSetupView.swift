import SwiftUI
import ReachlyAgent

/// The AI Integration setup sheet: what was found on this Mac, each with its one-click button, and what can
/// be set up. Shown once on the first launch where no provider is usable, and from Settings › AI Integration.
struct AIIntegrationSetupView: View {
    enum Origin {
        /// Over the main window at launch; "Open AI Integration" opens the Settings window.
        case launch
        /// Over Settings › AI Integration; "Open AI Integration" just closes the sheet.
        case settings
    }

    let origin: Origin
    @Environment(MCPServerController.self) private var mcp
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openURL) private var openURL
    @State private var detector = ProviderDetector.shared
    @State private var settings = AgentSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Label("Set Up AI Integration", systemImage: "sparkles")
                    .font(.title2.weight(.semibold))
                Text("Reachly looked for AI tools already on this Mac. To see whether Reachly is already connected, it reads Claude Desktop's and Qoder's settings files for a reachly entry and asks Claude Code with claude mcp get. Nothing is copied or changed until you click a button, and each button says what it will do first.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 4)

            Form {
                Section("Found on this Mac") {
                    AIProviderRowsList()
                }
                let suggestions = detector.machine.map { AIProviderCatalogue.suggestions(machine: $0, reachly: detector.reachlyState(mcp: mcp)) } ?? []
                if !suggestions.isEmpty {
                    Section("Can be set up") {
                        ForEach(suggestions) { suggestion in
                            suggestionRow(suggestion)
                        }
                    }
                }
                Section {
                    readinessLine
                }
            }
            .formStyle(.grouped)
            .themedForm()

            Divider()
            HStack(spacing: 8) {
                Button("Check Again") { Task { await detector.refresh() } }
                    .disabled(detector.isChecking)
                if detector.isChecking { ProgressView().controlSize(.small) }
                Spacer()
                Button("Set Up Later") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 620, height: 660)
        .task { await detector.refreshIfStale() }
    }

    private func suggestionRow(_ suggestion: AIProviderSuggestion) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "circle.dashed")
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(suggestion.title).fontWeight(.medium)
                Text(suggestion.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !suggestion.links.isEmpty {
                    HStack(spacing: 12) {
                        ForEach(suggestion.links, id: \.self) { link in
                            Button(link.title) { openURL(link.url) }
                                .buttonStyle(.link)
                                .help(link.url.absoluteString)
                        }
                    }
                    .font(.caption)
                }
            }
            Spacer(minLength: 8)
            if suggestion.opensSettings {
                Button("Open AI Integration") { openAIIntegration() }
            }
        }
        .padding(.vertical, 2)
    }

    /// Whether the Claude panel can work now, so the sheet can be closed with confidence.
    private var readinessLine: some View {
        let usable = AIProviderReadiness.isUsable(settings.configuration, hasKey: settings.hasUsableAPIKey)
        return HStack(spacing: 6) {
            Image(systemName: usable ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(usable ? .green : .secondary)
            Text(usable
                 ? "Ready: the panel uses \(settings.configuration.kind.displayName). Change it any time in Settings › AI Integration."
                 : "No provider is set up yet. The panel needs one before it can answer; you can set it up later in Settings › AI Integration.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func openAIIntegration() {
        switch origin {
        case .settings:
            dismiss()
        case .launch:
            SettingsNavigation.shared.show(SettingsNavigation.aiIntegration, using: openSettings)
        }
    }
}

/// When the setup sheet appears by itself: once, on the first launch where no provider is usable.
@MainActor
enum AIIntegrationOnboarding {
    static let doneKey = "onboarding.aiIntegration.done"
    /// Asked once per launch, so a second main window does not bring up a second sheet.
    private static var askedThisLaunch = false

    /// Also records "done" when a provider already works, so an upgrade with a working provider never shows it.
    static func shouldPresentOnLaunch() -> Bool {
        guard !askedThisLaunch else { return false }
        askedThisLaunch = true
        #if DEBUG
        // UI checks launch with flags (`--window=…`, `--qa-…`, `--seed-demo`); keep their windows clear.
        // `--window=ai-setup` opens the sheet on purpose.
        if CommandLine.arguments.dropFirst().contains(where: { $0.hasPrefix("--") }) { return false }
        #endif
        let defaults = UserDefaults.standard
        let settings = AgentSettings.shared
        settings.refreshKeyState()
        let alreadyDone = defaults.bool(forKey: doneKey)
        let show = AIProviderReadiness.shouldOfferSetup(alreadyDone: alreadyDone, configuration: settings.configuration, hasKey: settings.hasUsableAPIKey)
        if !show, !alreadyDone { markDone() }
        return show
    }

    /// Set when the sheet closes, whichever button closed it.
    static func markDone() {
        UserDefaults.standard.set(true, forKey: doneKey)
    }
}
