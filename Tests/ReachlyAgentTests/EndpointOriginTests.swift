import Foundation
import Testing
import ReachlyCore
@testable import ReachlyAgent

@Suite("Endpoint key origin")
struct EndpointOriginTests {
    private final class FakeKeyStore: APIKeyStore, @unchecked Sendable {
        var items: [String: String] = [:]

        func itemExists(account: String) throws -> Bool { items[account] != nil }
        func itemHasPrefix(account: String, prefix: String) throws -> Bool { items[account]?.hasPrefix(prefix) ?? false }

        func move(from source: String, to destination: String, label: String) throws {
            guard let value = items[source] else { throw SecretStoreError.itemNotFound(source) }
            guard items[destination] == nil else { throw SecretStoreError.destinationNotEmpty(destination) }
            items[destination] = value
            items[source] = nil
        }

        func delete(account: String) throws { items[account] = nil }
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let name = "reachly-key-origin-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    private func origin(_ url: String) -> EndpointOrigin? { EndpointOrigin(baseURL: url) }

    private var anthropicAccount: String { LLMProviderConfiguration.Kind.anthropic.keychainAccount }
    private var endpointAccount: String { LLMProviderConfiguration.Kind.openAICompatible.keychainAccount }

    private func endpoint(_ baseURL: String) -> LLMProviderConfiguration {
        LLMProviderConfiguration(kind: .openAICompatible, baseURL: baseURL)
    }

    // MARK: Origins

    @Test func anOriginIsSchemeHostAndPort() throws {
        let openAI = try #require(origin("https://api.openai.com/v1"))
        #expect(openAI.canonical == "https://api.openai.com:443")
        #expect(openAI.description == "https://api.openai.com")
        #expect(origin("HTTPS://API.OpenAI.com:443/v1/") == openAI)
        #expect(origin("  https://api.openai.com/other/path?x=1  ") == openAI)

        let lmStudio = try #require(origin("http://127.0.0.1:1234/v1"))
        #expect(lmStudio.canonical == "http://127.0.0.1:1234")
        #expect(lmStudio.description == "http://127.0.0.1:1234")
        #expect(origin("http://example.com/v1")?.port == 80)
        #expect(origin("http://[::1]:11434/v1")?.canonical == "http://[::1]:11434")
    }

    @Test func anyDifferenceInSchemeHostOrPortIsAnotherOrigin() {
        let openAI = origin("https://api.openai.com/v1")
        #expect(origin("http://api.openai.com/v1") != openAI)
        #expect(origin("https://api.openai.com:8443/v1") != openAI)
        #expect(origin("https://api.openai.com.evil.example/v1") != openAI)
        #expect(origin("https://openrouter.ai/api/v1") != openAI)
        // Names are compared as typed, not resolved: localhost and 127.0.0.1 are different origins.
        #expect(origin("http://localhost:1234/v1") != origin("http://127.0.0.1:1234/v1"))
        #expect(origin("http://127.0.0.1:1234/v1") != origin("http://127.0.0.1:11434/v1"))
    }

    @Test func onlyHTTPEndpointsWithAHostHaveAnOrigin() {
        #expect(origin("") == nil)
        #expect(origin("localhost:1234") == nil)
        #expect(origin("file:///etc/passwd") == nil)
        #expect(origin("ftp://example.com") == nil)
        #expect(origin("https://") == nil)
    }

