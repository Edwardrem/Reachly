import Foundation
import Testing
@testable import ReachlyAgent

@Suite("Caimex CLI output")
struct CaimexCLIOutputTests {
    @Test func listWithAStoredKey() {
        #expect(CaimexCLIOutput.listShowsStoredKey("Caimex  API key                     stored\n"))
    }

    @Test func listAmongOtherIntegrationsAndColours() {
        let text = """
        INTEGRATION  LABEL      STATUS
        \u{1B}[1mGitHub\u{1B}[0m  token      stored
        \u{1B}[32mCaimex\u{1B}[0m  API key    \u{1B}[32mstored\u{1B}[0m
        """
        #expect(CaimexCLIOutput.listShowsStoredKey(text))
    }

    @Test func listWithoutACaimexKey() {
        #expect(!CaimexCLIOutput.listShowsStoredKey(""))
        #expect(!CaimexCLIOutput.listShowsStoredKey("No integrations yet. Run caimex auth login.\n"))
        #expect(!CaimexCLIOutput.listShowsStoredKey("GitHub  token  stored\n"))
        #expect(!CaimexCLIOutput.listShowsStoredKey("Caimex  API key  not stored\n"))
        #expect(!CaimexCLIOutput.listShowsStoredKey("Caimex  API key  missing\n"))
        // "caimex" must be the integration, not a word later in the line.
        #expect(!CaimexCLIOutput.listShowsStoredKey("GitHub  caimex mirror  stored\n"))
    }

    @Test func exportTakesTheActiveCaimexKey() throws {
        let json = """
        [
          {"id": "1", "integrationID": "github", "label": "token", "active": true, "value": {"type": "key", "key": "ghp-not-this"}},
          {"id": "2", "integrationID": "caimex", "label": "Old", "active": false, "value": {"type": "key", "key": "sk-old"}},
          {"id": "3", "integrationID": "Caimex", "label": "API key", "active": true, "value": {"type": "key", "key": " sk-active \\n"}}
        ]
        """
        let key = try #require(CaimexExportedKey.parse(Data(json.utf8)))
        #expect(key.key == "sk-active")
    }

    @Test func exportFallsBackToTheFirstCaimexKey() throws {
        let json = """
        [
          {"id": "1", "integrationID": "openrouter", "active": true, "value": {"type": "key", "key": "or-key"}},
          {"id": "2", "integrationID": "CAIMEX", "active": false, "value": {"type": "key", "key": "sk-first"}},
          {"id": "3", "integrationID": "caimex", "value": {"type": "key", "key": "sk-second"}}
        ]
        """
        #expect(CaimexExportedKey.parse(Data(json.utf8))?.key == "sk-first")
    }

    @Test func exportSkipsCaimexEntriesWithoutAKey() throws {
        let json = """
        [
          {"id": "1", "integrationID": "caimex", "active": true, "value": {"type": "oauth", "key": "not-a-key", "refresh": "r"}},
          {"id": "2", "integrationID": "caimex", "active": true, "value": {"type": "key", "key": "   "}},
          {"id": "3", "integrationID": "caimex", "active": false, "value": {"type": "key", "key": "sk-usable"}}
        ]
        """
        #expect(CaimexExportedKey.parse(Data(json.utf8))?.key == "sk-usable")
    }

    @Test func exportWithNothingUsable() {
        #expect(CaimexExportedKey.parse(Data()) == nil)
        #expect(CaimexExportedKey.parse(Data("[]".utf8)) == nil)
        #expect(CaimexExportedKey.parse(Data("not json".utf8)) == nil)
        #expect(CaimexExportedKey.parse(Data(#"{"integrationID": "caimex", "value": {"key": "sk-x"}}"#.utf8)) == nil)
        #expect(CaimexExportedKey.parse(Data(#"[{"integrationID": "github", "value": {"type": "key", "key": "k"}}]"#.utf8)) == nil)
        #expect(CaimexExportedKey.parse(Data(#"[{"integrationID": "caimex", "value": {"type": "key", "key": 42}}]"#.utf8)) == nil)
        #expect(CaimexExportedKey.parse(Data(#"[{"integrationID": "caimex", "value": "sk-flat"}]"#.utf8)) == nil)
    }

    @Test func exportSurroundedByOtherOutput() {
        let text = "Connecting to the background service…\n[{\"integrationID\": \"caimex\", \"active\": true, \"value\": {\"type\": \"key\", \"key\": \"sk-wrapped\"}}]\n"
        #expect(CaimexExportedKey.parse(Data(text.utf8))?.key == "sk-wrapped")
    }

