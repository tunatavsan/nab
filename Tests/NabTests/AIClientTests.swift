import Foundation
import NabCore
import Synchronization
import Testing

@testable import NabAI

@Suite("AI client")
struct AIClientTests {
    private let turns = [
        ChatMessage(role: .user, text: "q1"), ChatMessage(role: .assistant, text: "a1"),
        ChatMessage(role: .user, text: "q2"),
    ]

    @Test func commandLinePromptCarriesTheHistory() {
        let prompt = AIClient.flatten(context: "<ctx/>", turns: turns)
        #expect(prompt.hasPrefix("<ctx/>"))
        #expect(prompt.contains("<conversation_so_far>\nUser: q1\n\nAssistant: a1\n</conversation_so_far>"))
        #expect(prompt.hasSuffix("User: q2"))
        #expect(AIClient.flatten(context: "<ctx/>", turns: [turns[0]]) == "<ctx/>\n\nq1")
    }

    @Test func httpProvidersGetTheContextInTheFirstMessage() {
        let anthropic = AIClient.anthropicMessages(context: "<ctx/>", turns: turns)
        let blocks = anthropic[0]["content"] as? [[String: Any]]
        #expect(blocks?.first?["text"] as? String == "<ctx/>")
        #expect((blocks?.first?["cache_control"] as? [String: String])?["type"] == "ephemeral")
        #expect(anthropic.map { $0["role"] as? String } == ["user", "assistant", "user"])

        let plain = AIClient.plainMessages(context: "<ctx/>", turns: turns)
        #expect(plain[0]["content"] as? String == "<ctx/>\n\nq1")
        #expect(plain[2]["content"] as? String == "q2")
    }

    @Test func serverSentEventsJoinDataLinesUntilABlankLine() {
        var parser = ServerSentEvents()
        let lines = [": keep-alive", "event: delta", "data: {\"a\":", "data: 1}\r", "", "", "data:[DONE]", ""]
        #expect(lines.compactMap { parser.feed($0) } == ["{\"a\":\n1}", "[DONE]"])
    }

