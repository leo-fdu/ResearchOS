import AppKit
import SwiftUI
import WebKit
import UniformTypeIdentifiers

enum Palette {
  static let ink = Color(red: 0.10, green: 0.16, blue: 0.27)
  static let accent = Color(red: 0.16, green: 0.38, blue: 0.90)
  static let canvas = Color.white
  static let muted = Color.secondary
  static let warm = Color(red: 0.77, green: 0.40, blue: 0.22)
}
let labels = [
  "project": "Project", "idea": "Idea", "plan": "Research plan", "task": "Task", "note": "Note", "memory": "Memory",
  "papers": "Papers", "notes": "Notes", "repo": "Repositories", "results": "Results", "data": "Datasets", "repo_catalog": "Repository", "data_catalog": "Dataset",
]
let symbols = [
  "project": "square.stack.3d.up", "idea": "lightbulb", "plan": "map", "task": "checklist",
  "note": "note.text", "memory": "brain", "papers": "books.vertical", "notes": "note.text",
  "repo": "chevron.left.forwardslash.chevron.right", "results": "chart.xyaxis.line",
]

struct WorkspaceView: View {
  @ObservedObject var model: WorkspaceModel
  @State private var showActivity = false
  @State private var titlebarInset: CGFloat = 28
  // Keep list identity (and its native scroll view) alive while viewing details
  // or another section. Only visited sections are mounted.
  @State private var visitedSections: Set<String> = ["home"]
  var body: some View {
    Group {
      if !model.ready {
        startup
      } else {
        HSplitView {
          if model.showNavigation { sidebar.padding(.top, titlebarInset).background(Color(red: 0.97, green: 0.985, blue: 1)).frame(minWidth: 205, idealWidth: 225, maxWidth: 270) }
          VStack(spacing: 0) {
            header.padding(.leading, !model.showNavigation && titlebarInset > 0 ? 70 : 0)
            Divider()
            center.frame(maxWidth: .infinity, maxHeight: .infinity)
          }.frame(minWidth: 460)
          if model.showAssistant && model.selectedSection != "brainstorm" && (model.selectedSection != "graph" || model.selected != nil) {
            ResearchAssistant(model: model).frame(minWidth: 355, idealWidth: 425, maxWidth: 700)
          }
        }
      }
    }
    .frame(minWidth: 1000, minHeight: 650)
    .tint(Palette.accent)
    .background(Palette.canvas)
    .background(WindowChromeReader(topInset: $titlebarInset))
    // HSplitView retains the window's titlebar inset; reclaim it for the two content columns.
    .padding(.top, -titlebarInset)
    .ignoresSafeArea(.container, edges: .top)
    .task { await model.start() }
    .onChange(of: model.selectedSection) { _, section in
      visitedSections.insert(section)
    }
    .sheet(isPresented: $model.showSetup) { WorkspaceSetup(model: model) }
    .sheet(isPresented: $model.showComposer) { RecordComposer(model: model) }
    .alert(
      "Action not completed",
      isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })
    ) {
      Button("OK") { model.error = nil }
    } message: {
      Text(model.error ?? "")
    }
    .overlay(alignment: .bottom) {
      if let notice = model.notice {
        HStack {
          Image(systemName: "checkmark.circle.fill")
          Text(notice)
          Button("Close") { model.notice = nil }
        }.padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)).padding()
      }
    }
  }
  private var startup: some View {
    VStack(spacing: 22) {
      Image(systemName: "sparkle.magnifyingglass").font(.system(size: 60)).foregroundStyle(
        Palette.accent)
      Text("Research OS").font(.system(size: 34, weight: .semibold, design: .serif))
      if model.startupError.isEmpty {
        ProgressView()
        Text("Preparing your workspace…").foregroundStyle(.secondary)
      } else {
        Text(model.startupError).textSelection(.enabled)
        Button("Retry") { Task { await model.start() } }
      }
    }.frame(maxWidth: .infinity, maxHeight: .infinity)
  }
  private var sidebar: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text("Research OS").font(.system(size: 17, weight: .semibold))
        Spacer()
        Button { model.showNavigation = false } label: { Image(systemName: "sidebar.left") }
          .buttonStyle(.plain).help("Collapse navigation")
      }.padding(18)
      VStack(alignment: .leading, spacing: 5) {
        nav("search", "Search", "magnifyingglass")
        nav("home", "Projects and ideas", "square.grid.2x2")
        nav("brainstorm", "Brainstorm", "bubble.left.and.bubble.right")
        nav("graph", "Graph", "point.3.connected.trianglepath.dotted")
        Text("RESOURCES").font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(.secondary).padding(.top, 20).padding(.bottom, 4).padding(.leading, 10)
        nav("papers", "Papers", "books.vertical")
        nav("note", "Notes", "note.text")
        nav("repo", "Repositories", "chevron.left.forwardslash.chevron.right")
        nav("data", "Datasets", "externaldrive")
      }.padding(.horizontal, 10)
      DiscussionHistory(model: model).padding(.top, 22)
      Divider().padding(.horizontal, 16)
      Button { model.selectedSection = "settings"; model.selected = nil } label: {
        Label("Settings", systemImage: "slider.horizontal.3").frame(maxWidth: .infinity, alignment: .leading)
      }.buttonStyle(.plain).padding(18)
      HStack(spacing: 7) {
        Circle().fill(model.connection.contains("connected ·") ? Palette.accent : Color.orange).frame(width: 6, height: 6)
        Text(model.connection).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
      }.padding(.horizontal, 18).padding(.bottom, 16)
    }.background(Color(red: 0.97, green: 0.985, blue: 1))
  }
  private func nav(_ section: String, _ title: String, _ image: String) -> some View {
    Button {
      model.selectedSection = section
      model.selected = nil
    } label: {
      HStack {
        Label(title, systemImage: image)
        Spacer()
        if model.selectedSection == section {
          Circle().fill(Palette.accent).frame(width: 5, height: 5)
        }
      }.padding(.horizontal, 10).padding(.vertical, 9).contentShape(Rectangle()).background(model.selectedSection == section ? Palette.accent.opacity(0.09) : Color.clear, in: RoundedRectangle(cornerRadius: 8)).foregroundStyle(
        model.selectedSection == section ? Palette.accent : Color.primary)
    }.buttonStyle(.plain)
  }
  private var header: some View {
    HStack(spacing: 12) {
      if !model.showNavigation {
        Button { model.showNavigation = true } label: { Image(systemName: "sidebar.left") }.help("Show navigation")
      }
      if model.selected != nil {
        Button {
          model.selected = nil
          model.editingFile = false
        } label: {
          Image(systemName: "chevron.left")
        }.help("Back to list")
      }
      VStack(alignment: .leading, spacing: 3) {
        Text(model.selected?.title ?? sectionTitle).font(.system(size: 21, weight: .semibold)).lineLimit(2).help(model.selected?.title ?? sectionTitle)

      }
      Spacer()
      Picker("Project scope", selection: $model.project) {
        Text("All projects").tag("")
        ForEach(model.objects.filter { $0.string("kind") == "project" }) {
          Text($0.title).tag($0.id)
        }
      }.labelsHidden().frame(maxWidth: 190).help("Filter resources and set the project for new discussions")
      if !model.showAssistant && model.selectedSection != "brainstorm" && (model.selectedSection != "graph" || model.selected != nil) {
        Button { model.showAssistant = true } label: { Image(systemName: "sidebar.right") }.help("Show research assistant")
      }
    }.padding(.horizontal, 20).padding(.vertical, 12)
  }
  private var sectionTitle: String {
    [
      "home": "Projects and ideas", "brainstorm": "Brainstorm", "graph": "Research graph", "search": "Search", "project": "Project", "idea": "Ideas", "plan": "Plans and tasks",
      "papers": "Papers", "note": "Notes", "repo": "Repositories", "experiments": "Experiments and results", "memory": "Memory",
      "settings": "Connections and settings", "data": "Datasets",
    ][model.selectedSection] ?? "Research OS"
  }
  private var center: some View {
    ZStack {
      ForEach(Array(visitedSections.union([model.selectedSection])).sorted(), id: \.self) { section in
        let visible = model.selected == nil && model.selectedSection == section
        sectionPane(section)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .opacity(visible ? 1 : 0)
          .allowsHitTesting(visible)
          .disabled(!visible)
          .accessibilityHidden(!visible)
      }
      if let selected = model.selected {
        DetailPane(model: model, row: selected)
          .id(selected.id)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(Palette.canvas)
      }
    }.clipped()
  }
  @ViewBuilder private func sectionPane(_ section: String) -> some View {
      switch section {
      case "home": HomePane(model: model)
      case "brainstorm": BrainstormPane(workspace: model)
      case "graph": ResearchGraph(model: model)
      case "search": SearchPane(model: model)
      case "papers", "repo", "data": LibraryPane(model: model, kind: section)
      case "note": LibraryPane(model: model, kind: "notes")
      case "experiments": ExperimentWorkspace(baseURL: model.baseURL)
      case "settings": WorkspaceSettings(model: model)
      default: RecordList(model: model, kind: section)
      }
  }
}