    @Test func onlyTheEndpointKindTiesItsKeyToAnOrigin() {
        let elsewhere = origin("https://openrouter.ai/api/v1")
        #expect(EndpointKeyPolicy.mayUseKey(kind: .anthropic, savedOrigin: nil, baseURL: ""))
        #expect(EndpointKeyPolicy.mayUseKey(kind: .caimex, savedOrigin: elsewhere, baseURL: "https://api.openai.com/v1"))
        #expect(EndpointKeyPolicy.mayUseKey(kind: .openAICompatible, savedOrigin: elsewhere, baseURL: "https://openrouter.ai/api/v1/"))
        #expect(!EndpointKeyPolicy.mayUseKey(kind: .openAICompatible, savedOrigin: elsewhere, baseURL: "https://api.openai.com/v1"))
        #expect(!EndpointKeyPolicy.mayUseKey(kind: .openAICompatible, savedOrigin: elsewhere, baseURL: "http://127.0.0.1:1234/v1"))
        #expect(!EndpointKeyPolicy.mayUseKey(kind: .openAICompatible, savedOrigin: nil, baseURL: "https://openrouter.ai/api/v1"))
        #expect(!EndpointKeyPolicy.mayUseKey(kind: .openAICompatible, savedOrigin: elsewhere, baseURL: "not a url"))
    }

    @Test func theMismatchMessageNamesTheSavedOrigin() {
        #expect(EndpointKeyPolicy.mismatchMessage(savedOrigin: origin("https://openrouter.ai/api/v1")) == "The saved key was for https://openrouter.ai; enter a key for this endpoint.")
        #expect(EndpointKeyPolicy.mismatchMessage(savedOrigin: origin("http://gpu.lan:8000/v1")) == "The saved key was for http://gpu.lan:8000; enter a key for this endpoint.")
    }

    // MARK: Stored origins

    @Test func anOriginIsStoredBesideThePreviewAndForgotten() {
        withDefaults { defaults in
            let origins = APIKeyOriginStore(defaults: defaults)
            origins.set(origin("https://openrouter.ai/api/v1"), for: .openAICompatible)
            #expect(defaults.string(forKey: "agent.keyOrigin.openai-compatible") == "https://openrouter.ai:443")
            #expect(origins.origin(for: .openAICompatible) == origin("https://openrouter.ai"))
            #expect(origins.origin(for: .anthropic) == nil)

            origins.forget(.openAICompatible)
            #expect(defaults.object(forKey: "agent.keyOrigin.openai-compatible") == nil)
            #expect(origins.origin(for: .openAICompatible) == nil)
        }
    }

    @Test func theUpgradeOriginIsRecordedOnceAndOnlyServesTheEndpoint() {
        withDefaults { defaults in
            let origins = APIKeyOriginStore(defaults: defaults)
            origins.recordUpgradeOrigin(baseURL: "https://gateway.example.com/v1")
            // A later launch with another base URL changes nothing: the upgrade happened once.
            origins.recordUpgradeOrigin(baseURL: "http://127.0.0.1:1234/v1")
            #expect(origins.origin(for: .openAICompatible) == origin("https://gateway.example.com"))
            #expect(origins.origin(for: .anthropic) == nil)
            #expect(origins.origin(for: .caimex) == nil)

            // A key saved later records its own origin, which wins.
            origins.set(origin("http://127.0.0.1:1234/v1"), for: .openAICompatible)
            #expect(origins.origin(for: .openAICompatible) == origin("http://127.0.0.1:1234"))
        }
    }

    @Test func anUpgradeWithNoValidBaseURLTiesTheOldKeyToNothing() {
        withDefaults { defaults in
            let origins = APIKeyOriginStore(defaults: defaults)
            origins.recordUpgradeOrigin(baseURL: "")
            #expect(defaults.string(forKey: APIKeyOriginStore.upgradeDefaultKey) == "")
            origins.recordUpgradeOrigin(baseURL: "https://api.openai.com/v1")
            #expect(origins.origin(for: .openAICompatible) == nil)
        }
    }

    // MARK: Plans

