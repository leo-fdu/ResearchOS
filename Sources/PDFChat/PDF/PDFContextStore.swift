import Foundation
import PDFKit
import SwiftUI
import CryptoKit

enum DocumentInputMode: String, CaseIterable, Identifiable {
    case pdf, text
    var id: String { rawValue }
    var label: String { self == .pdf ? "PDF File" : "PDFKit Text" }
}
struct DocumentQuote: Codable, Equatable {
    var text: String
    var page: Int
}
struct PreparedDocument {
    var pdf: PDFInput?
    var text: String
}

/// Uses its own PDFDocument, never the PDFView instance. Parsing and encoding run
/// off the UI thread and are cached for the document's lifetime.
actor PDFDocumentReader {
    private let url: URL?
    private var bytes: Data?
    private var parsed: PDFDocument?
    private var encoded: PDFInput?
    private var pageTexts: [Int: String] = [:]
    init(url: URL?, data: Data?) { self.url = url; self.bytes = data }
    private func data() throws -> Data {
        if let bytes { return bytes }
        guard let url else { throw ChatError.configuration("First open PDF.") }
        let value = try Data(contentsOf: url, options: .mappedIfSafe)
        bytes = value
        return value
    }
    private func document() throws -> PDFDocument {
        if let parsed { return parsed }
        guard let doc = PDFDocument(data: try data()), !doc.isLocked else { throw ChatError.configuration("PDF cannot be read or requires a password.") }
        parsed = doc
        return doc
    }
    func identity() throws -> String { SHA256.hash(data: try data()).map { String(format: "%02x", $0) }.joined() }
    func prepare(mode: DocumentInputMode) throws -> PreparedDocument {
        try Task.checkCancellation()
        if mode == .pdf {
            if let encoded { return .init(pdf: encoded, text: "") }
            let bytes = try data()
            guard bytes.count < 50_000_000 else { throw ChatError.configuration("PDF exceeds the 50 MB upload limit. Use PDFKit text mode. Your provider may have a lower limit.") }
            let input = PDFInput(filename: url?.lastPathComponent ?? "document.pdf", base64: bytes.base64EncodedString())
            encoded = input
            return .init(pdf: input, text: "")
        }
        let doc = try document()
        var chunks: [String] = []
        for index in 0..<doc.pageCount {
            try Task.checkCancellation()
            chunks.append("[Page \(index + 1)]\n" + (try pageText(index + 1)))
        }
        guard pageTexts.values.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw ChatError.configuration("This PDF has no extractable text. Use PDF file mode or send page images.")
        }
        return .init(pdf: nil, text: chunks.joined(separator: "\n\n"))
    }
    func pageText(_ number: Int) throws -> String {
        if let cached = pageTexts[number] { return cached }
        let doc = try document()
        guard number >= 1, number <= doc.pageCount, let page = doc.page(at: number - 1) else {
            throw ChatError.configuration("Page number out of range (1–\(doc.pageCount)).")
        }
        let text = page.string ?? ""
        pageTexts[number] = text
        return text
    }
    func search(_ query: String) throws -> String {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "Enter a search query." }
        let doc = try document()
        var results: [String] = []
        for page in 1...max(doc.pageCount, 1) {
            try Task.checkCancellation()
            let text = try pageText(page)
            if let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) {
                let start = text.index(range.lowerBound, offsetBy: -240, limitedBy: text.startIndex) ?? text.startIndex
                let end = text.index(range.upperBound, offsetBy: 600, limitedBy: text.endIndex) ?? text.endIndex
                results.append("[Page \(page)](pdfchat://page/\(page))\n" + text[start..<end])
                if results.count == 20 { break }
            }
        }
        return results.isEmpty ? "No matching text. Use view_pdf_page for scanned pages." : results.joined(separator: "\n\n")
    }
    func pageImage(_ number: Int) throws -> String {
        let doc = try document()
        guard number >= 1, number <= doc.pageCount, let page = doc.page(at: number - 1) else { throw ChatError.configuration("Page number out of range.") }
        let bounds = page.bounds(for: .cropBox)
        let ratio = 1600 / max(bounds.width, bounds.height, 1)
        let image = page.thumbnail(of: NSSize(width: bounds.width * ratio, height: bounds.height * ratio), for: .cropBox)
        guard let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data),
              let png = bitmap.representation(using: .png, properties: [:]) else { throw ChatError.configuration("Could not render page image.") }
        return "data:image/png;base64," + png.base64EncodedString()
    }
}

