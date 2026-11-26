import AppKit
import Observation
import ReachlyCore
import SwiftData
import SwiftUI

/// Servers `~/.ssh/known_hosts` trusts, read off the main actor, and what the
/// sidebar lists of them. The files are parsed again only when one of them
/// changed, and the list is recomputed only when the scan, the hosts or the
/// hidden set change.
@MainActor @Observable
final class DetectedHostsModel {
    /// A calm line under the list after Add went wrong.
    struct Notice: Equatable {
        var message: String
        var detail: String
    }

    private(set) var scan = SystemKnownHosts.Scan.empty
    private(set) var suggestions = SystemKnownHosts.Suggestions()
    /// Servers whose Add is under way (their keys are being saved).
    private(set) var adding: Set<String> = []
    var notice: Notice?

    @ObservationIgnored private var existing: Set<SystemKnownHosts.Endpoint> = []
    @ObservationIgnored private var hidden: Set<String>
    @ObservationIgnored private var sources: SystemKnownHosts.Sources?
    @ObservationIgnored private var isRefreshing = false
    @ObservationIgnored private var refreshPending = false
    @ObservationIgnored private let defaults: UserDefaults

    /// Hidden servers (`SystemKnownHosts.Server.id`, comma-separated), remembered between launches.
    static let hiddenKey = "sidebar.hiddenDetectedHosts"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hidden = Set((defaults.string(forKey: Self.hiddenKey) ?? "").split(separator: ",").map(String.init))
    }

    /// Scans if any file read last time changed. A request that arrives while a
    /// scan runs is kept and run when that scan finishes.
    func refresh() async {
        guard !isRefreshing else {
            refreshPending = true
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        repeat {
            refreshPending = false
            await scanIfChanged()
        } while refreshPending
    }

    private func scanIfChanged() async {
        let previous = sources
        let result = await Task.detached(priority: .utility) { () -> (SystemKnownHosts.Scan, SystemKnownHosts.Sources)? in
            if let previous, !previous.haveChanged() { return nil }
            let loaded = SystemKnownHosts.load()
            return (loaded.scan, loaded.sources)
        }.value
        guard let result else { return }
        sources = result.1
        if result.0 != scan {
            scan = result.0
            recompute()
        }
    }

    /// The hosts' hostnames and ports, from `DetectedHostsTracker`.
    func setExisting(_ endpoints: Set<SystemKnownHosts.Endpoint>) {
        guard endpoints != existing else { return }
        existing = endpoints
        recompute()
    }

    func hide(_ servers: [SystemKnownHosts.Server]) {
        hidden.formUnion(servers.map(\.id))
        persistHidden()
    }

    func showHidden() {
        hidden = []
        persistHidden()
    }

    /// Trusts the server's keys, then saves it as a host. Returns the new host's
    /// id to select, or nil when nothing was added.
    func add(_ server: SystemKnownHosts.Server, in context: ModelContext) async -> UUID? {
        guard !adding.contains(server.id) else { return nil }
        adding.insert(server.id)
        defer { adding.remove(server.id) }
        let result = await SystemKnownHosts.add(server, to: context, store: .shared)
        guard let host = result.host else {
            notice = Notice(message: "Couldn't add \(server.hostname).", detail: result.saveError?.localizedDescription ?? "")
            return nil
        }
        // Drop the row now rather than on the next query update.
        setExisting(existing.union([SystemKnownHosts.Endpoint(host: host.hostname, port: host.port)]))
        if let trustError = result.trustError {
            notice = Notice(
                message: "Added \(server.hostname), but its key couldn't be saved in Reachly. The first connection will ask you to confirm it.",
                detail: trustError.localizedDescription)
        } else {
            notice = nil
        }
        return host.uuid
    }

    private func persistHidden() {
        defaults.set(hidden.sorted().joined(separator: ","), forKey: Self.hiddenKey)
        recompute()
    }

    private func recompute() {
        let next = SystemKnownHosts.suggestions(from: scan, existing: existing, hidden: hidden)
        if next != suggestions { suggestions = next }
    }
}

/// Feeds the model the hosts' hostnames and ports. A view of its own so that
/// only a change to the hosts re-evaluates it, not every redraw of the sidebar.
private struct DetectedHostsTracker: View {
    let model: DetectedHostsModel
    @Query private var hosts: [SSHHost]

    var body: some View {
        let endpoints = Set(hosts.map { SystemKnownHosts.Endpoint(host: $0.hostname, port: $0.port) })
        Color.clear
            .onChange(of: endpoints, initial: true) { _, endpoints in model.setExisting(endpoints) }
    }
}

extension View {
    /// Keeps the model current: scans on appear and whenever the app becomes
    /// active (never polls), and follows the hosts.
    func detectsKnownHosts(_ model: DetectedHostsModel) -> some View {
        background(DetectedHostsTracker(model: model))
            .task { await model.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task { await model.refresh() }
            }
    }
}

/// The line shown under the host list when adding a detected server went wrong.
struct DetectedHostsNoticeView: View {
    let notice: DetectedHostsModel.Notice
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ChromeDivider()
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(notice.message)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    if !notice.detail.isEmpty {
                        Text(notice.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }
                Spacer(minLength: 0)
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Dismiss")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .textSelection(.enabled)
    }
}

/// "Detected on this Mac": servers in `~/.ssh/known_hosts` that are not in Reachly yet.
struct DetectedHostsSection: View {
    let suggestions: SystemKnownHosts.Suggestions
    let scan: SystemKnownHosts.Scan
    /// Ids of servers whose Add is under way.
    let adding: Set<String>
    @Binding var isExpanded: Bool
    let add: (SystemKnownHosts.Server) -> Void
    let hide: ([SystemKnownHosts.Server]) -> Void
    let showHidden: () -> Void

    var body: some View {
        Section(isExpanded: $isExpanded) {
            ForEach(suggestions.servers) { server in
                DetectedHostRow(server: server, isAdding: adding.contains(server.id), add: { add(server) }, hide: { hide([server]) })
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
    /// True while its keys are being saved; Add can't run twice.
    let isAdding: Bool
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
            .opacity(isHovering && !isAdding ? 1 : 0)
            .disabled(isAdding)
            .accessibilityHidden(true)
            Button("Add", action: add)
                .controlSize(.small)
                .disabled(isAdding)
                .help("Add \(server.hostname) to Hosts")
        }
        .padding(.vertical, compact ? 2 : 5)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .help(summary)
        .contextMenu {
            Button("Add to Hosts", action: add)
                .disabled(isAdding)
            Button("Hide", action: hide)
                .disabled(isAdding)
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
