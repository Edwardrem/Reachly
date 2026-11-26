import Foundation

/// One immutable capture of everything a provider build needs, taken before the vault prompt. The key,
/// the account and the configuration stay paired, so changing the Provider picker while Touch ID is up
/// cannot send one provider's key to another's host.
public struct ProviderBuildPlan: Sendable, Equatable {
    /// A saved key the plan does not use, because it was saved for another endpoint.
    public struct WithheldKey: Sendable, Equatable {
        /// The origin the key was saved for; nil when that is unknown.
        public let savedFor: EndpointOrigin?

        public init(savedFor: EndpointOrigin?) {
            self.savedFor = savedFor
        }

        public var message: String { EndpointKeyPolicy.mismatchMessage(savedOrigin: savedFor) }
    }

    public let configuration: LLMProviderConfiguration
    /// The selected kind's key version when the plan was taken, so the panel records what it built.
    public let keyVersion: Int
    /// The account the snapshot's kind may read, or nil while a pending move withholds it or the key was
    /// saved for another endpoint.
    public let account: String?
    /// Whether `account` held a key the plan may send when the plan was taken.
    public let hasKey: Bool
    /// Set when a key is saved for the kind but not used, because its origin is not the base URL's.
    public let withheldKey: WithheldKey?

    public init(configuration: LLMProviderConfiguration, keyVersion: Int, account: String?, hasKey: Bool, withheldKey: WithheldKey? = nil) {
        self.configuration = configuration
        self.keyVersion = keyVersion
        self.account = account
        self.hasKey = hasKey
        self.withheldKey = withheldKey
    }
}

extension APIKeyMigration {
    /// Captures the configuration and the account that serves its kind right now. Do this before any
    /// await; build the provider and name the system prompt from the plan, never from live settings.
    /// An endpoint key saved for another origin is left out: the plan then has no account and no key.
    public func plan(for configuration: LLMProviderConfiguration, keyVersion: Int) -> ProviderBuildPlan {
        let kind = configuration.kind
        let account = account(for: kind)
        let hasKey = hasKey(for: kind)
        if hasKey {
            let origin = savedOrigin(for: kind)
            if !EndpointKeyPolicy.mayUseKey(kind: kind, savedOrigin: origin, baseURL: configuration.baseURL) {
                return ProviderBuildPlan(configuration: configuration, keyVersion: keyVersion, account: nil, hasKey: false, withheldKey: .init(savedFor: origin))
            }
        }
        return ProviderBuildPlan(configuration: configuration, keyVersion: keyVersion, account: account, hasKey: hasKey)
    }
}
