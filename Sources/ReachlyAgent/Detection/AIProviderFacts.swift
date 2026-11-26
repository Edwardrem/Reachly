import Foundation

/// An API key Reachly may find in its own process environment. Only `ProcessInfo` is consulted; no login shell
/// is started to look for one.
public enum EnvironmentAPIKey: String, Sendable, CaseIterable, Hashable {
    case anthropic = "ANTHROPIC_API_KEY"
    case openAI = "OPENAI_API_KEY"

    /// The names set to a non-blank value. The values are not kept.
    public static func present(in environment: [String: String]) -> Set<EnvironmentAPIKey> {
        Set(allCases.filter { !(environment[$0.rawValue] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    }
}

/// What Reachly found on this Mac, gathered without reading any secret. Nil for something that is not there.
public struct AIProviderMachineFacts: Sendable, Equatable {
    public struct Caimex: Sendable, Equatable {
        public var cliPath: String
        /// `caimex auth list` shows a stored Caimex credential.
        public var hasStoredKey: Bool

        public init(cliPath: String, hasStoredKey: Bool) {
            self.cliPath = cliPath
            self.hasStoredKey = hasStoredKey
        }
    }

    public struct LocalServer: Sendable, Equatable {
        /// The app or its command-line tool is on this Mac.
        public var installed: Bool
        public var state: LocalServerState

        public init(installed: Bool = false, state: LocalServerState = .notRunning) {
            self.installed = installed
            self.state = state
        }

        /// Worth a row: installed, or something answers on its port.
        public var isFound: Bool { installed || state != .notRunning }
    }

    public struct ClaudeCode: Sendable, Equatable {
        public var cliPath: String
        /// `claude mcp get reachly` exited 0 in time.
        public var isConnected: Bool

        public init(cliPath: String, isConnected: Bool) {
            self.cliPath = cliPath
            self.isConnected = isConnected
        }
    }

    public struct ClaudeDesktop: Sendable, Equatable {
        public var configPath: String
        public var config: MCPClientConfig.State

        public init(configPath: String, config: MCPClientConfig.State) {
            self.configPath = configPath
            self.config = config
        }
    }

    public struct Qoder: Sendable, Equatable {
        public var appInstalled: Bool
        /// The Qoder CLI, which can add MCP servers itself. Nil when only the app is installed.
        public var cliPath: String?
        /// The file `cliPath` leads to through its symbolic links, when that is somewhere else.
        public var cliTarget: String?
        /// `~/.qoder/settings.json`, which both the app and the CLI read.
        public var config: MCPClientConfig.State

        public init(appInstalled: Bool, cliPath: String?, cliTarget: String? = nil, config: MCPClientConfig.State) {
            self.appInstalled = appInstalled
            self.cliPath = cliPath
            self.cliTarget = cliTarget
            self.config = config
        }
    }

    public struct OpenAIApps: Sendable, Equatable {
        public var chatGPTApp: Bool
        public var codexApp: Bool
        public var codexCLIPath: String?

        public init(chatGPTApp: Bool = false, codexApp: Bool = false, codexCLIPath: String? = nil) {
            self.chatGPTApp = chatGPTApp
            self.codexApp = codexApp
            self.codexCLIPath = codexCLIPath
        }

        public var isFound: Bool { chatGPTApp || codexApp || codexCLIPath != nil }
    }

    public var caimex: Caimex?
    public var lmStudio: LocalServer
    public var ollama: LocalServer
    public var claudeCode: ClaudeCode?
    public var claudeDesktop: ClaudeDesktop?
    public var qoder: Qoder?
    public var openAI: OpenAIApps?
    public var environmentKeys: Set<EnvironmentAPIKey>

    public init(
        caimex: Caimex? = nil,
        lmStudio: LocalServer = LocalServer(),
        ollama: LocalServer = LocalServer(),
        claudeCode: ClaudeCode? = nil,
        claudeDesktop: ClaudeDesktop? = nil,
        qoder: Qoder? = nil,
        openAI: OpenAIApps? = nil,
        environmentKeys: Set<EnvironmentAPIKey> = []
    ) {
        self.caimex = caimex
        self.lmStudio = lmStudio
        self.ollama = ollama
        self.claudeCode = claudeCode
        self.claudeDesktop = claudeDesktop
        self.qoder = qoder
        self.openAI = openAI
        self.environmentKeys = environmentKeys
    }

    public func server(_ server: LocalModelServer) -> LocalServer {
        switch server {
        case .lmStudio: lmStudio
        case .ollama: ollama
        }
    }
}

/// Reachly's own side, read live from settings: what is selected, whether it has a key, the MCP server.
public struct ReachlyAIState: Sendable, Equatable {
    public var kind: LLMProviderConfiguration.Kind
    /// Whether the selected kind has a saved key (only the Keychain item's existence; never the key).
    public var hasKey: Bool
    /// For an endpoint, the origin its saved key belongs to; the key is sent only there.
    public var savedKeyOrigin: EndpointOrigin?
    public var baseURL: String
    public var model: String
    public var bridgePath: String
    public var mcpServerEnabled: Bool
    public var mcpPort: Int
    /// The agent the chat panel runs over ACP (the Qoder CLI), when one is chosen.
    public var acpCommandPath: String?

    public init(kind: LLMProviderConfiguration.Kind, hasKey: Bool, savedKeyOrigin: EndpointOrigin? = nil, baseURL: String = "", model: String = "", bridgePath: String, mcpServerEnabled: Bool, mcpPort: Int = MCPBridgeConfig.defaultPort, acpCommandPath: String? = nil) {
        self.kind = kind
        self.acpCommandPath = acpCommandPath
        self.hasKey = hasKey
        self.savedKeyOrigin = savedKeyOrigin
        self.baseURL = baseURL
        self.model = model
        self.bridgePath = bridgePath
        self.mcpServerEnabled = mcpServerEnabled
        self.mcpPort = mcpPort
    }

    public init(configuration: LLMProviderConfiguration, hasKey: Bool, savedKeyOrigin: EndpointOrigin?, bridgePath: String, mcpServerEnabled: Bool, mcpPort: Int) {
        self.init(kind: configuration.kind, hasKey: hasKey, savedKeyOrigin: savedKeyOrigin, baseURL: configuration.baseURL, model: configuration.model, bridgePath: bridgePath, mcpServerEnabled: mcpServerEnabled, mcpPort: mcpPort, acpCommandPath: configuration.acpCommandPath)
    }

    /// A key is saved and will be sent: Anthropic and Caimex always, an endpoint only at the origin it was saved for.
    public var hasUsableKey: Bool {
        hasKey && EndpointKeyPolicy.mayUseKey(kind: kind, savedOrigin: savedKeyOrigin, baseURL: baseURL)
    }

    /// A key is saved for the selected endpoint but withheld from its current base URL.
    public var hasWithheldKey: Bool { hasKey && !hasUsableKey }

    /// Where Reachly's stdio bridge would be written into other apps' configs, when that place is temporary:
    /// a disk image or a translocated copy disappears, and the client could then not start Reachly.
    public var bridgeLocationProblem: String? {
        MCPBridgeLocation.problem(bridgePath: bridgePath)
    }

    /// The OpenAI-compatible endpoint is selected and points at this local server.
    public func uses(_ server: LocalModelServer) -> Bool {
        kind == .openAICompatible && server.matches(baseURL: baseURL)
    }

    /// The OpenAI-compatible endpoint is selected and points at the OpenAI API.
    public var usesOpenAIAPI: Bool {
        kind == .openAICompatible && URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased() == "api.openai.com"
    }
}

/// Whether the agent panel can work with what is saved, and whether the first-run setup should appear.
public enum AIProviderReadiness {
    /// The selected kind has a key when it needs one, and an endpoint has a base URL with a scheme and host.
    public static func isUsable(_ configuration: LLMProviderConfiguration, hasKey: Bool) -> Bool {
        switch configuration.kind {
        case .anthropic, .caimex:
            return hasKey
        case .openAICompatible:
            guard let url = URL(string: configuration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
            return url.scheme != nil && url.host != nil
        case .qoder:
            // The CLI confirmed in AI Integration. Whether it is signed in shows on the first message.
            return !(configuration.acpCommandPath ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Once, on the first launch where nothing is usable. A launch that finds a usable provider also counts
    /// as done, so someone upgrading with a working provider never sees the sheet.
    public static func shouldOfferSetup(alreadyDone: Bool, configuration: LLMProviderConfiguration, hasKey: Bool) -> Bool {
        !alreadyDone && !isUsable(configuration, hasKey: hasKey)
    }
}

/// Where Reachly looks for the tools and apps it can offer. Only file checks: nothing is opened or run here.
public enum AIProviderLocations {
    public enum Tool: String, Sendable, CaseIterable {
        case caimex, claude, qoder, codex, lms, ollama
    }

    public enum App: String, Sendable, CaseIterable {
        case claudeDesktop = "Claude.app"
        case qoder = "Qoder.app"
        case chatGPT = "ChatGPT.app"
        case codex = "Codex.app"
        case lmStudio = "LM Studio.app"
        case ollama = "Ollama.app"
    }

    /// `~/.local/bin`, `/opt/homebrew/bin` and `/usr/local/bin`, in that order.
    public static func binDirectories(home: String) -> [String] {
        [home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
    }

    public static func applicationDirectories(home: String) -> [String] {
        ["/Applications", home + "/Applications"]
    }

    /// Every path the tool may be at, most likely first.
    public static func candidates(for tool: Tool, home: String) -> [String] {
        let bins = binDirectories(home: home)
        switch tool {
        case .caimex: return bins.map { $0 + "/caimex" }
        case .claude: return bins.map { $0 + "/claude" } + [home + "/.claude/local/claude"]
        case .qoder:
            return [home + "/.qoder/bin/qoder", home + "/.qoder/bin/qodercli"]
                + bins.map { $0 + "/qoder" } + bins.map { $0 + "/qodercli" }
        case .codex: return bins.map { $0 + "/codex" }
        case .lms: return [home + "/.lmstudio/bin/lms"] + bins.map { $0 + "/lms" }
        case .ollama: return bins.map { $0 + "/ollama" }
        }
    }

    public static func candidates(forApp app: App, home: String) -> [String] {
        applicationDirectories(home: home).map { $0 + "/" + app.rawValue }
    }

    /// The first candidate `exists` accepts. A tool whose real path is inside an app bundle is skipped when
    /// `skipAppLaunchers` is set: for Qoder that is the editor's `qoder` shell command, which has no `mcp add`.
    public static func first(
        _ candidates: [String],
        skipAppLaunchers: Bool = false,
        resolve: (String) -> String = { $0 },
        exists: (String) -> Bool
    ) -> String? {
        candidates.first { path in
            guard exists(path) else { return false }
            return !(skipAppLaunchers && isInsideAppBundle(resolve(path)))
        }
    }

    /// Whether a folder on the way to `path` is an app bundle (`Qoder.app`, `qoder.APP`), by whole path
    /// components, so `/opt/my.apps/bin/qoder` is not one.
    public static func isInsideAppBundle(_ path: String) -> Bool {
        path.split(separator: "/").dropLast().contains { component in
            component.count > 4 && component.lowercased().hasSuffix(".app")
        }
    }
}
