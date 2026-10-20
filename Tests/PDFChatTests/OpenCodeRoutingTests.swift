import XCTest
@testable import PDFChat

final class OpenCodeRoutingTests: XCTestCase {
    @MainActor
    func testConversationRoutingIdentitySurvivesRestoreAndChangesForNewChat() throws {
        let model = ChatViewModel(credentials: { ("fixture", "") })
        let first = ChatMessage(role: "user", text: "first", images: [], streaming: false)
        model.restore(messages: [first])
        let original = model.routingSessionID
        model.messages.append(.init(role: "assistant", text: "answer", images: [], streaming: false))
        model.messages.append(.init(role: "user", text: "follow-up", images: [], streaming: false))
        XCTAssertEqual(model.routingSessionID, original)
        let restored = ChatViewModel(credentials: { ("fixture", "") })
        restored.restore(messages: model.messages)
        XCTAssertEqual(restored.routingSessionID, original)
        model.newConversation()
        XCTAssertNotEqual(model.routingSessionID, original)
        model.messages.append(.init(role: "user", text: "new", images: [], streaming: false))
        XCTAssertNotEqual(model.routingSessionID, original)
    }

    func testAllRequestPathsUseConversationIDOnlyOnOfficialHosts() throws {
        for base in ["https://opencode.ai/go/v1", "https://opencode.ai/inference/go/openai/v1", "https://api.opencode.ai/v1"] {
            var config = APIConfig.default; config.baseURL = base
            for path in ["chat/completions", "responses", "models"] {
                // A fresh client for each question still receives the same conversation ID.
                let client = OpenAIClient(config: config, apiKey: "fixture", conversationSessionID: "conversation-1")
                for _ in 0..<3 {
                    XCTAssertEqual(try client.request(path).value(forHTTPHeaderField: "x-opencode-session"), "conversation-1")
                }
            }
        }
        for base in ["https://api.example.com/v1", "https://opencode.ai.example.com/v1", "https://notopencode.ai/v1"] {
            var config = APIConfig.default; config.baseURL = base
            XCTAssertNil(try OpenAIClient(config: config, apiKey: "fixture").request("responses").value(forHTTPHeaderField: "x-opencode-session"))
        }
    }

    func testMissingSessionErrorDoesNotSuggestPDFIncompatibility() {
        let error = ChatError.server(400, "Request is missing x-opencode-session and cannot be routed efficiently.")
        XCTAssertTrue(error.localizedDescription.contains("session routing"))
        XCTAssertFalse(error.localizedDescription.contains("PDF or tools are not supported"))
    }

    func testConnectionAndModelListSendStableOpenCodeRoutingHeaders() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenCodeProbe.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        OpenCodeProbe.reset()
        var config = APIConfig.default
        config.baseURL = "https://opencode.ai/go/v1"
        let client = OpenAIClient(config: config, apiKey: "fixture", session: session)
        try await client.testConnection()
        _ = try await client.fetchModels()
        config.apiStyle = .responses
        try await OpenAIClient(config: config, apiKey: "fixture", session: session).testConnection()
        let requests = OpenCodeProbe.requests
        XCTAssertEqual(requests.count, 3)
        let firstID = try XCTUnwrap(requests.first?.value(forHTTPHeaderField: "x-opencode-session"))
        XCTAssertFalse(firstID.isEmpty)
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "x-opencode-session"), firstID)
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("PDFChat/") == true })
    }
}

private final class OpenCodeProbe: URLProtocol {
    private static let lock = NSLock()
    private static var captured: [URLRequest] = []
    static var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return captured }
    static func reset() { lock.lock(); defer { lock.unlock() }; captured = [] }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.captured.append(request); Self.lock.unlock()
        let missing = request.value(forHTTPHeaderField: "x-opencode-session")?.isEmpty != false
        let body = missing
            ? #"{"error":{"message":"Request is missing x-opencode-session and cannot be routed efficiently."}}"#
            : #"{"data":[],"choices":[]}"#
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: missing ? 400 : 200,
                                                             httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
