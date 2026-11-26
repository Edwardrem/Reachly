import Foundation

/// The agent session each conversation last used, so a conversation reopened after the agent restarted can
/// ask for it back with `session/load`, when the agent offers that. A small JSON file of ids only: no message
/// text, and nothing of the agent's sign-in.
public struct ACPSessionStore: Sendable {
    public let url: URL
    /// The most conversations remembered; the oldest go first.
    public static let limit = 500

    public init(url: URL) {
        self.url = url
    }

    /// A conversation's session, and the last of the conversation's messages it was sent.
    public struct Saved: Sendable, Equatable {
        public var session: String
        /// Nil for an entry saved before Reachly kept it, which is then never loaded for a later turn.
        public var lastMessage: UUID?
    }

    private struct Entry: Codable {
        var conversation: String
        var session: String
        var lastMessage: UUID?
        var savedAt: Date
    }

    public func saved(for conversation: String) -> Saved? {
        load().last { $0.conversation == conversation }.map { Saved(session: $0.session, lastMessage: $0.lastMessage) }
    }

    public func sessionID(for conversation: String) -> String? {
        saved(for: conversation)?.session
    }

    /// Remembers `session` for the conversation, having been sent `lastMessage`; nil forgets it.
    public func set(_ session: String?, for conversation: String, lastMessage: UUID? = nil) {
        var entries = load().filter { $0.conversation != conversation }
        if let session {
            entries.append(Entry(conversation: conversation, session: session, lastMessage: lastMessage, savedAt: .now))
        }
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
        save(entries)
    }

    private func load() -> [Entry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Entry].self, from: data)) ?? []
    }

    private func save(_ entries: [Entry]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
