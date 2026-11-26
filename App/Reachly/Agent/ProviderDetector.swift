import AppKit
import Foundation
import Observation
import ReachlyAgent
import ReachlyCore

/// Finds the AI providers already on this Mac and runs the one-click actions the AI Integration rows offer.
///
/// Detection reads no secret: file checks for apps and tools, `caimex auth list` (which prints none),
/// `claude mcp get reachly` (only its exit status), loopback probes of LM Studio and Ollama, and the Claude
/// Desktop and Qoder MCP configs, read in memory for one key. Every tool runs with a timeout, its output stays
/// in memory and is never logged, and a probe that fails just means "not found". Claude Code's and ChatGPT's
/// sign-ins are never read: no Keychain item, credentials file or token.
@MainActor
@Observable
final class ProviderDetector {
    static let shared = ProviderDetector()

    struct ActionResult: Equatable {
        let message: String
        let isError: Bool

        static func done(_ message: String) -> ActionResult { ActionResult(message: message, isError: false) }
        static func failed(_ message: String) -> ActionResult { ActionResult(message: message, isError: true) }
    }

    /// Nil until the first check has finished.
    private(set) var machine: AIProviderMachineFacts?
    private(set) var isChecking = false
    /// The row whose action is running; the other buttons wait.
    private(set) var runningAction: AIProviderRow.ID?
    /// The last action's outcome per row, shown under it.
    private(set) var results: [AIProviderRow.ID: ActionResult] = [:]

    @ObservationIgnored private var lastChecked: Date?
    @ObservationIgnored private var recheckRequested = false

    let home = FileManager.default.homeDirectoryForCurrentUser

    private init() {}

    /// Reachly's side of the rows, read live so a switch made anywhere shows at once.
    func reachlyState(mcp: MCPServerController) -> ReachlyAIState {
        let settings = AgentSettings.shared
        return ReachlyAIState(configuration: settings.configuration, hasKey: settings.hasAPIKey, savedKeyOrigin: settings.savedKeyOrigin, bridgePath: mcp.bridgePath, mcpServerEnabled: mcp.isEnabled, mcpPort: mcp.port)
    }

    // MARK: Detection

    /// On appear: the sheet and the Settings section often appear together, so a fresh result is reused.
    func refreshIfStale() async {
        if let lastChecked, Date().timeIntervalSince(lastChecked) < 15 { return }
        await refresh()
    }

    /// Check Again, and after an action. A request during a check runs once more when it ends.
    func refresh() async {
        guard !isChecking else {
            recheckRequested = true
            return
        }
        isChecking = true
        defer { isChecking = false }
        repeat {
            recheckRequested = false
            let home = home
            let keys = EnvironmentAPIKey.present(in: ProcessInfo.processInfo.environment)
            machine = await Task.detached(priority: .userInitiated) {
                await Self.gather(home: home, environmentKeys: keys)
            }.value
            lastChecked = Date()
        } while recheckRequested
    }

