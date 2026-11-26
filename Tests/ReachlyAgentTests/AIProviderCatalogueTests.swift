import Foundation
import Testing
@testable import ReachlyAgent

@Suite("AI provider rows")
struct AIProviderCatalogueTests {
    private let home = "/Users/me"
    private let bridge = "/Applications/Reachly.app/Contents/MacOS/reachly-mcp"

    private func reachly(_ kind: LLMProviderConfiguration.Kind = .anthropic, hasKey: Bool = false, baseURL: String = "", model: String = "", mcp: Bool = true) -> ReachlyAIState {
        ReachlyAIState(kind: kind, hasKey: hasKey, baseURL: baseURL, model: model, bridgePath: bridge, mcpServerEnabled: mcp, mcpPort: 7317)
    }

    private func row(_ id: AIProviderRow.ID, _ machine: AIProviderMachineFacts, _ state: ReachlyAIState? = nil) throws -> AIProviderRow {
        try #require(AIProviderCatalogue.rows(machine: machine, reachly: state ?? reachly()).first { $0.id == id })
    }

    /// Today's Mac: Caimex CLI with a key, LM Studio not running, Claude Code and Claude Desktop, the Qoder app, ChatGPT.
    private var thisMac: AIProviderMachineFacts {
        AIProviderMachineFacts(
            caimex: .init(cliPath: "/Users/me/.local/bin/caimex", hasStoredKey: true),
            lmStudio: .init(installed: true, state: .notRunning),
            claudeCode: .init(cliPath: "/Users/me/.local/bin/claude", isConnected: false),
            claudeDesktop: .init(configPath: "/Users/me/Library/Application Support/Claude/claude_desktop_config.json", config: .notConnected),
            qoder: .init(appInstalled: true, cliPath: nil, config: .notConnected),
            openAI: .init(chatGPTApp: true))
    }

    // MARK: Order and presence

    @Test func nothingFoundGivesNoRows() {
        #expect(AIProviderCatalogue.rows(machine: AIProviderMachineFacts(), reachly: reachly()).isEmpty)
    }

    @Test func thisMacsRowsInOrder() {
        let ids = AIProviderCatalogue.rows(machine: thisMac, reachly: reachly()).map(\.id)
        #expect(ids == [.caimex, .lmStudio, .claudeCode, .claudeDesktop, .qoder, .openAI])
    }

    @Test func everythingInOrder() {
        var machine = thisMac
        machine.ollama = .init(installed: false, state: .running(models: ["llama3.2"]))
        machine.environmentKeys = [.openAI, .anthropic]
        let ids = AIProviderCatalogue.rows(machine: machine, reachly: reachly()).map(\.id)
        #expect(ids == [.caimex, .lmStudio, .ollama, .anthropicEnvironmentKey, .openAIEnvironmentKey, .claudeCode, .claudeDesktop, .qoder, .openAI])
    }

    // MARK: Caimex

    @Test func caimexWithAStoredKey() throws {
        let caimex = try row(.caimex, thisMac)
        #expect(caimex.status == .ready)
        #expect(caimex.actions == [.useCaimexKey])
        #expect(caimex.note?.contains("only when you click") == true)
    }

    @Test func caimexInUse() throws {
        let caimex = try row(.caimex, thisMac, reachly(.caimex, hasKey: true))
        #expect(caimex.status == .inUse)
        #expect(caimex.actions == [.useCaimexKey])
    }

    @Test func caimexSelectedWithoutAKeyIsNotInUse() throws {
        #expect(try row(.caimex, thisMac, reachly(.caimex, hasKey: false)).status == .ready)
    }

    @Test func caimexCLIWithoutAKey() throws {
        var machine = thisMac
        machine.caimex = .init(cliPath: "/opt/homebrew/bin/caimex", hasStoredKey: false)
        let caimex = try row(.caimex, machine)
        #expect(caimex.status == .needsAction)
        #expect(!caimex.actions.contains(.useCaimexKey))
        #expect(caimex.actions == [.openLink(.caimexKeys)])
        #expect(caimex.note?.contains("caimex auth login") == true)
    }

    // MARK: Local servers

    @Test func lmStudioNotRunningSaysHowToStartIt() throws {
        let lm = try row(.lmStudio, thisMac)
        #expect(lm.status == .needsAction)
        #expect(lm.actions.isEmpty)
        #expect(lm.note?.contains("Developer") == true)
        #expect(lm.note?.contains("lms server start") == true)
    }

