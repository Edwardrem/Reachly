import Foundation
import Testing
import ReachlyCore
@testable import ReachlyAgent

@Suite("API key hint")
struct APIKeyHintTests {
    /// In-memory stand-in for the Keychain. A class so the migration's writes stay visible here.
    private final class FakeKeyStore: APIKeyStore, @unchecked Sendable {
        var items: [String: String] = [:]
        /// A locked or busy Keychain: every move fails until the test clears it.
        var failMoves = false

        func itemExists(account: String) throws -> Bool { items[account] != nil }

        func itemHasPrefix(account: String, prefix: String) throws -> Bool {
            items[account]?.hasPrefix(prefix) ?? false
        }

        func move(from source: String, to destination: String, label: String) throws {
            if failMoves { throw FakeError.writeFailed }
            guard let value = items[source] else { throw SecretStoreError.itemNotFound(source) }
            guard items[destination] == nil else { throw SecretStoreError.destinationNotEmpty(destination) }
            items[destination] = value
            items[source] = nil
        }

        func delete(account: String) throws { items[account] = nil }
    }

    private enum FakeError: Error {
        case writeFailed
    }

    /// Every test gets its own defaults suite and removes it, so no preview leaks into the next run.
    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let name = "reachly-key-hint-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    private var anthropicAccount: String { LLMProviderConfiguration.Kind.anthropic.keychainAccount }
    private var endpointAccount: String { LLMProviderConfiguration.Kind.openAICompatible.keychainAccount }

