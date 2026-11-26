import Foundation
import Synchronization
import Testing
@testable import ReachlyAgent

/// Plays a local server for the probe: a redirect, a body in chunks, or a status, and records every request.
private final class ProbeStubProtocol: URLProtocol {
    enum Answer: Sendable {
        case redirect(to: String)
        case body(chunks: [Data], status: Int)
    }

    private static let state = Mutex<(answer: Answer, seen: [URL])>((.body(chunks: [], status: 200), []))

    static func install(_ answer: Answer) {
        state.withLock { $0 = (answer, []) }
    }

    static var requested: [URL] { state.withLock { $0.seen } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let answer = Self.state.withLock { state in
            state.seen.append(url)
            return state.answer
        }
        switch answer {
        case .redirect(let target):
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target])!
            var next = request
            next.url = URL(string: target)
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        case .body(let chunks, let status):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for chunk in chunks { client?.urlProtocol(self, didLoad: chunk) }
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

@Suite("Local model server probe", .serialized)
struct LocalModelServerProbeTests {
    private func probe() -> LocalModelServerProbe {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProbeStubProtocol.self]
        return LocalModelServerProbe(session: URLSession(configuration: configuration))
    }

    private let models = Data(#"{"object":"list","data":[{"id":"qwen3-8b"},{"id":"gemma-3-12b"}]}"#.utf8)

    @Test func aModelListMeansRunning() async {
        ProbeStubProtocol.install(.body(chunks: [models], status: 200))
        #expect(await probe().state(of: .lmStudio) == .running(models: ["qwen3-8b", "gemma-3-12b"]))
        #expect(ProbeStubProtocol.requested == [LocalModelServer.lmStudio.modelsURL])
    }

    @Test func aRedirectIsNotFollowed() async {
        ProbeStubProtocol.install(.redirect(to: "https://example.com/v1/models"))
        #expect(await probe().state(of: .ollama) == .notRunning)
        // Only the loopback URL was asked; the redirect target never was.
        #expect(ProbeStubProtocol.requested == [LocalModelServer.ollama.modelsURL])
    }

    @Test func theDelegateRefusesEveryRedirect() async {
        let task = URLSession.shared.dataTask(with: LocalModelServer.lmStudio.modelsURL)
        let response = HTTPURLResponse(url: LocalModelServer.lmStudio.modelsURL, statusCode: 301, httpVersion: nil, headerFields: nil)!
        let next = await LocalModelServerProbe.NoRedirects.shared.urlSession(
            URLSession.shared, task: task, willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: URL(string: "http://127.0.0.1:1234/elsewhere")!))
        #expect(next == nil)
    }

    @Test func aBodyOverTheCapStopsWhileStreaming() async {
        // A list that would parse if it were read whole, padded past 2 MB and sent in pieces.
        let chunk = Data(repeating: 0x20, count: 256 * 1024)
        let chunks = [Data(#"{"data":[{"id":"x"}],"pad":""#.utf8)] + Array(repeating: chunk, count: 9) + [Data(#""}"#.utf8)]
        ProbeStubProtocol.install(.body(chunks: chunks, status: 200))
        #expect(await probe().state(of: .lmStudio) == .notRunning)
    }

    @Test func aBodyJustUnderTheCapIsRead() async {
        let head = Data(#"{"data":[{"id":"x"}],"pad":""#.utf8)
        let tail = Data(#""}"#.utf8)
        let pad = Data(repeating: 0x20, count: LocalModelServerProbe.maximumBodyBytes - head.count - tail.count)
        ProbeStubProtocol.install(.body(chunks: [head, pad, tail], status: 200))
        #expect(await probe().state(of: .lmStudio) == .running(models: ["x"]))
    }

    @Test func anAuthenticationAnswerMeansAKeyIsNeeded() async {
        ProbeStubProtocol.install(.body(chunks: [Data("{}".utf8)], status: 401))
        #expect(await probe().state(of: .lmStudio) == .requiresKey)
    }
}