    @Test func serverAddressIsCheckedNotTrusted() throws {
        var settings = AISettings()
        settings.kind = .ollama
        settings.model = "llama"
        #expect(AIClient(settings: settings, apiKey: nil).problem == nil)
        #expect(
            try AIClient(settings: settings, apiKey: nil).endpoint("/models").absoluteString
                == "http://localhost:11434/v1/models")
        for address in ["http://a b", "localhost:11434", "file:///etc", "https://"] {
            settings.baseURL = address
            #expect(AIClient(settings: settings, apiKey: nil).problem != nil, "\(address)")
        }
    }

    // MARK: Streaming over HTTP, against a stubbed server

    @Test func anthropicStreamsTextAndCachesTheContext() async throws {
        let server = StubServer(
            body: """
                event: message_start
                data: {"type":"message_start","message":{"id":"m"}}

                event: content_block_delta
                data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}

                event: ping
                data: {"type":"ping"}

                event: content_block_delta
                data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" world"}}

                event: message_stop
                data: {"type":"message_stop"}

                """)
        var settings = AISettings()
        settings.kind = .anthropic
        settings.baseURL = server.baseURL
        settings.model = "claude-opus-5-5"
        let client = AIClient(settings: settings, apiKey: "key", session: server.session)

        #expect(try await collect(client.reply(context: "<ctx/>", turns: [turns[0]])) == "Hello world")
        let request = try #require(server.requests.first)
        #expect(request.path == "/v1/messages")
        #expect(request.headers["x-api-key"] == "key")
        #expect(request.headers["anthropic-version"] == "2023-06-01")
        #expect(request.headers["anthropic-beta"] == "server-side-fallback-2026-07-01")
        let body = try #require(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        #expect(body["stream"] as? Bool == true)
        #expect(body["fallbacks"] as? String == "default")
        #expect(body["system"] as? String == settings.resolvedSystemPrompt)
    }

    @Test func anthropicRefusalIsReportedNotSwallowed() async throws {
        let server = StubServer(
            body: """
                data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"I"}}

                data: {"type":"message_delta","delta":{"stop_reason":"refusal"}}

                """)
        var settings = AISettings()
        settings.kind = .anthropic
        settings.baseURL = server.baseURL
        let client = AIClient(settings: settings, apiKey: "key", session: server.session)
        await #expect(throws: NabError.self) { try await collect(client.reply(context: "c", turns: [turns[0]])) }
    }

    @Test func openAICompatibleServersStreamUntilDone() async throws {
        let server = StubServer(
            body: """
                data: {"choices":[{"delta":{"role":"assistant"}}]}

                data: {"choices":[{"delta":{"content":"Hi"}}]}

                data: {"choices":[{"delta":{"content":" there"}}]}

                data: [DONE]

                data: {"choices":[{"delta":{"content":" after the end"}}]}

                """)
        var settings = AISettings()
        settings.kind = .custom
        settings.baseURL = server.baseURL
        settings.model = "local-model"
        let client = AIClient(settings: settings, apiKey: "key", session: server.session)

        #expect(try await collect(client.reply(context: "<ctx/>", turns: turns)) == "Hi there")
        let request = try #require(server.requests.first)
        #expect(request.path == "/v1/chat/completions")
        #expect(request.headers["Authorization"] == "Bearer key")
        let body = try #require(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages.map { $0["role"] } == ["system", "user", "assistant", "user"])
        #expect(body["model"] as? String == "local-model")
    }

    @Test func httpErrorsCarryTheServerMessage() async throws {
        let server = StubServer(status: 401, body: #"{"error":{"message":"invalid x-api-key"}}"#)
        var settings = AISettings()
        settings.kind = .anthropic
        settings.baseURL = server.baseURL
        let client = AIClient(settings: settings, apiKey: "wrong", session: server.session)
        do {
            _ = try await collect(client.reply(context: "c", turns: [turns[0]]))
            Issue.record("expected an error")
        } catch {
            #expect(error.localizedDescription == "HTTP 401: invalid x-api-key")
        }
    }

    @Test func modelsAreListedSorted() async throws {
        let server = StubServer(body: #"{"data":[{"id":"b-model"},{"id":"a-model"}]}"#)
        var settings = AISettings()
        settings.kind = .lmStudio
        settings.baseURL = server.baseURL
        let models = try await AIClient(settings: settings, apiKey: nil, session: server.session).models()
        #expect(models == ["a-model", "b-model"])
        #expect(server.requests.first?.path == "/v1/models")
    }
}

func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> String {
    var text = ""
    for try await chunk in stream { text += chunk }
    return text
}

/// A server that answers every request on its own host with one canned response and records what it was sent.
/// Each instance has a unique host, so tests running in parallel never see each other's requests.
struct StubServer {
    struct Request: Sendable {
        let path: String
        let headers: [String: String]
        let body: Data
    }

    let host: String
    let session: URLSession
    var baseURL: String { "https://\(host)/v1" }
    var requests: [Request] { StubProtocol.requests.withLock { $0[host] ?? [] } }

    init(status: Int = 200, body: String) {
        let host = "\(UUID().uuidString.lowercased()).test"
        self.host = host
        StubProtocol.replies.withLock { $0[host] = StubProtocol.Reply(status: status, body: Data(body.utf8)) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        session = URLSession(configuration: configuration)
    }
}

/// Serves `StubServer` replies. URLSession creates and drives each instance on its own queue, and an instance
/// keeps no state of its own; the shared tables are behind a `Mutex`.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        let status: Int
        let body: Data
    }

    static let replies = Mutex<[String: Reply]>([:])
    static let requests = Mutex<[String: [StubServer.Request]]>([:])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host(),
            let reply = Self.replies.withLock({ $0[host] }),
            let response = HTTPURLResponse(
                url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: nil)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let recorded = StubServer.Request(
            path: url.path(), headers: request.allHTTPHeaderFields ?? [:], body: request.httpBody ?? bodyStream())
        Self.requests.withLock { $0[host, default: []].append(recorded) }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// URLSession hands an uploaded body to a protocol as a stream.
    private func bodyStream() -> Data {
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
