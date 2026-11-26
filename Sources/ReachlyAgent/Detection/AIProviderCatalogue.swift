import Foundation

/// A page a row or suggestion links to.
public enum AIProviderLink: String, Sendable, Hashable, CaseIterable {
    case anthropicKeys, caimexKeys, openAIKeys, lmStudio, ollama

    public var title: String {
        switch self {
        case .anthropicKeys: "Get an Anthropic Key"
        case .caimexKeys: "Get a Caimex Key"
        case .openAIKeys: "Get an OpenAI Key"
        case .lmStudio: "Get LM Studio"
        case .ollama: "Get Ollama"
        }
    }

    public var url: URL {
        switch self {
        case .anthropicKeys: LLMProviderConfiguration.Kind.anthropic.keyPageURL!
        case .caimexKeys: LLMProviderConfiguration.Kind.caimex.keyPageURL!
        case .openAIKeys: URL(string: "https://platform.openai.com/api-keys")!
        case .lmStudio: URL(string: "https://lmstudio.ai")!
        case .ollama: URL(string: "https://ollama.com/download")!
        }
    }
}

/// What a row's button does. Anything that changes a setting, runs a tool or writes a file first shows the
/// prompt from `prompt(machine:reachly:home:)`; nothing is read or changed before the user confirms it.
public enum AIProviderAction: Sendable, Hashable {
    /// Runs `caimex auth export` once, keeps the Caimex key, selects Caimex and saves the key.
    case useCaimexKey
    /// Selects the OpenAI-compatible endpoint at the local server with a model from its list.
    case useLocalServer(LocalModelServer)
    case connectClaudeCode
    case connectClaudeDesktop
    /// Copies the Claude Desktop snippet, for a config Reachly will not change.
    case copyClaudeDesktopSnippet
    case connectQoderCLI
    /// The steps for adding Reachly in the Qoder app, with the bridge path to copy.
    case showQoderAppSteps
    /// Points the OpenAI-compatible endpoint at api.openai.com; the key is pasted by the user.
    case setUpOpenAIEndpoint
    /// Saves the key from Reachly's own environment for its provider and selects that provider.
    case useEnvironmentKey(EnvironmentAPIKey)
    case turnOnMCPServer
    case openLink(AIProviderLink)

    public var title: String {
        switch self {
        case .useCaimexKey: "Use Caimex Key"
        case .useLocalServer(let server): "Use \(server.displayName)"
        case .connectClaudeCode, .connectClaudeDesktop, .connectQoderCLI: "Connect"
        case .copyClaudeDesktopSnippet: "Copy Config"
        case .showQoderAppSteps: "Show Steps"
        case .setUpOpenAIEndpoint: "Set Up OpenAI API"
        case .useEnvironmentKey: "Use Key"
        case .turnOnMCPServer: "Turn On MCP Server"
        case .openLink(let link): link.title
        }
    }

    public var isLink: Bool {
        if case .openLink = self { return true }
        return false
    }
}

/// The confirmation (or, for the Qoder app, the steps) shown before an action runs.
public struct AIProviderPrompt: Sendable, Equatable {
    public var title: String
    public var message: String
    /// Numbered steps the user follows by hand.
    public var steps: [String]
    /// The exact command or path involved, shown in a monospaced box with a Copy button.
    public var detail: String?
    /// The confirming button; nil when the prompt only informs and has nothing to confirm.
    public var confirmTitle: String?

    public init(title: String, message: String, steps: [String] = [], detail: String? = nil, confirmTitle: String?) {
        self.title = title
        self.message = message
        self.steps = steps
        self.detail = detail
        self.confirmTitle = confirmTitle
    }
}

/// One provider found on this Mac, as the AI Integration rows show it.
public struct AIProviderRow: Sendable, Equatable, Identifiable {
    public enum ID: String, Sendable, Hashable, CaseIterable {
        case caimex, lmStudio, ollama, anthropicEnvironmentKey, openAIEnvironmentKey, claudeCode, claudeDesktop, qoder, openAI
    }

