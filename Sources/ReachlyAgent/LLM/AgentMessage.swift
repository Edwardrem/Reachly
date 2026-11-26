import Foundation

/// One turn of a conversation, provider-neutral so transcripts can be saved
/// and replayed to either kind of model.
public struct AgentMessage: Codable, Sendable, Equatable, Identifiable {
    public enum Role: String, Codable, Sendable {
        case user, assistant
    }

    public var id: UUID
    public var role: Role
    public var blocks: [AgentContentBlock]
    public var createdAt: Date
    /// The model that produced an assistant turn (as reported by the API).
    public var model: String?

    public init(id: UUID = UUID(), role: Role, blocks: [AgentContentBlock], createdAt: Date = .now, model: String? = nil) {
        self.id = id
        self.role = role
        self.blocks = blocks
        self.createdAt = createdAt
        self.model = model
    }

    /// A failure row: why a reply stopped, shown where it stopped, after what
    /// had streamed of it. It is display only and never sent to a model.
    public init(failure: AgentFailure, partial: [AgentContentBlock] = [], createdAt: Date = .now, model: String? = nil) {
        self.init(role: .assistant, blocks: partial + [.failure(failure)], createdAt: createdAt, model: model)
    }

    public static func user(_ text: String) -> AgentMessage {
        AgentMessage(role: .user, blocks: [.text(text)])
    }

    /// A user turn with files: attachments come first so the model reads them before the question.
    public static func user(_ text: String, attachments: [AgentAttachment]) -> AgentMessage {
        var blocks: [AgentContentBlock] = attachments.map { .attachment($0) }
        if !text.isEmpty { blocks.append(.text(text)) }
        return AgentMessage(role: .user, blocks: blocks)
    }

    public var attachments: [AgentAttachment] {
        blocks.compactMap { if case .attachment(let file) = $0 { return file } else { return nil } }
    }

    /// The visible text of the turn.
    public var text: String {
        blocks.compactMap { if case .text(let text) = $0 { return text } else { return nil } }.joined(separator: "\n")
    }

    public var toolUses: [(id: String, name: String, input: JSONValue)] {
        blocks.compactMap { if case .toolUse(let id, let name, let input) = $0 { return (id, name, input) } else { return nil } }
    }

    /// Set on a failure row. The row's other blocks are what streamed before
    /// the reply failed, kept for the reader.
    public var failure: AgentFailure? {
        for block in blocks {
            if case .failure(let failure) = block { return failure }
        }
        return nil
    }
}

/// Why a reply did not finish, kept in the transcript where it stopped and
/// saved with the conversation. Failure rows are for the reader only: they are
/// never sent to a model and play no part in tool-call pairing.
public struct AgentFailure: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        /// The request could not start: no key, a bad endpoint, Touch ID cancelled.
        case setup
        /// The provider or the network returned an error.
        case error
        /// The reply held nothing that could be read.
        case unreadable
        /// The reply reached the model's output limit.
        case cutOff = "cut_off"
        /// The model declined to continue.
        case refusal
        /// The reply ended before a tool call finished.
        case interrupted
        /// The agent reached its limit of tool rounds for one message.
        case toolRounds = "tool_rounds"
        /// The user stopped the reply.
        case stopped
    }

    public var kind: Kind
    public var message: String

    public init(kind: Kind, message: String) {
        self.kind = kind
        self.message = message
    }

    /// One sentence for the transcript and the clipboard. Provider and setup
    /// errors are prefixed with what failed; the other messages already say it.
    public var summary: String {
        switch kind {
        case .setup: "Not sent: \(message)"
        case .error: "The request failed: \(message)"
        case .unreadable, .cutOff, .refusal, .interrupted, .toolRounds, .stopped: message
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind, message
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // A kind added by a later version reads as a plain error instead of failing the whole transcript.
        kind = Kind(rawValue: try container.decodeIfPresent(String.self, forKey: .kind) ?? "") ?? .error
        message = try container.decodeIfPresent(String.self, forKey: .message) ?? ""
    }
}

public enum AgentContentBlock: Codable, Sendable, Equatable {
    case text(String)
    /// `text` is the summary shown to the user; `signature` lets the block be
    /// replayed to the same model. Unsigned blocks are not sent back.
    case thinking(text: String, signature: String?)
    case redactedThinking(data: String)
    case toolUse(id: String, name: String, input: JSONValue)
    case toolResult(toolUseID: String, content: String, isError: Bool)
    /// A file the user attached (user turns only).
    case attachment(AgentAttachment)
    /// Marks a failure row (see `AgentFailure`). Display only: never sent.
    case failure(AgentFailure)

