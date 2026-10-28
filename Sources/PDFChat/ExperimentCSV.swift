import AppKit
import SwiftUI

struct ExperimentCSV: Sendable {
  let rows: [[String]]
  let limited: Bool
  var columns: Int { rows.map(\.count).max() ?? 0 }
  static func supports(_ path: String) -> Bool {
    ["csv", "tsv"].contains(URL(fileURLWithPath: path).pathExtension.lowercased())
  }
  enum Failure: LocalizedError {
    case encoding, malformed, empty
    var errorDescription: String? {
      switch self {
      case .encoding: return "Save the table as UTF-8 or UTF-16 to preview it."
      case .malformed: return "The CSV contains unmatched quotes or invalid quoted fields."
      case .empty: return "No complete table rows to preview."
      }
    }
  }
  static func load(_ path: String) throws -> Self {
    let url = URL(fileURLWithPath: path)
    guard (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { throw Failure.empty }
    let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
    let limit = 2 * 1024 * 1024
    let bytes = try handle.read(upToCount: limit + 1) ?? Data()
    let cut = bytes.count > limit
    var data = Data(bytes.prefix(limit))
    let utf16 = data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff])
    var text = String(data: data, encoding: utf16 ? .utf16 : .utf8)
    // A bounded read may split a Unicode scalar. Do not replace bytes or corrupt cell values.
    if cut && text == nil {
      for _ in 0..<3 {
        data.removeLast(); text = String(data: data, encoding: utf16 ? .utf16 : .utf8)
        if text != nil { break }
      }
    }
    guard let text else { throw Failure.encoding }
    return try parse(text, separator: url.pathExtension.lowercased() == "tsv" ? "\t" : ",", byteLimited: cut)
  }
  static func parse(_ text: String, separator: Unicode.Scalar = ",", byteLimited: Bool = false,
                    maxRows: Int = 201, maxColumns: Int = 30, maxCell: Int = 1000) throws -> Self {
    let chars = Array(text.unicodeScalars.drop(while: { $0 == "\u{feff}" }))
    var rows: [[String]] = [], row: [String] = [], cell = ""
    var quoted = false, closed = false, started = false, limited = byteLimited, column = 0, cellCount = 0, i = 0
    func append(_ c: Unicode.Scalar) {
      if cellCount < maxCell && column < maxColumns { cell.unicodeScalars.append(c) }
      else { limited = true }
      cellCount += 1
    }
    func finishCell() {
      if column < maxColumns { row.append(cell + (cellCount > maxCell ? "…" : "")) } else { limited = true }
      column += 1; cell = ""; cellCount = 0; closed = false
    }
    func finishRow() {
      finishCell(); rows.append(row); row = []; column = 0; started = false
    }
    while i < chars.count {
      if rows.count >= maxRows { limited = true; break }
      let c = chars[i]
      if quoted {
        if c == "\"" {
          if i + 1 < chars.count && chars[i + 1] == "\"" { append("\""); i += 1 }
          else { quoted = false; closed = true }
        } else { append(c) }
      } else if c == separator {
        finishCell(); started = true
      } else if c == "\r" || c == "\n" {
        finishRow()
        if c == "\r" && i + 1 < chars.count && chars[i + 1] == "\n" { i += 1 }
      } else if c == "\"" {
        guard !closed && cellCount == 0 else { throw Failure.malformed }
        quoted = true; started = true
      } else {
        if closed { if c != " " && c != "\t" { throw Failure.malformed } }
        else { append(c); started = true }
      }
      i += 1
    }
    if !byteLimited && rows.count < maxRows {
      guard !quoted else { throw Failure.malformed }
      if started || column > 0 { finishRow() }
    }
    guard !rows.isEmpty else { throw Failure.empty }
    return Self(rows: rows, limited: limited)
  }
  func headers(firstRow: Bool) -> [String] {
    (0..<columns).map { index in
      firstRow && index < rows[0].count ? rows[0][index] : "Column \(index + 1)"
    }
  }
  func values(firstRow: Bool) -> [[String]] { firstRow ? Array(rows.dropFirst()) : rows }
  func markdown(firstRow: Bool) -> String {
    func escape(_ value: String) -> String {
      value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\\", with: "&#92;")
        .replacingOccurrences(of: "|", with: "&#124;").replacingOccurrences(of: "*", with: "&#42;")
        .replacingOccurrences(of: "_", with: "&#95;").replacingOccurrences(of: "`", with: "&#96;")
        .replacingOccurrences(of: "[", with: "&#91;").replacingOccurrences(of: "]", with: "&#93;")
        .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").replacingOccurrences(of: "\n", with: "<br>")
    }
    func line(_ cells: [String]) -> String { "| " + (0..<columns).map { escape($0 < cells.count ? cells[$0] : "") }.joined(separator: " | ") + " |" }
    return ([line(headers(firstRow: firstRow)), "| " + Array(repeating: "---", count: columns).joined(separator: " | ") + " |"] + values(firstRow: firstRow).map(line)).joined(separator: "\n")
  }
}

