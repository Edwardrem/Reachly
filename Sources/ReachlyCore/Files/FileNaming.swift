import Foundation

// CONTRACT (stream reachly-files-core implements this; the signatures are fixed).

/// Names for new, copied and renamed files, the same on the Mac and on a host.
public enum FileNaming {
    /// nil when `name` can be used as one file or folder name; otherwise a short reason to show the user.
    public static func validationError(for name: String) -> String? {
        name.isEmpty || name.contains("/") ? "Enter a name without a slash." : nil
    }

    /// The Finder-style name for a copy that is not in `existing`: "report copy.txt", then "report copy 2.txt", …
    public static func copyName(for name: String, isDirectory: Bool, existing: Set<String>) -> String {
        name + " copy"
    }

    /// `base` when it is free, otherwise "base 2", "base 3", … keeping any extension ("untitled 2.txt").
    public static func uniqueName(_ base: String, existing: Set<String>) -> String {
        base
    }
}
