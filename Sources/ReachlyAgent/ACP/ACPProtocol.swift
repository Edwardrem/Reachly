import Foundation

/// The parts of the Agent Client Protocol (agentclientprotocol.com) Reachly uses as a client, as pure
/// functions: the messages it builds and how it reads the agent's.
public enum ACPProtocol {
    /// The protocol version Reachly speaks (Initialization › protocolVersion).
    public static let protocolVersion = 1

    // MARK: Initialization

    /// What the agent said about itself in its `initialize` answer.
    public struct AgentInfo: Sendable, Equatable {
        public var protocolVersion: Int
        public var name: String?
        public var title: String?
        public var version: String?
        /// `agentCapabilities.loadSession`: `session/load` restores an earlier session.
        public var loadSession: Bool
        /// `agentCapabilities.promptCapabilities`: what a prompt may carry beyond text and resource links.
        public var acceptsImages: Bool
        public var acceptsEmbeddedContext: Bool
        /// The ids of the advertised `authMethods`.
        public var authMethods: [String]

        public init(protocolVersion: Int = ACPProtocol.protocolVersion, name: String? = nil, title: String? = nil, version: String? = nil, loadSession: Bool = false, acceptsImages: Bool = false, acceptsEmbeddedContext: Bool = false, authMethods: [String] = []) {
            self.protocolVersion = protocolVersion
            self.name = name
            self.title = title
            self.version = version
            self.loadSession = loadSession
            self.acceptsImages = acceptsImages
            self.acceptsEmbeddedContext = acceptsEmbeddedContext
            self.authMethods = authMethods
        }

        /// "Qoder CLI 0.1.2" for the status line.
        public var label: String? {
            let name = title ?? self.name
            switch (name, version) {
            case let (name?, version?): return "\(name) \(version)"
            case let (name?, nil): return name
            default: return nil
            }
        }
    }

    /// `initialize` params. Reachly advertises no file system and no terminal capability, so the agent must not
    /// call `fs/*` or `terminal/*` (File System, Terminals: "MUST NOT attempt to call"): its own tools for this
    /// Mac stay its own, under its own rules, and Reachly's tools reach servers over MCP only.
    public static func initializeParams(clientName: String, clientVersion: String) -> JSONValue {
        [
            "protocolVersion": .number(Double(protocolVersion)),
            "clientCapabilities": [
                "fs": ["readTextFile": false, "writeTextFile": false],
                "terminal": false,
            ],
            "clientInfo": ["name": .string(clientName.lowercased()), "title": .string(clientName), "version": .string(clientVersion)],
        ]
    }

    public static func agentInfo(from result: JSONValue) throws -> AgentInfo {
        guard result.objectValue != nil else { throw ACPError.invalidResponse("initialize returned no object") }
        let capabilities = result["agentCapabilities"]
        let prompt = capabilities?["promptCapabilities"]
        let info = result["agentInfo"]
        return AgentInfo(
            protocolVersion: result["protocolVersion"]?.intValue ?? protocolVersion,
            name: info?["name"]?.stringValue,
            title: info?["title"]?.stringValue,
            version: info?["version"]?.stringValue,
            loadSession: capabilities?["loadSession"]?.boolValue ?? false,
            acceptsImages: prompt?["image"]?.boolValue ?? false,
            acceptsEmbeddedContext: prompt?["embeddedContext"]?.boolValue ?? false,
            authMethods: result["authMethods"]?.arrayValue?.compactMap { $0["id"]?.stringValue } ?? [])
    }

    // MARK: Sessions

    /// An MCP server handed to the agent for a session (Session Setup › MCP servers, stdio transport, which every
    /// agent supports). `env` is a list of name and value pairs, not a map.
    public struct StdioMCPServer: Sendable, Equatable {
        public var name: String
        public var command: String
        public var arguments: [String]
        public var environment: [(name: String, value: String)]

        public init(name: String, command: String, arguments: [String] = [], environment: [(name: String, value: String)] = []) {
            self.name = name
            self.command = command
            self.arguments = arguments
            self.environment = environment
        }

