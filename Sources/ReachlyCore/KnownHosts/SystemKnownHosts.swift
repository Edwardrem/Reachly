import Foundation

/// Servers this Mac already trusts in `~/.ssh/known_hosts`, offered in the
/// sidebar so they can be added to Reachly with their keys.
///
/// Parsing and filtering are pure (text in, values out) so they can be tested;
/// `load(sshDirectory:)` is the thin wrapper that reads the files. Nothing here
/// writes to `~/.ssh`.
///
/// Format: sshd(8), "SSH_KNOWN_HOSTS FILE FORMAT".
public enum SystemKnownHosts {
    /// Files larger than this are ignored rather than read.
    public static let maximumFileSize = 8 * 1024 * 1024
    /// At most this many servers are listed.
    public static let maximumServers = 3_000

    /// Code-hosting endpoints that accept SSH for Git but never give a shell.
    /// They are left out of the suggestions; this is the one list.
    public static let codeHostingHosts: Set<String> = [
        "github.com", "ssh.github.com",
        "gitlab.com", "altssh.gitlab.com",
        "bitbucket.org", "altssh.bitbucket.org",
        "ssh.dev.azure.com", "vs-ssh.visualstudio.com",
        "source.developers.google.com",
        "codeberg.org",
    ]

    // MARK: - Values

    /// A host and port as ssh records them: lowercased, port 22 unless bracketed.
    public struct Endpoint: Hashable, Sendable, CustomStringConvertible {
        public let host: String
        public let port: Int

        /// Trims and lowercases `host`, the way known_hosts and `KnownHostsStore` compare names.
        public init(host: String, port: Int = 22) {
            self.host = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            self.port = port
        }

        /// `host`, or `[host]:port` off port 22, as known_hosts writes it. Also the
        /// id a hidden suggestion is remembered by.
        public var description: String { port == 22 ? host : "[\(host)]:\(port)" }

        /// True for IPv4 and IPv6 literals.
        public var isIPAddress: Bool { SystemKnownHosts.isIPAddress(host) }
    }

    /// One host key from a known_hosts line.
    public struct Key: Hashable, Sendable {
        /// e.g. `ssh-ed25519`
        public let keyType: String
        /// `type base64`, the form `KnownHostsStore` keeps.
        public let publicKey: String
        public let fingerprintSHA256: String
    }

    /// One server: the names on its known_hosts lines and the keys ssh accepts for it.
    public struct Server: Hashable, Sendable, Identifiable {
        /// The name shown and used for the new host: the first name on the line
        /// that is not an IP address.
        public let endpoint: Endpoint
        /// Other names for the same server on its lines, such as its IP address.
        public let aliases: [Endpoint]
        /// Keys to carry into Reachly's store: those ssh would accept for
        /// `endpoint`, minus revoked keys and minus any key type listed with more
        /// than one key (Reachly keeps one key per type, and guessing wrong would
        /// show a changed-key warning instead of the first-connection prompt).
        public let keys: [Key]
        /// `User` from a `~/.ssh/config` Host block whose HostName is this server.
        public var configUser: String?

        public init(endpoint: Endpoint, aliases: [Endpoint] = [], keys: [Key], configUser: String? = nil) {
            self.endpoint = endpoint
            self.aliases = aliases
            self.keys = keys
            self.configUser = configUser
        }

        public var id: String { endpoint.description }
        public var hostname: String { endpoint.host }
        public var port: Int { endpoint.port }
        /// `endpoint` followed by `aliases`.
        public var names: [Endpoint] { [endpoint] + aliases }
    }

    /// Everything read from the files, before filtering against Reachly's hosts.
    public struct Scan: Hashable, Sendable {
        /// Named servers alphabetically, then servers known only by address.
        public var servers: [Server]
        /// Lines whose names are hashed (`HashKnownHosts yes`) and cannot be read back.
        public var hashedEntryCount: Int
        /// True when more than `maximumServers` were found and the rest were dropped.
        public var isTruncated: Bool

        public init(servers: [Server] = [], hashedEntryCount: Int = 0, isTruncated: Bool = false) {
            self.servers = servers
            self.hashedEntryCount = hashedEntryCount
            self.isTruncated = isTruncated
        }

        public static let empty = Scan()
    }

    /// What the sidebar lists.
    public struct Suggestions: Hashable, Sendable {
        public var servers: [Server]
        /// Servers the user hid that would otherwise be listed.
        public var hiddenCount: Int

        public init(servers: [Server] = [], hiddenCount: Int = 0) {
            self.servers = servers
            self.hiddenCount = hiddenCount
        }
    }

    // MARK: - Parsing

