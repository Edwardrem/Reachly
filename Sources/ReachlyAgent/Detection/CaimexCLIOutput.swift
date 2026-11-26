import Foundation

/// What the Caimex CLI prints, read without keeping more than Reachly needs.
public enum CaimexCLIOutput {
    /// True when `caimex auth list` shows a stored Caimex credential. The list prints no secrets, one row per
    /// credential, such as `Caimex  API key                     stored`.
    public static func listShowsStoredKey(_ text: String) -> Bool {
        for line in TerminalText.stripEscapes(text).split(whereSeparator: \.isNewline) {
            let words = line.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
            guard words.first == "caimex" else { continue }
            if words.contains("stored"), !words.contains("not") { return true }
        }
        return false
    }
}

/// The Caimex API key from `caimex auth export`, which prints every stored credential, secrets included, as a
/// JSON array. Only the key is kept; it never appears in a description, a mirror or an error.
public struct CaimexExportedKey: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let key: String

    public init(key: String) {
        self.key = key
    }

    public var description: String { "CaimexExportedKey(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }

    /// The active Caimex key (integration id compared without case), else the first Caimex key, else nil.
    /// Other integrations in the array are ignored. Nil for empty, malformed or key-less output.
    public static func parse(_ data: Data) -> CaimexExportedKey? {
        guard let entries = jsonArray(data) else { return nil }
        var first: String?
        for case let entry as [String: Any] in entries {
            guard let integration = entry["integrationID"] as? String,
                  integration.trimmingCharacters(in: .whitespaces).lowercased() == "caimex",
                  let value = entry["value"] as? [String: Any],
                  let raw = value["key"] as? String else { continue }
            // A credential of another type (an OAuth sign-in, say) carries no API key.
            if let type = value["type"] as? String, type.lowercased() != "key" { continue }
            let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            if entry["active"] as? Bool == true { return CaimexExportedKey(key: key) }
            if first == nil { first = key }
        }
        return first.map(CaimexExportedKey.init(key:))
    }

    /// The array itself, or the part from the first `[` to the last `]` when the CLI printed a line around it.
    private static func jsonArray(_ data: Data) -> [Any]? {
        if let array = try? JSONSerialization.jsonObject(with: data) as? [Any] { return array }
        guard let open = data.firstIndex(of: UInt8(ascii: "[")),
              let close = data.lastIndex(of: UInt8(ascii: "]")), open < close else { return nil }
        return try? JSONSerialization.jsonObject(with: data[open...close]) as? [Any]
    }
}

/// Command output as plain text: ANSI colour and cursor sequences removed.
public enum TerminalText {
    /// CSI sequences (colours, cursor moves), OSC sequences (titles, links) and two-character escapes.
    private static let escape = try! NSRegularExpression(pattern: "\u{1B}(?:\\[[0-9;?]*[ -/]*[@-~]|\\][^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\\\)|[@-_])")

    public static func stripEscapes(_ text: String) -> String {
        guard text.contains("\u{1B}") else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return escape.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }

    /// One short paragraph from a tool's output, for showing under a row: escapes removed, whitespace
    /// collapsed, at most `limit` characters.
    public static func summary(_ data: Data, limit: Int = 300) -> String {
        let text = stripEscapes(String(decoding: data.prefix(16_384), as: UTF8.self))
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit)) + "…"
    }
}
