import SwiftUI
import ReachlyAgent
import ReachlyCore

/// "Claude wants to run…" (or the provider answering in the panel) with the exact command, the host and the reason.
/// Approve runs it as shown, editing runs the edited text, Deny tells the model no.
/// A comment sends the request back instead: nothing runs, and the model gets the
/// comment (and any edit) so it can propose a revised command in a new sheet.
/// Only run_command's text can be edited; the other tools show a stand-in line
/// that is not their real input, so it is read-only.
struct AgentApprovalSheet: View {
    let prompt: AgentApprovalPrompt
    /// Who is answering in the panel. A request from an MCP client comes from Claude Desktop or Claude Code.
    let assistantName: String
    @Environment(\.palette) private var palette
    @State private var command: String
    @State private var comment = ""

    init(prompt: AgentApprovalPrompt, assistantName: String) {
        self.prompt = prompt
        self.assistantName = assistantName
        _command = State(initialValue: prompt.request.command)
    }

    private var request: AgentApprovalRequest { prompt.request }
    /// Who asks: an agent Reachly started itself names itself (Qoder in the chat panel); another MCP client is
    /// taken to be Claude Desktop or Claude Code; otherwise the panel's own provider.
    private var requesterName: String { request.requester ?? (request.source == .mcp ? "Claude" : assistantName) }
    private var requesterDetail: String {
        if let requester = request.requester { return "Requested by \(requester) in the chat panel, through Reachly's MCP server" }
        return request.source == .mcp ? "Requested by an MCP client (Claude Desktop or Claude Code)" : "Requested from the Claude panel"
    }
    private var isEdited: Bool { request.isCommandEditable && command != request.command }
    private var isEmpty: Bool { command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    /// What Send answers; nil while the comment is empty or only whitespace.
    private var changeRequest: AgentApprovalResponse? {
        AgentApprovalResponse.changeRequest(comment: comment, command: command, proposed: request.command, includingEdit: request.isCommandEditable)
    }
    /// Send passes the edited command back too (run_command only, and only a real change).
    private var sendsEdit: Bool { changeRequest?.suggestedCommand != nil }
    /// The hint under the comment: what Send does, and how to run the command instead.
    private var commentHint: String {
        "Nothing runs. \(requesterName) gets your comment\(sendsEdit ? " and your edit" : "") and can propose a revised command. Clear the comment to \(sendsEdit ? "run your edit" : "run the command") instead."
    }
    /// A comment is waiting to be sent, so Approve and Run Edited Command stay off:
    /// running the command would drop it.
    private var hasComment: Bool { changeRequest != nil }
    private var commentLimit: Int { AgentApprovalResponse.commentLimit }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                IconTile(systemImage: request.isDestructive ? "exclamationmark.triangle.fill" : "sparkles", color: request.isDestructive ? .red : (palette.accent ?? .accentColor), size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(requesterName) wants to run a \(request.isDestructive ? "destructive " : "")command")
                        .font(.headline)
                    Text(requesterDetail)
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
                Group {
                    if request.isCommandEditable {
                        TextEditor(text: $command)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 64, maxHeight: 160)
                    } else {
                        // A stand-in for the tool's real input: shown, not editable.
                        ScrollView {
                            Text(request.command)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 5)
                        }
                        .frame(maxHeight: 160)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .font(.body.monospaced())
                .padding(6)
                .background(palette.raised, in: Design.shape(Design.radiusMedium))
                .overlay(Design.shape(Design.radiusMedium).strokeBorder(request.isDestructive ? Color.red.opacity(0.6) : palette.separator))
                Text(request.detail)
                    .font(.caption)
                    .foregroundStyle(request.isDestructive ? .red : .secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Comment").foregroundStyle(.secondary)
                TextField("Comment", text: $comment, prompt: Text("Ask for changes…"), axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(2...5)
                    .padding(8)
                    .background(palette.raised, in: Design.shape(Design.radiusMedium))
                    .overlay(Design.shape(Design.radiusMedium).strokeBorder(palette.separator))
                    .onChange(of: comment) { _, text in
                        if text.count > commentLimit { comment = String(text.prefix(commentLimit)) }
                    }
                    .onSubmit { if let changeRequest { prompt.resume(changeRequest) } }
                    .onExitCommand { prompt.resume(.denied) }
                if hasComment || comment.count > commentLimit - 200 {
                    HStack(alignment: .firstTextBaseline) {
                        if hasComment {
                            Text(commentHint)
                        }
                        Spacer(minLength: 8)
                        if comment.count > commentLimit - 200 {
                            Text("\(comment.count) / \(commentLimit.formatted())").monospacedDigit()
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Deny") { prompt.resume(.denied) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if isEdited {
                    Button("Run Edited Command") { prompt.resume(.edited(command)) }
                        .keyboardShortcut(hasComment ? nil : .defaultAction)
                        .disabled(isEmpty || hasComment)
                } else {
                    Button("Approve") { prompt.resume(.approved) }
                        .keyboardShortcut(hasComment ? nil : .defaultAction)
                        .disabled(hasComment)
                }
                if let changeRequest {
                    Button("Send to \(requesterName)") { prompt.resume(changeRequest) }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 560)
        .interactiveDismissDisabled()
    }
}
