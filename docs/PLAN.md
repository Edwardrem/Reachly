# Reachly — Plan (No Sync, Export/Import)

_Nov 3, 2026 · Rufaro Mutepfa_

## Status

| Step | Area | State |
|---|---|---|
| 1 | SSH transport (SwiftNIO SSH) + SwiftTerm terminal + host list | **Done** (Nov 3, 2026) — see README for scope and known gaps |
| 2 | Tabs and split panes | **Done** (Nov 3, 2026) |
| 3 | GitHub Actions CI, GitHub Pages site, Sparkle updater | **Done** (Nov 3, 2026) — needs the Sparkle key and Developer ID secrets before a real release |
| 4 | Keychain vault + Touch ID, identities & keys | **Done** (Nov 3, 2026) — see README; agent forwarding and FIDO2 blocked by SwiftNIO SSH |
| 5 | Snippets and command history | **Done** (Nov 3, 2026) — folders, tags, `{{variables}}`, run in tab / all tabs / host / group, OSC 133 shell integration for bash & zsh, history with exit status, inline suggestions |
| 6 | `.reachly` export / import and `~/.ssh/config` interop | **Done** (Nov 3, 2026) — encrypted `.reachly` (Argon2id + ChaCha20-Poly1305 in Swift), reviewed import (new / changed / identical with field diff, per-record choice, pre-import backup), last 10 backups in Settings → Data, import from `~/.ssh/config`, Termius CSV, PuTTY sessions and Tabby, export to a managed `~/.ssh/config` block, `.reachly` registered as a document type |
| 7 | Claude agent panel + MCP server with guardrails | **Done** (Nov 3, 2026) — BYOK panel (Anthropic Messages API with tool use, or any OpenAI-compatible endpoint), six tools, per-host permission modes, destructive-command detection, approval sheet with Approve / Edit / Deny, audit log with JSON export, agent log tab with Esc to stop, output passed as untrusted data; MCP server (streamable HTTP on localhost + stdio bridge) with the same guardrails and a one-line config per client in Settings |
| 8 | Port forwarding | **Done** (Nov 3, 2026) — local, remote and dynamic (SOCKS5) rules per host, one-click start or auto-start on connect, live status and byte counts in the Port Forwarding sidebar, rules follow reconnects, exported in `.reachly` |
| 9 | SFTP (dual-pane browser) | **Done** (Nov 3, 2026) — SFTP v3 client in Swift, Files window with local and remote panes (either pane can point at any host for server-to-server copies via the Mac), drag and drop, transfer queue with pause / resume / cancel, folder transfers, rename, chmod, delete, new folder, open-with that re-uploads on save |
| 10 | Serial and cloud-provider host imports (AWS, DigitalOcean, Azure) | **Done** (Nov 3, 2026) — USB serial consoles (`/dev/cu.*`) with saved line settings, line-ending conversion, local echo and a hex view, in the same tabs and splits; read-only EC2 / DigitalOcean / Azure listings with Keychain credentials that add instances through the reviewed import |
| — | Jump hosts and proxies (section 6), group defaults | **Done** (Nov 3, 2026) — chained bastions over direct-tcpip channels, HTTP CONNECT and SOCKS5 proxies per host or group, group defaults for identity, jump host, proxy, theme and font |
| — | Theming (section 16) | **Done** (Nov 3, 2026) — 13 bundled schemes, editor with live sample, import from iTerm2 / Windows Terminal / VS Code / Alacritty / Ghostty, JSON export, `reachly://theme?url=` install links, bundled JetBrains Mono, cursor / contrast / opacity / blur, app appearance and accent, per-host and per-group overrides, background tint and watermark, corner badge, light / dark auto-switch by system or schedule, themes in `.reachly` |
| — | Reachly 1.0.0, the first release | **Done** (Nov 25, 2026) — app, site, repository (`Edwardrem/Reachly`), Xcode project, MCP bridge (`reachly-mcp`), release assets and cask; bundle identifier and Keychain service `io.github.edwardrem.reachly`, data in `~/Library/Application Support/Reachly`, exports as `.reachly`. Polish that went into 1.0: scheme-coloured chrome and full-screen header rows, groups as projects with drag and drop, attachments (images, PDF, Word, text, folders) and `create_document` reports, on-device dictation hardened against two macOS 26/27 crashes, chat copy / edit / rewind, transcript repair for unanswered tool calls, Caimex as a provider with a Keychain key per provider, and a chat that names the provider that answers (`docs/releases/1.0.0.md`) |
| — | Reachly 1.0.1 | **Done** (Nov 25, 2026) — the Settings tab for providers and the MCP server is renamed from Claude to AI Integration, with help text, errors, README and site docs to match (`docs/releases/1.0.1.md`) |
| — | Reachly 1.1.0 | **Done** (Nov 26, 2026) — servers from `~/.ssh/known_hosts` in the sidebar, AI providers found on this Mac with a first-launch setup sheet, key links / show-hide / masked preview, Qoder in the chat panel over ACP, comments on approvals, AI History, Files window file operations (New File, Duplicate, Move to, Copy / Cut / Paste, Files menu) with no-overwrite and Cut-only-what-arrived, a chat that follows the reply and keeps failed requests (`docs/releases/1.1.0.md`) |
| — | Reachly 1.1.1 | **Done** (Nov 26, 2026) — long chats no longer go blank (the transcript lays out every message and the streaming reply redraws at most ten times a second); the Caimex model picker lists only models tagged for tool calling and shows context, price, hosting country and training |
| — | Reachly 1.1.2 | **Done** (Nov 26, 2026) — wrapper tags inside host text are escaped so a log line cannot pose as instructions, an adversarial prompt-injection test suite, docs/SECURITY.md, a README section on verifying tests, releases and updates, and steadier CI (sshd readiness, live-test diagnostics, an MCP test race) |
| — | Reachly 1.1.4 | **Done** (Nov 26, 2026; tagged 1.1.3 first, but its test gate stopped that release) — the command guard checks each command in a line, sees through disguised destructive commands, never auto-allows what it can't read, and keeps read-only hosts to plain inspection; a guard-evasion suite of 97 attacks (1.1.2 let 84 through); releases run every test on the tagged commit and attach the report; CI writes its test count to the run summary |

