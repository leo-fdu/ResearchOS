import SwiftUI
import PDFKit
import AppKit

struct ContentView: View {
    @StateObject private var contextStore = PDFContextStore()
    @StateObject private var chatViewModel = ChatViewModel()
    @StateObject private var historyStore = ConversationHistoryStore()
    @AppStorage("reader.sidebarWidth") private var sidebarWidth: Double = 420
    @AppStorage("reader.sidebarVisible") private var sidebarVisible = true
    @State private var showOpenSheet = false
    @State private var initialized = false
    @State private var loadingHistory = true
    let pdfDocBinding: Binding<PDFDocument?>
    let fileURL: URL?

    init(pdfDoc: Binding<PDFDocument?>, fileURL: URL? = nil) {
        self.pdfDocBinding = pdfDoc; self.fileURL = fileURL
    }
    var body: some View {
        GeometryReader { geometry in
            let width = min(max(sidebarWidth, 330), max(330, geometry.size.width - 370))
            HStack(spacing: 0) {
                pdfPane.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                if sidebarVisible {
                    SidebarDivider(width: $sidebarWidth, maximum: max(330, geometry.size.width - 370))
                        .frame(width: 12)
                    ChatSidebarView(viewModel: chatViewModel, contextStore: contextStore, historyStore: historyStore)
                        .frame(width: width).clipped().disabled(loadingHistory)
                }
            }
            .transaction { $0.animation = nil }
        }
        .frame(minWidth: sidebarVisible ? 740 : 400, minHeight: 520)
        .background(Color(NSColor.windowBackgroundColor))
        .task { await load() }
        .onDisappear { chatViewModel.stop(); contextStore.recordPosition() }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { showOpenSheet = true } label: { Label("Open  PDF", systemImage: "folder") }.help("Open  PDF (⌘O)")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { sidebarVisible.toggle() } label: { Label("Reading assistant", systemImage: "sidebar.trailing") }
                    .help("Show or hide reading assistant (⌘⇧L)").keyboardShortcut("l", modifiers: [.command, .shift])
            }
        }
        .fileImporter(isPresented: $showOpenSheet, allowedContentTypes: [.pdf]) { result in
            if case .success(let url) = result {
                NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
            }
        }
        .focusedSceneValue(\.pdfChatViewModel, chatViewModel)
        .focusedSceneValue(\.pdfChatOpenPicker) { showOpenSheet = true }
    }
    private var pdfPane: some View {
        Group {
            if contextStore.document != nil { PDFViewerView(store: contextStore) }
            else {
                VStack(spacing: 18) {
                    Image(systemName: "doc.text").font(.system(size: 58, weight: .ultraLight)).foregroundStyle(.tint)
                    Text("Stay with the paper").font(.system(size: 28, weight: .semibold))
                    Text("Open a PDF and discuss it with your reading assistant.") .foregroundStyle(.secondary)
                    Button("Open  PDF…") { showOpenSheet = true }.buttonStyle(.borderedProminent).controlSize(.large)
                    Text("You can also open a PDF from Finder.").font(.caption).foregroundStyle(.tertiary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
    private func load() async {
        guard !initialized else { return }
        defer { loadingHistory = false }
        initialized = true
        chatViewModel.history = historyStore
        contextStore.onAsk = { prompt in
            sidebarVisible = true
            if !prompt.isEmpty { chatViewModel.inputText = prompt }
            NotificationCenter.default.post(name: .pdfChatFocusInput, object: chatViewModel)
        }
        guard let doc = pdfDocBinding.wrappedValue else { return }
        contextStore.load(document: doc, url: fileURL)
        if let id = try? await contextStore.reader?.identity() {
            contextStore.setIdentity(id)
            await historyStore.load(for: fileURL, contentKey: id)
            if let latest = historyStore.conversations.first { chatViewModel.restore(messages: historyStore.load(latest)) }
        }
    }
}

struct SidebarDivider: NSViewRepresentable {
    @Binding var width: Double
    var maximum: Double
    func makeNSView(context: Context) -> DragDivider { DragDivider() }
    func updateNSView(_ view: DragDivider, context: Context) {
        view.currentWidth = width
        view.onChange = { value in width = min(max(330, value), maximum) }
    }
}
final class DragDivider: NSView {
    var currentWidth: Double = 420
    var onChange: ((Double) -> Void)?
    private var originX: CGFloat = 0
    private var originalWidth: Double = 0
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true); setAccessibilityLabel("Resize reading assistant")
        setAccessibilityRole(.splitter)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override func mouseDown(with event: NSEvent) { originX = event.locationInWindow.x; originalWidth = currentWidth }
    override func mouseDragged(with event: NSEvent) { onChange?(originalWidth - Double(event.locationInWindow.x - originX)) }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 123 { onChange?(currentWidth + 20) }
        else if event.keyCode == 124 { onChange?(currentWidth - 20) }
        else { super.keyDown(with: event) }
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill(); bounds.fill()
        NSColor.separatorColor.withAlphaComponent(0.55).setFill()
        NSRect(x: bounds.midX, y: 0, width: 1, height: bounds.height).fill()
        NSColor.tertiaryLabelColor.setFill()
        NSBezierPath(roundedRect: NSRect(x: bounds.midX - 1.5, y: bounds.midY - 15, width: 3, height: 30), xRadius: 1.5, yRadius: 1.5).fill()
    }
}
extension Notification.Name { static let pdfChatFocusInput = Notification.Name("PDFChat.focusInput") }
