import XCTest
@testable import PDFChat

final class GraphPhysicsTests: XCTestCase {
  func testDraggingPullsLinkedNeighborAndHeldNodeStaysUnderPointer() {
    let initial = ["a": CGPoint(x: -50,y: 0), "b": CGPoint(x: 50,y: 0)]
    var linked = GraphPhysics(ids: ["a","b"], edges: [("a","b")], positions: initial)
    var unlinked = GraphPhysics(ids: ["a","b"], edges: [], positions: initial)
    let pointer = CGPoint(x: -50,y: 180)
    linked.move("a", to: pointer); unlinked.move("a", to: pointer)
    for _ in 0..<35 { linked.step(holding: "a"); unlinked.step(holding: "a") }
    XCTAssertEqual(linked.positions["a"],pointer)
    XCTAssertGreaterThan(linked.positions["b"]!.y,unlinked.positions["b"]!.y+30)
  }
  func testPinSurvivesNudgesAndCanBeDraggedThenReleased() {
    var p = GraphPhysics(ids: ["a","b"], edges: [("a","b")], positions: ["a":.zero,"b":CGPoint(x:100,y:0)])
    p.togglePin("a");p.scatter()
    for _ in 0..<30 { p.step() }
    XCTAssertEqual(p.positions["a"],.zero)
    let moved = CGPoint(x: 10,y: 150);p.move("a",to:moved)
    for _ in 0..<30 { p.step() }
    XCTAssertEqual(p.positions["a"],moved)
    p.togglePin("a");p.step();XCTAssertNotEqual(p.positions["a"],moved)
  }
  func testSimulationSettlesStopsAndWakesWithoutChangingIDs() {
    let ids = (0..<50).map(String.init)
    var p = GraphPhysics(ids:ids, edges:(1..<50).map { ("0",String($0)) }, positions:[:])
    for _ in 0..<400 { p.step() }
    XCTAssertTrue(p.isSettled)
    let stopped = p.positions;p.step();XCTAssertEqual(p.positions,stopped)
    p.scatter();XCTAssertFalse(p.isSettled);p.step();XCTAssertNotEqual(p.positions,stopped)
    XCTAssertEqual(Set(p.positions.keys),Set(ids))
  }
  func testCoincidentNodesSeparateAndDenseGraphRemainsFinite() {
    let ids = (0..<400).map(String.init)
    var p = GraphPhysics(ids:ids, edges:(1..<400).map { ("0",String($0)) }, positions:Dictionary(uniqueKeysWithValues:ids.map { ($0,CGPoint.zero) }))
    for _ in 0..<40 { p.step() }
    XCTAssertTrue(p.points.allSatisfy { $0.x.isFinite && $0.y.isFinite })
    XCTAssertNotEqual(p.points[0],p.points[1])
    XCTAssertTrue(p.velocities.allSatisfy { hypot($0.x,$0.y) <= 15.000001 })
  }
  func testDuplicateRelationsDoNotMultiplySpringStrength() {
    let positions = ["a":CGPoint.zero,"b":CGPoint(x:150,y:40)]
    var single = GraphPhysics(ids:["a","b"],edges:[("a","b")],positions:positions)
    var duplicated = GraphPhysics(ids:["a","b"],edges:[("a","b"),("b","a"),("a","b"),("a","a"),("missing","a")],positions:positions)
    for _ in 0..<10 { single.step();duplicated.step() }
    XCTAssertEqual(single.positions,duplicated.positions)
  }
  func testEmptyGraphSleepsAndInvalidPointerDoesNotCorruptPosition() {
    var empty = GraphPhysics(ids:[],edges:[],positions:[:]);empty.step();XCTAssertTrue(empty.isSettled)
    var p = GraphPhysics(ids:["a"],edges:[],positions:["a":.zero]);p.move("a",to:CGPoint(x:Double.nan,y:0));XCTAssertEqual(p.positions["a"],.zero)
  }
}
