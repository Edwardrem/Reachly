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
`Tests/ReachlyAgentTests/AgentSessionTests.swift` and `MCPServerTests.swift`.

## Prompt injection

Text from a server (a log line, a file, a banner) can be written to steer the model. Reachly defends in two layers:

1. **Host text is marked as data.**
   - Command output, file contents and the terminal buffer reach the model inside `<command_output>`, `<file>`
     and `<terminal_buffer>` tags.
   - The system prompt tells the model that everything inside them comes from a remote machine and is never
     instructions.
   - Since 1.1.2, a wrapper tag inside that text is escaped (`&lt;/command_output>`), so a log line cannot pretend
     the output has ended and continue as if it were someone else speaking.
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
