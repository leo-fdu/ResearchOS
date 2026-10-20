import SwiftUI
import UniformTypeIdentifiers
import PDFKit

/// 仅用于让 SwiftUI `DocumentGroup(viewing:)` 把 PDF File路由成多窗口.
/// 实际渲染由 `PDFContextStore` 通过 `pdfDocument` Done.
struct PDFFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.pdf] }
    static var writableContentTypes: [UTType] { [] }

    var pdfDocument: PDFDocument?

    init(pdfDocument: PDFDocument?) { self.pdfDocument = pdfDocument }

    init(configuration: ReadConfiguration) throws {
        if let data = configuration.file.regularFileContents as Data? {
            self.pdfDocument = PDFDocument(data: data)
        } else {
            self.pdfDocument = nil
        }
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        throw CocoaError(.featureUnsupported)
    }
}