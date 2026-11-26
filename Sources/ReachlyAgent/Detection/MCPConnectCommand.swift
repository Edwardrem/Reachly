import Foundation

/// Whether the bridge's path can go into another app's config. A path on a disk image or in a translocated
/// copy stops existing, and the client could then no longer start Reachly.
public enum MCPBridgeLocation {
    public static func problem(bridgePath: String) -> String? {
        if bridgePath.contains("/AppTranslocation/") {
            return "macOS is running Reachly from a temporary copy, so other apps couldn't start it later. Move Reachly to Applications first."
        }
        if bridgePath.hasPrefix("/Volumes/") {
            return "Reachly is running from a disk image, so other apps couldn't start it once the image is ejected. Move Reachly to Applications first."
        }
        return nil
    }
}

/// A command-line call Reachly runs for a provider: an MCP client's `mcp add` or `mcp get`, or the Caimex CLI's
/// export. Always an executable and an argument array, never a shell string.
public struct MCPConnectCommand: Sendable, Equatable {
    public let executable: String
    public let arguments: [String]

    public init(executable: String, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }

    /// `claude mcp add --scope user reachly -- <bridge>`: Reachly for every Claude Code project of this user.
    public static func claudeCodeAdd(claude: String, bridgePath: String) -> MCPConnectCommand {
        MCPConnectCommand(executable: claude, arguments: ["mcp", "add", "--scope", "user", MCPClientConfig.serverName, "--", bridgePath])
    }

    /// `claude mcp get reachly`: exits 0 when Claude Code has a server of that name.
    public static func claudeCodeGet(claude: String) -> MCPConnectCommand {
        MCPConnectCommand(executable: claude, arguments: ["mcp", "get", MCPClientConfig.serverName])
    }

    /// `qoder mcp add -s user reachly -- <bridge>`: writes Reachly into `~/.qoder/settings.json`.
    public static func qoderAdd(qoder: String, bridgePath: String) -> MCPConnectCommand {
        MCPConnectCommand(executable: qoder, arguments: ["mcp", "add", "-s", "user", MCPClientConfig.serverName, "--", bridgePath])
    }

    /// The command as it would be typed in Terminal, with each word quoted where needed and the home folder
    /// shown as `~` in the executable's path. For showing only; it is never run through a shell.
    public func displayString(home: String? = nil) -> String {
        var shownExecutable = executable
        if let home, !home.isEmpty, executable.hasPrefix(home + "/") {
            shownExecutable = "~" + executable.dropFirst(home.count)
        }
        let words = [shownExecutable.hasPrefix("~/") ? "~/" + Self.quoted(String(shownExecutable.dropFirst(2))) : Self.quoted(shownExecutable)]
            + arguments.map(Self.quoted)
        return words.joined(separator: " ")
    }

    /// The word unchanged when it holds only safe characters, otherwise in single quotes.
    static func quoted(_ word: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./=:@%+,")
        if !word.isEmpty, word.unicodeScalars.allSatisfy(safe.contains) { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
