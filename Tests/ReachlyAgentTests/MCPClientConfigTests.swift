import Foundation
import Testing
@testable import ReachlyAgent

@Suite("MCP client config merge")
struct MCPClientConfigTests {
    private let bridge = "/Applications/Reachly.app/Contents/MacOS/reachly-mcp"

    private func object(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func added(_ merge: MCPClientConfig.Merge) throws -> Data {
        guard case .added(let data) = merge else {
            Issue.record("expected .added, got \(merge)")
            throw CancellationError()
        }
        return data
    }

    @Test func noFileGivesJustReachly() throws {
        let root = try object(try added(MCPClientConfig.merge(existing: nil, command: bridge)))
        let servers = try #require(root["mcpServers"] as? [String: Any])
        #expect(root.count == 1)
        #expect((servers["reachly"] as? [String: Any])?["command"] as? String == bridge)
        #expect((servers["reachly"] as? [String: Any])?.count == 1)
    }

    @Test func blankFileCountsAsEmpty() throws {
        let root = try object(try added(MCPClientConfig.merge(existing: Data(" \n\t".utf8), command: bridge)))
        #expect((root["mcpServers"] as? [String: Any])?["reachly"] != nil)
    }

    @Test func everyOtherKeyIsKept() throws {
        let existing = """
        {
          "preferences": {"quickEntryShortcut": "off", "sidebarMode": "chat", "menuBarEnabled": false},
          "coworkUserFilesPath": "/Users/me/Claude Files",
          "globalShortcut": "",
          "count": 3,
          "ratio": 0.25,
          "mcpServers": {
            "github": {"command": "npx", "args": ["-y", "@modelcontextprotocol/server-github"], "env": {"GITHUB_TOKEN": "ghp-keep-me"}},
            "remote": {"url": "https://example.com/mcp"}
          }
        }
        """
        let root = try object(try added(MCPClientConfig.merge(existing: Data(existing.utf8), command: bridge)))
        let preferences = try #require(root["preferences"] as? [String: Any])
        #expect(preferences["quickEntryShortcut"] as? String == "off")
        #expect(preferences["sidebarMode"] as? String == "chat")
        #expect(preferences["menuBarEnabled"] as? Bool == false)
        #expect(root["coworkUserFilesPath"] as? String == "/Users/me/Claude Files")
        #expect(root["globalShortcut"] as? String == "")
        #expect(root["count"] as? Int == 3)
        #expect(root["ratio"] as? Double == 0.25)
        let servers = try #require(root["mcpServers"] as? [String: Any])
        #expect(servers.count == 3)
        let github = try #require(servers["github"] as? [String: Any])
        #expect(github["command"] as? String == "npx")
        #expect(github["args"] as? [String] == ["-y", "@modelcontextprotocol/server-github"])
        #expect((github["env"] as? [String: String])?["GITHUB_TOKEN"] == "ghp-keep-me")
        #expect((servers["remote"] as? [String: Any])?["url"] as? String == "https://example.com/mcp")
        #expect((servers["reachly"] as? [String: Any])?["command"] as? String == bridge)
    }

    @Test func slashesAreWrittenPlain() throws {
        let text = String(decoding: try added(MCPClientConfig.merge(existing: nil, command: bridge)), as: UTF8.self)
        #expect(text.contains(bridge))
        #expect(text.hasSuffix("\n"))
    }

    @Test func anExistingEntryIsNeverReplaced() {
        let other = #"{"mcpServers": {"reachly": {"command": "/Users/me/Old/Reachly.app/Contents/MacOS/reachly-mcp", "args": ["--x"]}}}"#
        #expect(MCPClientConfig.merge(existing: Data(other.utf8), command: bridge) == .alreadyPresent(command: "/Users/me/Old/Reachly.app/Contents/MacOS/reachly-mcp"))
        let odd = #"{"mcpServers": {"reachly": "something else"}}"#
        #expect(MCPClientConfig.merge(existing: Data(odd.utf8), command: bridge) == .alreadyPresent(command: nil))
    }

    @Test func notAnObjectIsNeverWritten() {
        #expect(MCPClientConfig.merge(existing: Data("[]".utf8), command: bridge) == .unreadable)
        #expect(MCPClientConfig.merge(existing: Data(#""text""#.utf8), command: bridge) == .unreadable)
        #expect(MCPClientConfig.merge(existing: Data("{\"mcpServers\": {".utf8), command: bridge) == .unreadable)
        #expect(MCPClientConfig.merge(existing: Data("// comment\n{}".utf8), command: bridge) == .unreadable)
        #expect(MCPClientConfig.merge(existing: Data(#"{"mcpServers": []}"#.utf8), command: bridge) == .unreadable)
        #expect(MCPClientConfig.merge(existing: Data(#"{"mcpServers": null}"#.utf8), command: bridge) == .unreadable)
        #expect(MCPClientConfig.merge(existing: Data([0xFF, 0xFE, 0x00]), command: bridge) == .unreadable)
    }

    @Test func states() {
        #expect(MCPClientConfig.state(of: nil) == .missing)
        #expect(MCPClientConfig.state(of: Data()) == .notConnected)
        #expect(MCPClientConfig.state(of: Data(#"{"preferences": {}}"#.utf8)) == .notConnected)
        #expect(MCPClientConfig.state(of: Data(#"{"mcpServers": {"atlassian": {}}}"#.utf8)) == .notConnected)
        #expect(MCPClientConfig.state(of: Data(#"{"mcpServers": {"reachly": {"command": "/x"}}}"#.utf8)) == .connected(command: "/x"))
        #expect(MCPClientConfig.state(of: Data("nope".utf8)) == .unreadable)
        #expect(MCPClientConfig.state(of: Data(#"{"mcpServers": 1}"#.utf8)) == .unreadable)
    }
}

@Suite("MCP client config file", .serialized)
struct MCPClientConfigFileTests {
    private let bridge = "/Applications/Reachly.app/Contents/MacOS/reachly-mcp"

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "reachly-mcp-config-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private func files(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    @Test func createsTheFileAndItsFolder() throws {
        try withDirectory { directory in
            let url = directory.appending(path: "Claude/claude_desktop_config.json")
            let file = MCPClientConfigFile(url: url)
            #expect(file.state() == .missing)
            let outcome = try file.connect(command: bridge)
            #expect(outcome == .added(backup: nil))
            #expect(file.state() == .connected(command: bridge))
            let names = try files(in: url.deletingLastPathComponent())
            #expect(names == ["claude_desktop_config.json"])
        }
    }

