import Foundation
import SwiftData
import Testing
@testable import ReachlyCore

@Suite struct AgentAuditFilterTests {
    @Test func ranAndNotRunSplitEveryDecision() {
        let ran: Set<AgentAuditDecision> = [.autoAllowed, .approved, .edited]
        for decision in AgentAuditDecision.allCases {
            #expect(AgentAuditFilter.all.includes(decision))
            #expect(AgentAuditFilter.ran.includes(decision) == ran.contains(decision), "\(decision)")
            #expect(AgentAuditFilter.notRun.includes(decision) == !ran.contains(decision), "\(decision)")
        }
        #expect(Set(AgentAuditFilter.ranDecisionValues) == Set(ran.map(\.rawValue)))
        #expect(AgentAuditFilter.allCases.map(\.title) == ["All", "Ran", "Not run"])
    }
}

@Suite struct AgentAuditSearchTests {
    @Test func blankQueriesMatchEverything() {
        #expect(AgentAuditSearch.normalized("") == nil)
        #expect(AgentAuditSearch.normalized("  \n\t") == nil)
        #expect(AgentAuditSearch.normalized("  df -h ") == "df -h")
        #expect(AgentAuditSearch.matches("   ", command: "ls", hostName: "web-01", hostTarget: "me@web", reason: ""))
    }

    @Test func looksInCommandHostAndReasonIgnoringCaseAndAccents() {
        func matches(_ query: String) -> Bool {
            AgentAuditSearch.matches(query, command: "systemctl status nginx", hostName: "Web-01", hostTarget: "deploy@10.0.0.5", reason: "Check the café proxy")
        }
        #expect(matches("NGINX"))
        #expect(matches("  status nginx "))
        #expect(matches("web-01"))
        #expect(matches("10.0.0.5"))
        #expect(matches("deploy@"))
        #expect(matches("cafe proxy"))
        #expect(!matches("restart"))
        #expect(!matches("nginx restart"))
    }

    @Test func ignoresOutputAndGuardrailDetail() {
        let entry = AgentAuditEntry(source: .mcp, hostID: nil, hostName: "db-01", hostTarget: "me@db", tool: "run_command", command: "uptime", reason: "Load", decision: .autoAllowed, decisionDetail: "read-only command", outputExcerpt: "load average: 0.42")
        #expect(AgentAuditSearch.matches("uptime", entry))
        #expect(!AgentAuditSearch.matches("average", entry))
        #expect(!AgentAuditSearch.matches("read-only", entry))
    }
}

@Suite struct AgentAuditDayTests {
    private func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    private func date(_ text: String) -> Date {
        try! Date(text, strategy: .iso8601)
    }

    @Test func groupsIntoTodayYesterdayAndDates() {
        let utc = calendar("UTC")
        let now = date("2026-11-26T15:00:00Z")
        let stamps = [
            date("2026-11-26T14:59:00Z"),
            date("2026-11-26T00:00:30Z"),
            date("2026-11-25T23:59:30Z"),
            date("2026-11-23T09:00:00Z"),
            date("2026-11-23T08:00:00Z"),
            date("2025-12-31T12:00:00Z"),
        ]
        let days = AgentAuditHistory.groupedByDay(stamps, date: { $0 }, calendar: utc, now: now)
        #expect(days.map(\.label) == [.today, .yesterday, .date(date("2026-11-23T00:00:00Z")), .date(date("2025-12-31T00:00:00Z"))])
        #expect(days.map(\.items.count) == [2, 1, 2, 1])
        #expect(days[0].items == Array(stamps[0...1]))
        #expect(days[2].items == Array(stamps[3...4]))
        #expect(days.map(\.id) == days.map(\.start))
    }

    @Test func usesTheCalendarsTimeZone() {
        let now = date("2026-11-26T10:00:00Z")
        let late = date("2026-11-25T20:00:00Z")
        // 20:00 UTC on the 25th is 05:00 on the 26th in Tokyo, where it is now 19:00 on the 26th.
        #expect(AgentAuditHistory.groupedByDay([late], date: { $0 }, calendar: calendar("UTC"), now: now).map(\.label) == [.yesterday])
        #expect(AgentAuditHistory.groupedByDay([late], date: { $0 }, calendar: calendar("Asia/Tokyo"), now: now).map(\.label) == [.today])
    }