    @Test func ollamaNotRunningSaysHowToStartIt() throws {
        var machine = thisMac
        machine.ollama = .init(installed: true, state: .notRunning)
        #expect(try row(.ollama, machine).note?.contains("ollama serve") == true)
    }

    @Test func lmStudioRunning() throws {
        var machine = thisMac
        machine.lmStudio = .init(installed: true, state: .running(models: ["qwen3-8b", "text-embedding-nomic-embed-text-v1.5", "gemma-3-12b"]))
        let lm = try row(.lmStudio, machine)
        #expect(lm.status == .ready)
        #expect(lm.actions == [.useLocalServer(.lmStudio)])
        #expect(lm.detail.contains("127.0.0.1:1234"))
        #expect(lm.detail.contains("2 models"))
    }

    @Test func aServerAnsweringWithoutTheAppStillShows() throws {
        var machine = AIProviderMachineFacts()
        machine.ollama = .init(installed: false, state: .running(models: ["llama3.2:latest"]))
        let ollama = try row(.ollama, machine)
        #expect(ollama.detail.contains("1 model"))
        #expect(ollama.actions == [.useLocalServer(.ollama)])
    }

    @Test func lmStudioWithNoModels() throws {
        var machine = thisMac
        machine.lmStudio = .init(installed: true, state: .running(models: []))
        let lm = try row(.lmStudio, machine)
        #expect(lm.status == .needsAction)
        #expect(lm.actions.isEmpty)
    }

    @Test func lmStudioAskingForAKey() throws {
        var machine = thisMac
        machine.lmStudio = .init(installed: true, state: .requiresKey)
        let lm = try row(.lmStudio, machine)
        #expect(lm.status == .needsAction)
        #expect(lm.actions.isEmpty)
        #expect(lm.note?.contains("http://127.0.0.1:1234/v1") == true)
    }

    @Test func lmStudioInUse() throws {
        var machine = thisMac
        machine.lmStudio = .init(installed: true, state: .running(models: ["qwen3-8b", "gemma-3-12b"]))
        let lm = try row(.lmStudio, machine, reachly(.openAICompatible, baseURL: "http://localhost:1234/v1", model: "qwen3-8b"))
        #expect(lm.status == .inUse)
        #expect(lm.detail.contains("qwen3-8b"))
        // Several models: the button stays so another can be picked.
        #expect(lm.actions == [.useLocalServer(.lmStudio)])
    }

    @Test func lmStudioSelectedButStopped() throws {
        let lm = try row(.lmStudio, thisMac, reachly(.openAICompatible, baseURL: "http://127.0.0.1:1234/v1", model: "qwen3-8b"))
        #expect(lm.status == .needsAction)
        #expect(lm.detail.contains("Selected in Reachly"))
    }

    // MARK: Claude

    @Test func claudeCodeNotConnected() throws {
        let claude = try row(.claudeCode, thisMac)
        #expect(claude.status == .ready)
        #expect(claude.actions == [.connectClaudeCode])
        #expect(claude.note?.contains(AIProviderCatalogue.claudeSignInNote) == true)
    }

    @Test func claudeCodeConnected() throws {
        var machine = thisMac
        machine.claudeCode = .init(cliPath: "/Users/me/.local/bin/claude", isConnected: true)
        let claude = try row(.claudeCode, machine)
        #expect(claude.status == .connected)
        #expect(claude.actions.isEmpty)
        #expect(claude.note == AIProviderCatalogue.claudeSignInNote)
    }

    @Test func connectedWhileTheServerIsOff() throws {
        var machine = thisMac
        machine.claudeCode = .init(cliPath: "/Users/me/.local/bin/claude", isConnected: true)
        let claude = try row(.claudeCode, machine, reachly(mcp: false))
        #expect(claude.status == .needsAction)
        #expect(claude.actions == [.turnOnMCPServer])
    }