    @Test func theKeyNeverShowsInDescriptions() {
        let key = CaimexExportedKey(key: "sk-secret-value-123")
        #expect(!String(describing: key).contains("sk-secret"))
        #expect(!String(reflecting: key).contains("sk-secret"))
        #expect(!"\(key)".contains("sk-secret"))
        var dumped = ""
        dump(key, to: &dumped)
        #expect(!dumped.contains("sk-secret"))
        #expect(Mirror(reflecting: key).children.isEmpty)
    }

    @Test func summariesDropEscapesAndStayShort() {
        let data = Data("\u{1B}[31mError:\u{1B}[0m   MCP server reachly\n already exists".utf8)
        #expect(TerminalText.summary(data) == "Error: MCP server reachly already exists")
        let long = Data(String(repeating: "word ", count: 200).utf8)
        let summary = TerminalText.summary(long, limit: 20)
        #expect(summary.count == 21)
        #expect(summary.hasSuffix("…"))
    }
}

@Suite("Local model servers")
struct LocalModelServerTests {
    @Test func modelIDsInOrderWithoutDuplicates() {
        let json = #"{"object": "list", "data": [{"id": "qwen3-8b", "object": "model"}, {"id": "llama3.2:latest"}, {"id": "qwen3-8b"}, {"id": ""}, {"object": "model"}, {"id": 7}]}"#
        #expect(OpenAIModelList.ids(from: Data(json.utf8)) == ["qwen3-8b", "llama3.2:latest"])
    }

    @Test func modelListShapes() {
        #expect(OpenAIModelList.ids(from: Data(#"{"data": []}"#.utf8)) == [])
        #expect(OpenAIModelList.ids(from: Data(#"{"models": [{"name": "llama3"}]}"#.utf8)) == nil)
        #expect(OpenAIModelList.ids(from: Data("[]".utf8)) == nil)
        #expect(OpenAIModelList.ids(from: Data("<html>LM Studio</html>".utf8)) == nil)
        #expect(OpenAIModelList.ids(from: Data()) == nil)
    }

    @Test func chatModelsLeaveEmbeddingsOut() {
        #expect(OpenAIModelList.chatModels(["text-embedding-nomic-embed-text-v1.5", "qwen3-8b"]) == ["qwen3-8b"])
        // A server with only embedding models still lists them rather than nothing.
        #expect(OpenAIModelList.chatModels(["nomic-embed-text"]) == ["nomic-embed-text"])
    }

    @Test func probeVerdicts() {
        let list = Data(#"{"data": [{"id": "m"}]}"#.utf8)
        #expect(LocalModelServerProbe.state(status: 200, body: list) == .running(models: ["m"]))
        #expect(LocalModelServerProbe.state(status: 200, body: Data("hello".utf8)) == .notRunning)
        #expect(LocalModelServerProbe.state(status: 401, body: Data()) == .requiresKey)
        #expect(LocalModelServerProbe.state(status: 403, body: Data()) == .requiresKey)
        #expect(LocalModelServerProbe.state(status: 404, body: list) == .notRunning)
        let huge = Data(count: LocalModelServerProbe.maximumBodyBytes + 1)
        #expect(LocalModelServerProbe.state(status: 200, body: huge) == .notRunning)
    }

    @Test func loopbackAddresses() {
        #expect(LocalModelServer.lmStudio.baseURL == "http://127.0.0.1:1234/v1")
        #expect(LocalModelServer.ollama.baseURL == "http://127.0.0.1:11434/v1")
        #expect(LocalModelServer.lmStudio.modelsURL.absoluteString == "http://127.0.0.1:1234/v1/models")
        #expect(LocalModelServer.lmStudio.matches(baseURL: "http://localhost:1234/v1"))
        #expect(LocalModelServer.lmStudio.matches(baseURL: " http://127.0.0.1:1234/v1/ "))
        #expect(LocalModelServer.ollama.matches(baseURL: "http://localhost:11434/v1"))
        #expect(!LocalModelServer.ollama.matches(baseURL: "http://localhost:1234/v1"))
        #expect(!LocalModelServer.lmStudio.matches(baseURL: "http://192.168.1.5:1234/v1"))
        #expect(!LocalModelServer.lmStudio.matches(baseURL: ""))
    }
}

@Suite("MCP connect commands")
struct MCPConnectCommandTests {
    private let bridge = "/Applications/Reachly.app/Contents/MacOS/reachly-mcp"

    @Test func claudeCodeAddIsAnArgumentArray() {
        let command = MCPConnectCommand.claudeCodeAdd(claude: "/Users/me/.local/bin/claude", bridgePath: bridge)
        #expect(command.executable == "/Users/me/.local/bin/claude")
        #expect(command.arguments == ["mcp", "add", "--scope", "user", "reachly", "--", bridge])
    }

