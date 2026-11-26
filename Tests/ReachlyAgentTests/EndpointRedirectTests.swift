import Foundation
import Synchronization
import Testing
@testable import ReachlyAgent

/// Plays several servers at once: each URL gets a scripted answer, and every request is recorded with the
/// key headers it carried. A redirect proposes the same request at the new URL, headers included, which is
/// what a session sends there if the redirect is followed.
private final class RedirectStubProtocol: URLProtocol {
    enum Answer: Sendable {
        case redirect(status: Int, to: String)
        case status(Int, body: String)
    }

    struct Seen: Sendable, Equatable {
        var url: String
        var authorization: String?
        var apiKey: String?
    }

    private static let state = Mutex<(answers: [String: Answer], seen: [Seen])>(([:], []))

    static func install(_ answers: [String: Answer]) {
        state.withLock { $0 = (answers, []) }
    }

    static var seen: [Seen] { state.withLock { $0.seen } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let answer = Self.state.withLock { state in
            state.seen.append(Seen(
                url: url.absoluteString,
                authorization: request.value(forHTTPHeaderField: "Authorization"),
                apiKey: request.value(forHTTPHeaderField: "x-api-key")))
            return state.answers[url.absoluteString]
        }
        switch answer {
        case .redirect(let status, let target):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Location": target])!
            var next = request
            next.url = URL(string: target)
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        case .status(let status, let body):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case nil:
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
        }
    }

    override func stopLoading() {}
}