        public static func == (lhs: StdioMCPServer, rhs: StdioMCPServer) -> Bool {
            lhs.name == rhs.name && lhs.command == rhs.command && lhs.arguments == rhs.arguments
                && lhs.environment.map(\.name) == rhs.environment.map(\.name) && lhs.environment.map(\.value) == rhs.environment.map(\.value)
        }

        var json: JSONValue {
            [
                "name": .string(name),
                "command": .string(command),
                "args": .array(arguments.map(JSONValue.string)),
                "env": .array(environment.map { ["name": .string($0.name), "value": .string($0.value)] }),
            ]
        }
    }

    /// `session/new` params: `cwd` must be absolute.
    public static func newSessionParams(cwd: URL, mcpServers: [StdioMCPServer]) -> JSONValue {
        ["cwd": .string(cwd.path), "mcpServers": .array(mcpServers.map(\.json))]
    }

    /// `session/load` params, the same as `session/new` plus the session to restore.
    public static func loadSessionParams(sessionID: String, cwd: URL, mcpServers: [StdioMCPServer]) -> JSONValue {
        ["sessionId": .string(sessionID), "cwd": .string(cwd.path), "mcpServers": .array(mcpServers.map(\.json))]
    }

    public static func sessionID(from result: JSONValue) throws -> String {
        guard let id = result["sessionId"]?.stringValue, !id.isEmpty else { throw ACPError.invalidResponse("session/new returned no sessionId") }
        return id
    }

    // MARK: Prompt turn

    /// The `prompt` content for a user message: Reachly's context first when a session is new, then the
    /// attachments, then the text. Images go as image blocks and text files as embedded resources when the
    /// agent accepts them; otherwise their text goes inline, and an image the agent can't take is named.
    public static func promptContent(for message: AgentMessage, context: String?, agent: AgentInfo) -> [JSONValue] {
        var blocks: [JSONValue] = []
        if let context, !context.isEmpty {
            blocks.append(["type": "text", "text": .string(context)])
        }
        for file in message.attachments {
            blocks.append(attachmentBlock(file, agent: agent))
        }
        let text = message.text
        if !text.isEmpty { blocks.append(["type": "text", "text": .string(text)]) }
        return blocks
    }

    static func attachmentBlock(_ file: AgentAttachment, agent: AgentInfo) -> JSONValue {
        guard let data = try? file.data() else {
            return ["type": "text", "text": .string("[The attachment \(file.fileName) is no longer available on this Mac.]")]
        }
        let uri = file.url.absoluteString
        switch file.kind {
        case .image:
            if agent.acceptsImages {
                return ["type": "image", "mimeType": .string(file.mediaType), "data": .string(data.base64EncodedString()), "uri": .string(uri)]
            }
            return ["type": "text", "text": .string("[The user attached the image \(file.fileName), but this agent doesn't accept images.]")]
        case .pdf:
            let text = PDFText.extract(from: data) ?? "[no text could be extracted from this PDF]"
            return textAttachment(name: file.fileName, mediaType: "text/plain", uri: uri, text: text, agent: agent)
        case .text:
            return textAttachment(name: file.fileName, mediaType: file.mediaType, uri: uri, text: String(decoding: data, as: UTF8.self), agent: agent)
        }
    }

    private static func textAttachment(name: String, mediaType: String, uri: String, text: String, agent: AgentInfo) -> JSONValue {
        if agent.acceptsEmbeddedContext {
            return ["type": "resource", "resource": ["uri": .string(uri), "mimeType": .string(mediaType), "text": .string(text)]]
        }
        return ["type": "text", "text": .string("<attachment name=\"\(name)\" type=\"\(mediaType)\">\n\(text)\n</attachment>")]
    }

    public static func promptParams(sessionID: String, content: [JSONValue]) -> JSONValue {
        ["sessionId": .string(sessionID), "prompt": .array(content)]
    }

    public static func cancelParams(sessionID: String) -> JSONValue {
        ["sessionId": .string(sessionID)]
    }

