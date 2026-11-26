import Foundation

/// One model the Caimex gateway can serve to the agent, with what the gateway's list says about it.
public struct CaimexModel: Sendable, Equatable, Identifiable {
    /// The gateway id, sent unchanged: some contain `/` or `:`.
    public let id: String
    public let featured: Bool
    /// Whether the model can call tools, which the agent needs: `tools` in the entry's `capability_tags`.
    /// Nil when the gateway didn't say, so an older list without tags hides nothing.
    public let supportsTools: Bool?
    /// The context window in tokens.
    public let contextLength: Int?
    /// US dollars per million input and output tokens, as the gateway lists them.
    public let inputPricePerMillion: Decimal?
    public let outputPricePerMillion: Decimal?
    /// Where the model runs: an ISO 3166 country code such as `ZW`.
    public let hostingCountry: String?
    /// Whether the provider may train on requests. Nil when the gateway didn't say.
    public let mayTrain: Bool?

    public init(
        id: String,
        featured: Bool = false,
        supportsTools: Bool? = nil,
        contextLength: Int? = nil,
        inputPricePerMillion: Decimal? = nil,
        outputPricePerMillion: Decimal? = nil,
        hostingCountry: String? = nil,
        mayTrain: Bool? = nil
    ) {
        self.id = id
        self.featured = featured
        self.supportsTools = supportsTools
        self.contextLength = contextLength
        self.inputPricePerMillion = inputPricePerMillion
        self.outputPricePerMillion = outputPricePerMillion
        self.hostingCountry = hostingCountry
        self.mayTrain = mayTrain
    }

    /// Short facts for the settings caption, such as `Tool calling`, `1M context`,
    /// `$0.38 in, $0.80 out per 1M tokens`, `Hosted in Zimbabwe` and `Not used for training`.
    /// Anything the gateway didn't say is left out.
    public func details(locale: Locale = .current) -> [String] {
        var parts: [String] = []
        switch supportsTools {
        case true?: parts.append("Tool calling")
        case false?: parts.append("No tool calling")
        case nil: break
        }
        if let contextLength, contextLength > 0 {
            parts.append("\(Self.tokenCount(contextLength, locale: locale)) context")
        }
        if let price = priceLabel(locale: locale) {
            parts.append(price)
        }
        if let hostingCountry {
            parts.append("Hosted in \(locale.localizedString(forRegionCode: hostingCountry) ?? hostingCountry)")
        }
        if let mayTrain {
            parts.append(mayTrain ? "May be used for training" : "Not used for training")
        }
        return parts
    }

    /// `1M`, `128K` or `200K`: whichever of the decimal or binary unit gives a whole number (decimal
    /// first, so 128000 is `128K` and 131072 is `128K` too), else one decimal place.
    static func tokenCount(_ tokens: Int, locale: Locale) -> String {
        func short(_ number: Double) -> String {
            number.formatted(.number.precision(.fractionLength(0...1)).grouping(.never).locale(locale))
        }
        for (suffix, decimal, binary) in [("M", 1_000_000, 1_048_576), ("K", 1_000, 1_024)] where tokens >= decimal {
            if tokens % decimal == 0 { return "\(tokens / decimal)\(suffix)" }
            if tokens % binary == 0 { return "\(tokens / binary)\(suffix)" }
            let inBinary = Double(tokens) / Double(binary)
            if (inBinary * 10).rounded() == inBinary * 10 { return short(inBinary) + suffix }
            return short(Double(tokens) / Double(decimal)) + suffix
        }
        return "\(tokens)"
    }

    private func priceLabel(locale: Locale) -> String? {
        func dollars(_ amount: Decimal) -> String {
            "$" + amount.formatted(.number.precision(.fractionLength(2...4)).locale(locale))
        }
        switch (inputPricePerMillion, outputPricePerMillion) {
        case let (input?, output?):
            if input == 0, output == 0 { return "Free" }
            return "\(dollars(input)) in, \(dollars(output)) out per 1M tokens"
        case let (input?, nil):
            return "\(dollars(input)) in per 1M tokens"
        case let (nil, output?):
            return "\(dollars(output)) out per 1M tokens"
        case (nil, nil):
            return nil
        }
    }
}

