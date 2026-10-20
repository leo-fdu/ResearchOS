import AppKit
import SwiftUI
import WebKit

/// Expanded Markdown has no independent vertical viewport. Route wheel events
/// over its visible body to the outer record page, before WebKit consumes them.
final class ResearchMarkdownWebView: WKWebView {
  var forwardsVerticalScrolling = false
  private var wheelMonitor: Any?

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    removeWheelMonitor()
    guard window != nil else { return }
    wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
      guard let self, self.forwardsVerticalScrolling,
        let window = self.window, event.window === window,
        !self.isHiddenOrHasHiddenAncestor,
        abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX),
        self.visibleRect.contains(self.convert(event.locationInWindow, from: nil)),
        let outer = self.enclosingScrollView
      else { return event }
      outer.scrollWheel(with: event)
      return nil
    }
  }

  func removeWheelMonitor() {
    if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
    wheelMonitor = nil
  }
  deinit { if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) } }
}

struct EdgeToEdgeWorkspace: NSViewRepresentable {
  let model: WorkspaceModel
  func makeNSView(context: Context) -> NSHostingView<WorkspaceView> {
    let host = NSHostingView(rootView: WorkspaceView(model: model))
    host.safeAreaRegions = []
    return host
  }
  func updateNSView(_ view: NSHostingView<WorkspaceView>, context: Context) {}
}

struct WindowChromeReader: NSViewRepresentable {
  @Binding var topInset: CGFloat
  func makeNSView(context: Context) -> ChromeView {
    let view = ChromeView()
    view.changed = { value in if topInset != value { topInset = value } }
    return view
  }
  func updateNSView(_ view: ChromeView, context: Context) {}
  final class ChromeView: NSView {
    var changed: ((CGFloat) -> Void)?
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      NotificationCenter.default.removeObserver(self)
      guard let window else { return }
      ReaderAppDelegate.workspaceWindow = window
      window.styleMask.insert(.fullSizeContentView)
      window.titlebarAppearsTransparent = true
      window.titleVisibility = .hidden
      for name in [NSWindow.didResizeNotification, NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
        NotificationCenter.default.addObserver(self, selector: #selector(updateInset), name: name, object: window)
      }
      updateInset()
    }
    @objc private func updateInset() {
      guard let window else { return }
      let inset = window.styleMask.contains(.fullScreen) ? 0 : max(28, window.frame.height - window.contentLayoutRect.height)
      DispatchQueue.main.async { [weak self] in self?.changed?(inset) }
    }
    deinit { NotificationCenter.default.removeObserver(self) }
  }
}

struct RelationComposer: View {
  @ObservedObject var model: WorkspaceModel
  let source: Row
  @Environment(\.dismiss) private var dismiss
  @State private var query = ""
  @State private var relation = "related"
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack { Text("Link to“\(source.title)”").font(.title3); Spacer(); Button("Done") { dismiss() } }
      TextField("Filter projects, plans, resources or folders", text: $query).textFieldStyle(.roundedBorder)
      Picker("Relationship", selection: $relation) {
        Text("Related resources").tag("related"); Text("Supporting evidence").tag("supports")
        Text("Contradicting evidence").tag("contradicts"); Text("Depends on").tag("depends_on")
      }
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 12) {
          ForEach((model.objects + model.roots + model.documents).filter {
            $0.id != source.id && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query))
          }.prefix(100)) { target in
            HStack {
              VStack(alignment: .leading) { Text(target.title).lineLimit(2); Text(labels[target.string("kind")] ?? target.string("kind")).font(.caption).foregroundStyle(.secondary) }
              Spacer()
              let linked = model.edges.contains { $0.string("source") == source.id && $0.string("target") == target.id && $0.string("relation") == relation }
              Button(linked ? "Linked" : "Link") {
                Task { await model.perform("/v2/link", ["source": source.id, "target": target.id, "relation": relation]) }
              }.disabled(linked)
            }
          }
        }
      }
      Text("Linked folders are included in project search. Filter to find a resource.").font(.caption).foregroundStyle(.secondary)
    }.padding(24).frame(width: 660, height: 520)
  }
}

