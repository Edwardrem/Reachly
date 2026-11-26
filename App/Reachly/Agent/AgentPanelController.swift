import AppKit
import Foundation
import Observation
import SwiftData
import ReachlyAgent
import ReachlyCore
import ReachlyTerminal
import UniformTypeIdentifiers

/// Owns the live `AgentSession`, the conversation it is saved to, and the
/// scope (one host, a group, or everything) the conversation is about.
@MainActor
@Observable
final class AgentPanelController {
    enum Scope: Hashable {
        case all
        case host(UUID)
        case group(UUID)
    }

    private let toolHost: AppAgentHost
    private let context: ModelContext
    private let workspace: Workspace
    private let settings: AgentSettings

    private(set) var scope: Scope = .all
    private(set) var session: AgentSession?
    private(set) var conversation: AgentConversation?
    /// True while a send or a retry builds its provider (which can wait on
    /// Touch ID), so a second one cannot start meanwhile.
    private(set) var isPreparing = false
    /// Bumped when the user sends or retries, so the transcript goes to its end
    /// and follows the reply even if it had been scrolled up.
    private(set) var scrollToEndRequest = 0
    /// Text from a send that was given back because another conversation was
    /// showing by the time it could start. The composer takes it with `takeRestoredDraft`.
    private(set) var restoredDraft: String?
    /// Bumped whenever the saved conversation list changes.
    private(set) var conversationsVersion = 0
    /// Files attached to the message being written, in the order they were added.
    private(set) var pendingAttachments: [AgentAttachment] = []
    /// Why the last file could not be attached.
    private(set) var attachmentError: String?
    /// True while files or folders are being read, so a message cannot be sent before they land.
    private(set) var isAttaching = false
    /// Number of imports in flight, so overlapping calls keep `isAttaching` right.
    private var attachCount = 0
    /// The earlier user message being rewritten in the composer. Sending
    /// replaces it and everything after it.
    private(set) var editing: AgentMessage?
    private var providerConfiguration: LLMProviderConfiguration?
    /// The selected kind's key version when the current provider was built.
    private var providerKeyVersion = 0
    /// The kind of the provider actually built for this session, for the status badge. nil until built.
    private(set) var providerKind: LLMProviderConfiguration.Kind?

    /// Reachly's MCP server, which an external agent (Qoder) uses to reach the servers. Set by `ContentView`.
    var mcpServer: MCPServerController?
    /// The ACP agent the panel runs, while Qoder is the provider: one process for the panel, started by the
    /// first message and stopped when the panel closes or another provider is chosen.
    private var externalAgent: ACPAgent?

    /// A reply is running in the panel.
    var isReplying: Bool { session?.isRunning == true }

    /// Qoder is chosen but Reachly's MCP server is off, so Qoder could not reach the servers. The panel offers
    /// to turn it on.
    var externalAgentNeedsMCPServer: Bool {
        settings.configuration.kind.isExternalAgent && mcpServer?.isEnabled != true
    }

    /// Each conversation's last agent session, for `session/load`: ids only.
    static var externalAgentSessions: ACPSessionStore {
        ACPSessionStore(url: AppPaths.applicationSupport.appending(path: "Agent/ACP/sessions.json"))
    }

    /// Where an external agent works and keeps nothing of Reachly's: its `cwd`, never the home folder.
    static var externalAgentWorkspace: URL {
        AppPaths.applicationSupport.appending(path: "Agent/ACP/Workspace", directoryHint: .isDirectory)
    }

    /// The name for whoever answers here: the provider built for this session, or the one chosen in
    /// Settings before the first message.
    var assistantName: String { (providerKind ?? settings.configuration.kind).agentName }
    /// Who answers the next message: the provider chosen in Settings.
    var nextAssistantName: String { settings.configuration.kind.agentName }
    /// The next message goes to an agent that runs its own loop (Qoder over ACP).
    var nextAssistantIsExternal: Bool { settings.configuration.kind.isExternalAgent }