struct HomePane: View {
  @ObservedObject var model: WorkspaceModel
  @State private var filter = ""
  @State private var includeArchived = false
  var body: some View {
    VStack(spacing: 16) {
      HStack {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        TextField("Find a project or idea", text: $filter).textFieldStyle(.plain)
        Toggle("Archived", isOn: $includeArchived).toggleStyle(.checkbox).font(.caption)
      }.padding(12).background(Color.white, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.accent.opacity(0.12)))
      HStack(alignment: .top, spacing: 18) {
        column("Projects", kind: "project", icon: "square.stack.3d.up")
        column("Ideas", kind: "idea", icon: "lightbulb")
      }
    }.padding(20).background(Color(red: 0.985, green: 0.99, blue: 1))
  }
  private func column(_ title: String, kind: String, icon: String) -> some View {
    let records = model.objects.filter {
      $0.string("kind") == kind && (includeArchived || $0.string("status") != "archived")
      && (model.project.isEmpty || $0.id == model.project || $0.string("project_id") == model.project)
      && (filter.isEmpty || ($0.title + $0.string("body") + String(describing: $0.data)).localizedCaseInsensitiveContains(filter))
    }
    return VStack(alignment: .leading, spacing: 14) {
      HStack {
        Label(title, systemImage: icon).font(.headline)
        Text("\(records.count)").font(.caption).foregroundStyle(.secondary)
        Spacer()
        Button { model.compose(kind) } label: { Image(systemName: "plus") }.buttonStyle(.borderless).help("New " + kind)
      }.foregroundStyle(Palette.ink)
      ScrollView {
        LazyVStack(spacing: 12) {
          if records.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
              Text(kind == "project" ? "A place for work in progress." : "A place for your next question.").font(.headline)
              Text("Create one here, or ask your assistant to save it.").font(.callout).foregroundStyle(.secondary)
              Button("New " + kind) { model.compose(kind) }.buttonStyle(.borderedProminent)
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(.white, in: RoundedRectangle(cornerRadius: 14))
              .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.accent.opacity(0.12)))
          }
          ForEach(records) { row in
            Button { model.selected = row } label: { ResearchCard(row: row) }.buttonStyle(.plain)
          }
        }.padding(.bottom, 12)
      }.scrollIndicators(.hidden)
    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}

