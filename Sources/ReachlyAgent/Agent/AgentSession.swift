import Foundation
import Observation
import ReachlyCore

/// One conversation with the model: streams replies, runs tool calls through
/// the guarded runner, and keeps the transcript.
@MainActor
@Observable
public final class AgentSession {
    public private(set) var messages: [AgentMessage]
    public private(set) var isRunning = false
    /// Text of the reply being streamed right now.
    public private(set) var streamingText = ""
    public private(set) var streamingThinking = ""
    /// Tool call in progress, for the status line.
    public private(set) var activeTool: String?
    /// Why the last run ended early. The transcript also records it, as a
    /// failure row where the reply stopped.
    public private(set) var lastError: String?
    public private(set) var lastModel: String?
    public private(set) var servedByFallback = false
    public private(set) var usage = LLMUsage()

    public var provider: any LLMProvider
    /// Set when an agent that runs its own loop answers, such as Qoder over ACP. Turns then go to it instead of
    /// `provider`, `systemPrompt` is the context it gets at the start of a session, and Reachly's tool runner
    /// does not run its tools: it reaches the servers through Reachly's MCP server, under the same guardrails.
    public var externalAgent: (any ExternalAgent)?
    /// The finished part of an external agent's reply in progress, in the order it came: text, reasoning, tool
    /// calls, plans and notices. `streamingThinking` and `streamingText` are the part still coming in.
    public private(set) var streamingBlocks: [AgentContentBlock] = []
    /// The ACP message the streaming text belongs to; a chunk with another id starts a new block.
    private var streamingMessageID: String?
    public var systemPrompt: String
    public let toolRunner: AgentToolRunner
    public var tools: [AgentToolDefinition] = AgentTools.all
    /// Rounds of tool calls per user message before the agent stops to check in.
    public var maxToolRounds = 40
    /// Called whenever the transcript changes, for persistence.
    public var transcriptDidChange: (() -> Void)?

    private var task: Task<Void, Never>?
    /// A run that `replace` abandoned; the next `start` waits for it to unwind
    /// so two runs never use the same tool runner at once.
    private var abandonedTask: Task<Void, Never>?
    /// Identifies the current run, so a run abandoned by `replace` can tell and
    /// stop touching the session. Bumped by `start` and by `replace`.
    private var runGeneration = 0
    /// Keep at most this much unparsed input from a call that never completed.
    private static let maximumStoredCutOffInputLength = 2_000

    public init(provider: any LLMProvider, systemPrompt: String, toolRunner: AgentToolRunner, messages: [AgentMessage] = []) {
        self.provider = provider
        self.systemPrompt = systemPrompt
        self.toolRunner = toolRunner
        self.messages = AgentTranscript.healed(messages)
    }

    public var canSend: Bool { !isRunning }

    /// Names the conversation the session holds. `replace` gives each
    /// conversation it swaps in a new token, so work that started before an
    /// await (building a provider can wait on Touch ID) can pass the token it
    /// started with and change nothing if another conversation is shown by then.
    public struct ConversationToken: Hashable, Sendable {
        public let id = UUID()
    }

    public private(set) var conversationToken = ConversationToken()

