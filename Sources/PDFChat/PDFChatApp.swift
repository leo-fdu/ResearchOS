import SwiftUI

private struct ChatViewModelKey: FocusedValueKey { typealias Value = ChatViewModel }
private struct OpenFilePickerKey: FocusedValueKey { typealias Value = () -> Void }
extension FocusedValues {
  var pdfChatViewModel: ChatViewModel? {
    get { self[ChatViewModelKey.self] }
    set { self[ChatViewModelKey.self] = newValue }
  }
  var pdfChatOpenPicker: (() -> Void)? {
    get { self[OpenFilePickerKey.self] }
    set { self[OpenFilePickerKey.self] = newValue }
  }
}
@main
struct PDFChatApp: App {
  @NSApplicationDelegateAdaptor(ReaderAppDelegate.self) private var appDelegate
  @StateObject private var workspace = WorkspaceModel()
  @AppStorage("ros.show-menu-bar") private var showMenuBar = false
  @Environment(\.openWindow) private var openWindow
  @FocusedValue(\.pdfChatViewModel) private var chatVM
  @FocusedValue(\.pdfChatOpenPicker) private var openPicker
  var body: some Scene {
    WindowGroup("Research OS", id: "workspace") {
      EdgeToEdgeWorkspace(model: workspace).ignoresSafeArea().preferredColorScheme(.light)
        .onOpenURL { workspace.handleLink($0) }.onAppear {
        ReaderAppDelegate.workspace = workspace
        workspace.openWorkspace = { openWindow(id: "workspace"); NSApp.activate(ignoringOtherApps: true) }
        if let path = Bundle.main.path(forResource: "ResearchOSBlue", ofType: "icns") { NSApp.applicationIconImage = NSImage(contentsOfFile: path) }
      }
    }.defaultSize(width: 1480, height: 920)
      .windowStyle(.hiddenTitleBar)
      .windowToolbarStyle(.unifiedCompact)
      .commands {
        CommandGroup(replacing: .appInfo) {
          Button("About Research OS") {
            var options: [NSApplication.AboutPanelOptionKey: Any] = [:]
            if let path = Bundle.main.path(forResource: "ResearchOSBlue", ofType: "icns"),
               let icon = NSImage(contentsOfFile: path) { options[.applicationIcon] = icon }
            NSApp.orderFrontStandardAboutPanel(options: options)
          }
        }
        CommandMenu("Research workspace") {
          Button("New discussion") { workspace.newChat() }.keyboardShortcut("n", modifiers: .command)
          Button("Quick capture Idea") { workspace.compose("idea") }.keyboardShortcut(
            "i", modifiers: [.command, .shift])
          Button("Search") {
            workspace.selectedSection = "search"
            workspace.selected = nil
          }.keyboardShortcut("k", modifiers: .command)
          Divider()
          Button(workspace.desktopWidget ? "Hide desktop research card" : "Show desktop research card") { workspace.setDesktopWidget(!workspace.desktopWidget) }
          Button("Open API reader") { openWindow(id: "api-reader") }
        }
      }
    MenuBarExtra("Research OS", systemImage: "sparkle.magnifyingglass", isInserted: Binding(
      get: { showMenuBar },
      set: { value in if showMenuBar != value { showMenuBar = value } }
    )) {
      Button("Open workspace") {
        openWindow(id: "workspace")
        NSApp.activate(ignoringOtherApps: true)
      }
      Button("Capture Idea") {
        openWindow(id: "workspace")
        workspace.compose("idea")
        NSApp.activate(ignoringOtherApps: true)
      }
      Button(workspace.desktopWidget ? "Hide desktop card" : "Show desktop card") { workspace.setDesktopWidget(!workspace.desktopWidget) }
      Divider()
      ForEach(
        workspace.objects.filter { $0.string("kind") == "task" && $0.string("status") != "done" }
          .prefix(5)
      ) { row in
        Button(row.title) {
          workspace.selected = row
          openWindow(id: "workspace")
        }
      }
      Divider()
      Button("Hide menu bar icon") { showMenuBar = false }
      Button("Quit Research OS") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
    DocumentGroup(viewing: PDFFileDocument.self) { file in
      ContentView(pdfDoc: file.$document.pdfDocument, fileURL: file.fileURL)
        .tint(Color(red: 0.34, green: 0.39, blue: 0.82))
    }
    .defaultSize(width: 1220, height: 820)
    .commands { commands }
    WindowGroup("API Reader", id: "api-reader") {
      ContentView(pdfDoc: .constant(nil)).tint(Color(red: 0.34, green: 0.39, blue: 0.82))
    }.defaultSize(width: 1220, height: 820)
    Settings { SettingsView() }
  }
  @CommandsBuilder private var commands: some Commands {
    CommandGroup(replacing: .newItem) {
      Button("New conversation") { chatVM?.newConversation() }.keyboardShortcut("n", modifiers: .command)
        .disabled(chatVM == nil)
      Button("Open PDF…") { openPicker?() }.keyboardShortcut("o", modifiers: .command)
    }
  }
}

@MainActor final class ReaderAppDelegate: NSObject, NSApplicationDelegate {
  static weak var workspace: WorkspaceModel?
  static weak var workspaceWindow: NSWindow?

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    // Dock activation must target the research workspace even if a reader or
    // floating desktop card is still visible. Reuse a retained window first.
    if let window = Self.workspaceWindow {
      if window.isMiniaturized { window.deminiaturize(nil) }
      window.makeKeyAndOrderFront(nil)
      sender.activate(ignoringOtherApps: true)
      return false
    }
    if let reopen = Self.workspace?.openWorkspace {
      reopen()
      return false
    }
    return true
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    Self.workspace?.shutdown()
    for model in ChatViewModel.liveModels.allObjects { model.stop() }
    Task {
      await HistoryDiskWriter.shared.flush()
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
}