    @Test func yesterdayHoldsAcrossADaylightSavingChange() {
        // Clocks in New York went forward on 8 March 2026, so that day had 23 hours.
        let newYork = calendar("America/New_York")
        let now = date("2026-03-09T00:30:00-04:00")
        let stamps = [date("2026-03-08T00:15:00-05:00"), date("2026-03-07T23:45:00-05:00")]
        let days = AgentAuditHistory.groupedByDay(stamps, date: { $0 }, calendar: newYork, now: now)
        #expect(days.map(\.label) == [.yesterday, .date(date("2026-03-07T00:00:00-05:00"))])
    }

    @Test func keepsTheOrderItWasGiven() {
        let utc = calendar("UTC")
        let now = date("2026-11-26T15:00:00Z")
        let stamps = [date("2026-11-25T10:00:00Z"), date("2026-11-26T10:00:00Z"), date("2026-11-25T09:00:00Z"), date("2026-11-27T01:00:00Z")]
        let days = AgentAuditHistory.groupedByDay(stamps, date: { $0 }, calendar: utc, now: now)
        // A clock that ran ahead gives a later day, shown as a date.
        #expect(days.map(\.label) == [.yesterday, .today, .date(date("2026-11-27T00:00:00Z"))])
        #expect(days[0].items == [stamps[0], stamps[2]])
        #expect(AgentAuditHistory.groupedByDay([Date](), date: { $0 }, calendar: utc, now: now).isEmpty)
    }
}

@Suite @MainActor struct AgentAuditFetchTests {
    /// The store query has to give exactly what the pure filter and search give.
    @Test func fetchAgreesWithTheFilterAndTheSearch() throws {
        let container = try ModelContainer(for: Schema(ReachlySchema.models), configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let context = container.mainContext
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let samples: [(String, String, String, String, AgentAuditDecision)] = [
            ("systemctl status nginx", "web-01", "deploy@web-01.example.org", "Check nginx", .autoAllowed),
            ("rm -rf /var/cache/nginx/*", "web-01", "deploy@web-01.example.org", "Clear the stale cache", .denied),
            ("df -h", "build-box", "ubuntu@10.0.0.5", "See which disk is full", .approved),
            ("du -sh /var/log", "build-box", "ubuntu@10.0.0.5", "Find what fills the disk", .edited),
            ("shutdown -r now", "db-01", "deploy@10.1.0.12", "Apply the kernel update", .blocked),
            ("journalctl -u nginx", "Café", "me@cafe.local", "Read the NGINX log", .cancelled),
            ("apt remove nginx", "db-01", "deploy@10.1.0.12", "", .changesRequested),
        ]
        for (index, sample) in samples.enumerated() {
            context.insert(AgentAuditEntry(
                timestamp: start.addingTimeInterval(Double(index) * 60), source: index.isMultiple(of: 2) ? .agentPanel : .mcp,
                hostID: nil, hostName: sample.1, hostTarget: sample.2, tool: "run_command", command: sample.0,
                reason: sample.3, decision: sample.4))
        }
        // A decision from a newer build reads as blocked, so it is "not run" both ways.
        let future = AgentAuditEntry(timestamp: start.addingTimeInterval(3600), source: .mcp, hostID: nil, hostName: "web-01", hostTarget: "deploy@web-01.example.org", tool: "run_command", command: "nginx -t", reason: "", decision: .approved)
        future.decisionRaw = "queued"
        context.insert(future)
        try context.save()

        let all = try context.fetch(FetchDescriptor<AgentAuditEntry>()).sorted { $0.timestamp > $1.timestamp }
        #expect(all.count == samples.count + 1)
        for filter in AgentAuditFilter.allCases {
            for query in ["", "  ", "nginx", "NGINX", "web-01", "10.0.0.5", "disk", " cache ", "cafe", "zzz"] {
                let fetched = try context.fetch(AgentAuditHistory.fetchDescriptor(filter: filter, search: query, limit: nil))
                let expected = all.filter { filter.includes($0.decision) && AgentAuditSearch.matches(query, $0) }
                #expect(fetched.map(\.uuid) == expected.map(\.uuid), "\(filter) \(query)")
            }
        }
        #expect(try context.fetch(AgentAuditHistory.fetchDescriptor(filter: .notRun, search: "", limit: nil)).contains { $0.uuid == future.uuid })

        let page = try context.fetch(AgentAuditHistory.fetchDescriptor(filter: .all, search: "", limit: 3))
        #expect(page.map(\.uuid) == all.prefix(3).map(\.uuid))
    }
}

@Suite struct AgentAuditDetailTests {
    @Test func otherDecisionsAreAllGuardrail() {
        let detail = AgentAuditDetail(decision: .denied, detail: " Destructive pattern (rm -rf): always asks.\n")
        #expect(detail == AgentAuditDetail(guardrail: "Destructive pattern (rm -rf): always asks."))
        // Text that looks like a comment is only read as one for a change request.
        #expect(AgentAuditDetail(decision: .approved, detail: "Comment: hi").comment == nil)
    }

