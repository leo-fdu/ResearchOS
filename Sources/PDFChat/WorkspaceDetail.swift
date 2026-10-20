import AppKit
import SwiftUI
import WebKit

struct DetailPane: View {
  @ObservedObject var model: WorkspaceModel
  let row: Row
  @State private var confirmDelete = false
  @State private var showAudit = false
  @State private var audit: [Row] = []
  @State private var showLinks = false
  private var isObject: Bool { model.objects.contains { $0.id == row.id } }
  private var related: [Row] {
    let ids = model.edges.filter { $0.string("source") == row.id || $0.string("target") == row.id }
      .flatMap { [$0.string("source"), $0.string("target")] }
    return (model.objects + model.documents + model.roots).filter {
      $0.id != row.id
        && (ids.contains($0.id) || ($0.data["parent_id"] as? String) == row.id
          || (row.string("kind") == "project" && $0.string("project_id") == row.id))
    }
  }
  var body: some View {
    VStack(spacing: 0) {
      if row.string("kind") != "pdf" {
      HStack {
        Text(labels[row.string("kind")] ?? row.string("kind")).font(.caption).foregroundStyle(
          Palette.accent)
        Spacer()
        Button("Link resources") { showLinks = true }
        if isObject {
          Button("Edit ") { model.compose(row.string("kind"), row: row) }
          Button("History") {
            Task {
              do {
                audit = model.rows(try await model.request("/v2/audit?id=" + row.id))
                showAudit = true
              } catch { model.error = error.localizedDescription }
            }
          }
          Button(role: .destructive) {
            confirmDelete = true
          } label: {
            Image(systemName: "trash")
          }
        } else {
          Button("Add to discussion") {
            if !model.attached.contains(row.id) { model.attached.append(row.id) }
            model.showAssistant = true
          }
          Button {
            NSWorkspace.shared.activateFileViewerSelecting([
              URL(fileURLWithPath: row.string("path"))
            ])
          } label: {
            Image(systemName: "folder")
          }
        }
      }.padding(.horizontal, 20).padding(.vertical, 12)
      Divider()
      }
      if row.string("kind") == "pdf" {
        PDFViewerView(store: model.pdf)
      } else if isObject {
        objectBody
      } else {
        fileBody
      }
    }
    .confirmationDialog(
      row.string("kind") == "memory" ? "Delete and forget this memory?" : "Delete this record?", isPresented: $confirmDelete
    ) {
      Button("Delete", role: .destructive) {
        Task {
          await model.perform("/v2/delete", ["id": row.id, "revision": row.int("revision")])
          if model.error == nil { model.selected = nil }
        }
      }
    }
    .sheet(isPresented: $showLinks) { RelationComposer(model: model, source: row) }
    .sheet(isPresented: $showAudit) {
      VStack(alignment: .leading) {
        HStack {
          Text("Change history").font(.title2)
          Spacer()
          Button("Close") { showAudit = false }
        }
        List(audit) { r in
          VStack(alignment: .leading) {
            Text(r.string("action") + " · " + r.string("at")).font(.headline)
            Text("Source: " + r.string("source")).font(.caption)
            Text(r.string("after")).font(.system(.caption, design: .monospaced)).textSelection(
              .enabled)
          }
        }
      }.padding(24).frame(width: 680, height: 480)
    }
  }
  private var objectBody: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        HStack {
          Group {
            if ["project", "idea"].contains(row.string("kind")) {
              ResearchStatus(status: row.string("status"))
            } else {
              Text(row.string("status").capitalized)
            }
          }.font(.caption).padding(.horizontal, 10).padding(.vertical, 5)
            .background(Palette.accent.opacity(0.1), in: Capsule())
          Spacer()
          Text(workspaceDate(row.string("updated_at"))).font(.caption).foregroundStyle(
            .secondary)
        }
        if ["project", "idea"].contains(row.string("kind")) {
          if let summary = row.data["summary"] as? String, !summary.isEmpty { Text(summary).font(.title3).textSelection(.enabled) }
          VStack(alignment: .leading, spacing: 8) {
            Text("CURRENT PROGRESS").font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(Palette.accent)
            Text((row.data["progress_summary"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "No progress update yet").textSelection(.enabled)
          }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Palette.accent.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
          Text("Details and progress notes").font(.headline)
        }
        ResearchMarkdown(text: row.string("body"), onLink: model.handleLink)
        if let source = row.data["source"] as? String {
          Label("Source: " + source, systemImage: "link").font(.caption).foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
        if let classification = row.data["classification"] as? String {
          Text("Memory type: " + classification).font(.caption).foregroundStyle(Palette.warm)
        }
        if row.string("kind") == "idea" {
          Button("Develop this idea") {
            model.input = "Develop this idea (ID: \(row.id)) using my papers and relevant code. Update this idea with a concise summary, current progress, detailed evidence and next steps. Keep uncertain information explicit. Do not create separate plans or tasks."
            model.showAssistant = true
          }.buttonStyle(.borderedProminent)
        }
        if row.string("kind") == "project" {
          Button("Review progress and next steps") {
            model.project = row.id
            model.newChat()
            model.input = "Read project \(row.id) and its linked resources. Review progress, unknowns and next steps; update its progress summary and detailed notes based on evidence."
          }.buttonStyle(.borderedProminent)
        }
        if !related.isEmpty {
          Divider()
          Text("Related resources").font(.headline)
          ForEach(related) { r in
            Button {
              Task { await model.select(r) }
            } label: {
              ResearchCard(row: r)
            }.buttonStyle(.plain)
          }
        }
      }.padding(24)
    }.scrollIndicators(.hidden)
  }
  private var fileBody: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(row.string("path")).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
      if ["md", "txt"].contains(URL(fileURLWithPath: row.string("path")).pathExtension.lowercased())
      {
        HStack {
          Toggle("Edit note", isOn: $model.editingFile).toggleStyle(.switch)
          Spacer()
          if model.editingFile {
            Button("Save to original file") {
              Task {
                await model.perform(
                  "/v2/save-text",
                  ["id": row.id, "text": model.editorText, "hash": model.editorHash],
                  success: "Note saved. Previous content backed up.")
                if model.error == nil { await model.select(row) }
              }
            }.buttonStyle(.borderedProminent)
          }
        }
      }
      if model.editingFile {
        TextEditor(text: $model.editorText).font(.system(size: 14, design: .monospaced))
          .scrollIndicators(.visible)
      } else if URL(fileURLWithPath: row.string("path")).pathExtension.lowercased() == "md" || row.string("kind").hasSuffix("_catalog") {
        ResearchMarkdownReader(text: model.editorText, onLink: model.handleLink).id(row.id)
      } else {
        ScrollView {
          Text(model.editorText.isEmpty ? row.string("body") : model.editorText).font(
            .system(size: 13, design: .monospaced)
          ).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }.scrollIndicators(.visible)
      }
    }.padding(20)
  }
}