    /// Parses the text of known_hosts files, in the order ssh reads them (a
    /// `@revoked` line in any file applies to all). `config` supplies `User`
    /// for servers a `~/.ssh/config` Host block names.
    public static func parse(_ texts: [String], config: [SSHConfigHost] = [], maximumServers: Int = maximumServers) -> Scan {
        var entries: [Entry] = []
        var revoked: Set<String> = []
        var hashed = 0
        for text in texts {
            for rawLine in text.split(whereSeparator: \.isNewline) {
                switch parseLine(rawLine) {
                case .entry(let endpoints, let key): entries.append(Entry(endpoints: endpoints, key: key))
                case .hashed: hashed += 1
                case .revoked(let fingerprint): revoked.insert(fingerprint)
                case nil: continue
                }
            }
        }
        var scan = group(entries, revoked: revoked, maximumServers: maximumServers)
        scan.hashedEntryCount = hashed
        let users = configUsers(config)
        if !users.isEmpty {
            for index in scan.servers.indices {
                scan.servers[index].configUser = users[scan.servers[index].endpoint]
            }
        }
        return scan
    }

    private enum Line {
        case entry([Endpoint], Key)
        case hashed
        case revoked(fingerprint: String)
    }

    private struct Entry {
        let endpoints: [Endpoint]
        let key: Key
        /// The first name that is not an IP address, else the first name.
        let primary: Endpoint

        init(endpoints: [Endpoint], key: Key) {
            self.endpoints = endpoints
            self.key = key
            self.primary = endpoints.first { !$0.isIPAddress } ?? endpoints[0]
        }
    }

