import SwiftUI
import ReachlyAgent

/// "Qoder wants to use one of its own tools": an external agent's `session/request_permission`, with the tool
/// call it wants to make and the agent's own options, in its order. Closing the sheet (Esc) rejects; nothing
/// is allowed without a click. These tools are the agent's, on this Mac; commands on servers come through
/// Reachly's MCP server and ask in the command approval sheet instead.
struct AgentPermissionSheet: View {
    let prompt: AgentPermissionPrompt
    @Environment(\.palette) private var palette

    private var request: AgentPermissionRequest { prompt.request }
    private var call: AgentToolActivity { request.toolCall }
    private var rejectOption: AgentPermissionRequest.Option? { request.defaultRejectOption }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                IconTile(systemImage: "hammer.fill", color: palette.accent ?? .accentColor, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(request.agentName) wants to use one of its own tools")
                        .font(.headline)
                    Text("\(request.agentName)'s own tools run on this Mac under \(request.agentName)'s own settings, with your user's access, and \(request.agentName) decides when to ask. Commands on your servers through Reachly always go through Reachly's guardrails.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text("Tool").foregroundStyle(.secondary)
                    Text(call.title).textSelection(.enabled)
                }
                GridRow {
                    Text("Kind").foregroundStyle(.secondary)
                    Text(AgentToolActivityText.kind(call.kind))
                }
                if !call.locations.isEmpty {
                    GridRow {
                        Text("Files").foregroundStyle(.secondary)
                        Text(call.locations.joined(separator: "\n")).font(.body.monospaced()).textSelection(.enabled)
                    }
                }
            }
            if let input = call.input, !input.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Input").foregroundStyle(.secondary)
                    ScrollView {
                        Text(input)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 5)
                    }
                    .frame(maxHeight: 180)
                    .fixedSize(horizontal: false, vertical: true)
                    .font(.body.monospaced())
                    .padding(6)
                    .background(palette.raised, in: Design.shape(Design.radiusMedium))
                    .overlay(Design.shape(Design.radiusMedium).strokeBorder(palette.separator))
                }
            }
            if request.options.isEmpty || rejectOption == nil {
                Text("\(request.agentName) offered no way to say no, so closing this sheet answers that the request was cancelled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                // Esc rejects, through the agent's own reject option when it offered one.
                Button(rejectOption == nil ? "Close" : "Close and Reject") { prompt.resume(.dismissed) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                // Each button says what it does from the option's kind, not only the name the agent gave it, so
                // an option that allows can't pass for one that rejects.
                ForEach(request.options) { option in
                    VStack(spacing: 2) {
                        Button { prompt.resume(.selected(option.id)) } label: {
                            Label(option.name, systemImage: AgentToolActivityText.optionSymbol(option.kind))
                        }
                        Text(AgentToolActivityText.optionCaption(option.kind))
                            .font(.caption2.weight(option.kind?.allows == true ? .semibold : .regular))
                            .foregroundStyle(option.kind?.allows == true ? Color.orange : Color.secondary)
                    }
                    .help(AgentToolActivityText.option(option.kind))
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .padding(20)
        .frame(width: 560)
        .interactiveDismissDisabled()
    }
}

/// The question on screen: a command waiting for approval, or an external agent's request to use its own tool.
@MainActor
enum AgentQuestion: Identifiable {
    case approval(AgentApprovalPrompt)
    case permission(AgentPermissionPrompt)

    nonisolated var id: UUID {
        switch self {
        case .approval(let prompt): prompt.id
        case .permission(let prompt): prompt.id
        }
    }

    static func first(approvals: [AgentApprovalPrompt], permissions: [AgentPermissionPrompt]) -> AgentQuestion? {
        approvals.first.map(AgentQuestion.approval) ?? permissions.first.map(AgentQuestion.permission)
    }

    /// The sheet went away without an answer: the command is denied, the agent's request rejected.
    func dismiss() {
        switch self {
        case .approval(let prompt): prompt.resume(.denied)
        case .permission(let prompt): prompt.resume(.dismissed)
        }
    }
}

/// Words for an ACP tool call's kind and a permission option's kind.
enum AgentToolActivityText {
    static func kind(_ kind: String) -> String {
        switch kind {
        case "read": "Read files"
        case "edit": "Edit files"
        case "delete": "Delete files"
        case "move": "Move or rename files"
        case "search": "Search"
        case "execute": "Run a command"
        case "think": "Think"
        case "fetch": "Fetch from the internet"
        case "switch_mode": "Switch mode"
        default: "Other"
        }
    }

    static func option(_ kind: AgentPermissionRequest.Option.Kind?) -> String {
        switch kind {
        case .allowOnce: "Allow this once"
        case .allowAlways: "Allow this from now on, as the agent keeps it"
        case .rejectOnce: "Reject this once"
        case .rejectAlways: "Reject this from now on, as the agent keeps it"
        case nil: "An option this version of Reachly doesn't know"
        }
    }

    /// Under each permission button: what choosing it does.
    static func optionCaption(_ kind: AgentPermissionRequest.Option.Kind?) -> String {
        switch kind {
        case .allowOnce: "Allows, once"
        case .allowAlways: "Allows, from now on"
        case .rejectOnce: "Rejects, once"
        case .rejectAlways: "Rejects, from now on"
        case nil: "Unknown kind"
        }
    }

    static func optionSymbol(_ kind: AgentPermissionRequest.Option.Kind?) -> String {
        switch kind {
        case .allowOnce, .allowAlways: "checkmark.circle"
        case .rejectOnce, .rejectAlways: "xmark.circle"
        case nil: "questionmark.circle"
        }
    }

    /// An SF Symbol for the kind.
    static func symbol(_ kind: String) -> String {
        switch kind {
        case "read": "doc.text"
        case "edit": "pencil"
        case "delete": "trash"
        case "move": "arrow.right.doc.on.clipboard"
        case "search": "magnifyingglass"
        case "execute": "terminal"
        case "think": "brain"
        case "fetch": "globe"
        case "switch_mode": "arrow.triangle.2.circlepath"
        default: "hammer"
        }
    }
}
