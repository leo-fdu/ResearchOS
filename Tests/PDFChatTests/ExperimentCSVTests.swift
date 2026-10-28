import XCTest
@testable import PDFChat

final class ExperimentCSVTests: XCTestCase {
  func testQuotedCommasEscapedQuotesMultilineAndCRLF() throws {
    let csv = try ExperimentCSV.parse("\u{feff}model,description,score\r\nA,\"two, items and \"\"quotes\"\"\",0.81\r\nB,\"line one\r\nline two\",\r\n")
    XCTAssertEqual(csv.rows, [["model", "description", "score"], ["A", "two, items and \"quotes\"", "0.81"], ["B", "line one\r\nline two", ""]])
    XCTAssertFalse(csv.limited)
  }
  func testNoHeaderRaggedRowsAndTrailingEmptyCell() throws {
    let csv = try ExperimentCSV.parse("001,1e-8\n002,,NA")
    XCTAssertEqual(csv.columns, 3)
    XCTAssertEqual(csv.values(firstRow: false).count, 2)
    XCTAssertEqual(csv.headers(firstRow: false), ["Column 1", "Column 2", "Column 3"])
    XCTAssertEqual(csv.rows[1], ["002", "", "NA"])
    XCTAssertTrue(csv.markdown(firstRow: false).contains("| 001 | 1e-8 |  |"))
  }
  func testMalformedInputIsReportedInsteadOfFabricatingCells() {
    for text in ["a,b\n\"unterminated", "a,abc\"def", "a,\"b\"oops"] { XCTAssertThrowsError(try ExperimentCSV.parse(text)) }
    XCTAssertThrowsError(try ExperimentCSV.parse(""))
  }
  func testBoundsAndPartialRecordAtReadLimit() throws {
    let csv = try ExperimentCSV.parse("a,b,c\nlong-value,2,3\n4,5,6\n7,8,9", maxRows: 2, maxColumns: 2, maxCell: 4)
    XCTAssertEqual(csv.rows, [["a", "b"], ["long…", "2"]]); XCTAssertTrue(csv.limited)
    let partial = try ExperimentCSV.parse("a,b\n1,2\n3,\"part", byteLimited: true)
    XCTAssertEqual(partial.rows, [["a", "b"], ["1", "2"]]); XCTAssertTrue(partial.limited)
  }
  func testMarkdownPreservesLiteralCellsAndEscapesMarkup() throws {
    let csv = try ExperimentCSV.parse("name,value\n\"a|b\",\"<script> [x](url) *bold*\nnext\"")
    let markdown = csv.markdown(firstRow: true)
    XCTAssertTrue(markdown.contains("a&#124;b")); XCTAssertTrue(markdown.contains("&lt;script&gt;"))
    XCTAssertTrue(markdown.contains("&#91;x&#93;(url) &#42;bold&#42;<br>next"))
    XCTAssertEqual(markdown.split(separator: "\n").count, 3)
  }
  func testFileEncodingAndLargeFileBound() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let tsv = root.appendingPathComponent("results.tsv")
    try XCTUnwrap("模型\t得分\n模型A\t0.81".data(using: .utf16)).write(to: tsv)
    XCTAssertEqual(try ExperimentCSV.load(tsv.path).rows[1], ["模型A", "0.81"])
    let csv = root.appendingPathComponent("large.csv")
    try ("name,value\nA,1\n\"" + String(repeating: "中", count: 800_000)).write(to: csv, atomically: true, encoding: .utf8)
    let value = try ExperimentCSV.load(csv.path)
    XCTAssertEqual(value.rows, [["name", "value"], ["A", "1"]]); XCTAssertTrue(value.limited)
    let invalid = root.appendingPathComponent("invalid.csv"); try Data([0x81, 0x82, 0x83]).write(to: invalid)
    XCTAssertThrowsError(try ExperimentCSV.load(invalid.path))
  }
}
