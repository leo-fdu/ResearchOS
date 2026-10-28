import SwiftUI

struct GraphLayout {
  static func positions(ids: [String], edges: [(String, String)]) -> [String: CGPoint] {
    guard !ids.isEmpty else { return [:] }
    let index = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
    let links = edges.compactMap { a, b -> (Int, Int)? in
      guard let i = index[a], let j = index[b], i != j else { return nil }; return (i, j)
    }
    let radius = max(170, sqrt(Double(ids.count)) * 24)
    var points = ids.indices.map { i in CGPoint(x: cos(Double(i) * 2.39996) * radius * sqrt(Double(i + 1) / Double(ids.count)), y: sin(Double(i) * 2.39996) * radius * sqrt(Double(i + 1) / Double(ids.count))) }
    // Bounded deterministic layout; large libraries use sampled repulsion.
    for iteration in 0..<75 {
      var forces = points.map { CGPoint(x: -$0.x * 0.008, y: -$0.y * 0.008) }
      let stride = max(1, ids.count / 400)
      for i in points.indices {
        for j in Swift.stride(from: i + 1, to: points.count, by: stride) {
          let dx = points[i].x - points[j].x, dy = points[i].y - points[j].y
          let d2 = max(64, dx * dx + dy * dy), f = min(5, 1500 / d2)
          let x = dx / sqrt(d2) * f, y = dy / sqrt(d2) * f
          forces[i].x += x; forces[i].y += y; forces[j].x -= x; forces[j].y -= y
        }
      }
      for (i, j) in links {
        let dx = points[j].x - points[i].x, dy = points[j].y - points[i].y
        let distance = max(1, hypot(dx, dy)), f = (distance - 95) * 0.035
        forces[i].x += dx / distance * f; forces[i].y += dy / distance * f
        forces[j].x -= dx / distance * f; forces[j].y -= dy / distance * f
      }
      let step = 1 - Double(iteration) / 100
      for i in points.indices { points[i].x += max(-12, min(12, forces[i].x)) * step; points[i].y += max(-12, min(12, forces[i].y)) * step }
    }
    return Dictionary(uniqueKeysWithValues: zip(ids, points))
  }
}

