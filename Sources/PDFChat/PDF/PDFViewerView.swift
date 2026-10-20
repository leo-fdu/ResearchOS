import SwiftUI
import PDFKit
import AppKit

struct PDFViewerView: View {
    @ObservedObject var store: PDFContextStore
    @State private var showOutline = false
    @State private var showSearch = false
    @FocusState private var searchFocused: Bool
    @State private var pageInput = "1"
    @State private var imageError: String?
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { showOutline.toggle() } label: { Image(systemName: "list.bullet.indent") }.help("Document outline")
                Button { showSearch.toggle() } label: { Image(systemName: "magnifyingglass") }.help("Search PDF (⌘F)").keyboardShortcut("f", modifiers: .command)
                Divider().frame(height: 15)
                Button { store.goToPage(store.currentPage - 1) } label: { Image(systemName: "chevron.left") }.disabled(store.currentPage <= 1)
                TextField("Page", text: $pageInput).textFieldStyle(.plain).multilineTextAlignment(.center).frame(width: 36)
                    .onSubmit { if let page = Int(pageInput) { store.goToPage(page) } }
                Text("/ \(store.pageCount)").monospacedDigit().foregroundStyle(.secondary)
                Button { store.goToPage(store.currentPage + 1) } label: { Image(systemName: "chevron.right") }.disabled(store.currentPage >= store.pageCount)
                Spacer(minLength: 0)
                Button { store.scale(0.85) } label: { Image(systemName: "minus") }.help("Zoom out")
                Text("\(Int(store.zoom * 100))%").monospacedDigit().foregroundStyle(.secondary).frame(width: 40)
                Button { store.scale(1.18) } label: { Image(systemName: "plus") }.help("Zoom in")
                Button { store.fitWidth() } label: { Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right") }.help("Fit width")
            }
            .buttonStyle(.borderless).font(.system(size: 12)).padding(.horizontal, 16).frame(height: 42)
            if showSearch {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search document", text: $store.searchQuery).textFieldStyle(.plain).focused($searchFocused).onAppear { searchFocused = true }.onSubmit { store.beginSearch() }
                    if store.isSearching { ProgressView().controlSize(.small) }
                    Text(store.searchStatus).font(.caption).foregroundStyle(.secondary)
                    Button { store.nextResult(-1) } label: { Image(systemName: "chevron.up") }
                    Button { store.nextResult(1) } label: { Image(systemName: "chevron.down") }
                    Button { showSearch = false } label: { Image(systemName: "xmark") }
                }.buttonStyle(.borderless).padding(10).background(.background).clipShape(RoundedRectangle(cornerRadius: 8)).padding(.horizontal, 12).padding(.bottom, 10)
            }
            Divider()
            HStack(spacing: 0) {
                if showOutline {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Outline").font(.headline).padding(.bottom, 8)
                            if let root = store.document?.outlineRoot, root.numberOfChildren > 0 {
                                ForEach(0..<root.numberOfChildren, id: \.self) { index in
                                    if let item = root.child(at: index) { OutlineRow(item: item, store: store) }
                                }
                            } else { Text("This PDF has no embedded outline.").font(.caption).foregroundStyle(.secondary) }
                        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(width: 190)
                    Divider()
                }
                PDFViewRepresentable(store: store)
            }
        }
        .onChange(of: store.currentPage) { _, page in pageInput = String(page) }
    }
}
private struct OutlineRow: View {
    let item: PDFOutline
    @ObservedObject var store: PDFContextStore
    var body: some View {
        if item.numberOfChildren > 0 {
            DisclosureGroup {
                ForEach(0..<item.numberOfChildren, id: \.self) { index in
                    if let child = item.child(at: index) { AnyView(OutlineRow(item: child, store: store)) }
                }
            } label: { destination }
        } else { destination }
    }
    private var destination: some View {
        Button {
            let destination = item.destination ?? (item.action as? PDFActionGoTo)?.destination
            if let destination { store.pdfView?.go(to: destination) }
        } label: { Text(item.label ?? "Section").font(.system(size: 12)).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading) }
            .buttonStyle(.plain).padding(.vertical, 4)
    }
}

