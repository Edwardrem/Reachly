#if DEBUG
import Foundation
import SwiftData
import ReachlyAgent
import ReachlyCore
import ReachlySSH

/// Sample records for screenshots and manual QA. Debug builds only, and only
/// when launched with `--seed-demo` against an empty store (pair it with
/// `REACHLY_DATA_DIR` and `REACHLY_KEYCHAIN_SERVICE` to keep real data untouched).
@MainActor
enum DemoData {
    static func seedIfEmpty(in context: ModelContext) {
        let hostCount = (try? context.fetchCount(FetchDescriptor<SSHHost>())) ?? 0
        let identityCount = (try? context.fetchCount(FetchDescriptor<Identity>())) ?? 0
        guard hostCount == 0, identityCount == 0 else { return }

        let group = HostGroup(name: "Lab", sortOrder: 0, colorLabel: "#5E9CFF")
        context.insert(group)
        let productionGroup = HostGroup(name: "Production", sortOrder: 1, colorLabel: "#FF5F57")
        context.insert(productionGroup)
        context.insert(HostGroup(name: "Staging", sortOrder: 2))

        do {
            let pair = try SSHKeyPair.generate(.ed25519, comment: "demo@reachly")
            let key = try IdentityOperations.createKeychainIdentity(name: "Demo Ed25519", username: "deploy", pair: pair, in: context)
            let admin = try IdentityOperations.createPasswordIdentity(name: "Lab admin", username: "admin", password: "demo-password", in: context)
            let bastion = SSHHost(name: "bastion", hostname: "bastion.example.org", username: "jump", authMethod: .privateKey, tags: ["jump"], colorLabel: "#FF9F0A", identity: key)
            context.insert(bastion)
            let buildBox = SSHHost(name: "build-box", hostname: "10.0.0.5", username: "ubuntu", authMethod: .privateKey, tags: ["ci"], colorLabel: "#34C759", group: group, identity: key)
            buildBox.jumpHost = bastion
            buildBox.themeID = "builtin:nord"
            context.insert(buildBox)
            context.insert(SSHHost(name: "router", hostname: "192.168.1.1", username: "admin", authMethod: .privateKey, sortOrder: 1, group: group, identity: admin))
            context.insert(SSHHost(name: "web-01", hostname: "web-01.example.org", username: "deploy", authMethod: .privateKey, tags: ["web"], sortOrder: 0, group: productionGroup, identity: key))
            context.insert(SSHHost(name: "db-01", hostname: "10.1.0.12", username: "deploy", authMethod: .privateKey, tags: ["db"], sortOrder: 1, group: productionGroup, identity: key))
            let production = SSHHost(name: "example.org", hostname: "example.org", username: "me", authMethod: .password)
            production.backgroundTint = "#FF5F57"
            production.watermark = "PROD"
            production.agentPermission = .readOnly
            context.insert(production)
            context.insert(PortForwardRule(name: "Postgres on build-box", kind: .local, bindPort: 15432, targetHost: "localhost", targetPort: 5432, autoStart: true, host: buildBox))
            context.insert(PortForwardRule(name: "Browser via bastion", kind: .dynamic, bindPort: 1080, host: bastion))
            context.insert(PortForwardRule(name: "Expose dev server", kind: .remote, bindAddress: "0.0.0.0", bindPort: 8080, targetHost: "localhost", targetPort: 3000, host: production))
            group.defaultJumpHost = bastion
            group.themeID = "builtin:gruvbox-dark"
            seedAuditLog(buildBox: buildBox, bastion: bastion, production: production, in: context)
        } catch {
            print("DemoData: \(error)")
        }

        context.insert(SerialProfile(name: "Lab switch", devicePath: "/dev/cu.usbserial-1420", baudRate: 9600, colorLabel: "#BF5AF2"))
        if let scheme = try? TerminalTheme.bundled(id: "builtin:dracula")?.asUserTheme(named: "Dracula (mine)").encodedJSON() {
            context.insert(TerminalThemeRecord(name: "Dracula (mine)", schemeJSON: scheme, source: "editor"))
        }

        let ops = SnippetFolder(name: "Ops", sortOrder: 0)
        context.insert(ops)
        let diskUsage = Snippet(name: "Disk usage", command: "df -h", tags: ["disk"], sortOrder: 0, folder: ops)
        context.insert(diskUsage)
        context.insert(Snippet(name: "Tail a log", command: "tail -n {{lines:100}} -f {{file:/var/log/syslog}}", tags: ["logs"], sortOrder: 1, folder: ops))
        context.insert(Snippet(name: "Who is logged in", command: "who", sortOrder: 2))
        context.insert(Snippet(name: "Update packages", command: "sudo apt update && sudo apt upgrade -y", tags: ["apt"], notes: "Debian and Ubuntu only.", sortOrder: 3))

        // A host for the throwaway sshd from Scripts/test-sshd.sh, when its environment is present.
        let env = ProcessInfo.processInfo.environment
        if let port = env["REACHLY_TEST_SSH_PORT"].flatMap(Int.init), let keyPath = env["REACHLY_TEST_SSH_KEY"] {
            let identity = Identity(name: "Test sshd key", username: NSUserName(), credentialKind: .keyFile, privateKeyPath: keyPath)
            context.insert(identity)
            // REACHLY_TEST_SSH_NAME names it (screenshots show "ci-runner" rather than "local sshd");
            // REACHLY_TEST_SSH_HOSTKEY (path to the sshd's public host key) trusts it ahead of time.
            let hostname = env["REACHLY_TEST_SSH_HOST"] ?? "127.0.0.1"
            let local = SSHHost(name: env["REACHLY_TEST_SSH_NAME"] ?? "local sshd", hostname: hostname, port: port, username: NSUserName(), authMethod: .privateKey, tags: ["test"], sortOrder: 2, colorLabel: "#34C759", group: env["REACHLY_TEST_SSH_NAME"] == nil ? nil : group, identity: identity)
            local.defaultSnippet = diskUsage
            local.inheritsGroupJumpHost = false   // reachable directly, whatever the group's bastion
            context.insert(local)
            if let hostKeyPath = env["REACHLY_TEST_SSH_HOSTKEY"],
               let line = try? String(contentsOfFile: hostKeyPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
               let fingerprint = HostKeyFingerprint.sha256(openSSHPublicKey: line) {
                let keyType = String(line.split(separator: " ").first ?? "ssh-ed25519")
                Task { try? await KnownHostsStore.shared.remember(host: hostname, port: port, keyType: keyType, publicKey: line, fingerprintSHA256: fingerprint) }
            }
        }
        try? context.save()
    }

    /// Two days of agent activity for the AI History sidebar: every decision, both
    /// sources, a failed command, and commands that link back to a saved conversation.
    private static func seedAuditLog(buildBox: SSHHost, bastion: SSHHost, production: SSHHost, in context: ModelContext) {
        let messages: [AgentMessage] = [
            .user("Why is the disk on build-box filling up?"),
            AgentMessage(role: .assistant, blocks: [.text("The root volume is at 91%. Most of it is 18 GB of nginx access logs that are not rotated, and an 11 GB proxy cache.")], model: "claude-opus-5-5"),
        ]
        let conversation = AgentConversation(title: "Why is the disk on build-box filling up?", hostID: buildBox.uuid, transcript: (try? AgentTranscript.encode(messages)) ?? Data(), model: "claude-opus-5-5")
        context.insert(conversation)
        let now = Date.now
        func add(_ minutesAgo: Double, _ host: SSHHost, _ command: String, reason: String, _ decision: AgentAuditDecision, detail: String = "", proposed: String? = nil, exit: Int? = nil, milliseconds: Int? = nil, output: String = "", source: AgentActionSource = .agentPanel) {
            let target = host.port == 22 ? "\(host.username)@\(host.hostname)" : "\(host.username)@\(host.hostname):\(host.port)"
            context.insert(AgentAuditEntry(
                timestamp: now.addingTimeInterval(-minutesAgo * 60), source: source, hostID: host.uuid, hostName: host.name, hostTarget: target,
                tool: "run_command", command: command, proposedCommand: proposed, reason: reason, decision: decision, decisionDetail: detail,
                exitStatus: exit, durationMilliseconds: milliseconds, outputExcerpt: output,
                conversationID: source == .agentPanel && host === buildBox ? conversation.uuid : nil))
        }
        add(4, buildBox, "df -h / /data", reason: "See which volume is full", .autoAllowed, detail: "Read-only command.", exit: 0, milliseconds: 412,
            output: "Filesystem      Size  Used Avail Use% Mounted on\n/dev/sda1        80G   73G  7.0G  91% /\n/dev/sdb1       500G  212G  288G  42% /data")
        add(3, buildBox, "sudo du -xsh /var/log/nginx /var/cache/nginx", reason: "Find what fills the root volume", .approved, detail: "This host asks before every command.", exit: 0, milliseconds: 2_310,
            output: "18G\t/var/log/nginx\n11G\t/var/cache/nginx")
        add(2, buildBox, "rm -rf /var/cache/nginx/*", reason: "Clear the stale proxy cache", .changesRequested,
            detail: AgentAuditDecision.changesRequestedDetail(guardrail: "Destructive pattern (rm with -r or -f): always asks, whatever the host's permission mode.", comment: "Keep the cache. Rotate the logs instead.", suggestion: nil))
        add(1, buildBox, "sudo logrotate -f /etc/logrotate.d/nginx", reason: "Rotate the nginx logs", .edited, detail: "This host asks before every command.",
            proposed: "sudo logrotate -f /etc/logrotate.conf", exit: 0, milliseconds: 1_204)
        add(40, production, "systemctl restart nginx", reason: "Apply the new config", .blocked, detail: "example.org is read-only for the assistant.", source: .mcp)
        add(55, bastion, "journalctl -u sshd --since today | tail -n 20", reason: "Check for failed logins", .autoAllowed, detail: "Read-only command.", exit: 0, milliseconds: 860,
            output: "Nov 26 06:12:01 bastion sshd[1182]: Accepted publickey for jump from 203.0.113.7 port 51022", source: .mcp)
        add(26 * 60, buildBox, "sudo apt-get upgrade -y", reason: "Install security updates", .denied, detail: "This host asks before every command.")
        add(27 * 60, buildBox, "cat /etc/nginx/sites-enabled/default", reason: "Read the site config", .approved, detail: "This host asks before every command.", exit: 1, milliseconds: 95,
            output: "stderr: cat: /etc/nginx/sites-enabled/default: No such file or directory")
        add(28 * 60, bastion, "sleep 600", reason: "Wait for the deploy", .cancelled, detail: "This host asks before every command.", milliseconds: 4_000, output: "failed: The action was cancelled.", source: .mcp)
    }
}
#endif
