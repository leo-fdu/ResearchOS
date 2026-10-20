import AppKit
import PDFKit
import SwiftUI
import WidgetKit

struct Row: Identifiable {
  var raw: [String: Any]
  var id: String {
    if let id = raw["id"] { return String(describing: id) }
    return string("key")
  }
  func string(_ key: String) -> String { raw[key] as? String ?? "" }
  func int(_ key: String) -> Int { raw[key] as? Int ?? 0 }
  var title: String { string("title").isEmpty ? string("name") : string("title") }
  var data: [String: Any] { raw["data"] as? [String: Any] ?? [:] }
}

func workspaceDate(_ value: String) -> String {
  let parser = ISO8601DateFormatter()
  parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  guard let date = parser.date(from: value) else { return String(value.prefix(10)) }
  let formatter = DateFormatter()
  formatter.locale = Locale(identifier: "en_US")
  formatter.dateStyle = .medium
  formatter.timeStyle = .none
  return formatter.string(from: date)
}

@MainActor final class WorkspaceModel: ObservableObject {
  @Published var objects: [Row] = []
  @Published var documents: [Row] = []
  @Published var documentCount = 0
  @Published var roots: [Row] = []
  @Published var sessions: [Row] = []
  @Published var jobs: [Row] = []
  @Published var edges: [Row] = []
  @Published var searchResults: [Row] = []
  @Published var approvals: [Row] = []
  @Published var activities: [Row] = []
  @Published var selectedSection = "home"
  @Published var project = ""
  @Published var selected: Row?
  @Published var sessionID = ""
  @Published var attached: [String] = []
  @Published var input = ""
  @Published var model = ""
  @Published var models: [Row] = []
  @Published var connection = "Not connected"
  @Published var busy = false
  @Published var canSteer = false
  @Published var sending = false
  @Published var ready = false
  @Published var error: String?
  @Published var notice: String?
  @Published var showAssistant = true
  @Published var showNavigation = true
  @Published var effort = UserDefaults.standard.string(forKey: "ros.effort") ?? ""
  @Published var remember = true
  @Published var execution = false
  @Published var webSearch = UserDefaults.standard.object(forKey: "ros.web-search") as? Bool ?? true {
    didSet { UserDefaults.standard.set(webSearch, forKey: "ros.web-search") }
  }
  @Published var query = ""
  @Published var editorText = ""
  @Published var editorHash = ""
  @Published var editingFile = false
  @Published var showComposer = false
  @Published var composeKind = "idea"
  @Published var editRecord: Row?
  @Published var startupError = ""
  @Published var showSetup = false
  @Published var installingCodex = false
  @Published var setupMessage = ""
  @Published var codexAvailable = false
  @Published var widgetStatus = "Waiting for workspace snapshot"
  @Published var desktopWidget = UserDefaults.standard.bool(forKey: "ros.desktop-widget")
  var openWorkspace: (() -> Void)?
  func setDesktopWidget(_ value: Bool) {
    desktopWidget = value; UserDefaults.standard.set(value, forKey: "ros.desktop-widget")
    if value { DesktopFocusController.shared.show(model: self) } else { DesktopFocusController.shared.hide() }
  }
  let chat = ChatViewModel()
  let pdf = PDFContextStore()
  var baseURL = ""
  private var token = ""
  private var service: Process?
  private var polling: Task<Void, Never>?
  private var transcriptStamp = ""
  private var selectionGeneration = UUID()
  private var starting = false
  private var widgetBytes: Data?
  static let dataDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
    "Library/Application Support/Research OS 2")
  init() {
    model = UserDefaults.standard.string(forKey: "ros.model") ?? ""
    remember = UserDefaults.standard.object(forKey: "ros.remember") as? Bool ?? true
    pdf.onAsk = { [weak self] prompt in
      self?.showAssistant = true
      if !prompt.isEmpty { self?.input = prompt }
    }
  }
  func start() async {
    guard !ready, !starting else { return }
    starting = true; startupError = ""
    defer { starting = false }
    do {
      let fm = FileManager.default
      let isNewWorkspace = !fm.fileExists(atPath: Self.dataDirectory.appendingPathComponent("workspace.sqlite3").path)
      try fm.createDirectory(at: Self.dataDirectory, withIntermediateDirectories: true)
      let readyFile = Self.dataDirectory.appendingPathComponent(
        "connection-\(UUID().uuidString).json")
      guard let resources = Bundle.main.resourceURL else { throw failure("Application resources are missing") }
      let source = resources.appendingPathComponent("service")
      let candidates = [
        ProcessInfo.processInfo.environment["RESEARCHOS_PYTHON"],
        resources.appendingPathComponent("python/bin/python3").path,
        Self.dataDirectory.appendingPathComponent("runtime/bin/python3").path,
        "/opt/homebrew/Caskroom/miniforge/base/bin/python", "/opt/homebrew/bin/python3",
        "/usr/local/bin/python3", "/usr/bin/python3",
      ].compactMap { $0 }
      guard let python = candidates.first(where: { fm.isExecutableFile(atPath: $0) }) else {
        throw failure("Python was not found. Run the included Install Dependencies.command.")
      }
      let process = Process()
      process.executableURL = URL(fileURLWithPath: python)
      process.arguments = [
        "-S", source.appendingPathComponent("launch.py").path, "--data-dir", Self.dataDirectory.path, "--ready", readyFile.path,
      ]
      process.currentDirectoryURL = source
      var environment = ProcessInfo.processInfo.environment
      environment["PATH"] =
        "/opt/homebrew/bin:/usr/local/bin:" + Self.dataDirectory.appendingPathComponent("bin").path + ":" + fm.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path + ":/opt/homebrew/Caskroom/miniforge/base/bin:/usr/bin:/bin:/usr/sbin:/sbin"
      environment.removeValue(forKey: "PYTHONHOME")
      environment.removeValue(forKey: "PYTHONPATH")
      environment["PYTHONUNBUFFERED"] = "1"
      environment["PYTHONDONTWRITEBYTECODE"] = "1"
      process.environment = environment
      let log = Self.dataDirectory.appendingPathComponent("server.log")
      if let size = try? fm.attributesOfItem(atPath: log.path)[.size] as? NSNumber, size.intValue > 5_000_000 { try? fm.moveItem(at: log, to: Self.dataDirectory.appendingPathComponent("server-previous.log")) }
      if !fm.fileExists(atPath: log.path) { fm.createFile(atPath: log.path, contents: nil) }
      let handle = try FileHandle(forWritingTo: log)
      try handle.seekToEnd()
      process.standardOutput = handle
      process.standardError = handle
      try process.run()
      service = process
      for _ in 0..<150 {
        if let bytes = try? Data(contentsOf: readyFile),
          let info = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        {
          baseURL = info["url"] as? String ?? ""
          token = info["token"] as? String ?? ""
          try? fm.removeItem(at: readyFile)
          ready = true
          break
        }
        if !process.isRunning { throw failure("Local service failed to start. Log: \(log.path)") }
        try await Task.sleep(nanoseconds: 100_000_000)
      }
      guard ready else { throw failure("Local service startup timed out") }
      await refresh()
      if isNewWorkspace { showSetup = true }
      writeWidgetSnapshot()
      if desktopWidget { DesktopFocusController.shared.show(model: self) }
      Task { await connectAgent(silent: true) }
      polling = Task { [weak self] in
        var tick = 0
        while !Task.isCancelled {
          try? await Task.sleep(nanoseconds: 900_000_000)
          guard let self, !Task.isCancelled else { return }
          await self.refreshChat()
          tick += 1
          if tick % 5 == 0 {
            await self.refresh(silent: true)
            self.writeWidgetSnapshot()
          }
        }
      }
    } catch { if service?.isRunning == true { service?.terminate() }; startupError = error.localizedDescription }
  }
  func shutdown() {
    polling?.cancel()
    service?.terminate()
  }
  func failure(_ text: String) -> NSError {
    NSError(domain: "ResearchOS", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
  }
  func request(_ path: String, body: [String: Any]? = nil) async throws -> Any {
    guard let url = URL(string: baseURL + path) else { throw failure("Invalid service address") }
    var request = URLRequest(url: url)
    request.timeoutInterval = 120
    request.setValue(token, forHTTPHeaderField: "X-ResearchOS-Token")
    if let body {
      request.httpMethod = "POST"
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    let (data, response) = try await URLSession.shared.data(for: request)
    let result = try JSONSerialization.jsonObject(with: data)
    guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode)
    else { throw failure((result as? [String: Any])?["error"] as? String ?? "Request failed") }
    return result
  }
  func rows(_ value: Any?) -> [Row] { (value as? [[String: Any]] ?? []).map { Row(raw: $0) } }
  func refresh(silent: Bool = false) async {
    do {
      guard let state = try await request("/v2/state") as? [String: Any] else { return }
      objects = rows(state["objects"])
      documents = rows(state["documents"])
      documentCount = (state["counts"] as? [String: Any])?["available"] as? Int ?? documents.count
      roots = rows(state["roots"])
      sessions = rows(state["sessions"])
      jobs = rows(state["jobs"])
      edges = rows(state["edges"])
      if let current = selected, current.string("kind") != "pdf",
        let updated = objects.first(where: { $0.id == current.id })
      {
        selected = updated
      }
    } catch { if !silent { self.error = error.localizedDescription } }
  }
  func connectAgent(silent: Bool = false) async {
    connection = "Connecting to Codex…"
    do {
      let result = try await request("/v2/agent") as? [String: Any] ?? [:]
      codexAvailable = true
      models = rows(result["models"])
      if model.isEmpty {
        model =
          models.first(where: { $0.raw["isDefault"] as? Bool == true })?.id ?? models.first?.id
          ?? ""
      }
      normalizeEffort()
      connection = result["connected"] as? Bool == true ? "Codex connected · ChatGPT" : "Sign in to ChatGPT"
    } catch {
      connection = "Codex is not ready"
      setupMessage = error.localizedDescription
      if !silent { self.error = error.localizedDescription }
    }
  }
  func login() async {
    do {
      let data = try await request("/v2/login", body: [:]) as? [String: Any]
      if let address = data?["authUrl"] as? String, let url = URL(string: address) {
        NSWorkspace.shared.open(url)
        notice = "Complete sign-in in your browser, then click Reconnect."
      }
    } catch { self.error = error.localizedDescription }
  }
  func search() async {
    let expected = query
    do {
      var components = URLComponents()
      components.queryItems = [
        URLQueryItem(name: "q", value: query), URLQueryItem(name: "project", value: project),
      ]
      let found = rows(try await request("/v2/search" + (components.string ?? "")))
      if expected == query { searchResults = found }
    } catch { self.error = error.localizedDescription }
  }
  var supportedEfforts: [String] {
    let selectedModel = models.first { $0.id == model }
    return (selectedModel?.raw["supportedReasoningEfforts"] as? [[String: Any]] ?? []).compactMap { $0["reasoningEffort"] as? String }
  }
  var defaultEffort: String { models.first { $0.id == model }?.string("defaultReasoningEffort") ?? "" }
  func normalizeEffort() {
    if !supportedEfforts.contains(effort) { effort = supportedEfforts.contains(defaultEffort) ? defaultEffort : supportedEfforts.first ?? "" }
  }
  func deleteDiscussion(_ id: String) async {
    do {
      _ = try await request("/v2/delete-session", body: ["id": id])
      if sessionID == id { newChat() }
      await refresh()
    } catch { self.error = error.localizedDescription }
  }
  func newChat() {
    sessionID = ""
    chat.messages = []
    chat.revision += 1
    transcriptStamp = ""
    busy = false
    canSteer = false
    approvals = []
    activities = []
    attached = selected?.string("kind") == "pdf" ? [selected!.id] : []
    pdf.quote = nil
    showAssistant = true
  }
  func openSession(_ id: String) async {
    sessionID = id
    canSteer = false
    transcriptStamp = ""
    showAssistant = true
    await refreshChat(restoreAttachments: true)
  }
  func openPaperSession(_ id: String, paper: Row) async {
    await openSession(id)
    guard sessionID == id else { return }
    if !attached.contains(paper.id) { attached.append(paper.id) }
    pdf.quote = nil
  }
  func send() async {
    guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !sending, !busy || canSteer else {
      return
    }
    sending = true
    defer { sending = false }
    let draft = input
    let originalSession = sessionID
    let quote = pdf.quote
    do {
      if sessionID.isEmpty {
        let result =
          try await request("/v2/session", body: ["project_id": project, "model": model])
          as? [String: Any] ?? [:]
        guard sessionID == originalSession else { return }
        sessionID = result["id"] as? String ?? ""
      }
      let targetSession = sessionID
      var text = draft
      if let quote {
        text = "Quote from PDF page  \(quote.page) : \n\(quote.text)\n\n" + text
      }
      if let selected, objects.contains(where: { $0.id == selected.id }) {
        text = "Current research record ID: \(selected.id)\n\n" + text
      }
      _ = try await request(
        "/v2/turn",
        body: [
          "session_id": targetSession, "text": text, "documents": attached, "model": model,
          "memory": remember, "execution": execution, "effort": effort, "web_search": webSearch,
        ])
      guard sessionID == targetSession else { return }
      if input == draft { input = ""; pdf.quote = nil }
      busy = true
      UserDefaults.standard.set(model, forKey: "ros.model")
      UserDefaults.standard.set(effort, forKey: "ros.effort")
      UserDefaults.standard.set(remember, forKey: "ros.remember")
      await refreshChat()
      await refresh(silent: true)
    } catch {
      self.error = error.localizedDescription
      if sessionID == originalSession { await refreshChat() }
    }
  }
  func refreshChat(restoreAttachments: Bool = false) async {
    guard !sessionID.isEmpty else { return }
    let id = sessionID
    do {
      let data = try await request("/v2/session?id=" + id) as? [String: Any] ?? [:]
      guard id == sessionID else { return }
      if restoreAttachments {
        attached = data["documents"] as? [String] ?? []
        pdf.quote = nil
      }
      let messages = rows(data["messages"])
      let signature = messages.map { $0.id + $0.string("text") + $0.string("status") }.joined()
      if signature != transcriptStamp {
        chat.messages = messages.map { row in
          let stable =
            UUID(uuidString: row.id) ?? UUID(uuidString: Self.uuidString(row.id)) ?? UUID()
          return ChatMessage(
            id: stable, role: row.string("role"), text: row.string("text"), images: [],
            streaming: row.string("status") == "streaming", model: model,
            status: ["failed": "error", "interrupted": "stopped"][row.string("status")] ?? row.string("status"))
        }
        chat.revision += 1
        transcriptStamp = signature
      }
      busy = (data["session"] as? [String: Any])?["status"] as? String == "running"
      canSteer = data["can_steer"] as? Bool ?? false
      activities = rows(data["events"])
      approvals = rows(data["approvals"])
    } catch { if busy { self.error = error.localizedDescription } }
  }
  static func uuidString(_ id: String) -> String {
    guard id.count == 32 else { return id }
    let a = Array(id)
    return String(a[0..<8]) + "-" + String(a[8..<12]) + "-" + String(a[12..<16]) + "-"
      + String(a[16..<20]) + "-" + String(a[20..<32])
  }
  func perform(_ path: String, _ data: [String: Any], success: String? = nil) async {
    do {
      _ = try await request(path, body: data)
      notice = success
      await refresh()
      await refreshChat()
    } catch { self.error = error.localizedDescription }
  }
  func select(_ row: Row, page: Int? = nil) async {
    if roots.contains(where: { $0.id == row.id }) { selected = nil; selectedSection = row.string("kind") == "notes" ? "note" : row.string("kind"); return }
    if row.string("source_type") == "session" { await openSession(row.id); return }
    selected = row
    editingFile = false
    editorText = ""
    selectionGeneration = UUID()
    let gen = selectionGeneration
    guard documents.contains(where: { $0.id == row.id }) || row.string("source_type") == "document" || !row.string("root_id").isEmpty
    else { return }
    do {
      let d = try await request("/v2/document?id=" + row.id) as? [String: Any] ?? [:]
      guard selectionGeneration == gen else { return }
      let document = Row(raw: d)
      selected = document
      if document.string("kind") == "pdf" {
        let url = URL(fileURLWithPath: document.string("path"))
        guard let doc = PDFDocument(url: url) else { throw failure("PDF could not be opened") }
        pdf.recordPosition()
        pdf.load(document: doc, url: url)
        pdf.setIdentity(document.string("hash"))
        if let page { pdf.goToPage(page) }
        if !attached.contains(row.id) { attached.append(row.id) }
      } else {
        editorText = document.string("body")
        editorHash = document.string("current_hash")
      }
    } catch { self.error = error.localizedDescription }
  }
  func handleLink(_ url: URL) {
    if url.host == "session" {
      Task { await openSession(url.lastPathComponent) }
    } else if url.host == "document" {
      let id = url.lastPathComponent
      let page = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: {
        $0.name == "page"
      })?.value.flatMap(Int.init)
      Task {
        if let row = documents.first(where: { $0.id == id }) { await select(row, page: page) }
        else { do { let d = try await request("/v2/document?id=" + id) as? [String: Any] ?? [:]; await select(Row(raw: d), page: page) } catch { self.error = error.localizedDescription } }
      }
    } else if url.host == "object" {
      if let row = objects.first(where: { $0.id == url.lastPathComponent }) { selected = row }
    } else if url.host == "quick" {
      composeKind = "idea"
      editRecord = nil
      showComposer = true
    }
  }
  func exportWorkspace() async {
    do {
      let data = try JSONSerialization.data(withJSONObject: await request("/v2/export"), options: [.prettyPrinted, .sortedKeys])
      let panel = NSSavePanel(); panel.nameFieldStringValue = "ResearchOS-workspace.json"
      if panel.runModal() == .OK, let url = panel.url { try data.write(to: url, options: .atomic); notice = "Workspace exported" }
    } catch { self.error = error.localizedDescription }
  }
  func attachDirectory(kind: String) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = true
    panel.message = "Connect a \(kind == "papers" ? "paper library (the parent of the PaperMind pdf/ folder)" : "resource folder"). Original files stay in place."
    if panel.runModal() == .OK {
      let paths = panel.urls.map(\.path)
      Task {
        for path in paths {
          await perform("/v2/root", ["path": path, "kind": kind, "project_id": project])
        }
      }
    }
  }
  func compose(_ kind: String, row: Row? = nil) {
    composeKind = kind
    editRecord = row
    showComposer = true
  }
  func writeWidgetSnapshot() {
    guard
      let directory = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: "group.com.niqi.researchos")
    else { return }
    let source = Self.dataDirectory.appendingPathComponent("widget.json")
    if let bytes = try? Data(contentsOf: source), bytes != widgetBytes {
      do {
        try bytes.write(to: directory.appendingPathComponent("widget.json"), options: .atomic)
        widgetBytes = bytes; widgetStatus = "Desktop snapshot updated"
        WidgetCenter.shared.reloadTimelines(ofKind: "ResearchOSFocus")
      } catch { widgetBytes = bytes; widgetStatus = "WidgetKit sharing is unavailable with this local signature. Use the desktop card above." }
    }
  }
}