    public enum Status: Sendable, Equatable {
        /// Reachly's chat uses it now.
        case inUse
        /// Reachly's MCP server is in its config.
        case connected
        /// One click away.
        case ready
        /// Found, but something has to happen first (start a server, sign in, turn the MCP server on).
        case needsAction
        /// Found, but its sign-in cannot be used by Reachly.
        case unavailable
    }

    public let id: ID
    public let title: String
    /// One line on what was found.
    public let detail: String
    public let status: Status
    public let actions: [AIProviderAction]
    /// Why something can't be used, or what to do next.
    public let note: String?

    public init(id: ID, title: String, detail: String, status: Status, actions: [AIProviderAction] = [], note: String? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.status = status
        self.actions = actions
        self.note = note
    }
}

/// Something that wasn't found but can be set up, for the setup sheet's "Can be set up" list.
public struct AIProviderSuggestion: Sendable, Equatable, Identifiable {
    public enum ID: String, Sendable, Hashable, CaseIterable {
        case anthropicKey, caimexKey, openAICompatible, localModels
    }

    public let id: ID
    public let title: String
    public let detail: String
    public let links: [AIProviderLink]
    /// Offers a button that opens Settings › AI Integration, where the key or endpoint is typed.
    public let opensSettings: Bool
}

/// Turns what was found into rows, suggestions and prompts. Pure: the same facts give the same rows.
public enum AIProviderCatalogue {
    /// Claude plan sign-ins (Free, Pro, Max) may not be used by other apps; said on every Claude row.
    public static let claudeSignInNote = "Claude plan sign-ins can't be used by other apps. To chat with Claude in Reachly, add an Anthropic API key."
    public static let openAISignInNote = "ChatGPT and Codex sign-ins can't be used by other apps. To use OpenAI models in Reachly, add an OpenAI API key to the OpenAI-compatible endpoint."
    public static let openAIBaseURL = "https://api.openai.com/v1"

    // MARK: Rows

    /// Chat providers first (Caimex, local servers, environment keys), then MCP clients, then ChatGPT.
    public static func rows(machine: AIProviderMachineFacts, reachly: ReachlyAIState) -> [AIProviderRow] {
        var rows = [AIProviderRow]()
        if let caimex = machine.caimex { rows.append(caimexRow(caimex, reachly: reachly)) }
        for server in LocalModelServer.allCases where machine.server(server).isFound {
            rows.append(localServerRow(server, facts: machine.server(server), reachly: reachly))
        }
        for key in EnvironmentAPIKey.allCases where machine.environmentKeys.contains(key) {
            rows.append(environmentKeyRow(key, reachly: reachly))
        }
        if let claudeCode = machine.claudeCode { rows.append(claudeCodeRow(claudeCode, reachly: reachly)) }
        if let desktop = machine.claudeDesktop { rows.append(claudeDesktopRow(desktop, reachly: reachly)) }
        if let qoder = machine.qoder { rows.append(qoderRow(qoder, reachly: reachly)) }
        if let openAI = machine.openAI, openAI.isFound { rows.append(openAIRow(openAI, reachly: reachly)) }
        return rows
    }

    static func caimexRow(_ caimex: AIProviderMachineFacts.Caimex, reachly: ReachlyAIState) -> AIProviderRow {
        guard caimex.hasStoredKey else {
            return AIProviderRow(
                id: .caimex, title: "Caimex CLI",
                detail: "Found, with no key stored in it.",
                status: .needsAction,
                actions: [.openLink(.caimexKeys)],
                note: "Sign in with `caimex auth login`, then click Check Again. Or paste a key from caimex.ai under API key.")
        }
        let inUse = reachly.kind == .caimex && reachly.hasKey
        return AIProviderRow(
            id: .caimex, title: "Caimex CLI",
            detail: inUse ? "A key is stored in the CLI. Caimex is selected in Reachly and has a key." : "A key is stored in the CLI.",
            status: inUse ? .inUse : .ready,
            actions: [.useCaimexKey],
            note: "The key is read only when you click Use Caimex Key.")
    }