    /// Copies of attached files live here, one folder per attachment.
    static var attachmentsDirectory: URL {
        AppPaths.applicationSupport.appending(path: "Agent/Attachments", directoryHint: .isDirectory)
    }

    init(toolHost: AppAgentHost, context: ModelContext, workspace: Workspace, settings: AgentSettings = .shared) {
        self.toolHost = toolHost
        self.context = context
        self.workspace = workspace
        self.settings = settings
        toolHost.externalAgentIsAnswering = { [weak self] request in self?.externalAgentIsAnswering(request) ?? false }
    }

    // MARK: Scope

    var hosts: [SSHHost] {
        (try? context.fetch(FetchDescriptor<SSHHost>(sortBy: [SortDescriptor(\.name)]))) ?? []
    }

    var groups: [HostGroup] {
        (try? context.fetch(FetchDescriptor<HostGroup>(sortBy: [SortDescriptor(\.name)]))) ?? []
    }

    var scopeTitle: String {
        switch scope {
        case .all: "All hosts"
        case .host(let id): hosts.first { $0.uuid == id }?.name ?? "Host"
        case .group(let id): groups.first { $0.uuid == id }?.name ?? "Group"
        }
    }

    /// Changes the scope and opens its most recent conversation.
    func focus(_ scope: Scope) {
        guard scope != self.scope || session == nil else { return }
        stop()
        self.scope = scope
        if let latest = conversations().first {
            open(latest)
        } else {
            newConversation()
        }
    }

    /// Points the panel at the focused terminal's host when it has one and nothing was chosen yet.
    func focusOnWorkspaceIfIdle() {
        guard session == nil, let host = workspace.focusedSession?.host, !host.isTransient else { return }
        focus(.host(host.id))
    }

    // MARK: Conversations

