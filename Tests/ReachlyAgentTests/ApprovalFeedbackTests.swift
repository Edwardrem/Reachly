import Foundation
import SwiftData
import Testing
import ReachlyCore
@testable import ReachlyAgent

/// The approval sheet's comment: the user asks for changes instead of running
/// the command, and the model gets the comment back as an ordinary tool result.
@Suite("Approval feedback")
@MainActor
struct ApprovalFeedbackTests {
    private func runCommand(_ runner: AgentToolRunner, _ command: String, on host: String = "web-01", reason: String = "check disk") async -> AgentToolRunner.Result {
        await runner.call(name: AgentToolName.runCommand.rawValue, input: ["host": .string(host), "command": .string(command), "reason": .string(reason)])
    }

    private func waitUntilDone(_ session: AgentSession) async {
        await waitFor { !session.isRunning }
        #expect(!session.isRunning)
    }

    @Test func commentReturnsFeedbackAndNeverRuns() async {
        let host = FakeToolHost(hosts: [FakeToolHost.web])
        host.approval = { _ in .requestChanges(comment: "Only the nginx unit,\nand just the last hour.", editedCommand: nil) }
        let runner = AgentToolRunner(host: host, source: .agentPanel)

        let result = await runCommand(runner, "journalctl --no-pager")

        #expect(host.approvalRequests.map(\.command) == ["journalctl --no-pager"])
        #expect(host.executed.isEmpty)
        #expect(!result.isError)
        #expect(AgentToolRunner.changesRequestedPrefix == "The user did not run this command and wants changes")
        #expect(result.content.hasPrefix(AgentToolRunner.changesRequestedPrefix + " before anything runs on web-01."))
        #expect(result.content.contains("<user_comment>\nOnly the nginx unit,\nand just the last hour.\n</user_comment>"))
        #expect(!result.content.contains("<suggested_command>"))
        #expect(result.content.contains("call run_command again"))
        #expect(!result.content.contains("<command_output"))
    }

    @Test func editPlusCommentIncludesBoth() async throws {
        let host = FakeToolHost(hosts: [FakeToolHost.web])
        host.approval = { _ in .requestChanges(comment: "Check the data volume instead.", editedCommand: "  df -h /data\n") }
        let runner = AgentToolRunner(host: host, source: .agentPanel)

        let result = await runCommand(runner, "df -h")

        #expect(host.executed.isEmpty)
        #expect(!result.isError)
        #expect(result.content.contains("<user_comment>\nCheck the data volume instead.\n</user_comment>"))
        #expect(result.content.contains("<suggested_command>\ndf -h /data\n</suggested_command>"))
        let record = try #require(host.auditRecords.first)
        #expect(record.decisionDetail.contains("Suggested command: df -h /data"))
        #expect(AgentAuditDecision.changesRequestedComment(in: record.decisionDetail) == "Check the data volume instead.")
        // The entry keeps the command as proposed: the suggestion did not run.
        #expect(record.command == "df -h")
        #expect(record.proposedCommand == nil)
    }

    @Test func unchangedEditIsNotOfferedAsASuggestion() async {
        let host = FakeToolHost(hosts: [FakeToolHost.web])
        host.approval = { _ in .requestChanges(comment: "Why sudo?", editedCommand: " df -h ") }
        let runner = AgentToolRunner(host: host, source: .agentPanel)

        let result = await runCommand(runner, "df -h")

        #expect(!result.isError)
        #expect(!result.content.contains("<suggested_command>"))
        #expect(AgentApprovalResponse.changeRequest(comment: "Why sudo?", command: "df -h", proposed: "df -h") == .requestChanges(comment: "Why sudo?", editedCommand: nil))
        #expect(AgentApprovalResponse.changeRequest(comment: "Why sudo?", command: "   ", proposed: "df -h") == .requestChanges(comment: "Why sudo?", editedCommand: nil))
        #expect(AgentApprovalResponse.changeRequest(comment: "Why sudo?", command: "df -h /", proposed: "df -h") == .requestChanges(comment: "Why sudo?", editedCommand: "df -h /"))
    }

