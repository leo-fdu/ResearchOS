import XCTest
@testable import PDFChat

final class TransportTests: XCTestCase {
    var server: Process!
    var baseURL = ""
    var temporary: URL!
    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("pdfchat-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let port = temporary.appendingPathComponent("port")
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        server = Process(); server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = [root.appendingPathComponent("Scripts/mock_api.py").path, port.path]
        try server.run()
        for _ in 0..<100 {
            if let number = try? String(contentsOf: port) { baseURL = "http://127.0.0.1:\(number)/v1"; return }
            Thread.sleep(forTimeInterval: 0.02)
        }
        throw NSError(domain: "mock did not start", code: 1)
    }
    override func tearDownWithError() throws {
        if server?.isRunning == true { server.terminate(); server.waitUntilExit() }
        try? FileManager.default.removeItem(at: temporary)
    }
    func testBothProtocolsExecuteToolsAndContinueStreaming() async throws {
        for style in APIStyle.allCases {
            var config = APIConfig.default
            config.baseURL = baseURL; config.apiStyle = style; config.model = style == .responses ? "tool-responses" : "tool-chat"
            let client = OpenAIClient(config: config, apiKey: "fixture")
            let recorder = Recorder()
            try await client.streamChat(system: "reader", messages: [.init(role: "user", text: "explain")], pdf: .init(filename: "test.pdf", base64: "JVBERi0="), tools: [], nativeWeb: false, execute: { call in
                XCTAssertEqual(call.name, "read_pdf_page")
                XCTAssertEqual(call.arguments, "{\"page\":1}")
                await recorder.called()
                return .init(text: "page content")
            }, onEvent: { await recorder.add($0) })
            let result = await recorder.snapshot()
            XCTAssertEqual(result.0, style == .responses ? "Responses tool success" : "Chat tool success")
            XCTAssertEqual(result.1, 1)
            XCTAssertGreaterThan(result.2, 0)
        }
    }
    func testUnsupportedPDFIsReportedWithoutFallback() async throws {
        var config = APIConfig.default; config.baseURL = baseURL; config.model = "reject-pdf"
        do {
            try await OpenAIClient(config: config, apiKey: "fixture").streamChat(system: "", messages: [.init(role: "user", text: "hi")], pdf: .init(filename: "test.pdf", base64: "JVBERi0="), tools: [], nativeWeb: false, execute: { _ in .init(text: "") }, onEvent: { _ in })
            XCTFail("Expected provider rejection")
        } catch { XCTAssertTrue(error.localizedDescription.contains("does not support file")) }
    }
    func testTruncatedConnectionDoesNotLookSuccessful() async throws {
        var config = APIConfig.default; config.baseURL = baseURL; config.model = "broken"
        do {
            try await OpenAIClient(config: config, apiKey: "fixture").streamChat(system: "", messages: [.init(role: "user", text: "hi")], pdf: nil, tools: [], nativeWeb: false, execute: { _ in .init(text: "") }, onEvent: { _ in })
            XCTFail("Expected incomplete stream")
        } catch { XCTAssertTrue(error.localizedDescription.contains("interrupted")) }
    }
    @MainActor
    func testCancelledRequestCannotCorruptNewConversation() async throws {
        let settings = AppSettings.shared
        let original = settings.config
        defer { settings.config = original }
        settings.config.baseURL = baseURL
        settings.config.apiStyle = .chatCompletions
        settings.config.model = "slow"
        let model = ChatViewModel(credentials: { ("fixture", "") })
        let context = PDFContextStore()
        model.inputText = "first"; model.send(contextStore: context)
        try await Task.sleep(nanoseconds: 180_000_000)
        model.newConversation()
        settings.config.model = "fast"
        model.inputText = "second"; model.send(contextStore: context)
        for _ in 0..<100 {
            if !model.isStreaming { break }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(model.messages.count, 2)
        XCTAssertEqual(model.messages.last?.text, "fresh answer")
        XCTAssertEqual(model.messages.last?.status, "complete")
        XCTAssertFalse(model.isStreaming)
    }
}
private actor Recorder {
    var text = "", calls = 0, tokens = 0
    func called() { calls += 1 }
    func add(_ event: ChatEvent) { switch event { case .text(let value): text += value; case .usage(let u): tokens += u.totalTokens; default: break } }
    func snapshot() -> (String, Int, Int) { (text, calls, tokens) }
}
