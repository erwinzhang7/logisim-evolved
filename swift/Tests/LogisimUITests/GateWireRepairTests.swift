// GateWireRepairTests.swift: part of logisim-evolved.
//
// Derived from logisim-evolution 4.1.0 WireRepair behavior. See LICENSE.md.

import AppKit
import CoreGraphics
import LogisimFile
import LogisimKernel
import LogisimRender
import LogisimRenderBackend
import LogisimStd
import Testing

@testable import LogisimUI

@MainActor
private struct GateWireRepairRig {
  let project: Project
  let circuit: Circuit
  let canvas: CircuitEditorCanvas

  init() throws {
    let host = try #require(
      try LogisimFileProjectHostFactory().makeEmptyProject() as? LogisimFileProjectHost)
    project = host.project
    circuit = try #require(host.currentCircuitObject)
    let surface = try #require(host.makeRenderSurface() as? CircuitCanvasSurface)
    canvas = CircuitEditorCanvas(
      project: project, surface: surface, circuit: circuit, initialTool: WiringTool())
  }

  func add(_ factory: any ComponentFactory, at location: Location) throws -> any Component {
    let component = try factory.createComponent(
      location: location, attributes: factory.createAttributeSet())
    try circuit.mutatorAdd(component)
    return component
  }

  func pointer(_ phase: CanvasPointerEvent.Phase, at location: Location) {
    let point = CGPoint(x: location.x, y: location.y)
    canvas.controller.canvasHandlePointer(
      CanvasPointerEvent(
        phase: phase,
        world: point,
        modifiers: [], clickCount: 1, buttonNumber: 1, dragOriginWorld: nil))
  }

  func drag(from start: Location, to end: Location) {
    pointer(.down, at: start)
    pointer(.dragged, at: end)
    pointer(.up, at: end)
  }
}

private func gateWirePoint(_ x: Int, _ y: Int) -> Location {
  Location.create(x, y, hasToSnap: true)
}

@MainActor
private func expectOvershootRepair(
  by factory: any ComponentFactory, componentName: String
) throws {
  let rig = try GateWireRepairRig()
  let component = try rig.add(factory, at: gateWirePoint(200, 100))
  let port = try #require(component.ends.dropFirst().first?.location)

  // All six default factories face east. Their first input lies west of the body, so dragging
  // ten units east of it overshoots the port inward. Start well west of the component so the
  // normalized wire's inward repair candidate is exactly the port.
  let release = gateWirePoint(port.x + 10, port.y)
  let start = gateWirePoint(port.x - 60, port.y)
  #expect(component.bounds.contains(release, 2), "\(componentName): overshoot missed body")
  #expect(!component.bounds.contains(start, 2), "\(componentName): start is inside body")
  #expect(!component.endsAt(release), "\(componentName): overshoot landed on another port")

  rig.drag(from: start, to: release)

  let actual = Set(rig.circuit.wires.flatMap { [$0.end0, $0.end1] })
  let expected: Set<Location> = [start, port]
  #expect(actual == expected, "\(componentName): wire endpoints \(actual.sorted()), wanted \(expected.sorted())")
}

@Suite("Gate and transistor wire repair", .serialized)
@MainActor
struct GateWireRepairTests {
  @Test func orGateRepairsOvershoot() throws {
    try expectOvershootRepair(by: OrGate.factory, componentName: "OR")
  }

  @Test func norGateRepairsOvershoot() throws {
    try expectOvershootRepair(by: NorGate.factory, componentName: "NOR")
  }

  @Test func xorGateRepairsOvershoot() throws {
    try expectOvershootRepair(by: XorGate.factory, componentName: "XOR")
  }

  @Test func xnorGateRepairsOvershoot() throws {
    try expectOvershootRepair(by: XnorGate.factory, componentName: "XNOR")
  }

  @Test func transistorRepairsOvershoot() throws {
    try expectOvershootRepair(by: Transistor.factory, componentName: "Transistor")
  }

  @Test func transmissionGateRepairsOvershoot() throws {
    try expectOvershootRepair(by: TransmissionGate.factory, componentName: "Transmission Gate")
  }
}
