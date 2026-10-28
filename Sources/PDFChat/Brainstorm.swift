import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct BrainstormMemberDraft: Identifiable {
  var id = UUID()
  var name = ""
  var runtime = "pi"
  var provider = ""
  var model = ""
  var effort = ""
  var levels: [String] = []
  var payload: [String: Any] { ["model_name": name, "name": name, "runtime": runtime, "provider": provider, "model": model, "effort": effort] }
}

@MainActor final class BrainstormModel: ObservableObject {
  weak var workspace: WorkspaceModel?
  @Published var rooms: [Row] = []
  @Published var showDeleted = false
  var drafts: [String: String] = [:]
  @Published var detail: Row?
  @Published var entries: [Row] = []
  @Published var files: [Row] = []
  @Published var catalogs: [String: [Row]] = [:]
  @Published var loadingCatalog: Set<String> = []
  @Published var error = ""
  @Published var pending = false
  @Published var selectedID = ""
  var members: [Row] { (detail?.raw["members"] as? [[String: Any]] ?? []).map { Row(raw: $0) } }
  func deliveryLabel(_ value: String?) -> String {
    switch value {
    case "included_in_turn": return "Included in turn"
    case "sent_to_running_agent": return "Sent to running member"
    default: return "Queued for next turn"
    }
  }
  func progressPreview(_ text: String) -> String {
    let pattern = #""summary"\s*:\s*"((?:[^"\\]|\\.)*)"#
    if let regex = try? NSRegularExpression(pattern: pattern),
       let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
       let range = Range(match.range(at: 1), in: text) {
      let captured = String(text[range])
      if let data = ("\"" + captured + "\"").data(using: .utf8),
         let decoded = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? String { return decoded }
      return captured
    }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
  }
  func modelName(_ member: Row) -> String {
    let key = member.string("model")
    return member.string("model_name").isEmpty ? key : member.string("model_name")
  }
  func name(_ id: String) -> String {
    guard let member = members.first(where: { $0.id == id }) else { return id }
    return modelName(member)
  }
  func query(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+&=#"))) ?? "" }
  func load() async {
    guard let workspace else { return }
    do {
      let loadedRooms = (try await workspace.request("/v2/brainstorm/rooms" + (showDeleted ? "?deleted=1" : ""))) as? [[String: Any]] ?? []
      if !NSArray(array: rooms.map(\.raw)).isEqual(to: loadedRooms) { rooms = loadedRooms.map { Row(raw: $0) } }
      if !selectedID.isEmpty { await select(selectedID) }
    } catch { self.error = error.localizedDescription }
  }
  func select(_ id: String) async {
    guard let workspace else { return }
    selectedID = id
    if id.isEmpty { detail = nil; entries = []; files = []; return }
    do {
      let value = try await workspace.request("/v2/brainstorm/room?id=" + query(id)) as? [String: Any] ?? [:]
      guard selectedID == id else { return }
      // Polling unchanged rooms must not invalidate the transcript every two seconds.
      if !NSDictionary(dictionary: detail?.raw ?? [:]).isEqual(to: value) { detail = Row(raw: value) }
      let loadedEntries = value["entries"] as? [[String: Any]] ?? []
      if !NSArray(array: entries.map(\.raw)).isEqual(to: loadedEntries) { entries = loadedEntries.map { Row(raw: $0) } }
      let loadedFiles = ((try await workspace.request("/v2/brainstorm/files?id=" + query(id))) as? [[String: Any]] ?? []).map { Row(raw: $0) }
      if selectedID == id, !NSArray(array: files.map(\.raw)).isEqual(to: loadedFiles.map(\.raw)) { files = loadedFiles }
    } catch { self.error = error.localizedDescription }
  }
  func catalog(_ runtime: String) async {
    guard let workspace, !loadingCatalog.contains(runtime) else { return }
    loadingCatalog.insert(runtime)
    defer { loadingCatalog.remove(runtime) }
    do {
      let value = try await workspace.request("/v2/brainstorm/catalog?runtime=" + runtime) as? [String: Any] ?? [:]
      catalogs[runtime] = (value["models"] as? [[String: Any]] ?? []).map { Row(raw: $0) }
    } catch { self.error = runtime + ": " + error.localizedDescription }
  }
  func levels(_ member: BrainstormMemberDraft) async -> [String] {
    if member.runtime == "codex" { if catalogs["codex"] == nil { await catalog("codex") }; return catalogs["codex"]?.first { $0.id == member.model }?.raw["levels"] as? [String] ?? [] }
    guard let workspace, !member.model.isEmpty else { return [] }
    do {
      let value = try await workspace.request("/v2/brainstorm/catalog?runtime=pi&provider=\(query(member.provider))&model=\(query(member.model))") as? [String: Any] ?? [:]
      return value["levels"] as? [String] ?? []
    } catch { self.error = error.localizedDescription; return [] }
  }
  @discardableResult func post(_ endpoint: String, _ body: [String: Any]) async -> Bool {
    guard let workspace else { return false }
    pending = true; error = ""
    defer { pending = false }
    do {
      let result = try await workspace.request("/v2/brainstorm/" + endpoint, body: body) as? [String: Any] ?? [:]
      if endpoint == "create", let id = result["id"] as? String { selectedID = id }
      if endpoint == "control", body["action"] as? String == "delete" { selectedID = ""; detail = nil; entries = [] }
      if endpoint == "save-note" { workspace.notice = "Report saved to Notes" }
      await load()
      return true
    } catch { self.error = error.localizedDescription; return false }
  }
  @discardableResult func control(_ action: String, text: String = "", target: String = "", calls: Int = 0, minutes: Int = 0) async -> Bool {
    await post("control", ["id": selectedID, "action": action, "text": text, "target": target, "calls": calls, "minutes": minutes])
  }
  func exportReport() {
    guard let text = detail?.string("report"), !text.isEmpty else { return }
    let panel = NSSavePanel(); panel.allowedContentTypes = [.plainText]; panel.nameFieldStringValue = "Brainstorm report.md"
    if panel.runModal() == .OK, let url = panel.url {
      do { try text.write(to: url, atomically: true, encoding: .utf8) } catch { self.error = error.localizedDescription }
    }
  }
}

struct BrainstormPane: View {
  @ObservedObject var workspace: WorkspaceModel
  @StateObject private var model = BrainstormModel()
  @State private var creating = false
  @State private var linkingResources = false
  @State private var tab = "discussion"
  @State private var reportDetails = false
  @State private var message = ""
  @State private var search = ""
  @State private var inputHeight: CGFloat = 48
  @State private var expanded: Set<String> = []
  @State private var addingBudget = false
  @State private var newTopic = false
  @State private var topic = ""
  @State private var topicMode = "agent_only"
  @State private var extraCalls = 6
  @State private var extraMinutes = 15
  @State private var extraRuns = 3
  init(workspace: WorkspaceModel, initialModel: BrainstormModel? = nil, initiallyExpanded: Set<String> = []) {
    self.workspace = workspace
    _model = StateObject(wrappedValue: initialModel ?? BrainstormModel())
    _expanded = State(initialValue: initiallyExpanded)
  }
  var body: some View {
    VStack(spacing: 0) {
      if !model.error.isEmpty {
        HStack { Text(model.error).foregroundStyle(.red).textSelection(.enabled); Spacer(); Button("Dismiss") { model.error = "" } }.font(.caption).padding(12)
      }
      if let room = model.detail, !model.selectedID.isEmpty {
        roomHeader(room)
        Picker("View", selection: $tab) {
          Text("Discussion").tag("discussion"); Text("Shared sources").tag("sources")
          Text("Workspace").tag("workspace"); Text("Report").tag("report")
        }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 14).padding(.bottom, 8)
        Divider()
        Group {
          switch tab {
          case "sources": sources(room)
          case "workspace": files
          case "report": report(room)
          default: discussion(room)
          }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
        intervention(room)
      } else { history }
    }
    .task {
      guard workspace.ready else { return }
      model.workspace = workspace; await model.load()
      if !workspace.brainstormSelection.isEmpty { await model.select(workspace.brainstormSelection); workspace.brainstormSelection = "" }
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        if Task.isCancelled { break }
        if workspace.selectedSection == "brainstorm" { await model.load() }
      }
    }
    .onChange(of: model.selectedID) { old, value in
      if !old.isEmpty { model.drafts[old] = message }
      message = model.drafts[value] ?? ""
    }
    .onChange(of: workspace.selectedSection) { old, value in
      if value == "brainstorm", old != value { goBack() }
    }
    .onChange(of: workspace.brainstormSelection) { _, id in
      guard !id.isEmpty else { return }
      Task { await model.select(id); workspace.brainstormSelection = "" }
    }
    .sheet(isPresented: $linkingResources) { if let room = model.detail { RelationComposer(model: workspace, source: Row(raw: ["id": room.id, "title": room.string("topic"), "kind": "brainstorm"])) } }
    .sheet(isPresented: $creating) { BrainstormComposer(model: model, projectID: workspace.project, linkedObjects: workspace.objects, isPresented: $creating) }
    .sheet(isPresented: $newTopic) {
      VStack(alignment: .leading, spacing: 18) {
        Text("Explore another topic").font(.title2)
        Text("Keep the same members, history and workspaces. Independent work starts in parallel; discussions follow the member order.").foregroundStyle(.secondary)
        TextField("What should we explore next?", text: $topic, axis: .vertical).lineLimit(3...6).textFieldStyle(.roundedBorder)
        Picker("Participation", selection: $topicMode) { Text("Agent only").tag("agent_only"); Text("Agent and user").tag("agent_and_user") }.pickerStyle(.segmented)
        Text(topicMode == "agent_only" ? "Agents discuss and prepare a report. You can follow up afterwards." : "Members first work independently, then wait for you. Each message prompts one round of responses.").font(.callout).foregroundStyle(.secondary)
        HStack { Button("Cancel") { newTopic = false }; Spacer(); Button("Start topic") {
          Task { if await model.post("control", ["id": model.selectedID, "action": "topic", "text": topic, "participation": topicMode]) { newTopic = false; topic = ""; tab = "discussion" } }
        }.buttonStyle(.borderedProminent).disabled(topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.pending) }
        Text("Uses the remaining session budget. If agents are working, this topic starts after the current stage.").font(.caption).foregroundStyle(.secondary)
      }.padding(24).frame(width: 540)
    }
    .sheet(isPresented: $addingBudget) {
      VStack(alignment: .leading, spacing: 18) {
        Text("Add session budget").font(.title2)
        Stepper("Additional member turns: \(extraCalls)", value: $extraCalls, in: 0...100)
        Stepper("Additional minutes: \(extraMinutes)", value: $extraMinutes, in: 0...120)
        Stepper("Additional script runs: \(extraRuns)", value: $extraRuns, in: 0...30)
        HStack { Button("Cancel") { addingBudget = false }; Spacer(); Button("Add budget") { Task { if await model.post("control", ["id": model.selectedID, "action": "budget", "calls": extraCalls, "minutes": extraMinutes, "runs": extraRuns]) { addingBudget = false } } }.buttonStyle(.borderedProminent) }
      }.padding(24).frame(width: 440)
    }
  }
  private func goBack() {
    model.selectedID = ""; model.detail = nil; model.entries = []; tab = "discussion"
  }
  private var history: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 5) { Text("Brainstorm").font(.largeTitle.bold()); Text("A place to think together, and keep going.").foregroundStyle(.secondary) }
        Spacer()
        Button { model.showDeleted = false; creating = true } label: { Label("Add new brainstorm", systemImage: "plus") }.buttonStyle(.borderedProminent)
      }.padding(24)
      HStack {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        TextField("Search discussions", text: $search).textFieldStyle(.plain)
        Spacer()
        Toggle("Deleted", isOn: $model.showDeleted).toggleStyle(.checkbox).onChange(of: model.showDeleted) { _, _ in Task { await model.load() } }
      }.padding(.horizontal, 24).padding(.bottom, 16)
      if model.showDeleted { Text("Deleted discussions and their workspaces are permanently removed after 30 days. Restore them before expiry to keep them.").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.bottom, 12) }
      Divider()
      ScrollView {
        LazyVStack(spacing: 0) {
          ForEach(model.rooms.filter { search.isEmpty || $0.string("topic").localizedCaseInsensitiveContains(search) }) { room in
            HStack(alignment: .top, spacing: 14) {
              Image(systemName: "bubble.left.and.bubble.right").font(.title3).foregroundStyle(Palette.accent).padding(.top, 3)
              Button {
                tab = "discussion"
                Task { await model.select(room.id) }
              } label: {
                VStack(alignment: .leading, spacing: 8) {
                  Text(room.string("topic")).font(.headline).lineLimit(2).foregroundStyle(.primary)
                  let names = (room.raw["members"] as? [[String: Any]] ?? []).map { model.modelName(Row(raw: $0)) }
                  let links = [room.string("project_id"), room.string("idea_id")].compactMap { id in workspace.objects.first { $0.id == id }?.title }
                  if !links.isEmpty { Text(links.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                  if model.showDeleted { Text("Permanently removed after " + String(room.string("purge_after").prefix(10))).font(.caption).foregroundStyle(.secondary) }
                  Text(names.joined(separator: " · ")).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                  Text(statusLabel(room.string("status")) + " · " + String(room.string("updated_at").prefix(16)).replacingOccurrences(of: "T", with: " ")).font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
              }.buttonStyle(.plain).disabled(model.showDeleted)
              if model.showDeleted {
                Button("Restore") { Task { await model.post("control", ["id": room.id, "action": "restore"]) } }
              } else {
                Button { Task { await model.post("control", ["id": room.id, "action": "delete"]) } } label: { Image(systemName: "trash") }
                  .buttonStyle(.plain).foregroundStyle(.secondary).help("Move to Deleted; restore within 30 days before permanent removal")
                  .disabled(room.string("status") == "running" || model.pending)
              }
            }.padding(22)
            Divider().padding(.leading, 24)
          }
          if model.rooms.isEmpty {
            VStack(spacing: 14) {
              Image(systemName: model.showDeleted ? "trash" : "bubble.left.and.bubble.right").font(.system(size: 38)).foregroundStyle(.tertiary)
              Text(model.showDeleted ? "No deleted discussions" : "Start with a question worth exploring.").font(.title3)
              Text("Independent ideas, shared evidence, and a conversation you can return to.").foregroundStyle(.secondary)
            }.padding(60).frame(maxWidth: .infinity)
          }
        }
      }
    }
  }
  private func statusLabel(_ status: String) -> String {
    switch status { case "waiting_user": return "Your turn"; case "completed": return "Report ready"; default: return status.capitalized }
  }
  private func settings(_ room: Row, _ values: [String: Any]) {
    Task { await model.post("control", ["id": room.id, "action": "settings"].merging(values) { _, new in new }) }
  }
  private func roomHeader(_ room: Row) -> some View {
    let config = room.raw["config"] as? [String: Any] ?? [:]
    return VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 12) {
        Button(action: goBack) { Image(systemName: "chevron.left") }.buttonStyle(.plain).help("All brainstorms").accessibilityLabel("All brainstorms")
        Text(room.string("topic")).font(.headline).lineLimit(1).textSelection(.enabled).help(room.string("topic"))
        Spacer(minLength: 8)
        Text("\(room.int("calls"))/\(config["max_calls"] as? Int ?? 0) turns").font(.caption).foregroundStyle(.secondary)
        if room.string("status") == "running" {
          ProgressView().controlSize(.mini)
          Button("Pause") { Task { await model.control("pause") } }
        } else if ["draft", "paused"].contains(room.string("status")) {
          Button(room.string("status") == "draft" ? "Start" : "Continue") { Task { await model.post("start", ["id": room.id]) } }.buttonStyle(.borderedProminent)
        } else { Text(statusLabel(room.string("status"))).font(.caption).foregroundStyle(.secondary) }
        Menu {
          if room.string("status") == "paused" {
            Text(room.string("reason"))
            Button("Retry failed") { Task { await model.control("retry") } }
          }
          Button("Link resources…") { linkingResources = true }
          Button("New topic…") { topicMode = config["participation"] as? String ?? "agent_only"; newTopic = true }
          Button("Add budget…") { addingBudget = true }.disabled(room.string("status") == "running")
          Button("Summarize now") { Task { await model.control("summarize"); tab = "report" } }
          Button("Delete discussion") { Task { await model.control("delete") } }.disabled(room.string("status") == "running")
        } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
      }.controlSize(.small)
      if !room.string("cycle_topic").isEmpty, room.string("cycle_topic") != room.string("topic") {
        Text("Now exploring: " + room.string("cycle_topic")).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(room.string("cycle_topic"))
      }
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 14) { memberControls; Spacer(minLength: 8); modeControls(room, config) }
        VStack(alignment: .leading, spacing: 6) {
          ScrollView(.horizontal, showsIndicators: false) { memberControls }
          modeControls(room, config)
        }
      }
    }.padding(.horizontal, 14).padding(.vertical, 10)
  }
  private var memberControls: some View {
    HStack(spacing: 14) { ForEach(model.members) { member in BrainstormEffortMenu(model: model, member: member) } }.fixedSize(horizontal: true, vertical: false)
  }
  private func modeControls(_ room: Row, _ config: [String: Any]) -> some View {
    HStack(spacing: 10) {
      Picker("Participation", selection: Binding(get: { config["participation"] as? String ?? "agent_only" }, set: { settings(room, ["participation": $0]) })) {
        Text("Agent only").tag("agent_only"); Text("Agent and user").tag("agent_and_user")
      }.labelsHidden().frame(width: 145)
      Toggle("Work mode", isOn: Binding(get: { config["work_mode"] as? Bool ?? false }, set: { settings(room, ["work_mode": $0]) })).toggleStyle(.switch).help("Allow scripts in the shared workspace")
    }.controlSize(.small).fixedSize()
  }
  private func discussion(_ room: Row) -> some View {
    ScrollViewReader { proxy in
      ScrollView {
        // Expanded Markdown measures asynchronously. Keep message geometry alive
        // offscreen so lazy estimates cannot move the reading position.
        VStack(alignment: .leading, spacing: 22) {
          ForEach(model.entries.filter { !["run", "tool", "report"].contains($0.string("phase")) }) { entry in
            messageBubble(entry).id(entry.id)
          }
          if model.entries.isEmpty { Text("Members first work independently in parallel. Their proposals will appear here.").foregroundStyle(.secondary).padding(.vertical, 30) }
          Color.clear.frame(height: 1).id("latest")
        }.padding(18).frame(maxWidth: 1100).frame(maxWidth: .infinity)
      }
      .onAppear { proxy.scrollTo("latest", anchor: .bottom) }
      .onChange(of: model.entries.filter { $0.string("phase") == "user" }.count) { _, _ in proxy.scrollTo("latest", anchor: .bottom) }
    }
  }
  @ViewBuilder private func messageBubble(_ entry: Row) -> some View {
    let payload = entry.raw["payload"] as? [String: Any] ?? [:]
    let response = payload["response"] as? [String: Any] ?? [:]
    let isUser = entry.string("phase") == "user"
    let isExpanded = expanded.contains(entry.id)
    HStack(alignment: .top, spacing: 12) {
      if isUser { Spacer(minLength: 50) }
      if !isUser {
        Text(String(model.name(entry.string("member_id")).prefix(1))).font(.headline).frame(width: 30, height: 30).background(Palette.accent.opacity(0.1), in: Circle())
      }
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text(isUser ? "You" : model.name(entry.string("member_id"))).font(.headline)
          if !isUser { Text(entry.string("phase").capitalized).font(.caption).foregroundStyle(.secondary) }
          Spacer()
          if entry.string("status") == "running" { ProgressView().controlSize(.mini) }
        }
        let text = isUser ? (payload["text"] as? String ?? "") : (response["text"] as? String ?? response["summary"] as? String ?? model.progressPreview(payload["progress"] as? String ?? payload["raw"] as? String ?? "Working…"))
        if isExpanded && !isUser && !text.isEmpty { ResearchMarkdown(text: text, onLink: workspace.handleLink) }
        else { Text(text).lineLimit(isUser ? nil : 4).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
        if let error = payload["error"] as? String { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
        if !isUser {
          if isExpanded, response["text"] == nil {
            let legacy = ["reasoning", "weakness", "changes", "verification", "next_step"].compactMap { response[$0] as? String }.filter { !$0.isEmpty }.joined(separator: "\n\n")
            if !legacy.isEmpty { ResearchMarkdown(text: legacy, onLink: workspace.handleLink) }
          }
          Button(isExpanded ? "Show less" : "Read more") { if isExpanded { expanded.remove(entry.id) } else { expanded.insert(entry.id) } }.buttonStyle(.plain).foregroundStyle(Palette.accent).font(.caption)
        } else { Text("Visible to everyone").font(.system(size: 10)).foregroundStyle(.secondary) }
      }.padding(isUser ? 14 : 0).background(isUser ? Palette.accent.opacity(0.07) : Color.clear, in: RoundedRectangle(cornerRadius: 16))
      if !isUser { Spacer(minLength: 24) }
    }
  }
  private func sources(_ room: Row) -> some View {
    let values = (room.raw["sources"] as? [[String: Any]] ?? []).map { Row(raw: $0) }
    return ScrollView {
      LazyVStack(alignment: .leading, spacing: 16) {
        Text("Shared does not mean read. Reading acknowledgements remain visible for every source.").font(.caption).foregroundStyle(.secondary)
        if values.isEmpty { Text("Relevant literature found by members will appear here, deduplicated by DOI or link.").foregroundStyle(.secondary) }
        ForEach(values) { source in
          VStack(alignment: .leading, spacing: 8) {
            Button(source.title) { if let url = URL(string: source.string("url")) { workspace.handleLink(url) } }.buttonStyle(.link)
            Text(source.string("note")).textSelection(.enabled)
            let readers = source.raw["read_by"] as? [String] ?? []
            Text("Read by: " + (readers.isEmpty ? "No acknowledgements yet" : readers.map(model.name).joined(separator: ", "))).font(.caption).foregroundStyle(.secondary)
            Text(source.string("url")).font(.caption).textSelection(.enabled)
          }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Palette.accent.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        }
      }.padding(18)
    }
  }
  private var files: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 10) {
        Text("Personal workspaces are writable. Shared resources hold literature and data; shared/work holds code when Work mode is enabled. Runs preserve scripts and logs. Storage guardrails limit disk use.").font(.callout).foregroundStyle(.secondary)
        if let path = model.detail?.string("workspace") { Button("Reveal discussion workspace") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path) } }
        ForEach(model.entries.filter { $0.string("phase") == "run" }) { entry in
          let payload = entry.raw["payload"] as? [String: Any] ?? [:]
          DisclosureGroup("\(model.name(entry.string("member_id"))) · verification · \(entry.string("status"))") {
            Text(payload["output"] as? String ?? "No output").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
          }.padding(10)
        }
        ForEach(model.files) { file in
          HStack {
            Image(systemName: "doc").foregroundStyle(Palette.accent)
            VStack(alignment: .leading) { Text(file.title); Text(file.id).font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.string("path"))]) }
          }.padding(8)
        }
      }.padding(18)
    }
  }
  private func report(_ room: Row) -> some View {
    VStack(spacing: 0) {
      HStack {
        Text("During discussion: excerpts. At completion or Summarize now: a separate report (one remaining turn).").font(.caption).foregroundStyle(.secondary)
        Spacer()
        Toggle("Evidence details", isOn: $reportDetails).toggleStyle(.checkbox)
        Button("Save to Notes") { Task { await model.post("save-note", ["id": room.id]) } }
        Button("Export…") { model.exportReport() }
      }.padding(12)
      if room.string("report").isEmpty { Text("The first report appears after a member responds.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
      else { ResearchMarkdownReader(text: room.string(reportDetails ? "report_details" : "report"), onLink: workspace.handleLink).id(room.id + "report") }
    }
  }
  private func sendMessage() {
    guard !model.pending, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    let text = message; let id = model.selectedID
    Task { if await model.post("control", ["id": id, "action": "message", "text": text]), model.selectedID == id, message == text { message = ""; model.drafts[id] = ""; tab = "discussion" } }
  }
  private func intervention(_ room: Row) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      if message.contains("@") {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack { ForEach(model.members) { member in Button("@" + model.modelName(member)) {
            if let at = message.range(of: "@", options: .backwards) { message.replaceSubrange(at.lowerBound..., with: "@" + model.modelName(member) + " ") }
          }.buttonStyle(.borderless) } }
        }
      }
      VStack(spacing: 0) {
        ZStack(alignment: .topLeading) {
          if message.isEmpty { Text("Join the conversation… @ a member to ask them directly").foregroundStyle(.tertiary).padding(.leading, 13).padding(.top, 12).allowsHitTesting(false) }
          ChatInputTextView(text: $message, onSend: sendMessage, onPasteImage: { _ in model.error = "Share image files through the workspace; this composer accepts text." }, onTextChange: { model.drafts[room.id] = message }, onHeightChange: { inputHeight = min(max($0, 48), 160) }, focusObject: model).frame(height: inputHeight)
        }
        HStack {
          Button { topicMode = (room.raw["config"] as? [String: Any])?["participation"] as? String ?? "agent_only"; newTopic = true } label: { Label("New topic", systemImage: "plus") }.buttonStyle(.plain)
          Text("Everyone can see your message").font(.caption).foregroundStyle(.secondary)
          Spacer()
          Button(action: sendMessage) { Image(systemName: "arrow.up").fontWeight(.semibold).frame(width: 22, height: 22) }.buttonStyle(.borderedProminent).disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.pending).help("Send (Enter); Shift+Enter for a new line")
        }.padding(.horizontal, 12).padding(.bottom, 10)
      }.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.12)))
      Text(room.string("status") == "running" ? "Sent to working members; a follow-up round lets everyone respond." : "Send a message for one response from each member, in order. New topics can use either participation mode.").font(.caption).foregroundStyle(.secondary)
    }.padding(.horizontal, 14).padding(.vertical, 8)
  }
}