    @Test func auditRecordsTheDecisionAndTheComment() async throws {
        let host = FakeToolHost(hosts: [FakeToolHost.web])
        host.approval = { _ in .requestChanges(comment: "Use systemctl reload, not restart.", editedCommand: nil) }
        let runner = AgentToolRunner(host: host, source: .mcp, conversationID: UUID())

        _ = await runCommand(runner, "systemctl restart nginx", reason: "apply config")

        let record = try #require(host.auditRecords.first)
        #expect(host.auditRecords.count == 1)
        #expect(record.decision == .changesRequested)
        #expect(!record.decision.ran)
        #expect(record.decision.displayName == "Changes requested")
        #expect(record.decisionDetail.contains("Comment: Use systemctl reload, not restart."))
        #expect(AgentAuditDecision.changesRequestedComment(in: record.decisionDetail) == "Use systemctl reload, not restart.")
        #expect(record.reason == "apply config")
        #expect(record.source == .mcp)
        #expect(record.exitStatus == nil)
        #expect(record.outputExcerpt.isEmpty)

        let json = try #require(String(data: try AgentAuditRecord.exportJSON(host.auditRecords), encoding: .utf8))
        #expect(json.contains(#""decision" : "changes-requested""#))
        #expect(json.contains("Use systemctl reload, not restart."))
        let decoded = try JSONDecoder.iso8601.decode([AgentAuditRecord].self, from: Data(json.utf8))
        #expect(decoded.first?.decision == .changesRequested)
    }

    @Test func destructiveCommandsTakeCommentsToo() async throws {
        let host = FakeToolHost(hosts: [FakeToolHost.web])
        host.approval = { _ in .requestChanges(comment: "Keep today's logs.", editedCommand: "find /var/log/nginx -name '*.gz' -mtime +1 -delete") }
        let runner = AgentToolRunner(host: host, source: .agentPanel)

        let result = await runCommand(runner, "rm -rf /var/log/nginx/*", reason: "free space")

        #expect(host.approvalRequests.first?.isDestructive == true)
        #expect(host.executed.isEmpty)
        #expect(!result.isError)
        #expect(result.content.contains("Keep today's logs."))
        #expect(result.content.contains("find /var/log/nginx -name '*.gz' -mtime +1 -delete"))
        #expect(host.auditRecords.map(\.decision) == [.changesRequested])
    }

    @Test func emptyCommentCannotBeSent() async {
        #expect(AgentApprovalResponse.normalizedComment("") == nil)
        #expect(AgentApprovalResponse.normalizedComment(" \n\t  ") == nil)
        #expect(AgentApprovalResponse.changeRequest(comment: "  \n ", command: "df -h /", proposed: "df -h") == nil)

        // The runner refuses one that arrives anyway, and runs nothing.
        let host = FakeToolHost(hosts: [FakeToolHost.web])
        host.approval = { _ in .requestChanges(comment: "   \n", editedCommand: "df -h /") }
        let runner = AgentToolRunner(host: host, source: .agentPanel)

        let result = await runCommand(runner, "df -h")

        #expect(host.executed.isEmpty)
        #expect(result.isError)
        #expect(result.content.contains("denied"))
        #expect(host.auditRecords.map(\.decision) == [.denied])
        #expect(host.auditRecords.first?.decisionDetail == "empty change request")
    }

    @Test func commentIsTrimmedAndBounded() async {
        #expect(AgentApprovalResponse.normalizedComment("  use --since 1h \n") == "use --since 1h")
        #expect(AgentApprovalResponse.commentLimit == 2_000)

        let long = "  " + String(repeating: "a", count: 2_500)
        let clipped = AgentApprovalResponse.normalizedComment(long)
        #expect(clipped?.count == 2_000)
        #expect(clipped == String(repeating: "a", count: 2_000))
        // Clipping counts characters, never splits one, and leaves no trailing space.
        #expect(AgentApprovalResponse.normalizedComment(String(repeating: "👍🏽", count: 2_001))?.count == 2_000)
        #expect(AgentApprovalResponse.normalizedComment(String(repeating: "b", count: 1_999) + "   tail")?.count == 1_999)

        let host = FakeToolHost(hosts: [FakeToolHost.web])
        host.approval = { _ in .requestChanges(comment: long, editedCommand: nil) }
        let runner = AgentToolRunner(host: host, source: .agentPanel)

        let result = await runCommand(runner, "df -h")

        #expect(!result.isError)
        #expect(result.content.contains("<user_comment>\n" + String(repeating: "a", count: 2_000) + "\n</user_comment>"))
        #expect(!result.content.contains(String(repeating: "a", count: 2_001)))
        #expect(host.auditRecords.first?.decisionDetail.contains(String(repeating: "a", count: 2_001)) == false)
    }