struct ResearchGraph: View {
  @ObservedObject var model: WorkspaceModel
  @State private var appActive = NSApplication.shared.isActive
  var fixture: [String: Any]? = nil
  @State private var nodes: [Row] = []
  @State private var edges: [Row] = []
  @State private var positions: [String: CGPoint] = [:]
  @State private var query = ""
  @State private var hidden: Set<String> = []
  @State private var selection = ""
  @State private var localOnly = false
  @State private var linking = false
  @State private var automaticFit = true
  @State private var zoom: CGFloat = 1
  @State private var pan = CGSize.zero
  @State private var dragStart = CGSize.zero
  @State private var dragNode = ""
  @State private var dragging = false
  @State private var loading = true
  @State private var viewport = CGSize.zero
  @State private var hoverID = ""
  @State private var gestureZoom: CGFloat?
  @State private var physics = GraphPhysics(ids: [], edges: [], positions: [:])
  @State private var paused = false
  @State private var graphSignature = ""
  @State private var lastClickID = ""
  @State private var lastClickTime = Date.distantPast
  @State private var lastClickPoint = CGPoint.zero
  private var animating: Bool { model.selectedSection == "graph" && model.selected == nil && appActive && !paused && !linking && !nodes.isEmpty && !physics.isSettled }
  private var highlightedID: String { hoverID.isEmpty ? selection : hoverID }
  private var highlightedNeighbors: Set<String> { Set(edges.filter { $0.string("source") == highlightedID || $0.string("target") == highlightedID }.flatMap { [$0.string("source"), $0.string("target")] }) }
  private let kinds = ["project", "idea", "brainstorm", "paper", "note", "repo", "data"]
  private func color(_ kind: String) -> Color {
    switch kind { case "project": return .blue; case "idea": return .orange; case "brainstorm": return .purple; case "paper": return .teal; case "note": return .green; case "repo": return .indigo; default: return .pink }
  }
  private func label(_ kind: String) -> String { ["project":"Projects", "idea":"Ideas", "brainstorm":"Brainstorms", "paper":"Papers", "note":"Notes", "repo":"Repos", "data":"Datasets"][kind] ?? kind }
  private var selected: Row? { nodes.first { $0.id == selection } }
  private var neighbors: Set<String> { Set(edges.filter { $0.string("source") == selection || $0.string("target") == selection }.flatMap { [$0.string("source"), $0.string("target")] }) }
  private var visible: [Row] {
    nodes.filter { node in !hidden.contains(node.string("kind")) && (model.project.isEmpty || node.id == model.project || node.string("project_id") == model.project || edges.contains { ($0.string("source") == model.project && $0.string("target") == node.id) || ($0.string("target") == model.project && $0.string("source") == node.id) }) }
      .filter { (!localOnly || selection.isEmpty || $0.id == selection || neighbors.contains($0.id)) && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.id == selection) }
  }
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        TextField("Find a resource in the graph", text: $query).textFieldStyle(.plain)
        Menu("Types") { ForEach(kinds, id: \.self) { kind in Button { if hidden.contains(kind) { hidden.remove(kind) } else { hidden.insert(kind) } } label: { Label(label(kind), systemImage: hidden.contains(kind) ? "circle" : "checkmark.circle.fill") } } }.fixedSize()
        Button { automaticFit = false; zoom = max(0.02, zoom / 1.2) } label: { Image(systemName: "minus.magnifyingglass") }
        Button { automaticFit = false; zoom = min(4, zoom * 1.2) } label: { Image(systemName: "plus.magnifyingglass") }
        Button { paused.toggle(); if !paused { physics.wake() } } label: { Image(systemName: paused ? "play.fill" : "pause.fill") }.help(paused ? "Resume motion" : "Pause motion").accessibilityLabel(paused ? "Resume motion" : "Pause motion")
        Button { physics.scatter(); paused = false } label: { Image(systemName: "sparkles") }.help("Give the graph a nudge").accessibilityLabel("Play with graph")
        Button("Fit graph") { automaticFit = true; pan = .zero; query = ""; hidden = []; localOnly = false; selection = ""; fit() }
        Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
      }.padding(14)
      Divider()
      ZStack(alignment: .topTrailing) {
        GeometryReader { geometry in
          let displayed = visible
          let ids = Set(displayed.map(\.id))
          let highlightedNeighbors = self.highlightedNeighbors
          Canvas { context, size in
            for edge in edges where ids.contains(edge.string("source")) && ids.contains(edge.string("target")) {
              let a = screen(edge.string("source"), size), b = screen(edge.string("target"), size)
              var path = Path(); path.move(to: a); path.addLine(to: b)
              let highlighted = edge.string("source") == highlightedID || edge.string("target") == highlightedID
              context.stroke(path, with: .color(highlighted ? Palette.accent.opacity(0.65) : Color.secondary.opacity(highlightedID.isEmpty ? 0.19 : 0.08)), lineWidth: highlighted ? 2 : 0.7)
            }
            for node in displayed {
              let p = screen(node.id, size), chosen = node.id == selection || node.id == hoverID
              let radius: CGFloat = chosen ? 8 : node.string("kind") == "project" ? 7 : 5
              if chosen {
                context.fill(Path(ellipseIn: CGRect(x: p.x-17, y: p.y-17, width: 34, height: 34)), with: .color(color(node.string("kind")).opacity(0.12)))
              }
              if physics.pinned.contains(node.id) {
                context.stroke(Path(ellipseIn: CGRect(x: p.x-radius-4, y: p.y-radius-4, width: (radius+4)*2, height: (radius+4)*2)), with: .color(color(node.string("kind"))), lineWidth: 1)
              }
              context.fill(Path(ellipseIn: CGRect(x: p.x-radius, y: p.y-radius, width: radius*2, height: radius*2)), with: .color(color(node.string("kind")).opacity(highlightedID.isEmpty || node.id == highlightedID || highlightedNeighbors.contains(node.id) ? 1 : 0.3)))
            }
            var occupied: [CGRect] = []
            let labelled = displayed.sorted { a, b in
              func priority(_ n: Row) -> Int { n.id == selection ? 0 : n.id == hoverID ? 1 : highlightedNeighbors.contains(n.id) ? 2 : n.string("kind") == "project" ? 3 : 4 }
              return priority(a) < priority(b)
            }
            for node in labelled {
              let chosen = node.id == selection || node.id == hoverID
              if chosen || highlightedNeighbors.contains(node.id) || displayed.count < 65 || zoom > 1.5 || !query.isEmpty || node.string("kind") == "project" {
                let p = screen(node.id, size)
                let title = String(node.title.prefix(chosen ? 48 : 25)) + (node.title.count > (chosen ? 48 : 25) ? "…" : "")
                let text = context.resolve(Text(title).font(.system(size: chosen ? 12 : 10, weight: chosen ? .semibold : .regular)).foregroundColor(.primary))
                let measured = text.measure(in: CGSize(width: 330, height: 40))
                let rect = CGRect(x: p.x - measured.width/2 - 3, y: p.y + 12, width: measured.width + 6, height: measured.height + 5)
                if chosen || !occupied.contains(where: { $0.intersects(rect) }) {
                  occupied.append(rect)
                  context.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(Color(nsColor: .windowBackgroundColor).opacity(0.85)))
                  context.draw(text, at: CGPoint(x: p.x, y: rect.minY + 2), anchor: .top)
                }
              }
            }
          }.contentShape(Rectangle())
            .accessibilityLabel("Interactive research graph")
            .accessibilityChildren {
              ForEach(displayed) { node in
                Button(node.title) { selection = node.id }
                  .accessibilityAction(named: Text("Open resource")) { open(node) }
                  .accessibilityAction(named: Text(physics.pinned.contains(node.id) ? "Unpin node" : "Pin node")) { physics.togglePin(node.id) }
              }
            }
            .onAppear { viewport = geometry.size; fit() }
            .onChange(of: geometry.size) { _, size in viewport = size; if automaticFit { fit() } }
            .onContinuousHover { phase in
              switch phase { case .active(let point): hoverID = nearest(point, size: geometry.size, nodes: displayed) ?? ""; case .ended: hoverID = "" }
            }
            .simultaneousGesture(MagnifyGesture().onChanged { value in automaticFit = false; if gestureZoom == nil { gestureZoom = zoom }; zoom = min(4, max(0.02, (gestureZoom ?? zoom) * value.magnification)) }.onEnded { _ in gestureZoom = nil })
            .overlay(GraphDragSurface(onChanged: { value in
              if !dragging { automaticFit = false; dragging = true; dragStart = pan; dragNode = nearest(value.startLocation, size: geometry.size, nodes: displayed) ?? ""; if !dragNode.isEmpty { physics.wake() } }
              if dragNode.isEmpty { pan = CGSize(width: dragStart.width + value.translation.width, height: dragStart.height + value.translation.height) }
              else if hypot(value.translation.width, value.translation.height) > 3 {
                physics.move(dragNode, to: CGPoint(x: (value.location.x - geometry.size.width/2 - pan.width)/zoom, y: (value.location.y - geometry.size.height/2 - pan.height)/zoom)); positions = physics.positions
              }
            }, onEnded: { value in
              if hypot(value.translation.width, value.translation.height) <= 3 {
                let now = Date()
                if !lastClickID.isEmpty && hypot(value.location.x-lastClickPoint.x,value.location.y-lastClickPoint.y) < 14 && now.timeIntervalSince(lastClickTime) < 0.4, let node = nodes.first(where: { $0.id == lastClickID }) { open(node); lastClickID = "" }
                else { selection = dragNode; lastClickID = dragNode; lastClickTime = now; lastClickPoint = value.location }
              }
              if !dragNode.isEmpty { physics.wake() }
              dragging = false; dragNode = ""
            }))
            .overlay(alignment: .bottomLeading) {
              VStack(alignment: .leading, spacing: 8) {
                Text("\(displayed.count) resources · \(edges.filter { ids.contains($0.string("source")) && ids.contains($0.string("target")) }.count) links").font(.caption)
                Text("Drag a node to tug its neighbors · double-click to open").font(.caption2).foregroundStyle(.secondary)
                HStack(spacing: 6) { Circle().fill(paused ? Color.orange : physics.isSettled ? Color.secondary : Color.green).frame(width: 5, height: 5); Text(paused ? "Motion paused" : physics.isSettled ? "Settled · drag to wake" : "Spring motion").font(.caption2).foregroundStyle(.secondary) }
                HStack(spacing: 10) { ForEach(kinds.filter { !hidden.contains($0) }, id: \.self) { kind in HStack(spacing: 3) { Circle().fill(color(kind)).frame(width: 6, height: 6); Text(label(kind)).font(.system(size: 9)) } } }
              }.padding(14).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10)).padding(12)
            }
            .overlay { if loading { ProgressView() } else if displayed.isEmpty { Text("No matching resources").foregroundStyle(.secondary) } }
        }
        if let node = selected {
          VStack(alignment: .leading, spacing: 16) {
            HStack { Text(label(node.string("kind"))).font(.caption).foregroundStyle(color(node.string("kind"))); Spacer(); Button { selection = ""; localOnly = false } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }
            Text(node.title).font(.headline).textSelection(.enabled)
            Button("Open resource") { open(node) }.buttonStyle(.borderedProminent)
            Button("Link resources") { linking = true }
            Button { physics.togglePin(node.id) } label: { Label(physics.pinned.contains(node.id) ? "Unpin node" : "Pin node", systemImage: physics.pinned.contains(node.id) ? "pin.slash" : "pin") }
            Text(physics.pinned.contains(node.id) ? "Fixed in place. Drag to reposition." : "Pin this node to hold it while its neighbors move.").font(.caption).foregroundStyle(.secondary)
            Toggle("Show only connected resources", isOn: $localOnly).toggleStyle(.checkbox)
            Divider()
            Text("Connections").font(.subheadline.bold())
            ScrollView {
              VStack(alignment: .leading, spacing: 12) {
                ForEach(edges.filter { $0.string("source") == selection || $0.string("target") == selection }) { edge in
                  let targetID = edge.string("source") == selection ? edge.string("target") : edge.string("source")
                  if let target = nodes.first(where: { $0.id == targetID }) {
                    Button { selection = target.id } label: { VStack(alignment: .leading, spacing: 4) { Text(target.title).lineLimit(3); Text(edge.string("relation").replacingOccurrences(of: "_", with: " ")).font(.caption).foregroundStyle(.secondary) } }.buttonStyle(.plain)
                  }
                }
              }
            }
            Spacer(minLength: 0)
          }.padding(18).frame(width: 235).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14)).padding(12)
        }
      }
    }.task { await load() }
      .onAppear { appActive = NSApplication.shared.isActive }
      .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in appActive = true }
      .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in appActive = false }
      .onReceive(NotificationCenter.default.publisher(for: NSWindow.didMiniaturizeNotification)) { note in if let window = note.object as? NSWindow, window === ReaderAppDelegate.workspaceWindow { appActive = false } }
      .onReceive(NotificationCenter.default.publisher(for: NSWindow.didDeminiaturizeNotification)) { note in if let window = note.object as? NSWindow, window === ReaderAppDelegate.workspaceWindow { appActive = NSApplication.shared.isActive } }
      .task(id: animating) {
        guard animating else { return }
        while !Task.isCancelled {
          do { try await Task.sleep(nanoseconds: 33_333_333) } catch { return }
          guard !Task.isCancelled else { return }
          physics.step(holding: dragNode.isEmpty ? nil : dragNode); positions = physics.positions
          if automaticFit { fit(onlyShrink: true) }
          if physics.isSettled { return }
        }
      }
      .onChange(of: visible.map(\.id)) { _, _ in if automaticFit { fit() } }
      .onChange(of: selection) { _, _ in if automaticFit { fit() } }
      .onChange(of: model.selectedSection) { _, section in if section == "graph" { Task { await load() } } }
      .onChange(of: model.edges.map(\.id)) { _, _ in Task { await load() } }
      .sheet(isPresented: $linking, onDismiss: { Task { await load() } }) { if let selected { RelationComposer(model: model, source: selected) } }
  }
  private func open(_ node: Row) { if let url = URL(string: node.string("uri")) { model.handleLink(url) } }
  private func screen(_ id: String, _ size: CGSize) -> CGPoint { let p = positions[id] ?? .zero; return CGPoint(x: size.width/2 + p.x*zoom + pan.width, y: size.height/2 + p.y*zoom + pan.height) }
  private func nearest(_ p: CGPoint, size: CGSize, nodes: [Row]) -> String? {
    nodes.map { ($0.id, hypot(screen($0.id, size).x - p.x, screen($0.id, size).y - p.y)) }.filter { $0.1 < 18 }.min { $0.1 < $1.1 }?.0
  }
  private func fit(onlyShrink: Bool = false) {
    guard viewport.width > 100, viewport.height > 100 else { return }
    let points = visible.compactMap { positions[$0.id] }
    guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
          let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return }
    // Reserve space for titles, the legend, and the optional resource inspector.
    let right: CGFloat = selected == nil ? 80 : 270
    let area = CGRect(x: 80, y: 45, width: max(40, viewport.width-80-right), height: max(40, viewport.height-175))
    let scale = min(3, min(area.width/max(160,maxX-minX), area.height/max(160,maxY-minY)))
    zoom = onlyShrink ? min(zoom, scale) : scale
    pan = CGSize(width: area.midX-viewport.width/2-(minX+maxX)/2*zoom,
                 height: area.midY-viewport.height/2-(minY+maxY)/2*zoom)
  }
  private func load() async {
    loading = true; defer { loading = false }
    do {
      let value: [String: Any]
      if let fixture { value = fixture } else { value = try await model.request("/v2/graph") as? [String: Any] ?? [:] }
      nodes = model.rows(value["nodes"])
      edges = model.rows(value["edges"]).enumerated().map { i, row in var r = row.raw; r["id"] = String(i); return Row(raw: r) }
      let pairs = edges.map { ($0.string("source"), $0.string("target")) }
      let signature = nodes.map(\.id).sorted().joined(separator: "|") + pairs.map { $0.0 + ":" + $0.1 }.sorted().joined(separator: "|")
      if graphSignature != signature {
        let first = positions.isEmpty
        let initial = GraphLayout.positions(ids: nodes.map(\.id), edges: pairs)
        let retainedPins = physics.pinned
        positions = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, positions[$0.id] ?? initial[$0.id] ?? .zero) })
        physics = GraphPhysics(ids: nodes.map(\.id), edges: pairs, positions: positions)
        for id in retainedPins { physics.togglePin(id) }
        graphSignature = signature
        if first { fit() }
      }
    } catch { model.error = error.localizedDescription }
  }
}