    public static func stopReason(from result: JSONValue) throws -> ExternalAgentStopReason {
        guard let raw = result["stopReason"]?.stringValue else { throw ACPError.invalidResponse("session/prompt returned no stopReason") }
        // A reason added later ends the turn like end_turn.
        return ExternalAgentStopReason(rawValue: raw) ?? .endTurn
    }

    // MARK: Updates

    /// What one `session/update` notification means for the panel.
    public enum Update: Equatable {
        case text(String, messageID: String?)
        case thought(String, messageID: String?)
        /// A user message chunk: the agent echoing or replaying what was sent. Not shown again.
        case userEcho
        case toolCall(ToolCallPatch)
        case plan([AgentPlanEntry])
        case mode(String)
        /// Known to ACP but not shown: available commands, usage, session info, config options and later kinds.
        case ignored(String)
    }

    /// The fields one `tool_call` or `tool_call_update` sets. A `tool_call` creates the call; an update changes
    /// only the fields it carries, and its `content` replaces the old content as a whole (Tool Calls).
    public struct ToolCallPatch: Equatable {
        public var id: String
        public var isCreation: Bool
        public var title: String?
        public var kind: String?
        public var status: AgentToolActivity.Status?
        public var output: String?
        public var locations: [String]?
        public var input: String?

        public init(id: String, isCreation: Bool, title: String? = nil, kind: String? = nil, status: AgentToolActivity.Status? = nil, output: String? = nil, locations: [String]? = nil, input: String? = nil) {
            self.id = id
            self.isCreation = isCreation
            self.title = title
            self.kind = kind
            self.status = status
            self.output = output
            self.locations = locations
            self.input = input
        }

        /// The call after this patch. An update for a call never seen starts one from what it carries.
        public func applied(to existing: AgentToolActivity?) -> AgentToolActivity {
            var call = existing ?? AgentToolActivity(id: id, title: title ?? "Tool call")
            if isCreation, existing != nil {
                // A second tool_call for the same id restates the call.
                call.status = status ?? .pending
            }
            if let title, !title.isEmpty { call.title = title }
            if let kind { call.kind = kind }
            if let status { call.status = status }
            if let output { call.output = AgentToolActivity.capped(output) }
            if let locations { call.locations = locations }
            if let input { call.input = AgentToolActivity.capped(input) }
            return call
        }
    }

    /// Reads `params.update` of a `session/update`, keyed by its `sessionUpdate` discriminator (Prompt Turn).
    public static func update(from params: JSONValue?) -> Update? {
        guard let update = params?["update"], let kind = update["sessionUpdate"]?.stringValue else { return nil }
        let messageID = update["messageId"]?.stringValue
        switch kind {
        case "agent_message_chunk":
            return .text(contentText(update["content"]), messageID: messageID)
        case "agent_thought_chunk":
            return .thought(contentText(update["content"]), messageID: messageID)
        case "user_message_chunk":
            return .userEcho
        case "tool_call", "tool_call_update":
            guard let patch = toolCallPatch(update, isCreation: kind == "tool_call") else { return .ignored(kind) }
            return .toolCall(patch)
        case "plan":
            let entries = update["entries"]?.arrayValue ?? []
            return .plan(entries.map { entry in
                AgentPlanEntry(
                    content: entry["content"]?.stringValue ?? "",
                    priority: entry["priority"]?.stringValue ?? "medium",
                    status: AgentPlanEntry.Status(rawValue: entry["status"]?.stringValue ?? "") ?? .pending)
            })
        case "current_mode_update":
            guard let mode = update["currentModeId"]?.stringValue else { return .ignored(kind) }
            return .mode(mode)
        default:
            return .ignored(kind)
        }
    }