    static func localServerRow(_ server: LocalModelServer, facts: AIProviderMachineFacts.LocalServer, reachly: ReachlyAIState) -> AIProviderRow {
        let selected = reachly.uses(server)
        let address = "127.0.0.1:\(server.port)"
        switch facts.state {
        case .running(let models):
            let chat = OpenAIModelList.chatModels(models)
            guard !chat.isEmpty else {
                return AIProviderRow(
                    id: server.rowID, title: server.displayName,
                    detail: "Server running on \(address), with no models.",
                    status: .needsAction,
                    note: "Download or load a model in \(server.displayName), then click Check Again.")
            }
            let count = chat.count == 1 ? "1 model" : "\(chat.count) models"
            if selected {
                return AIProviderRow(
                    id: server.rowID, title: server.displayName,
                    detail: "In use with \(reachly.model.isEmpty ? "no model set" : reachly.model). Server on \(address), \(count).",
                    status: .inUse,
                    actions: chat.count > 1 ? [.useLocalServer(server)] : [])
            }
            return AIProviderRow(
                id: server.rowID, title: server.displayName,
                detail: "Server running on \(address), \(count). No key needed.",
                status: .ready,
                actions: [.useLocalServer(server)])
        case .requiresKey:
            return AIProviderRow(
                id: server.rowID, title: server.displayName,
                detail: "Server running on \(address); it asks for an API key.",
                status: .needsAction,
                note: "Turn off the server's authentication, or select the OpenAI-compatible endpoint with base URL \(server.baseURL) and paste its key under API key.")
        case .notRunning:
            return AIProviderRow(
                id: server.rowID, title: server.displayName,
                detail: selected ? "Selected in Reachly, but the server isn't running." : "Installed. The server isn't running.",
                status: .needsAction,
                note: server.startInstructions)
        }
    }

    static func environmentKeyRow(_ key: EnvironmentAPIKey, reachly: ReachlyAIState) -> AIProviderRow {
        switch key {
        case .anthropic:
            return AIProviderRow(
                id: .anthropicEnvironmentKey, title: key.rawValue,
                detail: "Set in Reachly's environment. Use it for Anthropic (Claude).",
                status: .ready,
                actions: [.useEnvironmentKey(.anthropic)])
        case .openAI:
            return AIProviderRow(
                id: .openAIEnvironmentKey, title: key.rawValue,
                detail: "Set in Reachly's environment. Use it with the OpenAI API.",
                status: .ready,
                actions: [.useEnvironmentKey(.openAI)])
        }
    }

    static func claudeCodeRow(_ claudeCode: AIProviderMachineFacts.ClaudeCode, reachly: ReachlyAIState) -> AIProviderRow {
        guard claudeCode.isConnected else {
            return AIProviderRow(
                id: .claudeCode, title: "Claude Code",
                detail: "Found. Not connected to Reachly's MCP server.",
                status: .ready,
                actions: [.connectClaudeCode],
                note: "Connecting lets Claude Code use Reachly's hosts and tools. " + claudeSignInNote)
        }
        return connectedRow(id: .claudeCode, title: "Claude Code", client: "Claude Code", reachly: reachly, note: claudeSignInNote)
    }

