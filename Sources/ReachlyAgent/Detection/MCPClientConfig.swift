import Foundation

/// Reachly's entry in an MCP client's JSON config, `mcpServers.reachly = {"command": <bridge>}`, as Claude
/// Desktop (`claude_desktop_config.json`) and Qoder (`~/.qoder/settings.json`) keep it.
public enum MCPClientConfig {
    public static let serverName = "reachly"

    /// What a config file says about Reachly.
    public enum State: Sendable, Equatable {
        /// There is no file yet.
        case missing
        /// A JSON object without `mcpServers.reachly`.
        case notConnected
        /// `mcpServers.reachly` exists; `command` is its command when it is a string.
        case connected(command: String?)
        /// Not a JSON object, or `mcpServers` is not an object. Reachly never writes such a file.
        case unreadable
    }

    /// The result of adding Reachly to a config.
    public enum Merge: Sendable, Equatable {
        /// The new file contents: the old object with `mcpServers.reachly` added and every other key kept.
        case added(Data)
        /// A `reachly` entry is already there. It is never modified or replaced.
        case alreadyPresent(command: String?)
        /// Not a JSON object, or `mcpServers` is not an object: nothing may be written.
        case unreadable
    }

    public static func state(of data: Data?) -> State {
        guard let data else { return .missing }
        switch parse(data) {
        case .none: return .unreadable
        case .some(let root):
            switch servers(in: root) {
            case .none: return .unreadable
            case .some(let servers):
                guard let entry = servers[serverName] else { return .notConnected }
                return .connected(command: (entry as? [String: Any])?["command"] as? String)
            }
        }
    }

    /// Adds `mcpServers.reachly = {"command": command}`. `existing` is nil when the file does not exist; an
    /// empty or blank file counts as an empty object, since there is nothing in it to lose.
    public static func merge(existing: Data?, command: String) -> Merge {
        var root: [String: Any]
        if let existing {
            guard let parsed = parse(existing) else { return .unreadable }
            root = parsed
        } else {
            root = [:]
        }
        guard var servers = servers(in: root) else { return .unreadable }
        if let entry = servers[serverName] {
            return .alreadyPresent(command: (entry as? [String: Any])?["command"] as? String)
        }
        servers[serverName] = ["command": command]
        root["mcpServers"] = servers
        guard var data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else {
            return .unreadable
        }
        data.append(UInt8(ascii: "\n"))
        return .added(data)
    }

    /// The top-level object; an empty or blank file is an empty object. Nil when it is anything else.
    private static func parse(_ data: Data) -> [String: Any]? {
        if data.allSatisfy({ [0x20, 0x09, 0x0A, 0x0D].contains($0) }) { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// `mcpServers`, or an empty object when the key is absent. Nil when it holds something other than an object.
    private static func servers(in root: [String: Any]) -> [String: Any]? {
        guard let value = root["mcpServers"] else { return [:] }
        return value as? [String: Any]
    }
}

/// Adds Reachly to an MCP client's config file on disk: the safe merge, a backup of the current file next to
/// it, then an atomic write that keeps the file's permissions. A symbolic link is followed, so the file it
/// points to is the one changed.
public struct MCPClientConfigFile: Sendable {
    public enum Outcome: Sendable, Equatable {
        /// Reachly was added. `backup` is the copy of the previous file, nil when there was none.
        case added(backup: URL?)
        case alreadyPresent(command: String?)
        case unreadable
    }

    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// `~/Library/Application Support/Claude/claude_desktop_config.json`.
    public static func claudeDesktop(home: URL) -> MCPClientConfigFile {
        MCPClientConfigFile(url: home.appending(path: "Library/Application Support/Claude/claude_desktop_config.json"))
    }

    /// `~/.qoder/settings.json`, where Qoder keeps user-scope MCP servers.
    public static func qoder(home: URL) -> MCPClientConfigFile {
        MCPClientConfigFile(url: home.appending(path: ".qoder/settings.json"))
    }

    /// Reads the file and says whether Reachly is in it. Never writes.
    public func state() -> MCPClientConfig.State {
        let target = url.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: target.path) else { return .missing }
        guard let data = try? Data(contentsOf: target) else { return .unreadable }
        return MCPClientConfig.state(of: data)
    }

    public func connect(command: String, now: Date = .now) throws -> Outcome {
        let fileManager = FileManager.default
        let target = url.resolvingSymlinksInPath()
        let existing: Data? = fileManager.fileExists(atPath: target.path) ? try Data(contentsOf: target) : nil
        switch MCPClientConfig.merge(existing: existing, command: command) {
        case .alreadyPresent(let command):
            return .alreadyPresent(command: command)
        case .unreadable:
            return .unreadable
        case .added(let data):
            var backup: URL?
            var permissions: NSNumber?
            if existing != nil {
                permissions = (try? fileManager.attributesOfItem(atPath: target.path))?[.posixPermissions] as? NSNumber
                let destination = Self.backupURL(for: target, at: now)
                try fileManager.copyItem(at: target, to: destination)
                backup = destination
            } else {
                try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            }
            try data.write(to: target, options: [.atomic])
            if let permissions {
                try? fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path)
            }
            return .added(backup: backup)
        }
    }

    /// `name.reachly-backup-20261126-101500.json` beside the file, with `-2`, `-3`… when that name is taken.
    static func backupURL(for file: URL, at date: Date) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: date)
        let directory = file.deletingLastPathComponent()
        let base = file.deletingPathExtension().lastPathComponent
        let ext = file.pathExtension
        var attempt = 1
        while true {
            let suffix = attempt == 1 ? "" : "-\(attempt)"
            let name = "\(base).reachly-backup-\(stamp)\(suffix)" + (ext.isEmpty ? "" : ".\(ext)")
            let candidate = directory.appending(path: name)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            attempt += 1
        }
    }
}
