import XCTest
import WebKit
import AppKit
@testable import PDFChat

final class RenderingRegressionTests: XCTestCase {
    @MainActor
    func testUserBubbleHasNoRoleAndCopyAppearsOnFocus() async throws {
        let (web, renderer, window, model) = try await readyWeb()
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(web)
        model.messages = [.init(role: "user", text: "A research question", images: [], streaming: false)]
        model.revision += 1; renderer.requestUpdate()
        try await Task.sleep(nanoseconds: 400_000_000)
        let role = try await web.evaluateJavaScript("getComputedStyle(document.querySelector('.user .role')).display") as? String
        XCTAssertEqual(role, "none")
        let copyText = try await web.evaluateJavaScript("document.querySelector('.copy').textContent") as? String
        XCTAssertEqual(copyText, "")
        let label = try await web.evaluateJavaScript("document.querySelector('.copy').getAttribute('aria-label')") as? String
        XCTAssertEqual(label, "Copy message")
        // Background WebKit test windows may suspend CSS animation frames.
        _ = try await web.evaluateJavaScript("document.querySelector('.copy').style.transition='none'; document.querySelector('.copy').focus()")
        try await Task.sleep(nanoseconds: 200_000_000)
        let focused = try await web.evaluateJavaScript("document.activeElement === document.querySelector('.copy')") as? Bool
        XCTAssertEqual(focused, true)
        let opacity = try await web.evaluateJavaScript("getComputedStyle(document.querySelector('.copy')).opacity") as? String
        XCTAssertEqual(opacity, "1")
    }
    @MainActor
    func testDraftUndoDoesNotRegisterDocumentEdits() {
        _ = NSApplication.shared
        let window = DraftTestWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 140),
                                     styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let input = SendableTextView(frame: window.contentView!.bounds)
        input.allowsUndo = true
        window.contentView = input
        window.makeFirstResponder(input)
        input.undoManager?.beginUndoGrouping()
        input.insertText("draft", replacementRange: NSRange(location: 0, length: 0))
        input.undoManager?.endUndoGrouping()
        XCTAssertEqual(input.string, "draft")
        XCTAssertFalse(window.documentUndoManager.canUndo, "Typing must not dirty the PDF's undo history")
        XCTAssertTrue(input.undoManager?.canUndo == true)
        let undo = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                   timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                   characters: "z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6)!
        XCTAssertTrue(input.performKeyEquivalent(with: undo))
        XCTAssertEqual(input.string, "")
        let redo = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift],
                                   timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                   characters: "Z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6)!
        XCTAssertTrue(input.performKeyEquivalent(with: redo))
        XCTAssertEqual(input.string, "draft")
        XCTAssertFalse(window.documentUndoManager.canUndo)
    }
    @MainActor
    func readyWeb() async throws -> (WKWebView, TranscriptView.Coordinator, NSWindow, ChatViewModel) {
        _ = NSApplication.shared
        let config = WKWebViewConfiguration()
        let coordinator = TranscriptView.Coordinator()
        config.userContentController.add(coordinator, name: "ready")
        config.userContentController.add(coordinator, name: "action")
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 420, height: 500), configuration: config)
        let window = NSWindow(contentRect: web.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = web
        let model = ChatViewModel(credentials: { ("test", "") })
        coordinator.webView = web; coordinator.model = model
        web.loadFileURL(TranscriptView.webDirectory.appendingPathComponent("index.html"), allowingReadAccessTo: TranscriptView.webDirectory)
        for _ in 0..<100 {
            if coordinator.ready { return (web, coordinator, window, model) }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Offline transcript did not load")
        return (web, coordinator, window, model)
    }
    @MainActor
    func testLatestStreamWinsAndRenderingIsOffline() async throws {
        let (web, renderer, window, model) = try await readyWeb()
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        model.messages = [.init(role: "assistant", text: "first", images: [], streaming: true)]
        for i in 0..<60 {
            model.messages[0].text = "chunk \(i)"
            model.revision += 1; renderer.requestUpdate()
        }
        model.messages[0].text = "Latest **complete** answer. Formula: $x^2$ [第 2 页](pdfchat://page/2)"
        model.messages[0].streaming = false
        model.revision += 1; renderer.requestUpdate()
        try await Task.sleep(nanoseconds: 400_000_000)
        let text = try await web.evaluateJavaScript("document.querySelector('.content').textContent") as? String
        XCTAssertTrue(text?.hasPrefix("Latest complete answer") == true)
        let math = try await web.evaluateJavaScript("document.querySelectorAll('.katex').length") as? Int
        XCTAssertEqual(math, 1)
        let href = try await web.evaluateJavaScript("document.querySelector('.content a').getAttribute('href')") as? String
        XCTAssertEqual(href, "pdfchat://page/2")
        let scripts = try await web.evaluateJavaScript("Array.from(document.scripts).every(s=>!s.src || s.src.startsWith('file:'))") as? Bool
        XCTAssertEqual(scripts, true)
        // Stale, out-of-order payloads are ignored even across the native/JS boundary.
        _ = try await web.evaluateJavaScript("applyUpdate({revision:1,reset:false,order:[],updates:[]})")
        let result1 = try await web.evaluateJavaScript("document.querySelectorAll('.message').length") as? Int
        XCTAssertEqual(result1, 1)
    }
    @MainActor
    func testScrollPositionAndSelectionSurviveStreamingAndResize() async throws {
        let (web, renderer, window, model) = try await readyWeb()
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        model.messages = (0..<30).map { .init(role: "assistant", text: "Message \($0)\n\n" + String(repeating: "Readable paragraph. ", count: 20), images: [], streaming: false) }
        model.revision += 1; renderer.requestUpdate()
        try await Task.sleep(nanoseconds: 400_000_000)
        _ = try await web.evaluateJavaScript("following=false; window.scrollTo(0,200)")
        try await Task.sleep(nanoseconds: 100_000_000)
        model.messages[29].text += " streamed tail"
        model.revision += 1; renderer.requestUpdate()
        try await Task.sleep(nanoseconds: 200_000_000)
        let scroll = try await web.evaluateJavaScript("window.scrollY") as? Double ?? -1
        XCTAssertEqual(scroll, 200, accuracy: 2, "Streaming must not pull a reader to the bottom")
        _ = try await web.evaluateJavaScript("const range=document.createRange();range.selectNodeContents(document.querySelector('.content'));const selection=window.getSelection();selection.removeAllRanges();selection.addRange(range)")
        let selected = try await web.evaluateJavaScript("window.getSelection().toString()") as? String
        model.messages[0].text += " appended while selected"
        model.revision += 1; renderer.requestUpdate()
        try await Task.sleep(nanoseconds: 100_000_000)
        let result2 = try await web.evaluateJavaScript("window.getSelection().toString()") as? String
        XCTAssertEqual(result2, selected)
        window.setContentSize(NSSize(width: 650, height: 500))
        try await Task.sleep(nanoseconds: 100_000_000)
        let result3 = try await web.evaluateJavaScript("document.querySelectorAll('.message').length") as? Int
        XCTAssertEqual(result3, 30)
    }
    @MainActor
    func testUntrustedHTMLIsSanitized() async throws {
        let (web, renderer, window, model) = try await readyWeb()
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        model.messages = [.init(role: "assistant", text: "<script>window.pwned=true</script><img src=x onerror='window.pwned=true'><a href='javascript:alert(1)'>bad</a>Safe", images: [], streaming: false)]
        model.revision += 1; renderer.requestUpdate()
        try await Task.sleep(nanoseconds: 200_000_000)
        let result4 = try await web.evaluateJavaScript("Boolean(window.pwned)") as? Bool
        XCTAssertEqual(result4, false)
        let result5 = try await web.evaluateJavaScript("document.querySelectorAll('.content script,.content img,[href^=\"javascript:\"]').length") as? Int
        XCTAssertEqual(result5, 0)
    }
}

private final class DraftTestWindow: NSWindow {
    let documentUndoManager = UndoManager()
    override var undoManager: UndoManager? { documentUndoManager }
}
