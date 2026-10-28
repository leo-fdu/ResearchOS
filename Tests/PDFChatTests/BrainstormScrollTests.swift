import XCTest
import AppKit
import SwiftUI
@testable import PDFChat

final class BrainstormScrollTests: XCTestCase {
  @MainActor func testExpandedDiscussionKeepsScrollPosition() async throws {
    let model = BrainstormModel()
    model.selectedID = "fixture"
    model.detail = Row(raw: ["id": "fixture", "topic": "Scroll fixture", "status": "completed", "members": [["id": "a", "model": "Example"]]])
    model.entries = (0..<18).map { n in Row(raw: ["id": "e\(n)", "member_id": "a", "phase": "discussion", "status": "completed", "payload": ["response": ["text": "## Reply \(n)\n\n" + Array(repeating: "A long paragraph about evidence and controlled experiments. ", count: 80).joined()]]]) }
    let host = NSHostingView(rootView: BrainstormPane(workspace: WorkspaceModel(), initialModel: model, initiallyExpanded: Set(model.entries.map(\.id))))
    host.frame = NSRect(x: 0, y: 0, width: 1000, height: 800)
    let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host
    defer { window.close() }
    window.orderBack(nil)
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    try await Task.sleep(nanoseconds: 2_000_000_000)
    let scroll = try XCTUnwrap(descendants(host).compactMap { $0 as? NSScrollView }.max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) })
    XCTAssertGreaterThan(scroll.documentView?.frame.height ?? 0, 3000)
    // Traverse off-screen expanded messages; wait for WebKit height callbacks,
    // then simulate the same replacement payload delivered by the polling loop.
    for target in [CGFloat(1400), 5400, 9400, 5400, 1400] {
      let extent = scroll.documentView!.frame.height
      let destination = min(target, max(0, extent - scroll.contentView.bounds.height - 20))
      scroll.contentView.scroll(to: NSPoint(x: 0, y: destination)); scroll.reflectScrolledClipView(scroll.contentView)
      let requested = scroll.contentView.bounds.minY
      model.detail = Row(raw: model.detail!.raw)
      let rows = model.entries; model.entries = rows.map { Row(raw: $0.raw) }
      try await Task.sleep(nanoseconds: 700_000_000)
      XCTAssertEqual(scroll.documentView!.frame.height, extent, accuracy: 8, "Unchanged expanded messages changed document geometry while scrolling")
      XCTAssertEqual(scroll.contentView.bounds.minY, requested, accuracy: 8, "Reading position jumped after scrolling to \(target)")
    }
  }
}
