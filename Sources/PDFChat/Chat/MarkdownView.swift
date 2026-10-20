import SwiftUI
import WebKit
import AppKit

/// A single, independently scrolling WebView for the transcript. No per-bubble
/// height bridge or nested SwiftUI ScrollView. Only changed messages cross IPC.
struct TranscriptView: NSViewRepresentable {
    @ObservedObject var viewModel: ChatViewModel
    var onPage: (Int) -> Void
    var onRetry: () -> Void
    var onResearchLink: ((URL) -> Void)? = nil
    var workspaceMode = false
    var onPrompt: ((String) -> Void)? = nil
    static var webDirectory: URL {
        let packaged = Bundle.main.url(forResource: "PDFChat_PDFChat", withExtension: "bundle").flatMap(Bundle.init(url:))
        return (packaged ?? Bundle.module).url(forResource: "Web", withExtension: nil)!
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "ready")
        config.userContentController.add(context.coordinator, name: "action")
        let view = WKWebView(frame: .zero, configuration: config)
        view.underPageBackgroundColor = .clear
        view.setValue(false, forKey: "drawsBackground")
        view.allowsMagnification = false
        view.navigationDelegate = context.coordinator
        context.coordinator.webView = view
        context.coordinator.model = viewModel
        let directory = Self.webDirectory
        view.loadFileURL(directory.appendingPathComponent("index.html"), allowingReadAccessTo: directory)
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.model = viewModel
        context.coordinator.onPage = onPage
        context.coordinator.onRetry = onRetry
        context.coordinator.onResearchLink = onResearchLink
        context.coordinator.workspaceMode = workspaceMode
        context.coordinator.onPrompt = onPrompt
        context.coordinator.requestUpdate()
    }
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeAllScriptMessageHandlers()
        view.stopLoading(); view.navigationDelegate = nil
        coordinator.webView = nil
    }
    @MainActor final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        weak var webView: WKWebView?
        weak var model: ChatViewModel?
        var onPage: ((Int) -> Void)?
        var onRetry: (() -> Void)?
        var onResearchLink: ((URL) -> Void)?
        var workspaceMode = false
        var onPrompt: ((String) -> Void)?
        var ready = false
        private var evaluating = false
        private var pending = false
        private var sent: [UUID: String] = [:]
        private var firstID: UUID?
        private var lastRevision = -1
        func requestUpdate() {
            pending = true
            guard ready, !evaluating, let webView, let model else { return }
            pending = false
            guard lastRevision != model.revision else { return }
            let reset = firstID != model.messages.first?.id
            if reset { sent.removeAll(); firstID = model.messages.first?.id }
            var updates: [[String: Any]] = []
            for message in model.messages {
                var details: [String] = []
                if let usage = message.usage { details.append("Input \(usage.promptTokens.formatted()) · Output \(usage.completionTokens.formatted()) tokens") }
                if let cost = message.costUSD { details.append(String(format: "Estimated $%.4f (Excludes tool costs)", cost)) }
                if let activities = message.activities { details += activities }
                let detail = details.joined(separator: "\n")
                let stamp = message.text + "\u{0}" + (message.status ?? "") + detail + String(message.streaming)
                if sent[message.id] == stamp { continue }
                var item: [String: Any] = ["id": message.id.uuidString, "role": message.role, "text": message.text,
                                           "streaming": message.streaming, "status": message.status ?? "", "details": detail,
                                           "model": message.model ?? "", "mode": workspaceMode ? "" : (message.inputMode == "text" ? "PDFKit Text" : "PDF File")]
                if let quote = message.quote { item["quote"] = ["text": quote.text, "page": quote.page] }
                if sent[message.id] == nil { item["images"] = message.images.map(\.dataURL) }
                updates.append(item); sent[message.id] = stamp
            }
            let payload: [String: Any] = ["workspace": workspaceMode, "revision": model.revision, "reset": reset, "order": model.messages.map { $0.id.uuidString }, "updates": updates]
            guard let bytes = try? JSONSerialization.data(withJSONObject: payload), let json = String(data: bytes, encoding: .utf8) else { return }
            lastRevision = model.revision
            evaluating = true
            webView.evaluateJavaScript("applyUpdate(\(json))") { [weak self] _, error in
                guard let self else { return }
                self.evaluating = false
                if error != nil { self.lastRevision = -1; self.sent.removeAll() }
                if self.pending { self.requestUpdate() }
            }
        }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "ready" { ready = true; requestUpdate(); return }
            guard let action = message.body as? [String: String], let model else { return }
            switch action["type"] {
            case "copy":
                if let id = action["id"] {
                    var success = false
                    if let message = model.messages.first(where: { $0.id.uuidString == id }) {
                        NSPasteboard.general.clearContents()
                        success = NSPasteboard.general.setString(message.text, forType: .string)
                    }
                    webView?.callAsyncJavaScript("window.copyResult(id, success)",
                        arguments: ["id": id, "success": success], in: nil, in: .page) { _ in }
                }
            case "prompt":
                let text = action["text"] ?? ""
                if let onPrompt { onPrompt(text) } else { model.inputText = text }
            case "retry": if model.messages.last?.id.uuidString == action["id"] { onRetry?() }
            case "link":
                guard let address = action["url"], let url = URL(string: address) else { return }
                if url.scheme == "pdfchat", url.host == "page", let page = Int(url.lastPathComponent), page > 0 { onPage?(page) }
                else if url.scheme == "researchos" { onResearchLink?(url) }
                else if ["https", "http", "mailto"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
            default: break
            }
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(navigationAction.request.url?.isFileURL == true ? .allow : .cancel)
        }
    }
}
