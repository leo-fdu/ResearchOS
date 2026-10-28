import AppKit
import SwiftUI

extension WorkspaceModel {
  func editMarkdown(_ row: Row) async {
    do {
      guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "abnerworks.Typora") else { throw NSError(domain: "ResearchOS", code: 1, userInfo: [NSLocalizedDescriptionKey: "Install Typora to edit Markdown."]) }
      let result = try await request("/v2/markdown?id=" + row.id) as? [String: Any] ?? [:]
      guard let path = result["path"] as? String else { return }
      let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true
      try await NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: app, configuration: configuration)
      notice = "Opened in Typora. Saved changes sync back automatically."
    } catch { self.error = error.localizedDescription }
  }
}

struct ExperimentJournal: View {
  @ObservedObject var model: WorkspaceModel
  let owner: Row
  var fixture: [Row]? = nil
  @State private var entries: [Row] = []
  @State private var creating = false
  @State private var editing: Row?
  @State private var deleting: Row?
  private var version: String { model.objects.filter { $0.data["owner_id"] as? String == owner.id }.map { $0.id + $0.string("updated_at") }.joined() }
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack { Label("Experiment log", systemImage: "chart.xyaxis.line").font(.headline); Spacer(); Button("Add entry") { creating = true } }
      if entries.isEmpty { Text("Keep new results, exploratory findings and your analysis together.").foregroundStyle(.secondary).font(.callout) }
      ForEach(entries) { entry in
        VStack(alignment: .leading, spacing: 10) {
          HStack { Text(entry.title).font(.headline); Spacer(); Text(workspaceDate(entry.string("created_at"))).font(.caption).foregroundStyle(.secondary) }
          if !entry.string("body").isEmpty { Text(entry.string("body")).lineLimit(5).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) }
          ExperimentAttachments(items: entry.data["attachments"] as? [[String: Any]] ?? [])
          HStack {
            
            Button("Edit in Typora") { Task { await model.editMarkdown(entry) } }
            Button("Manage images") { editing = entry }
            Button("Delete entry", role: .destructive) { deleting = entry }
          }.controlSize(.small)
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Palette.accent.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
      }
    }.task(id: owner.id + version) { await load() }
      .sheet(isPresented: $creating) { JournalComposer(model: model, owner: owner) }
      .sheet(item: $editing) { entry in JournalComposer(model: model, owner: owner, entry: entry) }
      .confirmationDialog("Delete this experiment log?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
        if let entry = deleting {
          Button("Delete entry", role: .destructive) { Task {
            do {
              _ = try await model.request("/v2/delete", body: ["id": entry.id, "revision": entry.int("revision")])
              await model.refresh(); await load()
            } catch { model.error = error.localizedDescription; await load() }
          } }
        }
      }
  }
  private func load() async {
    if let fixture { entries = fixture; return }
    do { entries = model.rows(try await model.request("/v2/journal?owner_id=" + owner.id)) } catch { model.error = error.localizedDescription }
  }

}

enum JournalClipboard {
  static func images(from pasteboard: NSPasteboard, directory: URL) throws -> [URL] {
    let files = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
      .filter { NSImage(contentsOf: $0) != nil }
    if !files.isEmpty { return files }
    guard let image = NSImage(pasteboard: pasteboard), let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else { return [] }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("Pasted-image-" + UUID().uuidString + ".png")
    try png.write(to: url, options: .atomic)
    return [url]
  }
}

