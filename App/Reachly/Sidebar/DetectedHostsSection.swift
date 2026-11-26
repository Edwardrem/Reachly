import AppKit
import Observation
import ReachlyCore
import SwiftUI

/// Servers `~/.ssh/known_hosts` trusts, read off the main actor. The files are
/// parsed again only when one of them changed; the sidebar filters the result
/// against the live hosts, so an added server drops out at once.
@MainActor @Observable
final class DetectedHostsModel {
    private(set) var scan = SystemKnownHosts.Scan.empty
    @ObservationIgnored private var stamps: [SystemKnownHosts.FileStamp?]?
    @ObservationIgnored private var isRefreshing = false

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let previous = stamps
        let result = await Task.detached(priority: .utility) { () -> (SystemKnownHosts.Scan, [SystemKnownHosts.FileStamp?])? in
            let current = SystemKnownHosts.stamps()
            guard current != previous else { return nil }
            return (SystemKnownHosts.load(), current)
        }.value
        guard let result else { return }
        stamps = result.1
        if result.0 != scan { scan = result.0 }
    }
}

extension View {
    /// Scans on appear and whenever the app becomes active; never polls.
    func detectsKnownHosts(_ model: DetectedHostsModel) -> some View {
        task { await model.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task { await model.refresh() }
            }
    }
}

/// "Detected on this Mac": servers in `~/.ssh/known_hosts` that are not in Reachly yet.
struct DetectedHostsSection: View {
    let suggestions: SystemKnownHosts.Suggestions
    let scan: SystemKnownHosts.Scan
    @Binding var isExpanded: Bool
    let add: (SystemKnownHosts.Server) -> Void
    let hide: ([SystemKnownHosts.Server]) -> Void
    let showHidden: () -> Void

    var body: some View {
        Section(isExpanded: $isExpanded) {
            ForEach(suggestions.servers) { server in
                DetectedHostRow(server: server, add: { add(server) }, hide: { hide([server]) })
            }
            if suggestions.hiddenCount > 0 {
                Button(action: showHidden) {
                    Text("Show \(suggestions.hiddenCount) hidden")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .selectionDisabled()
            }
            if scan.hashedEntryCount > 0 {
                Text(scan.hashedEntryCount == 1 ? "1 hashed entry can't be listed." : "\(scan.hashedEntryCount) hashed entries can't be listed.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .help("ssh stored these names as hashes (HashKnownHosts), so they can't be read back.")
                    .selectionDisabled()
            }
            if scan.isTruncated {
                Text("Only the first \(SystemKnownHosts.maximumServers.formatted()) servers are listed.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .selectionDisabled()
            }
        } header: {
            HStack(spacing: 6) {
                Text("Detected on this Mac")
                    .font(.callout.weight(.semibold))
                Text("\(suggestions.servers.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.18), in: Capsule())
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .help("Servers this Mac already trusts in ~/.ssh/known_hosts. Adding one saves it as a host and trusts the same key in Reachly.")
            .contextMenu {
                Button("Hide All") { hide(suggestions.servers) }
                if suggestions.hiddenCount > 0 {
                    Button("Show \(suggestions.hiddenCount) Hidden", action: showHidden)
                }
            }
        }
    }
}

/// A detected server: its name, the target Add would save, and the two actions.
struct DetectedHostRow: View {
    let server: SystemKnownHosts.Server
    let add: () -> Void
    let hide: () -> Void
    @Environment(ThemeStore.self) private var themes
    @State private var isHovering = false

    var body: some View {
        let compact = themes.appearance.compactSidebar
        HStack(spacing: compact ? 8 : 12) {
            IconTile(systemImage: "server.rack", color: .gray, size: compact ? 22 : 34)
                .opacity(0.75)
            VStack(alignment: .leading, spacing: 1) {
                Text(server.hostname)
                    .font(compact ? .body : .system(size: Design.sidebarTextSize, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !compact {
                    Text(target)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
            Button(action: hide) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Hide")
            .opacity(isHovering ? 1 : 0)
            .accessibilityHidden(true)
            Button("Add", action: add)
                .controlSize(.small)
                .help("Add \(server.hostname) to Hosts")
        }
        .padding(.vertical, compact ? 2 : 5)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .help(summary)
        .contextMenu {
            Button("Add to Hosts", action: add)
            Button("Hide", action: hide)
        }
        .accessibilityAction(named: "Hide", hide)
        .selectionDisabled()
    }

    /// `user@host[:port]`, as the saved host will show it.
    private var target: String {
        let user = server.configUser ?? NSUserName()
        return server.port == 22 ? "\(user)@\(server.hostname)" : "\(user)@\(server.hostname):\(server.port)"
    }

    private var summary: String {
        var lines: [String] = []
        if server.keys.isEmpty {
            lines.append("In ~/.ssh/known_hosts. Reachly will ask you to confirm its key on the first connection.")
        } else {
            let types = server.keys.map(\.keyType).joined(separator: ", ")
            lines.append("In ~/.ssh/known_hosts with \(types). Adding it trusts the same \(server.keys.count == 1 ? "key" : "keys") in Reachly.")
        }
        if !server.aliases.isEmpty {
            lines.append("Also listed as \(server.aliases.map(\.description).joined(separator: ", ")).")
        }
        return lines.joined(separator: "\n")
    }
}