struct DiscussionHistory: View {
  @ObservedObject var model: WorkspaceModel
  @AppStorage("ros.history-expanded") private var expanded = true
  @State private var hovered = ""
  @State private var showTrash = false
  @State private var trash: [Row] = []
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Button { expanded.toggle() } label: {
          HStack(spacing: 7) {
            Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
            Text("Discussions").font(.system(size: 12, weight: .semibold))
            Text("\(model.sessions.count)").font(.caption2).foregroundStyle(.secondary)
          }
        }.buttonStyle(.plain).help(expanded ? "Collapse discussions" : "Expand discussions")
        Spacer()
        Menu {
          Button("Recently deleted…") { Task { await loadTrash(); showTrash = true } }
        } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize().help("Discussion options")
      }.padding(.horizontal, 18)
      if expanded {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 4) {
            if model.sessions.isEmpty { Text("Your conversations will appear here.").font(.caption).foregroundStyle(.secondary).padding(12) }
            ForEach(model.sessions) { session in
              HStack(spacing: 8) {
                Button { Task { await model.openSession(session.id) } } label: {
                  VStack(alignment: .leading, spacing: 5) {
                    Text(researchMessageText(session.title).isEmpty ? "Research discussion" : researchMessageText(session.title)).font(.system(size: 12, weight: model.sessionID == session.id ? .semibold : .regular)).lineLimit(2)
                    Text(session.string("status") == "running" ? "Working…" : workspaceDate(session.string("updated_at"))).font(.system(size: 10)).foregroundStyle(.secondary)
                  }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain)
                Button { Task { await model.deleteDiscussion(session.id) } } label: { Image(systemName: "trash").font(.caption) }
                  .buttonStyle(.plain).foregroundStyle(.secondary).opacity(hovered == session.id ? 1 : 0)
                  .disabled(session.string("status") == "running").help("Delete discussion")
              }.padding(10).background(model.sessionID == session.id ? Palette.accent.opacity(0.10) : hovered == session.id ? Palette.accent.opacity(0.04) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
                .onHover { hovered = $0 ? session.id : "" }
                .contextMenu { Button("Delete discussion", role: .destructive) { Task { await model.deleteDiscussion(session.id) } }.disabled(session.string("status") == "running") }
            }
          }.padding(.horizontal, 8)
        }.scrollIndicators(.visible)
      } else { Spacer(minLength: 0) }
    }.frame(maxHeight: .infinity, alignment: .top)
      .sheet(isPresented: $showTrash) {
        VStack(alignment: .leading, spacing: 16) {
          HStack { Text("Recently deleted").font(.title2); Spacer(); Button("Done") { showTrash = false } }
          Text("Restore a discussion to put it back in your history. Saved memories remain separate.").font(.callout).foregroundStyle(.secondary)
          List(trash) { row in
            HStack { Text(row.title).lineLimit(2); Spacer(); Button("Restore") { Task { await model.perform("/v2/restore-session", ["id": row.id]); await loadTrash() } } }
          }
        }.padding(24).frame(width: 540, height: 400)
      }
  }
  private func loadTrash() async {
    do { trash = model.rows(try await model.request("/v2/deleted-sessions")) } catch { model.error = error.localizedDescription }
  }
}
struct EmptyCard: View {
  let title: String
  let detail: String
  let icon: String
  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: icon).font(.system(size: 34, weight: .light)).foregroundStyle(
        Palette.accent)
      Text(title).font(.headline)
      Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
    }.padding(35).frame(maxWidth: .infinity).background(
      .background, in: RoundedRectangle(cornerRadius: 14))
  }
}
struct ResearchStatus: View {
  let status: String
  var body: some View {
    HStack(spacing: 6) {
      Circle().fill(status == "doing" ? Color.green : Color.red).frame(width: 6, height: 6)
        .accessibilityHidden(true)
      Text(status.capitalized)
    }
  }
}