    @Test func claudeRowsNeverOfferToUseTheSignIn() {
        var machine = thisMac
        machine.claudeCode = .init(cliPath: "/Users/me/.local/bin/claude", isConnected: false)
        for state in [reachly(), reachly(.anthropic, hasKey: true), reachly(mcp: false)] {
            for claudeRow in AIProviderCatalogue.rows(machine: machine, reachly: state) where [.claudeCode, .claudeDesktop].contains(claudeRow.id) {
                #expect(claudeRow.status != .inUse)
                for action in claudeRow.actions {
                    #expect([.connectClaudeCode, .connectClaudeDesktop, .copyClaudeDesktopSnippet, .turnOnMCPServer].contains(action))
                }
                #expect(claudeRow.note?.contains("Claude plan sign-ins can't be used by other apps") == true)
            }
        }
    }

    @Test func claudeDesktopStates() throws {
        var machine = thisMac
        #expect(try row(.claudeDesktop, machine).actions == [.connectClaudeDesktop])

        machine.claudeDesktop?.config = .missing
        #expect(try row(.claudeDesktop, machine).actions == [.connectClaudeDesktop])

        machine.claudeDesktop?.config = .connected(command: bridge)
        let connected = try row(.claudeDesktop, machine)
        #expect(connected.status == .connected)
        #expect(connected.actions.isEmpty)

        machine.claudeDesktop?.config = .connected(command: "/Users/me/Old/Reachly.app/Contents/MacOS/reachly-mcp")
        let other = try row(.claudeDesktop, machine)
        #expect(other.detail.contains("another copy"))
        #expect(other.actions.isEmpty)
        #expect(other.note?.contains("/Users/me/Old/Reachly.app") == true)

        machine.claudeDesktop?.config = .unreadable
        let unreadable = try row(.claudeDesktop, machine)
        #expect(unreadable.status == .needsAction)
        #expect(unreadable.actions == [.copyClaudeDesktopSnippet])
    }

    // MARK: Qoder

    @Test func qoderAppOnlyShowsSteps() throws {
        let qoder = try row(.qoder, thisMac)
        #expect(qoder.title == "Qoder")
        #expect(qoder.actions == [.showQoderAppSteps])
    }

    @Test func qoderCLIConnectsItself() throws {
        var machine = thisMac
        machine.qoder = .init(appInstalled: true, cliPath: "/usr/local/bin/qoder", config: .notConnected)
        let qoder = try row(.qoder, machine)
        #expect(qoder.title == "Qoder and Qoder CLI")
        #expect(qoder.actions == [.connectQoderCLI])

        machine.qoder = .init(appInstalled: false, cliPath: "/usr/local/bin/qoder", config: .missing)
        #expect(try row(.qoder, machine).title == "Qoder CLI")
    }

    @Test func qoderConnected() throws {
        var machine = thisMac
        machine.qoder = .init(appInstalled: true, cliPath: nil, config: .connected(command: bridge))
        let qoder = try row(.qoder, machine)
        #expect(qoder.status == .connected)
        #expect(qoder.actions.isEmpty)
    }

    // MARK: ChatGPT and Codex

    @Test func chatGPTSignInIsNotUsed() throws {
        let openAI = try row(.openAI, thisMac)
        #expect(openAI.title == "ChatGPT")
        #expect(openAI.status == .unavailable)
        #expect(openAI.actions == [.setUpOpenAIEndpoint, .openLink(.openAIKeys)])
        #expect(openAI.note == AIProviderCatalogue.openAISignInNote)
    }

    @Test func codexTitles() throws {
        var machine = AIProviderMachineFacts()
        machine.openAI = .init(codexCLIPath: "/opt/homebrew/bin/codex")
        #expect(try row(.openAI, machine).title == "Codex")
        machine.openAI = .init(chatGPTApp: true, codexApp: true)
        #expect(try row(.openAI, machine).title == "ChatGPT and Codex")
        machine.openAI = .init()
        #expect(AIProviderCatalogue.rows(machine: machine, reachly: reachly()).isEmpty)
    }

    @Test func openAIAPIInUse() throws {
        let withKey = try row(.openAI, thisMac, reachly(.openAICompatible, hasKey: true, baseURL: "https://api.openai.com/v1"))
        #expect(withKey.status == .inUse)
        #expect(withKey.actions.isEmpty)
        let withoutKey = try row(.openAI, thisMac, reachly(.openAICompatible, hasKey: false, baseURL: "https://api.openai.com/v1"))
        #expect(withoutKey.status == .needsAction)
        #expect(withoutKey.actions == [.openLink(.openAIKeys)])
    }

    // MARK: Environment keys