struct PaperDiscussions: View {
  @ObservedObject var model: WorkspaceModel
  let paper: Row
  @State private var sessions: [Row] = []
  @State private var showHistory = false
  @State private var loading = true
  @State private var loadError: String?
  @State private var filter = ""
  private var refreshKey: String {
    paper.id + "|" + model.sessions.map { $0.id + $0.string("updated_at") + $0.string("status") }.joined(separator: "|")
  }
  private var matches: [Row] {
    sessions.filter { filter.isEmpty || $0.title.localizedCaseInsensitiveContains(filter) }
  }
  var body: some View {
    Button { showHistory.toggle() } label: {
      Image(systemName: "clock.arrow.circlepath")
    }.buttonStyle(.plain)
        .accessibilityLabel("Paper discussion history")
        .help("Discussions for this paper" + (loading ? "" : " (\(sessions.count))"))
        .popover(isPresented: $showHistory, arrowEdge: .bottom) { history }
        .task(id: refreshKey) { await load() }
  }
  private var history: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Discussions for this paper").font(.headline)
        Spacer()
        Button { showHistory = false } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("Close")
      }
      Text(paper.title).font(.caption).foregroundStyle(.secondary).lineLimit(2)
      TextField("Find a discussion", text: $filter).textFieldStyle(.roundedBorder)
      if let loadError {
        Text(loadError).font(.callout).foregroundStyle(.secondary)
        Button("Retry") { Task { await load() } }
        Spacer()
      } else if loading && sessions.isEmpty {
        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if matches.isEmpty {
        VStack(spacing: 10) {
          Image(systemName: "bubble.left.and.bubble.right").font(.largeTitle).foregroundStyle(Palette.accent.opacity(0.65))
          Text(filter.isEmpty ? "No discussions yet" : "No matching discussions").font(.headline)
          Text("Use New discussion beside the history button. Your first message saves it with this paper.")
            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVStack(spacing: 8) {
            ForEach(matches) { session in
              Button {
                showHistory = false
                Task { await model.openPaperSession(session.id, paper: paper) }
              } label: {
                HStack(alignment: .top, spacing: 10) {
                  Image(systemName: session.id == model.sessionID ? "bubble.left.fill" : "bubble.left").foregroundStyle(Palette.accent).padding(.top, 2)
                  VStack(alignment: .leading, spacing: 6) {
                    Text(session.title).font(.system(size: 13, weight: .medium)).lineLimit(2).foregroundStyle(.primary)
                    Text(workspaceDate(session.string("updated_at")) + " · \(session.int("message_count")) messages" + (session.string("status") == "running" ? " · Working…" : ""))
                      .font(.system(size: 11)).foregroundStyle(.secondary)
                  }.frame(maxWidth: .infinity, alignment: .leading)
                  if session.id == model.sessionID { Image(systemName: "checkmark").font(.caption).foregroundStyle(Palette.accent) }
                }.padding(12).background(Palette.accent.opacity(session.id == model.sessionID ? 0.09 : 0.035), in: RoundedRectangle(cornerRadius: 10))
                  .contentShape(Rectangle())
              }.buttonStyle(.plain)
            }
          }
        }
      }
    }.padding(18).frame(width: 365, height: 390)
  }
  private func load() async {
    do {
      let result = try await model.request("/v2/paper-sessions?document_id=" + paper.id)
      try Task.checkCancellation()
      sessions = model.rows(result)
      loadError = nil
    } catch is CancellationError { return }
      catch { if !Task.isCancelled { loadError = error.localizedDescription } }
    loading = false
  }
}