    func conversations() -> [AgentConversation] {
        let all = (try? context.fetch(FetchDescriptor<AgentConversation>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]))) ?? []
        return all.filter { stored in
            switch scope {
            case .all: stored.hostID == nil && stored.groupID == nil
            case .host(let id): stored.hostID == id
            case .group(let id): stored.groupID == id
            }
        }
    }

    func open(_ stored: AgentConversation) {
        stop()
        cancelEditing()
        conversation = stored
        let messages = (try? AgentTranscript.decode(stored.transcript)) ?? []
        if let session {
            session.replace(messages: messages)
            // Commands from here on are audited under this conversation, not the one shown before.
            session.toolRunner.conversationID = stored.uuid
        } else {
            session = makeSession(messages: messages)
        }
    }

    /// Opens a saved conversation from elsewhere in the app (AI History), moving
    /// the scope to the host or group it was saved for. Returns false when it no
    /// longer exists. A conversation already showing is left running.
    @discardableResult
    func open(conversationID id: UUID) -> Bool {
        if conversation?.uuid == id { return true }
        guard let stored = try? context.fetch(FetchDescriptor<AgentConversation>(predicate: #Predicate { $0.uuid == id })).first else {
            return false
        }
        scope = stored.hostID.map(Scope.host) ?? stored.groupID.map(Scope.group) ?? .all
        open(stored)
        return true
    }

    func newConversation() {
        stop()
        cancelEditing()
        conversation = nil
        if let session {
            session.replace(messages: [])
            session.toolRunner.conversationID = nil
        } else {
            session = makeSession(messages: [])
        }
    }

    func delete(_ stored: AgentConversation) {
        // Its agent session is not loaded again.
        externalAgent?.forgetSession(for: stored.uuid.uuidString)
        Self.externalAgentSessions.set(nil, for: stored.uuid.uuidString)
        if stored === conversation { newConversation() }
        context.delete(stored)
        try? context.save()
        conversationsVersion += 1
    }

    // MARK: Attachments

    /// Imports each item (files: images, PDFs, Word documents, text; folders: a text bundle
    /// plus the images and PDFs inside) off the main actor, so a folder of photos and Word
    /// documents does not freeze the window. Items keep the order they were given; one that
    /// cannot be read reports why and the rest still attach.
    func attach(urls: [URL]) {
        guard !urls.isEmpty else { return }
        // Resolve folders and the store location here; plain values cross to the background task.
        let items = urls.map { (url: $0, isDirectory: Self.isDirectory($0)) }
        let directory = Self.attachmentsDirectory
        attachmentError = nil
        attachCount += 1
        isAttaching = true
        Task.detached(priority: .userInitiated) {
            var attachments: [AgentAttachment] = []
            var failures: [String] = []
            for item in items {
                do {
                    if item.isDirectory {
                        attachments.append(contentsOf: try AttachmentImporter.importFolder(at: item.url, into: directory))
                    } else {
                        attachments.append(try AttachmentImporter.importFile(at: item.url, into: directory))
                    }
                } catch {
                    failures.append(error.localizedDescription)
                }
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.pendingAttachments.append(contentsOf: attachments)
                if let first = failures.first {
                    let more = failures.count - 1
                    self.attachmentError = more > 0 ? "\(first) (and \(more) more could not be attached)" : first
                } else {
                    self.attachmentError = nil
                }
                self.attachCount -= 1
                self.isAttaching = self.attachCount > 0
            }
        }
    }

    /// A package (`Foo.app`, `Notes.rtfd`, a project bundle) is a directory on disk but belongs to
    /// `importFile`: walking it would attach its resource images as a folder.
    private static func isDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]) else { return false }
        return values.isDirectory == true && values.isPackage != true
    }

    func removeAttachment(_ file: AgentAttachment) {
        pendingAttachments.removeAll { $0.id == file.id }
        // A file that came with the message being edited still belongs to that
        // message until the edit is sent, so its copy stays on disk.
        if editing?.attachments.contains(where: { $0.id == file.id }) != true {
            AttachmentImporter.discard(file)
        }
        attachmentError = nil
    }

    /// The standard open panel, limited to what the models can read, files or whole folders.
    func pickFiles() {
        let panel = NSOpenPanel()
        panel.title = "Attach Files or Folders"
        panel.message = "Images, PDFs, Word documents and text files such as logs, configs, code and CSV — or a folder, to send the files and images inside it."
        panel.prompt = "Attach Files or Folders"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        // `.folder` keeps directories selectable next to the file types the models can read.
        panel.allowedContentTypes = [.folder, .image, .pdf, .text, .sourceCode, .json, .xml, .yaml, .propertyList, .commaSeparatedText, .log, .shellScript, .data]
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            Task { @MainActor in self?.attach(urls: panel.urls) }
        }
    }

    // MARK: Copying and editing

    /// The whole conversation as plain text on the clipboard.
    func copyConversation() {
        guard let session else { return }
        Self.copy(AgentTranscript.plainText(session.messages, assistantName: assistantName))
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Whether this message can be rewritten: a user turn the person typed
    /// (not a tool result), while no reply is running or starting.
    func canEdit(_ message: AgentMessage) -> Bool {
        message.role == .user && (!message.text.isEmpty || !message.attachments.isEmpty) && session?.isRunning != true && !isPreparing
    }

    /// Starts rewriting an earlier message: its files go back in the pending
    /// list and the caller puts its text in the composer. Nothing in the
    /// transcript changes until the edit is sent.
    func beginEditing(_ message: AgentMessage) {
        guard canEdit(message) else { return }
        cancelEditing()
        editing = message
        let present = Set(pendingAttachments.map(\.id))
        pendingAttachments = message.attachments.filter { !present.contains($0.id) && !$0.isMissing } + pendingAttachments
    }

    /// Leaves the earlier message as it was.
    func cancelEditing() {
        guard let message = editing else { return }
        editing = nil
        let original = Set(message.attachments.map(\.id))
        pendingAttachments.removeAll { original.contains($0.id) }
    }

    // MARK: Sending

    var canSend: Bool {
        session?.isRunning != true && !isAttaching && !isPreparing
    }

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !pendingAttachments.isEmpty else { return }
        let session = session ?? makeSession(messages: [])
        self.session = session
        guard session.canSend, !isPreparing else { return }
        let files = pendingAttachments
        let edited = editing
        // Building the provider can wait on Touch ID, and History, the scope menu
        // or New Conversation can show another conversation meanwhile. The message
        // belongs to the one it was written in.
        let started = session.conversationToken
        pendingAttachments = []
        attachmentError = nil
        isPreparing = true
        scrollToEndRequest += 1
        Task {
            defer { isPreparing = false }
            var setupFailure: String?
            do {
                try await prepareProvider(for: session)
            } catch {
                setupFailure = error.localizedDescription
            }
            guard self.session === session, session.conversationToken == started else {
                // Another conversation is showing: nothing goes into it. The text
                // and files go back to the composer instead.
                restoreUnsent(trimmed, files: files, edited: edited)
                return
            }
            // Until the edit is applied, the original message keeps its files.
            var stillEditing = edited
            if let edited, editing?.id == edited.id {
                // The rewritten message takes the place of the original and of
                // every reply that followed it. Files taken off the edit go with it.
                editing = nil
                stillEditing = nil
                session.rewind(to: edited.id)
                let kept = Set(files.map(\.id))
                for file in edited.attachments where !kept.contains(file.id) { AttachmentImporter.discard(file) }
            }
            let delivered = if let setupFailure {
                // The message and its files stay in the transcript with the reason
                // under it, and Retry sends them once the key is set.
                session.recordUnsent(trimmed, attachments: files, reason: setupFailure, in: started)
            } else {
                session.send(trimmed, attachments: files, in: started)
            }
            if !delivered { restoreUnsent(trimmed, files: files, edited: stillEditing) }
        }
    }

    func takeRestoredDraft() -> String? {
        defer { restoredDraft = nil }
        return restoredDraft
    }

    /// Puts an unsent message back in the composer. Files that came with an
    /// earlier message being edited stay with that message, in its own
    /// conversation; files added since go back to the pending list.
    private func restoreUnsent(_ text: String, files: [AgentAttachment], edited: AgentMessage?) {
        let original = Set(edited?.attachments.map(\.id) ?? [])
        pendingAttachments = files.filter { !original.contains($0.id) } + pendingAttachments
        if !text.isEmpty {
            restoredDraft = restoredDraft.map { $0 + "\n\n" + text } ?? text
        }
    }

    /// Whether this failure row is the latest and its turn can run again.
    func canRetry(_ message: AgentMessage) -> Bool {
        guard let session, !isPreparing, session.canRetry else { return false }
        return session.messages.last?.id == message.id
    }

    /// Runs the turn that ended in the latest failure row again, building the
    /// provider first if the settings changed. If it still cannot start, the
    /// row says why instead of a new one being added.
    func retry() {
        guard let session, session.canRetry, !isPreparing else { return }
        // As in `send`: the retry is for the conversation showing now. If another
        // one is showing once the provider is ready, nothing happens.
        let started = session.conversationToken
        isPreparing = true
        scrollToEndRequest += 1
        Task {
            defer { isPreparing = false }
            do {
                try await prepareProvider(for: session)
                session.retry(in: started)
            } catch {
                session.recordSetupFailure(error.localizedDescription, in: started)
            }
        }
    }

    /// Builds the provider when the settings or the key changed since the last
    /// turn, and points the system prompt at the current scope.
    private func prepareProvider(for session: AgentSession) async throws {
        // One snapshot before any await: the prompt must not be able to retarget the key or host.
        let plan = settings.providerPlan()
        if plan.configuration.kind.isExternalAgent {
            session.externalAgent = try prepareExternalAgent(plan.configuration)
            providerConfiguration = plan.configuration
            providerKind = plan.configuration.kind
            session.systemPrompt = externalAgentContext(agentName: plan.configuration.kind.agentName)
            return
        }
        // Another provider answers now: the agent process goes.
        session.externalAgent = nil
        stopExternalAgent()
        if providerConfiguration != plan.configuration
            || providerKeyVersion != plan.keyVersion
            || session.provider is PlaceholderProvider {
            session.provider = try await settings.makeProvider(for: plan)
            providerConfiguration = plan.configuration
            providerKeyVersion = plan.keyVersion
            providerKind = plan.configuration.kind
        }
        session.systemPrompt = systemPrompt(providerName: plan.configuration.kind.agentName)
    }

    func stop() {
        session?.stop()
    }

    // MARK: External agent

    /// The ACP agent for this configuration, made on first use. Throws, before anything is sent, when the CLI
    /// is not chosen or gone, or when Reachly's MCP server is off: without it Qoder could not reach the servers
    /// under Reachly's guardrails.
    private func prepareExternalAgent(_ configuration: LLMProviderConfiguration) throws -> ACPAgent {
        let name = configuration.kind.agentName
        guard let command = configuration.acpCommandPath?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty else {
            throw AgentSetupError(message: "Choose the \(name) CLI first: in Settings › AI Integration, click Use in Chat Panel on the Qoder row.")
        }
        // Where the path leads now, through any links: that file runs, and never one inside an app bundle.
        let executable: String
        switch ACPLaunch.resolveExecutable(command) {
        case .success(let resolved):
            executable = resolved
        case .failure(.missing):
            throw AgentSetupError(message: "The \(name) CLI isn't at \(command) any more. Click Check Again in Settings › AI Integration, then Use in Chat Panel.")
        case .failure(.notExecutable):
            throw AgentSetupError(message: "\(command) isn't a program Reachly can run. Choose the \(name) CLI in Settings › AI Integration.")
        case .failure(.insideAppBundle(let resolved)):
            throw AgentSetupError(message: "\(command) leads to \(resolved), inside an app bundle: that is the \(name) editor's launcher, not the \(name) CLI, so Reachly won't run it. Install the CLI (docs.qoder.com/en/cli/quick-start), then click Check Again in Settings › AI Integration and Use in Chat Panel.")
        }
        guard let mcpServer, mcpServer.isRunning else {
            throw AgentSetupError(message: "\(name) reaches your servers only through Reachly's MCP server, which is off. Turn it on (the button above, or Settings › AI Integration › MCP server), then Retry.")
        }
        if let externalAgent, externalAgent.configuration.executable == executable {
            return externalAgent
        }
        stopExternalAgent()
        let agent = ACPAgent(configuration: Self.externalAgentConfiguration(name: name, command: command, executable: executable, bridgePath: mcpServer.bridgePath))
        agent.permissionHandler = { [toolHost] request in await toolHost.askPermission(request) }
        // A command Qoder asked for through the MCP server is not left in its sheet once the turn is over.
        agent.turnEndHandler = { [toolHost] key in
            guard let requester = Self.externalAgentRequester else { return }
            toolHost.withdrawApprovals(from: requester, conversationKey: key)
        }
        externalAgent = agent
        return agent
    }

    /// What Qoder's bridge says it is (`REACHLY_MCP_CLIENT`), and the name the MCP server gives it in the sheet.
    nonisolated static let externalAgentClient = "qoder"
    nonisolated static var externalAgentRequester: String? { MCPServer.knownClients[externalAgentClient] }

    /// Whether the panel's agent is answering the turn this request came from (see `AppAgentHost`).
    private func externalAgentIsAnswering(_ request: AgentApprovalRequest) -> Bool {
        guard let externalAgent, request.requester == Self.externalAgentRequester else { return false }
        return externalAgent.isAnswering(request.conversationID?.uuidString)
    }

    /// How Qoder is run: the CLI in ACP mode (`--acp`, then `acp`), in Reachly's own folder, with the app's
    /// environment and the usual bin folders on PATH, and Reachly's stdio MCP bridge in every session. The
    /// bridge finds the server's port and token in Reachly's data folder itself, so no token is handed over,
    /// and it tells the server which conversation the commands belong to.
    /// `command` is the path chosen in Settings and `executable` the file it leads to, which is what runs.
    static func externalAgentConfiguration(name: String, command: String, executable: String, bridgePath: String) -> ACPAgent.Configuration {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dataDirectory = AppPaths.applicationSupport.path
        let binary = URL(fileURLWithPath: command).lastPathComponent
        let permissionMode = externalAgentPermissionMode
        return ACPAgent.Configuration(
            name: name,
            executable: executable,
            // Qoder's permission docs (docs.qoder.com/en/cli/permissions) give `--permission-mode default` for
            // the session's mode, and its ACP docs say ACP mode has the CLI's permission settings. A Qoder that
            // doesn't know the option runs without it, and the transcript says so.
            argumentSets: [["--acp"] + permissionMode, ["--acp"], ["acp"] + permissionMode, ["acp"]],
            fallbackNotices: ["--permission-mode": "\(name) didn't accept --permission-mode default, so it runs in the permission mode its own settings choose."],
            environment: ProviderDetector.toolEnvironment(for: command, home: home),
            workingDirectory: externalAgentWorkspace,
            mcpServers: { conversation in
                [ACPProtocol.StdioMCPServer(
                    name: MCPClientConfig.serverName,
                    command: bridgePath,
                    environment: [
                        ("REACHLY_DATA_DIR", dataDirectory),
                        ("REACHLY_MCP_CLIENT", externalAgentClient),
                        ("REACHLY_MCP_CONVERSATION", conversation),
                    ])]
            },
            clientVersion: UpdateManager.currentShortVersion,
            sessionStore: externalAgentSessions,
            signInHint: "Run `\(binary) login` in Terminal, or start Reachly with QODER_PERSONAL_ACCESS_TOKEN set, then Retry. Reachly never sees \(name)'s sign-in.")
    }

    /// Qoder's default permission mode, which its docs describe as asking before sensitive actions, in place of
    /// a mode in its settings that skips asking (`bypass_permissions`, `auto`). Qoder still decides what asks.
    nonisolated static let externalAgentPermissionMode = ["--permission-mode", "default"]

    /// Stops the agent process. The next message starts it again.
    func stopExternalAgent() {
        externalAgent?.shutdown()
        externalAgent = nil
        session?.externalAgent = nil
    }

    /// The panel closed: the agent process goes once no reply is running.
    func stopExternalAgentIfIdle() {
        guard externalAgent != nil, !isReplying, !isPreparing else { return }
        stopExternalAgent()
    }

    private func externalAgentContext(agentName: String) -> String {
        let infos = toolHost.hosts()
        switch scope {
        case .all:
            return AgentSystemPrompt.externalAgentContext(hosts: infos, focus: nil, agentName: agentName)
        case .host(let id):
            return AgentSystemPrompt.externalAgentContext(hosts: infos, focus: infos.first { $0.id == id }, agentName: agentName)
        case .group(let id):
            let group = groups.first { $0.uuid == id }
            let members = Set(group?.hosts.map(\.uuid) ?? [])
            return AgentSystemPrompt.externalAgentContext(hosts: infos.filter { members.contains($0.id) }, focus: nil, groupName: group?.name, agentName: agentName)
        }
    }

    private func makeSession(messages: [AgentMessage]) -> AgentSession {
        let runner = AgentToolRunner(host: toolHost, source: .agentPanel, conversationID: conversation?.uuid)
        // A fresh session starts with the placeholder; the next send builds and records the real provider.
        providerKind = nil
        let session = AgentSession(provider: PlaceholderProvider(), systemPrompt: systemPrompt(providerName: settings.configuration.kind.agentName), toolRunner: runner, messages: messages)
        session.transcriptDidChange = { [weak self] in self?.persist() }
        return session
    }

    private func systemPrompt(providerName: String) -> String {
        let infos = toolHost.hosts()
        switch scope {
        case .all:
            return AgentSystemPrompt.build(hosts: infos, focus: nil, providerName: providerName)
        case .host(let id):
            return AgentSystemPrompt.build(hosts: infos, focus: infos.first { $0.id == id }, providerName: providerName)
        case .group(let id):
            let group = groups.first { $0.uuid == id }
            let members = Set(group?.hosts.map(\.uuid) ?? [])
            return AgentSystemPrompt.build(hosts: infos.filter { members.contains($0.id) }, focus: nil, groupName: group?.name, providerName: providerName)
        }
    }

    private func persist() {
        guard let session else { return }
        let messages = session.messages
        if messages.isEmpty {
            return
        }
        let stored: AgentConversation
        if let conversation {
            stored = conversation
        } else {
            let firstLine = messages.first { $0.role == .user }?.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? "Conversation"
            let title = firstLine.count > 60 ? String(firstLine.prefix(57)) + "…" : firstLine
            var hostID: UUID?
            var groupID: UUID?
            if case .host(let id) = scope { hostID = id }
            if case .group(let id) = scope { groupID = id }
            stored = AgentConversation(title: title, hostID: hostID, groupID: groupID)
            context.insert(stored)
            conversation = stored
            session.toolRunner.conversationID = stored.uuid
            conversationsVersion += 1
        }
        stored.transcript = (try? AgentTranscript.encode(messages)) ?? Data()
        stored.updatedAt = .now
        if let model = session.lastModel { stored.model = model }
        try? context.save()
    }
}