final class ReadingPDFView: PDFView {
    var onSelectionAction: ((String) -> Void)?
    var onLayoutReady: (() -> Void)?
    override func layout() {
        super.layout()
        if bounds.width > 200 { DispatchQueue.main.async { [weak self] in self?.onLayoutReady?() } }
    }
    private let selectionPopover = NSPopover()
    func showSelectionActions() {
        guard let selection = currentSelection, let text = selection.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let page = selection.pages.first else { selectionPopover.close(); return }
        let rect = convert(selection.bounds(for: page), from: page)
        let toolbar = NSStackView()
        toolbar.orientation = .horizontal; toolbar.spacing = 2
        for (title, tag) in [("Ask", 0), ("explain", 1), ("translate", 2), ("Copy", 3)] {
            let button = NSButton(title: title, target: self, action: #selector(selectionAction(_:)))
            button.tag = tag; button.bezelStyle = .inline; toolbar.addArrangedSubview(button)
        }
        toolbar.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        let controller = NSViewController(); controller.view = toolbar
        selectionPopover.contentViewController = controller; selectionPopover.behavior = .transient
        selectionPopover.animates = false
        selectionPopover.show(relativeTo: rect, of: self, preferredEdge: .maxY)
    }
    @objc private func selectionAction(_ sender: NSButton) {
        if sender.tag == 3 { copy(nil) }
        else { onSelectionAction?(["", "Explain the quoted passage using the document context.", "Translate the quoted passage into Chinese, preserving key terms."][sender.tag]) }
        selectionPopover.close()
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "c").target = self
        let ask = menu.addItem(withTitle: "Quote and ask", action: #selector(askSelection), keyEquivalent: "")
        ask.target = self
        return menu
    }
    @objc private func askSelection() { onSelectionAction?("") }
}
struct PDFViewRepresentable: NSViewRepresentable {
    @ObservedObject var store: PDFContextStore
    func makeNSView(context: Context) -> ReadingPDFView {
        let view = ReadingPDFView()
        view.document = store.document; view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical; view.displaysPageBreaks = true; view.autoScales = true
        view.backgroundColor = NSColor.controlBackgroundColor
        view.minScaleFactor = 0.25; view.maxScaleFactor = 5
        store.pdfView = view
        context.coordinator.store = store
        view.document?.delegate = context.coordinator
        view.onSelectionAction = { [weak store] prompt in store?.pinSelection(prompt: prompt) }
        view.onLayoutReady = { [weak store] in store?.restorePositionIfReady() }
        context.coordinator.mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak view] event in
            guard let view, event.window === view.window,
                  view.bounds.contains(view.convert(event.locationInWindow, from: nil)) else { return event }
            DispatchQueue.main.async { [weak view] in view?.showSelectionActions() }
            return event
        }
        let center = NotificationCenter.default
        for name in [Notification.Name.PDFViewPageChanged, .PDFViewScaleChanged] {
            center.addObserver(context.coordinator, selector: #selector(Coordinator.positionChanged), name: name, object: view)
        }
        center.addObserver(context.coordinator, selector: #selector(Coordinator.selectionChanged), name: .PDFViewSelectionChanged, object: view)
        center.addObserver(context.coordinator, selector: #selector(Coordinator.searchFinished), name: .PDFDocumentDidEndFind, object: view.document)
        DispatchQueue.main.async {
            store.restorePositionIfReady()
        }
        return view
    }
    func updateNSView(_ view: ReadingPDFView, context: Context) {
        if view.document !== store.document { view.document = store.document; view.document?.delegate = context.coordinator }
    }
    static func dismantleNSView(_ view: ReadingPDFView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
        if let monitor = coordinator.mouseMonitor { NSEvent.removeMonitor(monitor); coordinator.mouseMonitor = nil }
        view.document?.delegate = nil; view.onSelectionAction = nil; view.onLayoutReady = nil
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator: NSObject, PDFDocumentDelegate {
        weak var store: PDFContextStore?
        var mouseMonitor: Any?
        @objc func positionChanged() { Task { @MainActor [weak self] in self?.store?.recordPosition() } }
        @objc func selectionChanged() {
            Task { @MainActor [weak self] in
                guard let store = self?.store, let view = store.pdfView else { return }
                store.selectedText = view.currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if let page = view.currentSelection?.pages.first, let document = view.document { store.selectedPage = document.index(for: page) + 1 }
            }
        }
        func didMatchString(_ instance: PDFSelection) { Task { @MainActor [weak self] in self?.store?.addSearchResult(instance) } }
        @objc func searchFinished() { Task { @MainActor [weak self] in self?.store?.finishSearch() } }
    }
}