    /// The tool call fields of a `tool_call`, `tool_call_update` or the `toolCall` of a permission request.
    public static func toolCallPatch(_ value: JSONValue, isCreation: Bool) -> ToolCallPatch? {
        guard let id = value["toolCallId"]?.stringValue, !id.isEmpty else { return nil }
        var patch = ToolCallPatch(id: id, isCreation: isCreation)
        patch.title = value["title"]?.stringValue
        patch.kind = value["kind"]?.stringValue
        if let raw = value["status"]?.stringValue { patch.status = AgentToolActivity.Status(rawValue: raw) }
        if isCreation {
            patch.kind = patch.kind ?? "other"
            patch.status = patch.status ?? .pending
        }
        if let content = value["content"]?.arrayValue {
            patch.output = content.map(toolCallContentText).filter { !$0.isEmpty }.joined(separator: "\n")
        }
        if let locations = value["locations"]?.arrayValue {
            patch.locations = locations.compactMap { location in
                guard let path = location["path"]?.stringValue else { return nil }
                return location["line"]?.intValue.map { "\(path):\($0)" } ?? path
            }
        }
        if let raw = value["rawInput"], !raw.isNull {
            patch.input = raw.stringValue ?? raw.prettyText
        }
        return patch
    }

    /// A `ToolCallContent` item as text: regular content, a diff as its path and new text, or a terminal by id.
    static func toolCallContentText(_ item: JSONValue) -> String {
        switch item["type"]?.stringValue {
        case "content":
            return contentText(item["content"])
        case "diff":
            let path = item["path"]?.stringValue ?? "a file"
            let verb = item["oldText"].map { $0.isNull ? "Create" : "Edit" } ?? "Create"
            return "\(verb) \(path):\n\(item["newText"]?.stringValue ?? "")"
        case "terminal":
            return "[Terminal \(item["terminalId"]?.stringValue ?? "")]"
        default:
            return ""
        }
    }

    /// A `ContentBlock` as text: its text, or a short stand-in for an image, audio or a resource.
    static func contentText(_ block: JSONValue?) -> String {
        guard let block else { return "" }
        switch block["type"]?.stringValue {
        case "text":
            return block["text"]?.stringValue ?? ""
        case "image":
            return "[image]"
        case "audio":
            return "[audio]"
        case "resource_link":
            return "[\(block["title"]?.stringValue ?? block["name"]?.stringValue ?? block["uri"]?.stringValue ?? "link")]"
        case "resource":
            return block["resource"]?["text"]?.stringValue ?? "[\(block["resource"]?["uri"]?.stringValue ?? "resource")]"
        default:
            return ""
        }
    }

    // MARK: Permission

    /// A `session/request_permission` request, read.
    public struct PermissionRequest: Equatable {
        public var sessionID: String?
        public var toolCall: ToolCallPatch
        public var options: [AgentPermissionRequest.Option]
    }

    public static func permissionRequest(from params: JSONValue?) -> PermissionRequest? {
        guard let params, let toolCall = params["toolCall"], let patch = toolCallPatch(toolCall, isCreation: false) else { return nil }
        let options = (params["options"]?.arrayValue ?? []).compactMap { option -> AgentPermissionRequest.Option? in
            guard let id = option["optionId"]?.stringValue else { return nil }
            return AgentPermissionRequest.Option(
                id: id,
                name: option["name"]?.stringValue ?? id,
                kind: option["kind"]?.stringValue.flatMap(AgentPermissionRequest.Option.Kind.init(rawValue:)))
        }
        return PermissionRequest(sessionID: params["sessionId"]?.stringValue, toolCall: patch, options: options)
    }

    /// The answer to a permission request. A dismissed request takes its reject option, so an unanswered
    /// request never allows anything; a cancelled turn answers `cancelled`, as ACP requires of the client.
    public static func permissionOutcome(_ decision: AgentPermissionDecision, request: AgentPermissionRequest) -> (result: JSONValue, chosen: AgentPermissionRequest.Option?) {
        switch decision {
        case .selected(let id):
            if let option = request.options.first(where: { $0.id == id }) {
                return (["outcome": ["outcome": "selected", "optionId": .string(option.id)]], option)
            }
            return permissionOutcome(.dismissed, request: request)
        case .dismissed:
            guard let reject = request.defaultRejectOption else { return (["outcome": ["outcome": "cancelled"]], nil) }
            return (["outcome": ["outcome": "selected", "optionId": .string(reject.id)]], reject)
        case .cancelled:
            return (["outcome": ["outcome": "cancelled"]], nil)
        }
    }
}
