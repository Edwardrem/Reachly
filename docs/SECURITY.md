# Security

How Reachly protects your machines and keys when an AI works on them, what is tested, and what is not done yet.

## What the AI can and cannot do

Every action the assistant takes (from the chat panel or from another AI app through the MCP server) goes through
the same policy check before it runs, whatever the model asked for:

- **Per-host mode.** Each host is *read-only* (only inspection commands such as `ls`, `cat`, `grep`, `df`, `ps` and
  `systemctl status` run, and changes are refused without asking), *ask every time*, or *allowlist* (matching
  commands run unattended, everything else asks).
- **Destructive commands always ask.** Commands such as `rm -rf`, `DROP`, `shutdown` and `truncate` stop at an
  approval sheet on every host, even an allowlisted one. The person can approve, edit, deny, or comment to have
  the command revised.
- **Everything is recorded.** AI History (⌥⌘Y) and a JSON audit log keep each command with its host, time,
  requester, decision and exit status.
- **MCP server.** It listens on 127.0.0.1 only and requires a bearer token. Other AI apps get the same tools under
  the same rules, and a request that names a client Reachly doesn't know is shown without that name.

The rules live in `Sources/ReachlyAgent/Guardrails/CommandGuard.swift`. They are tested in
`Tests/ReachlyAgentTests/CommandGuardTests.swift`, `GuardEvasionTests.swift`, `AgentSessionTests.swift` and
`MCPServerTests.swift`.

## How the guard reads a command

The guard is pattern-based, so since 1.1.3 it reads a command line the way a shell would before it decides:

- **Each command is checked on its own.** The line is cut at every unquoted `;`, `&&`, `||`, `|`, `&` and newline,
  and every command in it must be allowlisted or read-only. An allowlist entry `df *` covers `df -h | grep sda`
  but not `df -h; mv /srv/app /tmp`. An entry without wildcards approves exactly that line and nothing joined on.
- **Disguises are taken off before the destructive check.** It also scans a rewritten form of the line, so these
  are all seen as `rm -rf` and stop for a person on every host:
  - quotes and backslashes: `'rm'`, `r\m`;
  - full paths: `/bin/rm`;
  - `$IFS` used as a space;
  - wrappers: `sudo`, `env`, `nice`, `command`;
  - a script handed to `sh -c`.
- **What can't be read always asks.** On an allowlist host, a command that hides what it runs is never
  auto-allowed:
  - command or process substitution (`$(…)`, backticks, `<(…)`);
  - a command name taken from a variable;
  - a shell, `eval` or `source`;
  - inline code for Python, Perl, Ruby or Node;
  - `sudo -s`.
- **Read-only hosts accept only plain inspection.**
  - The command must be named plainly or from the system's `bin` folders, so a planted `./ls` or `/tmp/ls` is
    refused.
  - Variables like `PATH=` or `LD_PRELOAD=` can't be set; only locale, time zone, terminal size and turning a
    pager off are allowed.
  - Inspection tools are refused when given options that write or run something:
    - `sed` with `w` or `e`, and `awk` with `system()` or a pipe;
    - `sort -o`, and a second operand to `uniq`;
    - `git log --output`, `curl -D` and `-o` (except `-o /dev/null`);
    - `ip netns exec`, and `date -s`.
- **Paths can't climb out of an allowlisted folder.** `write_file /srv/app/*` doesn't cover
  `/srv/app/../../etc/cron.d/job`.

The core of the per-command allowlist check, from `CommandGuard.decide`:

```swift
// Each command in the line must be allowlisted or read-only: `df *` covers `df -h | grep sda`,
// not `df -h; mv /srv/app /tmp`.
let segments = ShellWords.commands(normalizedForScan(trimmed))
var matched: String?
for segment in segments {
    if let pattern = allowlistMatch(segment, patterns: allowlist) { matched = matched ?? pattern; continue }
    if isReadOnly(segment) { continue }
    return .ask(segments.count > 1 ? "Part of this command is not on this host's allowlist: \(segment)" : "Not on this host's allowlist.")
}
```

`Tests/ReachlyAgentTests/GuardEvasionTests.swift` holds 97 attack cases, and each one must stop for a person
or be refused:

- the disguises above;
- commands chained onto an allowlisted one;
- read-only tools given options that write or run something;
- paths that climb out of a folder.

It also checks that 38 ordinary commands still run, such as `df -h | grep`, `sed -n '1,50p'`, `curl -s -o /dev/null -w '%{http_code}'` and
`systemctl restart nginx && systemctl status nginx`. The guard as it was before 1.1.3 lets 84 of the 97 attacks
through.