    @Test func aPlanSendsTheEndpointKeyOnlyToItsOrigin() throws {
        withDefaults { defaults in
            let store = FakeKeyStore()
            store.items[endpointAccount] = "endpoint-test-key"
            let migration = APIKeyMigration(store: store, defaults: defaults)
            migration.run(legacyKind: .anthropic)
            APIKeyOriginStore(defaults: defaults).set(origin("https://openrouter.ai/api/v1"), for: .openAICompatible)

            let same = migration.plan(for: endpoint("https://openrouter.ai/api/v1/"), keyVersion: 1)
            #expect(same.account == endpointAccount)
            #expect(same.hasKey)
            #expect(same.withheldKey == nil)

            for elsewhere in ["http://127.0.0.1:1234/v1", "http://localhost:11434/v1", "https://api.openai.com/v1", "http://openrouter.ai/api/v1", ""] {
                let plan = migration.plan(for: endpoint(elsewhere), keyVersion: 1)
                #expect(plan.account == nil, "\(elsewhere)")
                #expect(!plan.hasKey, "\(elsewhere)")
                #expect(plan.withheldKey == .init(savedFor: origin("https://openrouter.ai")))
                #expect(plan.withheldKey?.message == "The saved key was for https://openrouter.ai; enter a key for this endpoint.")
            }
        }
    }

    @Test func anEndpointWithNoKeyWithholdsNothing() {
        withDefaults { defaults in
            let migration = APIKeyMigration(store: FakeKeyStore(), defaults: defaults)
            migration.run(legacyKind: .anthropic)
            let plan = migration.plan(for: endpoint("http://127.0.0.1:1234/v1"), keyVersion: 0)
            #expect(plan.account == endpointAccount)
            #expect(!plan.hasKey)
            #expect(plan.withheldKey == nil)
        }
    }

    @Test func aKeySavedBeforeOriginsKeepsWorkingForTheUpgradeBaseURL() {
        withDefaults { defaults in
            let store = FakeKeyStore()
            store.items[endpointAccount] = "endpoint-test-key"
            let migration = APIKeyMigration(store: store, defaults: defaults)
            migration.run(legacyKind: .anthropic)
            // What AgentSettings does on the first launch of this version, before anything else.
            APIKeyOriginStore(defaults: defaults).recordUpgradeOrigin(baseURL: "https://gateway.example.com/v1")

            #expect(migration.plan(for: endpoint("https://gateway.example.com/v1"), keyVersion: 0).hasKey)
            let moved = migration.plan(for: endpoint("http://127.0.0.1:1234/v1"), keyVersion: 0)
            #expect(!moved.hasKey)
            #expect(moved.withheldKey?.savedFor == origin("https://gateway.example.com"))
        }
    }

    @Test func anAnthropicOrCaimexKeyIsNeverWithheld() {
        withDefaults { defaults in
            let store = FakeKeyStore()
            store.items[anthropicAccount] = "sk-ant-test"
            store.items[LLMProviderConfiguration.Kind.caimex.keychainAccount] = "caimex-test"
            let migration = APIKeyMigration(store: store, defaults: defaults)
            migration.run(legacyKind: .anthropic)
            #expect(migration.plan(for: LLMProviderConfiguration(kind: .anthropic), keyVersion: 0).hasKey)
            #expect(migration.plan(for: LLMProviderConfiguration(kind: .caimex), keyVersion: 0).hasKey)
        }
    }

    @Test func theOldKeyMoveCarriesItsOrigin() {
        withDefaults { defaults in
            let store = FakeKeyStore()
            // 0.3.8 kept the endpoint's key under the Anthropic account.
            store.items[anthropicAccount] = "endpoint-test-key"
            let origins = APIKeyOriginStore(defaults: defaults)
            origins.recordUpgradeOrigin(baseURL: "http://gpu.lan:8000/v1")
            let migration = APIKeyMigration(store: store, defaults: defaults)
            migration.run(legacyKind: .openAICompatible)

            #expect(store.items[endpointAccount] == "endpoint-test-key")
            #expect(migration.savedOrigin(for: .openAICompatible) == origin("http://gpu.lan:8000"))
            #expect(migration.plan(for: endpoint("http://gpu.lan:8000/v1"), keyVersion: 0).hasKey)
            #expect(!migration.plan(for: endpoint("https://api.openai.com/v1"), keyVersion: 0).hasKey)
            #expect(defaults.object(forKey: "agent.keyOrigin.anthropic") == nil)
        }
    }
}