    static func claudeDesktopRow(_ desktop: AIProviderMachineFacts.ClaudeDesktop, reachly: ReachlyAIState) -> AIProviderRow {
        switch desktop.config {
        case .connected(let command):
            if let command, command != reachly.bridgePath {
                return AIProviderRow(
                    id: .claudeDesktop, title: "Claude Desktop",
                    detail: "Connected to another copy of Reachly.",
                    status: .connected,
                    actions: reachly.mcpServerEnabled ? [] : [.turnOnMCPServer],
                    note: "Its reachly entry runs \(command). Reachly never changes an existing entry; edit claude_desktop_config.json to point it at this copy.")
            }
            return connectedRow(id: .claudeDesktop, title: "Claude Desktop", client: "Claude Desktop", reachly: reachly, note: claudeSignInNote)
        case .missing, .notConnected:
            return AIProviderRow(
                id: .claudeDesktop, title: "Claude Desktop",
                detail: "Installed. Not connected to Reachly's MCP server.",
                status: .ready,
                actions: [.connectClaudeDesktop],
                note: "Connecting lets Claude Desktop use Reachly's hosts and tools. " + claudeSignInNote)
        case .unreadable:
            return AIProviderRow(
                id: .claudeDesktop, title: "Claude Desktop",
                detail: "Its config file couldn't be read, so Reachly won't change it.",
                status: .needsAction,
                actions: [.copyClaudeDesktopSnippet],
                note: "Copy the config and add it to claude_desktop_config.json by hand. " + claudeSignInNote)
        }
    }

    static func qoderRow(_ qoder: AIProviderMachineFacts.Qoder, reachly: ReachlyAIState) -> AIProviderRow {
        let title = qoder.cliPath == nil ? "Qoder" : (qoder.appInstalled ? "Qoder and Qoder CLI" : "Qoder CLI")
        let note = "Qoder keeps its own sign-in; Reachly only offers it Reachly's tools over MCP."
        if case .connected = qoder.config {
            return connectedRow(id: .qoder, title: title, client: "Qoder", reachly: reachly, note: note)
        }
        let unreadable = qoder.config == .unreadable
        if qoder.cliPath != nil {
            return AIProviderRow(
                id: .qoder, title: title,
                detail: unreadable ? "Found. Its settings file couldn't be read." : "Found. Not connected to Reachly's MCP server.",
                status: .ready,
                actions: [.connectQoderCLI],
                note: note)
        }
        return AIProviderRow(
            id: .qoder, title: title,
            detail: unreadable ? "Installed. Its settings file couldn't be read." : "Installed. Not connected to Reachly's MCP server.",
            status: .ready,
            actions: [.showQoderAppSteps],
            note: "The Qoder CLI isn't installed, so Reachly is added in the Qoder app's settings. " + note)
    }

    static func openAIRow(_ apps: AIProviderMachineFacts.OpenAIApps, reachly: ReachlyAIState) -> AIProviderRow {
        let hasChatGPT = apps.chatGPTApp
        let hasCodex = apps.codexApp || apps.codexCLIPath != nil
        let title = hasChatGPT && hasCodex ? "ChatGPT and Codex" : (hasChatGPT ? "ChatGPT" : "Codex")
        if reachly.usesOpenAIAPI {
            return AIProviderRow(
                id: .openAI, title: title,
                detail: reachly.hasKey ? "The OpenAI API is selected in Reachly and has a key." : "The OpenAI API is selected in Reachly. Paste a key under API key.",
                status: reachly.hasKey ? .inUse : .needsAction,
                actions: reachly.hasKey ? [] : [.openLink(.openAIKeys)],
                note: openAISignInNote)
        }
        return AIProviderRow(
            id: .openAI, title: title,
            detail: "Installed. Its sign-in can't be used by Reachly.",
            status: .unavailable,
            actions: [.setUpOpenAIEndpoint, .openLink(.openAIKeys)],
            note: openAISignInNote)
    }

    /// A client whose config has Reachly. It only works while Reachly's MCP server is on.
    private static func connectedRow(id: AIProviderRow.ID, title: String, client: String, reachly: ReachlyAIState, note: String) -> AIProviderRow {
        guard reachly.mcpServerEnabled else {
            return AIProviderRow(
                id: id, title: title,
                detail: "Connected, but Reachly's MCP server is off.",
                status: .needsAction,
                actions: [.turnOnMCPServer],
                note: "\(client) can't reach Reachly until the MCP server is on. " + note)
        }
        return AIProviderRow(id: id, title: title, detail: "Connected to Reachly's MCP server.", status: .connected, note: note)
    }