    @Test func environmentKeys() throws {
        var machine = AIProviderMachineFacts()
        machine.environmentKeys = [.anthropic, .openAI]
        #expect(try row(.anthropicEnvironmentKey, machine).actions == [.useEnvironmentKey(.anthropic)])
        #expect(try row(.openAIEnvironmentKey, machine).actions == [.useEnvironmentKey(.openAI)])
        #expect(try row(.anthropicEnvironmentKey, machine).title == "ANTHROPIC_API_KEY")
    }

    // MARK: Suggestions

    @Test func suggestionsOnAnEmptyMac() {
        let ids = AIProviderCatalogue.suggestions(machine: AIProviderMachineFacts(), reachly: reachly()).map(\.id)
        #expect(ids == [.anthropicKey, .caimexKey, .openAICompatible, .localModels])
    }

    @Test func suggestionsOnThisMac() {
        // Caimex and LM Studio were found, so they are rows rather than suggestions.
        let ids = AIProviderCatalogue.suggestions(machine: thisMac, reachly: reachly()).map(\.id)
        #expect(ids == [.anthropicKey, .openAICompatible])
    }

    @Test func suggestionsDropWhatIsInUse() {
        #expect(!AIProviderCatalogue.suggestions(machine: AIProviderMachineFacts(), reachly: reachly(.anthropic, hasKey: true)).map(\.id).contains(.anthropicKey))
        #expect(!AIProviderCatalogue.suggestions(machine: AIProviderMachineFacts(), reachly: reachly(.caimex, hasKey: true)).map(\.id).contains(.caimexKey))
        #expect(!AIProviderCatalogue.suggestions(machine: AIProviderMachineFacts(), reachly: reachly(.openAICompatible, baseURL: "http://gpu.lan:8000/v1")).map(\.id).contains(.openAICompatible))
        #expect(AIProviderCatalogue.suggestions(machine: AIProviderMachineFacts(), reachly: reachly(.openAICompatible, baseURL: "")).map(\.id).contains(.openAICompatible))
    }

    @Test func suggestionLinks() throws {
        let suggestions = AIProviderCatalogue.suggestions(machine: AIProviderMachineFacts(), reachly: reachly())
        let anthropic = try #require(suggestions.first { $0.id == .anthropicKey })
        #expect(anthropic.links == [.anthropicKeys])
        #expect(anthropic.opensSettings)
        #expect(anthropic.detail.contains("Claude plan sign-ins can't be used by other apps"))
        #expect(AIProviderLink.anthropicKeys.url == LLMProviderConfiguration.Kind.anthropic.keyPageURL)
        #expect(AIProviderLink.caimexKeys.url == LLMProviderConfiguration.Kind.caimex.keyPageURL)
        #expect(AIProviderLink.openAIKeys.url.absoluteString == "https://platform.openai.com/api-keys")
        let local = try #require(suggestions.first { $0.id == .localModels })
        #expect(local.links == [.lmStudio, .ollama])
        #expect(!local.opensSettings)
    }

    // MARK: Prompts

    private func prompt(_ action: AIProviderAction, _ state: ReachlyAIState? = nil) -> AIProviderPrompt? {
        AIProviderCatalogue.prompt(for: action, machine: thisMac, reachly: state ?? reachly(), home: home)
    }

    @Test func everyChangeAsksFirst() {
        let changing: [AIProviderAction] = [
            .useCaimexKey, .useLocalServer(.lmStudio), .useLocalServer(.ollama), .connectClaudeCode, .connectClaudeDesktop,
            .connectQoderCLI, .setUpOpenAIEndpoint, .useEnvironmentKey(.anthropic), .useEnvironmentKey(.openAI), .turnOnMCPServer,
        ]
        for action in changing {
            let shown = prompt(action)
            #expect(shown?.confirmTitle != nil, "\(action) must be confirmed")
            #expect(shown?.message.isEmpty == false)
        }
        #expect(prompt(.openLink(.openAIKeys)) == nil)
        #expect(prompt(.copyClaudeDesktopSnippet) == nil)
    }

    @Test func caimexPromptNamesTheCommand() throws {
        let shown = try #require(prompt(.useCaimexKey))
        #expect(shown.detail == "~/.local/bin/caimex auth export")
        #expect(shown.message.contains("Keychain"))
        #expect(shown.message.contains("discarded"))
    }