    @Test func backsUpThenWritesAndKeepsPermissions() throws {
        try withDirectory { directory in
            let url = directory.appending(path: "claude_desktop_config.json")
            let original = Data(#"{"preferences": {"menuBarEnabled": true}}"#.utf8)
            try original.write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)

            let date = Date(timeIntervalSince1970: 1_800_000_000)
            let outcome = try MCPClientConfigFile(url: url).connect(command: bridge, now: date)
            guard case .added(let backup?) = outcome else {
                Issue.record("expected a backup, got \(outcome)")
                return
            }
            #expect(backup.deletingLastPathComponent().standardizedFileURL == url.deletingLastPathComponent().standardizedFileURL)
            #expect(backup.lastPathComponent.hasPrefix("claude_desktop_config.reachly-backup-"))
            #expect(backup.pathExtension == "json")
            #expect(try Data(contentsOf: backup) == original)

            let written = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            #expect((written["preferences"] as? [String: Any])?["menuBarEnabled"] as? Bool == true)
            #expect(((written["mcpServers"] as? [String: Any])?["reachly"] as? [String: Any])?["command"] as? String == bridge)
            let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
            #expect(permissions?.intValue == 0o600)
        }
    }

    @Test func secondBackupInTheSameSecondGetsItsOwnName() throws {
        try withDirectory { directory in
            let url = directory.appending(path: "settings.json")
            let date = Date(timeIntervalSince1970: 1_800_000_000)
            try Data("{}".utf8).write(to: url)
            let first = MCPClientConfigFile.backupURL(for: url, at: date)
            try Data("{}".utf8).write(to: first)
            let second = MCPClientConfigFile.backupURL(for: url, at: date)
            #expect(first != second)
            #expect(second.lastPathComponent.hasSuffix("-2.json"))
        }
    }

    @Test func alreadyPresentLeavesTheFileAlone() throws {
        try withDirectory { directory in
            let url = directory.appending(path: "claude_desktop_config.json")
            let original = Data(#"{"mcpServers":{"reachly":{"command":"/elsewhere/reachly-mcp"}}}"#.utf8)
            try original.write(to: url)
            #expect(try MCPClientConfigFile(url: url).connect(command: bridge) == .alreadyPresent(command: "/elsewhere/reachly-mcp"))
            #expect(try Data(contentsOf: url) == original)
            #expect(try files(in: directory) == ["claude_desktop_config.json"])
        }
    }

    @Test func unreadableLeavesTheFileAlone() throws {
        try withDirectory { directory in
            let url = directory.appending(path: "claude_desktop_config.json")
            let original = Data("{ this is not json".utf8)
            try original.write(to: url)
            let file = MCPClientConfigFile(url: url)
            #expect(file.state() == .unreadable)
            #expect(try file.connect(command: bridge) == .unreadable)
            #expect(try Data(contentsOf: url) == original)
            #expect(try files(in: directory) == ["claude_desktop_config.json"])
        }
    }

    @Test func aSymbolicLinkIsFollowed() throws {
        try withDirectory { directory in
            let real = directory.appending(path: "dotfiles/claude_desktop_config.json")
            try FileManager.default.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: real)
            let link = directory.appending(path: "claude_desktop_config.json")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

            _ = try MCPClientConfigFile(url: link).connect(command: bridge)
            let attributes = try FileManager.default.attributesOfItem(atPath: link.path)
            #expect(attributes[.type] as? FileAttributeType == .typeSymbolicLink)
            #expect(MCPClientConfigFile(url: real).state() == .connected(command: bridge))
        }
    }
}

