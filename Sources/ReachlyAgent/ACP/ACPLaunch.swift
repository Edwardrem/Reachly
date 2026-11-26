import Foundation

/// Checks made before an ACP agent is started: which file really runs, and whether a failed start is worth one
/// more try with other arguments.
public enum ACPLaunch {
    /// Why a chosen path can't be run as the agent.
    public enum ExecutableProblem: Error, Equatable, Sendable {
        /// Nothing is there, or a link leads nowhere.
        case missing
        /// A folder, or a file that isn't executable.
        case notExecutable
        /// The path leads into an app bundle, such as the `qoder` shell command the Qoder editor installs, which
        /// opens the editor rather than speaking ACP.
        case insideAppBundle(resolved: String)
    }

    /// The file `path` leads to, with every symbolic link resolved, when it can run as the agent: an executable
    /// file outside any app bundle. Checked at each start, so a link that later points somewhere else, such as
    /// into Qoder.app, is caught then, and the file that runs is the one checked.
    public static func resolveExecutable(_ path: String, fileManager: FileManager = .default) -> Result<String, ExecutableProblem> {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: resolved, isDirectory: &isDirectory) else { return .failure(.missing) }
        if AIProviderLocations.isInsideAppBundle(resolved) { return .failure(.insideAppBundle(resolved: resolved)) }
        guard !isDirectory.boolValue, fileManager.isExecutableFile(atPath: resolved) else { return .failure(.notExecutable) }
        return .success(resolved)
    }

    /// What a command line tool prints when it doesn't know an argument it was given, in the wordings common
    /// argument parsers use (commander, yargs, clap, cobra, getopt, argparse).
    static let refusalPhrases = [
        "unknown option", "unknown flag", "unknown argument", "unknown command", "unknown subcommand",
        "unrecognized", "unrecognised", "unexpected argument", "invalid option", "illegal option",
        "no such option", "no such command", "not a valid option",
    ]

    /// The argument the agent refused as unknown, going by what it wrote before it exited: a line that says an
    /// option or command is unknown and names one of `arguments`. Nil for anything else (a crash, a missing
    /// sign-in, a message that names none of them), which is not worth another try.
    public static func refusedArgument(in standardError: String, among arguments: [String]) -> String? {
        for line in standardError.lowercased().split(whereSeparator: \.isNewline) {
            guard refusalPhrases.contains(where: { line.contains($0) }) else { continue }
            // Words as a parser prints them: `'--acp'`, `"acp"`, `--permission-mode=default`.
            let words = line.split { !($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "=") }
                .map { $0.split(separator: "=", maxSplits: 1).first.map(String.init) ?? "" }
            if let refused = arguments.filter({ words.contains($0.lowercased()) }).max(by: { $0.count < $1.count }) {
                return refused
            }
        }
        return nil
    }
}