    nonisolated private static func gather(home: URL, environmentKeys: Set<EnvironmentAPIKey>) async -> AIProviderMachineFacts {
        let homePath = home.path
        let caimexPath = tool(.caimex, home: homePath)
        let claudePath = tool(.claude, home: homePath)
        let qoderPath = tool(.qoder, home: homePath, skipAppLaunchers: true)
        let codexPath = tool(.codex, home: homePath)
        let lmsPath = tool(.lms, home: homePath)
        let ollamaPath = tool(.ollama, home: homePath)

        let probe = LocalModelServerProbe()
        async let caimexHasKey = caimexHasStoredKey(cli: caimexPath, home: home)
        async let claudeConnected = claudeCodeIsConnected(cli: claudePath, home: home)
        async let lmStudioState = probe.state(of: .lmStudio)
        async let ollamaState = probe.state(of: .ollama)

        var facts = AIProviderMachineFacts(environmentKeys: environmentKeys)
        if app(.claudeDesktop, home: homePath) {
            let file = MCPClientConfigFile.claudeDesktop(home: home)
            facts.claudeDesktop = .init(configPath: file.url.path, config: file.state())
        }
        let qoderApp = app(.qoder, home: homePath)
        if qoderApp || qoderPath != nil {
            facts.qoder = .init(appInstalled: qoderApp, cliPath: qoderPath, config: MCPClientConfigFile.qoder(home: home).state())
        }
        let openAI = AIProviderMachineFacts.OpenAIApps(chatGPTApp: app(.chatGPT, home: homePath), codexApp: app(.codex, home: homePath), codexCLIPath: codexPath)
        if openAI.isFound { facts.openAI = openAI }

        if let caimexPath { facts.caimex = .init(cliPath: caimexPath, hasStoredKey: await caimexHasKey) }
        if let claudePath { facts.claudeCode = .init(cliPath: claudePath, isConnected: await claudeConnected) }
        facts.lmStudio = .init(installed: lmsPath != nil || app(.lmStudio, home: homePath), state: await lmStudioState)
        facts.ollama = .init(installed: ollamaPath != nil || app(.ollama, home: homePath), state: await ollamaState)
        return facts
    }