@Suite("Command runner")
struct CommandRunnerTests {
    @Test func capturesStandardOutputAndStatus() async throws {
        let output = try #require(await CommandRunner.run("/bin/sh", arguments: ["-c", "echo out; echo err >&2; exit 3"], timeout: 10))
        #expect(String(decoding: output.data, as: UTF8.self) == "out\n")
        #expect(output.exitStatus == 3)
        #expect(!output.timedOut)
        #expect(!output.succeeded)
    }

    @Test func canIncludeStandardError() async throws {
        let output = try #require(await CommandRunner.run("/bin/sh", arguments: ["-c", "echo out; echo err >&2"], timeout: 10, includeStandardError: true))
        let text = String(decoding: output.data, as: UTF8.self)
        #expect(text.contains("out"))
        #expect(text.contains("err"))
        #expect(output.succeeded)
    }

    @Test func argumentsAreNotShellWords() async throws {
        let output = try #require(await CommandRunner.run("/bin/echo", arguments: ["a b", "$(whoami)", "'q'"], timeout: 10))
        #expect(String(decoding: output.data, as: UTF8.self) == "a b $(whoami) 'q'\n")
    }

    @Test func aToolThatHangsIsStopped() async throws {
        let started = Date()
        let output = try #require(await CommandRunner.run("/bin/sleep", arguments: ["30"], timeout: 0.3))
        #expect(output.timedOut)
        #expect(!output.succeeded)
        // Well short of the 30 s sleep, with room for a loaded CI runner.
        #expect(Date().timeIntervalSince(started) < 15)
    }

    @Test func aTimeoutStopsEverythingTheToolStarted() async throws {
        // The shell starts a helper, prints its pid and waits: a timeout must stop the helper too.
        let output = try #require(await CommandRunner.run("/bin/sh", arguments: ["-c", "sleep 30 & echo $!; wait"], timeout: 0.5))
        #expect(output.timedOut)
        let helper = try #require(Int32(String(decoding: output.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        var gone = false
        for _ in 0..<40 {
            if kill(helper, 0) == -1, errno == ESRCH { gone = true; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        if !gone { kill(helper, SIGKILL) }
        #expect(gone, "the helper outlived the timeout")
    }

    @Test func aHelperThatIgnoresSIGTERMIsKilledToo() async throws {
        // The helper ignores SIGTERM; the shell exits on it. The helper must still not outlive the run.
        let output = try #require(await CommandRunner.run("/bin/sh", arguments: ["-c", "(trap '' TERM; exec sleep 30) & echo $!; wait"], timeout: 0.5))
        #expect(output.timedOut)
        let helper = try #require(Int32(String(decoding: output.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        var gone = false
        for _ in 0..<60 {
            if kill(helper, 0) == -1, errno == ESRCH { gone = true; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        if !gone { kill(helper, SIGKILL) }
        #expect(gone, "a helper that ignored SIGTERM outlived the timeout")
    }

    @Test func theToolLeadsItsOwnProcessGroup() async throws {
        let output = try #require(await CommandRunner.run("/bin/sh", arguments: ["-c", "if kill -0 -- -$$ 2>/dev/null; then echo leader; else echo member; fi"], timeout: 10))
        #expect(String(decoding: output.data, as: UTF8.self) == "leader\n")
    }

    @Test func theToolReadsNothingFromStandardInput() async throws {
        // cat waiting on an open stdin would run until the timeout.
        let output = try #require(await CommandRunner.run("/bin/cat", arguments: [], timeout: 10))
        #expect(!output.timedOut)
        #expect(output.succeeded)
        #expect(output.data.isEmpty)
    }

    @Test func aBackgroundChildHoldingThePipeDoesNotBlock() async throws {
        // Waiting for the helper's copy of the pipe to close would run past the timeout (the helper sleeps 20 s).
        let output = try #require(await CommandRunner.run("/bin/sh", arguments: ["-c", "sleep 20 & echo done"], timeout: 15))
        #expect(!output.timedOut)
        #expect(String(decoding: output.data, as: UTF8.self) == "done\n")
        #expect(output.exitStatus == 0)
    }

    @Test func outputIsCapped() async throws {
        let output = try #require(await CommandRunner.run("/bin/sh", arguments: ["-c", "head -c 200000 /dev/zero"], timeout: 10, outputLimit: 1000))
        #expect(output.data.count == 1000)
        #expect(output.truncated)
    }

    @Test func aMissingToolIsNil() async {
        #expect(await CommandRunner.run("/nonexistent/reachly-test-tool", arguments: [], timeout: 1) == nil)
    }

    @Test func environmentAndDirectoryAreUsed() async throws {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let output = try #require(await CommandRunner.run("/bin/sh", arguments: ["-c", "echo $REACHLY_TEST_VALUE; pwd -P"], timeout: 10, environment: ["REACHLY_TEST_VALUE": "hello", "PATH": "/usr/bin:/bin"], currentDirectory: directory))
        let lines = String(decoding: output.data, as: UTF8.self).split(separator: "\n").map(String.init)
        #expect(lines.first == "hello")
        // Foundation and `pwd -P` spell /private/var differently; compare both resolved the same way.
        #expect(lines.last.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } == directory.path)
    }
}