struct ResearchAssistant: View {
  @ObservedObject var model: WorkspaceModel
  @ObservedObject private var pdf: PDFContextStore
  @State private var inputHeight: CGFloat = 90
  @State private var showModelControls = false
  @State private var answers: [String: String] = [:]
  init(model: WorkspaceModel) {
    self.model = model
    self.pdf = model.pdf
  }
  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Text("Research assistant").font(.headline)
        Spacer()
        if let paper = model.selected, paper.string("kind") == "pdf" {
          PaperDiscussions(model: model, paper: paper).id(paper.id)
        }
        Button { model.newChat() } label: { Image(systemName: "square.and.pencil") }.buttonStyle(.plain).help("New discussion")
        Button { model.showAssistant = false } label: { Image(systemName: "sidebar.right") }.buttonStyle(.plain).help("Collapse assistant")
      }.padding(.horizontal, 16).padding(.vertical, 14)
      Divider()
      TranscriptView(
        viewModel: model.chat, onPage: model.pdf.goToPage,
        onRetry: { model.input = "Continue the unfinished work from the previous turn." }, onResearchLink: model.handleLink, workspaceMode: true, onPrompt: { model.input = $0 })
      if !model.approvals.isEmpty { approvalPane }
      Divider()
      composer
    }.background(Color.white)
      .onChange(of: model.remember) { _, value in UserDefaults.standard.set(value, forKey: "ros.remember") }
  }
  private var composer: some View {
    VStack(alignment: .leading, spacing: 10) {
      if !model.attached.isEmpty {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack {
            ForEach(model.attached, id: \.self) { id in
              HStack(spacing: 5) {
                Image(systemName: "paperclip")
                Text(model.documents.first { $0.id == id }?.title ?? id).lineLimit(1).frame(
                  maxWidth: 180)
                Button {
                  model.attached.removeAll { $0 == id }
                } label: {
                  Image(systemName: "xmark")
                }.buttonStyle(.plain)
              }.font(.caption).padding(7).background(
                Palette.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
            }
          }
        }
      }
      if let quote = pdf.quote {
        HStack(alignment: .top) {
          Text("Page \(quote.page) · " + quote.text).font(.caption).lineLimit(3)
          Spacer()
          Button {
            pdf.quote = nil
          } label: {
            Image(systemName: "xmark")
          }.buttonStyle(.plain)
        }.padding(10).background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
      }
      VStack(spacing: 0) {
        ZStack(alignment: .topLeading) {
          if model.input.isEmpty {
            Text(model.busy ? "Add guidance to the current task…" : "Ask about your research…").font(.system(size: 14)).foregroundStyle(.tertiary).padding(.leading, 13).padding(.top, 12).allowsHitTesting(false)
          }
          ChatInputTextView(text: $model.input, onSend: { Task { await model.send() } },
            onPasteImage: { _ in model.error = "Attach a paper from the library to discuss its pages." },
            onTextChange: {}, onHeightChange: { inputHeight = min(max($0, 90), 220) }, focusObject: model)
            .frame(height: inputHeight)
        }
        HStack {
          if model.busy { ProgressView().controlSize(.small) }
          Button { showModelControls.toggle() } label: {
            HStack(spacing: 5) {
              Text(model.models.first { $0.id == model.model }?.string("displayName") ?? "Choose model").fontWeight(.medium)
              if !model.effort.isEmpty { Text(model.effort.capitalized).foregroundStyle(.secondary) }
              Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }.font(.system(size: 12)).lineLimit(1).padding(.horizontal, 10).padding(.vertical, 7)
              .background(Color.black.opacity(0.035), in: Capsule())
          }.buttonStyle(.plain).help("Model and thinking effort")
            .disabled(model.busy || model.sending)
            .popover(isPresented: $showModelControls, arrowEdge: .top) { modelControls }
            .onChange(of: model.model) { _, _ in model.normalizeEffort() }
          Spacer()
          if model.busy {
            Button { Task { await model.perform("/v2/stop", ["session_id": model.sessionID]) } } label: {
              Image(systemName: "stop.fill").frame(width: 22, height: 22)
            }.buttonStyle(.borderedProminent).help("Stop")
          }
          if !model.busy || !model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Button { Task { await model.send() } } label: {
              Image(systemName: model.busy ? "arrow.turn.up.right" : "arrow.up").fontWeight(.semibold).frame(width: 22, height: 22)
            }.buttonStyle(.borderedProminent)
              .accessibilityLabel(model.busy ? "Send guidance" : "Send message")
              .help(model.busy ? "Guide the current task (Return)" : "Send (Return); Shift+Return for a new line")
              .disabled(model.sending || (model.busy && !model.canSteer) || model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          }
        }.padding(.horizontal, 12).padding(.bottom, 10)
      }.background(Color.white).clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Palette.accent.opacity(0.20), lineWidth: 1))
        .shadow(color: Palette.accent.opacity(0.04), radius: 8, y: 2)
      HStack(spacing: 12) {
        Toggle("Memory", isOn: $model.remember).disabled(model.busy || model.sending).help("Save and retrieve durable research memory")
        Toggle("Analysis files", isOn: $model.execution).disabled(model.busy || model.sending).help("Allow saving scripts and results in the app’s artifacts folder")
        Spacer(minLength: 0)
        Toggle(isOn: $model.webSearch) {
          Label(model.webSearch ? "Web on" : "Web off", systemImage: "globe")
            .font(.system(size: 11, weight: .medium))
        }
        .toggleStyle(.button).buttonStyle(.plain).disabled(model.busy || model.sending)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .foregroundStyle(model.webSearch ? Palette.accent : Color.secondary)
        .background(model.webSearch ? Palette.accent.opacity(0.09) : Color.black.opacity(0.035), in: Capsule())
        .accessibilityLabel("Web search")
        .disabled(model.busy)
        .help(model.busy ? "Wait for this reply to finish before changing web search" : (model.webSearch ? "Web and academic search are on. Click to turn off." : "Web and academic search are off. Click to turn on."))
      }.toggleStyle(.switch).controlSize(.mini).font(.system(size: 11)).padding(.horizontal, 4)
    }.padding(14)
  }
  private var modelControls: some View {
    VStack(spacing: 16) {
      Menu {
        ForEach(model.models) { row in
          Button { model.model = row.id; model.normalizeEffort() } label: {
            if model.model == row.id { Label(row.string("displayName"), systemImage: "checkmark") } else { Text(row.string("displayName")) }
          }
        }
      } label: {
        HStack(spacing: 4) {
          Text(model.models.first { $0.id == model.model }?.string("displayName") ?? "Select model")
          Image(systemName: "chevron.right").font(.caption)
        }.foregroundStyle(.secondary)
      }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
      if model.supportedEfforts.count > 1 {
        EffortTrack(options: model.supportedEfforts, selection: $model.effort)
        HStack {
          Text(model.supportedEfforts.first?.capitalized ?? "")
          Spacer()
          Text(model.effort.capitalized).font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.accent)
          Spacer()
          Text(model.supportedEfforts.last?.capitalized ?? "")
        }.font(.caption2).foregroundStyle(.secondary)
      } else {
        Text(model.effort.isEmpty ? "Default" : model.effort.capitalized).foregroundStyle(Palette.accent)
      }
    }.padding(22).frame(width: 275).background(Color.white)
  }
  private var approvalPane: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 10) {
        ForEach(model.approvals) { r in
          let params = r.raw["params"] as? [String: Any] ?? [:]
          Text("Your input is needed").font(.headline)
          Text(
            (params["reason"] as? String) ?? (params["command"] as? String) ?? r.string("method")
          ).font(.caption).textSelection(.enabled)
          if let questions = params["questions"] as? [[String: Any]] {
            ForEach(Array(questions.enumerated()), id: \.offset) { _, q in
              let id = q["id"] as? String ?? "answer"
              Text(q["question"] as? String ?? "")
              TextField(
                "Your answer", text: Binding(get: { answers[id] ?? "" }, set: { answers[id] = $0 })
              ).textFieldStyle(.roundedBorder)
            }
          }
          if let permissions = params["permissions"],
            let data = try? JSONSerialization.data(
              withJSONObject: permissions, options: .prettyPrinted),
            let text = String(data: data, encoding: .utf8)
          {
            Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
          }
          HStack {
            Button("Allow / Submit") {
              Task {
                await model.perform(
                  "/v2/approval", ["key": r.string("key"), "accept": true, "answers": answers])
              }
            }.buttonStyle(.borderedProminent)
            Button("Decline") {
              Task {
                await model.perform("/v2/approval", ["key": r.string("key"), "accept": false])
              }
            }
          }
        }
      }.padding(14)
    }.frame(maxHeight: 260).background(Color.orange.opacity(0.08))
  }
}

