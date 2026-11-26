import Foundation

// CONTRACT (stream reachly-files-core implements this; the signatures are fixed).

/// Names for new, copied and renamed files, the same on the Mac and on a host.
///
/// Names that differ only in letter case count as the same name when looking for a free one: the Mac's disks are
/// usually case-insensitive, so "Report.txt" and "report.txt" can't sit side by side there. On a case-sensitive host
/// this only costs an unneeded "copy" or number, never an overwrite.
public enum FileNaming {
    /// The longest name, in UTF-8 bytes, that APFS and common Linux file systems accept.
    static let maximumNameBytes = 255

    /// nil when `name` can be used as one file or folder name; otherwise a short reason to show the user.
    public static func validationError(for name: String) -> String? {
        if name.allSatisfy(\.isWhitespace) { return "Enter a name." }
        return pathComponentError(for: name)
    }

    /// nil when `name` stands for exactly one item in a folder, so joining it to the folder's path stays in that
    /// folder; otherwise a short reason. Use it for names a host or a folder listing supplies: unlike
    /// `validationError`, a name of only spaces passes, as it is unusual but harmless.
    public static func pathComponentError(for name: String) -> String? {
        if name.isEmpty { return "The name is empty." }
        if name == "." || name == ".." { return "“.” and “..” can't be used as names." }
        if name.contains("/") { return "Names can't contain a slash." }
        if name.unicodeScalars.contains("\0") { return "Names can't contain a null character." }
        if name.utf8.count > maximumNameBytes { return "That name is too long." }
        return nil
    }

    /// `name` as a message can show it: control characters (a null among them) become "�", and a long name is
    /// shortened with "…".
    public static func displayed(_ name: String) -> String {
        var shown = String(String.UnicodeScalarView(name.unicodeScalars.map { $0.properties.generalCategory == .control ? "\u{FFFD}" : $0 }))
        if shown.count > 60 { shown = String(shown.prefix(60)) + "…" }
        return shown
    }

    /// The Finder-style name for a copy that is not in `existing`: "report copy.txt", then "report copy 2.txt", …
    public static func copyName(for name: String, isDirectory: Bool, existing: Set<String>) -> String {
        let (stem, pathExtension) = split(name, isDirectory: isDirectory)
        let base = removingCopySuffix(stem)
        let taken = folded(existing)
        var number = 1
        while true {
            let suffix = number == 1 ? " copy" : " copy \(number)"
            let candidate = fitted(base, suffix: suffix, pathExtension: pathExtension)
            if !taken.contains(fold(candidate)) { return candidate }
            number += 1
        }
    }

    /// `base` when it is free, otherwise "base 2", "base 3", … keeping any extension ("untitled 2.txt").
    public static func uniqueName(_ base: String, existing: Set<String>) -> String {
        uniqueName(base, isDirectory: false, existing: existing)
    }

    /// `uniqueName(_:existing:)`, but a folder's name is never split at a dot ("photos.2024 2", not "photos 2.2024").
    static func uniqueName(_ base: String, isDirectory: Bool, existing: Set<String>) -> String {
        let taken = folded(existing)
        if !taken.contains(fold(base)) { return base }
        let (stem, pathExtension) = split(base, isDirectory: isDirectory)
        var number = 2
        while true {
            let candidate = fitted(stem, suffix: " \(number)", pathExtension: pathExtension)
            if !taken.contains(fold(candidate)) { return candidate }
            number += 1
        }
    }

    // MARK: Helpers

    /// Compound extensions kept whole, so "archive.tar.gz" becomes "archive copy.tar.gz".
    private static let compoundPrefix = "tar"

    /// Splits "report.txt" into ("report", ".txt"). Folders, dotfiles (".env"), names ending in a dot and
    /// extensions with spaces in them have no extension. "archive.tar.gz" keeps ".tar.gz" together.
    static func split(_ name: String, isDirectory: Bool) -> (stem: String, pathExtension: String) {
        guard !isDirectory, let dot = extensionDot(in: name, before: name.endIndex) else { return (name, "") }
        var start = dot
        if let previous = extensionDot(in: name, before: dot), name[name.index(after: previous)..<dot].lowercased() == compoundPrefix {
            start = previous
        }
        return (String(name[..<start]), String(name[start...]))
    }

    /// The last dot before `end` that starts an extension: something non-empty without spaces after it, and
    /// something other than dots before it.
    private static func extensionDot(in name: String, before end: String.Index) -> String.Index? {
        guard let dot = name[..<end].lastIndex(of: ".") else { return nil }
        let after = name[name.index(after: dot)..<end]
        let before = name[..<dot]
        guard !after.isEmpty, !after.contains(where: \.isWhitespace), before.contains(where: { $0 != "." }) else { return nil }
        return dot
    }

    /// "report copy" and "report copy 3" become "report", so a copy of a copy doesn't read "report copy copy".
    static func removingCopySuffix(_ stem: String) -> String {
        if stem.hasSuffix(" copy"), stem.count > " copy".count {
            return String(stem.dropLast(" copy".count))
        }
        guard let range = stem.range(of: " copy ", options: .backwards) else { return stem }
        let number = stem[range.upperBound...]
        guard number.allSatisfy({ $0.isASCII && $0.isNumber }), number.first != "0", let value = Int(number), value >= 2,
              range.lowerBound > stem.startIndex else {
            return stem
        }
        return String(stem[..<range.lowerBound])
    }

    /// `stem + suffix + pathExtension`, with the stem shortened (whole characters only) when the result would be
    /// longer than a file system allows.
    private static func fitted(_ stem: String, suffix: String, pathExtension: String) -> String {
        var stem = stem
        var pathExtension = pathExtension
        if suffix.utf8.count + pathExtension.utf8.count >= maximumNameBytes {
            stem += pathExtension
            pathExtension = ""
        }
        let room = maximumNameBytes - suffix.utf8.count - pathExtension.utf8.count
        while stem.utf8.count > room { stem.removeLast() }
        return stem + suffix + pathExtension
    }

    /// True when `name` matches one of `names`, ignoring letter case.
    static func clashes(_ name: String, with names: Set<String>) -> Bool {
        folded(names).contains(fold(name))
    }

    private static func fold(_ name: String) -> String { name.lowercased() }

    private static func folded(_ names: Set<String>) -> Set<String> { Set(names.map(fold)) }
}