@Suite("Endpoint redirects", .serialized)
struct EndpointRedirectTests {
    private static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RedirectStubProtocol.self]
        return URLSession(configuration: configuration)
    }

    private let request = LLMRequest(system: "s", messages: [.user("hello")], tools: [])
    private let collector = "https://collector.example.net/steal"

    /// The error the stream ended with, or nil when it finished.
    private func failure(of provider: some LLMProvider) async -> Error? {
        do {
            for try await _ in provider.stream(request) {}
            return nil
        } catch {
            return error
        }
    }

    private func openAI(_ baseURL: String) -> OpenAICompatibleProvider {
        OpenAICompatibleProvider(baseURL: URL(string: baseURL)!, apiKey: "test-endpoint-key", model: "m", session: Self.session())
    }

    @Test func anEndpointRedirectToAnotherServerIsRefused() async throws {
        RedirectStubProtocol.install([
            "https://gateway.example.com/v1/chat/completions": .redirect(status: 307, to: collector),
            collector: .status(200, body: ""),
        ])
        let error = await failure(of: openAI("https://gateway.example.com/v1"))

        let refused = try #require(error as? EndpointRedirectError)
        #expect(refused == EndpointRedirectError(target: "https://collector.example.net"))
        #expect(refused.localizedDescription == "The endpoint redirected to https://collector.example.net; Reachly doesn't follow redirects to another server.")
        // Only the endpoint was asked, with its key; the other server never saw a request, let alone the key.
        #expect(RedirectStubProtocol.seen == [.init(url: "https://gateway.example.com/v1/chat/completions", authorization: "Bearer test-endpoint-key")])
        #expect(!RedirectStubProtocol.seen.contains { $0.url.contains("collector") })
    }

    @Test func anAnthropicRedirectToAnotherServerIsRefused() async throws {
        RedirectStubProtocol.install([
            "https://api.anthropic.com/v1/messages": .redirect(status: 307, to: "https://collector.example.net:8443/v1/messages"),
            "https://collector.example.net:8443/v1/messages": .status(200, body: ""),
        ])
        let provider = AnthropicProvider(apiKey: "test-anthropic-key", model: "claude-opus-5-5", session: Self.session())
        let error = await failure(of: provider)

        #expect(error as? EndpointRedirectError == EndpointRedirectError(target: "https://collector.example.net:8443"))
        #expect(RedirectStubProtocol.seen.map(\.url) == ["https://api.anthropic.com/v1/messages"])
        #expect(RedirectStubProtocol.seen.allSatisfy { $0.url.hasPrefix("https://api.anthropic.com/") })
    }

    @Test func everyRedirectStatusIsRefused() async {
        for status in [301, 302, 303, 308] {
            RedirectStubProtocol.install([
                "https://gateway.example.com/v1/chat/completions": .redirect(status: status, to: collector),
                collector: .status(200, body: ""),
            ])
            let error = await failure(of: openAI("https://gateway.example.com/v1"))
            #expect(error is EndpointRedirectError, "\(status)")
            #expect(RedirectStubProtocol.seen.count == 1, "\(status)")
        }
    }

    @Test func aRedirectWithinTheEndpointIsFollowed() async {
        RedirectStubProtocol.install([
            "https://gateway.example.com/v1/chat/completions": .redirect(status: 307, to: "https://gateway.example.com/v2/chat/completions"),
            "https://gateway.example.com/v2/chat/completions": .status(401, body: #"{"error":{"type":"auth","message":"bad key"}}"#),
        ])
        let error = await failure(of: openAI("https://gateway.example.com/v1"))

        // The second answer is the endpoint's own, reported as usual.
        #expect(error as? LLMError == .api(type: "auth", message: "bad key"))
        #expect(RedirectStubProtocol.seen.map(\.url) == [
            "https://gateway.example.com/v1/chat/completions",
            "https://gateway.example.com/v2/chat/completions",
        ])
    }

    @Test func aChainThatLeavesTheEndpointIsRefusedAtTheHopThatLeaves() async {
        RedirectStubProtocol.install([
            "https://gateway.example.com/v1/chat/completions": .redirect(status: 307, to: "https://gateway.example.com/v2/chat/completions"),
            "https://gateway.example.com/v2/chat/completions": .redirect(status: 307, to: collector),
            collector: .status(200, body: ""),
        ])
        let error = await failure(of: openAI("https://gateway.example.com/v1"))
        #expect(error as? EndpointRedirectError == EndpointRedirectError(target: "https://collector.example.net"))
        #expect(RedirectStubProtocol.seen.count == 2)
    }

    @Test func whichRedirectsMayBeFollowed() {
        let https = EndpointOrigin(baseURL: "https://gateway.example.com/v1")
        let http = EndpointOrigin(baseURL: "http://gpu.lan/v1")
        let local = EndpointOrigin(baseURL: "http://127.0.0.1:1234/v1")
        func url(_ string: String) -> URL? { URL(string: string) }

        #expect(EndpointRedirectGuard.mayFollow(from: https, to: url("https://gateway.example.com/v2/chat")))
        #expect(EndpointRedirectGuard.mayFollow(from: https, to: url("https://GATEWAY.example.com:443/x")))
        // http to https on the same host: the same server, now over TLS.
        #expect(EndpointRedirectGuard.mayFollow(from: http, to: url("https://gpu.lan/v1/chat/completions")))
        // Never the other way, never another port, host or scheme.
        #expect(!EndpointRedirectGuard.mayFollow(from: https, to: url("http://gateway.example.com/v1")))
        #expect(!EndpointRedirectGuard.mayFollow(from: https, to: url("https://gateway.example.com:8443/v1")))
        #expect(!EndpointRedirectGuard.mayFollow(from: https, to: url("https://example.com/v1")))
        #expect(!EndpointRedirectGuard.mayFollow(from: https, to: url("https://gateway.example.com.evil.example/v1")))
        #expect(!EndpointRedirectGuard.mayFollow(from: local, to: url("https://127.0.0.1/v1")))
        #expect(!EndpointRedirectGuard.mayFollow(from: local, to: url("http://localhost:1234/v1")))
        #expect(!EndpointRedirectGuard.mayFollow(from: https, to: url("file:///etc/hosts")))
        #expect(!EndpointRedirectGuard.mayFollow(from: https, to: nil))
        #expect(!EndpointRedirectGuard.mayFollow(from: nil, to: url("https://gateway.example.com/v1")))
    }
}
