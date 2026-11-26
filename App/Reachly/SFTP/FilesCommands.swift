import AppKit
import SwiftUI

/// What the Files window offers the menu bar while it is the key window. The window publishes it with
/// `focusedSceneValue`, so it is nil whenever another window is in front.
struct FilesWindowCommands {
    /// No sheet or confirmation is open in the window.
    var isIdle: Bool
    /// The focused pane has a selection.
    var hasSelection: Bool
    /// A file list has keyboard focus, rather than the path field: only then is ⌘⌫ Delete.
    var fileListHasFocus: Bool
    var reload: @MainActor () -> Void
    var newFile: @MainActor () -> Void
    var newFolder: @MainActor () -> Void
    var duplicate: @MainActor () -> Void
    var moveTo: @MainActor () -> Void
    var delete: @MainActor () -> Void
}

struct FilesWindowCommandsKey: FocusedValueKey {
    typealias Value = FilesWindowCommands
}

extension FocusedValues {
    var filesWindow: FilesWindowCommands? {
        get { self[FilesWindowCommandsKey.self] }
        set { self[FilesWindowCommandsKey.self] = newValue }
    }
}

/// The Files menu. Its items act on the Files window only while it is the key window.
///
/// ⌘D, ⌥⌘N and ⇧⌘N also belong to main-window commands (Split Right, New Snippet, New Group). SwiftUI lets only one
/// menu item hold a key equivalent and strips it from a later duplicate, so the two sides never both carry one: these
/// items take their keys while the Files window is in front, and the main-window items give theirs up then (see
/// `ReachlyApp`). ⌘R and ⌘⌫ are used nowhere else.
struct FilesCommands: Commands {
    @FocusedValue(\.filesWindow) private var files

    var body: some Commands {
        CommandMenu("Files") {
            Button("Reload") { files?.reload() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(files?.isIdle != true)
            Divider()
            Button("New File…") { files?.newFile() }
                .keyboardShortcut(whileFront("n", [.command, .option]))
                .disabled(files?.isIdle != true)
            Button("New Folder…") { files?.newFolder() }
                .keyboardShortcut(whileFront("n", [.command, .shift]))
                .disabled(files?.isIdle != true)
            Divider()
            Button("Duplicate") { files?.duplicate() }
                .keyboardShortcut(whileFront("d", .command))
                .disabled(!canActOnSelection)
            Button("Move to…") { files?.moveTo() }
                .disabled(!canActOnSelection)
            Divider()
            Button("Delete…") { files?.delete() }
                // Only while a file list has focus, so ⌘⌫ still deletes to the start of the line in the path field.
                .keyboardShortcut(canActOnSelection && files?.fileListHasFocus == true ? KeyboardShortcut(.delete, modifiers: .command) : nil)
                .disabled(!canActOnSelection)
        }
    }

    private var canActOnSelection: Bool {
        files?.isIdle == true && files?.hasSelection == true
    }

    /// The shortcut while the Files window is in front; none otherwise, when the main window's commands use it.
    private func whileFront(_ key: KeyEquivalent, _ modifiers: EventModifiers) -> KeyboardShortcut? {
        files == nil ? nil : KeyboardShortcut(key, modifiers: modifiers)
    }
}

/// The Files window's `NSWindow`, so a main-window command can check, at the moment it runs, whether the Files window
/// is in front (the menu's enabled state can lag behind a window switch).
@MainActor
enum FilesWindow {
    static weak var window: NSWindow?

    /// True while the Files window, or a sheet or dialog on it, is the key window.
    static var isKey: Bool {
        guard let window, let key = NSApp.keyWindow else { return false }
        return key === window || key.sheetParent === window
    }

    /// Closes the Files window when it is the key window itself (not while a sheet or dialog on it is).
    static func closeIfKey() {
        guard let window, NSApp.keyWindow === window else { return }
        window.performClose(nil)
    }
}

/// Records the window it is placed in as `FilesWindow.window`.
struct FilesWindowReader: NSViewRepresentable {
    func makeNSView(context: Context) -> ReaderView { ReaderView() }
    func updateNSView(_ view: ReaderView, context: Context) {}

    final class ReaderView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { FilesWindow.window = window }
        }
    }
}
