import Foundation

/// A tool call an external agent ran with its own tools, as the transcript shows it. Display only: it is saved
/// with the conversation and never sent to a model, which keeps Reachly's own tool-call pairing out of it.
public struct AgentToolActivity: Codable, Sendable, Equatable, Identifiable {
    public enum Status: String, Codable, Sendable, Equatable {
        case pending
        case inProgress = "in_progress"
        case completed
        case failed
        /// Not an ACP status: the turn stopped or the agent went away before the call finished.
        case cancelled

        public var isFinished: Bool { self == .completed || self == .failed || self == .cancelled }
    }

    public var id: String
    public var title: String
    /// The agent's category for the tool: read, edit, delete, move, search, execute, think, fetch, switch_mode
    /// or other.
    public var kind: String
    public var status: Status
    /// What the tool reported, as text: its content, a diff in short, or the terminal it used. Capped.
    public var output: String
    /// Files the tool touches, as absolute paths, with `:line` when the agent gave one.
    public var locations: [String]
    /// The tool's raw input as JSON text, capped. Nil when the agent sent none.
    public var input: String?
    /// What the user answered when the agent asked before running it.
    public var permission: String?

    /// The most text kept for `output` and for `input`, so a large result does not bloat the saved transcript.
    public static let textLimit = 16_000

    public init(id: String, title: String, kind: String = "other", status: Status = .pending, output: String = "", locations: [String] = [], input: String? = nil, permission: String? = nil) {
        self.id = id
        self.title = title
        self.kind = kind
        self.status = status
        self.output = output
        self.locations = locations
        self.input = input
        self.permission = permission
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, kind, status, output, locations, input, permission
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? "other"
        // A status added later reads as pending rather than failing the transcript.
        status = Status(rawValue: try container.decodeIfPresent(String.self, forKey: .status) ?? "") ?? .pending
        output = try container.decodeIfPresent(String.self, forKey: .output) ?? ""
        locations = try container.decodeIfPresent([String].self, forKey: .locations) ?? []
        input = try container.decodeIfPresent(String.self, forKey: .input)
        permission = try container.decodeIfPresent(String.self, forKey: .permission)
    }

    /// Cuts text to `textLimit` characters, saying how much was left out.
    public static func capped(_ text: String) -> String {
        guard text.count > textLimit else { return text }
        let kept = text.prefix(textLimit)
        return kept + "\n… (\((text.count - textLimit).formatted()) more characters not kept)"
    }
}

/// One step of an external agent's plan.
public struct AgentPlanEntry: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable, Equatable {
        case pending
        case inProgress = "in_progress"
        case completed
    }

    public var content: String
    /// high, medium or low.
    public var priority: String
    public var status: Status

    public init(content: String, priority: String = "medium", status: Status = .pending) {
        self.content = content
        self.priority = priority
        self.status = status
    }

    private enum CodingKeys: String, CodingKey {
        case content, priority, status
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        content = try container.decodeIfPresent(String.self, forKey: .content) ?? ""
        priority = try container.decodeIfPresent(String.self, forKey: .priority) ?? "medium"
        status = Status(rawValue: try container.decodeIfPresent(String.self, forKey: .status) ?? "") ?? .pending
    }
}