private struct BrainstormEffortMenu: View {
  @ObservedObject var model: BrainstormModel
  let member: Row
  @State private var levels: [String] = []
  var body: some View {
    Menu {
      Button("Runtime default") { update("") }
      ForEach(levels, id: \.self) { level in Button(level.capitalized) { update(level) } }
      Text("Changes apply to the next turn")
    } label: {
      Text(model.modelName(member) + " · " + (member.string("effort").isEmpty ? "Default" : member.string("effort").capitalized)).font(.caption)
    }.menuStyle(.borderlessButton).fixedSize().help(member.string("model") + " — change thinking effort for the next turn")
    .task(id: member.id) {
      levels = await model.levels(BrainstormMemberDraft(name: member.title, runtime: member.string("runtime"), provider: member.string("provider"), model: member.string("model")))
    }
  }
  private func update(_ effort: String) { Task { await model.post("control", ["id": model.selectedID, "action": "effort", "member_id": member.id, "effort": effort]) } }
}

struct BrainstormComposer: View {
  @ObservedObject var model: BrainstormModel
  let projectID: String
  var linkedObjects: [Row] = []
  @State private var selectedProject = ""
  @State private var selectedIdea = ""
  @Binding var isPresented: Bool
  @State private var topic = ""
  @State private var members = [BrainstormMemberDraft(runtime: "codex"), BrainstormMemberDraft()]
  @State private var participation = "agent_only"
  @State private var workMode = false
  @State private var calls = 12
  @State private var minutes = 30
  @State private var rounds = 3
  @State private var runs = 6
  @State private var turnSeconds = 300
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack { Text("Add new brainstorm").font(.title2); Spacer(); Button("Cancel") { isPresented = false } }
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          TextField("What question should this discussion resolve?", text: $topic, axis: .vertical).lineLimit(3...5).textFieldStyle(.roundedBorder)
          HStack {
            Picker("Project", selection: $selectedProject) {
              Text("None").tag("")
              ForEach(linkedObjects.filter { $0.string("kind") == "project" }) { Text($0.title).tag($0.id) }
            }
            Picker("Idea", selection: $selectedIdea) {
              Text("None").tag("")
              ForEach(linkedObjects.filter { $0.string("kind") == "idea" && (selectedProject.isEmpty || $0.string("project_id").isEmpty || $0.string("project_id") == selectedProject) }) { Text($0.title).tag($0.id) }
            }
          }
          Text("Optional. Linking an idea also selects its project. Linked context is shared with all members; other resources remain accessible.").font(.caption).foregroundStyle(.secondary)
          Text("Equal participants · no moderator or fixed roles").font(.headline)
          ForEach($members) { $member in
            BrainstormMemberEditor(model: model, member: $member, remove: { members.removeAll { $0.id == member.id } }).disabled(model.pending)
          }
          Button("Add participant") { members.append(BrainstormMemberDraft()); calls = max(calls, members.count * 4 + 1) }.disabled(members.count >= 12)
          Divider()
          Picker("Participation", selection: $participation) { Text("Agent only").tag("agent_only"); Text("Agent and user").tag("agent_and_user") }.pickerStyle(.segmented)
          Text(participation == "agent_only" ? "Independent proposals in parallel, then sequential discussion and a report. Follow up whenever you like." : "Independent proposals in parallel, then your turn. Each message prompts one sequential round.").font(.callout).foregroundStyle(.secondary)
          Toggle("Work mode — allow scripts in the shared workspace", isOn: $workMode)
          Stepper("Maximum member turns: \(calls)", value: $calls, in: max(4,members.count * 3)...200)
          if participation == "agent_only" {
            let availableRounds = min(rounds, max(0, (calls - 1) / max(1, members.count) - 3))
            Text(availableRounds == 0
              ? "This budget skips discussion. Use at least \(members.count * 4 + 1) turns for proposals, one discussion round, verification, final statements and a report."
              : "Current turn budget allows up to \(availableRounds) discussion round(s), plus proposals, verification, final statements and a report. The time limit may stop earlier.")
              .font(.caption).foregroundStyle(availableRounds == 0 ? Color.orange : Color.secondary)
          }
          Stepper("Time budget: \(minutes) minutes", value: $minutes, in: 1...240)
          DisclosureGroup("Advanced budget controls") {
            VStack(alignment: .leading, spacing: 12) {
              Stepper("Discussion rounds: up to \(rounds)", value: $rounds, in: 1...20)
              Stepper("Verification runs: up to \(runs)", value: $runs, in: 0...100)
              Stepper("Per-member turn: \(turnSeconds) seconds", value: $turnSeconds, in: 30...900, step: 30)
            }.padding(.top, 8)
          }
          Text("Stops at the selected round/time budget, or after repeated identical replies. Verification and final statements have reserved turns. One member turn can contain multiple inference requests; subscription balance is not available here. A final summary uses one remaining member turn; ordinary messages have no fixed template.")
            .font(.caption).foregroundStyle(.secondary)
          Text("Personal workspaces allow files and scripts by default. Publish literature and data for everyone. Shared scripts require Work mode. Storage guardrails: 100 MB / 2,000 files per member; 300 MB / 6,000 files per session. Original resources stay read-only.").font(.caption).foregroundStyle(.secondary)
          if !model.error.isEmpty { Text(model.error).foregroundStyle(.red).textSelection(.enabled) }
        }
      }
      HStack {
        Text("\(members.count) members").foregroundStyle(.secondary); Spacer()
        Button("Create discussion") {
          Task {
            if await model.post("create", ["topic": topic, "project_id": selectedProject, "idea_id": selectedIdea, "members": members.map(\.payload), "config": ["mode": "verify", "participation": participation, "work_mode": workMode, "max_calls": calls, "minutes": minutes, "max_rounds": rounds, "max_runs": runs, "turn_seconds": turnSeconds]]) { isPresented = false }
          }
        }.buttonStyle(.borderedProminent).disabled(model.pending || topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || members.count < 2 || members.contains { $0.model.isEmpty })
      }
    }.padding(24).frame(width: 760, height: 720)
    .onAppear { selectedProject = projectID }
    .onChange(of: selectedIdea) { _, id in
      if let idea = linkedObjects.first(where: { $0.id == id }), !idea.string("project_id").isEmpty { selectedProject = idea.string("project_id") }
    }
    .onChange(of: selectedProject) { _, id in
      if let idea = linkedObjects.first(where: { $0.id == selectedIdea }), !idea.string("project_id").isEmpty, idea.string("project_id") != id { selectedIdea = "" }
    }
    .task { await model.catalog("codex"); await model.catalog("pi") }
  }
}