    // MARK: Suggestions

    /// What can still be set up: an Anthropic key, Caimex, an OpenAI-compatible endpoint and local models,
    /// each left out once it is in use or found.
    public static func suggestions(machine: AIProviderMachineFacts, reachly: ReachlyAIState) -> [AIProviderSuggestion] {
        var suggestions = [AIProviderSuggestion]()
        if !(reachly.kind == .anthropic && reachly.hasKey) {
            suggestions.append(AIProviderSuggestion(
                id: .anthropicKey, title: "Anthropic API key",
                detail: "Chat with Claude in Reachly. Claude plan sign-ins can't be used by other apps, so this needs an API key from the Claude Console.",
                links: [.anthropicKeys], opensSettings: true))
        }
        if machine.caimex == nil, !(reachly.kind == .caimex && reachly.hasKey) {
            suggestions.append(AIProviderSuggestion(
                id: .caimexKey, title: "Caimex",
                detail: "One key for the models on the Caimex gateway, such as DeepSeek, Qwen and GLM.",
                links: [.caimexKeys], opensSettings: true))
        }
        let endpointInUse = reachly.kind == .openAICompatible
            && AIProviderReadiness.isUsable(LLMProviderConfiguration(kind: .openAICompatible, baseURL: reachly.baseURL), hasKey: reachly.hasKey)
        if !endpointInUse {
            suggestions.append(AIProviderSuggestion(
                id: .openAICompatible, title: "OpenAI-compatible endpoint",
                detail: "Any server that speaks the OpenAI chat completions API with tool calling: the OpenAI API, vLLM, llama.cpp or a server on your network.",
                links: [], opensSettings: true))
        }
        if !machine.lmStudio.isFound, !machine.ollama.isFound {
            suggestions.append(AIProviderSuggestion(
                id: .localModels, title: "Local models",
                detail: "Run models on this Mac with LM Studio or Ollama. Reachly finds their servers on 127.0.0.1, and they need no key.",
                links: [.lmStudio, .ollama], opensSettings: false))
        }
        return suggestions
    }

    // MARK: Prompts

