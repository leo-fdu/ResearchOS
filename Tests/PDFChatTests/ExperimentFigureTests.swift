import XCTest
import AppKit
import PDFKit
@testable import PDFChat

final class ExperimentFigureTests: XCTestCase {
  func testImagePreviewIsDownsampledAndSurvivesMissingOriginal() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let original = folder.appendingPathComponent("plot.PNG"), copy = folder.appendingPathComponent("saved.PNG")
    try Self.chart().write(to: original); try FileManager.default.copyItem(at: original, to: copy)
    try FileManager.default.removeItem(at: original)
    let thumbnail = try XCTUnwrap(ExperimentFigure.thumbnail(copy.path, maxPixels: 320))
    XCTAssertEqual(thumbnail.size.width, 320); XCTAssertEqual(thumbnail.size.height, 200)
    XCTAssertNil(ExperimentFigure.thumbnail(original.path))
  }
  func testPDFPreviewAndUnreadableInputs() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let pdf = PDFDocument(), image = try XCTUnwrap(NSImage(data: Self.chart()))
    pdf.insert(try XCTUnwrap(PDFPage(image: image)), at: 0)
    pdf.insert(try XCTUnwrap(PDFPage(image: image)), at: 1)
    let path = folder.appendingPathComponent("figures.pdf"); XCTAssertTrue(pdf.write(to: path))
    let thumbnail = try XCTUnwrap(ExperimentFigure.thumbnail(path.path, maxPixels: 400))
    let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(thumbnail.tiffRepresentation)))
    var bluePixels = 0
    for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
      for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
        if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.blueComponent > color.redComponent + 0.2 { bluePixels += 1 }
      }
    }
    XCTAssertGreaterThan(bluePixels, 20, "PDF preview must render the chart, not a blank page")
    let corrupt = folder.appendingPathComponent("broken.png"); try Data("invalid".utf8).write(to: corrupt)
    XCTAssertNil(ExperimentFigure.thumbnail(corrupt.path))
    XCTAssertNil(ExperimentFigure.thumbnail(folder.path))
    XCTAssertFalse(ExperimentFigure.supports("results.csv"))
  }
  static func chart() throws -> Data {
    let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1280, pixelsHigh: 800, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
    NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 1280, height: 800).fill()
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 30), .foregroundColor: NSColor.black]
    ("Validation loss · illustrative test fixture" as NSString).draw(at: NSPoint(x: 100, y: 720), withAttributes: attrs)
    NSColor.gray.setStroke(); let axes = NSBezierPath(); axes.move(to: NSPoint(x: 100, y: 650)); axes.line(to: NSPoint(x: 100, y: 100)); axes.line(to: NSPoint(x: 1180, y: 100)); axes.lineWidth = 2; axes.stroke()
    NSColor.systemBlue.setStroke(); let line = NSBezierPath(); line.move(to: NSPoint(x: 110, y: 620))
    for i in 1...50 { line.line(to: NSPoint(x: 110 + Double(i) * 21, y: 180 + 440 * exp(-Double(i) / 12))) }
    line.lineWidth = 5; line.stroke()
    ("Epoch" as NSString).draw(at: NSPoint(x: 600, y: 45), withAttributes: attrs)
    return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
  }
}
