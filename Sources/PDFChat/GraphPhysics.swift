import Foundation

/// Presentation-only spring simulation. Resource data and relations never change.
struct GraphPhysics {
  private(set) var ids: [String]
  private(set) var points: [CGPoint]
  private(set) var velocities: [CGPoint]
  private(set) var pinned: Set<String> = []
  private(set) var isSettled = false
  private var index: [String: Int]
  private var springs: [(Int, Int)] = []
  private var degrees: [Double]
  private var heat = 1.0
  private var remainingFrames = 360
  private var quietFrames = 0
  var positions: [String: CGPoint] { Dictionary(uniqueKeysWithValues: zip(ids, points)) }

  init(ids: [String], edges: [(String, String)], positions: [String: CGPoint]) {
    self.ids = ids; index = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
    points = ids.enumerated().map { i, id in positions[id] ?? CGPoint(x: cos(Double(i)*2.4)*100, y: sin(Double(i)*2.4)*100) }
    velocities = ids.map { _ in .zero }; degrees = ids.map { _ in 1 }
    var seen: Set<String> = []
    for (a, b) in edges {
      guard let i = index[a], let j = index[b], i != j else { continue }
      guard seen.insert("\(min(i,j)):\(max(i,j))").inserted else { continue }
      springs.append((i,j)); degrees[i] += 1; degrees[j] += 1
    }
  }
  mutating func wake() { heat = 1; remainingFrames = 360; quietFrames = 0; isSettled = false }
  mutating func togglePin(_ id: String) {
    guard let i = index[id] else { return }
    if pinned.contains(id) { pinned.remove(id) } else { pinned.insert(id) }
    velocities[i] = .zero; wake()
  }
  mutating func move(_ id: String, to point: CGPoint) {
    guard let i = index[id], point.x.isFinite, point.y.isFinite else { return }
    points[i] = point; velocities[i] = .zero; wake()
  }
  mutating func scatter() {
    for i in ids.indices where !pinned.contains(ids[i]) {
      let angle = Double(i)*2.39996 + 0.7
      velocities[i] = CGPoint(x: cos(angle)*9, y: sin(angle)*9)
    }
    wake()
  }
  /// Fixed 30 Hz timestep, bounded pair work for large libraries, damping and a hard sleep deadline.
  mutating func step(holding: String? = nil) {
    guard !isSettled, !ids.isEmpty else { isSettled = true; return }
    var forces = points.map { CGPoint(x: -$0.x*0.0015, y: -$0.y*0.0015) }
    let sampleStride = max(1, ids.count / 350)
    for i in ids.indices {
      for j in stride(from: i+1, to: ids.count, by: sampleStride) {
        var dx = points[i].x-points[j].x, dy = points[i].y-points[j].y
        if abs(dx)+abs(dy) < 0.01 { dx = cos(Double(i+j)*2.4); dy = sin(Double(i+j)*2.4) }
        let distance2 = max(25, dx*dx+dy*dy)
        let strength = min(10, 2300/distance2), distance = sqrt(distance2)
        let x = dx/distance*strength, y = dy/distance*strength
        forces[i].x += x; forces[i].y += y; forces[j].x -= x; forces[j].y -= y
      }
    }
    for (i,j) in springs {
      let dx = points[j].x-points[i].x, dy = points[j].y-points[i].y
      let distance = max(1,hypot(dx,dy))
      let strength = (distance-95)*0.035 / pow(degrees[i]*degrees[j],0.25)
      let x = dx/distance*strength, y = dy/distance*strength
      forces[i].x += x; forces[i].y += y; forces[j].x -= x; forces[j].y -= y
    }
    var maxSpeed = 0.0
    for i in ids.indices {
      if pinned.contains(ids[i]) || ids[i] == holding { velocities[i] = .zero; continue }
      var vx = (velocities[i].x + max(-12,min(12,forces[i].x))*heat)*0.82
      var vy = (velocities[i].y + max(-12,min(12,forces[i].y))*heat)*0.82
      let speed = hypot(vx,vy)
      if speed > 15 { vx *= 15/speed; vy *= 15/speed }
      velocities[i] = CGPoint(x: vx,y: vy); points[i].x += vx; points[i].y += vy
      maxSpeed = max(maxSpeed,hypot(vx,vy))
    }
    heat *= 0.98; remainingFrames -= 1
    quietFrames = maxSpeed < 0.035 ? quietFrames+1 : 0
    if remainingFrames <= 0 || quietFrames >= 20 { isSettled = true; velocities = ids.map { _ in .zero } }
  }
}
