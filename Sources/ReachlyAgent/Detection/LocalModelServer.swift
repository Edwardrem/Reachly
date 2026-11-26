import Foundation

/// A model server that runs on this Mac and speaks the OpenAI API on a fixed loopback port.
public enum LocalModelServer: String, Sendable, CaseIterable, Hashable {
    case lmStudio
    case ollama

    public var displayName: String {
        switch self {
        case .lmStudio: "LM Studio"
        case .ollama: "Ollama"
        }
    }

    public var port: Int {
        switch self {
        case .lmStudio: 1234
        case .ollama: 11434
        }
    }

    /// The base URL Reachly saves for the endpoint: loopback only.
    public var baseURL: String { "http://127.0.0.1:\(port)/v1" }

    public var modelsURL: URL { URL(string: "\(baseURL)/models")! }

    /// How to start the server, for a row that found the app but no server.
    public var startInstructions: String {
        switch self {
        case .lmStudio: "In LM Studio, open Developer and click Start Server, or run `lms server start` in Terminal. Then click Check Again."
        case .ollama: "Open the Ollama app, or run `ollama serve` in Terminal. Then click Check Again."
        }
    }

    /// True when `baseURL` points at this server on this Mac (127.0.0.1, localhost or ::1, on its port).
    public func matches(baseURL: String) -> Bool {
        guard let components = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = components.host?.lowercased() else { return false }
        return ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host) && components.port == port
    }
}

/// What a loopback probe of a local model server found.
public enum LocalServerState: Sendable, Equatable {
    /// Nothing answered on the port, or it did not answer like an OpenAI server.
    case notRunning
    /// The server answered and lists these model ids (possibly none).
    case running(models: [String])
    /// The server answered but wants an API key before it lists models.
    case requiresKey
}

/// Reads an OpenAI-style `GET /v1/models` response.
public enum OpenAIModelList {
    /// The ids in `{"data":[{"id":"…"}]}`, in the server's order without duplicates or empty ids. Nil when the
    /// body is not that shape; an empty array when the server lists no models.
    public static func ids(from data: Data) -> [String]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = object["data"] as? [Any] else { return nil }
        var seen = Set<String>()
        var ids = [String]()
        for case let entry as [String: Any] in entries {
            guard let id = entry["id"] as? String, !id.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            if seen.insert(id).inserted { ids.append(id) }
        }
        return ids
    }

    /// The ids a chat picker offers: embedding models are left out, unless nothing else is listed.
    public static func chatModels(_ ids: [String]) -> [String] {
        let chat = ids.filter { !$0.lowercased().contains("embed") }
        return chat.isEmpty ? ids : chat
    }
}

/// Asks a local model server for its models over loopback, with a short timeout. A server that is not running
/// is the common case, not an error.
public struct LocalModelServerProbe: Sendable {
    public static let timeout: TimeInterval = 1.5
    public static let maximumBodyBytes = 2 * 1024 * 1024

    private let session: URLSession

    /// One session for every probe: loopback only, never through a proxy, no cookies, no cache.
    private static let loopbackSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 2
        configuration.connectionProxyDictionary = [:]
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    public init(session: URLSession? = nil) {
        self.session = session ?? Self.loopbackSession
    }

    public func state(of server: LocalModelServer) async -> LocalServerState {
        var request = URLRequest(url: server.modelsURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.timeout)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // A redirect could lead the probe off loopback; it is refused, and the 3xx itself counts as "not running".
        guard let (bytes, response) = try? await session.bytes(for: request, delegate: NoRedirects.shared),
              let http = response as? HTTPURLResponse else { return .notRunning }
        guard http.statusCode == 200 else { return Self.state(status: http.statusCode, body: Data()) }
        // The cap holds while the body streams in, so an endless body never fills memory.
        var body = Data()
        do {
            for try await byte in bytes {
                guard body.count < Self.maximumBodyBytes else { return .notRunning }
                body.append(byte)
            }
        } catch {
            return .notRunning
        }
        return Self.state(status: http.statusCode, body: body)
    }

    /// Refuses every redirect, so the request stays on the loopback URL it was made for.
    final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        static let shared = NoRedirects()

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
            nil
        }
    }

    /// The probe's verdict for one HTTP answer.
    public static func state(status: Int, body: Data) -> LocalServerState {
        switch status {
        case 200:
            guard body.count <= maximumBodyBytes, let ids = OpenAIModelList.ids(from: body) else { return .notRunning }
            return .running(models: ids)
        case 401, 403:
            return .requiresKey
        default:
            return .notRunning
        }
    }
}