    /// What the confirmation says, in full, before the action runs. Nil for a link or a copy, which change
    /// nothing. `home` shortens paths to `~`.
    public static func prompt(for action: AIProviderAction, machine: AIProviderMachineFacts, reachly: ReachlyAIState, home: String) -> AIProviderPrompt? {
        let serverNote = reachly.mcpServerEnabled ? "" : " Reachly's MCP server is turned on too, on 127.0.0.1:\(reachly.mcpPort)."
        switch action {
        case .useCaimexKey:
            let cli = machine.caimex?.cliPath ?? "caimex"
            return AIProviderPrompt(
                title: "Use the Caimex CLI's key?",
                message: "Reachly runs this command once to read the Caimex API key, saves the key in your login Keychain for Caimex, and selects Caimex as the provider. It replaces any Caimex key saved in Reachly. The rest of the command's output is discarded and nothing else is kept.",
                detail: MCPConnectCommand(executable: cli, arguments: ["auth", "export"]).displayString(home: home),
                confirmTitle: "Use Key")
        case .useLocalServer(let server):
            return AIProviderPrompt(
                title: "Use \(server.displayName)?",
                message: "Reachly selects the OpenAI-compatible endpoint at \(server.baseURL) with the model you pick. Chats go to \(server.displayName) on this Mac, and no key is needed. Your other providers and their keys stay as they are.",
                confirmTitle: "Use \(server.displayName)")
        case .connectClaudeCode:
            let cli = machine.claudeCode?.cliPath ?? "claude"
            return AIProviderPrompt(
                title: "Connect Claude Code to Reachly?",
                message: "Reachly runs this command, which adds Reachly's MCP server to Claude Code for your user account. Claude Code can then use Reachly's hosts and tools, with the same guardrails, approval sheet and audit log.\(serverNote)",
                detail: MCPConnectCommand.claudeCodeAdd(claude: cli, bridgePath: reachly.bridgePath).displayString(home: home),
                confirmTitle: "Connect")
        case .connectClaudeDesktop:
            let path = machine.claudeDesktop?.configPath ?? "~/Library/Application Support/Claude/claude_desktop_config.json"
            return AIProviderPrompt(
                title: "Connect Claude Desktop to Reachly?",
                message: "Reachly adds a reachly entry under mcpServers in Claude Desktop's config. Nothing else in the file changes, and a copy of the current file is saved next to it first. Restart Claude Desktop afterwards to load Reachly.\(serverNote)",
                detail: abbreviate(path, home: home),
                confirmTitle: "Connect")
        case .connectQoderCLI:
            let cli = machine.qoder?.cliPath ?? "qoder"
            return AIProviderPrompt(
                title: "Connect Qoder to Reachly?",
                message: "Reachly runs this command, which adds Reachly's MCP server to Qoder for your user account, in ~/.qoder/settings.json. Qoder can then use Reachly's hosts and tools, with the same guardrails, approval sheet and audit log.\(serverNote)",
                detail: MCPConnectCommand.qoderAdd(qoder: cli, bridgePath: reachly.bridgePath).displayString(home: home),
                confirmTitle: "Connect")
        case .showQoderAppSteps:
            var steps = [
                "Open Qoder, then Settings (⌘⇧,) › MCP.",
                "Click Add and choose STDIO.",
                "Name it reachly and paste the command below.",
                "Save. Qoder starts Reachly's bridge when it needs Reachly's tools.",
            ]
            if !reachly.mcpServerEnabled {
                steps.append("Turn on Reachly's MCP server under Settings › AI Integration › MCP server.")
            }
            return AIProviderPrompt(
                title: "Connect the Qoder app to Reachly",
                message: "The Qoder CLI isn't installed, so add Reachly in the Qoder app. Reachly doesn't change Qoder's settings itself.",
                steps: steps,
                detail: reachly.bridgePath,
                confirmTitle: nil)
        case .setUpOpenAIEndpoint:
            return AIProviderPrompt(
                title: "Set up the OpenAI API?",
                message: "ChatGPT and Codex sign-ins can't be used by other apps, so Reachly uses an OpenAI API key instead. Reachly selects the OpenAI-compatible endpoint at \(openAIBaseURL). Then paste an OpenAI API key under API key and type a model ID under Model.",
                confirmTitle: "Set Up")
        case .useEnvironmentKey(.anthropic):
            return AIProviderPrompt(
                title: "Use ANTHROPIC_API_KEY?",
                message: "Reachly saves the key from its environment in your login Keychain for Anthropic and selects Anthropic (Claude) as the provider. It replaces any Anthropic key saved in Reachly.",
                confirmTitle: "Use Key")
        case .useEnvironmentKey(.openAI):
            return AIProviderPrompt(
                title: "Use OPENAI_API_KEY?",
                message: "Reachly saves the key from its environment in your login Keychain for the OpenAI-compatible endpoint, selects that endpoint and points it at \(openAIBaseURL). It replaces any endpoint key saved in Reachly. Type a model ID under Model afterwards.",
                confirmTitle: "Use Key")
        case .turnOnMCPServer:
            return AIProviderPrompt(
                title: "Turn on Reachly's MCP server?",
                message: "Reachly listens on 127.0.0.1:\(reachly.mcpPort) with a bearer token, so connected clients can use its tools with the same guardrails and approval sheet. Turn it off any time under MCP server.",
                confirmTitle: "Turn On")
        case .copyClaudeDesktopSnippet, .openLink:
            return nil
        }
    }

    static func abbreviate(_ path: String, home: String) -> String {
        guard !home.isEmpty, path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }
}

extension LocalModelServer {
    var rowID: AIProviderRow.ID {
        switch self {
        case .lmStudio: .lmStudio
        case .ollama: .ollama
        }
    }
}