/// The ids a Caimex model picker offers: the models that can call tools, which the agent needs, in the
/// gateway's order. A model the gateway didn't describe stays; the model the user already has is kept
/// first when the list no longer offers it, so the picker still shows it. Ids stay opaque and are never
/// trimmed or split.
public struct CaimexModelChoices: Sendable, Equatable {
    public let ids: [String]
    /// Chat models left out because the gateway says they can't call tools.
    public let withoutToolsCount: Int

    public init(models: [CaimexModel], current: String) {
        let usable = models.filter { $0.supportsTools != false }
        var ids = usable.map(\.id)
        if !current.isEmpty, !ids.contains(current) {
            ids.insert(current, at: 0)
        }
        self.ids = ids
        withoutToolsCount = models.count - usable.count
    }
}

/// Loads the Caimex model list. The gateway answers without a key, so the picker
/// can fill before one is saved.
public struct CaimexModelCatalogue: Sendable {
    /// Today's list is about 174 KB; refuse anything an order of magnitude larger.
    public static let maximumBodyBytes = 4 * 1024 * 1024
    public static let timeout: TimeInterval = 30

    public var session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public static var modelsURL: URL {
        LLMProviderConfiguration.caimexBaseURL.appending(path: "models")
    }

    /// Chat-capable, unlocked models, with their tags, prices, context and hosting: featured first, then by id.
    public func models(apiKey: String? = nil) async throws -> [CaimexModel] {
        var request = URLRequest(url: Self.modelsURL)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = Self.timeout

        // Transport errors and cancellation keep their own type; the view decides whether to show them.
        // The request can carry the Caimex key: never follow a redirect to another server.
        let redirects = EndpointRedirectGuard(for: Self.modelsURL)
        let (bytes, response) = try await session.bytes(for: request, delegate: redirects)
        try redirects.throwIfRefused()

        guard let http = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse("not an HTTP response")
        }
        guard http.statusCode == 200 else {
            let body = await Self.readAtMost(from: bytes, limit: 64_000)
            throw LLMError.fromHTTP(status: http.statusCode, body: body)
        }

