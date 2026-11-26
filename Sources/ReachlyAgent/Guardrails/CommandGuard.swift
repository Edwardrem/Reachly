import Foundation
import ReachlyCore

/// Decides whether a command the agent proposes may run on a host.
///
/// Three layers: destructive patterns always need the user (and are refused
/// outright on read-only hosts); the read-only list names commands that only
/// inspect the host; the host's allowlist patterns let chosen commands run
/// unattended in `.allowlist` mode.
public enum CommandGuard {
    public enum Verdict: Equatable, Sendable {
        /// Runs without asking. The string says why (read-only list, allowlist pattern).
        case allow(String)
        /// Show the approval sheet. The string is the reason shown to the user.
        case ask(String)
        /// Refused without asking.
        case deny(String)
    }

    // MARK: Destructive patterns

    private struct Pattern {
        let regex: NSRegularExpression
        let label: String

        init(_ pattern: String, _ label: String, caseInsensitive: Bool = false) {
            regex = try! NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
            self.label = label
        }
    }

    private static let destructive: [Pattern] = [
        Pattern(#"(^|[\s;&|(])rm\s+(-\S*\s+)*-\S*[rRf]"#, "rm with -r or -f"),
        Pattern(#"(^|[\s;&|(])rm\s+(-\S*\s+)*(/|~|\*|/\*|\.\s*$)"#, "rm of / ~ or *"),
        Pattern(#"(^|[\s;&|(])dd\s"#, "dd"),
        Pattern(#"(^|[\s;&|(])(mkfs(\.\w+)?|mke2fs|mkswap|wipefs|fdisk|sfdisk|sgdisk|parted|shred)(\s|$)"#, "disk formatting or wiping"),
        Pattern(#">\s*/dev/(sd|nvme|hd|vd|xvd|disk|mapper/)\S*"#, "writing to a raw disk device"),
        Pattern(#"\b(drop|truncate)\s+(table|database|schema|index|view|user|role|tablespace)\b"#, "SQL DROP / TRUNCATE", caseInsensitive: true),
        Pattern(#"\bdelete\s+from\s+\S+\s*;?\s*$"#, "SQL DELETE without WHERE", caseInsensitive: true),
        Pattern(#"(^|[\s;&|(])(shutdown|reboot|halt|poweroff)(\s|$)"#, "shutdown or reboot"),
        Pattern(#"(^|[\s;&|(])(init|telinit)\s+[06](\s|$)"#, "shutdown or reboot"),
        Pattern(#"(^|[\s;&|(])systemctl\s+(reboot|poweroff|halt|kexec|suspend|hibernate)(\s|$)"#, "shutdown or reboot"),
        Pattern(#"\|\s*(sudo\s+(-\S+\s+)*)?(/bin/|/usr/bin/|/usr/local/bin/)?(ba|z|da|k|a|c|tc|fi)?sh(\s|$)"#, "pipes into a shell"),
        Pattern(#"(^|[\s;&|(])(ba|z|da|k|)sh\s+<\("#, "runs a process substitution in a shell"),
        Pattern(#"(^|[\s;&|(])(source|\.)\s+<\("#, "sources a process substitution"),
        Pattern(#"(^|[\s;&|(])eval\s"#, "eval"),
        Pattern(#"(^|[\s;&|(])chmod\s+(-\S+\s+)*[0-7]*777(\s|$)"#, "chmod 777"),
        Pattern(#"(^|[\s;&|(])chmod\s+(-\S+\s+)*-R\s+.*\s/\s*$"#, "recursive chmod of /"),
        Pattern(#"(^|[\s;&|(])chown\s+(-\S+\s+)*-R\s+.*\s/\s*$"#, "recursive chown of /"),
        Pattern(#"(^|[\s;&|(])kill\s+(-\S+\s+)*-1(\s|$)"#, "kill -1 (every process)"),
        Pattern(#"(^|[\s;&|(])(killall|pkill)\s+(-\S+\s+)*(sshd|init|systemd)(\s|$)"#, "killing sshd or init"),
        Pattern(#"(^|[\s;&|(])(iptables|ip6tables)\s+(-\S+\s+)*(-F|--flush|-X|-P\s+INPUT\s+DROP)"#, "flushing firewall rules"),
        Pattern(#"(^|[\s;&|(])(nft\s+flush|ufw\s+(disable|reset))(\s|$)"#, "disabling the firewall"),
        Pattern(#":\s*\(\s*\)\s*\{\s*:\s*\|\s*:\s*&\s*\}\s*;\s*:"#, "fork bomb"),
        Pattern(#"(^|[\s;&|(])(userdel|groupdel|passwd|chpasswd|usermod\s+(-\S+\s+)*-L)(\s|$)"#, "changing accounts or passwords"),
        Pattern(#"(^|[\s;&|(])git\s+(push\s+.*(--force|-f\b)|reset\s+--hard|clean\s+-\S*f|branch\s+-D|checkout\s+--\s+\.)"#, "destructive git operation"),
        Pattern(#"(^|[\s;&|(])docker\s+(system\s+prune|container\s+prune|image\s+prune|volume\s+(prune|rm)|rm\s+-f|rmi)(\s|$)"#, "removing docker resources"),
        Pattern(#"(^|[\s;&|(])kubectl\s+(-\S+\s+)*delete(\s|$)"#, "kubectl delete"),
        Pattern(#"(^|[\s;&|(])crontab\s+(-\S+\s+)*-r(\s|$)"#, "removing the crontab"),
        Pattern(#"(^|[\s;&|(])(apt|apt-get|yum|dnf|zypper|pacman)\s+(-\S+\s+)*(remove|purge|autoremove|-R\S*)(\s|$)"#, "removing packages"),
        Pattern(#"(^|[\s;&|(])truncate\s+(-\S+\s+)*-s\s*0(\s|$)"#, "truncating a file"),
        Pattern(#"(^|[;&|(]\s*|\s)>\s*(?!/dev/null)(?!&)[^\s|;&]+"#, "truncates a file with >"),
        Pattern(#"(^|[\s;&|(])mv\s+.*\s/dev/null(\s|$)"#, "moving to /dev/null"),
        Pattern(#"(^|[\s;&|(])(history\s+-c|unset\s+HISTFILE)(\s|$)"#, "clearing shell history"),
        Pattern(#"(^|[\s;&|(])find\s.*\s-delete(\s|$)"#, "find -delete"),
        Pattern(#"(^|[\s;&|(])(xargs|-exec|-execdir|-ok|-okdir)\s+(-\S+\s+)*(\S*/)?(rm|shred|unlink|rmdir)(\s|$)"#, "deleting the files it finds"),
        Pattern(#"(^|[\s;&|(])truncate\s+(-\S+\s+)*--size[=\s]*0(\s|$)"#, "truncating a file"),
    ]

    /// The destructive pattern a command matches, if any. `>` redirections to
    /// /dev/null and `2>&1` do not count. The line is scanned as written and again with its
    /// disguises taken off (see `canonical`), so `/bin/rm -rf`, `r\m -rf`, `'rm' -rf`,
    /// `rm${IFS}-rf` and `sh -c 'rm -rf …'` are all seen as `rm -rf`.
    public static func destructiveMatch(_ command: String) -> String? {
        let text = normalizedForScan(command)
        for candidate in [text, canonical(text)] {
            let range = NSRange(candidate.startIndex..., in: candidate)
            for pattern in destructive where pattern.regex.firstMatch(in: candidate, options: [], range: range) != nil {
                return pattern.label
            }
        }
        return nil
    }

    private static func normalizedForScan(_ command: String) -> String {
        var text = command
        for harmless in ["2>&1", "&>/dev/null", "&> /dev/null", "2>/dev/null", "2> /dev/null", ">/dev/null", "> /dev/null", ">>/dev/null", ">> /dev/null"] {
            text = text.replacingOccurrences(of: harmless, with: " ")
        }
        return text
    }

    // MARK: Read-only list

    /// Commands that only inspect the host, with optional argument rules.
    private static let readOnlyCommands: [String: (@Sendable ([String]) -> Bool)?] = {
        var table: [String: (@Sendable ([String]) -> Bool)?] = [:]
        for name in ["ls", "cat", "head", "tail", "grep", "egrep", "fgrep", "rg", "ag", "zcat", "zgrep", "wc", "sort", "uniq", "cut", "tr", "column", "tac", "nl",
                     "df", "du", "free", "uptime", "whoami", "id", "hostname", "uname", "ps", "pgrep", "pstree", "netstat", "ss", "ifconfig", "lsblk", "blkid", "lsof", "dmesg",
                     "date", "cal", "env", "printenv", "which", "whereis", "type", "file", "stat", "md5sum", "sha1sum", "sha256sum", "cksum", "nproc", "lscpu", "lsmem", "lspci", "lsusb",
                     "lsb_release", "who", "w", "last", "lastlog", "true", "false", "pwd", "echo", "printf", "basename", "dirname", "readlink", "realpath", "tree",
                     "vmstat", "iostat", "mpstat", "sar", "dig", "nslookup", "host", "getent", "ulimit", "locale", "timedatectl", "hostnamectl", "loginctl",
                     "diff", "cmp", "comm", "strings", "hexdump", "xxd", "od", "jq", "yq", "test", "[", "seq", "expr", "bc", "sleep", "arp", "route", "numfmt", "fold", "paste", "join", "rev", "expand",
                     "nginx", "apachectl", "httpd", "sshd", "showmount", "ldconfig", "getcap", "getfacl", "namei", "findmnt", "swapon", "losetup", "journalctl", "systemctl", "docker", "kubectl", "git",
                     "ip", "apt", "apt-cache", "dpkg", "dpkg-query", "rpm", "yum", "dnf", "brew", "pip", "pip3", "npm", "crontab", "find", "sed", "awk", "gawk", "mawk", "top", "ping", "traceroute", "mtr", "mount", "stat", "python3", "python", "node", "curl", "wget"] {
            table[name] = nil as (@Sendable ([String]) -> Bool)?
        }
        table["find"] = { args in !args.contains { ["-delete", "-exec", "-execdir", "-ok", "-okdir", "-fprint", "-fprint0", "-fprintf", "-fls"].contains($0) } }
        table["sed"] = { args in sedIsReadOnly(args) }
        // No program file or extension (-f, -l, -i), and a program that never runs anything:
        // system(), a pipe to or from a command (print | "sh", "id" | getline) or @load.
        let awkRule: @Sendable ([String]) -> Bool = { args in
            !hasOption(args, ["-f", "--file", "-l", "--load", "-E", "--exec", "-i", "--include"])
                && !args.contains { $0.range(of: #"system\s*\(|\||@load|@include"#, options: .regularExpression) != nil }
        }
        table["awk"] = awkRule; table["gawk"] = awkRule; table["mawk"] = awkRule
        table["systemctl"] = { args in
            let verb = firstVerb(args)
            return ["status", "show", "list-units", "list-unit-files", "is-active", "is-enabled", "is-failed", "is-system-running", "cat", "list-timers", "list-dependencies", "list-sockets", "list-jobs", "get-default", "show-environment", "help"].contains(verb)
        }
        table["journalctl"] = { args in !args.contains { $0.hasPrefix("--vacuum") || $0 == "--rotate" || $0 == "--flush" || $0 == "--sync" || $0 == "--relinquish-var" || $0 == "--update-catalog" || $0.hasPrefix("--setup-keys") } }
        table["docker"] = { args in
            let verb = firstVerb(args)
            switch verb {
            case "ps", "logs", "images", "inspect", "version", "info", "top", "port", "diff", "history", "stats", "events", "search": return !(verb == "stats" && !args.contains("--no-stream"))
            case "container", "image", "network", "volume", "compose", "system", "node", "service", "stack", "context":
                let sub = args.dropFirst(args.firstIndex(of: verb)! + 1).first { !$0.hasPrefix("-") } ?? ""
                return ["ls", "list", "inspect", "logs", "ps", "df", "top", "port", "images", "version", "events", "config", "show"].contains(sub)
            default: return false
            }
        }
        table["kubectl"] = { args in
            let verb = firstVerb(args)
            guard ["get", "describe", "logs", "version", "top", "cluster-info", "explain", "api-resources", "api-versions", "config", "diff", "auth"].contains(verb) else { return false }
            switch verb {
            case "config": return !args.contains { ["set", "use-context", "delete-context", "unset", "set-context", "set-cluster", "set-credentials"].contains($0) }
            case "auth": // can-i and whoami only ask; reconcile changes RBAC.
                let sub = args.drop { $0 != "auth" }.dropFirst().first { !$0.hasPrefix("-") }
                return sub == "can-i" || sub == "whoami"
            case "cluster-info": return !args.contains { $0.hasPrefix("--output-directory") }
            default: return true
            }
        }
        table["git"] = { args in
            // Options that write a file (--output), run a program (--ext-diff, grep -O) or point git
            // at another repository or program directory.
            if hasOption(args, ["--output", "--ext-diff", "--textconv", "--open-files-in-pager", "--exec-path", "--git-dir", "--work-tree", "--config-env"]) || args.contains(where: { $0.hasPrefix("-O") }) { return false }
            let verb = firstVerb(args)
            switch verb {
            case "status", "log", "diff", "show", "rev-parse", "ls-files", "ls-remote", "blame", "describe", "shortlog", "reflog", "cat-file", "grep", "config", "remote", "branch", "tag", "stash", "worktree":
                if verb == "branch" { return !args.contains { ["-d", "-D", "-m", "-M", "-c", "-C", "--delete", "--move", "--copy", "--set-upstream-to", "-u"].contains($0) } && args.filter { !$0.hasPrefix("-") }.count <= 1 }
                if verb == "tag" { return args.filter { !$0.hasPrefix("-") }.count <= 1 && !args.contains { ["-d", "--delete", "-a", "-s", "-f"].contains($0) } }
                if verb == "stash" { return args.contains("list") || args.contains("show") }
                if verb == "remote" { return args.filter { !$0.hasPrefix("-") }.count <= 1 }
                if verb == "config" { return args.contains("--get") || args.contains("--list") || args.contains("-l") || args.contains("--get-all") || args.contains("--get-regexp") }
                if verb == "worktree" { return args.contains("list") }
                return true
            default: return false
            }
        }
        table["ip"] = { args in
            let words = args.filter { !$0.hasPrefix("-") }
            return !words.contains { ["add", "del", "delete", "set", "change", "replace", "flush", "append", "link"].contains($0) && $0 != "link" } && !(words.contains("link") && words.contains { ["set", "add", "del", "delete"].contains($0) })
                // ip netns exec / ip vrf exec run any command; -batch runs a file of ip commands.
                && !words.contains { ["exec", "restore", "deleteall", "prepend"].contains($0) }
                && !args.contains { ["-b", "-batch", "--batch", "-force", "--force"].contains($0) }
        }
        table["apt"] = { args in ["list", "policy", "show", "search", "depends", "rdepends", "changelog", "moo"].contains(firstVerb(args)) }
        table["apt-cache"] = { _ in true }
        table["dpkg"] = { args in args.contains { ["-l", "-L", "-s", "-S", "--list", "--status", "--listfiles", "--search", "--print-architecture", "--get-selections"].contains($0) } && !args.contains { ["-i", "-r", "-P", "--install", "--remove", "--purge", "--configure", "--set-selections"].contains($0) } }
        table["rpm"] = { args in args.contains { $0.hasPrefix("-q") || $0 == "--query" } && !args.contains { ["-i", "-U", "-e", "--install", "--upgrade", "--erase"].contains($0) } }
        let pkgQuery: @Sendable ([String]) -> Bool = { args in ["list", "info", "search", "provides", "repolist", "history", "check-update", "deplist"].contains(firstVerb(args)) }
        table["yum"] = pkgQuery; table["dnf"] = pkgQuery
        table["brew"] = { args in ["list", "info", "deps", "outdated", "doctor", "config", "search", "services"].contains(firstVerb(args)) && !(firstVerb(args) == "services" && args.contains { ["start", "stop", "restart", "run", "kill", "cleanup"].contains($0) }) }
        let pipQuery: @Sendable ([String]) -> Bool = { args in ["list", "show", "freeze", "check", "--version", "-V"].contains(firstVerb(args)) }
        table["pip"] = pipQuery; table["pip3"] = pipQuery
        table["npm"] = { args in ["ls", "list", "view", "outdated", "--version", "-v", "config"].contains(firstVerb(args)) && !(firstVerb(args) == "config" && args.contains { ["set", "delete", "edit"].contains($0) }) }
        table["crontab"] = { args in args == ["-l"] || (args.count == 3 && args[0] == "-u" && args[2] == "-l") || (args.count == 2 && args[0] == "-l") }
        table["top"] = { args in args.contains { $0.hasPrefix("-b") } || args.contains { $0.hasPrefix("-n") } || args.contains("-l") }
        table["ping"] = { args in args.contains { $0.hasPrefix("-c") } }
        table["mtr"] = { args in args.contains { $0 == "-r" || $0 == "--report" } }
        table["mount"] = { args in args.isEmpty || args == ["-l"] }
        // Testing the running configuration only: another config file (-c, -f) can load modules.
        table["nginx"] = { args in (args.contains("-t") || args.contains("-T") || args.contains("-v") || args.contains("-V")) && !hasOption(args, ["-c", "-g", "-p", "-e", "-s"]) }
        let apacheControl: Set<String> = ["start", "stop", "restart", "graceful", "graceful-stop"]
        table["apachectl"] = { args in args.contains { ["configtest", "-t", "-S", "-M", "-v", "-V", "status", "fullstatus"].contains($0) } && !hasOption(args, ["-f", "-C", "-c", "-d", "-k"]) && !args.contains { apacheControl.contains($0) } }
        table["httpd"] = { args in args.contains { ["-t", "-S", "-M", "-v", "-V"].contains($0) } && !hasOption(args, ["-f", "-C", "-c", "-d", "-k"]) }
        table["sshd"] = { args in args.contains("-T") || args.contains("-t") }
        table["swapon"] = { args in args.contains("--show") || args == ["-s"] }
        table["losetup"] = { args in args.contains("-a") || args.contains("--list") || args.contains("-l") }
        table["ldconfig"] = { args in args.contains("-p") }
        table["timedatectl"] = { args in firstVerb(args).isEmpty || ["status", "show", "list-timezones", "timesync-status"].contains(firstVerb(args)) }
        table["hostnamectl"] = { args in firstVerb(args).isEmpty || ["status", "show"].contains(firstVerb(args)) }
        table["loginctl"] = { args in firstVerb(args).isEmpty || ["list-sessions", "list-users", "show-session", "show-user", "session-status", "user-status"].contains(firstVerb(args)) }
        let interpreter: @Sendable ([String]) -> Bool = { args in args.first == "--version" || args.first == "-V" || args.first == "-v" }
        table["python3"] = interpreter; table["python"] = interpreter; table["node"] = interpreter
        // A plain request: nothing sent (-d, --json, -F, -T, -X), and nothing written to a file on the
        // host (-o other than /dev/null, -O, -D, -c, --trace, -K config files), so health checks such as
        // curl -s -o /dev/null -w '%{http_code}' run.
        table["curl"] = { args in
            let sendsOrWrites: Set<String> = ["-d", "--data", "--data-binary", "--data-raw", "--data-urlencode", "--data-ascii", "--json", "-F", "--form", "--form-string",
                                              "-T", "--upload-file", "-O", "--remote-name", "--remote-name-all", "-J", "--remote-header-name", "-X", "--request",
                                              "-D", "--dump-header", "-c", "--cookie-jar", "--trace", "--trace-ascii", "--libcurl", "-K", "--config", "--stderr",
                                              "--etag-save", "--hsts", "--alt-svc", "--output-dir", "--create-dirs"]
            var index = 0
            while index < args.count {
                let arg = args[index]
                if arg == "-o" || arg == "--output" {
                    guard index + 1 < args.count, args[index + 1] == "/dev/null" else { return false }
                    index += 2; continue
                }
                if arg.hasPrefix("--output=") { guard arg == "--output=/dev/null" else { return false } }
                else if arg.hasPrefix("-o"), !arg.hasPrefix("--") { guard arg == "-o/dev/null" else { return false } }
                else if sendsOrWrites.contains(arg) || (arg.hasPrefix("--") && sendsOrWrites.contains(String(arg.prefix { $0 != "=" }))) { return false }
                else if arg.hasPrefix("-"), !arg.hasPrefix("--"), arg.count > 2, arg.dropFirst().contains(where: { "dFTOXJDcKo".contains($0) }) { return false }
                if arg == "-w" || arg == "--write-out", index + 1 < args.count, args[index + 1].contains("%output") { return false }
                index += 1
            }
            return true
        }
        table["wget"] = { args in
            args.contains("--spider") && !args.contains { arg in
                ["-O", "-o", "-a", "-P", "-x", "-i", "-e", "--output-document", "--output-file", "--append-output", "--directory-prefix", "--force-directories", "--input-file", "--execute", "--config"].contains(arg)
                    || ["--output", "--append", "--post", "--body", "--method", "--execute", "--config", "--directory-prefix"].contains { arg.hasPrefix($0) }
                    || arg.hasPrefix("-O") || arg.hasPrefix("-o") || arg.hasPrefix("-e")
            }
        }
        // Tools that also write files, change settings or run programs when given certain options.
        table["sort"] = { args in !hasOption(args, ["-o", "--output", "--compress-program"]) }
        table["uniq"] = { args in operands(args, valueOptions: ["-f", "-s", "-w", "--skip-fields", "--skip-chars", "--check-chars"]).count <= 1 } // a second operand is the output file
        table["date"] = { args in
            var takesValue = false
            for arg in args {
                if takesValue { takesValue = false; continue }
                if arg == "-s" || arg.hasPrefix("--set") || (arg.hasPrefix("-s") && arg.count > 2) { return false }
                if ["-d", "--date", "-r", "--reference", "-f", "--file"].contains(arg) { takesValue = true; continue }
                if arg.hasPrefix("-") { continue }
                if !arg.hasPrefix("+") { return false } // an operand other than +FORMAT sets the clock
            }
            return true
        }
        table["hostname"] = { args in operands(args).isEmpty && !hasOption(args, ["-F", "--file", "-b", "--boot"]) }
        table["ifconfig"] = { args in operands(args).count <= 1 } // ifconfig eth0 down / eth0 10.0.0.2 change it
        table["route"] = { args in let words = operands(args); return words.isEmpty || ["get", "show", "print"].contains(words[0]) }
        table["arp"] = { args in !hasOption(args, ["-d", "-s", "-f", "-S", "--delete", "--set", "--file"]) }
        table["dmesg"] = { args in !hasOption(args, ["-c", "-C", "-n", "-D", "-E", "--clear", "--read-clear", "--console-level", "--console-off", "--console-on"]) }
        table["xxd"] = { args in !hasOption(args, ["-r"]) && operands(args, valueOptions: ["-c", "-g", "-l", "-s", "-o", "-n", "-cols", "-len", "-seek", "-groupsize", "-offset", "-name"]).count <= 1 }
        table["tree"] = { args in !hasOption(args, ["-o"]) }
        table["file"] = { args in !hasOption(args, ["-C", "--compile"]) }
        table["sar"] = { args in !hasOption(args, ["-o"]) }
        table["yq"] = { args in !hasOption(args, ["-i", "--inplace"]) }
        table["rg"] = { args in !hasOption(args, ["--pre"]) } // --pre runs a program on every file
        table["ag"] = { args in !hasOption(args, ["--pager"]) }
        table["lastlog"] = { args in !hasOption(args, ["-C", "-S", "--clear", "--set"]) }
        return table
    }()

    private static func firstVerb(_ args: [String]) -> String {
        args.first { !$0.hasPrefix("-") } ?? ""
    }

    /// The words in `args` that are not options or the values of `valueOptions`.
    private static func operands(_ args: [String], valueOptions: Set<String> = []) -> [String] {
        var result: [String] = []
        var skipNext = false
        for arg in args {
            if skipNext { skipNext = false; continue }
            if valueOptions.contains(arg) { skipNext = true; continue }
            if arg.count > 1, arg.hasPrefix("-") { continue }
            result.append(arg)
        }
        return result
    }

    /// True when `args` gives one of `options`: alone, as `--option=value`, or as a letter in a run of
    /// short options (`-nro` gives -o).
    private static func hasOption(_ args: [String], _ options: Set<String>) -> Bool {
        args.contains { arg in
            if options.contains(arg) { return true }
            if arg.hasPrefix("--") { return options.contains(String(arg.prefix { $0 != "=" })) }
            if arg.hasPrefix("-"), arg.count > 2 { return arg.dropFirst().contains { options.contains("-\($0)") } }
            return false
        }
    }

    private static let sedCommand = try! NSRegularExpression(pattern: #"^\s*(?:(?:\d+|\$|/(?:[^/\\]|\\.)*/I?)(?:~\d+)?(?:\s*,\s*(?:\d+|\$|/(?:[^/\\]|\\.)*/I?|[+~]\d+))?)?\s*!?\s*(?:[pdlnNPDgGhHxz=]|[qQ]\d*|s/(?:[^/\\]|\\.)*/(?:[^/\\]|\\.)*/[gpiImM0-9]*|y/(?:[^/\\]|\\.)*/(?:[^/\\]|\\.)*/)\s*$"#)

    /// sed that only prints: no in-place edit and no script file, and scripts made only of commands
    /// that print, drop lines from the output, quit, substitute or transliterate. GNU sed's `w`/`W`
    /// write files and `e` (and the `s///e` flag) run commands, so a script using them is refused;
    /// so is anything the simple grammar here does not recognise.
    private static func sedIsReadOnly(_ args: [String]) -> Bool {
        var scripts: [String] = []
        var operands: [String] = []
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg == "-e" || arg == "--expression" {
                guard index + 1 < args.count else { return false }
                scripts.append(args[index + 1]); index += 2; continue
            }
            if arg.hasPrefix("--expression=") { scripts.append(String(arg.dropFirst("--expression=".count))); index += 1; continue }
            if arg == "-f" || arg.hasPrefix("--file") || arg.hasPrefix("-i") || arg.hasPrefix("--in-place") { return false }
            if arg.hasPrefix("-"), !arg.hasPrefix("--"), arg.count > 2 {
                // A run of short options: -ne 'script', -nE, -ni (in place), -nf (script file).
                let letters = arg.dropFirst()
                if letters.contains("i") || letters.contains("f") { return false }
                if letters.last == "e" {
                    guard index + 1 < args.count else { return false }
                    scripts.append(args[index + 1]); index += 2; continue
                }
                if let e = letters.firstIndex(of: "e") { scripts.append(String(letters[letters.index(after: e)...])) }
                index += 1; continue
            }
            if arg == "-l" || arg == "--line-length" { index += 2; continue }
            if arg.count > 1, arg.hasPrefix("-") { index += 1; continue }
            operands.append(arg); index += 1
        }
        if scripts.isEmpty, let first = operands.first { scripts.append(first) }
        return !scripts.isEmpty && scripts.allSatisfy { script in
            script.split(whereSeparator: { $0 == ";" || $0 == "\n" }).allSatisfy { part in
                let text = String(part)
                return text.trimmingCharacters(in: .whitespaces).isEmpty
                    || sedCommand.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)) != nil
            }
        }
    }

    /// True when every part of the command only inspects the host.
    public static func isReadOnly(_ command: String) -> Bool {
        let text = normalizedForScan(command)
        // Anything that can run arbitrary code or write files disqualifies the whole line.
        if text.contains("$(") || text.contains("`") || text.contains("<(") || text.contains(">(") { return false }
        if text.contains(">") { return false }
        let segments = ShellWords.commands(text)
        guard !segments.isEmpty else { return false }
        return segments.allSatisfy(segmentIsReadOnly)
    }

    /// Variables a read-only command may be given: none of them changes which program runs or what
    /// it loads (unlike PATH, LD_PRELOAD or BASH_ENV).
    private static let safeAssignmentNames: Set<String> = ["LANG", "LANGUAGE", "TZ", "COLUMNS", "LINES", "TERM", "NO_COLOR", "SYSTEMD_COLORS"]
    private static let pagerNames: Set<String> = ["PAGER", "GIT_PAGER", "SYSTEMD_PAGER", "MANPAGER"]

    private static func isSafeAssignment(_ assignment: String) -> Bool {
        let parts = assignment.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        let name = String(parts[0])
        let value = parts.count > 1 ? String(parts[1]) : ""
        if value.contains("$") || value.contains("`") { return false }
        if safeAssignmentNames.contains(name) || name.hasPrefix("LC_") { return true }
        if pagerNames.contains(name) { return value.isEmpty || value == "cat" } // turning the pager off
        return false
    }

    /// A command named plainly or by its place in the system's bin folders: never a script by path
    /// (`./ls`, `/tmp/ls`) or a name built from a variable.
    private static func isPlainCommandWord(_ word: String) -> Bool {
        word.range(of: #"^([A-Za-z0-9._+\[-]+|/(usr/(local/)?)?s?bin/[A-Za-z0-9._+-]+)$"#, options: .regularExpression) != nil
    }

    private static func segmentIsReadOnly(_ segment: String) -> Bool {
        guard let command = simpleCommand(segment), command.unsafeWrapperOption == nil else { return false }
        // A bare `env` prints the environment; its assignments reach no other program.
        if command.word.isEmpty { return command.wrappers.last == "env" }
        guard command.assignments.allSatisfy(isSafeAssignment), isPlainCommandWord(command.word),
              let entry = readOnlyCommands[command.name] else { return false }
        if let rule = entry { return rule(command.arguments) }
        return true
    }

    // MARK: Reading a command line

    /// One simple command (no `;`, `&` or `|`) once its leading `NAME=value` assignments and its
    /// wrappers (sudo, env, nice, timeout, …) are taken off.
    struct SimpleCommand {
        var assignments: [String] = []
        var wrappers: [String] = []
        /// A wrapper option that runs a shell, edits or writes a file, or acts on another process
        /// (`sudo -s`, `env -S`, `time -o`, `ionice -p`), so the command after it is not the whole story.
        var unsafeWrapperOption: String?
        /// The command word, unquoted, as written: it may include a directory.
        var word = ""
        var arguments: [String] = []
        /// The text after the command word, as written.
        var rest: Substring = ""
        var name: String { (word as NSString).lastPathComponent }
    }

    /// Each wrapper's options that take the next word as their value.
    private static let wrapperValueOptions: [String: Set<String>] = [
        "sudo": ["-u", "-g", "-p", "-h", "-C", "-D", "-r", "-t", "-T", "-U", "--user", "--group", "--prompt", "--host", "--close-from", "--chdir", "--role", "--type", "--other-user"],
        "doas": ["-u", "-C"],
        "env": ["-u", "--unset", "-C", "--chdir", "-S", "--split-string", "-P"],
        "nice": ["-n", "--adjustment"],
        "ionice": ["-c", "--class", "-n", "--classdata", "-p", "--pid", "-P", "--pgid", "-u", "--uid"],
        "time": ["-f", "--format", "-o", "--output"],
        "command": [],
        "nohup": [],
        "timeout": ["-s", "--signal", "-k", "--kill-after"],
        "stdbuf": ["-i", "--input", "-o", "--output", "-e", "--error"],
        "exec": ["-a"],
    ]

    /// Wrapper options that make the wrapper do more than run the command after it.
    private static let unsafeWrapperOptions: [String: Set<String>] = [
        "sudo": ["-s", "--shell", "-i", "--login", "-e", "--edit"],
        "doas": ["-s"],
        "env": ["-S", "--split-string", "-P"],
        "time": ["-o", "--output", "-a", "--append"],
        "ionice": ["-p", "--pid", "-P", "--pgid", "-u", "--uid"],
    ]

    static func isAssignment(_ word: String) -> Bool {
        word.range(of: #"^[A-Za-z_][A-Za-z0-9_]*="#, options: .regularExpression) != nil
    }

    /// Reads one simple command. Nil when it holds no words.
    static func simpleCommand(_ segment: String) -> SimpleCommand? {
        var command = SimpleCommand()
        var remaining = Substring(segment)
        var wrapper: String?
        var timeoutNeedsDuration = false
        var sawWord = false
        while let next = ShellWords.firstWord(remaining) {
            let word = next.word
            sawWord = true
            remaining = next.rest
            if let current = wrapper {
                if word == "--" { continue }
                if word.count > 1, word.hasPrefix("-"), current != "timeout" || timeoutNeedsDuration {
                    if let unsafe = unsafeWrapperOptions[current], command.unsafeWrapperOption == nil {
                        let flagged = word.hasPrefix("--") ? unsafe.contains(String(word.prefix { $0 != "=" })) : word.dropFirst().contains { unsafe.contains("-\($0)") }
                        if flagged { command.unsafeWrapperOption = "\(current) \(word)" }
                    }
                    // An option given on its own takes the next word (-u root); attached (-uroot, --user=root) it doesn't.
                    if wrapperValueOptions[current]?.contains(word) == true, let value = ShellWords.firstWord(remaining) { remaining = value.rest }
                    continue
                }
                if current == "env", isAssignment(word) { command.assignments.append(word); continue }
                if current == "timeout", timeoutNeedsDuration { timeoutNeedsDuration = false; continue }
                wrapper = nil
            }
            // Assignments come first, or straight after sudo, doas or env (sudo FOO=1 cmd).
            if command.wrappers.isEmpty || ["sudo", "doas", "env"].contains(command.wrappers.last ?? ""), isAssignment(word) {
                command.assignments.append(word); continue
            }
            // A wrapper may be named by its path too (/usr/bin/env).
            let base = (word as NSString).lastPathComponent
            if wrapperValueOptions[base] != nil {
                command.wrappers.append(base)
                wrapper = base
                timeoutNeedsDuration = base == "timeout"
                continue
            }
            command.word = word
            command.rest = next.rest
            var tail = next.rest
            while let argument = ShellWords.firstWord(tail) { command.arguments.append(argument.word); tail = argument.rest }
            return command
        }
        return sawWord ? command : nil
    }

    private static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "mksh", "ash", "fish", "csh", "tcsh", "busybox"]
    private static let interpreters: Set<String> = ["python", "python2", "python3", "perl", "ruby", "node", "nodejs", "php", "lua", "Rscript", "osascript", "bun", "tclsh"]

    /// The command line with its disguises taken off, for the destructive scan: `$IFS` read as a
    /// space; each command named without quotes, backslashes, directory or wrappers; and the script
    /// given to a shell with -c read the same way. `sudo '/bin/r\m' -rf /` reads as `rm -rf /`.
    static func canonical(_ command: String, depth: Int = 0) -> String {
        let text = command.replacingOccurrences(of: #"\$\{IFS[^}]*\}|\$IFS\b"#, with: " ", options: .regularExpression)
        var out = ""
        for piece in ShellWords.pieces(text) {
            if let simple = simpleCommand(piece.text), !simple.word.isEmpty {
                out += simple.name + simple.rest
                if depth < 3, shells.contains(simple.name),
                   let flag = simple.arguments.firstIndex(where: { $0.range(of: #"^-[A-Za-z]*c[A-Za-z]*$"#, options: .regularExpression) != nil }),
                   flag + 1 < simple.arguments.count {
                    out += " ; " + canonical(simple.arguments[flag + 1], depth: depth + 1)
                }
            }
            out += " " + piece.separator + " "
        }
        return out
    }

    /// Why Reachly can't tell from the text what a command runs, or nil when it can: a command or
    /// process substitution, a command name taken from a variable, a shell, `eval` or `source`, code
    /// handed to an interpreter inline, or a wrapper option that runs a shell.
    public static func opaqueReason(_ command: String) -> String? {
        let text = normalizedForScan(command)
        if text.contains("$(") || text.contains("`") { return "it runs a command substitution" }
        if text.contains("<(") || text.contains(">(") { return "it runs a process substitution" }
        for segment in ShellWords.commands(text) {
            guard let simple = simpleCommand(segment) else { continue }
            if let option = simple.unsafeWrapperOption { return "\(option) does more than run the command after it" }
            guard !simple.word.isEmpty else { continue }
            if simple.word.contains("$") { return "its command name comes from a variable" }
            if simple.word != "[", simple.word.contains(where: { "{}*?[".contains($0) }) { return "its command name is a pattern the shell expands" }
            let name = simple.name
            if shells.contains(name) { return "it starts a shell (\(name))" }
            if ["eval", "source", "."].contains(name) { return "it runs code from text or a file (\(name))" }
            if interpreters.contains(name), simple.arguments.contains(where: { $0 == "--eval" || $0 == "--print" || $0.range(of: #"^-[A-Za-z]*[ceErp]$"#, options: .regularExpression) != nil }) {
                return "it hands \(name) code to run"
            }
        }
        return nil
    }

    // MARK: Allowlist

    /// The allowlist pattern the command matches, if any. Patterns are globs
    /// (`*` any text, `?` one character) matched against the whole command,
    /// or regular expressions written as `/pattern/`.
    public static func allowlistMatch(_ command: String, patterns: [String]) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        for pattern in patterns {
            let candidate = pattern.trimmingCharacters(in: .whitespaces)
            guard !candidate.isEmpty, !candidate.hasPrefix("#") else { continue }
            guard let regex = regex(forPattern: candidate) else { continue }
            if regex.firstMatch(in: trimmed, options: [], range: NSRange(trimmed.startIndex..., in: trimmed)) != nil {
                return pattern
            }
        }
        return nil
    }

    static func regex(forPattern pattern: String) -> NSRegularExpression? {
        if pattern.count >= 2, pattern.hasPrefix("/"), pattern.hasSuffix("/") {
            let body = String(pattern.dropFirst().dropLast())
            return try? NSRegularExpression(pattern: "^(?:\(body))$", options: [.dotMatchesLineSeparators])
        }
        var out = "^"
        for character in pattern {
            switch character {
            case "*": out += ".*"
            case "?": out += "."
            default: out += NSRegularExpression.escapedPattern(for: String(character))
            }
        }
        out += "$"
        return try? NSRegularExpression(pattern: out, options: [.dotMatchesLineSeparators])
    }

    // MARK: Decision

    /// The verdict for a shell command on a host with the given mode.
    public static func decide(command: String, mode: AgentPermissionMode, allowlist: [String]) -> Verdict {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .deny("Empty command.") }
        let destructive = destructiveMatch(trimmed)
        let readOnly = destructive == nil && isReadOnly(trimmed)
        switch mode {
        case .readOnly:
            if readOnly { return .allow("on the read-only list") }
            if let destructive { return .deny("This host is read-only and the command is destructive (\(destructive)).") }
            return .deny("This host is read-only; only inspection commands such as ls, cat, grep, df, ps and systemctl status may run.")
        case .ask:
            if let destructive { return .ask("Destructive: \(destructive).") }
            return .ask(readOnly ? "Read-only command; this host asks for every command." : "This host asks for every command.")
        case .allowlist:
            if let destructive { return .ask("Destructive (\(destructive)); destructive commands always ask.") }
            // A pattern without wildcards approves exactly that line, as written.
            if let exact = allowlist.first(where: { isLiteralPattern($0) && $0.trimmingCharacters(in: .whitespaces) == trimmed }) {
                return .allow("matches allowlist pattern \(exact)")
            }
            if let opaque = opaqueReason(trimmed) { return .ask("Reachly can't tell what this runs: \(opaque). Such commands always ask.") }
            // Each command in the line must be allowlisted or read-only: `df *` covers `df -h | grep sda`,
            // not `df -h; mv /srv/app /tmp`.
            let segments = ShellWords.commands(normalizedForScan(trimmed))
            var matched: String?
            for segment in segments {
                if let pattern = allowlistMatch(segment, patterns: allowlist) { matched = matched ?? pattern; continue }
                if isReadOnly(segment) { continue }
                return .ask(segments.count > 1 ? "Part of this command is not on this host's allowlist: \(segment)" : "Not on this host's allowlist.")
            }
            if let matched { return .allow("matches allowlist pattern \(matched)") }
            return .ask(readOnly ? "Read-only command, not on this host's allowlist." : "Not on this host's allowlist.")
        }
    }

    private static func isLiteralPattern(_ pattern: String) -> Bool {
        let text = pattern.trimmingCharacters(in: .whitespaces)
        return !text.isEmpty && !text.hasPrefix("#") && !(text.count >= 2 && text.hasPrefix("/") && text.hasSuffix("/")) && !text.contains("*") && !text.contains("?")
    }

    /// The verdict for an action that is not a shell command the user wrote,
    /// such as writing a file. `readOnly` says whether it only reads.
    public static func decide(action description: String, readOnly: Bool, mode: AgentPermissionMode, allowlist: [String]) -> Verdict {
        switch mode {
        case .readOnly:
            return readOnly ? .allow("read-only action") : .deny("This host is read-only; \(description) would change it.")
        case .ask:
            return .ask("This host asks for every action.")
        case .allowlist:
            // write_file /srv/app/* must not cover /srv/app/../../etc/cron.d/job.
            if description.range(of: #"(^|/|\s)\.\.(/|\s|$)"#, options: .regularExpression) != nil {
                return .ask("The path climbs out of a folder (..), so the allowlist doesn't cover it.")
            }
            if let pattern = allowlistMatch(description, patterns: allowlist) { return .allow("matches allowlist pattern \(pattern)") }
            return .ask("Not on this host's allowlist.")
        }
    }
}

/// Splits a shell segment into words, honouring quotes and backslashes.
public enum ShellWords {
    public static func split(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        var inWord = false
        var quote: Character?
        var escaped = false
        for character in text {
            if escaped {
                current.append(character); escaped = false; inWord = true; continue
            }
            if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
                continue
            }
            switch character {
            case "\\": escaped = true; inWord = true
            case "\"", "'": quote = character; inWord = true
            case " ", "\t", "\n":
                if inWord { words.append(current); current = ""; inWord = false }
            default: current.append(character); inWord = true
            }
        }
        if inWord { words.append(current) }
        return words
    }

    /// The first word of `text`, with its quotes and backslashes resolved as a POSIX shell would, and
    /// the text after it as written. Nil when only blanks are left.
    public static func firstWord(_ text: Substring) -> (word: String, rest: Substring)? {
        var index = text.startIndex
        while index < text.endIndex, text[index].isWhitespace { index = text.index(after: index) }
        guard index < text.endIndex else { return nil }
        var word = ""
        var quote: Character?
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if let open = quote {
                if character == open {
                    quote = nil
                } else if open == "\"", character == "\\", next < text.endIndex, "$`\"\\\n".contains(text[next]) {
                    word.append(text[next]); index = text.index(after: next); continue
                } else {
                    word.append(character)
                }
            } else if character == "\\" {
                if next < text.endIndex { word.append(text[next]); index = text.index(after: next); continue }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character.isWhitespace {
                break
            } else {
                word.append(character)
            }
            index = next
        }
        return (word, text[index...])
    }

    /// A command line cut at its unquoted `;`, `&`, `|` and newlines: each piece as written, with the
    /// operator that follows it (`;`, `&&`, `|`, …; empty after the last).
    public static func pieces(_ text: String) -> [(text: String, separator: String)] {
        var pieces: [(text: String, separator: String)] = []
        var current = ""
        var separator = ""
        var quote: Character?
        var escaped = false
        for character in text.replacingOccurrences(of: "\\\n", with: " ") {
            if escaped { current.append(character); escaped = false; continue }
            if let open = quote {
                current.append(character)
                if character == open { quote = nil } else if open == "\"", character == "\\" { escaped = true }
                continue
            }
            if ";&|\n".contains(character) { separator.append(character); continue }
            if !separator.isEmpty { pieces.append((current, separator)); current = ""; separator = "" }
            if character == "\\" { escaped = true } else if character == "\"" || character == "'" { quote = character }
            current.append(character)
        }
        pieces.append((current, separator))
        return pieces
    }

    /// The simple commands in a command line, as written: cut at unquoted `;`, `&`, `|` and newlines.
    public static func commands(_ text: String) -> [String] {
        pieces(text).map { $0.text.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Single-quotes a string for a POSIX shell.
    public static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
