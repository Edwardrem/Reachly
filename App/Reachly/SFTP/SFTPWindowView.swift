import AppKit
import SwiftData
import SwiftUI
import ReachlyCore
import ReachlySSH
import ReachlyTerminal
import UniformTypeIdentifiers

/// The Files window: a local pane on the left, a remote pane on the right,
/// drag-and-drop between them, and the transfer queue underneath.
struct SFTPWindowView: View {
    @Environment(AppState.self) private var appState
    @Environment(Workspace.self) private var workspace
    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\SSHHost.sortOrder), SortDescriptor(\SSHHost.name)]) private var hosts: [SSHHost]
    @State private var model: SFTPWindowModel?

    var body: some View {
        Group {
            if let model {
                SFTPWindowContent(model: model, hosts: hosts)
            } else {
                ProgressView()
            }
        }
        .task {
            if model == nil {
                let created = SFTPWindowModel(workspace: workspace, context: modelContext)
                model = created
                await created.start(hostID: appState.sftpHostID ?? hosts.first?.uuid)
            }
        }
        .onChange(of: appState.sftpHostID) { _, hostID in
            guard let model, let hostID else { return }
            Task { await model.showHost(hostID, in: .right) }
        }
        .frame(minWidth: 900, minHeight: 520)
    }
}

struct SFTPWindowContent: View {
    @Bindable var model: SFTPWindowModel
    let hosts: [SSHHost]
    @State private var sheet: PaneSheet?
    @State private var isConfirmingDelete = false

    enum PaneSheet: Identifiable {
        case newFolder(SFTPWindowModel.Side)
        case rename(SFTPWindowModel.Side, FileItem)
        case permissions(SFTPWindowModel.Side, [FileItem])

        var id: String {
            switch self {
            case .newFolder(let side): "newFolder-\(side)"
            case .rename(_, let item): "rename-\(item.path)"
            case .permissions(_, let items): "permissions-\(items.count)"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                FileBrowserPane(model: model, side: .left, hosts: hosts) { sheet = $0 }
                    .frame(minWidth: 320)
                FileBrowserPane(model: model, side: .right, hosts: hosts) { sheet = $0 }
                    .frame(minWidth: 320)
            }
            Divider()
            TransferListView(queue: model.queue)
                .frame(height: 170)
            if let status = model.status ?? model.openWith.message {
                Divider()
                Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1).padding(.horizontal, 10).padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    Task { await transferSelection() }
                } label: {
                    Label(model.focusedSide == .left ? "Copy to Right" : "Copy to Left", systemImage: model.focusedSide == .left ? "arrow.right.square" : "arrow.left.square")
                }
                .disabled(model.focusedPane.selection.isEmpty)
                .help("Copy the selected items to the other pane")
                Button {
                    sheet = .newFolder(model.focusedSide)
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
                Button {
                    guard let item = model.focusedPane.selectedItems.first, model.focusedPane.selection.count == 1 else { return }
                    sheet = .rename(model.focusedSide, item)
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                .disabled(model.focusedPane.selection.count != 1)
                Button {
                    sheet = .permissions(model.focusedSide, model.focusedPane.selectedItems)
                } label: {
                    Label("Permissions", systemImage: "lock")
                }
                .disabled(model.focusedPane.selection.isEmpty)
                Button(role: .destructive) {
                    isConfirmingDelete = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(model.focusedPane.selection.isEmpty)
                Button {
                    Task { await model.focusedPane.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
        .confirmationDialog("Delete \(model.focusedPane.selection.count) item(s)?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                let pane = model.focusedPane
                Task { await pane.delete(pane.selectedItems) }
            }
        } message: {
            Text(model.focusedPane.source.isRemote ? "Files on the host are removed permanently; folders are emptied first." : "Local items are moved to the Trash.")
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .newFolder(let side):
                NameSheet(title: "New Folder", prompt: "untitled folder", initial: "") { name in
                    Task { await model.pane(side).makeDirectory(named: name) }
                }
            case .rename(let side, let item):
                NameSheet(title: "Rename \(item.name)", prompt: item.name, initial: item.name) { name in
                    Task { await model.pane(side).rename(item, to: name) }
                }
            case .permissions(let side, let items):
                PermissionsSheet(items: items) { mode in
                    Task { await model.pane(side).setMode(mode, for: items) }
                }
            }
        }
        .onDisappear { model.stop() }
    }

    private func transferSelection() async {
        let source = model.focusedPane
        await model.transfer(source.selectedItems, from: source, to: model.otherPane)
    }
}

/// The transfer queue list with progress, pause, resume and cancel.
struct TransferListView: View {
    let queue: TransferQueue

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Transfers").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if queue.pendingCount > 0 {
                    Text("\(queue.pendingCount) pending").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Pause All") { queue.pauseAll() }.disabled(queue.activeCount == 0)
                Button("Clear Finished") { queue.clearFinished() }.disabled(!queue.items.contains { $0.state.isFinished })
            }
            .controlSize(.small)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            Divider()
            if queue.items.isEmpty {
                Text("Drag files between the panes, or select items and use Copy. Transfers can be paused and resumed; interrupted ones continue where they stopped.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
            } else {
                List(queue.items.reversed()) { item in
                    TransferRow(item: item, queue: queue)
                }
                .listStyle(.plain)
            }
        }
    }
}

private struct TransferRow: View {
    let item: TransferItem
    let queue: TransferQueue

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.displayName).lineLimit(1)
                    Text(direction).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if item.state == .running || item.state == .paused {
                    ProgressView(value: item.fraction ?? 0)
                        .progressViewStyle(.linear)
                        .opacity(item.fraction == nil ? 0.4 : 1)
                }
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            switch item.state {
            case .running, .queued:
                Button { queue.pause(item.id) } label: { Image(systemName: "pause.fill") }.buttonStyle(.borderless).help("Pause")
                Button { queue.cancel(item.id) } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Cancel")
            case .paused, .failed:
                Button { queue.resume(item.id) } label: { Image(systemName: "play.fill") }.buttonStyle(.borderless).help("Resume")
                Button { queue.remove(item.id) } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Remove")
            case .completed, .cancelled:
                Button { queue.remove(item.id) } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Remove")
            }
        }
        .padding(.vertical, 2)
    }

    private var direction: String {
        switch item.kind {
        case .download: "\(item.hostName) → Mac"
        case .upload: "Mac → \(item.hostName)"
        case .copyBetweenHosts(_, let target, _): "\(item.hostName) → \(target) via Mac"
        }
    }

    private var detail: String {
        let done = ByteCountFormatter.string(fromByteCount: item.transferred, countStyle: .file)
        let total = item.total.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        switch item.state {
        case .queued: return "Waiting" + (total.map { " · \($0)" } ?? "")
        case .running:
            var parts = [total.map { "\(done) of \($0)" } ?? done]
            if let rate = item.rate { parts.append(ByteCountFormatter.string(fromByteCount: Int64(rate), countStyle: .file) + "/s") }
            return parts.joined(separator: " · ")
        case .paused: return "Paused at \(done)" + (total.map { " of \($0)" } ?? "")
        case .completed: return "Done · \(done)"
        case .failed(let message): return "Failed: \(message)"
        case .cancelled: return "Cancelled"
        }
    }

    private var icon: String {
        switch item.state {
        case .queued: "clock"
        case .running: item.kind == .upload ? "arrow.up.circle" : "arrow.down.circle"
        case .paused: "pause.circle"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "xmark.circle"
        }
    }

    private var color: Color {
        switch item.state {
        case .completed: .green
        case .failed: .orange
        case .cancelled: .secondary
        default: .accentColor
        }
    }
}

