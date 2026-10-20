import SwiftUI
import AppKit

/// 多行Input框: Enter 发送、Shift+Enter New line, 并支持粘贴/拖拽图片.
/// 由 NSScrollView 承载并铺满整个Input矩形: 点击、滚动、Text边界即整个矩形, 
/// 无背景、无边框、无聚焦环, 面板内不存在任何内层视图.
struct ChatInputTextView: NSViewRepresentable {
    @Binding var text: String
    var topInset: CGFloat = 12
    var onSend: () -> Void
    var onPasteImage: (NSImage) -> Void
    var onTextChange: () -> Void
    var onHeightChange: (CGFloat) -> Void = { _ in }
    var focusObject: AnyObject? = nil

    func makeNSView(context: Context) -> NSScrollView {
        let tv = SendableTextView()
        tv.font = .systemFont(ofSize: 14)
        tv.isRichText = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.textColor = .labelColor
        // 背景透明 + 无聚焦环: 不绘制任何自身的矩形
        tv.drawsBackground = false
        tv.backgroundColor = .clear
        tv.focusRingType = .none
        tv.isEditable = true
        tv.isSelectable = true
        tv.allowsUndo = true
        // 加大内边距: 光标起始位置离边缘更远; 顶部由 topInset 动态控制
        tv.textContainerInset = NSSize(width: 8, height: topInset)
        tv.textContainer?.widthTracksTextView = true
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.delegate = context.coordinator
        context.coordinator.textView = tv
        context.coordinator.observeFocus()
        tv.onSend = onSend
        tv.onPasteImage = onPasteImage

        // 滚动容器: Text超过面板High度时在矩形内部滚动, 而不是溢出裁剪
        let scroll = NSScrollView()
        scroll.documentView = tv
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = nsView.documentView as? SendableTextView else { return }
        // macOS 27 重构了 NSTextView 内部机制: Input法组字期间对文本的任何外部
        // rewrite都会重置Input法会话 (候选窗只剩最后一个按键、无法上屏), 组字Medium绝不回写
        if tv.string != text && !tv.hasMarkedText() {
            tv.string = text
        }
        // 顶部内边距随悬浮图片行的有无动态变化
        if tv.textContainerInset.height != topInset {
            tv.textContainerInset.height = topInset
        }
        tv.onSend = onSend
        tv.onPasteImage = onPasteImage
        context.coordinator.measure()
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatInputTextView
        weak var textView: NSTextView?
        var focusObserver: NSObjectProtocol?
        var lastHeight: CGFloat = 0
        deinit { if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) } }
        func observeFocus() {
            focusObserver = NotificationCenter.default.addObserver(forName: .pdfChatFocusInput, object: nil, queue: .main) { [weak self] note in
                guard let self, note.object as AnyObject? === self.parent.focusObject else { return }
                self.textView?.window?.makeFirstResponder(self.textView)
            }
        }
        func measure() {
            guard let tv = textView, let layout = tv.layoutManager, let container = tv.textContainer else { return }
            layout.ensureLayout(for: container)
            let height = ceil(layout.usedRect(for: container).height + 24)
            guard height != lastHeight else { return }
            lastHeight = height
            DispatchQueue.main.async { [weak self] in self?.parent.onHeightChange(height) }
        }
        init(_ parent: ChatInputTextView) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            // 组字期间不同步到 SwiftUI Status: 避免每个按键触发重渲染, 
            // 进而避免 updateNSView 在组字Medium触碰文本; 上屏后一次性同步
            guard !tv.hasMarkedText() else { return }
            parent.text = tv.string
            parent.onTextChange()
            measure()
        }
    }
}

/// Custom NSTextView: 拦截 Return 与 Cmd+V 粘贴图片.
final class SendableTextView: NSTextView {
    // Chat drafts are not PDF edits. Keep their undo registrations out of NSDocument.
    private let draftUndoManager = UndoManager()
    override var undoManager: UndoManager? { draftUndoManager }
    var onSend: () -> Void = {}
    var onPasteImage: (NSImage) -> Void = { _ in }

    // 不重写 keyDown: Enter 在文本系统内部 (doCommandBy)拦截, 位于Input法之后, 
    // 组字Medium按 Return 会先交给Input法上屏, 天然不会触发发送.
    override func doCommand(by selector: Selector) {
        if selector == #selector(insertNewline(_:)) {
            if (NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags).contains(.shift) {
                super.doCommand(by: selector) // New line
            } else {
                onSend()
            }
            return
        }
        super.doCommand(by: selector)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Handle selected draft text before menu/PDF responder-chain shortcuts.
        // Let the input method own deletion while composing marked text.
        if window?.firstResponder === self, event.type == .keyDown,
           event.keyCode == 51 || event.keyCode == 117,
           event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           !hasMarkedText(), selectedRange().length > 0 {
            insertText("", replacementRange: selectedRange())
            return true
        }
        if event.type == .keyDown, event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "z" {
            breakUndoCoalescing()
            if event.modifierFlags.contains(.shift) { draftUndoManager.redo() }
            else { draftUndoManager.undo() }
            return true
        }
        if event.type == .keyDown,
           event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers == "v" {
            if let img = ImageCoding.imageFromPasteboard() {
                onPasteImage(img)
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}