    @Test func modelRevisesAfterTheCommentAndAsksAgain() async {
        let host = FakeToolHost(hosts: [FakeToolHost.web])
        host.approval = { request in
            request.command == "df -h" ? .requestChanges(comment: "Only /srv please.", editedCommand: nil) : .approved
        }
        let provider = FakeProvider(responses: [
            FakeProvider.toolCall(.runCommand, id: "t1", ["host": "web-01", "command": "df -h", "reason": "disk"]),
            FakeProvider.toolCall(.runCommand, id: "t2", ["host": "web-01", "command": "df -h /srv", "reason": "disk on /srv"]),
            FakeProvider.reply("/srv has room."),
        ])
        let session = AgentSession(provider: provider, systemPrompt: "sys", toolRunner: AgentToolRunner(host: host, source: .agentPanel, conversationID: UUID()))

        session.send("how is the disk?")
        await waitUntilDone(session)

        #expect(host.approvalRequests.map(\.command) == ["df -h", "df -h /srv"])
        #expect(host.executed.map(\.command) == ["df -h /srv"])
        #expect(host.auditRecords.map(\.decision) == [.changesRequested, .approved])
        guard case .toolResult(let id, let content, let isError)? = session.messages[2].blocks.first else { Issue.record("no tool result"); return }
        #expect(id == "t1")
        #expect(!isError)
        #expect(content.contains("<user_comment>\nOnly /srv please.\n</user_comment>"))
        // The model saw the feedback before it proposed the revision.
        #expect(provider.requests.count == 3)
        #expect(provider.requests[1].messages.last?.blocks.first == .toolResult(toolUseID: "t1", content: content, isError: false))
        #expect(session.messages.last?.text == "/srv has room.")
    }

    @Test func auditCommentReadsBackForTheRow() throws {
        let multiline = "Keep today's logs.\nAnd skip /var/log/nginx/error.log."
        let detail = AgentAuditDecision.changesRequestedDetail(guardrail: "Destructive: rm -rf.", comment: multiline, suggestion: "find /var/log/nginx -name '*.gz' -delete")
        #expect(detail == "Destructive: rm -rf.\nSuggested command: find /var/log/nginx -name '*.gz' -delete\nComment: " + multiline)
        #expect(AgentAuditDecision.changesRequestedComment(in: detail) == multiline)
        #expect(AgentAuditDecision.changesRequestedComment(in: AgentAuditDecision.changesRequestedDetail(guardrail: "", comment: "Why sudo?", suggestion: nil)) == "Why sudo?")
        #expect(AgentAuditDecision.changesRequestedComment(in: "This host asks for every command.") == nil)
        #expect(AgentAuditDecision.changesRequestedComment(in: "This host asks for every command.\nComment:   ") == nil)

        let revised = AgentAuditEntry(source: .agentPanel, hostID: nil, hostName: "web-01", hostTarget: "me@host", tool: "run_command", command: "rm -rf /var/log/nginx/*", reason: "", decision: .changesRequested, decisionDetail: detail)
        #expect(revised.changesRequestedComment == multiline)
        // Other decisions never show a comment line, whatever their detail says.
        let denied = AgentAuditEntry(source: .agentPanel, hostID: nil, hostName: "web-01", hostTarget: "me@host", tool: "run_command", command: "true", reason: "", decision: .denied, decisionDetail: detail)
        #expect(denied.changesRequestedComment == nil)
    }

    @Test func heredocCommentLineDoesNotFoolTheAuditRow() async throws {
        let heredoc = "cat > /etc/motd <<'EOF'\nComment: maintenance tonight\nEOF"
        let host = FakeToolHost(hosts: [FakeToolHost.web])
        host.approval = { _ in .requestChanges(comment: "Keep the old banner.", editedCommand: heredoc) }
        let runner = AgentToolRunner(host: host, source: .agentPanel)

        let result = await runCommand(runner, "rm /etc/motd")

        #expect(result.content.contains("<suggested_command>\n" + heredoc + "\n</suggested_command>"))
        let record = try #require(host.auditRecords.first)
        #expect(record.decisionDetail.contains("Suggested command: cat > /etc/motd <<'EOF'\n  Comment: maintenance tonight\n  EOF\nComment: Keep the old banner."))
        #expect(AgentAuditDecision.changesRequestedComment(in: record.decisionDetail) == "Keep the old banner.")
        let entry = AgentAuditEntry(source: record.source, hostID: record.hostID, hostName: record.hostName, hostTarget: record.hostTarget, tool: record.tool, command: record.command, reason: record.reason, decision: record.decision, decisionDetail: record.decisionDetail)
        #expect(entry.changesRequestedComment == "Keep the old banner.")

        // CRLF line endings, a guardrail that spans lines or starts like a
        // comment, and a comment that itself mentions "Comment: " all round-trip.
        let crlf = "cat > /etc/motd <<'EOF'\r\nComment: tonight\r\nEOF"
        #expect(AgentAuditDecision.changesRequestedComment(in: AgentAuditDecision.changesRequestedDetail(guardrail: "", comment: "No.", suggestion: crlf)) == "No.")
        let guardrail = "Comment: odd guardrail\nComment: second line"
        #expect(AgentAuditDecision.changesRequestedComment(in: AgentAuditDecision.changesRequestedDetail(guardrail: guardrail, comment: "Fine.", suggestion: nil)) == "Fine.")
        let comment = "Two things.\nComment: keep this line too."
        #expect(AgentAuditDecision.changesRequestedComment(in: AgentAuditDecision.changesRequestedDetail(guardrail: "Ask.", comment: comment, suggestion: heredoc)) == comment)
    }