@MainActor
final class PDFContextStore: ObservableObject {
    @Published private(set) var document: PDFDocument?
    @Published private(set) var pdfURL: URL?
    @Published var mode: DocumentInputMode = .pdf
    @Published var quote: DocumentQuote?
    @Published var selectedText = ""
    @Published var selectedPage = 1
    @Published var currentPage = 1
    @Published var zoom: CGFloat = 1
    @Published var searchQuery = ""
    @Published var searchStatus = ""
    @Published var isSearching = false
    @Published var identity: String?
    var reader: PDFDocumentReader?
    weak var pdfView: PDFView?
    var onAsk: ((String) -> Void)?
    var pageCount: Int { document?.pageCount ?? 0 }
    var filename: String { pdfURL?.lastPathComponent ?? "PDF Document" }
    var hasSelection: Bool { quote != nil }
    var contextLabel: String { mode.label }
    private var restoredPosition = false
    private var results: [PDFSelection] = []
    private var resultIndex = 0

    func load(document: PDFDocument, url: URL?) {
        self.document = document; pdfURL = url
        reader = PDFDocumentReader(url: url, data: url == nil ? document.dataRepresentation() : nil)
    }
    func setIdentity(_ id: String) {
        identity = id
        restorePositionIfReady()
    }
    func restorePositionIfReady() {
        guard !restoredPosition, let id = identity, let view = pdfView, view.bounds.width > 200, view.window != nil else { return }
        let savedPage = UserDefaults.standard.integer(forKey: "reading.page.\(id)")
        let scale = UserDefaults.standard.double(forKey: "reading.zoom.\(id)")
        view.autoScales = false
        if scale > 0 { view.scaleFactor = scale; zoom = scale } else { fitWidth() }
        goToPage(savedPage > 0 ? savedPage : 1)
        restoredPosition = true
        recordPosition()
    }
    func recordPosition() {
        guard let pdfView, let document, let page = pdfView.currentPage else { return }
        currentPage = document.index(for: page) + 1
        zoom = pdfView.scaleFactor
        if restoredPosition, let identity {
            UserDefaults.standard.set(currentPage, forKey: "reading.page.\(identity)")
            UserDefaults.standard.set(Double(zoom), forKey: "reading.zoom.\(identity)")
        }
    }
    func pinSelection(prompt: String = "") {
        guard !selectedText.isEmpty else { return }
        quote = .init(text: selectedText, page: selectedPage)
        onAsk?(prompt)
    }
    func goToPage(_ page: Int) {
        guard let document, let target = document.page(at: max(0, min(page - 1, document.pageCount - 1))) else { return }
        pdfView?.go(to: target)
        currentPage = document.index(for: target) + 1
    }
    func fitWidth() {
        guard let view = pdfView, let page = view.currentPage else { return }
        view.autoScales = false
        view.scaleFactor = max(0.25, (view.bounds.width - 32) / page.bounds(for: .cropBox).width)
        recordPosition()
    }
    func scale(_ factor: CGFloat) {
        guard let view = pdfView else { return }
        view.autoScales = false
        view.scaleFactor = max(0.25, min(5, view.scaleFactor * factor)); recordPosition()
    }
    func beginSearch() {
        document?.cancelFindString()
        results = []; resultIndex = 0; searchStatus = ""
        guard !searchQuery.isEmpty else { pdfView?.highlightedSelections = nil; return }
        isSearching = true
        document?.beginFindString(searchQuery, withOptions: [.caseInsensitive])
    }
    func addSearchResult(_ selection: PDFSelection) { results.append(selection) }
    func finishSearch() {
        isSearching = false
        searchStatus = results.isEmpty ? "Not found" : "1 / \(results.count)"
        if let first = results.first { pdfView?.setCurrentSelection(first, animate: false); pdfView?.go(to: first) }
    }
    func nextResult(_ offset: Int) {
        guard !results.isEmpty else { return }
        resultIndex = (resultIndex + offset + results.count) % results.count
        pdfView?.setCurrentSelection(results[resultIndex], animate: false)
        pdfView?.go(to: results[resultIndex])
        searchStatus = "\(resultIndex + 1) / \(results.count)"
    }
}