struct RecordComposer: View {
  @ObservedObject var model: WorkspaceModel
  @Environment(\.dismiss) private var dismiss
  @State private var title = ""
  @State private var bodyText = ""
  @State private var summary = ""
  @State private var progress = ""
  @State private var project = ""
  @State private var status = "active"
  @State private var source = "user"
  @State private var saving = false
  private var isResearchRecord: Bool { ["project", "idea"].contains(model.composeKind) }
  private var statuses: [String] {
    isResearchRecord ? ["doing", "todo", "paused", "archived", "done"]
      : ["active", "exploring", "testing", "blocked", "paused", "done", "archived", "todo", "doing", "superseded", "disputed"]
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack {
        Text((model.editRecord == nil ? "New " : "Edit ") + (labels[model.composeKind] ?? "Record")).font(
          .title2
        ).fontWeight(.semibold)
        Spacer()
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
      }
      TextField("Title", text: $title).textFieldStyle(.roundedBorder).font(.title3)
      HStack {
        Picker("Project", selection: $project) {
          Text("Global").tag("")
          ForEach(model.objects.filter { $0.string("kind") == "project" }) {
            Text($0.title).tag($0.id)
          }
        }
        Picker("Status", selection: $status) {
          ForEach(statuses, id: \.self) { value in
            Group {
              if isResearchRecord { Text("\(value == "doing" ? "🟢" : "🔴") \(value.capitalized)") }
              else { Text(value.capitalized) }
            }.tag(value)
          }
        }
      }
      if ["project", "idea"].contains(model.composeKind) {
        TextField("Short overview · shown on the card", text: $summary).textFieldStyle(.roundedBorder)
        TextField("Progress summary · where things stand", text: $progress).textFieldStyle(.roundedBorder)
      }
      Text("Details · Progress, evidence, open questions and next steps").font(.caption).foregroundStyle(.secondary)
      TextEditor(text: $bodyText).font(.system(size: 14)).frame(minHeight: 250).border(
        Color.secondary.opacity(0.2))
      if model.composeKind == "memory" {
        TextField("Source", text: $source).textFieldStyle(.roundedBorder)
      }
      HStack {
        Text("Source and change history are saved automatically").font(.caption).foregroundStyle(.secondary)
        Spacer()
        Button("Save") { save() }.buttonStyle(.borderedProminent).keyboardShortcut(
          .return, modifiers: .command
        ).disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)
      }
    }.padding(26).frame(width: 660)
      .onAppear {
        if let r = model.editRecord {
          title = r.title
          bodyText = r.string("body")
          summary = r.data["summary"] as? String ?? ""
          progress = r.data["progress_summary"] as? String ?? ""
          project = r.string("project_id")
          status = r.string("status")
          source = r.data["source"] as? String ?? "user"
        } else {
          project = model.project
          status = isResearchRecord || model.composeKind == "task" ? "todo" : "active"
        }
      }
  }
  private func save() {
    saving = true
    Task {
      defer { saving = false }
      var record = model.editRecord?.raw ?? [:]
      record["kind"] = model.composeKind
      record["title"] = title
      record["body"] = bodyText
      record["project_id"] = project
      record["status"] = status
      var data = model.editRecord?.data ?? [:]
      data["source"] = source
      if ["project", "idea"].contains(model.composeKind) { data["summary"] = summary; data["progress_summary"] = progress }
      record["data"] = data
      do {
        let saved =
          try await model.request(
            "/v2/record", body: ["record": record, "id": model.editRecord?.id as Any? ?? NSNull()])
          as? [String: Any] ?? [:]
        await model.refresh()
        model.selected = Row(raw: saved)
        dismiss()
      } catch { model.error = error.localizedDescription }
    }
  }
}