    @Test func claudeCodeGet() {
        #expect(MCPConnectCommand.claudeCodeGet(claude: "/opt/homebrew/bin/claude").arguments == ["mcp", "get", "reachly"])
    }

    @Test func qoderAddIsAnArgumentArray() {
        let command = MCPConnectCommand.qoderAdd(qoder: "/usr/local/bin/qoder", bridgePath: bridge)
        #expect(command.arguments == ["mcp", "add", "-s", "user", "reachly", "--", bridge])
    }

    @Test func aPathWithSpacesStaysOneArgument() {
        let spaced = "/Users/me/Apps/Reachly Beta.app/Contents/MacOS/reachly-mcp"
        let command = MCPConnectCommand.claudeCodeAdd(claude: "/Users/me/.local/bin/claude", bridgePath: spaced)
        #expect(command.arguments.last == spaced)
        #expect(command.arguments.count == 7)
        #expect(command.displayString(home: "/Users/me") == "~/.local/bin/claude mcp add --scope user reachly -- '/Users/me/Apps/Reachly Beta.app/Contents/MacOS/reachly-mcp'")
    }

    @Test func displayQuotesOnlyWhatNeedsIt() {
        #expect(MCPConnectCommand.quoted("reachly") == "reachly")
        #expect(MCPConnectCommand.quoted("--scope") == "--scope")
        #expect(MCPConnectCommand.quoted("it's") == "'it'\\''s'")
        #expect(MCPConnectCommand.quoted("") == "''")
        #expect(MCPConnectCommand.quoted("$(rm -rf ~)") == "'$(rm -rf ~)'")
        let command = MCPConnectCommand.qoderAdd(qoder: "/usr/local/bin/qoder", bridgePath: bridge)
        #expect(command.displayString(home: "/Users/me") == "/usr/local/bin/qoder mcp add -s user reachly -- /Applications/Reachly.app/Contents/MacOS/reachly-mcp")
    }
}

@Suite("Provider locations")
struct AIProviderLocationsTests {
    private let home = "/Users/me"

    @Test func usualPlaces() {
        #expect(AIProviderLocations.candidates(for: .caimex, home: home) == ["/Users/me/.local/bin/caimex", "/opt/homebrew/bin/caimex", "/usr/local/bin/caimex"])
        #expect(AIProviderLocations.candidates(for: .lms, home: home).first == "/Users/me/.lmstudio/bin/lms")
        #expect(AIProviderLocations.candidates(for: .qoder, home: home).prefix(2) == ["/Users/me/.qoder/bin/qoder", "/Users/me/.qoder/bin/qodercli"])
        #expect(AIProviderLocations.candidates(for: .claude, home: home).contains("/Users/me/.local/bin/claude"))
        #expect(AIProviderLocations.candidates(forApp: .claudeDesktop, home: home) == ["/Applications/Claude.app", "/Users/me/Applications/Claude.app"])
    }

    @Test func firstExistingCandidate() {
        let present: Set<String> = ["/opt/homebrew/bin/caimex", "/usr/local/bin/caimex"]
        let found = AIProviderLocations.first(AIProviderLocations.candidates(for: .caimex, home: home), exists: present.contains)
        #expect(found == "/opt/homebrew/bin/caimex")
        #expect(AIProviderLocations.first(AIProviderLocations.candidates(for: .codex, home: home), exists: present.contains) == nil)
    }

    @Test func qoderEditorLauncherIsNotTheCLI() {
        // The Qoder editor can install a `qoder` shell command that points into its app bundle; it has no `mcp add`.
        let present: Set<String> = ["/usr/local/bin/qoder", "/opt/homebrew/bin/qodercli"]
        let resolve: (String) -> String = { $0 == "/usr/local/bin/qoder" ? "/Applications/Qoder.app/Contents/Resources/app/bin/qoder" : $0 }
        let found = AIProviderLocations.first(AIProviderLocations.candidates(for: .qoder, home: home), skipAppLaunchers: true, resolve: resolve, exists: present.contains)
        #expect(found == "/opt/homebrew/bin/qodercli")
    }

    @Test func environmentKeysArePresenceOnly() {
        let found = EnvironmentAPIKey.present(in: ["ANTHROPIC_API_KEY": "sk-ant-x", "OPENAI_API_KEY": "  ", "PATH": "/usr/bin"])
        #expect(found == [.anthropic])
        #expect(EnvironmentAPIKey.present(in: [:]).isEmpty)
    }
}