    private enum CodingKeys: String, CodingKey {
        case type, text, signature, data, id, name, input, toolUseID = "tool_use_id", content, isError = "is_error", file, failure
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "text":
            self = .text(try container.decode(String.self, forKey: .text))
        case "thinking":
            self = .thinking(text: try container.decodeIfPresent(String.self, forKey: .text) ?? "", signature: try container.decodeIfPresent(String.self, forKey: .signature))
        case "redacted_thinking":
            self = .redactedThinking(data: try container.decode(String.self, forKey: .data))
        case "tool_use":
            self = .toolUse(id: try container.decode(String.self, forKey: .id), name: try container.decode(String.self, forKey: .name), input: try container.decodeIfPresent(JSONValue.self, forKey: .input) ?? .object([:]))
        case "tool_result":
            self = .toolResult(toolUseID: try container.decode(String.self, forKey: .toolUseID), content: try container.decodeIfPresent(String.self, forKey: .content) ?? "", isError: try container.decodeIfPresent(Bool.self, forKey: .isError) ?? false)
        case "attachment":
            self = .attachment(try container.decode(AgentAttachment.self, forKey: .file))
        case "failure":
            self = .failure(try container.decode(AgentFailure.self, forKey: .failure))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown block type \(other)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .thinking(let text, let signature):
            try container.encode("thinking", forKey: .type)
            try container.encode(text, forKey: .text)
            try container.encodeIfPresent(signature, forKey: .signature)
        case .redactedThinking(let data):
            try container.encode("redacted_thinking", forKey: .type)
            try container.encode(data, forKey: .data)
        case .toolUse(let id, let name, let input):
            try container.encode("tool_use", forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(name, forKey: .name)
            try container.encode(input, forKey: .input)
        case .toolResult(let toolUseID, let content, let isError):
            try container.encode("tool_result", forKey: .type)
            try container.encode(toolUseID, forKey: .toolUseID)
            try container.encode(content, forKey: .content)
            try container.encode(isError, forKey: .isError)
        case .attachment(let file):
            try container.encode("attachment", forKey: .type)
            try container.encode(file, forKey: .file)
        case .failure(let failure):
            try container.encode("failure", forKey: .type)
            try container.encode(failure, forKey: .failure)
        }
    }
}

public enum AgentTranscript {
    /// The result text for a tool call that never finished: the reply was cut
    /// off or interrupted before the tool could run.
    public static let interruptedToolCallText = "This tool call did not finish: the reply was interrupted before it ran."
    /// The result text for a call whose result was lost with the app or the
    /// conversation, so it may in fact have run.
    public static let missingToolResultText = "No result was recorded for this tool call: the app was closed or the conversation was switched while it was in flight. It may have run. Check the current state before repeating it."
    /// The result text when the output limit ended the reply before the call was answered.
    public static let maxTokensToolCallText = "The reply reached the model's output limit, so this tool call did not run. If its input was cut off, send it again in smaller parts."
    /// The result text for a call whose streamed input never parsed, so it cannot be run.
    public static let cutOffInputToolCallText = "This tool call's input was not valid JSON (it may have been cut off), so it did not run. Send it again with valid JSON, in smaller parts if it was large."

    /// Returns a transcript the Messages API accepts: failure rows are left out
    /// (they are for the reader only), and every assistant turn with tool calls
    /// is answered by the very next user turn, with exactly one result per call
    /// in call order, results before any other block, and results that answer
    /// nothing dropped. Missing results are added as errors that warn the call
    /// may have run; a call with an empty id (a half-streamed block) or a
    /// repeated id is dropped. Healthy history is returned unchanged, so the
    /// function is idempotent.
    public static func repaired(_ messages: [AgentMessage]) -> [AgentMessage] {
        repair(messages, keepingFailures: false)
    }

    /// The same repair for the transcript that is shown and saved: failure rows
    /// stay where they are and the repair passes over them, so
    /// `repaired(healed(x)) == repaired(x)`.
    public static func healed(_ messages: [AgentMessage]) -> [AgentMessage] {
        repair(messages, keepingFailures: true)
    }

