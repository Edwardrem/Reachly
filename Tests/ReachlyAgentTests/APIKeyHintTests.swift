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
        /// Every existence check fails, as a locked Keychain would.
        var failExists = false

        func itemExists(account: String) throws -> Bool {
            if failExists { throw FakeError.existsFailed }
            return items[account] != nil
        }

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
        case existsFailed
    }

    /// Every test gets its own defaults suite and removes it, so no preview leaks into the next run.
    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let name = "reachly-key-hint-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    private var anthropicAccount: String { LLMProviderConfiguration.Kind.anthropic.keychainAccount }
    private var caimexAccount: String { LLMProviderConfiguration.Kind.caimex.keychainAccount }
    private var endpointAccount: String { LLMProviderConfiguration.Kind.openAICompatible.keychainAccount }

    /// A test key of `count` characters with no `-`, so no prefix is taken from it.
    private func plainKey(_ count: Int) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<count).map { alphabet[$0 % alphabet.count] })
    }

    // MARK: The format

    @Test func anAnthropicKeyKeepsItsFormatMarkerAndLastFour() {
        #expect(APIKeyHint.make(for: "sk-ant-api03-" + plainKey(80) + "a1b2") == "sk-ant-api03-…a1b2")
        // Another Anthropic key type still shares `sk-ant-`, and nothing after it is kept.
        #expect(APIKeyHint.make(for: "sk-ant-admin01-" + plainKey(80) + "a1b2") == "sk-ant-…a1b2")
    }

    @Test func aKnownFormatMarkerIsKeptLongestFirst() {
        #expect(APIKeyHint.make(for: "sk-proj-" + plainKey(40) + "wxyz") == "sk-proj-…wxyz")
        #expect(APIKeyHint.make(for: "sk-" + plainKey(40) + "wxyz") == "sk-…wxyz")
        let markers = APIKeyHint.formatPrefixes
        #expect(markers == markers.sorted { $0.count > $1.count }, "a shorter marker must never shadow a longer one")
    }

    @Test func aDashEarlyInAnUnknownKeyIsNotAPrefix() {
        // Seven secret characters before the dash: keeping them would put 11 of 28 outside the Keychain.
        #expect(APIKeyHint.make(for: "a1b2c3d-9f8e7d6c5b4a39281706") == "…1706")
        #expect(APIKeyHint.make(for: "x-" + plainKey(40) + "wxyz") == "…wxyz")
    }

    @Test func aUUIDStyleKeyKeepsNoPrefix() {
        #expect(APIKeyHint.make(for: "123e4567-e89b-12d3-a456-426614174000") == "…4000")
        #expect(APIKeyHint.make(for: UUID().uuidString)?.hasPrefix("…") == true)
    }

    @Test func anUnknownFormatKeepsNoPrefix() {
        #expect(APIKeyHint.make(for: "cmx-" + plainKey(40) + "c3d4") == "…c3d4")
        #expect(APIKeyHint.make(for: "gsk_" + plainKey(40) + "c3d4") == "…c3d4")
        #expect(APIKeyHint.make(for: "SK-ANT-" + plainKey(40) + "c3d4") == "…c3d4", "markers match exactly")
        #expect(APIKeyHint.make(for: "ask-" + plainKey(40) + "c3d4") == "…c3d4", "a marker counts only at the start")
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
        // Sixteen characters in all, but only eight after `sk-proj-`: the marker plus four would be most of it.
        #expect(APIKeyHint.make(for: "sk-proj-abcdefgh") == "…gh")
        #expect(APIKeyHint.make(for: "sk-ant-" + "abcdefghijklmno") == "…no")
    }

    @Test func aVeryShortKeyHasNoPreview() {
        #expect(APIKeyHint.make(for: "ollama") == nil)
        #expect(APIKeyHint.make(for: "sk-ant-ab") == nil, "the part after the marker is too short to show any of")
        #expect(APIKeyHint.make(for: "") == nil)
        #expect(APIKeyHint.make(for: "  \n") == nil)
    }

    @Test func surroundingWhitespaceIsIgnoredAsItIsWhenSaving() {
        let key = "sk-ant-api03-" + plainKey(40) + "a1b2"
        #expect(APIKeyHint.make(for: "  \(key)\n") == "sk-ant-api03-…a1b2")
    }

    @Test func noPreviewShowsMoreThanFourTrailingCharactersOrAQuarterOfTheSecret() {
        // Known markers are not secret, so the quarter is measured on what follows them.
        for marker in ["", "sk-", "sk-ant-", "sk-proj-", "sk-ant-api03-"] {
            for count in 0...80 {
                let key = marker + plainKey(count)
                guard let hint = APIKeyHint.make(for: key) else {
                    #expect(count < 8, "a body of \(count) characters should have a preview")
                    continue
                }
                let parts = hint.components(separatedBy: "…")
                #expect(parts.count == 2)
                let shownPrefix = parts[0]
                let tail = parts[1]
                #expect(shownPrefix.isEmpty || shownPrefix == marker)
                #expect(tail.count <= 4)
                #expect(key.hasSuffix(tail))
                #expect(tail.count * 4 <= count, "\(hint) shows too much of a \(key.count)-character key")
            }
        }
        // Anything else before a dash may be secret: no prefix, and the quarter is measured on the whole key.
        for unknown in ["a1b2c3d-", "cmx-", "x-", "123e4567-e89b-", "-"] {
            for count in 0...80 {
                let key = unknown + plainKey(count)
                guard let hint = APIKeyHint.make(for: key) else {
                    #expect(key.count < 8, "a key of \(key.count) characters should have a preview")
                    continue
                }
                let parts = hint.components(separatedBy: "…")
                #expect(parts.count == 2)
                #expect(parts[0].isEmpty, "\(hint) keeps part of an unknown key's start")
                #expect(parts[1].count <= 4)
                #expect(key.hasSuffix(parts[1]))
                #expect(parts[1].count * 4 <= key.count, "\(hint) shows too much of a \(key.count)-character key")
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
            #expect(hints.hint(for: .anthropic) == "sk-ant-api03-…a1b2")
        }
    }

    @Test func aFailedWriteLeavesTheOldPreviewForTheKeyStillStored() {
        withDefaults { defaults in
            let hints = APIKeyHintStore(defaults: defaults)
            hints.save("sk-ant-api03-" + plainKey(40) + "a1b2", for: .anthropic) {}

            #expect(throws: FakeError.writeFailed) {
                try hints.save("sk-ant-api03-" + plainKey(40) + "c3d4", for: .anthropic) { throw FakeError.writeFailed }
            }
            #expect(hints.hint(for: .anthropic) == "sk-ant-api03-…a1b2")

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

            #expect(hints.hint(for: .anthropic) == "sk-ant-api03-…a1b2")
            #expect(hints.hint(for: .caimex) == "…c3d4")
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
            #expect(hints.hint(for: .anthropic) == "sk-ant-api03-…a1b2")

            hints.remove(for: .anthropic) {}

            #expect(hints.hint(for: .anthropic) == nil)
            #expect(hints.hint(for: .caimex) == "…c3d4", "removing one kind's key leaves the others")
        }
    }

    @Test func removeAllForgetsEveryKindsPreview() {
        withDefaults { defaults in
            let hints = APIKeyHintStore(defaults: defaults)
            for kind in LLMProviderConfiguration.Kind.allCases {
                hints.save(plainKey(40), for: kind) {}
            }
            defaults.set("unrelated", forKey: "agent.provider.test")

            hints.removeAll()

            for kind in LLMProviderConfiguration.Kind.allCases {
                #expect(hints.hint(for: kind) == nil)
                #expect(defaults.object(forKey: APIKeyHintStore.defaultsKey(for: kind)) == nil)
            }
            #expect(defaults.string(forKey: "agent.provider.test") == "unrelated", "only previews are removed")
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
            #expect(values.contains("sk-ant-api03-…a1b2"))
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
            #expect(hints.hint(for: .openAICompatible) == "…9999")
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
            #expect(hints.hint(for: .anthropic) == "sk-ant-api03-…a1b2")
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

    // MARK: keyState: what the settings screen shows, and pruning

    @Test func aSavedKeyAnswersItsPreview() {
        withDefaults { defaults in
            let store = FakeKeyStore()
            let migration = APIKeyMigration(store: store, defaults: defaults)
            migration.run(legacyKind: .anthropic)
            let hints = APIKeyHintStore(defaults: defaults)
            let key = "sk-ant-api03-" + plainKey(40) + "a1b2"
            hints.save(key, for: .anthropic) { store.items[anthropicAccount] = key }

            #expect(migration.keyState(for: .anthropic) == SavedKeyState(hasKey: true, hint: "sk-ant-api03-…a1b2"))
            #expect(migration.keyState(for: .caimex) == SavedKeyState(hasKey: false, hint: nil))
        }
    }

    @Test func aKeyRemovedElsewhereDropsItsPreview() {
        withDefaults { defaults in
            let store = FakeKeyStore()
            let migration = APIKeyMigration(store: store, defaults: defaults)
            migration.run(legacyKind: .anthropic)
            let hints = APIKeyHintStore(defaults: defaults)
            hints.save("cmx-" + plainKey(40) + "c3d4", for: .caimex) { store.items[caimexAccount] = "caimex-test-key" }
            hints.save("sk-ant-" + plainKey(40) + "a1b2", for: .anthropic) { store.items[anthropicAccount] = "sk-ant-test-key" }

            // Security › Remove All, or Keychain Access, deletes the item without going through Settings.
            store.items[caimexAccount] = nil

            #expect(migration.keyState(for: .caimex) == SavedKeyState(hasKey: false, hint: nil))
            #expect(hints.hint(for: .caimex) == nil, "the stored preview is dropped, not just hidden")
            #expect(hints.hint(for: .anthropic) == "sk-ant-…a1b2", "only the kind that was asked about is pruned")
        }
    }

    @Test func aStalePreviewNeverComesBackForADifferentKey() {
        withDefaults { defaults in
            let store = FakeKeyStore()
            let migration = APIKeyMigration(store: store, defaults: defaults)
            migration.run(legacyKind: .anthropic)
            let hints = APIKeyHintStore(defaults: defaults)
            hints.save(plainKey(40) + "old1", for: .caimex) { store.items[caimexAccount] = "old-test-key" }

            store.items[caimexAccount] = nil
            _ = migration.keyState(for: .caimex)
            // A different key arrives without a preview (an older build saved it): it must not get the old one.
            store.items[caimexAccount] = "new-test-key"

            #expect(migration.keyState(for: .caimex) == SavedKeyState(hasKey: true, hint: nil))
        }
    }

    @Test func anUnreadableStoreAnswersNoKeyButKeepsThePreview() {
        withDefaults { defaults in
            let store = FakeKeyStore()
            let migration = APIKeyMigration(store: store, defaults: defaults)
            migration.run(legacyKind: .anthropic)
            let hints = APIKeyHintStore(defaults: defaults)
            hints.save(plainKey(40) + "c3d4", for: .caimex) { store.items[caimexAccount] = "caimex-test-key" }
            store.failExists = true

            #expect(migration.keyState(for: .caimex) == SavedKeyState(hasKey: false, hint: nil))
            #expect(hints.hint(for: .caimex) == "…c3d4", "the item may still be there")

            store.failExists = false
            #expect(migration.keyState(for: .caimex) == SavedKeyState(hasKey: true, hint: "…c3d4"))
        }
    }

    @Test func aWithheldAccountAnswersNoKeyAndPrunesNothing() {
        withDefaults { defaults in
            let store = FakeKeyStore()
            store.items[anthropicAccount] = "endpoint-test-key"
            store.failMoves = true
            let migration = APIKeyMigration(store: store, defaults: defaults)
            migration.run(legacyKind: .openAICompatible)
            #expect(migration.account(for: .anthropic) == nil)
            let hints = APIKeyHintStore(defaults: defaults)
            hints.save("endpoint-" + plainKey(40) + "e5f6", for: .anthropic) {}

            #expect(migration.keyState(for: .anthropic) == SavedKeyState(hasKey: false, hint: nil))
            #expect(hints.hint(for: .anthropic) == "…e5f6", "a pending move withholds the account; it is not empty")
        }
    }

    @Test func keyStateAgreesWithHasKey() {
        withDefaults { defaults in
            let store = FakeKeyStore()
            store.items[caimexAccount] = "caimex-test-key"
            let migration = APIKeyMigration(store: store, defaults: defaults)
            migration.run(legacyKind: .anthropic)

            for failing in [false, true] {
                store.failExists = failing
                for kind in LLMProviderConfiguration.Kind.allCases {
                    #expect(migration.keyState(for: kind).hasKey == migration.hasKey(for: kind))
                }
            }
        }
    }
}