    @Test func connectPromptsShowTheExactCommand() throws {
        let claude = try #require(prompt(.connectClaudeCode))
        #expect(claude.detail == "~/.local/bin/claude mcp add --scope user reachly -- /Applications/Reachly.app/Contents/MacOS/reachly-mcp")
        var machine = thisMac
        machine.qoder = .init(appInstalled: true, cliPath: "/usr/local/bin/qoder", config: .notConnected)
        let qoder = try #require(AIProviderCatalogue.prompt(for: .connectQoderCLI, machine: machine, reachly: reachly(), home: home))
        #expect(qoder.detail == "/usr/local/bin/qoder mcp add -s user reachly -- /Applications/Reachly.app/Contents/MacOS/reachly-mcp")
    }

    @Test func connectPromptsSayTheServerTurnsOn() throws {
        #expect(try #require(prompt(.connectClaudeCode, reachly(mcp: false))).message.contains("turned on too"))
        #expect(try #require(prompt(.connectClaudeCode, reachly(mcp: true))).message.contains("turned on too") == false)
        #expect(try #require(prompt(.connectClaudeDesktop, reachly(mcp: false))).message.contains("127.0.0.1:7317"))
    }

    @Test func claudeDesktopPromptPromisesABackupAndARestart() throws {
        let shown = try #require(prompt(.connectClaudeDesktop))
        #expect(shown.detail == "~/Library/Application Support/Claude/claude_desktop_config.json")
        #expect(shown.message.contains("copy of the current file"))
        #expect(shown.message.contains("Restart Claude Desktop"))
    }

    @Test func qoderAppStepsInform() throws {
        let shown = try #require(prompt(.showQoderAppSteps))
        #expect(shown.confirmTitle == nil)
        #expect(shown.detail == bridge)
        #expect(shown.steps.first?.contains("⌘⇧,") == true)
        #expect(shown.steps.contains { $0.contains("STDIO") })
        #expect(try #require(prompt(.showQoderAppSteps, reachly(mcp: false))).steps.last?.contains("MCP server") == true)
    }

    @Test func openAIPromptExplainsTheSignIn() throws {
        let shown = try #require(prompt(.setUpOpenAIEndpoint))
        #expect(shown.message.contains("https://api.openai.com/v1"))
        #expect(shown.message.contains("can't be used by other apps"))
    }

    // MARK: Readiness

    @Test func readiness() {
        #expect(!AIProviderReadiness.isUsable(LLMProviderConfiguration(kind: .anthropic), hasKey: false))
        #expect(AIProviderReadiness.isUsable(LLMProviderConfiguration(kind: .anthropic), hasKey: true))
        #expect(!AIProviderReadiness.isUsable(LLMProviderConfiguration(kind: .caimex), hasKey: false))
        #expect(AIProviderReadiness.isUsable(LLMProviderConfiguration(kind: .caimex), hasKey: true))
        #expect(!AIProviderReadiness.isUsable(LLMProviderConfiguration(kind: .openAICompatible, baseURL: ""), hasKey: false))
        #expect(!AIProviderReadiness.isUsable(LLMProviderConfiguration(kind: .openAICompatible, baseURL: "   "), hasKey: true))
        #expect(!AIProviderReadiness.isUsable(LLMProviderConfiguration(kind: .openAICompatible, baseURL: "localhost"), hasKey: false))
        // A local server needs no key.
        #expect(AIProviderReadiness.isUsable(LLMProviderConfiguration(kind: .openAICompatible, baseURL: "http://127.0.0.1:1234/v1"), hasKey: false))
    }

    @Test func setupShowsOnceAndOnlyWhenNothingWorks() {
        let fresh = LLMProviderConfiguration()
        #expect(AIProviderReadiness.shouldOfferSetup(alreadyDone: false, configuration: fresh, hasKey: false))
        #expect(!AIProviderReadiness.shouldOfferSetup(alreadyDone: true, configuration: fresh, hasKey: false))
        // An upgrade with a working provider never sees it.
        #expect(!AIProviderReadiness.shouldOfferSetup(alreadyDone: false, configuration: fresh, hasKey: true))
        #expect(!AIProviderReadiness.shouldOfferSetup(alreadyDone: false, configuration: LLMProviderConfiguration(kind: .openAICompatible, baseURL: "http://localhost:11434/v1"), hasKey: false))
    }
}