/// Asks for a name (new folder, rename).
struct NameSheet: View {
    let title: String
    let prompt: String
    let initial: String
    let commit: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            TextField("Name", text: $name, prompt: Text(prompt))
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(submit)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("OK", action: submit).keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || name.contains("/"))
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            name = initial
            focused = true
        }
    }

    private func submit() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.contains("/") else { return }
        commit(trimmed)
        dismiss()
    }
}

/// chmod: a grid of r/w/x checkboxes and the octal value.
struct PermissionsSheet: View {
    let items: [FileItem]
    let commit: (UInt32) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var mode: UInt32 = 0o644
    @State private var octal = "644"

    private let rows: [(String, Int)] = [("Owner", 6), ("Group", 3), ("Others", 0)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(items.count == 1 ? "Permissions for \(items[0].name)" : "Permissions for \(items.count) items").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("")
                    Text("Read").font(.caption).foregroundStyle(.secondary)
                    Text("Write").font(.caption).foregroundStyle(.secondary)
                    Text("Execute").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(rows, id: \.0) { row in
                    GridRow {
                        Text(row.0)
                        ForEach([4, 2, 1], id: \.self) { bit in
                            Toggle("", isOn: Binding(
                                get: { mode & (UInt32(bit) << row.1) != 0 },
                                set: { on in
                                    if on { mode |= UInt32(bit) << row.1 } else { mode &= ~(UInt32(bit) << row.1) }
                                    octal = String(mode & 0o777, radix: 8)
                                }))
                            .labelsHidden()
                        }
                    }
                }
            }
            HStack {
                Text("Octal")
                TextField("644", text: $octal)
                    .frame(width: 70)
                    .font(.body.monospaced())
                    .onChange(of: octal) { _, value in
                        if let parsed = UInt32(value, radix: 8), parsed <= 0o7777 { mode = parsed }
                    }
                Text(SFTP.Attributes(permissions: mode | 0o100000).modeString).font(.body.monospaced()).foregroundStyle(.secondary)
            }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Apply") { commit(mode & 0o7777); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            if let first = items.first?.mode {
                mode = first
                octal = String(first & 0o777, radix: 8)
            }
        }
    }
}
