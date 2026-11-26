import Foundation

/// A short preview of a saved API key, such as `sk-ant-…a1b2`, so Settings can show which key is stored
/// without reading it from the Keychain. It is made once, from the key being saved, and gives away at most
/// a format prefix and the last four characters.
public enum APIKeyHint {
    /// The prefix is looked for only in this many leading characters, so it stays a format marker such as
    /// `sk-ant-` or `sk-proj-` rather than a stretch of the secret.
    static let prefixWindow = 8
    /// A body (the key after its prefix) this long or longer shows its last four characters.
    static let longBodyLength = 16
    /// A shorter body shows its last two characters, and one shorter than this shows none.
    static let shortestPreviewedBody = 8

    /// The preview of `key`, or nil when the key is too short to preview without giving much of it away.
    /// Surrounding whitespace is ignored, as it is when the key is saved.
    public static func make(for key: String) -> String? {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        // The prefix runs up to the last `-` within the window: `sk-ant-api03-…` keeps `sk-ant-`.
        let prefix = key.prefix(prefixWindow).lastIndex(of: "-").map { String(key[...$0]) } ?? ""
        let body = key.dropFirst(prefix.count)
        if body.count >= longBodyLength {
            return prefix + "…" + body.suffix(4)
        }
        // A short key keeps no prefix, so the preview is never most of it.
        if body.count >= shortestPreviewedBody {
            return "…" + body.suffix(2)
        }
        return nil
    }
}

/// Where the previews live: UserDefaults, one entry per provider kind, never the Keychain and never the
/// key itself. A key saved before previews existed has none, and none is made for it later, because that
/// would mean reading the key.
public struct APIKeyHintStore {
    public static let defaultsKeyPrefix = "agent.keyHint."

    public static func defaultsKey(for kind: LLMProviderConfiguration.Kind) -> String {
        defaultsKeyPrefix + kind.rawValue
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The preview of the key saved for `kind`, or nil when none was recorded.
    public func hint(for kind: LLMProviderConfiguration.Kind) -> String? {
        defaults.string(forKey: Self.defaultsKey(for: kind))
    }

    /// Runs `write` (the Keychain write) and records the preview of `key` only once it returns. When it
    /// throws, the old preview stays, because the old key is still the one stored. A key too short to
    /// preview replaces the old preview with none.
    public func save(_ key: String, for kind: LLMProviderConfiguration.Kind, write: () throws -> Void) rethrows {
        try write()
        set(APIKeyHint.make(for: key), for: kind)
    }

    /// Runs `delete` (the Keychain delete) and forgets the preview only once it returns.
    public func remove(for kind: LLMProviderConfiguration.Kind, delete: () throws -> Void) rethrows {
        try delete()
        set(nil, for: kind)
    }

    /// The migration moved the key from one kind's account to another's, so the preview goes with it. The
    /// destination held no item, so whatever preview it had was stale.
    func move(from source: LLMProviderConfiguration.Kind, to destination: LLMProviderConfiguration.Kind) {
        set(hint(for: source), for: destination)
        set(nil, for: source)
    }

    /// The migration deleted this kind's item.
    func forget(_ kind: LLMProviderConfiguration.Kind) {
        set(nil, for: kind)
    }

    private func set(_ hint: String?, for kind: LLMProviderConfiguration.Kind) {
        if let hint {
            defaults.set(hint, forKey: Self.defaultsKey(for: kind))
        } else {
            defaults.removeObject(forKey: Self.defaultsKey(for: kind))
        }
    }
}
