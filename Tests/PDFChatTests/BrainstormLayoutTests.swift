import XCTest
import AppKit
import SwiftUI
@testable import PDFChat

final class BrainstormLayoutTests: XCTestCase {
  @MainActor func testBrainstormScreensRenderWithoutLaunchingAppOrService() async throws {
    guard let path = ProcessInfo.processInfo.environment["RESEARCHOS_TEST_RENDER_DIR"] else { return }
    let model = BrainstormModel()
    model.catalogs = ["codex": [Row(raw: ["id": "gpt-6-astra", "name": "GPT-6 Astra", "provider": "OpenAI", "levels": ["low", "high"]])], "pi": [Row(raw: ["id": "fixture", "name": "Example model", "provider": "Example provider"])]]
    try await snapshot(BrainstormComposer(model: model, projectID: "", isPresented: .constant(true)), size: NSSize(width: 760, height: 720), path: path + "/composer.png")
    let members: [[String: Any]] = [["id": "a", "name": "Astra", "runtime": "codex", "model": "gpt-6-astra"], ["id": "b", "name": "Pi member", "runtime": "pi", "model": "Example"]]
    let workspace = WorkspaceModel()
    model.rooms = [Row(raw: ["id": "fixture", "topic": "Does the proposed representation improve generalization?", "status": "waiting_user", "updated_at": "2026-10-24T08:00:00", "members": members])]
    try await snapshot(BrainstormPane(workspace: workspace, initialModel: model), size: NSSize(width: 1000, height: 800), path: path + "/history.png")
    model.selectedID = "fixture"
    model.rooms = [Row(raw: ["id": "fixture", "topic": "Does the proposed representation improve generalization?"])]
    model.detail = Row(raw: ["id": "fixture", "topic": "Does the proposed representation improve generalization?", "status": "paused", "phase": "discussion", "round": 1, "calls": 4, "config": ["max_calls": 12], "members": members, "guidance": [["id": "g", "text": "Keep the dataset split identical and test a matched-capacity baseline.", "target": "", "delivery": ["a": "included_in_turn"]]]])
    model.entries = [Row(raw: ["id": "e", "member_id": "a", "phase": "proposal", "round": 0, "status": "completed", "payload": ["response": ["summary": "Compare the proposed representation against a matched-capacity baseline. A better mean score alone does not distinguish representation quality from increased capacity.", "weakness": "This is a test plan, not a measured result."]]])]
    model.entries.append(Row(raw: ["id": "u", "member_id": "user", "phase": "user", "status": "completed", "payload": ["text": "@Astra 请区分容量增加与表征改善。大家都请给出一个可以区分两者的实验。"]]))
    try await snapshot(BrainstormPane(workspace: workspace, initialModel: model), size: NSSize(width: 1000, height: 800), path: path + "/discussion.png")
  }
  @MainActor private func snapshot<V: View>(_ view: V, size: NSSize, path: String) async throws {
    let host = NSHostingView(rootView: view.background(Color.white).environment(\.colorScheme, .light)); host.frame = NSRect(origin: .zero, size: size)
    let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host
    defer { window.close() }
    // No orderFront or activation: visual QA is rendered offscreen.
    host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 200_000_000)
    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
    try png.write(to: URL(fileURLWithPath: path))
    XCTAssertGreaterThan(png.count, 10000)
  }
}
