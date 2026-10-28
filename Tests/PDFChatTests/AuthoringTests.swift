import XCTest
import AppKit
import SwiftUI
@testable import PDFChat

final class AuthoringTests: XCTestCase {
  @MainActor func testResearchContextUsesRemovableTitleChips() {
    let model = WorkspaceModel()
    let idea = Row(raw: ["id": "idea-id", "kind": "idea", "title": "My idea"])
    model.objects = [idea]; model.selected = idea
    XCTAssertEqual(model.attached, [idea.id])
    model.attached.removeAll(); model.selected = idea
    XCTAssertTrue(model.attached.isEmpty)
    model.newChat(); XCTAssertEqual(model.attached, [idea.id])
    XCTAssertEqual(researchMessageText("Current research record ID: 0123456789abcdef0123456789abcdef\n\nMy question"), "My question")
    XCTAssertEqual(researchMessageText("My question with a hash 0123456789abcdef0123456789abcdef"), "My question with a hash 0123456789abcdef0123456789abcdef")
  }
  @MainActor func testJournalClipboardCopiesBitmapAndAcceptsImageFile() throws {
    let board = NSPasteboard.withUniqueName()
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { board.releaseGlobally(); try? FileManager.default.removeItem(at: dir) }
    XCTAssertTrue(try JournalClipboard.images(from: board, directory: dir).isEmpty)
    let png = try ExperimentFigureTests.chart()
    board.clearContents(); XCTAssertTrue(board.writeObjects([try XCTUnwrap(NSImage(data: png))]))
    let urls = try JournalClipboard.images(from: board, directory: dir)
    XCTAssertEqual(urls.count, 1)
    XCTAssertNotNil(NSImage(contentsOf: try XCTUnwrap(urls.first)))
    board.clearContents(); board.writeObjects(urls.map { $0 as NSURL })
    XCTAssertEqual(try JournalClipboard.images(from: board, directory: dir), urls)
  }
  func testGraphLayoutIsFiniteDeterministicAndKeepsAllNodes() {
    let ids = (0..<400).map(String.init), edges = (1..<80).map { ("0", String($0)) }
    let a = GraphLayout.positions(ids: ids, edges: edges), b = GraphLayout.positions(ids: ids, edges: edges)
    XCTAssertEqual(a, b); XCTAssertEqual(a.count, 400)
    XCTAssertTrue(a.values.allSatisfy { $0.x.isFinite && $0.y.isFinite })
    XCTAssertEqual(GraphLayout.positions(ids: [], edges: []), [:])
  }
  @MainActor func testAuthoringScreensRender() async throws {
    guard let path = ProcessInfo.processInfo.environment["RESEARCHOS_TEST_RENDER_DIR"] else { return }
    let model = WorkspaceModel(), owner = Row(raw: ["id": "p", "kind": "project", "title": "Protein–peptide affinity prediction"])
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    let chartPath = path + "/validation-loss.png"
    try ExperimentFigureTests.chart().write(to: URL(fileURLWithPath: chartPath))
    let entry = Row(raw: ["id": "e", "kind": "note", "title": "Matched-capacity baseline · seed 1", "body": "Validation correlation improved from 0.61 to 0.64. This is a single-seed observation, not evidence that the mechanism generalizes. Next: repeat matched controls with three seeds.", "created_at": "2026-10-25T01:00:00", "data": ["entry_type": "experiment_log", "owner_id": "p", "attachments": [["path": chartPath, "name": "Validation loss.png", "caption": "Illustrative test fixture: loss over epochs. Actual experiments should include units, seeds and uncertainty.", "mode": "copy"], ["path": "/tmp/results.csv", "name": "results.csv", "mode": "copy"]]]])
    try await snapshot(ScrollView { ExperimentJournal(model: model, owner: owner, fixture: [entry]).padding(24) }, size: NSSize(width: 800, height: 760), path: path + "/journal.png")
    let csvPath = path + "/model-comparison.csv"
    try "Model,Seed,RMSE,Pearson r,Comment\nBaseline,001,1.12,0.61,Reference\nContact pooling,001,1.03,0.64,Single seed only\nControl,002,1.15,0.60,Matched capacity\n".write(toFile: csvPath, atomically: true, encoding: .utf8)
    try await snapshot(ExperimentCSVPreview(path: csvPath).padding(24), size: NSSize(width: 900, height: 330), path: path + "/csv-table.png")
    try await snapshot(PaperNoteComposer(model: model, paper: Row(raw: ["id": "paper", "title": "Molecular representations for binding affinity"])), size: NSSize(width: 620, height: 270), path: path + "/paper-note.png")
    let types = ["project", "idea", "brainstorm", "paper", "note", "repo", "data"]
    let titles = ["Affinity prediction", "Contact-weighted pooling", "Compare competing hypotheses", "Representation learning", "Literature notes", "Model implementation", "Benchmark split"]
    let nodes = (0..<35).map { i in ["id": String(i), "kind": types[i % 7], "title": titles[i % 7] + " \(i / 7 + 1)", "uri": "researchos://object/\(i)"] }
    let edges = (1..<35).map { i in ["source": String(i / 7 * 7), "target": String(i), "relation": "supports"] }
    try await snapshot(ResearchGraph(model: model, fixture: ["nodes": nodes, "edges": edges]), size: NSSize(width: 1000, height: 760), path: path + "/graph.png")
  }
  @MainActor private func snapshot<V: View>(_ view: V, size: NSSize, path: String) async throws {
    let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).background(Color.white).environment(\.colorScheme, .light));host.sizingOptions = [];host.frame = NSRect(origin: .zero, size: size)
    let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false);window.isReleasedWhenClosed = false;window.contentView = host
    defer { window.close() }
    host.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds: 400_000_000)
    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds));host.cacheDisplay(in: host.bounds, to: bitmap)
    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]));try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true);try png.write(to: URL(fileURLWithPath: path));XCTAssertGreaterThan(png.count, 10000)
  }
}