    @Test func otherToolsSendTheCommentAlone() async throws {
        let temp = FileManager.default.temporaryDirectory.appending(path: "reachly-feedback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let upload = temp.appending(path: "site.tar.gz")
        try Data("payload".utf8).write(to: upload)

        let host = FakeToolHost(hosts: [FakeToolHost.web])
        host.approval = { _ in .requestChanges(comment: "Upload it to /srv/releases instead.", editedCommand: "cat > /srv/releases/site.tar.gz") }
        let runner = AgentToolRunner(host: host, source: .mcp)

        let transfer = await runner.call(name: AgentToolName.sftpTransfer.rawValue, input: ["host": "web-01", "direction": "upload", "remote_path": "/tmp/site.tar.gz", "local_path": .string(upload.path), "reason": "deploy"])
        let write = await runner.call(name: AgentToolName.writeFile.rawValue, input: ["host": "web-01", "path": "/etc/motd", "contents": "hello", "reason": "banner"])

        #expect(host.approvalRequests.map(\.isCommandEditable) == [false, false])
        #expect(host.executed.isEmpty)
        for (result, tool) in [(transfer, "sftp_transfer"), (write, "write_file")] {
            #expect(!result.isError)
            #expect(result.content.hasPrefix(AgentToolRunner.changesRequestedPrefix))
            #expect(result.content.contains("<user_comment>\nUpload it to /srv/releases instead.\n</user_comment>"))
            #expect(!result.content.contains("<suggested_command>"))
            #expect(!result.content.contains("cat > /srv/releases"))
            #expect(result.content.contains("Adjust the \(tool) arguments to follow their comment and call \(tool) again"))
            #expect(!result.content.contains("run_command"))
        }
        #expect(host.auditRecords.map(\.decision) == [.changesRequested, .changesRequested])
        #expect(host.auditRecords.allSatisfy { !$0.decisionDetail.contains("Suggested command") })

        // The sheet builds the same answer, so its hint never promises the edit.
        #expect(AgentApprovalResponse.changeRequest(comment: "x", command: "cat > /srv/a", proposed: "cat > /tmp/a", includingEdit: false)?.suggestedCommand == nil)
        #expect(AgentApprovalResponse.changeRequest(comment: "x", command: "df -h /", proposed: "df -h")?.suggestedCommand == "df -h /")
        // A whitespace-only edit is no edit: nothing to send, nothing to mention.
        #expect(AgentApprovalResponse.changeRequest(comment: "x", command: "df -h \n", proposed: "df -h")?.suggestedCommand == nil)
        #expect(AgentApprovalResponse.approved.suggestedCommand == nil)
    }

    @Test func onlyRunCommandIsEditable() {
        for tool in AgentToolName.allCases {
            let request = AgentApprovalRequest(source: .agentPanel, host: FakeToolHost.web, tool: tool.rawValue, command: "x", reason: "", detail: "", isDestructive: false)
            #expect(request.isCommandEditable == (tool == .runCommand), "\(tool.rawValue)")
        }
    }

    @Test func editsToStandInLinesRunNothing() async throws {
        let temp = FileManager.default.temporaryDirectory.appending(path: "reachly-edit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let upload = temp.appending(path: "site.tar.gz")
        try Data("payload".utf8).write(to: upload)

        let host = FakeToolHost(hosts: [FakeToolHost.web])
        host.approval = { _ in .edited("cat > /srv/elsewhere") }
        let runner = AgentToolRunner(host: host, source: .agentPanel)

        let calls: [(AgentToolName, JSONValue)] = [
            (.writeFile, ["host": "web-01", "path": "/etc/motd", "contents": "hello", "reason": "banner"]),
            (.sftpTransfer, ["host": "web-01", "direction": "upload", "remote_path": "/tmp/site.tar.gz", "local_path": .string(upload.path), "reason": "deploy"]),
            (.sftpTransfer, ["host": "web-01", "direction": "download", "remote_path": "/etc/hosts", "local_path": .string(temp.appending(path: "hosts").path), "reason": "copy"]),
            (.readFile, ["host": "web-01", "path": "/etc/hosts"]),
        ]
        for (tool, input) in calls {
            let result = await runner.call(name: tool.rawValue, input: input)
            #expect(result.isError, "\(tool.rawValue)")
            #expect(result.content == "The user's edit can't be applied to \(tool.rawValue); nothing ran.")
        }

        #expect(host.approvalRequests.count == calls.count)
        #expect(host.executed.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: temp.appending(path: "hosts").path))
        #expect(host.auditRecords.map(\.decision) == Array(repeating: .denied, count: calls.count))
        #expect(!host.auditRecords.contains { $0.decision == .edited || $0.decision.ran })
        #expect(host.auditRecords.map(\.decisionDetail) == calls.map { "The user's edit can't be applied to \($0.0.rawValue); nothing ran." })
        #expect(host.auditRecords.allSatisfy { $0.proposedCommand == nil && !$0.command.contains("/srv/elsewhere") })
    }

    @Test func runCommandEditsStillRunTheEditedText() async throws {
        let host = FakeToolHost(hosts: [FakeToolHost.web])
        host.approval = { _ in .edited("  df -h /srv\n") }
        let runner = AgentToolRunner(host: host, source: .mcp)

        let result = await runCommand(runner, "df -h")

        #expect(!result.isError)
        #expect(result.content.contains("ran: df -h /srv"))
        #expect(host.executed.map(\.command) == ["df -h /srv"])
        let record = try #require(host.auditRecords.first)
        #expect(host.auditRecords.map(\.decision) == [.edited])
        #expect(record.command == "df -h /srv")
        #expect(record.proposedCommand == "df -h")
    }

    @Test func systemPromptExplainsComments() {
        let prompt = AgentSystemPrompt.build(hosts: [], focus: nil)
        #expect(prompt.contains("The user may approve, edit, deny, or send a comment asking for changes; a denied command must not be retried unchanged."))
        #expect(prompt.contains("After a comment nothing has run: revise the command to follow it and call the tool again (the user reviews the new version), or reply to the user when the comment is a question."))
    }

    @Test func oldAuditRawValuesStillDecode() throws {
        let stored = ["auto-allowed": AgentAuditDecision.autoAllowed, "approved": .approved, "edited": .edited, "denied": .denied, "blocked": .blocked, "cancelled": .cancelled, "changes-requested": .changesRequested]
        for (raw, decision) in stored {
            #expect(AgentAuditDecision(rawValue: raw) == decision)
            #expect(decision.rawValue == raw)
        }
        #expect(Set(AgentAuditDecision.allCases.map(\.rawValue)) == Set(stored.keys))

        // A record exported before this change still decodes.
        let old = #"[{"id":"6F1C2B9E-3E0A-4E59-9B0D-1C8E2A4D5F60","timestamp":"2026-10-01T09:30:00Z","source":"agent","hostID":null,"hostName":"web-01","hostTarget":"ubuntu@10.0.0.5","tool":"run_command","command":"df -h","reason":"disk","decision":"edited","decisionDetail":"This host asks for every command.","outputExcerpt":""}]"#
        let records = try JSONDecoder.iso8601.decode([AgentAuditRecord].self, from: Data(old.utf8))
        #expect(records.first?.decision == .edited)
    }

    @Test func storedEntriesKeepTheirDecision() throws {
        let container = try ModelContainer(for: Schema(ReachlySchema.models), configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let context = ModelContext(container)
        for decision in AgentAuditDecision.allCases {
            context.insert(AgentAuditEntry(source: .agentPanel, hostID: nil, hostName: decision.rawValue, hostTarget: "me@host", tool: "run_command", command: "true", reason: "", decision: decision))
        }
        let legacy = AgentAuditEntry(source: .mcp, hostID: nil, hostName: "legacy", hostTarget: "me@host", tool: "run_command", command: "true", reason: "", decision: .approved)
        legacy.decisionRaw = "denied"
        context.insert(legacy)
        try context.save()

        let entries = try context.fetch(FetchDescriptor<AgentAuditEntry>())
        let byHost = Dictionary(uniqueKeysWithValues: entries.map { ($0.hostName, $0.decision) })
        for decision in AgentAuditDecision.allCases {
            #expect(byHost[decision.rawValue] == decision)
        }
        #expect(byHost["legacy"] == .denied)
        #expect(AgentAuditRecord(try #require(entries.first { $0.hostName == "changes-requested" })).decision == .changesRequested)
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
