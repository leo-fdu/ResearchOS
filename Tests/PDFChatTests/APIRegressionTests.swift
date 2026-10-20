import XCTest
import PDFKit
@testable import PDFChat

final class APIRegressionTests: XCTestCase {
    func testPDFIsSentAsAFileInBothProtocols() throws {
        let pdf = PDFInput(filename: "paper.pdf", base64: Data("%PDF-test".utf8).base64EncodedString())
        for style in APIStyle.allCases {
            let body = OpenAIClient.initialInput(style: style, system: "reader", messages: [.init(role: "user", text: "explain")], pdf: pdf)
            let parts = body.last?["content"] as? [[String: Any]]
            XCTAssertEqual(parts?.first?["type"] as? String, style == .responses ? "input_file" : "file")
            let file = style == .responses ? parts?.first : parts?.first?["file"] as? [String: Any]
            XCTAssertEqual(file?["file_data"] as? String, "data:application/pdf;base64," + pdf.base64)
            let textOnly = OpenAIClient.initialInput(style: style, system: "extracted", messages: [.init(role: "user", text: "explain")], pdf: nil)
            let json = String(data: try JSONSerialization.data(withJSONObject: textOnly), encoding: .utf8)!
            XCTAssertFalse(json.contains("file_data"))
        }
    }
    func testFragmentedParallelToolCallsAndUsage() throws {
        var round = StreamRound()
        _ = try round.accept(#"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"a","function":{"name":"read_pdf_page","arguments":"{\"pa"}},{"index":1,"id":"b","function":{"name":"search_pdf","arguments":"{\"query\":\"test\"}"}}]}}]}"#, style: .chatCompletions)
        _ = try round.accept(#"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"ge\":2}"}}]},"finish_reason":"tool_calls"}]}"#, style: .chatCompletions)
        XCTAssertEqual(round.calls[0], .init(id: "a", name: "read_pdf_page", arguments: #"{"page":2}"#))
        XCTAssertEqual(round.calls[1]?.name, "search_pdf")
        XCTAssertTrue(round.finished)
        let events = try round.accept(#"{"choices":[],"usage":{"prompt_tokens":100,"completion_tokens":12}}"#, style: .chatCompletions)
        if case .usage(let usage) = events.first { XCTAssertEqual(usage.totalTokens, 112) } else { XCTFail("Missing usage") }
    }
    func testSSEFramesAndIncompleteResponse() throws {
        var decoder = SSEDecoder()
        XCTAssertNil(decoder.consume(": keepalive"))
        XCTAssertNil(decoder.consume("data: {\"a\":"))
        XCTAssertNil(decoder.consume("data: 1}"))
        XCTAssertEqual(decoder.consume(""), "{\"a\":\n1}")
        var round = StreamRound()
        _ = try round.accept(#"{"type":"response.output_text.delta","delta":"Hello"}"#, style: .responses)
        XCTAssertFalse(round.finished)
        XCTAssertThrowsError(try round.accept(#"{"type":"response.incomplete","response":{}}"#, style: .responses))
    }
    func testResponsesPreservesToolOutputAndReasoningItems() throws {
        var round = StreamRound()
        _ = try round.accept(#"{"type":"response.completed","response":{"output":[{"type":"reasoning","id":"rs_1","summary":[]},{"type":"function_call","call_id":"call_1","name":"read_pdf_page","arguments":"{\"page\":1}"}],"usage":{"input_tokens":12,"output_tokens":3}}}"#, style: .responses)
        XCTAssertEqual(round.responseOutput.count, 2)
        XCTAssertEqual(round.calls[1]?.id, "call_1")
    }
    @MainActor
    func testSelectionIsExplicitAndStable() {
        let store = PDFContextStore()
        XCTAssertEqual(store.mode, .pdf)
        store.selectedText = "A quoted paragraph"; store.selectedPage = 4
        XCTAssertNil(store.quote)
        store.pinSelection()
        store.selectedText = ""; store.currentPage = 8
        XCTAssertEqual(store.quote, .init(text: "A quoted paragraph", page: 4))
    }
    func testToolPermissionsAndWebAddressValidation() async throws {
        let tools = ReadingTools(reader: nil, webEnabled: false, searchKey: "", visionEnabled: false)
        XCTAssertTrue(tools.definitions(style: .responses).isEmpty)
        let result = try await tools.execute(.init(id: "bad", name: "shell", arguments: "{}"))
        XCTAssertTrue(result.text.contains("unknown tool"))
        for url in ["file:///etc/passwd", "http://127.0.0.1", "http://192.168.1.1", "https://user:pass@example.com", "http://localhost"] {
            XCTAssertFalse(ReadingTools.isPublicWebURL(URL(string: url)!))
        }
        XCTAssertTrue(ReadingTools.isPublicWebURL(URL(string: "https://example.com/paper")!))
    }
    func testOldHistoryAndConfigDecode() throws {
        let config = #"{"baseURL":"https://example.com/v1","model":"test","models":["test"],"pricing":{},"maxContexts":{}}"#
        let decoded = try JSONDecoder().decode(APIConfig.self, from: Data(config.utf8))
        XCTAssertEqual(decoded.resolvedStyle, .chatCompletions)
        XCTAssertNil(decoded.toolsEnabled)
        let old = #"{"id":"00000000-0000-0000-0000-000000000001","role":"user","text":"hello","imageDataURLs":[]}"#
        XCTAssertEqual(try JSONDecoder().decode(StoredChatMessage.self, from: Data(old.utf8)).text, "hello")
    }
}

final class PDFReaderTests: XCTestCase {
    func fixtureURL() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/reading.pdf")
    }
    func testFileBytesArePreservedAndTextModeIsExplicit() async throws {
        let url = fixtureURL()
        let reader = PDFDocumentReader(url: url, data: nil)
        let file = try await reader.prepare(mode: .pdf)
        XCTAssertEqual(file.pdf?.base64, try Data(contentsOf: url).base64EncodedString())
        XCTAssertTrue(file.text.isEmpty)
        let text = try await reader.prepare(mode: .text)
        XCTAssertNil(text.pdf)
        XCTAssertTrue(text.text.contains("[Page 3]"))
        XCTAssertTrue(text.text.contains("Select this paragraph"))
        let results = try await reader.search("synthetic chart")
        XCTAssertTrue(results.contains("pdfchat://page/1"))
        let screenshot = try await reader.pageImage(2)
        XCTAssertTrue(screenshot.hasPrefix("data:image/png;base64,"))
        let tool = ReadingTools(reader: reader, webEnabled: false, searchKey: "", visionEnabled: true)
        let page = try await tool.execute(.init(id: "page", name: "read_pdf_page", arguments: "{\"page\":2}"))
        XCTAssertTrue(page.text.contains("Page 2 / 3"))
        let invalid = try await tool.execute(.init(id: "page", name: "read_pdf_page", arguments: "{\"page\":99}"))
        XCTAssertTrue(invalid.text.contains("out of range"))
    }
    func testHistoryIdentitySurvivesRename() async throws {
        let data = try Data(contentsOf: fixtureURL())
        let a = PDFDocumentReader(url: fixtureURL(), data: data)
        let b = PDFDocumentReader(url: URL(fileURLWithPath: "/tmp/renamed.pdf"), data: data)
        let original = try await a.identity(), renamed = try await b.identity()
        XCTAssertEqual(original, renamed)
    }
}