struct WorkspaceSettings: View {
  @ObservedObject var model: WorkspaceModel
  @AppStorage("ros.show-menu-bar") private var showMenuBar = false
  @State private var autoIndex = false
  @State private var backups: [String] = []
  @State private var restorePath = ""
  @State private var confirmation = ""
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        Text("Connected folders").font(.title3).fontWeight(.semibold)
        HStack {
          ForEach(["papers", "notes", "repo", "results", "data"], id: \.self) { kind in
            Button(labels[kind] ?? kind) { model.attachDirectory(kind: kind) }
          }
        }
        ForEach(model.roots) { r in
          VStack(alignment: .leading, spacing: 10) {
            HStack {
              Label(r.title, systemImage: symbols[r.string("kind")] ?? "folder").font(.headline)
              Spacer()
              Button(["repo", "data"].contains(r.string("kind")) ? "Refresh folder entries" : "Refresh library") { Task { await model.perform("/v2/scan", ["id": r.id]) } }
              if r.string("kind") == "papers" {
                Button("Organize papers") {
                  Task {
                    await model.perform(
                      "/v2/scan", ["id": r.id, "organize": true], success: "Paper organization queued")
                  }
                }
              }
            }
            Text(r.string("path")).font(.caption).textSelection(.enabled)
            if !r.string("error").isEmpty {
              Text(r.string("error")).font(.caption).foregroundStyle(.orange)
            }
            HStack {
              Text("Updated: " + (r.string("last_scan").isEmpty ? "Not refreshed yet" : r.string("last_scan"))).font(
                .caption2
              ).foregroundStyle(.secondary)
              Spacer()
              Button("Disconnect", role: .destructive) {
                Task { await model.perform("/v2/disconnect", ["id": r.id]) }
              }.font(.caption)
            }
          }.padding(16).background(.background, in: RoundedRectangle(cornerRadius: 12))
        }
        Toggle("Check folders automatically while the app is open (every 90 seconds)", isOn: $autoIndex).onChange(of: autoIndex) { _, v in
          Task { await model.perform("/v2/settings", ["auto_index": v]) }
        }
        Divider()
        Toggle("Show menu bar icon", isOn: $showMenuBar)
        Toggle("Show desktop research card", isOn: Binding(get: { model.desktopWidget }, set: { model.setDesktopWidget($0) }))
        Text("Drag the card anywhere on your desktop. It stays available when the main window is closed and hides when the app quits.").font(.caption).foregroundStyle(.secondary)
        Text(model.widgetStatus).font(.caption).foregroundStyle(.secondary)
        HStack {
          Text("Codex and history import").font(.title3).fontWeight(.semibold)
          Spacer()
          Button("Setup assistant") { model.showSetup = true }
        }
        Text(model.connection).foregroundStyle(.secondary)
        HStack {
          Button("Sign in with ChatGPT") { Task { await model.login() } }
          Button("Reconnect") { Task { await model.connectAgent() } }
        }
        HStack {
          Button("Import Research OS 1.0 records") {
            Task { await model.perform("/v2/import-legacy", [:], success: "Legacy records imported. Duplicates are skipped.") }
          }
          Button("Import PDFChat history") {
            Task { await model.perform("/v2/import-pdfchat", [:], success: "PDFChat text history and references imported") }
          }
        }
        Text("The legacy experiment database is copied into separate storage. Original PDFChat history and attachments stay in place. Open the API reader from the menu; its API keys use separate Keychain entries.").font(
          .caption
        ).foregroundStyle(.secondary)
        Divider()
        Text("Backup and restore").font(.title3).fontWeight(.semibold)
        HStack {
          Button("Create snapshot") {
            Task {
              await model.perform("/v2/backup", [:], success: "Workspace snapshot created")
              await loadBackups()
            }
          }
          Button("Export JSON") { Task { await model.exportWorkspace() } }
          Button("Open app data folder") { NSWorkspace.shared.open(WorkspaceModel.dataDirectory) }
          Button("Refresh snapshots") { Task { await loadBackups() } }
        }
        if !backups.isEmpty {
          Picker("Snapshot", selection: $restorePath) {
            Text("Choose a snapshot").tag("")
            ForEach(backups, id: \.self) {
              Text(URL(fileURLWithPath: $0).lastPathComponent).tag($0)
            }
          }
          HStack {
            TextField("Type RESTORE to replace the workspace", text: $confirmation).textFieldStyle(.roundedBorder)
            Button("Restore snapshot", role: .destructive) {
              Task {
                await model.perform(
                  "/v2/restore", ["path": restorePath, "confirmation": confirmation],
                  success: "Snapshot restored")
                model.newChat()
                model.selected = nil
                confirmation = ""
              }
            }.disabled(restorePath.isEmpty || confirmation != "RESTORE")
          }
        }
        Text("Snapshots contain workspace records, library cache and discussions. External papers, code and model weights are not copied. Experiments have separate backups. A snapshot is created before restoring.").font(.caption)
          .foregroundStyle(.secondary)
        Divider()
        Text("Background tasks").font(.title3).fontWeight(.semibold)
        ForEach(model.jobs) { j in
          VStack(alignment: .leading, spacing: 6) {
            HStack {
              Text(j.string("kind") + " · " + j.string("status")).font(.headline)
              Spacer()
              if ["queued", "running"].contains(j.string("status")) { Button("Stop") { Task { await model.perform("/v2/cancel-job", ["id": j.id]) } } }
            }
            Text(j.string("detail")).font(.system(.caption, design: .monospaced)).textSelection(
              .enabled)
          }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(
            .background, in: RoundedRectangle(cornerRadius: 10))
        }
      }.padding(26)
    }.task {
      await loadBackups()
      if let settings = try? await model.request("/v2/settings") as? [String: Any] { autoIndex = settings["auto_index"] as? Bool ?? false }
    }
  }
  private func loadBackups() async {
    do { backups = try await model.request("/v2/backups") as? [String] ?? [] } catch {
      model.error = error.localizedDescription
    }
  }
}