#if DEBUG
extension AgentPanelController {
    /// `--qa-agent-demo`: a finished conversation with two attachments, a tool
    /// call and a real generated PDF, so the panel can be screenshotted without a key.
    func seedDemoConversation() {
        let directory = Self.attachmentsDirectory.appending(path: "demo", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let imageURL = directory.appending(path: "grafana-disk.png")
        try? Self.demoImage().write(to: imageURL)
        let logURL = directory.appending(path: "nginx-error.log")
        try? Data("2026/11/11 06:12:01 [error] 1182#1182: *44 open() \"/var/www/html/favicon.ico\" failed (2: No such file or directory)\n2026/11/11 06:12:04 [crit] 1182#1182: *45 pwrite() \"/var/cache/nginx/proxy_temp/3/01/0000000013\" failed (28: No space left on device)\n".utf8).write(to: logURL)
        let image = AgentAttachment(fileName: "grafana-disk.png", mediaType: "image/png", byteCount: (try? Data(contentsOf: imageURL).count) ?? 0, path: imageURL.path)
        let log = AgentAttachment(fileName: "nginx-error.log", mediaType: "text/plain", byteCount: (try? Data(contentsOf: logURL).count) ?? 0, path: logURL.path)

        let runner = AgentToolRunner(host: toolHost, source: .agentPanel)
        let report = """
        ## Summary
        The root volume on **build-box** is at 91% and nginx has started failing writes to its proxy cache. Two log directories account for most of the growth.

        ## Volumes
        | Mount | Size | Used | Free | Use |
        |-------|------|------|------|-----|
        | / | 80 GB | 73 GB | 7.0 GB | 91% |
        | /data | 500 GB | 212 GB | 288 GB | 42% |

        ## Largest directories
        1. `/var/log/nginx` — 18 GB (access logs, no rotation since October)
        2. `/var/cache/nginx` — 11 GB
        3. `/home/ubuntu/.cache/pip` — 6 GB

        ## Recommendations
        - Enable `logrotate` for nginx with 14 days of compressed history.
        - Clear the pip cache and the stale proxy cache.
        - Alert at 80% so the next fill-up is caught early.

        > Nothing was changed on the host; every command above was read-only.
        """
        let created = (try? runner.createDocument(fileName: "Disk usage report", format: .pdf, title: "Disk usage report — build-box", content: report)) ?? ""
        let messages: [AgentMessage] = [
            .user("Here is this morning's Grafana panel and the nginx error log. Check the disks on build-box and give me a PDF report I can send to the team.", attachments: [image, log]),
            AgentMessage(role: .assistant, blocks: [
                .text("The log shows nginx failing with *No space left on device*, so I'll start with the volumes on build-box."),
                .toolUse(id: "demo-1", name: "run_command", input: ["host": "build-box", "command": "df -h / /data && sudo du -xsh /var/log/nginx /var/cache/nginx /home/ubuntu/.cache/pip", "reason": "See which volume is full and what is filling it"]),
            ], model: "claude-opus-5-5"),
            AgentMessage(role: .user, blocks: [
                .toolResult(toolUseID: "demo-1", content: "<command_output host=\"build-box\" exit_status=\"0\" duration_ms=\"412\" truncated=\"false\">\nFilesystem      Size  Used Avail Use% Mounted on\n/dev/sda1        80G   73G  7.0G  91% /\n/dev/sdb1       500G  212G  288G  42% /data\n18G\t/var/log/nginx\n11G\t/var/cache/nginx\n6.0G\t/home/ubuntu/.cache/pip\n</command_output>", isError: false),
            ]),
            AgentMessage(role: .assistant, blocks: [
                .toolUse(id: "demo-2", name: "create_document", input: ["file_name": "Disk usage report", "format": "pdf", "title": "Disk usage report — build-box", "content": .string(report)]),
            ], model: "claude-opus-5-5"),
            AgentMessage(role: .user, blocks: [.toolResult(toolUseID: "demo-2", content: created, isError: false)]),
            AgentMessage(role: .assistant, blocks: [
                .text("**Disk usage report** is ready. The root volume is at 91%, driven by 18 GB of unrotated nginx access logs and an 11 GB proxy cache; the report lists the volumes, the three largest directories and three fixes, starting with `logrotate`. Nothing was changed on the host."),
            ], model: "claude-opus-5-5"),
        ]
        newConversation()
        session?.replace(messages: messages)
    }

    /// A small chart-like PNG standing in for a dashboard screenshot.
    private static func demoImage() -> Data {
        let size = CGSize(width: 480, height: 280)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor(srgbRed: 0.09, green: 0.1, blue: 0.14, alpha: 1).setFill()
            rect.fill()
            let values: [CGFloat] = [0.42, 0.47, 0.51, 0.58, 0.63, 0.7, 0.74, 0.8, 0.86, 0.91]
            let path = NSBezierPath()
            for (index, value) in values.enumerated() {
                let point = CGPoint(x: 30 + CGFloat(index) * 46, y: 30 + value * 220)
                if index == 0 { path.move(to: point) } else { path.line(to: point) }
            }
            NSColor(srgbRed: 0.42, green: 0.69, blue: 1, alpha: 1).setStroke()
            path.lineWidth = 3
            path.stroke()
            NSColor(srgbRed: 1, green: 0.45, blue: 0.4, alpha: 0.9).setStroke()
            let limit = NSBezierPath()
            limit.move(to: CGPoint(x: 20, y: 30 + 0.8 * 220))
            limit.line(to: CGPoint(x: 460, y: 30 + 0.8 * 220))
            limit.setLineDash([6, 4], count: 2, phase: 0)
            limit.lineWidth = 1.5
            limit.stroke()
            let label = NSAttributedString(string: "Disk used — / on build-box", attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.white])
            label.draw(at: CGPoint(x: 20, y: 256))
            return true
        }
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else { return Data() }
        return png
    }
}
#endif

/// Stands in until the real provider is built from settings on the first send.
private struct PlaceholderProvider: LLMProvider {
    var displayName: String { "none" }
    var modelName: String { "" }
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: AgentSetupError(message: "No model is configured.")) }
    }
}
