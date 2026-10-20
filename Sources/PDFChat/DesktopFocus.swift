import AppKit
import SwiftUI

@MainActor final class DesktopFocusController {
  static let shared = DesktopFocusController()
  private var panel: NSPanel?
  func show(model: WorkspaceModel) {
    if let panel { panel.orderFrontRegardless(); return }
    let frame = NSRect(x: 40, y: 100, width: 330, height: 280)
    let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
    panel.title = "Research OS · Desktop research card"
    panel.identifier = NSUserInterfaceItemIdentifier("researchos-desktop-card")
    panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
    panel.hidesOnDeactivate = false; panel.isMovableByWindowBackground = true
    panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
    panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    panel.minSize = NSSize(width: 280, height: 220)
    panel.contentView = NSHostingView(rootView: DesktopFocusView(model: model))
    panel.setFrameAutosaveName("ResearchOSDesktopCard")
    if !panel.setFrameUsingName("ResearchOSDesktopCard"), let screen = NSScreen.main {
      panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.minX + 40, y: screen.visibleFrame.maxY - 330))
    }
    self.panel = panel; panel.orderFrontRegardless()
  }
  func hide() { panel?.orderOut(nil) }
}
struct DesktopFocusView: View {
  @ObservedObject var model: WorkspaceModel
  private var tasks: [Row] { model.objects.filter { $0.string("kind") == "task" && !["done", "archived"].contains($0.string("status")) } }
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Image(systemName: "sparkle.magnifyingglass").foregroundStyle(Palette.accent)
        Text("Research OS").font(.headline)
        Spacer()
        Button { model.openWorkspace?(); model.compose("idea") } label: { Image(systemName: "plus.circle") }.buttonStyle(.plain).help("Capture Idea")
        Button { model.setDesktopWidget(false) } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("Hide desktop card")
      }
      if let project = model.objects.first(where: { $0.string("kind") == "project" && $0.string("status") != "archived" }) {
        Button { model.selected = project; model.openWorkspace?() } label: { Text(project.title).font(.title3).fontWeight(.semibold).lineLimit(2) }.buttonStyle(.plain)
      } else {
        Text("What will you investigate next?").font(.title3).fontWeight(.medium)
      }
      if tasks.isEmpty {
        Text("Capture an idea and develop it into a plan with your assistant.").font(.callout).foregroundStyle(.secondary)
      } else {
        ForEach(tasks.prefix(3)) { task in
          HStack {
            Button {
              Task { var record = task.raw; record["status"] = "done"; await model.perform("/v2/record", ["id": task.id, "record": record]) }
            } label: { Image(systemName: "circle") }.buttonStyle(.plain).help("Mark complete")
            Button { model.selected = task; model.openWorkspace?() } label: { Text(task.title).font(.callout).lineLimit(2) }.buttonStyle(.plain)
          }
        }
      }
      Spacer(minLength: 0)
      HStack {
        Text("\(model.documentCount.formatted()) resources").font(.caption).foregroundStyle(.secondary)
        Spacer()
        Button("Open workspace ↗") { model.openWorkspace?() }.buttonStyle(.plain).foregroundStyle(Palette.accent).font(.caption)
      }
    }.padding(22).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
      .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.3), lineWidth: 1))
      .clipShape(RoundedRectangle(cornerRadius: 22))
  }
}