struct ResearchCard: View {
  let row: Row
  var body: some View {
    HStack(alignment: .top, spacing: 14) {
      Image(systemName: symbols[row.string("kind")] ?? "doc.text").foregroundStyle(Palette.accent)
        .font(.title3).frame(width: 25)
      VStack(alignment: .leading, spacing: 7) {
        Text(row.title).font(.headline).foregroundStyle(.primary)
        Text((row.data["summary"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (row.string("excerpt").isEmpty ? row.string("body") : row.string("excerpt"))).font(
          .callout
        ).foregroundStyle(.secondary).lineLimit(3)
        HStack {
          Text(labels[row.string("kind")] ?? row.string("kind"))
          if ["project", "idea"].contains(row.string("kind")) {
            ResearchStatus(status: row.string("status"))
          } else {
            Text(row.string("status").capitalized)
          }
        }.font(.caption2).foregroundStyle(Palette.accent)
        if ["project", "idea"].contains(row.string("kind")) {
          Divider().overlay(Palette.accent.opacity(0.08))
          Text((row.data["progress_summary"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "No progress update yet")
            .font(.caption).foregroundStyle(.secondary).lineLimit(3)
          Text("Updated " + workspaceDate(row.string("updated_at"))).font(.system(size: 10)).foregroundStyle(.tertiary)
        }
      }
      Spacer(minLength: 0)
    }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(
      .white, in: RoundedRectangle(cornerRadius: 12))
      .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.accent.opacity(0.14)))
  }
}
struct RecordList: View {
  @ObservedObject var model: WorkspaceModel
  let kind: String
  @State private var filter = ""
  private var records: [Row] {
    model.objects.filter { r in
      (r.string("kind") == kind || (kind == "plan" && r.string("kind") == "task"))
        && (model.project.isEmpty || r.string("project_id") == model.project
          || r.id == model.project)
        && (filter.isEmpty || (r.title + r.string("body")).localizedCaseInsensitiveContains(filter))
    }
  }
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        HStack {
          TextField("Filter by title or content", text: $filter).textFieldStyle(.roundedBorder)
          Button("New " + (labels[kind] ?? "Record")) { model.compose(kind) }.buttonStyle(
            .borderedProminent)
        }
        if records.isEmpty {
          EmptyCard(
            title: "Capture something worth pursuing", detail: "Create a record, or discuss it with your assistant and ask to save it.",
            icon: symbols[kind] ?? "doc.text")
        }
        ForEach(records) { r in
          Button {
            model.selected = r
          } label: {
            ResearchCard(row: r)
          }.buttonStyle(.plain)
        }
        if kind == "note" {
          Text("Connected note files").font(.headline)
          ForEach(model.documents.filter { $0.string("kind") == "notes" }.prefix(100)) { r in
            Button {
              Task { await model.select(r) }
            } label: {
              Label(r.title, systemImage: "doc.text")
            }.buttonStyle(.plain)
          }
        }
      }.padding(24)
    }
  }
}
struct ResourceIcon: View {
  let row: Row
  var body: some View {
    if row.string("kind").hasSuffix("_catalog") {
      Image(nsImage: NSWorkspace.shared.icon(for: .folder)).resizable().scaledToFit().frame(width: 42, height: 42)
    } else {
      let isPDF = row.string("kind") == "pdf"
      VStack(spacing: 2) {
        Image(systemName: isPDF ? "doc.richtext" : "doc.plaintext").font(.system(size: 20, weight: .light))
        Text(isPDF ? "PDF" : URL(fileURLWithPath: row.string("path")).pathExtension.lowercased() == "md" ? "MD" : "TXT")
          .font(.system(size: 8, weight: .bold, design: .rounded))
      }.foregroundStyle(isPDF ? Color(red: 0.79, green: 0.27, blue: 0.30) : Palette.accent)
        .frame(width: 42, height: 48).background(isPDF ? Color.red.opacity(0.05) : Palette.accent.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
    }
  }
}
struct ResourceRow: View {
  let row: Row
  let attached: Bool
  @State private var hovering = false
  private var modified: String {
    guard let number = row.raw["modified_ns"] as? NSNumber, number.doubleValue > 0 else { return "Modified date unavailable" }
    let date = Date(timeIntervalSince1970: number.doubleValue / 1_000_000_000)
    let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US"); formatter.dateStyle = .medium; formatter.timeStyle = .short
    return "Modified " + formatter.string(from: date)
  }
  var body: some View {
    HStack(alignment: .top, spacing: 14) {
      ResourceIcon(row: row)
      VStack(alignment: .leading, spacing: 7) {
        Text(row.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.ink).lineLimit(2)
        if !row.string("summary").isEmpty { Text(row.string("summary")).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2) }
        HStack(spacing: 8) {
          Text(modified).help(row.string("kind").hasSuffix("_catalog") ? "Folder modification time; internal files are not scanned" : "Source file modification time")
          if row.int("pages") > 0 { Text("· \(row.int("pages")) pages") }
        }.font(.system(size: 10)).foregroundStyle(.secondary)
        Text(row.string("path")).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
        if !row.string("error").isEmpty { Text(row.string("error")).font(.caption).foregroundStyle(.orange).lineLimit(2) }
      }.frame(maxWidth: .infinity, alignment: .leading)
      if attached { Image(systemName: "paperclip").font(.caption).foregroundStyle(Palette.accent) }
      Image(systemName: "chevron.right").font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary).padding(.top, 5)
    }.padding(15).background(hovering ? Palette.accent.opacity(0.035) : Color.white, in: RoundedRectangle(cornerRadius: 13))
      .overlay(RoundedRectangle(cornerRadius: 13).stroke(Palette.accent.opacity(hovering ? 0.22 : 0.09)))
      .contentShape(Rectangle()).onHover { hovering = $0 }
  }
}
struct LibraryPane: View {
  @ObservedObject var model: WorkspaceModel
  let kind: String
  @State private var filter = ""
  @State private var sort = "modified_desc"
  @State private var category = ""
  @State private var files: [Row] = []
  @State private var total = 0
  @State private var limit = 100
  @State private var loading = false
  private var paperRoots: [Row] { model.roots.filter { $0.string("kind") == "papers" } }
  private var libraryVersion: String { model.roots.map { $0.id + $0.string("last_scan") }.joined(separator: "|") }
  private func organize(_ root: Row) {
    Task { await model.perform("/v2/scan", ["id": root.id, "organize": true], success: "Paper organization queued") }
  }
  private var searchKey: String { kind + "|" + category + "|" + filter + "|" + model.project + "|" + String(limit) + "|" + sort }
  private var localNotes: [Row] {
    model.objects.filter { $0.string("kind") == "note" && $0.data["entry_type"] as? String != "experiment_log" && (category.isEmpty || ($0.data["category"] as? String ?? "other") == category) && (model.project.isEmpty || $0.string("project_id") == model.project) && (filter.isEmpty || ($0.title + $0.string("body")).localizedCaseInsensitiveContains(filter)) }
  }
  private func load() async {
    let key = searchKey
    do {
      try await Task.sleep(nanoseconds: 180_000_000)
      try Task.checkCancellation()
      loading = true
      var components = URLComponents()
      components.queryItems = [URLQueryItem(name: "kind", value: kind), URLQueryItem(name: "q", value: filter), URLQueryItem(name: "project", value: model.project), URLQueryItem(name: "limit", value: String(limit)), URLQueryItem(name: "sort", value: sort), URLQueryItem(name: "category", value: category)]
      let result = try await model.request("/v2/documents" + (components.string ?? "")) as? [String: Any] ?? [:]
      guard key == searchKey else { return }
      files = model.rows(result["documents"]); total = result["total"] as? Int ?? 0
    } catch is CancellationError {} catch { model.error = error.localizedDescription }
    loading = false
  }
  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        HStack(spacing: 8) {
          Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
          TextField("Find a resource", text: $filter).textFieldStyle(.plain)
        }.padding(10).background(Color.white, in: RoundedRectangle(cornerRadius: 9))
          .overlay(RoundedRectangle(cornerRadius: 9).stroke(Palette.accent.opacity(0.13)))
        if kind == "papers" {
          if paperRoots.count == 1, let root = paperRoots.first {
            Button { organize(root) } label: { Label("Organize", systemImage: "tray.full") }.fixedSize()
              .help("Organize newest PDFs first, saving Markdown; stop at the first already organized paper")
          } else {
            Menu("Organize") {
              ForEach(paperRoots) { root in Button(root.string("path")) { organize(root) } }
            }.disabled(paperRoots.isEmpty).fixedSize()
          }
        }
        Menu {
          ForEach(["name_asc", "name_desc", "modified_desc", "modified_asc"], id: \.self) { value in
            Button { sort = value } label: {
              let title = ["name_asc":"Name · A–Z", "name_desc":"Name · Z–A", "modified_desc":"Modified · Newest first", "modified_asc":"Modified · Oldest first"][value]!
              if sort == value { Label(title, systemImage: "checkmark") } else { Text(title) }
            }
          }
        } label: { Label("Sort", systemImage: "arrow.up.arrow.down") }.menuStyle(.borderlessButton).fixedSize().help("Sort resources")
        Menu {
          Button("Connect folder…") { model.attachDirectory(kind: kind) }
          if kind == "notes" { Button("New workspace note") { model.compose("note") } }
        } label: { Image(systemName: "plus") }.menuStyle(.borderlessButton).fixedSize().help("Add resources")
      }.padding(20).padding(.bottom, -6)
      if kind == "notes" {
        Picker("Folder", selection: $category) { Text("All").tag(""); Text("blog").tag("blog"); Text("concepts").tag("concepts"); Text("paper").tag("paper"); Text("Other").tag("other") }.pickerStyle(.segmented).padding(.horizontal, 20).padding(.bottom, 10)
      }
      HStack {
        Text("\(total + (kind == "notes" ? localNotes.count : 0)) resources").font(.caption).foregroundStyle(.secondary)
        Spacer()
        Text(["name_asc":"Name A–Z", "name_desc":"Name Z–A", "modified_desc":"Newest first", "modified_asc":"Oldest first"][sort] ?? "").font(.caption).foregroundStyle(.secondary)
        if loading { ProgressView().controlSize(.small) }
      }.padding(.horizontal, 22).padding(.bottom, 12)
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 10) {
          if kind == "notes" && !localNotes.isEmpty {
            Text("Notes").font(.headline)
            ForEach(localNotes) { row in Button { model.selected = row } label: { ResearchCard(row: row) }.buttonStyle(.plain) }
            Text("Connected files").font(.headline).padding(.top, 10)
          }
          if files.isEmpty && !loading { EmptyCard(title: "No matching resources", detail: "Try another search or connect a folder.", icon: "folder") }
          ForEach(files) { row in
            Button { Task { await model.select(row) } } label: { ResourceRow(row: row, attached: model.attached.contains(row.id)) }
              .buttonStyle(.plain).contextMenu {
                Button("Add to discussion") { if !model.attached.contains(row.id) { model.attached.append(row.id) }; model.showAssistant = true }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: row.string("path"))]) }
              }
          }
          if total > files.count && limit < 2000 { Button("Load more") { limit += 100 }.frame(maxWidth: .infinity).padding(8) }
        }.padding(.horizontal, 20).padding(.bottom, 20)
      }.scrollIndicators(.visible)
    }.background(Color(red: 0.985, green: 0.99, blue: 1))
      .task(id: searchKey + "|" + libraryVersion) { await load() }
      .onAppear { sort = UserDefaults.standard.string(forKey: "ros.resource-sort." + kind) ?? "modified_desc" }
      .onChange(of: sort) { _, value in UserDefaults.standard.set(value, forKey: "ros.resource-sort." + kind) }
  }
}
struct SearchPane: View {
  @ObservedObject var model: WorkspaceModel
  @State private var source = "local"
  @State private var remote: [[String: Any]] = []
  @State private var searching = false
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        HStack {
          TextField("Search questions, papers, notes and repositories…", text: $model.query).textFieldStyle(.roundedBorder).onSubmit {
            run()
          }
          Button("Search", action: run).buttonStyle(.borderedProminent).disabled(searching)
        }
        Picker("Scope", selection: $source) {
          Text("Local resources").tag("local")
          Text("PubMed").tag("pubmed")
          Text("arXiv").tag("arxiv")
          Text("bio/medRxiv").tag("biorxiv")
        }.pickerStyle(.segmented)
        if searching { ProgressView() }
        if source == "local" {
          ForEach(model.searchResults) { r in
            Button {
              Task { await model.select(r) }
            } label: {
              ResearchCard(row: r)
            }.buttonStyle(.plain)
          }
        } else {
          ForEach(Array(remote.enumerated()), id: \.offset) { _, r in
            VStack(alignment: .leading, spacing: 8) {
              Text(r["title"] as? String ?? "").font(.headline)
              Text((r["authors"] as? String) ?? (r["authors"] as? [String])?.joined(separator: ", ") ?? "").font(.caption).foregroundStyle(.secondary)
              Text(r["abstract"] as? String ?? "").lineLimit(8).textSelection(.enabled)
              HStack {
                if let address = r["url"] as? String, let url = URL(string: address) {
                  Link("View source", destination: url)
                }
                Button("Discuss with assistant") {
                  model.input =
                    "Read and verify this paper, then relate it to my research:\n\n" + (r["title"] as? String ?? "") + "\n"
                    + (r["url"] as? String ?? "")
                  model.showAssistant = true
                }
              }
            }.padding(18).background(.background, in: RoundedRectangle(cornerRadius: 12))
          }
        }
        Text(
          source == "biorxiv"
            ? "Search Europe PMC for 10.1101 preprints, including medRxiv. Indexing may be delayed." : "Local search stays on your Mac. Scholarly search sends only your query."
        ).font(.caption).foregroundStyle(.secondary)
      }.padding(24)
    }
  }
  private func run() {
    searching = true
    Task {
      defer { searching = false }
      if source == "local" {
        await model.search()
      } else {
        do {
          let r =
            try await model.request(
              "/v2/scholarly", body: ["query": model.query, "source": source]) as? [String: Any]
            ?? [:]
          remote = r["records"] as? [[String: Any]] ?? []
        } catch { model.error = error.localizedDescription }
      }
    }
  }
}
