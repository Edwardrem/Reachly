import Foundation
import Observation
import ReachlyAgent
import ReachlyCore

/// Provider choice, model and the API key for the Claude panel. The key lives
/// in the Keychain behind the vault; everything else is in UserDefaults.
@MainActor
@Observable
final class AgentSettings {
    static let shared = AgentSettings()
    static let configurationKey = "agent.provider"

    var configuration: LLMProviderConfiguration {
        didSet {
            save()
            // The key and its state belong to the selected kind; finish a pending move first.
            if configuration.kind != oldValue.kind {
                migration.retryPendingMove()
                refreshKeyState()
            }
        }
    }
    private(set) var hasAPIKey: Bool
    /// The preview of the selected kind's saved key, such as `sk-ant-…a1b2`, read from UserDefaults. Nil
    /// when there is no key, or the key was saved before previews existed.
    private(set) var savedKeyHint: String?
    /// Bumped whenever the selected kind's saved key changes, so the panel rebuilds its provider even
    /// when the configuration (kind, model, URL) looks the same.
    private(set) var keyVersion = 0

    /// One migration for the app: run once in `init`, then consulted for every key operation.
    private let migration: APIKeyMigration
    /// Written only after the Keychain write or delete it describes has succeeded.
    private let hints = APIKeyHintStore()

    private init() {
        let stored: LLMProviderConfiguration
        if let data = UserDefaults.standard.data(forKey: Self.configurationKey),
           let decoded = try? JSONDecoder().decode(LLMProviderConfiguration.self, from: data) {
            stored = decoded
        } else {
            stored = LLMProviderConfiguration()
        }
        configuration = stored

        let migration = APIKeyMigration()
        // Decide who owns the 0.3.8 key before anything reads it; this also retries a pending move.
        migration.run(legacyKind: stored.kind)
        self.migration = migration
        let state = migration.keyState(for: stored.kind)
        hasAPIKey = state.hasKey
        savedKeyHint = state.hint
    }

    private func save() {
        if let data = try? JSONEncoder().encode(configuration) {
            UserDefaults.standard.set(data, forKey: Self.configurationKey)
        }
    }

    /// Re-reads whether the selected kind has a key, and its preview, dropping the preview when the
    /// Keychain definitely has no item for it. It only asks whether the item exists: no secret is read and
    /// the vault stays locked, so Settings may call it on appear.
    func refreshKeyState() {
        let state = migration.keyState(for: configuration.kind)
        hasAPIKey = state.hasKey
        savedKeyHint = state.hint
    }

    /// Captures the provider's inputs before any prompt, so a picker change while Touch ID is up cannot
    /// retarget the key, the host or the recorded version. Retries a pending move first.
    func providerPlan() -> ProviderBuildPlan {
        migration.retryPendingMove()
        refreshKeyState()
        return migration.plan(for: configuration, keyVersion: keyVersion)
    }

    /// Reads the plan's key, unlocking the vault (Touch ID) first when that is required.
    private func apiKey(for plan: ProviderBuildPlan) async throws -> String? {
        guard plan.hasKey, let account = plan.account else { return nil }
        try await Vault.shared.ensureUnlocked(reason: "use the saved API key for the Claude panel")
        return try SecretStore.shared.string(account: account)
    }

    func setAPIKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return try removeAPIKey() }
        let kind = configuration.kind
        // A pending move withholds the account: retry it, but never write to the old one.
        migration.retryPendingMove()
        guard let account = migration.accountForSaving(kind) else {
            throw AgentSetupError(message: "Reachly is still moving the key you saved before. Try again in a moment; nothing was saved.")
        }
        // The preview is recorded for the kind captured above, and only once the Keychain write returns.
        try hints.save(trimmed, for: kind) {
            try SecretStore.shared.set(trimmed, account: account, label: kind.keychainLabel)
        }
        hasAPIKey = true
        savedKeyHint = hints.hint(for: kind)
        keyVersion += 1
    }

    func removeAPIKey() throws {
        migration.retryPendingMove()
        let kind = configuration.kind
        guard let account = migration.account(for: kind) else { return }
        try hints.remove(for: kind) {
            try SecretStore.shared.delete(account: account)
        }
        hasAPIKey = false
        savedKeyHint = nil
        keyVersion += 1
    }

    /// Builds the provider from the plan taken before the prompt; never from live settings. Throws a
    /// readable message when something is missing.
    func makeProvider(for plan: ProviderBuildPlan) async throws -> any LLMProvider {
        let kind = plan.configuration.kind
        let key = try await apiKey(for: plan)
        if key == nil, kind.requiresAPIKey {
            throw AgentSetupError(message: "Add your \(kind.keyName) API key in Settings › AI Integration to start.")
        }
        return try plan.configuration.makeProvider(apiKey: key)
    }
}

struct AgentSetupError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
