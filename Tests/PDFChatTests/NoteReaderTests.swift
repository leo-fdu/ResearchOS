import XCTest
import AppKit
import SwiftUI
import WebKit
@testable import PDFChat

final class NoteReaderTests: XCTestCase {
    @MainActor
    func testLongNoteHasIndependentScrollableViewport() async throws {
        let text = (0..<1800).map { "Paragraph \($0). A long note must remain readable." }.joined(separator: "\n\n")
        let host = NSHostingView(rootView: ResearchMarkdownReader(text: text, onLink: { _ in }))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 420), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        func findWeb(_ view: NSView) -> WKWebView? {
            if let web = view as? WKWebView { return web }
            return view.subviews.compactMap(findWeb).first
        }
        var loaded: WKWebView?
        for _ in 0..<100 {
            if let web = findWeb(host), (try? await web.evaluateJavaScript("document.querySelector('.content')?.textContent.includes('Paragraph 1799')")) as? Bool == true {
                loaded = web; break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let web = try XCTUnwrap(loaded)
        let initial = try await web.evaluateJavaScript("window.scrollY") as? Double ?? -1
        XCTAssertEqual(initial, 0, accuracy: 1, "Notes must open at the top, not follow chat autoscroll")
        let overflow = try await web.evaluateJavaScript("getComputedStyle(document.documentElement).overflowY") as? String
        XCTAssertEqual(overflow, "scroll")
        _ = try await web.evaluateJavaScript("window.scrollTo(0,document.documentElement.scrollHeight)")
        try await Task.sleep(nanoseconds: 100_000_000)
        let bottom = try await web.evaluateJavaScript("window.scrollY + window.innerHeight >= document.documentElement.scrollHeight - 2") as? Bool
        XCTAssertEqual(bottom, true)
        XCTAssertLessThan(web.frame.height, 500, "Web view remains a viewport, not an expanded document inside another scroll view")
    }
}