    @Test func splitsAChangeRequestBackIntoItsParts() {
        let comment = "Keep the last week.\nCheck with ops first."
        let full = AgentAuditDecision.changesRequestedDetail(guardrail: "Destructive pattern (rm -rf).", comment: comment, suggestion: "find /var/log -mtime +7 -delete")
        #expect(AgentAuditDetail(decision: .changesRequested, detail: full) == AgentAuditDetail(guardrail: "Destructive pattern (rm -rf).", suggestion: "find /var/log -mtime +7 -delete", comment: comment))

        let noSuggestion = AgentAuditDecision.changesRequestedDetail(guardrail: "This host asks for every command.", comment: "Why sudo?", suggestion: nil)
        #expect(AgentAuditDetail(decision: .changesRequested, detail: noSuggestion) == AgentAuditDetail(guardrail: "This host asks for every command.", comment: "Why sudo?"))

        let onlyComment = AgentAuditDecision.changesRequestedDetail(guardrail: "", comment: "Not now.", suggestion: nil)
        #expect(AgentAuditDetail(decision: .changesRequested, detail: onlyComment) == AgentAuditDetail(guardrail: "", comment: "Not now."))

        let multiline = AgentAuditDecision.changesRequestedDetail(guardrail: "", comment: "Split it.", suggestion: "cd /srv\nmake clean")
        #expect(AgentAuditDetail(decision: .changesRequested, detail: multiline) == AgentAuditDetail(guardrail: "", suggestion: "cd /srv\nmake clean", comment: "Split it."))

        let entry = AgentAuditEntry(source: .agentPanel, hostID: nil, hostName: "web-01", hostTarget: "me@web", tool: "run_command", command: "rm -rf /tmp/x", reason: "", decision: .changesRequested, decisionDetail: full)
        #expect(entry.detailParts.comment == entry.changesRequestedComment)
    }
}

@Suite struct AgentAuditDurationTests {
    @Test func readsAsMillisecondsSecondsOrMinutes() {
        #expect(AgentAuditHistory.durationText(milliseconds: -5) == "0 ms")
        #expect(AgentAuditHistory.durationText(milliseconds: 0) == "0 ms")
        #expect(AgentAuditHistory.durationText(milliseconds: 850) == "850 ms")
        #expect(AgentAuditHistory.durationText(milliseconds: 1000) == "1 s")
        #expect(AgentAuditHistory.durationText(milliseconds: 1234) == "1.2 s")
        #expect(AgentAuditHistory.durationText(milliseconds: 1960) == "2 s")
        #expect(AgentAuditHistory.durationText(milliseconds: 59_960) == "1 min")
        #expect(AgentAuditHistory.durationText(milliseconds: 120_000) == "2 min")
        #expect(AgentAuditHistory.durationText(milliseconds: 125_400) == "2 min 5 s")
    }

    @Test func sourcesHaveNames() {
        #expect(AgentActionSource.agentPanel.displayName == "Chat panel")
        #expect(AgentActionSource.mcp.displayName == "MCP client")
    }
}