    private static func repair(_ messages: [AgentMessage], keepingFailures: Bool) -> [AgentMessage] {
        var out: [AgentMessage] = []
        // The call ids of the immediately preceding assistant turn, still unanswered.
        var pending: [String] = []

        for message in messages {
            if message.failure != nil {
                // Neither a reply nor a user turn: it answers no call and leaves
                // the pending ones for the next user turn.
                if keepingFailures { out.append(message) }
                continue
            }
            if message.role == .assistant {
                if !pending.isEmpty {
                    out.append(answering(pending))
                    pending = []
                }
                let copy = withoutInvalidToolUses(message)
                // A turn that only held half-streamed calls has nothing left to show.
                guard !copy.blocks.isEmpty || message.blocks.isEmpty else { continue }
                out.append(copy)
                pending = copy.toolUses.map(\.id)
            } else {
                var seen = Set<String>()
                var answers: [String: AgentContentBlock] = [:]
                var others: [AgentContentBlock] = []
                for block in message.blocks {
                    if case .toolResult(let id, _, _) = block {
                        guard pending.contains(id), seen.insert(id).inserted else { continue }
                        answers[id] = block
                    } else {
                        others.append(block)
                    }
                }
                // Results lead the turn, in the order of the calls they answer.
                var blocks: [AgentContentBlock] = pending.map { id in
                    answers[id] ?? .toolResult(toolUseID: id, content: missingToolResultText, isError: true)
                }
                blocks.append(contentsOf: others)
                pending = []
                // A turn whose only blocks were orphaned results goes too.
                guard !blocks.isEmpty || message.blocks.isEmpty else { continue }
                var copy = message
                copy.blocks = blocks
                out.append(copy)
            }
        }
        // A reply interrupted after its calls still needs an answer at the end.
        if !pending.isEmpty { out.append(answering(pending)) }
        return out
    }

    /// Drops calls that cannot be answered: a half-streamed block with no id,
    /// and any later call that repeats an id already used in the same turn.
    static func withoutInvalidToolUses(_ message: AgentMessage) -> AgentMessage {
        guard message.role == .assistant else { return message }
        var seen = Set<String>()
        var copy = message
        copy.blocks = message.blocks.filter { block in
            guard case .toolUse(let id, _, _) = block else { return true }
            return !id.isEmpty && seen.insert(id).inserted
        }
        return copy
    }

    private static func answering(_ ids: [String]) -> AgentMessage {
        AgentMessage(role: .user, blocks: ids.map {
            .toolResult(toolUseID: $0, content: missingToolResultText, isError: true)
        })
    }

    public static func encode(_ messages: [AgentMessage]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(messages)
    }

    public static func decode(_ data: Data) throws -> [AgentMessage] {
        guard !data.isEmpty else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([AgentMessage].self, from: data)
    }

    /// The conversation as plain text for the clipboard: each visible turn
    /// under "You" or the assistant's name, attachments by name and tool calls as one line.
    /// A failure row is a line of its own in brackets, after any text that streamed before it.
    /// Thinking and tool results are left out. A transcript does not record who wrote each
    /// reply, so one name labels every assistant turn.
    public static func plainText(_ messages: [AgentMessage], assistantName: String = "Claude") -> String {
        let assistantHeading = "\(assistantName):\n"
        var turns: [String] = []
        for message in messages {
            var lines: [String] = []
            for block in message.blocks {
                switch block {
                case .text(let text):
                    lines.append(text)
                case .attachment(let file):
                    lines.append("[Attached: \(file.fileName)]")
                case .toolUse(_, let name, let input):
                    let detail = input["command"]?.stringValue ?? input["path"]?.stringValue ?? input["remote_path"]?.stringValue ?? input["file_name"]?.stringValue
                    let host = input["host"]?.stringValue.map { " on \($0)" } ?? ""
                    lines.append("[\(name)\(host)\(detail.map { ": \($0)" } ?? "")]")
                case .thinking, .redactedThinking, .toolResult, .failure:
                    break
                }
            }
            if !lines.isEmpty {
                let body = lines.joined(separator: "\n")
                // Consecutive assistant messages (a reply split by tool calls) read as one turn.
                if message.role == .assistant, let last = turns.last, last.hasPrefix(assistantHeading) {
                    turns[turns.count - 1] = last + "\n" + body
                } else {
                    turns.append((message.role == .user ? "You:\n" : assistantHeading) + body)
                }
            }
            if let failure = message.failure {
                turns.append("[\(failure.summary)]")
            }
        }
        return turns.joined(separator: "\n\n")
    }
}