struct ResearchMarkdown: View {
  let text: String
  let onLink: (URL) -> Void
  @State private var height: CGFloat = 180
  var body: some View {
    MarkdownSurface(text: text, height: $height, onLink: onLink).frame(height: max(100, height))
  }
}
struct ResearchMarkdownReader: View {
  let text: String
  let onLink: (URL) -> Void
  var body: some View {
    MarkdownSurface(text: text, height: .constant(0), onLink: onLink, scrollable: true)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
struct MarkdownSurface: NSViewRepresentable {
  let text: String
  @Binding var height: CGFloat
  let onLink: (URL) -> Void
  var scrollable = false
  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeNSView(context: Context) -> WKWebView {
    let config = WKWebViewConfiguration()
    config.userContentController.add(context.coordinator, name: "ready")
    config.userContentController.add(context.coordinator, name: "action")
    config.userContentController.add(context.coordinator, name: "documentHeight")
    let scrollCSS = scrollable ? "html{overflow-y:scroll!important;scrollbar-gutter:stable}::-webkit-scrollbar{width:12px}::-webkit-scrollbar-track{background:rgba(128,128,128,.08)}::-webkit-scrollbar-thumb{background:rgba(128,128,128,.5);border:3px solid transparent;background-clip:padding-box;border-radius:8px}" : ""
    let js = "window.researchDocument=true;document.addEventListener('DOMContentLoaded',()=>{let s=document.createElement('style');s.textContent='body{padding:0!important} .role,.actions,details,#latest{display:none!important}.message{padding:0!important;margin:0!important}\(scrollCSS)';document.head.appendChild(s);new ResizeObserver(()=>window.webkit.messageHandlers.documentHeight.postMessage(document.getElementById(\"messages\").getBoundingClientRect().height+24)).observe(document.getElementById('messages'));});"
    config.userContentController.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    let web = ResearchMarkdownWebView(frame: .zero, configuration: config)
    web.forwardsVerticalScrolling = !scrollable
    web.setValue(false, forKey: "drawsBackground")
    web.navigationDelegate = context.coordinator
    context.coordinator.web = web
    let directory = TranscriptView.webDirectory
    web.loadFileURL(directory.appendingPathComponent("index.html"), allowingReadAccessTo: directory)
    return web
  }
  func updateNSView(_ web: WKWebView, context: Context) {
    (web as? ResearchMarkdownWebView)?.forwardsVerticalScrolling = !scrollable
    context.coordinator.parent = self; context.coordinator.update()
  }
  static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
    (view as? ResearchMarkdownWebView)?.removeWheelMonitor()
    view.configuration.userContentController.removeAllScriptMessageHandlers(); view.stopLoading()
  }
  @MainActor final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    var parent: MarkdownSurface
    weak var web: WKWebView?
    var ready = false
    var last = ""
    var revision = 0
    init(_ parent: MarkdownSurface) { self.parent = parent }
    func update() {
      guard ready, last != parent.text || revision == 0 else { return }
      last = parent.text; revision += 1
      let payload: [String: Any] = ["revision": revision, "reset": true, "order": ["document"], "updates": [["id": "document", "role": "assistant", "text": last, "streaming": false]]]
      if let bytes = try? JSONSerialization.data(withJSONObject: payload), let json = String(data: bytes, encoding: .utf8) { web?.evaluateJavaScript("applyUpdate(\(json))") }
    }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
      if message.name == "ready" { ready = true; update() }
      else if message.name == "documentHeight", !parent.scrollable, let value = message.body as? Double { if abs(parent.height - value) > 1 { parent.height = min(100000, value) } }
      else if let action = message.body as? [String: String], let address = action["url"], let url = URL(string: address) {
        if url.scheme == "researchos" { parent.onLink(url) }
        else if ["https", "http", "mailto"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
      }
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) { decisionHandler(action.request.url?.isFileURL == true ? .allow : .cancel) }
  }
}

struct ExperimentWorkspace: View {
  let baseURL: String
  @State private var page = "experiments"
  var body: some View {
    VStack(spacing: 0) {
      Picker("Experiment section", selection: $page) {
        Text("Experiments").tag("experiments"); Text("Projects").tag("projects")
        Text("Dataset versions").tag("datasets"); Text("Backups").tag("settings")
      }.pickerStyle(.segmented).labelsHidden().padding(12)
      LegacyPane(url: baseURL + "/#" + page)
    }
  }
}
struct LegacyPane: NSViewRepresentable {
  let url: String
  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeNSView(context: Context) -> WKWebView {
    let config = WKWebViewConfiguration()
    config.userContentController.add(context.coordinator, name: "exportFile")
    config.userContentController.addUserScript(WKUserScript(source: "document.addEventListener('DOMContentLoaded',()=>{let s=document.createElement('style');s.textContent='.sidebar,.topbar,.main-footer{display:none!important}.main-shell{margin-left:0!important}#app{display:block!important}main{padding:18px!important}';document.head.appendChild(s)});", injectionTime: .atDocumentStart, forMainFrameOnly: true))
    let web = WKWebView(frame: .zero, configuration: config)
    web.uiDelegate = context.coordinator; web.navigationDelegate = context.coordinator
    context.coordinator.origin = URL(string: url)
    if let u = URL(string: url) { web.load(URLRequest(url: u)) }
    return web
  }
  func updateNSView(_ web: WKWebView, context: Context) {
    guard let target = URL(string: url), web.url != target else { return }
    if web.url?.host == target.host {
      if let data = try? JSONSerialization.data(withJSONObject: [target.fragment ?? "experiments"]), let json = String(data: data, encoding: .utf8) { web.evaluateJavaScript("location.hash=(\(json))[0]") }
    }
  }
  static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) { web.configuration.userContentController.removeAllScriptMessageHandlers(); web.stopLoading() }
  @MainActor final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    var origin: URL?
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
      guard let url = action.request.url else { decisionHandler(.cancel); return }
      if url.host == origin?.host && url.port == origin?.port { decisionHandler(.allow) }
      else { if ["https", "http"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }; decisionHandler(.cancel) }
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
      let alert = NSAlert(); alert.messageText = "Research OS"; alert.informativeText = message; alert.addButton(withTitle: "Confirm"); alert.addButton(withTitle: "Cancel")
      completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
      let alert = NSAlert(); alert.messageText = message; alert.runModal(); completionHandler()
    }
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
      let panel = NSOpenPanel(); panel.allowsMultipleSelection = parameters.allowsMultipleSelection; panel.canChooseDirectories = false
      completionHandler(panel.runModal() == .OK ? panel.urls : nil)
    }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
      guard message.frameInfo.securityOrigin.host == origin?.host, message.frameInfo.securityOrigin.port == origin?.port,
        let data = message.body as? [String: String], let content = data["content"], content.utf8.count <= 30_000_000 else { return }
      let panel = NSSavePanel(); panel.nameFieldStringValue = URL(fileURLWithPath: data["name"] ?? "export.json").lastPathComponent
      let exports = WorkspaceModel.dataDirectory.appendingPathComponent("exports")
      try? FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
      panel.directoryURL = exports
      if panel.runModal() == .OK, let url = panel.url {
        do { try content.write(to: url, atomically: true, encoding: .utf8) }
        catch { let alert = NSAlert(); alert.messageText = error.localizedDescription; alert.runModal() }
      }
    }
  }
}
