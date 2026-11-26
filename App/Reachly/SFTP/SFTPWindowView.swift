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
    @State private var pendingDelete: DeleteRequest?

    enum PaneSheet: Identifiable {
        case newFolder(SFTPWindowModel.Side)
        case newFile(SFTPWindowModel.Side)
        case rename(SFTPWindowModel.Side, FileItem)
        case move(SFTPWindowModel.Side, [FileItem])
        case permissions(SFTPWindowModel.Side, [FileItem])

        var id: String {
            switch self {
            case .newFolder(let side): "newFolder-\(side)"
            case .newFile(let side): "newFile-\(side)"
            case .rename(_, let item): "rename-\(item.path)"
            case .move(let side, let items): "move-\(side)-\(items.count)"
            case .permissions(_, let items): "permissions-\(items.count)"
            }
        }

        var side: SFTPWindowModel.Side {
            switch self {
            case .newFolder(let side), .newFile(let side), .rename(let side, _), .move(let side, _), .permissions(let side, _): side
            }
        }
    }

    /// A delete waiting for the user to confirm it, with the items as they were when it was asked for.
    struct DeleteRequest {
        let side: SFTPWindowModel.Side
        let source: PaneSource
        /// The host's name (or "This Mac").
        let place: String
        let items: [FileItem]

        var title: String {
            items.count == 1 ? "Delete “\(FileNaming.displayed(items[0].name))”?" : "Delete \(items.count) items?"
        }

        var message: String {
            guard source.isRemote else { return "Local items are moved to the Trash." }
            let folders = items.filter { $0.isDirectory && !$0.isSymlink }.count
            guard items.count == 1 else {
                let inside = folders == 0 ? "" : folders == 1 ? ", with everything in the folder" : ", with everything in the folders"
                return "They are removed permanently from \(place)\(inside). This can't be undone."
            }
            return "It is removed permanently from \(place)\(folders == 1 ? ", with everything in it" : ""). This can't be undone."
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                pane(.left)
                pane(.right)
            }
            messages
            Divider()
            TransferListView(queue: model.queue)
                .frame(height: 170)
        }
        // The Files menu's commands and their shortcuts (`FilesCommands`), live while this window is in front.
        .focusedSceneValue(\.filesWindow, menuCommands)
        .background(FilesWindowReader())
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
                    sheet = .newFile(model.focusedSide)
                } label: {
                    Label("New File", systemImage: "doc.badge.plus")
                }
                .help("Create an empty file in the focused pane")
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
                    confirmDelete(model.focusedPane.selectedItems, on: model.focusedSide)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(model.focusedPane.selection.isEmpty)
                Button(action: reloadFocusedPane) {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
                .help("Reload the focused pane")
            }
        }
        .confirmationDialog(pendingDelete?.title ?? "", isPresented: isConfirmingDelete, titleVisibility: .visible, presenting: pendingDelete) { request in
            Button("Delete", role: .destructive) { delete(request) }
        } message: { request in
            Text(request.message)
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .newFolder(let side):
                let pane = model.pane(side)
                let names = names(in: pane)
                NameSheet(title: "New Folder", prompt: "untitled folder", initial: FileNaming.uniqueName("untitled folder", existing: names), existing: names) { name in
                    Task { await pane.makeDirectory(named: name) }
                }
            case .newFile(let side):
                let pane = model.pane(side)
                let names = names(in: pane)
                NameSheet(title: "New File", prompt: "untitled.txt", initial: FileNaming.uniqueName("untitled.txt", existing: names), existing: names) { name in
                    Task { await pane.createFile(named: name) }
                }
            case .rename(let side, let item):
                let pane = model.pane(side)
                NameSheet(title: "Rename \(item.name)", prompt: item.name, initial: item.name, existing: names(in: pane).subtracting([item.name])) { name in
                    guard name != item.name else { return }
                    Task { await pane.rename(item, to: name) }
                }
            case .move(let side, let items):
                let pane = model.pane(side)
                MoveSheet(items: items, folder: pane.path, canChoose: !pane.source.isRemote) { directory in
                    Task { await pane.move(items, toDirectory: directory) }
                }
            case .permissions(let side, let items):
                PermissionsSheet(items: items) { mode in
                    Task { await model.pane(side).setMode(mode, for: items) }
                }
            }
        }
        .onChange(of: model.left.source) { _, _ in dropRequests(for: .left) }
        .onChange(of: model.right.source) { _, _ in dropRequests(for: .right) }
        .onDisappear { model.stop() }
    }

    private func pane(_ side: SFTPWindowModel.Side) -> some View {
        FileBrowserPane(model: model, side: side, hosts: hosts, present: { sheet = $0 }, confirmDelete: { confirmDelete($0, on: side) })
            .frame(minWidth: 320)
    }

    /// Operation failures for each pane, then the window's own status, under the panes.
    @ViewBuilder
    private var messages: some View {
        let failures = [SFTPWindowModel.Side.left, .right].compactMap { side in model.pane(side).operationMessage.map { (side, $0) } }
        let status = model.status ?? model.openWith.message
        if !failures.isEmpty || status != nil {
            Divider()
            VStack(alignment: .leading, spacing: 3) {
                ForEach(failures, id: \.0) { side, message in
                    Label {
                        Text("\(paneName(side)): \(message)")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
                if let status {
                    Text(status).foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .lineLimit(2)
            .textSelection(.enabled)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The pane's title, with the side when both panes show the same place.
    private func paneName(_ side: SFTPWindowModel.Side) -> String {
        let title = model.pane(side).title
        guard model.left.title == model.right.title else { return title }
        return "\(title) (\(side == .left ? "left" : "right"))"
    }

    /// Every name in the pane's folder, hidden ones too.
    private func names(in pane: PaneModel) -> Set<String> {
        Set(pane.items.map(\.name))
    }

    // MARK: Menu commands

    /// The Files menu's view of this window. Each action checks again when it runs, as the menu can lag behind.
    private var menuCommands: FilesWindowCommands {
        FilesWindowCommands(
            isIdle: isIdle,
            hasSelection: !model.focusedPane.selection.isEmpty,
            fileListHasFocus: model.focusedFileList == model.focusedSide,
            reload: { if canAct { reloadFocusedPane() } },
            newFile: { if canAct { sheet = .newFile(model.focusedSide) } },
            newFolder: { if canAct { sheet = .newFolder(model.focusedSide) } },
            duplicate: { if canAct { duplicateSelection() } },
            moveTo: {
                let items = model.focusedPane.selectedItems
                if canAct, !items.isEmpty { sheet = .move(model.focusedSide, items) }
            },
            delete: { if canAct { confirmDelete(model.focusedPane.selectedItems, on: model.focusedSide) } })
    }

    /// No sheet or confirmation is open, so a menu command may act on the panes.
    private var isIdle: Bool { sheet == nil && pendingDelete == nil }

    /// A Files menu command may run now: this window is the key window (checked as it runs, as the main-window
    /// commands do) and nothing is open on it.
    private var canAct: Bool { FilesWindow.isKey && isIdle }

    private func reloadFocusedPane() {
        let pane = model.focusedPane
        Task { await pane.refresh() }
    }

    private func duplicateSelection() {
        let pane = model.focusedPane
        let items = pane.selectedItems
        guard !items.isEmpty else { return }
        Task { await pane.duplicate(items) }
    }

    private var isConfirmingDelete: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private func confirmDelete(_ items: [FileItem], on side: SFTPWindowModel.Side) {
        guard !items.isEmpty else { return }
        pendingDelete = DeleteRequest(side: side, source: model.pane(side).source, place: model.pane(side).title, items: items)
    }

    private func delete(_ request: DeleteRequest) {
        let pane = model.pane(request.side)
        // The pane may have switched to another host or the Mac while the dialog was open: never delete there.
        guard pane.source == request.source else {
            model.status = "Nothing was deleted: the pane shows \(pane.title) now."
            return
        }
        Task { await pane.delete(request.items) }
    }

    /// Closes a sheet or confirmation that was opened for a pane that has since switched to another host or the Mac.
    private func dropRequests(for side: SFTPWindowModel.Side) {
        if pendingDelete?.side == side { pendingDelete = nil }
        if sheet?.side == side { sheet = nil }
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

/// Asks for a name (new file, new folder, rename), checked as it is typed.
struct NameSheet: View {
    let title: String
    let prompt: String
    let initial: String
    /// Names already in the folder; one of them is refused here rather than failing later.
    var existing: Set<String> = []
    let commit: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @FocusState private var focused: Bool

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }

    /// Why the name can't be used, or nil when it can.
    private var problem: String? {
        if let error = FileNaming.validationError(for: trimmed) { return error }
        if existing.contains(trimmed) { return "An item named “\(trimmed)” is already in this folder." }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                TextField("Name", text: $name, prompt: Text(prompt))
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit(submit)
                if let problem {
                    Text(problem).font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("OK", action: submit).keyboardShortcut(.defaultAction).disabled(problem != nil)
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
        guard problem == nil else { return }
        commit(trimmed)
        dismiss()
    }
}

/// Asks for the folder to move items into, on the same side.
struct MoveSheet: View {
    let items: [FileItem]
    /// The folder the items are in now; the field starts there.
    let folder: String
    /// Panes on this Mac can pick the folder with an open panel.
    let canChoose: Bool
    let commit: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var path = ""
    @FocusState private var focused: Bool

    private var trimmed: String { path.trimmingCharacters(in: .whitespaces) }

    /// Something other than the folder the items are already in.
    private var canMove: Bool {
        let target = Self.withoutTrailingSlash(trimmed)
        return !target.isEmpty && target != "." && target != Self.withoutTrailingSlash(folder)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(items.count == 1 ? "Move “\(items[0].name)”" : "Move \(items.count) Items").font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    TextField("Folder", text: $path, prompt: Text(folder))
                        .textFieldStyle(.roundedBorder)
                        .font(.callout.monospaced())
                        .focused($focused)
                        .onSubmit(submit)
                    if canChoose {
                        Button("Choose…", action: choose)
                    }
                }
                Text("A full path, or one relative to the current folder.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Move", action: submit).keyboardShortcut(.defaultAction).disabled(!canMove)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            path = folder
            focused = true
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = URL(fileURLWithPath: trimmed.hasPrefix("/") ? trimmed : folder)
        if panel.runModal() == .OK, let url = panel.url { path = url.path }
    }

    private func submit() {
        guard canMove else { return }
        commit(trimmed)
        dismiss()
    }

    private static func withoutTrailingSlash(_ path: String) -> String {
        var path = path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
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