/// Use AppKit mouse events so Canvas hover tracking cannot swallow a node drag.
private struct GraphDragSurface: NSViewRepresentable {
  struct Sample {
    var startLocation: CGPoint
    var location: CGPoint
    var translation: CGSize { CGSize(width: location.x-startLocation.x, height: location.y-startLocation.y) }
  }
  var onChanged: (Sample) -> Void
  var onEnded: (Sample) -> Void
  func makeNSView(context: Context) -> Surface { Surface() }
  func updateNSView(_ view: Surface, context: Context) {
    view.onChanged = onChanged
    view.onEnded = onEnded
  }
  final class Surface: NSView {
    var onChanged: ((Sample) -> Void)?
    var onEnded: ((Sample) -> Void)?
    private var start: CGPoint?
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
      NSApp.activate(ignoringOtherApps: true)
      window?.makeKey()
      let point = convert(event.locationInWindow, from: nil)
      start = point
      onChanged?(Sample(startLocation: point, location: point))
    }
    override func mouseDragged(with event: NSEvent) {
      guard let start else { return }
      onChanged?(Sample(startLocation: start, location: convert(event.locationInWindow, from: nil)))
    }
    override func mouseUp(with event: NSEvent) {
      guard let start else { return }
      onEnded?(Sample(startLocation: start, location: convert(event.locationInWindow, from: nil)))
      self.start = nil
    }
  }
}
