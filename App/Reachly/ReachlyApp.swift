import AppKit
import SwiftData
import SwiftUI
import ReachlyAgent
import ReachlyCore
import ReachlyTerminal

@main
struct ReachlyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow
    @State private var appState: AppState
    @State private var workspace: Workspace
    @State private var updates = UpdateManager()
    @State private var agent: AgentPanelController
    @State private var mcp: MCPServerController
    @State private var forwarding: PortForwardingManager
    @State private var themes: ThemeStore
    /// Non-nil while the Files window is the key window.
    @FocusedValue(\.filesWindow) private var filesWindow
    private let container: ModelContainer

    init() {
        // macOS 26/27 workaround, belt-and-suspenders for launches that bypass
        // LaunchServices (the Info.plist LSEnvironment covers Finder/`open`):
        // force the pre-Swift-6 thread-based executor check so SwiftUI's hover
        // hit-testing cannot crash in swift_task_isCurrentExecutorWithFlags.
        setenv("SWIFT_IS_CURRENT_EXECUTOR_LEGACY_MODE_OVERRIDE", "legacy", 0)
        do {
            let schema = Schema(ReachlySchema.models)
            let configuration = ModelConfiguration("Reachly", schema: schema, url: AppPaths.databaseURL)
            container = try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Could not open the Reachly database at \(AppPaths.databaseURL.path): \(error)")
        }
        HistoryOperations.container = container
        let recorder = AppHistoryRecorder(context: container.mainContext)
        let appState = AppState()
        let workspace = Workspace(makeSession: { host in
            TerminalSession(host: host, historyRecorder: recorder)
        })
        let toolHost = AppAgentHost(context: container.mainContext, workspace: workspace, appState: appState)
        _appState = State(initialValue: appState)
        _workspace = State(initialValue: workspace)
        _agent = State(initialValue: AgentPanelController(toolHost: toolHost, context: container.mainContext, workspace: workspace))
        _mcp = State(initialValue: MCPServerController(toolHost: toolHost))
        _forwarding = State(initialValue: PortForwardingManager(workspace: workspace))
        _themes = State(initialValue: ThemeStore(context: container.mainContext))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .environment(workspace)
                .environment(updates)
                .environment(agent)
                .environment(mcp)
                .environment(forwarding)
                .appAppearance(themes)
                .onAppear {
                    appDelegate.workspace = workspace
                    appDelegate.appState = appState
                    appDelegate.forwarding = forwarding
                    appDelegate.themes = themes
                }
                .sheet(item: Bindable(updates).availableUpdate) { item in
                    UpdateAvailableView(item: item)
                        .environment(updates)
                        .themedSheet()
                }
        }
        .modelContainer(container)
        .defaultSize(width: 1200, height: 760)
        // Commands that use one of the Files menu's keys (⌘D, ⌥⌘N, ⇧⌘N) give it up and turn off while the Files
        // window is in front, and check again when they run, so a key never acts on the main window from there.
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updates.checkForUpdates() }
            }
            IdentityCommands()
            CommandGroup(replacing: .importExport) {
                Button("Import…") { appState.importRequest = .chooseFile }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Menu("Import From") {
                    Button("~/.ssh/config…") { appState.importRequest = .sshConfig }
                    Button("Termius CSV…") { appState.importRequest = .termius }
                    Button("PuTTY Sessions…") { appState.importRequest = .putty }
                    Button("Tabby Config…") { appState.importRequest = .tabby }
                    Divider()
                    Button("Cloud Provider (AWS, DigitalOcean, Azure)…") { appState.isShowingCloudImport = true }
                    Divider()
                    Button("Terminal Theme File…") { appState.importRequest = .themeFile }
                }
                Divider()
                Button("Export…") { appState.isExporting = true }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Export to ~/.ssh/config…") { appState.isExportingSSHConfig = true }
            }
            CommandGroup(replacing: .newItem) {
                Button("New Host…") { appState.hostEditor = .create }
                    .keyboardShortcut("n", modifiers: .command)
                Button("New Group…") {
                    guard !FilesWindow.isKey else { return }
                    appState.newGroup = NewGroupRequest()
                }
                .keyboardShortcut(mainWindowShortcut("n", [.command, .shift]))
                .disabled(filesWindow != nil)
                Button("New Snippet…") {
                    guard !FilesWindow.isKey else { return }
                    appState.snippetEditor = .create(folder: nil, command: nil)
                }
                .keyboardShortcut(mainWindowShortcut("n", [.command, .option]))
                .disabled(filesWindow != nil)
                Button("New Forwarding Rule…") { appState.portForwardEditor = .create(hostID: appState.selectedHostID) }
                Button("New Serial Console…") { appState.serialProfileEditor = .create }
                Divider()
                Button("New Tab…") {
                    guard !FilesWindow.isKey else { return }
                    appState.isShowingNewTabPicker = true
                }
                .keyboardShortcut(mainWindowShortcut("t", .command))
                .disabled(filesWindow != nil)
                // SwiftUI gives ⌘W to this item rather than the standard Close, so in the Files window it closes that
                // window instead of a terminal pane behind it. (Moving ⌘W between the two items doesn't work: once
                // Close holds it, SwiftUI keeps it there.)
                Button(filesWindow != nil ? "Close Window" : "Close Pane") {
                    if FilesWindow.isKey {
                        FilesWindow.closeIfKey()
                    } else {
                        workspace.closeFocusedPane()
                    }
                }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(filesWindow == nil && workspace.selectedTab == nil)
                Button("Close Tab") {
                    guard !FilesWindow.isKey, let id = workspace.selectedTabID else { return }
                    workspace.closeTab(id: id)
                }
                .keyboardShortcut(mainWindowShortcut("w", [.command, .shift]))
                .disabled(workspace.selectedTab == nil || filesWindow != nil)
            }
            CommandMenu("Session") {
                Button("Search Everything…") { appState.isShowingSearch = true }
                    .keyboardShortcut("k", modifiers: .command)
                Divider()
                Button("Split Right") {
                    guard !FilesWindow.isKey else { return }
                    workspace.split(.horizontal)
                }
                .keyboardShortcut(mainWindowShortcut("d", .command))
                .disabled(workspace.focusedSession == nil || filesWindow != nil)
                Button("Split Down") {
                    guard !FilesWindow.isKey else { return }
                    workspace.split(.vertical)
                }
                .keyboardShortcut(mainWindowShortcut("d", [.command, .shift]))
                .disabled(workspace.focusedSession == nil || filesWindow != nil)
                Divider()
                // Without their keys while the Files window is in front, ⌘← and ⌘→ move the cursor in its path field.
                ForEach(Self.focusPaneCommands, id: \.title) { pane in
                    Button(pane.title) {
                        guard !FilesWindow.isKey else { return }
                        workspace.focus(direction: pane.direction)
                    }
                    .keyboardShortcut(mainWindowShortcut(pane.key, .command))
                    .disabled(filesWindow != nil)
                }
                Divider()
                Button("Reconnect") {
                    guard !FilesWindow.isKey, let session = workspace.focusedSession else { return }
                    Task { await session.reconnect() }
                }
                .keyboardShortcut(mainWindowShortcut("r", [.command, .shift]))
                .disabled(workspace.focusedSession == nil || filesWindow != nil)
                Button("Disconnect") {
                    guard !FilesWindow.isKey else { return }
                    workspace.focusedSession?.disconnect()
                }
                .keyboardShortcut(mainWindowShortcut("d", [.command, .option]))
                .disabled(workspace.focusedSession?.isConnected != true || filesWindow != nil)
                Divider()
                Button("Lock Saved Secrets") { Vault.shared.lock() }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                Divider()
                Button("Ask \(agent.nextAssistantName) About This Host") {
                    if let host = workspace.focusedSession?.host, !host.isTransient { agent.focus(.host(host.id)) }
                    appState.isShowingAgentPanel = true
                }
                .disabled(workspace.focusedSession == nil)
                Divider()
                Button("Find in Terminal…") {
                    guard !FilesWindow.isKey else { return }
                    NotificationCenter.default.post(name: .reachlyFindInTerminal, object: nil)
                }
                .keyboardShortcut(mainWindowShortcut("f", .command))
                .disabled(workspace.focusedSession == nil || filesWindow != nil)
                Button("Browse Files (SFTP)…") {
                    guard let host = workspace.focusedSession?.host, !host.isTransient, !host.isSerial else { return }
                    appState.sftpHostID = host.id
                    openWindow(id: "sftp")
                }
                .keyboardShortcut("o", modifiers: [.command, .option])
                .disabled(workspace.focusedSession?.host.isTransient != false)
            }
            CommandGroup(after: .sidebar) {
                Button("Show Hosts") { appState.sidebarMode = .hosts }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                Button("Show Snippets") { appState.sidebarMode = .snippets }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Button("Show History") { appState.sidebarMode = .history }
                    .keyboardShortcut("y", modifiers: .command)
                Button("Show Port Forwarding") { appState.sidebarMode = .ports }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Divider()
                Button("Theme Editor…") { openWindow(id: ThemeEditorView.windowID) }
                Divider()
                Button(appState.isShowingAgentPanel ? "Hide Claude Panel" : "Show Claude Panel") { appState.isShowingAgentPanel.toggle() }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
            }
            // After Session, so the Files menu sits next to it.
            FilesCommands()
            CommandGroup(after: .windowArrangement) {
                Button("Previous Tab") {
                    guard !FilesWindow.isKey else { return }
                    workspace.selectPreviousTab()
                }
                .keyboardShortcut(mainWindowShortcut("[", [.command, .shift]))
                .disabled(filesWindow != nil)
                Button("Next Tab") {
                    guard !FilesWindow.isKey else { return }
                    workspace.selectNextTab()
                }
                .keyboardShortcut(mainWindowShortcut("]", [.command, .shift]))
                .disabled(filesWindow != nil)
                ForEach(1...9, id: \.self) { number in
                    Button("Tab \(number)") {
                        guard !FilesWindow.isKey else { return }
                        workspace.selectTab(at: number - 1)
                    }
                    .keyboardShortcut(mainWindowShortcut(KeyEquivalent(Character(String(number))), .command))
                    .disabled(filesWindow != nil)
                }
            }
        }

        WindowGroup("Session", id: "session", for: UUID.self) { $hostID in
            SessionWindowView(hostID: hostID)
                .environment(forwarding)
                .appAppearance(themes)
        }
        .modelContainer(container)
        .defaultSize(width: 900, height: 600)

        Window("Files", id: "sftp") {
            SFTPWindowView()
                .environment(appState)
                .environment(workspace)
                .appAppearance(themes)
        }
        .modelContainer(container)
        .defaultSize(width: 1100, height: 680)

        Window("Theme Editor", id: ThemeEditorView.windowID) {
            ThemeEditorView()
                .environment(appState)
                .appAppearance(themes)
        }
        .modelContainer(container)
        .defaultSize(width: 1080, height: 680)

        Window("Identities & Keys", id: IdentitiesView.windowID) {
            IdentitiesView()
                .appAppearance(themes)
        }
        .modelContainer(container)
        .defaultSize(width: 860, height: 560)

        Settings {
            SettingsView()
                .environment(updates)
                .environment(appState)
                .environment(mcp)
                .environment(forwarding)
                .appAppearance(themes)
        }
        .modelContainer(container)
    }

    /// A main-window command's shortcut, or none while the Files window is in front: there the key belongs to the
    /// Files menu or to the focused control, and never acts on the main window. Each such command also checks
    /// `FilesWindow.isKey` when it runs, as the menu can lag behind a window switch.
    private func mainWindowShortcut(_ key: KeyEquivalent, _ modifiers: EventModifiers) -> KeyboardShortcut? {
        filesWindow == nil ? KeyboardShortcut(key, modifiers: modifiers) : nil
    }

    /// A Focus Pane command: its title, the direction it moves focus and its key (with ⌘).
    private struct FocusPaneCommand {
        let title: String
        let direction: PaneDirection
        let key: KeyEquivalent
    }

    /// The Focus Pane commands, in menu order.
    private static let focusPaneCommands = [
        FocusPaneCommand(title: "Focus Pane Left", direction: .left, key: .leftArrow),
        FocusPaneCommand(title: "Focus Pane Right", direction: .right, key: .rightArrow),
        FocusPaneCommand(title: "Focus Pane Above", direction: .up, key: .upArrow),
        FocusPaneCommand(title: "Focus Pane Below", direction: .down, key: .downArrow),
    ]
}