    /// `[@marker] patterns keytype base64 [comment]`
    private static func parseLine(_ raw: Substring) -> Line? {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
        var fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })[...]
        var marker: Substring?
        if let first = fields.first, first.hasPrefix("@") {
            marker = first
            fields = fields.dropFirst()
        }
        guard fields.count >= 3 else { return nil }
        let patterns = fields[fields.startIndex]
        guard let key = key(type: fields[fields.startIndex + 1], base64: fields[fields.startIndex + 2]) else { return nil }
        switch marker {
        case nil: break
        case "@revoked"?: return .revoked(fingerprint: key.fingerprintSHA256)
        default: return nil   // @cert-authority, or a marker this version does not know
        }
        var endpoints: [Endpoint] = []
        var sawHashed = false
        for pattern in patterns.split(separator: ",") {
            if pattern.hasPrefix("|") {
                sawHashed = true
            } else if let endpoint = endpoint(fromPattern: pattern), !endpoints.contains(endpoint) {
                endpoints.append(endpoint)
            }
        }
        if endpoints.isEmpty { return sawHashed ? .hashed : nil }
        return .entry(endpoints, key)
    }

    /// A key whose base64 decodes to a blob that names the same type, or nil.
    static func key(type: Substring, base64: Substring) -> Key? {
        let type = String(type)
        guard !type.isEmpty, type.count <= 64,
              type.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "@" || $0 == "." || $0 == "_") }),
              let blob = Data(base64Encoded: String(base64)),
              embeddedKeyType(blob) == type,
              let publicKey = HostKeyFingerprint.normalize(openSSHPublicKey: "\(type) \(base64)")
        else { return nil }
        return Key(keyType: type, publicKey: publicKey, fingerprintSHA256: HostKeyFingerprint.sha256(keyBlob: blob))
    }

    /// The type string an SSH wire-format key blob starts with.
    private static func embeddedKeyType(_ blob: Data) -> String? {
        guard blob.count > 4 else { return nil }
        let length = blob.prefix(4).reduce(0) { $0 << 8 | Int($1) }
        guard length > 0, length <= 64, blob.count >= 4 + length else { return nil }
        return String(bytes: blob.dropFirst(4).prefix(length), encoding: .utf8)
    }

    /// `host` (port 22), `[host]:port` or `[::1]:2222`. Nil for wildcards,
    /// negations and anything that is not a plain name or address.
    static func endpoint(fromPattern pattern: Substring) -> Endpoint? {
        guard !pattern.contains("*"), !pattern.contains("?"), !pattern.hasPrefix("!") else { return nil }
        var host = pattern
        var port = 22
        if pattern.hasPrefix("[") {
            guard let close = pattern.firstIndex(of: "]") else { return nil }
            host = pattern[pattern.index(after: pattern.startIndex)..<close]
            let rest = pattern[pattern.index(after: close)...]
            if !rest.isEmpty {
                guard rest.hasPrefix(":"), let parsed = Int(rest.dropFirst()), (1...65535).contains(parsed) else { return nil }
                port = parsed
            }
        }
        guard !host.isEmpty, host.allSatisfy(isHostCharacter) else { return nil }
        return Endpoint(host: String(host), port: port)
    }

    private static func isHostCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "-" || character == "." || character == "_"
            || character == ":" || character == "%"
    }

    static func isIPAddress(_ host: String) -> Bool {
        if host.contains(":") { return true }   // IPv6; host names cannot contain a colon
        var address = in_addr()
        return inet_pton(AF_INET, host, &address) == 1
    }

    /// One server per name: lines are grouped by their primary name, and a group
    /// whose names appear on a line of a group already listed is the same server
    /// (`example.com,203.0.113.5` then `203.0.113.5` lists only example.com).
    /// Named servers win over ones known only by address.
    private static func group(_ entries: [Entry], revoked: Set<String>, maximumServers: Int) -> Scan {
        var linesByEndpoint: [Endpoint: [Int]] = [:]
        var aliasesByPrimary: [Endpoint: [Endpoint]] = [:]
        var order: [Endpoint] = []
        for (index, entry) in entries.enumerated() {
            for endpoint in entry.endpoints {
                linesByEndpoint[endpoint, default: []].append(index)
            }
            if aliasesByPrimary[entry.primary] == nil {
                aliasesByPrimary[entry.primary] = []
                order.append(entry.primary)
            }
            for endpoint in entry.endpoints where endpoint != entry.primary && !aliasesByPrimary[entry.primary, default: []].contains(endpoint) {
                aliasesByPrimary[entry.primary, default: []].append(endpoint)
            }
        }

        var servers: [Server] = []
        var claimed: Set<Endpoint> = []
        var listed: Set<Endpoint> = []
        var truncated = false
        let ranked = order.filter { !$0.isIPAddress } + order.filter(\.isIPAddress)
        for primary in ranked {
            let aliases = aliasesByPrimary[primary] ?? []
            guard !claimed.contains(primary), !aliases.contains(where: listed.contains) else { continue }
            // Every key ssh would accept for this name, in file order.
            let candidates = (linesByEndpoint[primary] ?? []).map { entries[$0].key }.filter { !revoked.contains($0.fingerprintSHA256) }
            // Only revoked keys: ssh refuses this server, so it is not offered.
            guard !candidates.isEmpty else { continue }
            guard servers.count < maximumServers else {
                truncated = true
                break
            }
            claimed.insert(primary)
            claimed.formUnion(aliases)
            listed.insert(primary)
            servers.append(Server(endpoint: primary, aliases: aliases, keys: unambiguousKeys(candidates)))
        }
        servers.sort(by: displayOrder)
        return Scan(servers: servers, isTruncated: truncated)
    }

    /// One key per type, in first-seen order; a type listed with two different keys is dropped.
    private static func unambiguousKeys(_ keys: [Key]) -> [Key] {
        var byType: [String: Key] = [:]
        var conflicting: Set<String> = []
        var order: [String] = []
        for key in keys {
            if let existing = byType[key.keyType] {
                if existing.publicKey != key.publicKey { conflicting.insert(key.keyType) }
            } else {
                byType[key.keyType] = key
                order.append(key.keyType)
            }
        }
        return order.filter { !conflicting.contains($0) }.compactMap { byType[$0] }
    }

    private static func displayOrder(_ a: Server, _ b: Server) -> Bool {
        let aIsAddress = a.endpoint.isIPAddress, bIsAddress = b.endpoint.isIPAddress
        if aIsAddress != bIsAddress { return !aIsAddress }
        switch a.hostname.compare(b.hostname, options: [.numeric, .caseInsensitive]) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return a.port < b.port
        }
    }

    /// `User` by the endpoint a non-pattern Host block connects to (its HostName,
    /// else its alias); the first block wins, as in ssh.
    private static func configUsers(_ config: [SSHConfigHost]) -> [Endpoint: String] {
        var users: [Endpoint: String] = [:]
        for host in config where !host.isPattern {
            guard let user = host.user, !user.isEmpty else { continue }
            let endpoint = Endpoint(host: host.hostName ?? host.alias, port: host.port ?? 22)
            if users[endpoint] == nil { users[endpoint] = user }
        }
        return users
    }

    // MARK: - Filtering

    /// The servers to list: not a code-hosting endpoint, not already a host in
    /// Reachly under any of its names (same hostname, ignoring case, and port),
    /// and not hidden by the user. `hidden` holds `Server.id`s.
    public static func suggestions(
        from scan: Scan,
        existing: [Endpoint],
        hidden: Set<String>,
        excluding excludedHosts: Set<String> = codeHostingHosts
    ) -> Suggestions {
        let existing = Set(existing)
        var result = Suggestions()
        for server in scan.servers {
            guard !server.names.contains(where: { existing.contains($0) || excludedHosts.contains($0.host) }) else { continue }
            if hidden.contains(server.id) {
                result.hiddenCount += 1
            } else {
                result.servers.append(server)
            }
        }
        return result
    }

    // MARK: - Adding

    /// The host Add creates, with the defaults of the `~/.ssh/config` import:
    /// named after the server, its port, the `User` ssh would use (from a Host
    /// block that names the server, else the local account, as ssh defaults)
    /// and password authentication until a key is chosen.
    public static func makeHost(for server: Server, localUsername: String = NSUserName(), sortOrder: Int = 0) -> SSHHost {
        SSHHost(
            name: server.hostname,
            hostname: server.hostname,
            port: server.port,
            username: server.configUser ?? localUsername,
            authMethod: .password,
            sortOrder: sortOrder)
    }

    public struct TrustOutcome: Hashable, Sendable {
        /// Keys newly saved in Reachly's store.
        public var added = 0
        /// Keys Reachly already trusted.
        public var alreadyTrusted = 0
        /// Key types for which Reachly holds a different key; left as they are.
        public var leftDifferent = 0

        public init(added: Int = 0, alreadyTrusted: Int = 0, leftDifferent: Int = 0) {
            self.added = added
            self.alreadyTrusted = alreadyTrusted
            self.leftDifferent = leftDifferent
        }
    }

    /// Saves `keys` in Reachly's store for `hostname` and `port`, which must be the
    /// new host's own: a session asks the store about the host's `hostname` and
    /// `port` exactly as saved (see `TerminalSession.verifyHostKey`). A key type
    /// for which Reachly already saved a different key is not overwritten, so
    /// Reachly's changed-key prompt still decides.
    @discardableResult
    public static func trust(_ keys: [Key], hostname: String, port: Int, in store: KnownHostsStore) async throws -> TrustOutcome {
        var outcome = TrustOutcome()
        for key in keys {
            switch await store.verdict(host: hostname, port: port, keyType: key.keyType, publicKey: key.publicKey) {
            case .unknown:
                try await store.remember(host: hostname, port: port, keyType: key.keyType, publicKey: key.publicKey, fingerprintSHA256: key.fingerprintSHA256)
                outcome.added += 1
            case .known:
                outcome.alreadyTrusted += 1
            case .changed:
                outcome.leftDifferent += 1
            }
        }
        return outcome
    }

    // MARK: - Files

    public static var defaultSSHDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".ssh", directoryHint: .isDirectory)
    }

    /// `known_hosts` and `known_hosts2`, in the order ssh reads them.
    public static func knownHostsURLs(in sshDirectory: URL = defaultSSHDirectory) -> [URL] {
        [sshDirectory.appending(path: "known_hosts"), sshDirectory.appending(path: "known_hosts2")]
    }

    /// Size and modification date of a file a scan reads, so an unchanged set of
    /// files is not parsed again. Nil when the file is missing.
    public struct FileStamp: Hashable, Sendable {
        public let size: Int
        public let modified: Date
    }

    /// Stamps for the files `load` reads.
    public static func stamps(sshDirectory: URL = defaultSSHDirectory) -> [FileStamp?] {
        (knownHostsURLs(in: sshDirectory) + [sshDirectory.appending(path: "config")]).map { url in
            guard let values = try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize, let modified = values.contentModificationDate else { return nil }
            return FileStamp(size: size, modified: modified)
        }
    }

    /// Reads the known_hosts files and `~/.ssh/config` (for `User`) and parses
    /// them. Read only; missing, unreadable or oversized files are skipped.
    public static func load(sshDirectory: URL = defaultSSHDirectory) -> Scan {
        let texts = knownHostsURLs(in: sshDirectory).compactMap { readText(at: $0) }
        var config: [SSHConfigHost] = []
        if let text = readText(at: sshDirectory.appending(path: "config")) {
            config = SSHConfigFile.parse(text, include: SSHConfigFile.defaultIncludeResolver(sshDirectory: sshDirectory))
        }
        return parse(texts, config: config)
    }

    /// The text of a regular file of at most `limit` bytes, else nil. Never reads past the limit.
    static func readText(at url: URL, limit: Int = maximumFileSize) -> String? {
        let resolved = url.resolvingSymlinksInPath()
        guard let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, (values.fileSize ?? 0) <= limit,
              let handle = try? FileHandle(forReadingFrom: resolved) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: limit + 1) else { return nil }
        guard data.count <= limit else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
