import SwiftUI
import UniformTypeIdentifiers

struct ChatInputView: View {
    @ObservedObject var viewModel: ChatViewModel
    @ObservedObject var contextStore: PDFContextStore
    @ObservedObject private var slashStore = SlashCommandStore.shared
    @State private var inputHeight: CGFloat = 110
    @State private var showImages = false
    @State private var imageError: String?
    @State private var preparingImage = false
    @State private var quoteExpanded = false
    private var matches: [PresetPrompt] { slashStore.matches(for: viewModel.inputText) }
    var body: some View {
        VStack(spacing: 0) {
            if let quote = contextStore.quote {
                HStack(alignment: .top, spacing: 8) {
                    Rectangle().fill(.tint).frame(width: 3)
                    VStack(alignment: .leading, spacing: 4) {
                        Button("Quote · Page \(quote.page)") { contextStore.goToPage(quote.page) }.buttonStyle(.plain).font(.caption).foregroundStyle(.tint)
                        Text(quote.text).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(quoteExpanded ? 12 : 2)
                            .onTapGesture { quoteExpanded.toggle() }
                    }
                    Spacer(minLength: 0)
                    Button { contextStore.quote = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                }.fixedSize(horizontal: false, vertical: true).padding(10).background(Color.accentColor.opacity(0.05)).padding(.horizontal, 10).padding(.top, 10)
            }
            if !viewModel.pendingImages.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(Array(viewModel.pendingImages.enumerated()), id: \.offset) { index, image in
                            if let data = image.thumbData, let nsImage = NSImage(data: data) {
                                Image(nsImage: nsImage).resizable().scaledToFit().frame(width: 58, height: 58).clipShape(RoundedRectangle(cornerRadius: 7))
                                    .overlay(alignment: .topTrailing) { Button { viewModel.removeImage(at: index) } label: { Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.6)) }.buttonStyle(.plain) }
                            }
                        }
                    }.padding(.horizontal, 12)
                }.frame(height: 70)
            }
            ZStack(alignment: .topLeading) {
                if viewModel.inputText.isEmpty {
                    Text(contextStore.quote == nil ? "Ask about this PDF…" : "What would you like to know about this passage?")
                        .font(.system(size: 14)).foregroundStyle(.tertiary).padding(.leading, 13).padding(.top, 12).allowsHitTesting(false)
                }
                ChatInputTextView(text: $viewModel.inputText,
                                  onSend: { viewModel.send(contextStore: contextStore) }, onPasteImage: handleImage,
                                  onTextChange: {}, onHeightChange: { inputHeight = min(max($0, 110), 260) }, focusObject: viewModel)
                    .frame(height: inputHeight)
            }
            if !matches.isEmpty {
                VStack(spacing: 2) {
                    ForEach(matches) { prompt in
                        Button { viewModel.inputText = prompt.content } label: {
                            HStack { Text("/" + prompt.trigger).fontWeight(.medium); Text(prompt.content).lineLimit(1).foregroundStyle(.secondary); Spacer() }.font(.caption).padding(8)
                        }.buttonStyle(.plain)
                    }
                }.padding(6).background(Color.accentColor.opacity(0.05))
            }
            HStack(spacing: 8) {
                Menu {
                    Button("Add images…") { showImages = true }
                    Button("Attach current PDF page image") { addPageImage() }.disabled(contextStore.reader == nil || preparingImage)
                } label: { Image(systemName: "plus") }.menuStyle(.borderlessButton).fixedSize().help("Add images or page screenshots")
                Menu {
                    ForEach(slashStore.presets) { prompt in Button(prompt.trigger) { viewModel.inputText = prompt.content } }
                } label: { Image(systemName: "text.badge.star") }.menuStyle(.borderlessButton).fixedSize().help("Prompt shortcuts")
                Picker("Document input", selection: $contextStore.mode) {
                    Text("PDF File").tag(DocumentInputMode.pdf)
                    Text("PDFKit Text").tag(DocumentInputMode.text)
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small)
                .frame(maxWidth: 180)
                .help("PDF file: sends the full PDF, requiring provider support. PDFKit text: sends extracted text, suited to long text-based documents.")
                .disabled(viewModel.isStreaming)
                if preparingImage { ProgressView().controlSize(.mini) }
                Spacer(minLength: 0)
                if viewModel.isStreaming {
                    Button { viewModel.stop() } label: { Image(systemName: "stop.fill").frame(width: 22, height: 22) }.buttonStyle(.borderedProminent).help("Stop response")
                } else {
                    Button { viewModel.send(contextStore: contextStore) } label: { Image(systemName: "arrow.up").fontWeight(.semibold).frame(width: 22, height: 22) }
                        .buttonStyle(.borderedProminent).help("Send (Return); Shift+Return for a new line")
                        .disabled(viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && viewModel.pendingImages.isEmpty)
                }
            }.foregroundStyle(.secondary).padding(.horizontal, 12).padding(.bottom, 10)
        }
        .background(Color(NSColor.textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.10), lineWidth: 1))
        .fileImporter(isPresented: $showImages, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result, let image = NSImage(contentsOf: url) { handleImage(image) }
        }
        .alert("Image processing failed", isPresented: Binding(get: { imageError != nil }, set: { if !$0 { imageError = nil } })) { Button("OK") {} } message: { Text(imageError ?? "") }
    }
    private func handleImage(_ image: NSImage) {
        guard let dataURL = ImageCoding.dataURL(from: image), let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else { return }
        viewModel.addImage(.init(dataURL: dataURL, thumbData: png))
    }
    private func addPageImage() {
        guard let reader = contextStore.reader else { return }
        let page = contextStore.currentPage
        preparingImage = true
        Task {
            defer { preparingImage = false }
            do {
                let dataURL = try await reader.pageImage(page)
                let data = dataURL.split(separator: ",", maxSplits: 1).last.flatMap { Data(base64Encoded: String($0)) }
                viewModel.addImage(.init(dataURL: dataURL, thumbData: data))
                if viewModel.inputText.isEmpty { viewModel.inputText = "Explain the image on page \(page) of this PDF." }
            } catch { imageError = error.localizedDescription }
        }
    }
}