    nonisolated private static func tool(_ tool: AIProviderLocations.Tool, home: String, skipAppLaunchers: Bool = false) -> String? {
        AIProviderLocations.first(
            AIProviderLocations.candidates(for: tool, home: home),
            skipAppLaunchers: skipAppLaunchers,
            resolve: { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
            exists: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    nonisolated private static func app(_ app: AIProviderLocations.App, home: String) -> Bool {
        AIProviderLocations.candidates(forApp: app, home: home).contains { FileManager.default.fileExists(atPath: $0) }
    }

    /// `caimex auth list` prints the stored credentials without their secrets.
    nonisolated private static func caimexHasStoredKey(cli: String?, home: URL) async -> Bool {
        guard let cli,
              let output = await CommandRunner.run(cli, arguments: ["auth", "list"], timeout: 5, environment: toolEnvironment(for: cli, home: home), currentDirectory: home, outputLimit: 64 * 1024),
              output.succeeded else { return false }
        return CaimexCLIOutput.listShowsStoredKey(String(decoding: output.data, as: UTF8.self))
    }

    /// Only the exit status counts; the printed details are dropped unread.
    nonisolated private static func claudeCodeIsConnected(cli: String?, home: URL) async -> Bool {
        guard let cli else { return false }
        let command = MCPConnectCommand.claudeCodeGet(claude: cli)
        let output = await CommandRunner.run(command.executable, arguments: command.arguments, timeout: 10, environment: toolEnvironment(for: cli, home: home), currentDirectory: home, outputLimit: 64 * 1024)
        return output?.succeeded ?? false
    }

    /// The app's own environment with the tool's folder and the usual bin folders on PATH, since an app
    /// opened from the Finder gets a short PATH and some CLIs start helpers by name. Colour is turned off.
    nonisolated private static func toolEnvironment(for executable: String, home: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let folders = [URL(fileURLWithPath: executable).deletingLastPathComponent().path]
            + AIProviderLocations.binDirectories(home: home.path)
            + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
            + (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        environment["PATH"] = folders.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
        environment["NO_COLOR"] = "1"
        return environment
    }

    // MARK: Actions

    /// Runs a confirmed action. `prompt` is the confirmation the user saw: a command or file write runs exactly
    /// as it showed, never re-read from a later check. `model` is the one picked for a local server.
    func perform(_ action: AIProviderAction, prompt: AIProviderPrompt?, row: AIProviderRow.ID, model: String?, mcp: MCPServerController) async {
        guard runningAction == nil else { return }
        runningAction = row
        let result = await run(action, prompt: prompt, model: model, mcp: mcp)
        runningAction = nil
        if let result { results[row] = result }
        switch action {
        case .useCaimexKey, .connectClaudeCode, .connectClaudeDesktop, .connectQoderCLI:
            await refresh()
        default:
            break
        }
    }

    private func run(_ action: AIProviderAction, prompt: AIProviderPrompt?, model: String?, mcp: MCPServerController) async -> ActionResult? {
        let settings = AgentSettings.shared
        switch action {
        case .useCaimexKey:
            guard let command = prompt?.command else { return .failed("The Caimex CLI is no longer found. Nothing was changed.") }
            return await useCaimexKey(command, settings: settings)
        case .useLocalServer(let server):
            return useLocalServer(server, model: model, settings: settings)
        case .connectClaudeCode:
            guard let command = prompt?.command else { return .failed("Claude Code is no longer found. Nothing was changed.") }
            return await connect(
                command, client: "Claude Code", mcp: mcp,
                success: "Claude Code is connected. Start a new Claude Code session to use Reachly's tools.")
        case .connectQoderCLI:
            guard let command = prompt?.command else { return .failed("The Qoder CLI is no longer found. Nothing was changed.") }
            return await connect(
                command, client: "Qoder", mcp: mcp,
                success: "Qoder is connected. Restart Qoder, or run /mcp reload in a Qoder CLI session, to load Reachly.")
        case .connectClaudeDesktop:
            guard let path = prompt?.configFile, let bridge = prompt?.bridgePath else {
                return .failed("Claude Desktop is no longer found. Nothing was changed.")
            }
            return await connectClaudeDesktop(file: MCPClientConfigFile(url: URL(fileURLWithPath: path)), bridge: bridge, mcp: mcp)
        case .copyClaudeDesktopSnippet:
            copy(mcp.claudeDesktopSnippet)
            return .done("Copied. Paste it into claude_desktop_config.json, then restart Claude Desktop.")
        case .showQoderAppSteps, .openLink:
            // The steps are the prompt itself and a link opens in the browser; nothing to run.
            return nil
        case .setUpOpenAIEndpoint:
            var next = settings.configuration
            next.kind = .openAICompatible
            next.baseURL = AIProviderCatalogue.openAIBaseURL
            settings.configuration = next
            if settings.hasUsableAPIKey {
                return .done("The OpenAI API is selected, with the key saved for it. Type a model ID under Model.")
            }
            return .done("The OpenAI API is selected. Paste an OpenAI API key under API key, then type a model ID under Model.")
        case .useEnvironmentKey(let key):
            return useEnvironmentKey(key, settings: settings)
        case .turnOnMCPServer:
            return await turnOnServer(mcp) ?? .done("Reachly's MCP server is on.")
        }
    }

    /// Runs `caimex auth export` only now, keeps the Caimex key and drops the rest of the output at once.
    private func useCaimexKey(_ command: MCPConnectCommand, settings: AgentSettings) async -> ActionResult {
        guard var output = await CommandRunner.run(command.executable, arguments: command.arguments, timeout: 15, environment: Self.toolEnvironment(for: command.executable, home: home), currentDirectory: home, outputLimit: 256 * 1024) else {
            return .failed("The Caimex CLI couldn't be started. Nothing was changed.")
        }
        let exported = output.succeeded ? CaimexExportedKey.parse(output.data) : nil
        // The export holds every stored credential: overwrite and release it before anything else happens.
        let timedOut = output.timedOut
        output.data.resetBytes(in: 0..<output.data.count)
        output.data = Data()
        guard let exported else {
            return .failed(timedOut ? "The Caimex CLI didn't answer in time. Nothing was changed." : "The Caimex CLI didn't give a Caimex API key. Nothing was changed.")
        }
        // `setAPIKey` saves for the selected kind, so Caimex is selected first, and put back if the save fails.
        let previous = settings.configuration
        if previous.kind != .caimex {
            var next = previous
            next.kind = .caimex
            settings.configuration = next
        }
        do {
            try settings.setAPIKey(exported.key)
        } catch {
            settings.configuration = previous
            return .failed(error.localizedDescription)
        }
        return .done("Caimex is selected, and the CLI's key is saved in your login Keychain.")
    }

    private func useLocalServer(_ server: LocalModelServer, model: String?, settings: AgentSettings) -> ActionResult {
        guard let model = model?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty else {
            return .failed("Pick a model first. Nothing was changed.")
        }
        var next = settings.configuration
        next.kind = .openAICompatible
        next.baseURL = server.baseURL
        next.model = model
        settings.configuration = next
        var message = "Reachly now uses \(server.displayName) with \(model)."
        if settings.hasUsableAPIKey {
            message += " The key saved for this endpoint is sent to it; remove it under API key if \(server.displayName) doesn't need one."
        } else if settings.hasAPIKey {
            message += " No key is sent to it; the saved endpoint key stays saved for its own endpoint."
        }
        return .done(message)
    }

    private func useEnvironmentKey(_ key: EnvironmentAPIKey, settings: AgentSettings) -> ActionResult {
        // Read only now, from Reachly's own environment.
        guard let value = ProcessInfo.processInfo.environment[key.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return .failed("\(key.rawValue) is no longer set. Nothing was changed.")
        }
        let previous = settings.configuration
        var next = previous
        switch key {
        case .anthropic:
            next.kind = .anthropic
        case .openAI:
            next.kind = .openAICompatible
            next.baseURL = AIProviderCatalogue.openAIBaseURL
        }
        settings.configuration = next
        do {
            try settings.setAPIKey(value)
        } catch {
            settings.configuration = previous
            return .failed(error.localizedDescription)
        }
        switch key {
        case .anthropic: return .done("Anthropic (Claude) is selected, and the key is saved in your login Keychain.")
        case .openAI: return .done("The OpenAI API is selected, and the key is saved in your login Keychain. Type a model ID under Model.")
        }
    }

    /// Runs a client's own `mcp add` and reports what it said.
    private func connect(_ command: MCPConnectCommand, client: String, mcp: MCPServerController, success: String) async -> ActionResult {
        guard let output = await CommandRunner.run(command.executable, arguments: command.arguments, timeout: 30, includeStandardError: true, environment: Self.toolEnvironment(for: command.executable, home: home), currentDirectory: home, outputLimit: 64 * 1024) else {
            return .failed("\(client) couldn't be started. Nothing was changed.")
        }
        if output.timedOut { return .failed("\(client) didn't finish within 30 seconds and was stopped.") }
        guard output.exitStatus == 0 else {
            let said = TerminalText.summary(output.data)
            return .failed(said.isEmpty ? "\(client) stopped with status \(output.exitStatus)." : "\(client) said: \(said)")
        }
        if let problem = await turnOnServer(mcp) { return .failed(success + " " + problem.message) }
        return .done(success)
    }

    private func connectClaudeDesktop(file: MCPClientConfigFile, bridge: String, mcp: MCPServerController) async -> ActionResult {
        let outcome: MCPClientConfigFile.Outcome
        do {
            outcome = try await Task.detached(priority: .userInitiated) { try file.connect(command: bridge) }.value
        } catch {
            return .failed("Claude Desktop's config couldn't be written: \(error.localizedDescription)")
        }
        let message: String
        switch outcome {
        case .added(let backup):
            let copy = backup.map { " The previous file is kept next to it as \($0.lastPathComponent)." } ?? ""
            message = "Reachly was added to Claude Desktop's config.\(copy) Restart Claude Desktop to load Reachly."
        case .alreadyPresent:
            message = "Claude Desktop already has a reachly entry, so the file was left as it is."
        case .unreadable:
            return .failed("Claude Desktop's config couldn't be read as JSON, so it was left as it is. Use Copy Config and add the entry by hand.")
        }
        if let problem = await turnOnServer(mcp) { return .failed(message + " " + problem.message) }
        return .done(message)
    }

    /// Turns the MCP server on when it is off and waits briefly to see it listen. Nil when it runs.
    private func turnOnServer(_ mcp: MCPServerController) async -> ActionResult? {
        if !mcp.isEnabled { mcp.isEnabled = true }
        for _ in 0..<30 where !mcp.isRunning && mcp.lastError == nil {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if let error = mcp.lastError { return .failed(error) }
        return nil
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
