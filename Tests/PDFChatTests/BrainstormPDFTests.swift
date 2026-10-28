import XCTest
import AppKit
import PDFKit
@testable import PDFChat

final class BrainstormPDFTests: XCTestCase {
  @MainActor private func image(_ size: NSSize) -> NSImage {
    let image = NSImage(size: size)
    image.lockFocus(); NSColor.white.setFill(); NSRect(origin: .zero, size: size).fill(); image.unlockFocus()
    return image
  }
  @MainActor func testPDFOpensAtFitWidthDespiteLegacyQuarterScale() throws {
    let image = image(NSSize(width: 600, height: 800))
    let page = try XCTUnwrap(PDFPage(image: image))
    let document = PDFDocument(); document.insert(page, at: 0)
    let store = PDFContextStore(); store.load(document: document, url: nil)
    let id = "test-" + UUID().uuidString
    UserDefaults.standard.set(0.25, forKey: "reading.zoom.\(id)")
    defer { UserDefaults.standard.removeObject(forKey: "reading.zoom.\(id)"); UserDefaults.standard.removeObject(forKey: "reading.page.\(id)") }
    let view = PDFView(frame: NSRect(x: 0, y: 0, width: 900, height: 600)); view.document = document
    view.minScaleFactor = 0.25; view.maxScaleFactor = 5
    let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = view
    // Intentionally never order the test window front: the user's app stays untouched.
    defer { window.close() }
    store.pdfView = view; store.setIdentity(id)
    XCTAssertEqual(view.scaleFactor, (view.bounds.width - 32) / page.bounds(for: .cropBox).width, accuracy: 0.02)
    XCTAssertGreaterThan(view.scaleFactor, 0.25)
    store.scale(0.5); let manual = view.scaleFactor
    view.setFrameSize(NSSize(width: 700, height: 600)); store.restorePositionIfReady()
    XCTAssertEqual(view.scaleFactor, manual, accuracy: 0.01)
    store.fitWidth(); view.setFrameSize(NSSize(width: 800, height: 600)); store.restorePositionIfReady()
    XCTAssertEqual(view.scaleFactor, (view.bounds.width - 32) / page.bounds(for: .cropBox).width, accuracy: 0.02)
  }
  @MainActor func testLoadingAnotherPDFResetsFitState() throws {
    let store = PDFContextStore()
    let first = PDFDocument(); first.insert(try XCTUnwrap(PDFPage(image: image(NSSize(width: 600, height: 800)))), at: 0)
    store.load(document: first, url: nil); store.setIdentity("first")
    let second = PDFDocument(); second.insert(try XCTUnwrap(PDFPage(image: image(NSSize(width: 300, height: 400)))), at: 0)
    store.load(document: second, url: nil)
    XCTAssertNil(store.identity); XCTAssertTrue(store.document === second)
  }
}