struct ExperimentCSVPreview: View {
  let path: String
  @State private var table: ExperimentCSV?
  @State private var error = ""
  @State private var expanded = false
  @State private var firstRow = true
  @State private var copied = false
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let table {
        HStack {
          Label("Table preview", systemImage: "tablecells").font(.headline); Spacer()
          Button("Expand table") { expanded = true }.controlSize(.small)
        }
        ExperimentCSVGrid(table: table, firstRow: firstRow, rowLimit: 8)
          .frame(height: CGFloat(min(8, table.values(firstRow: firstRow).count) + 1) * 42 + 16)
        Text("Showing \(min(8, table.values(firstRow: firstRow).count)) rows · \(table.columns) columns. Expand to view more or copy as Markdown.")
          .font(.caption).foregroundStyle(.secondary)
        if table.limited { Text("Preview limited to 200 data rows, 30 columns, 1,000 characters per cell and 2 MB. The original file is unchanged.").font(.caption).foregroundStyle(.secondary) }
      } else if !error.isEmpty {
        Text(error + " Open the original file below.").font(.caption).foregroundStyle(.secondary)
      } else { ProgressView().frame(height: 80) }
    }.task(id: path) {
      table = nil; error = ""; let file = path
      do {
        let result = try await Task.detached(priority: .utility) { try ExperimentCSV.load(file) }.value
        guard !Task.isCancelled else { return }; table = result
      } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }.sheet(isPresented: $expanded) {
      if let table {
        VStack(alignment: .leading, spacing: 12) {
          HStack {
            Text(URL(fileURLWithPath: path).lastPathComponent).font(.headline).lineLimit(1); Spacer()
            Button("Open original") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
            Button("Done") { expanded = false }.keyboardShortcut(.cancelAction)
          }
          HStack {
            Toggle("First row is header", isOn: $firstRow).onChange(of: firstRow) { _, _ in copied = false }
            Spacer()
            Button(copied ? "Copied preview" : "Copy preview as Markdown") {
              NSPasteboard.general.clearContents(); NSPasteboard.general.setString(table.markdown(firstRow: firstRow), forType: .string); copied = true
            }
          }
          ExperimentCSVGrid(table: table, firstRow: firstRow, rowLimit: 201)
          Text("\(table.values(firstRow: firstRow).count) preview rows · \(table.columns) columns" + (table.limited ? " · Limited preview; open the original for complete data." : ""))
            .font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(width: 900, height: 620)
      }
    }
  }
}

private struct ExperimentCSVGrid: View {
  let table: ExperimentCSV
  let firstRow: Bool
  let rowLimit: Int
  var body: some View {
    ScrollView(.horizontal) {
      VStack(alignment: .leading, spacing: 0) {
        cells(table.headers(firstRow: firstRow), header: true)
        ScrollView(.vertical) {
          LazyVStack(spacing: 0) {
            ForEach(Array(table.values(firstRow: firstRow).prefix(rowLimit).enumerated()), id: \.offset) { index, values in
              cells(values, header: false).background(index.isMultiple(of: 2) ? Color.primary.opacity(0.025) : Color.clear)
            }
          }
        }
      }.frame(width: CGFloat(table.columns) * 160)
    }.background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
      .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))
  }
  private func cells(_ values: [String], header: Bool) -> some View {
    HStack(spacing: 0) {
      ForEach(0..<table.columns, id: \.self) { column in
        let value = column < values.count ? values[column] : ""
        Text(verbatim: value).font(header ? .system(size: 12, weight: .semibold) : .system(size: 12, design: .monospaced))
          .lineLimit(2).textSelection(.enabled).padding(.horizontal, 8).frame(width: 160, height: 42, alignment: .leading)
          .help(value).overlay(alignment: .trailing) { Divider() }
      }
    }.background(header ? Palette.accent.opacity(0.1) : Color.clear)
      .overlay(alignment: .bottom) { Divider() }
  }
}