struct EffortTrack: View {
  let options: [String]
  @Binding var selection: String
  private var index: Int { options.firstIndex(of: selection) ?? 0 }
  var body: some View {
    GeometryReader { geometry in
      let width = max(1, geometry.size.width - 30)
      let fraction = CGFloat(index) / CGFloat(max(1, options.count - 1))
      ZStack(alignment: .leading) {
        Capsule().fill(Color.black.opacity(0.08)).frame(height: 25)
        Capsule().fill(Palette.accent).frame(width: 15 + width * fraction, height: 25)
        ForEach(options.indices, id: \.self) { i in
          Circle().fill(Color.primary.opacity(0.24)).frame(width: 4, height: 4)
            .offset(x: 13 + width * CGFloat(i) / CGFloat(max(1, options.count - 1)))
        }
        Circle().fill(Color.white).frame(width: 30, height: 30)
          .shadow(color: .black.opacity(0.16), radius: 2, y: 1).offset(x: width * fraction)
      }.frame(height: 34).contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { event in
          let step = Int(((event.location.x - 15) / width * CGFloat(options.count - 1)).rounded())
          selection = options[min(max(step, 0), options.count - 1)]
        })
    }.frame(height: 34).accessibilityElement().accessibilityLabel("Thinking effort").accessibilityValue(selection.capitalized)
      .accessibilityAdjustableAction { direction in
        let next = direction == .increment ? min(index + 1, options.count - 1) : max(index - 1, 0)
        selection = options[next]
      }
  }
}