    /// Sends a message. With `token`, only while the session still holds that
    /// conversation; returns whether the message was sent.
    @discardableResult
    public func send(_ text: String, attachments: [AgentAttachment] = [], in token: ConversationToken? = nil) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty, !isRunning, holds(token) else { return false }
        // A transcript loaded from an older version can end in an unanswered call;
        // heal it before the new turn goes after it.
        messages = AgentTranscript.healed(messages)
        append(.user(trimmed, attachments: attachments))
        start()
        return true
    }

    /// Records a turn that could not start (no key, Touch ID cancelled): the
    /// message joins the transcript with the reason in a failure row under it,
    /// so what was typed and attached is kept and `retry` can send it. With
    /// `token`, only while the session still holds that conversation.
    @discardableResult
    public func recordUnsent(_ text: String, attachments: [AgentAttachment] = [], reason: String, in token: ConversationToken? = nil) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty, !isRunning, holds(token) else { return false }
        messages = AgentTranscript.healed(messages)
        messages.append(.user(trimmed, attachments: attachments))
        fail(.setup, reason)
        return true
    }

    /// Records that a retry could not start. A row for a message that was never
    /// sent now gives this reason; any other row keeps its own failure, and what
    /// streamed before it, and adds that the retry did not start. Without a
    /// failure row at the end, a new one is added. With `token`, only while the
    /// session still holds that conversation.
    @discardableResult
    public func recordSetupFailure(_ reason: String, in token: ConversationToken? = nil) -> Bool {
        guard !isRunning, holds(token) else { return false }
        lastError = reason
        guard let last = messages.indices.last, let current = messages[last].failure else {
            append(AgentMessage(failure: AgentFailure(kind: .setup, message: reason)))
            return true
        }
        var updated = current
        if current.kind == .setup {
            updated.message = reason
        } else {
            updated.retryError = reason
        }
        messages[last].blocks = messages[last].blocks.map { block in
            if case .failure = block { return .failure(updated) }
            return block
        }
        transcriptDidChange?()
        return true
    }

    /// True when the conversation ends in a failure row that `retry` can run again.
    public var canRetry: Bool {
        !isRunning && messages.last?.failure != nil && messages.contains { $0.role == .user && $0.failure == nil }
    }

    /// Runs the turn that ended in the latest failure row again. The row goes,
    /// with the reply it ended if that reply finished the turn (cut off,
    /// refused, stopped), and the model answers again from the last user turn
    /// or tool results. The user's message is not repeated, and completed tool
    /// rounds are not run again. With `token`, only while the session still
    /// holds that conversation; returns whether the turn started.
    @discardableResult
    public func retry(in token: ConversationToken? = nil) -> Bool {
        guard canRetry, holds(token) else { return false }
        var kept = messages
        kept.removeLast()
        while let last = kept.last, last.role == .assistant, last.failure == nil {
            kept.removeLast()
        }
        kept = AgentTranscript.healed(kept)
        guard AgentTranscript.repaired(kept).last?.role == .user else { return false }
        messages = kept
        transcriptDidChange?()
        start()
        return true
    }

    private func holds(_ token: ConversationToken?) -> Bool {
        token.map { $0 == conversationToken } ?? true
    }

    /// Stops the current reply or tool call. Pending tool calls get error results so the transcript stays valid.
    public func stop() {
        task?.cancel()
    }

    public func clear() {
        guard !isRunning else { return }
        messages = []
        externalAgent?.forgetSession(for: externalConversationKey)
        lastError = nil
        transcriptDidChange?()
    }

    /// Replaces the whole conversation. A reply in flight belongs to the old
    /// conversation, so it is abandoned rather than allowed to save its partial
    /// turn into the new one; the swap always takes effect.
    public func replace(messages: [AgentMessage]) {
        if isRunning {
            if let running = task {
                running.cancel()
                abandonedTask = running
            }
            runGeneration += 1
            isRunning = false
            streamingText = ""
            streamingThinking = ""
            streamingBlocks = []
            streamingMessageID = nil
            activeTool = nil
            task = nil
        }
        self.messages = AgentTranscript.healed(messages)
        conversationToken = ConversationToken()
        lastError = nil
    }

    /// Drops the message with this id and everything after it, so an earlier
    /// user message can be edited and sent again. Returns the dropped message,
    /// or nil when a reply is running or the id is unknown.
    @discardableResult
    public func rewind(to messageID: UUID) -> AgentMessage? {
        guard !isRunning, let index = messages.firstIndex(where: { $0.id == messageID }) else { return nil }
        let message = messages[index]
        messages.removeSubrange(index...)
        // Cutting at any id can leave a reply with unanswered calls at the end.
        messages = AgentTranscript.healed(messages)
        // An external agent's session still holds what was cut.
        externalAgent?.forgetSession(for: externalConversationKey)
        lastError = nil
        transcriptDidChange?()
        return message
    }

    private func start() {
        lastError = nil
        isRunning = true
        runGeneration += 1
        let generation = runGeneration
        let previous = abandonedTask
        abandonedTask = nil
        task = Task { [weak self] in
            // A run abandoned by replace must finish unwinding before the next
            // one starts, or two tool calls could overlap on the same runner.
            _ = await previous?.value
            await self?.run(generation: generation)
            self?.finishRun(generation: generation)
        }
    }

    private func finishRun(generation: Int) {
        guard isCurrent(generation) else { return }
        isRunning = false
        streamingText = ""
        streamingThinking = ""
        streamingBlocks = []
        streamingMessageID = nil
        activeTool = nil
        task = nil
    }

    private func isCurrent(_ generation: Int) -> Bool {
        runGeneration == generation
    }

    private func append(_ message: AgentMessage) {
        messages.append(message)
        transcriptDidChange?()
    }

    /// What has streamed of the reply in progress: an external agent's finished blocks, then the reasoning and
    /// text still coming in.
    private var partialBlocks: [AgentContentBlock] {
        var blocks = streamingBlocks
        if !streamingThinking.isEmpty { blocks.append(.thinking(text: streamingThinking, signature: nil)) }
        if !streamingText.isEmpty { blocks.append(.text(streamingText)) }
        return blocks
    }

    /// Ends the run early: `message` becomes `lastError` and a failure row in
    /// the transcript. With `keepingPartial`, what streamed of the unfinished
    /// reply goes in the row, shown but never sent.
    private func fail(_ kind: AgentFailure.Kind, _ message: String, keepingPartial: Bool = false) {
        lastError = message
        let partial = keepingPartial ? partialBlocks : []
        append(AgentMessage(failure: AgentFailure(kind: kind, message: message), partial: partial, model: partial.isEmpty ? nil : lastModel))
    }

    /// The user stopped the stream. Streamed text stays a reply the model sees
    /// next time, as before, now with its reasoning; reasoning alone is kept in the row.
    private func stopped() {
        if streamingText.isEmpty {
            fail(.stopped, Self.stoppedText, keepingPartial: true)
        } else {
            append(AgentMessage(role: .assistant, blocks: partialBlocks, model: lastModel))
            fail(.stopped, Self.stoppedText)
        }
    }

    private static let stoppedText = "Stopped."

    private func run(generation: Int) async {
        if let externalAgent {
            await runExternal(externalAgent, generation: generation)
            return
        }
        for _ in 0..<maxToolRounds {
            guard isCurrent(generation) else { return }
            streamingText = ""
            streamingThinking = ""
            activeTool = nil
            let response: LLMResponse
            do {
                response = try await streamOnce(generation: generation)
            } catch is CancellationError {
                guard isCurrent(generation) else { return }
                stopped()
                return
            } catch {
                guard isCurrent(generation) else { return }
                if Task.isCancelled {
                    stopped()
                } else {
                    // What streamed before the failure stays in view, in the row.
                    fail(.error, error.localizedDescription, keepingPartial: true)
                }
                return
            }
            guard isCurrent(generation) else { return }
            // Keep the stored partial input small and drop calls this turn cannot
            // keep (an empty id or a repeated one) before the reply is saved.
            let normalised = AgentTranscript.withoutInvalidToolUses(response.message)
            // A reply whose only content was unusable calls has nothing to show.
            guard !normalised.blocks.isEmpty || response.message.blocks.isEmpty else {
                fail(.unreadable, "The model's reply could not be read. Send the message again.")
                return
            }
            let reply = Self.boundingCutOffInputs(normalised)
            append(reply)
            lastModel = response.model
            servedByFallback = response.servedByFallback
            usage.inputTokens += response.usage.inputTokens
            usage.outputTokens += response.usage.outputTokens
            usage.cacheReadTokens += response.usage.cacheReadTokens
            usage.cacheWriteTokens += response.usage.cacheWriteTokens

            // A reply that carries calls but did not stop for tools (cut off,
            // refused, connection dropped) must answer them immediately, or the
            // API rejects every later message in the conversation.
            let interruptedCalls = response.stopReason == .toolUse ? [] : reply.toolUses
            if !interruptedCalls.isEmpty {
                let text = response.stopReason == .maxTokens
                    ? AgentTranscript.maxTokensToolCallText
                    : AgentTranscript.interruptedToolCallText
                append(AgentMessage(role: .user, blocks: interruptedCalls.map {
                    .toolResult(toolUseID: $0.id, content: text, isError: true)
                }))
            }

            switch response.stopReason {
            case .toolUse:
                // A call whose streamed input did not parse is truncated JSON and
                // must not run; complete calls in the same reply still run, in order.
                let uses = reply.toolUses
                guard !uses.isEmpty else { return }
                var results: [AgentContentBlock] = []
                for use in uses {
                    if Task.isCancelled {
                        results.append(.toolResult(toolUseID: use.id, content: "Cancelled by the user before it ran.", isError: true))
                        continue
                    }
                    guard ToolCallInput.rawArguments(in: use.input) == nil else {
                        results.append(.toolResult(toolUseID: use.id, content: AgentTranscript.cutOffInputToolCallText, isError: true))
                        continue
                    }
                    activeTool = use.name
                    let result = await toolRunner.call(name: use.name, input: use.input)
                    guard isCurrent(generation) else { return }
                    results.append(.toolResult(toolUseID: use.id, content: result.content, isError: result.isError))
                }
                activeTool = nil
                append(AgentMessage(role: .user, blocks: results))
                if Task.isCancelled {
                    fail(.stopped, Self.stoppedText)
                    return
                }
            case .pauseTurn:
                continue
            case .maxTokens:
                fail(.cutOff, "The reply was cut off at the model's output limit. Send \"continue\" to go on.")
                return
            case .refusal:
                fail(.refusal, "The model declined to continue" + (response.refusalCategory.map { " (\($0))" } ?? "") + ".")
                return
            case .endTurn, .other:
                if !interruptedCalls.isEmpty {
                    fail(.interrupted, "The reply was interrupted before a tool call finished. Send \"continue\" to go on.")
                }
                return
            }
        }
        guard isCurrent(generation) else { return }
        fail(.toolRounds, "Stopped after \(maxToolRounds) rounds of tool calls. Send a message to continue.")
    }

    // MARK: External agent

    /// The conversation as an external agent knows it: the saved conversation's id, or, before it is saved,
    /// this session's hold on it.
    public var externalConversationKey: String {
        toolRunner.conversationID?.uuidString ?? "unsaved-\(conversationToken.id.uuidString)"
    }

    /// One turn of an external agent: the latest user message goes to it, and what it reports streams into the
    /// reply in progress, which becomes one assistant message when the turn ends. A stop, an error or the agent
    /// going away leaves a failure row, as a model's reply does.
    private func runExternal(_ agent: any ExternalAgent, generation: Int) async {
        resetStreaming()
        guard let index = messages.lastIndex(where: { $0.role == .user && $0.failure == nil }) else { return }
        let message = messages[index]
        let earlier = messages[..<index].contains { $0.role == .user && $0.failure == nil && (!$0.text.isEmpty || !$0.attachments.isEmpty) }
        let turn = ExternalAgentTurn(
            conversationKey: externalConversationKey,
            message: message,
            context: systemPrompt,
            hasEarlierTurns: earlier)
        let stop: ExternalAgentStopReason
        do {
            stop = try await agent.run(turn) { [weak self] event in
                guard let self, self.isCurrent(generation) else { return }
                self.apply(event)
            }
        } catch is CancellationError {
            guard isCurrent(generation) else { return }
            stopped()
            return
        } catch {
            guard isCurrent(generation) else { return }
            if Task.isCancelled {
                stopped()
            } else {
                // What the agent did before it failed stays in view, in the row.
                fail((error as? ExternalAgentFailure)?.kind ?? .error, error.localizedDescription, keepingPartial: true)
            }
            return
        }
        guard isCurrent(generation) else { return }
        if stop == .cancelled {
            stopped()
            return
        }
        let reply = partialBlocks
        resetStreaming()
        append(AgentMessage(role: .assistant, blocks: reply.isEmpty ? [.notice("\(agent.name) finished without a reply.")] : reply, model: lastModel))
        switch stop {
        case .endTurn, .cancelled:
            break
        case .maxTokens:
            fail(.cutOff, "\(agent.name) stopped at its model's output limit. Send \"continue\" to go on.")
        case .maxTurnRequests:
            fail(.toolRounds, "\(agent.name) reached its limit of model requests for one message. Send a message to continue.")
        case .refusal:
            fail(.refusal, "\(agent.name) declined to continue.")
        }
    }

    private func resetStreaming() {
        streamingText = ""
        streamingThinking = ""
        streamingBlocks = []
        streamingMessageID = nil
        activeTool = nil
    }

    /// Moves the reasoning and text still coming in into `streamingBlocks`, so what comes next starts a new block.
    private func flushStreaming() {
        if !streamingThinking.isEmpty { streamingBlocks.append(.thinking(text: streamingThinking, signature: nil)) }
        if !streamingText.isEmpty { streamingBlocks.append(.text(streamingText)) }
        streamingThinking = ""
        streamingText = ""
    }

    /// Takes one event of an external agent's turn into the reply in progress.
    private func apply(_ event: ExternalAgentEvent) {
        switch event {
        case .started(let agent):
            lastModel = agent ?? externalAgent?.name
        case .notice(let text):
            flushStreaming()
            streamingBlocks.append(.notice(text))
        case .text(let piece, let messageID):
            startsNewMessage(messageID)
            streamingText += piece
        case .thinking(let piece, let messageID):
            startsNewMessage(messageID)
            // Reasoning after text belongs below it, in a block of its own.
            if !streamingText.isEmpty { flushStreaming() }
            streamingThinking += piece
        case .toolCall(let call):
            if let index = streamingBlocks.firstIndex(where: { if case .agentToolCall(let existing) = $0 { existing.id == call.id } else { false } }) {
                streamingBlocks[index] = .agentToolCall(call)
            } else {
                flushStreaming()
                streamingBlocks.append(.agentToolCall(call))
            }
            activeTool = streamingBlocks.reversed().lazy.compactMap { block -> String? in
                if case .agentToolCall(let call) = block, !call.status.isFinished { return call.title }
                return nil
            }.first
        case .plan(let entries):
            // One plan per reply, kept where it first appeared and replaced by each update.
            if let index = streamingBlocks.firstIndex(where: { if case .plan = $0 { true } else { false } }) {
                streamingBlocks[index] = .plan(entries)
            } else {
                flushStreaming()
                streamingBlocks.append(.plan(entries))
            }
        }
    }

    private func startsNewMessage(_ messageID: String?) {
        guard let messageID else { return }
        if let current = streamingMessageID, current != messageID { flushStreaming() }
        streamingMessageID = messageID
    }

    private func streamOnce(generation: Int) async throws -> LLMResponse {
        // Defence in depth: the provider gets a transcript the API accepts even
        // if some other path left an unanswered call behind. `repaired` also
        // leaves out failure rows, which are for the reader only.
        let request = LLMRequest(system: systemPrompt, messages: AgentTranscript.repaired(messages), tools: tools)
        var final: LLMResponse?
        for try await event in provider.stream(request) {
            try Task.checkCancellation()
            guard isCurrent(generation) else { throw CancellationError() }
            switch event {
            case .started(let model): lastModel = model
            case .textDelta(let piece): streamingText += piece
            case .thinkingDelta(let piece): streamingThinking += piece
            case .toolUseStarted(let name): activeTool = name
            case .done(let response): final = response
            }
        }
        guard isCurrent(generation) else { throw CancellationError() }
        guard let final else { throw LLMError.invalidResponse("the stream ended without a message") }
        return final
    }

    /// Keeps a large unparsed input short: it is saved and sent again with every
    /// later request, so only its start is useful to show that the call failed.
    private static func boundingCutOffInputs(_ message: AgentMessage) -> AgentMessage {
        var message = message
        message.blocks = message.blocks.map { block in
            guard case .toolUse(let id, let name, let input) = block,
                  let partial = ToolCallInput.rawArguments(in: input) else { return block }
            let bounded = String(partial.prefix(maximumStoredCutOffInputLength))
            return .toolUse(id: id, name: name, input: .object([ToolCallInput.rawArgumentsKey: .string(bounded)]))
        }
        return message
    }
}
