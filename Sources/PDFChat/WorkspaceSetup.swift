import AppKit
import SwiftUI

/// Shared by first launch and Settings, so setup can be skipped and resumed.
struct WorkspaceSetup: View {
  @ObservedObject var model: WorkspaceModel
  var body: some View {
    VStack(alignment: .leading, spacing: 22) {
      HStack {
        Image(systemName: "books.vertical").font(.system(size: 32)).foregroundStyle(Palette.accent)
        VStack(alignment: .leading, spacing: 4) {
          Text("Welcome to Research OS").font(.title2.bold())
          Text("Your research, connected on this Mac.").foregroundStyle(.secondary)
        }
        Spacer()
      }
      ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          section("Local workspace", icon: "checkmark.circle.fill") {
            Text("Ready. PDF reading and your research workspace work locally. Python and PDF processing are included in the shared edition.")
          }
          section("Research assistant", icon: "bubble.left.and.bubble.right") {
            Text(model.connection).fontWeight(.medium)
            Text("Install Codex, then sign in with your own ChatGPT account. Your account determines available models and usage limits.")
            HStack {
              Button(model.installingCodex ? "Installing…" : "Install Codex") {
                Task { await model.installCodex() }
              }.disabled(model.installingCodex || model.codexAvailable)
              Button("Sign in") { Task { await model.login() } }.disabled(!model.codexAvailable)
              Button("Check connection") { Task { await model.connectAgent(silent: true) } }
                .disabled(model.installingCodex)
            }
            Text("Downloads from OpenAI’s official GitHub release into your application data folder. No administrator password or Homebrew required.")
              .font(.caption).foregroundStyle(.secondary)
            if !model.setupMessage.isEmpty {
              Text(model.setupMessage).font(.caption).textSelection(.enabled)
            }
            if let notice = model.notice { Text(notice).font(.caption).foregroundStyle(Palette.accent) }
            Link("Manual installation instructions", destination: URL(string: "https://github.com/openai/codex#quickstart")!)
              .font(.caption)
          }
          section("Connect your folders", icon: "folder") {
            Text("Choose only the folders you want to use. Files stay where they are; repositories and datasets get one entry per top-level folder.")
            HStack {
              ForEach(["papers", "notes", "repo", "data"], id: \.self) { kind in
                Button(labels[kind] ?? kind) { model.attachDirectory(kind: kind) }
              }
            }
            ForEach(model.roots) { root in
              Label(root.title, systemImage: "folder.fill").font(.caption).foregroundStyle(Palette.accent)
            }
            Text("For Organize, choose a paper library containing a pdf folder. Reading works with ordinary PDF folders too. OCR for scanned pages requires optional Tesseract.")
              .font(.caption).foregroundStyle(.secondary)
          }
          Text("Research OS stores your own records on this Mac. Content read by the assistant is sent to the model service. No one else’s account, papers or research history is included.")
            .font(.caption).foregroundStyle(.secondary)
        }.padding(2)
      }
      HStack {
        Text("You can return here from Settings.").font(.caption).foregroundStyle(.secondary)
        Spacer()
        Button("Open workspace") { model.showSetup = false }
          .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
      }
    }.padding(28).frame(width: 600, height: 660)
      .tint(Palette.accent)
      .interactiveDismissDisabled(model.installingCodex)
  }
  private func section<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Label(title, systemImage: icon).font(.headline).foregroundStyle(Palette.ink)
      content().font(.callout)
    }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.blue.opacity(0.035), in: RoundedRectangle(cornerRadius: 16))
      .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.blue.opacity(0.10)))
  }
}

extension WorkspaceModel {
  func installCodex() async {
    guard !installingCodex else { return }
    guard let resources = Bundle.main.resourceURL else { return }
    let python = resources.appendingPathComponent("python/bin/python3")
    guard FileManager.default.isExecutableFile(atPath: python.path) else {
      setupMessage = "Use the shared edition with bundled Python, or install Codex from the manual instructions."
      return
    }
    installingCodex = true
    setupMessage = "Downloading Codex from OpenAI… This may take a few minutes."
    defer { installingCodex = false }
    do {
      let log = Self.dataDirectory.appendingPathComponent("codex-install.log")
      try Data().write(to: log)
      let handle = try FileHandle(forWritingTo: log)
      defer { try? handle.close() }
      let process = Process()
      process.executableURL = python
      process.arguments = ["-I", resources.appendingPathComponent("service/install_codex.py").path, "--destination", Self.dataDirectory.appendingPathComponent("bin").path]
      process.standardOutput = handle; process.standardError = handle
      let status: Int32 = try await withCheckedThrowingContinuation { continuation in
        process.terminationHandler = { task in continuation.resume(returning: task.terminationStatus) }
        do { try process.run() } catch { continuation.resume(throwing: error) }
      }
      let detail = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
      guard status == 0 else { throw failure(String(detail.suffix(1500))) }
      setupMessage = "Codex installed. Sign in to connect your account."
      await connectAgent(silent: true)
    } catch { setupMessage = "Installation failed: " + error.localizedDescription }
  }
}
