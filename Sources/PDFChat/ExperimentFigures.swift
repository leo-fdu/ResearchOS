import AppKit
import ImageIO
import PDFKit
import SwiftUI

enum ExperimentFigure {
  static func supports(_ path: String) -> Bool {
    ["png", "jpg", "jpeg", "tif", "tiff", "gif", "heic", "heif", "webp", "bmp", "pdf"].contains(URL(fileURLWithPath: path).pathExtension.lowercased())
  }

  // Decode a bounded thumbnail, never a full-resolution experiment image on the UI thread.
  static func thumbnail(_ path: String, maxPixels: Int = 1600) -> NSImage? {
    let url = URL(fileURLWithPath: path)
    guard supports(path), let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
          values.isRegularFile == true, (values.fileSize ?? Int.max) <= 100 * 1024 * 1024 else { return nil }
    if url.pathExtension.lowercased() == "pdf" {
      guard let document = PDFDocument(url: url), let page = document.page(at: 0) else { return nil }
      let size = page.bounds(for: .mediaBox).size
      guard size.width > 0, size.height > 0 else { return nil }
      let ratio = CGFloat(maxPixels) / max(size.width, size.height)
      return withExtendedLifetime(document) {
        page.thumbnail(of: NSSize(width: size.width * ratio, height: size.height * ratio), for: .mediaBox)
      }
    }
    guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels
          ] as CFDictionary) else { return nil }
    return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
  }
}

struct ExperimentAttachments: View {
  let items: [[String: Any]]
  var body: some View {
    LazyVStack(alignment: .leading, spacing: 16) {
      ForEach(Array(items.enumerated()), id: \.offset) { _, item in
        if let path = item["path"] as? String {
          ExperimentAttachment(path: path, name: item["name"] as? String,
            caption: item["caption"] as? String ?? "", referenced: item["mode"] as? String == "reference")
        }
      }
    }
  }
}

struct ExperimentAttachment: View {
  let path: String
  var name: String? = nil
  var caption = ""
  var referenced = false
  @State private var image: NSImage?
  @State private var loading = true
  @State private var expanded = false
  private var title: String { name ?? URL(fileURLWithPath: path).lastPathComponent }
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if ExperimentCSV.supports(path) {
        ExperimentCSVPreview(path: path)
      } else if ExperimentFigure.supports(path) {
        if let image {
          Button { expanded = true } label: {
            Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 360)
              .padding(8).background(Color.white, in: RoundedRectangle(cornerRadius: 8))
              .overlay(alignment: .topTrailing) {
                Image(systemName: "arrow.up.left.and.arrow.down.right").padding(8)
                  .background(.regularMaterial, in: Circle()).padding(8)
              }
          }.buttonStyle(.plain).help("Enlarge figure").accessibilityLabel("Enlarge " + title)
        } else if loading {
          ProgressView().frame(maxWidth: .infinity).frame(height: 100)
        } else {
          Label("Preview unavailable · open the original file below", systemImage: "photo")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      HStack {
        Button { NSWorkspace.shared.open(URL(fileURLWithPath: path)) } label: {
          Label(title, systemImage: ExperimentCSV.supports(path) ? "tablecells" : (ExperimentFigure.supports(path) ? "photo" : "paperclip")).lineLimit(2)
        }.buttonStyle(.plain).foregroundStyle(Palette.accent)
        if referenced { Text("Linked original").font(.caption).foregroundStyle(.secondary) }
        if URL(fileURLWithPath: path).pathExtension.lowercased() == "pdf" {
          Text("Page 1 preview").font(.caption).foregroundStyle(.secondary)
        }
      }
      if !caption.isEmpty { Text(caption).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
    }.frame(maxWidth: .infinity, alignment: .leading)
      .task(id: path) {
        loading = true; image = nil
        let file = path
        let result = await Task.detached(priority: .utility) { ExperimentFigure.thumbnail(file) }.value
        guard !Task.isCancelled else { return }
        image = result; loading = false
      }
      .sheet(isPresented: $expanded) { ExperimentFigureViewer(path: path, title: title, caption: caption, image: image) }
  }
}

private struct ExperimentFigureViewer: View {
  let path: String
  let title: String
  let caption: String
  let image: NSImage?
  @Environment(\.dismiss) private var dismiss
  @State private var zoom = 1.0
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text(title).font(.headline).lineLimit(1); Spacer()
        Button("Open original") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
        Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
      }
      if URL(fileURLWithPath: path).pathExtension.lowercased() == "pdf" {
        ExperimentPDFView(url: URL(fileURLWithPath: path))
      } else if let image {
        HStack { Text("Zoom"); Slider(value: $zoom, in: 0.5...3); Text("\(Int(zoom * 100))%").monospacedDigit().frame(width: 50) }
        GeometryReader { proxy in
          ScrollView([.horizontal, .vertical]) {
            Image(nsImage: image).resizable().scaledToFit()
              .frame(width: max(1, proxy.size.width * zoom), height: max(1, proxy.size.height * zoom))
              .background(Color.white)
          }
        }
      }
      if !caption.isEmpty { Text(caption).textSelection(.enabled).lineLimit(4) }
    }.padding(20).frame(width: 900, height: 660)
  }
}

private struct ExperimentPDFView: NSViewRepresentable {
  let url: URL
  func makeNSView(context: Context) -> PDFView {
    let view = PDFView(); view.document = PDFDocument(url: url); view.autoScales = true
    view.displayMode = .singlePageContinuous; return view
  }
  func updateNSView(_ view: PDFView, context: Context) {}
}
