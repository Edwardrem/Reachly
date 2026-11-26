import Foundation

/// Where an endpoint lives: scheme, host and port, with the default port filled in. An OpenAI-compatible
/// endpoint's key is tied to the origin it was saved for and is sent nowhere else.
public struct EndpointOrigin: Sendable, Hashable, CustomStringConvertible {
    public let scheme: String
    public let host: String
    public let port: Int

    /// The origin of a base URL such as `https://api.openai.com/v1`. Nil unless it is http or https with a host.
    public init?(baseURL: String) {
        guard let components = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var host = components.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        self.scheme = scheme
        self.host = host
        self.port = components.port ?? (scheme == "https" ? 443 : 80)
    }

    /// `scheme://host:port`, always with the port: the form that is stored and compared.
    public var canonical: String { "\(scheme)://\(hostInURL):\(port)" }

    /// `scheme://host`, with the port only when it is not the scheme's default: the form shown to people.
    public var description: String {
        let isDefault = (scheme == "https" && port == 443) || (scheme == "http" && port == 80)
        return isDefault ? "\(scheme)://\(hostInURL)" : canonical
    }

    private var hostInURL: String { host.contains(":") ? "[\(host)]" : host }
}

/// Which saved key may go to which endpoint.
public enum EndpointKeyPolicy {
    /// Anthropic and Caimex keys only ever go to their fixed hosts. An OpenAI-compatible key goes only to the
    /// origin it was saved for; with no known origin, or a base URL that is not a valid endpoint, it is not sent.
    public static func mayUseKey(kind: LLMProviderConfiguration.Kind, savedOrigin: EndpointOrigin?, baseURL: String) -> Bool {
        guard kind.bindsKeyToEndpoint else { return true }
        guard let savedOrigin, let current = EndpointOrigin(baseURL: baseURL) else { return false }
        return savedOrigin == current
    }

    /// What the API key section and the rows say when a saved key is not sent to the current endpoint.
    public static func mismatchMessage(savedOrigin: EndpointOrigin?) -> String {
        guard let savedOrigin else {
            return "The saved key isn't tied to an endpoint; enter a key for this endpoint."
        }
        return "The saved key was for \(savedOrigin); enter a key for this endpoint."
    }
}

/// The origin each kind's key was saved for, in UserDefaults beside the key previews. An origin is not a secret.
///
/// A key saved before origins were recorded has none. For the OpenAI-compatible kind it is treated as saved for
/// the base URL configured when this version first ran, recorded once by `recordUpgradeOrigin(baseURL:)`, so an
/// endpoint that worked before the upgrade keeps working.
public struct APIKeyOriginStore {
    public static let defaultsKeyPrefix = "agent.keyOrigin."
    /// The upgrade-time origin: a canonical origin, or an empty string when the base URL was not a valid endpoint.
    public static let upgradeDefaultKey = "agent.keyOrigin.upgradeDefault"

    public static func defaultsKey(for kind: LLMProviderConfiguration.Kind) -> String {
        defaultsKeyPrefix + kind.rawValue
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Records the upgrade-time origin the first time this version runs; later calls change nothing.
    public func recordUpgradeOrigin(baseURL: String) {
        guard defaults.object(forKey: Self.upgradeDefaultKey) == nil else { return }
        defaults.set(EndpointOrigin(baseURL: baseURL)?.canonical ?? "", forKey: Self.upgradeDefaultKey)
    }

    /// The origin the kind's key was saved for. Only the OpenAI-compatible kind falls back to the upgrade default.
    public func origin(for kind: LLMProviderConfiguration.Kind) -> EndpointOrigin? {
        if let stored = defaults.string(forKey: Self.defaultsKey(for: kind)) {
            return EndpointOrigin(baseURL: stored)
        }
        guard kind.bindsKeyToEndpoint, let upgrade = defaults.string(forKey: Self.upgradeDefaultKey) else { return nil }
        return EndpointOrigin(baseURL: upgrade)
    }

    /// Called once the Keychain write for `kind` has succeeded, with the origin the key was saved for.
    public func set(_ origin: EndpointOrigin?, for kind: LLMProviderConfiguration.Kind) {
        if let origin {
            defaults.set(origin.canonical, forKey: Self.defaultsKey(for: kind))
        } else {
            defaults.removeObject(forKey: Self.defaultsKey(for: kind))
        }
    }

    /// The key was deleted. A later key gets its own origin when it is saved.
    public func forget(_ kind: LLMProviderConfiguration.Kind) {
        defaults.removeObject(forKey: Self.defaultsKey(for: kind))
    }

    /// The migration moved a key from one kind's account to another's; its recorded origin goes with it.
    func move(from source: LLMProviderConfiguration.Kind, to destination: LLMProviderConfiguration.Kind) {
        if let stored = defaults.string(forKey: Self.defaultsKey(for: source)) {
            defaults.set(stored, forKey: Self.defaultsKey(for: destination))
        } else {
            defaults.removeObject(forKey: Self.defaultsKey(for: destination))
        }
        defaults.removeObject(forKey: Self.defaultsKey(for: source))
    }
}