        let body = try await Self.readBody(from: bytes, limit: Self.maximumBodyBytes, overflow: "The model list is too large to read.")
        guard let list = try? JSONDecoder().decode(ModelList.self, from: body) else {
            throw LLMError.invalidResponse("The model list could not be read.")
        }
        return list.data
            .compactMap(\.entry)
            .filter { entry in
                guard !entry.id.isEmpty, !entry.locked else { return false }
                // Known capabilities must include chat; unknown (absent or null) keeps the model.
                guard let capabilities = entry.capabilities else { return true }
                return capabilities.contains("chat")
            }
            .map { entry in
                CaimexModel(
                    id: entry.id,
                    featured: entry.featured,
                    supportsTools: entry.capabilityTags.map { tags in tags.contains { $0.lowercased() == "tools" } },
                    contextLength: entry.contextLength,
                    inputPricePerMillion: entry.pricing?.inputPerMillion,
                    outputPricePerMillion: entry.pricing?.outputPerMillion,
                    hostingCountry: entry.hostingCountry,
                    mayTrain: entry.mayTrain
                )
            }
            .sorted { lhs, rhs in
                guard lhs.featured == rhs.featured else { return lhs.featured }
                return lhs.id < rhs.id
            }
    }

    /// Reads at most `limit` bytes; a longer body is an error, never a partial list.
    private static func readBody(from bytes: URLSession.AsyncBytes, limit: Int, overflow: String) async throws -> Data {
        var body = Data()
        for try await byte in bytes {
            if body.count >= limit { throw LLMError.invalidResponse(overflow) }
            body.append(byte)
        }
        return body
    }

    /// Reads at most `limit` bytes and stops, so an oversized error page keeps its status.
    private static func readAtMost(from bytes: URLSession.AsyncBytes, limit: Int) async -> Data {
        var body = Data()
        do {
            for try await byte in bytes {
                body.append(byte)
                if body.count >= limit { break }
            }
        } catch {
            // A broken error body still leaves the status to report.
        }
        return body
    }

    private struct ModelList: Decodable {
        let data: [LossyEntry]
    }

    /// One array element. An entry that cannot be read is skipped instead of failing the whole list.
    private struct LossyEntry: Decodable {
        let entry: Entry?

        init(from decoder: any Decoder) throws {
            entry = try? Entry(from: decoder)
        }
    }

    /// Only the fields the picker needs; unknown keys and `null` values are fine. A `featured` or `locked`
    /// that is not a Bool counts as false; absent or null capabilities mean "unknown", not "no chat".
    /// The descriptive fields (tags, context, prices, hosting) are read loosely: one that is absent, null or
    /// of an unexpected type is simply unknown, and never hides the model.
    private struct Entry: Decodable {
        let id: String
        let featured: Bool
        let locked: Bool
        let capabilities: [String]?
        let capabilityTags: [String]?
        let contextLength: Int?
        let pricing: Pricing?
        let hostingCountry: String?
        let mayTrain: Bool?

        private enum CodingKeys: String, CodingKey {
            case id, featured, locked, capabilities, pricing
            case capabilityTags = "capability_tags"
            case contextLength = "context_length"
            case topProvider = "top_provider"
            case hostingCountry = "hosting_country"
            case mayTrain = "may_train"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            featured = (try? container.decode(Bool.self, forKey: .featured)) ?? false
            locked = (try? container.decode(Bool.self, forKey: .locked)) ?? false
            if container.contains(.capabilities) {
                let isNull = (try? container.decodeNil(forKey: .capabilities)) ?? false
                // Absent or null is unknown; a present value that is not a string array cannot support chat.
                capabilities = isNull ? nil : ((try? container.decode([String].self, forKey: .capabilities)) ?? [])
            } else {
                capabilities = nil
            }
            capabilityTags = try? container.decode([String].self, forKey: .capabilityTags)
            let ownContext = (try? container.decode(Int.self, forKey: .contextLength)).flatMap { $0 > 0 ? $0 : nil }
            contextLength = ownContext ?? (try? container.decode(TopProvider.self, forKey: .topProvider))?.contextLength
            pricing = try? container.decode(Pricing.self, forKey: .pricing)
            let country = (try? container.decode(String.self, forKey: .hostingCountry))?
                .trimmingCharacters(in: .whitespaces).uppercased()
            // A region code is two letters (or three digits); anything else is not one to name.
            hostingCountry = country.flatMap { code in
                code.count >= 2 && code.count <= 3 && code.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } ? code : nil
            }
            mayTrain = try? container.decode(Bool.self, forKey: .mayTrain)
        }
    }

    private struct TopProvider: Decodable {
        let contextLength: Int?

        private enum CodingKeys: String, CodingKey {
            case contextLength = "context_length"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            contextLength = (try? container.decode(Int.self, forKey: .contextLength)).flatMap { $0 > 0 ? $0 : nil }
        }
    }

    /// Prices per million tokens. The gateway sends them as strings (`"0.38"`); numbers are read too.
    private struct Pricing: Decodable {
        let inputPerMillion: Decimal?
        let outputPerMillion: Decimal?

        private enum CodingKeys: String, CodingKey {
            case inputPerMillion = "input_per_1m"
            case outputPerMillion = "output_per_1m"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            inputPerMillion = Self.amount(container, .inputPerMillion)
            outputPerMillion = Self.amount(container, .outputPerMillion)
        }

        private static func amount(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Decimal? {
            let value: Decimal?
            if let text = try? container.decode(String.self, forKey: key) {
                value = Decimal(string: text.trimmingCharacters(in: .whitespaces), locale: Locale(identifier: "en_US_POSIX"))
            } else if let number = try? container.decode(Double.self, forKey: key), number.isFinite {
                value = Decimal(string: String(number), locale: Locale(identifier: "en_US_POSIX"))
            } else {
                value = nil
            }
            // A negative or unreadable price is not one to show.
            guard let value, !value.isNaN, value >= 0 else { return nil }
            return value
        }
    }
}