/// The look chosen in Settings → Appearance, for every scene: the theme store
/// and the palette in the environment, the accent colour, and the window
/// painted with the scheme. The light or dark side is set on `NSApp` by the
/// store, so sheets, menus and panels follow too.
private struct AppAppearanceModifier: ViewModifier {
    let themes: ThemeStore

    func body(content: Content) -> some View {
        let palette = themes.palette
        content
            .schemeEdges(palette)
            .environment(themes)
            .environment(\.palette, palette)
            .tint(themes.appearance.accentColor ?? palette.accent)
            .background(WindowChrome(palette: palette))
    }
}

extension View {
    func appAppearance(_ themes: ThemeStore) -> some View {
        modifier(AppAppearanceModifier(themes: themes))
    }
}

/// Window menu entry for the Identities & Keys window.
struct IdentityCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(before: .windowList) {
            Button("Identities & Keys") { openWindow(id: IdentitiesView.windowID) }
                .keyboardShortcut("i", modifiers: [.command, .shift])
        }
    }
}

/// Saves the workspace and disconnects cleanly at quit; locks secrets on sleep.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var workspace: Workspace?
    var appState: AppState?
    var forwarding: PortForwardingManager?
    var themes: ThemeStore?

    /// Double-clicked or dropped `.reachly` files, theme JSON files, and `reachly://theme?url=` links
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            for url in urls {
                if url.scheme == "reachly" {
                    handleAppLink(url)
                } else if url.pathExtension == ReachlyFile.fileExtension {
                    appState?.importRequest = .file(url)
                } else if url.pathExtension.lowercased() == "json" || url.pathExtension.lowercased() == "itermcolors" {
                    appState?.importRequest = .themeFileAt(url)
                } else {
                    appState?.importRequest = .file(url)
                }
            }
            NSApp.activate()
        }
    }

    @MainActor
    private func handleAppLink(_ url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        switch components.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) {
        case "theme":
            guard let source = components.queryItems?.first(where: { $0.name == "url" })?.value, let themeURL = URL(string: source) else { return }
            appState?.pendingThemeInstall = PendingThemeInstall(sourceURL: themeURL)
        default:
            break
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { Vault.shared.systemDidSleep() }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { Vault.shared.systemDidSleep() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            MCPBridgeConfig.remove()
            guard let workspace else { return }
            try? workspace.snapshot().save()
            workspace.disconnectAll()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        MainActor.assumeIsolated { themes?.systemAppearanceChanged() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