    /// A test key of `count` characters with no `-`, so no prefix is taken from it.
    private func plainKey(_ count: Int) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<count).map { alphabet[$0 % alphabet.count] })
    }

    // MARK: The format

    @Test func anAnthropicKeyKeepsItsPrefixAndLastFour() {
        let key = "sk-ant-api03-" + plainKey(80) + "a1b2"
        #expect(APIKeyHint.make(for: key) == "sk-ant-…a1b2")
    }

    @Test func theLastDashInTheFirstEightCharactersEndsThePrefix() {
        #expect(APIKeyHint.make(for: "sk-proj-" + plainKey(40) + "wxyz") == "sk-proj-…wxyz")
        #expect(APIKeyHint.make(for: "sk-" + plainKey(40) + "wxyz") == "sk-…wxyz")
    }

    @Test func aDashAfterTheFirstEightCharactersIsNotAPrefix() {
        let key = "abcdefghij-" + plainKey(30) + "wxyz"
        #expect(APIKeyHint.make(for: key) == "…wxyz")
    }

    @Test func aKeyWithNoDashShowsOnlyItsLastFour() {
        let key = plainKey(28) + "9z8y"
        #expect(APIKeyHint.make(for: key) == "…9z8y")
    }

    @Test func aKeyUnderSixteenCharactersShowsOnlyItsLastTwo() {
        #expect(APIKeyHint.make(for: "abcdefghijklmno") == "…no")
        #expect(APIKeyHint.make(for: "abcdefgh") == "…gh")
        #expect(APIKeyHint.make(for: plainKey(16)) == "…" + plainKey(16).suffix(4))
    }

    @Test func aShortBodyAfterAPrefixShowsNoPrefixAndOnlyTwo() {
        // Sixteen characters in all, but only nine after `sk-proj-`: the prefix plus four would be most of it.
        #expect(APIKeyHint.make(for: "sk-proj-abcdefgh") == "…gh")
        #expect(APIKeyHint.make(for: "sk-ant-" + "abcdefghijklmno") == "…no")
    }

    @Test func aVeryShortKeyHasNoPreview() {
        #expect(APIKeyHint.make(for: "ollama") == nil)
        #expect(APIKeyHint.make(for: "sk-ant-ab") == nil, "the part after the prefix is too short to show any of")
        #expect(APIKeyHint.make(for: "") == nil)
        #expect(APIKeyHint.make(for: "  \n") == nil)
    }

    @Test func surroundingWhitespaceIsIgnoredAsItIsWhenSaving() {
        let key = "sk-ant-api03-" + plainKey(40) + "a1b2"
        #expect(APIKeyHint.make(for: "  \(key)\n") == "sk-ant-…a1b2")
    }

    @Test func noPreviewShowsMoreThanFourTrailingCharactersOrAQuarterOfTheSecret() {
        for prefix in ["", "sk-", "sk-ant-", "sk-proj-"] {
            for count in 0...80 {
                let key = prefix + plainKey(count)
                guard let hint = APIKeyHint.make(for: key) else {
                    #expect(count < 8, "a body of \(count) characters should have a preview")
                    continue
                }
                let parts = hint.components(separatedBy: "…")
                #expect(parts.count == 2)
                let shownPrefix = parts[0]
                let tail = parts[1]
                #expect(shownPrefix.isEmpty || shownPrefix == prefix)
                #expect(tail.count <= 4)
                #expect(key.hasSuffix(tail))
                // The secret is the key after its format prefix; at most a quarter of it is visible.
                #expect(tail.count * 4 <= count, "\(hint) shows too much of a \(key.count)-character key")
            }
        }
    }

    // MARK: Where previews are kept

    @Test func aPreviewIsRecordedOnlyAfterTheWriteSucceeds() {
        withDefaults { defaults in
            let hints = APIKeyHintStore(defaults: defaults)
            let key = "sk-ant-api03-" + plainKey(40) + "a1b2"
            var wrote = false

            hints.save(key, for: .anthropic) {
                #expect(hints.hint(for: .anthropic) == nil, "the preview must not exist before the write returns")
                wrote = true
            }

            #expect(wrote)
            #expect(hints.hint(for: .anthropic) == "sk-ant-…a1b2")
        }
    }

    @Test func aFailedWriteLeavesTheOldPreviewForTheKeyStillStored() {
        withDefaults { defaults in
            let hints = APIKeyHintStore(defaults: defaults)
            hints.save("sk-ant-api03-" + plainKey(40) + "a1b2", for: .anthropic) {}

            #expect(throws: FakeError.writeFailed) {
                try hints.save("sk-ant-api03-" + plainKey(40) + "c3d4", for: .anthropic) { throw FakeError.writeFailed }
            }
            #expect(hints.hint(for: .anthropic) == "sk-ant-…a1b2")

            #expect(throws: FakeError.writeFailed) {
                try hints.save(plainKey(40), for: .caimex) { throw FakeError.writeFailed }
            }
            #expect(hints.hint(for: .caimex) == nil)
        }
    }

    @Test func aKeyTooShortToPreviewReplacesTheOldPreviewWithNone() {
        withDefaults { defaults in
            let hints = APIKeyHintStore(defaults: defaults)
            hints.save(plainKey(40), for: .openAICompatible) {}
            #expect(hints.hint(for: .openAICompatible) != nil)

            hints.save("ollama", for: .openAICompatible) {}

            #expect(hints.hint(for: .openAICompatible) == nil, "the old preview would describe a key that is gone")
        }
    }

    @Test func eachKindKeepsItsOwnPreview() {
        withDefaults { defaults in
            let hints = APIKeyHintStore(defaults: defaults)
            hints.save("sk-ant-api03-" + plainKey(40) + "a1b2", for: .anthropic) {}
            hints.save("cmx-" + plainKey(40) + "c3d4", for: .caimex) {}

            #expect(hints.hint(for: .anthropic) == "sk-ant-…a1b2")
            #expect(hints.hint(for: .caimex) == "cmx-…c3d4")
            #expect(hints.hint(for: .openAICompatible) == nil)
            #expect(Set(LLMProviderConfiguration.Kind.allCases.map(APIKeyHintStore.defaultsKey(for:))).count == 3)
        }
    }

    @Test func removingClearsThePreviewOnlyAfterTheDeleteSucceeds() {
        withDefaults { defaults in
            let hints = APIKeyHintStore(defaults: defaults)
            hints.save("sk-ant-api03-" + plainKey(40) + "a1b2", for: .anthropic) {}
            hints.save("cmx-" + plainKey(40) + "c3d4", for: .caimex) {}

            #expect(throws: FakeError.writeFailed) {
                try hints.remove(for: .anthropic) { throw FakeError.writeFailed }
            }
            #expect(hints.hint(for: .anthropic) == "sk-ant-…a1b2")

            hints.remove(for: .anthropic) {}

            #expect(hints.hint(for: .anthropic) == nil)
            #expect(hints.hint(for: .caimex) == "cmx-…c3d4", "removing one kind's key leaves the others")
        }
    }

    @Test func aKeySavedBeforePreviewsExistedHasNone() {
        withDefaults { defaults in
            // Nothing recorded: the screen shows the plain "saved" text and nothing reads the key to fill it.
            let hints = APIKeyHintStore(defaults: defaults)
            for kind in LLMProviderConfiguration.Kind.allCases {
                #expect(hints.hint(for: kind) == nil)
            }
        }
    }

    @Test func theKeyItselfIsNeverWrittenToDefaults() {
        withDefaults { defaults in
            let hints = APIKeyHintStore(defaults: defaults)
            let key = "sk-ant-api03-" + plainKey(80) + "a1b2"
            hints.save(key, for: .anthropic) {}

            let values = defaults.dictionaryRepresentation().values.compactMap { $0 as? String }
            #expect(!values.contains { $0.contains(plainKey(80)) })
            #expect(values.contains("sk-ant-…a1b2"))
        }
    }

    // MARK: The preview follows the 0.3.8 key move

    @Test func aMovedEndpointKeyTakesItsPreviewWithIt() {
        withDefaults { defaults in
            let store = FakeKeyStore()
            store.items[anthropicAccount] = "endpoint-test-key"
            let hints = APIKeyHintStore(defaults: defaults)
            // A preview recorded for the item under agent.apiKey describes that item, wherever it goes.
            hints.save("endpoint-" + plainKey(40) + "e5f6", for: .anthropic) {}

            APIKeyMigration(store: store, defaults: defaults).run(legacyKind: .openAICompatible)

            #expect(store.items[endpointAccount] == "endpoint-test-key")
            #expect(hints.hint(for: .openAICompatible) == "…e5f6")
            #expect(hints.hint(for: .anthropic) == nil, "Anthropic no longer has that key")
        }
    }

    @Test func aMovedKeyWithNoPreviewClearsAStaleOneAtTheDestination() {
        withDefaults { defaults in
            let store = FakeKeyStore()
            store.items[anthropicAccount] = "endpoint-test-key"
            store.failMoves = true
            let migration = APIKeyMigration(store: store, defaults: defaults)
            migration.run(legacyKind: .openAICompatible)

            // The endpoint account is empty, so a preview there describes nothing that is stored.
            let hints = APIKeyHintStore(defaults: defaults)
            hints.save("stale-" + plainKey(40), for: .openAICompatible) {}
            store.failMoves = false
            migration.retryPendingMove()

            #expect(store.items[endpointAccount] == "endpoint-test-key")
            #expect(hints.hint(for: .openAICompatible) == nil)
            #expect(hints.hint(for: .anthropic) == nil)
        }
    }

    @Test func aSupersededOldKeyTakesItsPreviewAwayAndLeavesTheNewOne() {
        withDefaults { defaults in
            let store = FakeKeyStore()
            store.items[anthropicAccount] = "old-endpoint-test-key"
            store.failMoves = true
            let migration = APIKeyMigration(store: store, defaults: defaults)
            migration.run(legacyKind: .openAICompatible)

            // While the move was pending, the user saved a new endpoint key, with its preview.
            let hints = APIKeyHintStore(defaults: defaults)
            hints.save("old-" + plainKey(40) + "0000", for: .anthropic) {}
            let newKey = "new-" + plainKey(40) + "9999"
            hints.save(newKey, for: .openAICompatible) { store.items[endpointAccount] = newKey }

            migration.run(legacyKind: .openAICompatible)

            #expect(store.items[anthropicAccount] == nil)
            #expect(hints.hint(for: .anthropic) == nil)
            #expect(hints.hint(for: .openAICompatible) == "new-…9999")
        }
    }

    @Test func anAnthropicKeyLeftInPlaceKeepsItsPreview() {
        withDefaults { defaults in
            let store = FakeKeyStore()
            let key = "sk-ant-api03-" + plainKey(40) + "a1b2"
            store.items[anthropicAccount] = key
            let hints = APIKeyHintStore(defaults: defaults)
            hints.save(key, for: .anthropic) {}

            APIKeyMigration(store: store, defaults: defaults).run(legacyKind: .openAICompatible)

            #expect(store.items[anthropicAccount] == key)
            #expect(hints.hint(for: .anthropic) == "sk-ant-…a1b2")
            #expect(hints.hint(for: .openAICompatible) == nil)
        }
    }

    @Test func aFailedMoveLeavesEveryPreviewWhereItWas() {
        withDefaults { defaults in
            let store = FakeKeyStore()
            store.items[anthropicAccount] = "endpoint-test-key"
            store.failMoves = true
            let hints = APIKeyHintStore(defaults: defaults)
            hints.save("endpoint-" + plainKey(40) + "e5f6", for: .anthropic) {}

            APIKeyMigration(store: store, defaults: defaults).run(legacyKind: .openAICompatible)

            #expect(store.items[anthropicAccount] == "endpoint-test-key")
            #expect(hints.hint(for: .anthropic) == "…e5f6")
            #expect(hints.hint(for: .openAICompatible) == nil)
        }
    }
}