private struct BrainstormMemberEditor: View {
  @ObservedObject var model: BrainstormModel
  @Binding var member: BrainstormMemberDraft
  let remove: () -> Void
  @State private var filter = ""
  private var available: [Row] {
    ["codex", "pi"].flatMap { runtime in
      (model.catalogs[runtime] ?? []).map { row in Row(raw: row.raw.merging(["runtime": runtime]) { _, value in value }) }
    }.filter { ($0.id == member.model && $0.string("provider") == member.provider && $0.string("runtime") == member.runtime) || filter.isEmpty || ($0.title + $0.string("provider") + $0.id).localizedCaseInsensitiveContains(filter) }
  }
  private var selection: Binding<String> {
    Binding(get: { member.runtime + "|" + member.provider + "|" + member.model }, set: { value in
      let parts = value.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
      guard parts.count == 3 else { return }
      member.runtime = parts[0]; member.provider = parts[1]; member.model = parts[2]; member.name = available.first { $0.rawModelKey == value }?.title ?? parts[2]; member.effort = ""; member.levels = []
      let selected = member
      Task { let levels = await model.levels(selected); if member.id == selected.id && member.model == selected.model && member.provider == selected.provider { member.levels = levels } }
    })
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text(member.name.isEmpty ? "Choose a model" : member.name).font(.headline)
        Spacer()
        Button(action: remove) { Image(systemName: "minus.circle") }.buttonStyle(.plain).foregroundStyle(.secondary)
      }
      HStack {
        TextField("Search model or channel", text: $filter).textFieldStyle(.roundedBorder).frame(width: 180)
        if !model.loadingCatalog.isEmpty { ProgressView().controlSize(.small) }
        Picker("Model", selection: selection) {
          Text("Select model").tag(member.runtime + "||")
          ForEach(available, id: \.rawModelKey) { row in Text(row.title + " · " + channel(row)).tag(row.rawModelKey) }
        }.labelsHidden()
        Button { Task { await model.catalog("codex"); await model.catalog("pi") } } label: { Image(systemName: "arrow.clockwise") }.help("Refresh models")
      }
      HStack {
        Picker("Thinking", selection: $member.effort) {
          Text("Runtime default").tag("")
          ForEach(member.levels, id: \.self) { Text($0.capitalized).tag($0) }
        }.frame(maxWidth: 280).disabled(member.model.isEmpty)
        Spacer()
        if !member.model.isEmpty { Text(member.runtime == "codex" ? "Codex account" : "Pi · " + member.provider).font(.caption).foregroundStyle(.secondary) }
      }
    }.padding(.vertical, 12)
    Divider()
  }
  private func channel(_ row: Row) -> String { row.string("runtime") == "codex" ? "Codex account" : row.string("provider") }
}

private extension Row { var rawModelKey: String { string("runtime") + "|" + string("provider") + "|" + id } }