**Limits of a pattern-based guard.** No set of patterns can foresee every way a shell can be told to do
something, so:

- keep production hosts on *ask* or *read-only*, and use *allowlist* for lab machines;
- read-only mode stops a host from being changed, not data from leaving it: `curl`, `dig` and `ping` are
  inspection tools and can carry what a command printed;
- inspection tools run on files the server controls can still use those files' own features, for example a
  repository's git configuration.

## Prompt injection

Text from a server (a log line, a file, a banner) can be written to steer the model. Reachly defends in two layers:

1. **Host text is marked as data.**
   - Command output, file contents and the terminal buffer reach the model inside `<command_output>`, `<file>`
     and `<terminal_buffer>` tags.
   - The system prompt tells the model that everything inside them comes from a remote machine and is never
     instructions.
   - Since 1.1.2, a wrapper tag inside that text is escaped (`&lt;/command_output>`), so a log line cannot pretend
     the output has ended and continue as if it were someone else speaking. The escaping, from
     `Sources/ReachlyAgent/Tools/AgentToolRunner.swift`, runs on command output, file contents and the
     terminal buffer:

     ```swift
     nonisolated static func neutralizingWrapperTags(_ text: String) -> String {
         guard text.contains("<"),
               let tag = try? NSRegularExpression(pattern: #"<(\s*/?\s*(?:command_output|file|terminal_buffer))(?=[\s>/]|$)"#, options: [.caseInsensitive])
         else { return text }
         return tag.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "&lt;$1")
     }
     ```
2. **The guardrails don't depend on the model.** If the model is fooled anyway, what it asks for still goes through
   the per-host check above: a destructive command waits for a person, and a read-only host refuses changes
   outright.

`Tests/ReachlyAgentTests/PromptInjectionTests.swift` attacks both layers:

- output, files and terminal text that try to close their wrapper;
- a model that obeys an injected order on an allowlist host, where the command stops for approval, is denied and
  never runs;
- the same on a read-only host, where commands and file writes are refused without asking;
- ordinary markup that must pass through unchanged.

**Not done yet:** there is no classifier that detects injected text. A fooled model can still propose commands, and
run read-only or allowlisted ones, so keep production hosts in *ask* or *read-only*.

## Keys and secrets

- **Storage.** SSH keys, passwords and API keys are kept in the macOS Keychain, behind Touch ID when the vault is
  locked. Each AI provider's key is sent only to that provider's own endpoint. A redirect to another server is
  reported instead of being followed with the key.
- **Folder uploads** to the assistant leave out files that look like keys or credentials.
- **Export.** The `.reachly` export file is encrypted.

## Not sandboxed

The app does not use the macOS App Sandbox. An SSH client has to:

- read `~/.ssh` (config, keys, `known_hosts`);
- open connections to any host and port the user chooses;
- start helper processes (Qoder, MCP bridges);
- open serial devices.

The sandbox would need temporary-exception entitlements for most of that.

What protects you instead:

- keys stay in the Keychain;
- the per-host policy and approvals;
- the audit log;
- a local MCP server that requires a token;
- no telemetry and no account: hosts live in a local database.

Reviewing the sandbox again is planned before any App Store build.

## What is live and what is seeded

- **The demo video's AI scenes ran live.**
  - The model was CAIMEx DeepSeek V4 Flash.
  - The servers were four Docker machines on the recording Mac, reached over real SSH through a jump host.
  - Every command went through the guard and is in the audit log.
- **The README's chat screenshots are seeded.** The finished conversation comes from `--qa-agent-demo`, a flag
  that only Debug builds read; `--seed-demo` and the scripted UI checks are Debug-only too. Release builds don't
  contain that code, because it is compiled out with `#if DEBUG`. The 1.1.2 release binary has none of those flag
  names in it, which you can check with `strings` on the app in the release ZIP.

## Builds and updates

- **Signing.** Releases are built by GitHub Actions from a tagged commit and ad-hoc signed. They are not yet
  signed with an Apple Developer ID, so they are not notarized, and the hardened runtime is off.
- **What an update does.** The in-app updater checks the feed and offers the new version as a download. It cannot
  install in place, because macOS blocks unsigned automatic installs.
- **Verifying a download.** Each release publishes a `SHA256SUMS` file.
- **With a Developer ID** (planned), builds get the hardened runtime, notarization, and Sparkle updates that
  install in place.

## Reporting a problem

Open a [security advisory](https://github.com/Edwardrem/Reachly/security/advisories/new) on GitHub (private), or an
issue for anything that is not sensitive.