## Export / import instead of sync

Dropping sync removes the whole backend and makes "open source, free, no account" literally true. Moving between Macs is a single file export and import.

- **Format.** One `.reachly` file containing versioned JSON (`"schemaVersion": 1`) so later releases can migrate older exports. Contents: hosts, groups, identities, snippets, port-forwarding rules, themes, known-hosts fingerprints, and optionally private keys.
- **Encrypted by default.** Export asks for a passphrase; the JSON is encrypted with Argon2id → ChaCha20-Poly1305 and wrapped in a small envelope (`{ "format": "reachly", "kdf": {...}, "nonce": ..., "ciphertext": ... }`). Import on the other Mac asks for the same passphrase. Plain-JSON export is a checkbox with a warning, and private keys are always excluded from a plain export.
- **Merge, don't overwrite.** Import shows a review sheet listing new, changed and identical records, with "skip duplicates" and "replace existing" per record. Each host carries a stable UUID so repeated imports never create copies.
- **Informal team sharing.** A team keeps a shared `.reachly` in Git, a shared drive or iCloud Drive and re-imports when it changes. Keys can be excluded from the team file so each person adds their own identity.
- **Interop.** Import from `~/.ssh/config`, Termius export, and PuTTY/Tabby config so switching costs nothing; export to `~/.ssh/config` too.
- **Mechanism.** SwiftData models conform to `Codable`; `NSSavePanel`/`NSOpenPanel` plus a registered `UTType` for `.reachly` so files open by double-click and drag-onto-dock. The last 10 exports are kept automatically in `~/Library/Application Support/Reachly/backups/` so a bad import is reversible.

## What's left in the plan

| Area | Decision |
|---|---|
| Storage | Everything local in SwiftData; passwords, private keys and the Anthropic API key in Keychain, unlocked with Touch ID |
| Claude integration | Unchanged: BYOK agent panel inside the app (Messages API with tool use) plus an MCP server so Claude Desktop/Code users drive it with their own subscription |
| Agent guardrails | Per-host permission mode (read-only / ask every command / allowlist), destructive-command detection always prompts, approval sheet shows the exact command, audit log, agent runs in its own PTY tab with Esc to interrupt, terminal output treated as untrusted data |
| Repo | Drop `reachly-sync/`; `ReachlyCore` gains an `Export/` module |
| Licence | MIT across the board |

## Distribution and updates via GitHub

The app updates itself from GitHub Releases, with GitHub Pages hosting the site and the update feed, so there is no server to run.

| Piece | How |
|---|---|
| Repo | `github.com/Edwardrem/Reachly` — client, docs and CI in one repo, MIT licence |
| Releases | Every tag `vX.Y.Z` publishes a GitHub Release with `Reachly-X.Y.Z.dmg`, a `.zip` for the updater, `SHA256SUMS` and release notes |
| In-app updater | Sparkle 2 with EdDSA signing; the app checks an appcast on launch and daily, shows release notes, and installs in place |
| Appcast | `appcast.xml` served from GitHub Pages (`https://edwardrem.github.io/Reachly/appcast.xml`); CI regenerates it with `generate_appcast` on each release |
| Channels | Stable feed plus an optional beta feed (`appcast-beta.xml`) from pre-releases; toggle in Settings |
| CI | GitHub Actions on `macos-latest`: build, run tests, sign with Developer ID, notarize with `notarytool`, staple, attach to the Release, push the appcast to the `gh-pages` branch |
| Secrets | Sparkle EdDSA private key, Developer ID certificate and notarization credentials stored as repository secrets |
| Site | GitHub Pages: landing page, docs, download button pointing at the latest Release, and the `.reachly` schema reference |
| Other install paths | Homebrew cask auto-bumped by CI; the Release assets double as the manual download |

No paid Apple Developer account yet: ship ad-hoc-signed builds and have the updater skip install (download only) until signing is in place, since Gatekeeper blocks unsigned auto-installs.

## Build order

Ship something usable early; each step reuses the previous one's plumbing.

1. SSH transport (SwiftNIO SSH) + SwiftTerm terminal + host list
2. Tabs and split panes
3. GitHub Actions CI, GitHub Pages site and Sparkle updater fed by GitHub Releases
4. Keychain vault + Touch ID
5. Snippets and command history
6. `.reachly` export / import and `~/.ssh/config` interop
7. Claude agent panel + MCP server with guardrails
8. Port forwarding
9. SFTP (dual-pane browser)
10. Serial and cloud-provider host imports (AWS, DigitalOcean, Azure)
