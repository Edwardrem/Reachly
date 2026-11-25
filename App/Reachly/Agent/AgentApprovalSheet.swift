import SwiftUI
import ReachlyAgent
import ReachlyCore

/// "Claude wants to run…" (or the provider answering in the panel) with the exact command, the host and the reason.
/// Approve runs it as shown, editing runs the edited text, Deny tells the model no.
struct AgentApprovalSheet: View {
    let prompt: AgentApprovalPrompt
    /// Who is answering in the panel. A request from an MCP client comes from Claude Desktop or Claude Code.
    let assistantName: String
    @Environment(\.palette) private var palette
    @State private var command: String

    init(prompt: AgentApprovalPrompt, assistantName: String) {
        self.prompt = prompt
        self.assistantName = assistantName
        _command = State(initialValue: prompt.request.command)
    }

    private var request: AgentApprovalRequest { prompt.request }
    private var requesterName: String { request.source == .mcp ? "Claude" : assistantName }
    private var isEdited: Bool { command != request.command }
    private var isEmpty: Bool { command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                IconTile(systemImage: request.isDestructive ? "exclamationmark.triangle.fill" : "sparkles", color: request.isDestructive ? .red : (palette.accent ?? .accentColor), size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(requesterName) wants to run a \(request.isDestructive ? "destructive " : "")command")
                        .font(.headline)
                    Text(request.source == .mcp ? "Requested by an MCP client (Claude Desktop or Claude Code)" : "Requested from the Claude panel")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text("Host").foregroundStyle(.secondary)
                    Text("\(request.host.name)  ·  \(request.host.target)").textSelection(.enabled)
                }
                GridRow {
                    Text("Tool").foregroundStyle(.secondary)
                    Text(request.tool).font(.body.monospaced())
                }
                GridRow {
                    Text("Reason").foregroundStyle(.secondary)
                    Text(request.reason.isEmpty ? "(none given)" : request.reason).textSelection(.enabled)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Command").foregroundStyle(.secondary)
                TextEditor(text: $command)
                    .font(.body.monospaced())
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 64, maxHeight: 160)
                    .padding(6)
                    .background(palette.raised, in: Design.shape(Design.radiusMedium))
                    .overlay(Design.shape(Design.radiusMedium).strokeBorder(request.isDestructive ? Color.red.opacity(0.6) : palette.separator))
                Text(request.detail)
                    .font(.caption)
                    .foregroundStyle(request.isDestructive ? .red : .secondary)
            }
            HStack {
                Button("Deny") { prompt.resume(.denied) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if isEdited {
                    Button("Run Edited Command") { prompt.resume(.edited(command)) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(isEmpty)
                } else {
                    Button("Approve") { prompt.resume(.approved) }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 560)
        .interactiveDismissDisabled()
    }
}