struct JournalComposer: View {
  @ObservedObject var model: WorkspaceModel
  let owner: Row
  var entry: Row? = nil
  @Environment(\.dismiss) private var dismiss
  @State private var title = ""
  @State private var bodyText = ""
  @State private var paths: [String] = []
  @State private var captions: [String: String] = [:]
  @State private var temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("ResearchOS-paste-" + UUID().uuidString)
  @State private var localError: String?
  @State private var saving = false
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack { Text(entry == nil ? "New experiment log" : "Edit experiment log").font(.title2); Spacer(); Button("Cancel") { dismiss() } }
      Text(owner.title).foregroundStyle(.secondary)
      TextField("Experiment or exploration title", text: $title).textFieldStyle(.roundedBorder)
      Text("Write and edit the Markdown text in Typora. Add or remove images here.").font(.callout).foregroundStyle(.secondary)
      if !paths.isEmpty {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 16) {
            ForEach(paths, id: \.self) { path in
              VStack(alignment: .leading, spacing: 8) {
                HStack {
                  Text(URL(fileURLWithPath: path).lastPathComponent).lineLimit(1); Spacer()
                  Button { paths.removeAll { $0 == path }; captions.removeValue(forKey: path) } label: { Image(systemName: "xmark") }.help("Remove attachment")
                }
                ExperimentAttachment(path: path)
                TextField("Figure caption or attachment description", text: Binding(get: { captions[path] ?? "" }, set: { captions[path] = $0 })).textFieldStyle(.roundedBorder)
              }
            }
          }.padding(4)
        }.frame(height: 220)
      }
      HStack {
      Button("Choose images or files…") {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.canChooseDirectories = true
        if panel.runModal() == .OK { for url in panel.urls where !paths.contains(url.path) { paths.append(url.path) } }
      }
      Button("Paste image") { pasteImages() }.keyboardShortcut("v", modifiers: [.command, .shift])
      }
      if let localError { Text(localError).foregroundStyle(.red).font(.caption) }
      Text("Images, PDF figures and CSV tables appear directly in the log. Click a figure or expand a table for details.").font(.caption).foregroundStyle(.secondary)
      Text("Files up to 100 MB are copied. Larger files and folders stay linked to their original location.").font(.caption).foregroundStyle(.secondary)
      HStack { Spacer(); Button(entry == nil ? "Create and edit in Typora" : "Save changes") { save() }.buttonStyle(.borderedProminent).disabled(saving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
    }.padding(24).frame(width: 640)
      .onAppear {
        if let entry {
          title = entry.title; bodyText = entry.string("body")
          for item in entry.data["attachments"] as? [[String: Any]] ?? [] {
            if let path = item["path"] as? String { paths.append(path); captions[path] = item["caption"] as? String ?? "" }
          }
        }
      }
      .onDisappear { try? FileManager.default.removeItem(at: temporaryDirectory) }
  }
  private func pasteImages() {
    do {
      let urls = try JournalClipboard.images(from: .general, directory: temporaryDirectory)
      localError = urls.isEmpty ? "Copy an image or an image file first." : nil
      for url in urls where !paths.contains(url.path) { paths.append(url.path) }
    } catch { localError = error.localizedDescription }
  }
  private func save() {
    saving = true
    Task {
      defer { saving = false }
      do {
        var record: [String: Any]
        if let entry {
          // Sync external Markdown first; attachment changes must not overwrite Typora edits.
          let rows = model.rows(try await model.request("/v2/journal?owner_id=" + owner.id))
          guard let current = rows.first(where: { $0.id == entry.id }) else { throw NSError(domain: "ResearchOS", code: 1, userInfo: [NSLocalizedDescriptionKey: "This log was deleted."]) }
          guard (current.data["attachments"] as? NSArray ?? []) == (entry.data["attachments"] as? NSArray ?? []), current.title == entry.title else { throw NSError(domain: "ResearchOS", code: 1, userInfo: [NSLocalizedDescriptionKey: "Images or title changed in another window. Reopen this editor."]) }
          record = current.raw
        } else { record = ["kind": "note", "body": bodyText] }
        record["title"] = title
        var data = record["data"] as? [String: Any] ?? ["entry_type": "experiment_log", "owner_id": owner.id]
        let previous = data["attachments"] as? [[String: Any]] ?? []
        data["attachments"] = paths.map { path -> [String: Any] in
          var item = previous.first { $0["path"] as? String == path } ?? ["path": path]
          item["caption"] = captions[path] ?? ""; return item
        }
        record["data"] = data
        var payload: [String: Any] = ["record": record]
        if let entry { payload["id"] = entry.id }
        let result = try await model.request("/v2/record", body: payload) as? [String: Any] ?? [:]
        await model.refresh(); dismiss()
        if entry == nil { await model.editMarkdown(Row(raw: result)) }
      } catch { localError = error.localizedDescription }
    }
  }
}

struct PaperNoteComposer: View {
  @ObservedObject var model: WorkspaceModel
  let paper: Row
  @Environment(\.dismiss) private var dismiss
  @State private var title = ""
  @State private var saving = false
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack { Text("New paper note").font(.title2); Spacer(); Button("Cancel") { dismiss() } }
      Text(paper.title).foregroundStyle(.secondary).lineLimit(3)
      TextField("Note title", text: $title).textFieldStyle(.roundedBorder)
      Text("Saved to notes/paper and linked to this paper. Typora opens for writing.").font(.caption).foregroundStyle(.secondary)
      HStack { Spacer(); Button("Create note") { create() }.buttonStyle(.borderedProminent).disabled(saving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
    }.padding(24).frame(width: 560).onAppear { title = String(paper.title.prefix(220)) + " — Notes" }
  }
  private func create() {
    saving = true
    Task {
      defer { saving = false }
      do {
        let record: [String: Any] = ["kind": "note", "title": title, "body": "# " + title + "\n\n[Source paper](researchos://document/" + paper.id + ")\n\n", "project_id": model.project, "data": ["paper_id": paper.id, "category": "paper"]]
        let saved = try await model.request("/v2/record", body: ["record": record]) as? [String: Any] ?? [:]
        await model.refresh(); dismiss(); await model.editMarkdown(Row(raw: saved))
      } catch { model.error = error.localizedDescription }
    }
  }
}
