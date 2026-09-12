// WireRepairComponentTests.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.tools.{WiringTool, WireRepair,
// WireRepairData}, com.cburch.logisim.circuit.Splitter, com.cburch.logisim.std.gates.
// {AbstractGate, ControlledBuffer, OrGate}),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// SEAM #23: DOES A COMPONENT'S OWN `shouldRepairWire` CHANGE THE WIRE THAT GETS SAVED?
//
// `WireRepair` was declared in `LogisimUI`, referenced 56 times, and had no conformer; because
// it *could* not: every implementor upstream is a component, every component in this port lives
// in `LogisimStd`, and `LogisimStd` sits below `LogisimUI` in the module graph. So
// `WiringTool.checkForRepairs`'s `component.wireRepairFeature()` returned nil for every component
// on the canvas and the whole feature was inert. The protocol has moved down beside
// `InstancePoker`; these tests are the evidence that the move did something.
//
// ── WHY EACH TEST IS AN ENDPOINT COMPARISON AND NOT A NON-NIL CHECK ─────────────────────────
//
// "The protocol has a conformer" and "the feature is non-nil" are both true of a conformance that
// answers wrongly, and `ToolFeatureSeamTests` already asserts both against a conformer declared
// in the test file; it would stay green if no real component ever conformed. So every test here
// drives a **real pointer gesture** through `CanvasInteractionHandler` into `WiringTool`, and
// asserts the endpoints of the `Wire` that lands in the `Circuit`. A wrong answer moves an
// endpoint by exactly one grid step, which is what the assertions compare.
//
// ── WHAT REPAIR ACTUALLY DOES, BECAUSE THE NAME POINTS THE WRONG WAY ────────────────────────
//
// `Wire.create` normalises its endpoints, so `end0` is the lower coordinate; `checkForRepairs`
// then takes the candidate for `end0` to be `end0 + 10`: one step back *toward the middle of
// the wire*. Repair therefore SHORTENS a wire that was dragged one grid step past a component's
// port and into its body, snapping the loose end back onto the port. Every case below is set up
// as exactly that overshoot: press outside the component, release one step inside it.
//
// ── THE RED PROBE ───────────────────────────────────────────────────────────────────────────
//
// Recorded in the commit that adds this file; each conformance was broken one at a time and the
// suite re-run. Removing a conformance turns exactly its own case red and leaves the others
// green, which is the property that makes these four cases separable evidence rather than one
// test written four times.
// ═════════════════════════════════════════════════════════════════════════════════════════════

import AppKit
import CoreGraphics
import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender
import LogisimRenderBackend
import LogisimStd
import Testing

@testable import LogisimUI

// MARK: - Harness

/// A project, its real render surface, and a `CircuitEditorCanvas` over both; the same rig
/// `CanvasToolRoundTripTests` uses, for the same reason: the question is whether the
/// *application's* canvas drives the tool, so the parts are the shipping ones.
@MainActor
private struct Rig {
  let host: LogisimFileProjectHost
  let project: Project
  let circuit: Circuit
  let surface: CircuitCanvasSurface
  let canvas: CircuitEditorCanvas

  init(tool: any CanvasTool) throws {
    let made = try LogisimFileProjectHostFactory().makeEmptyProject()
    host = try #require(made as? LogisimFileProjectHost)
    project = host.project
    circuit = try #require(host.currentCircuitObject)
    surface = try #require(host.makeRenderSurface() as? CircuitCanvasSurface)
    canvas = CircuitEditorCanvas(
      project: project, surface: surface, circuit: circuit, initialTool: tool)
  }

  @discardableResult
  func add(_ factory: any ComponentFactory, at point: (Int, Int)) throws -> any Component {
    let component = try factory.createComponent(
      location: Location.create(point.0, point.1, hasToSnap: false),
      attributes: factory.createAttributeSet())
    try circuit.mutatorAdd(component)
    return component
  }

  /// Send a gesture the way `CanvasHostNSView` does.
  func pointer(_ phase: CanvasPointerEvent.Phase, _ point: Location) {
    let world = CGPoint(x: CGFloat(point.x), y: CGFloat(point.y))
    canvas.controller.canvasHandlePointer(
      CanvasPointerEvent(
        phase: phase,
        world: world,
        modifiers: [],
        clickCount: 1,
        buttonNumber: 1,
        dragOriginWorld: nil))
  }

  /// Press, drag, release: one straight wire drag, exactly as the three-event sequence the
  /// AppKit host delivers. `WiringTool.mouseReleased` bails unless `hasDragged`, so the middle
  /// event is not optional.
  func drag(from press: Location, to release: Location) {
    pointer(.down, press)
    pointer(.dragged, release)
    pointer(.up, release)
  }
}

private func at(_ x: Int, _ y: Int) -> Location { Location.create(x, y, hasToSnap: true) }

/// The overshoot geometry, stated once so each test reads as a claim about the component.
///
/// `port` is the pin the wire should end on; `release` is one grid step further *into* the body,
/// which is where the drag actually ends; `press` is 60 units out on the far side, which makes
/// the wire 70 long: comfortably past `checkForRepairs`'s `length <= 10` guard.
private struct Overshoot {
  let port: Location
  let release: Location
  let press: Location

  /// `dx`/`dy` point from the port *inward*. Exactly one of them is non-zero.
  init(port: Location, inward dx: Int, _ dy: Int) {
    self.port = port
    release = at(port.x + dx, port.y + dy)
    press = at(port.x - 6 * dx, port.y - 6 * dy)
  }
}

/// Asserts the three preconditions `checkForRepairs` applies before it ever asks a component.
///
/// Without this the tests could pass or fail for reasons that have nothing to do with
/// `shouldRepairWire`; a release point that happens to be another port, say, short-circuits the
/// second guard and no repair would happen no matter what any component answered.
@MainActor
private func expectGuardsAdmitTheRepair(
  _ shot: Overshoot, on component: any Component, in circuit: Circuit, label: String
) {
  #expect(component.endsAt(shot.port), "\(label): the port is not an end of the component")
  #expect(
    component.bounds.contains(shot.release, 2),
    "\(label): the release point is outside the component's bounds, so guard 3 rejects it")
  #expect(
    circuit.nonWires.allSatisfy { !$0.endsAt(shot.release) },
    "\(label): something already ends at the release point, so guard 2 bails")
  #expect(
    !component.bounds.contains(shot.press, 2),
    "\(label): the press point is inside the component, so this is not an overshoot")
}

@MainActor
private func soleWire(in circuit: Circuit) throws -> Wire {
  let all = circuit.wires
  #expect(all.count == 1, "expected exactly one wire, got \(all.count)")
  return try #require(all.first)
}

/// Every endpoint of every wire in the circuit.
///
/// The refusal cases need this rather than a single-`Wire` assertion, and the reason is worth
/// naming because it looked at first like a repair firing when it should not have: a wire that is
/// NOT repaired still runs one grid step past the port and *through* it, and adding such a wire
/// splits it in two at the port (`Circuit.mutatorAdd` → `CircuitPoints`). So a refusal leaves two
/// wires whose endpoints include both the port and the release point, while a repair leaves one
/// wire that stops at the port. The discriminating question in both directions is therefore
/// "does any wire still end where the user released the mouse?".
@MainActor
private func wireEnds(in circuit: Circuit) -> Set<Location> {
  Set(circuit.wires.flatMap { [$0.end0, $0.end1] })
}

// MARK: - A gate that repairs, for the AbstractGate override path

/// `OrGate.shouldRepairWire` (`OrGate.java:114-117`) in a gate this module is allowed to write.
///
/// The four gates that override the hook upstream, `OrGate`, `NorGate`, `XorGate`, `XnorGate`,
/// are all `final` in this port and all live outside this task's slice, so their one-line
/// overrides are reported as follow-up rather than added here. This local subclass carries the
/// same body, which is what makes `AbstractGate`'s half of the seam, the `.wireRepair` arm in
/// `getInstanceFeature` and the `open` hook it dispatches to, testable at all: a stock gate
/// inherits `false`, and "no feature" and "a feature that answers false" are indistinguishable
/// from outside.
private final class RepairingGate: AbstractGate {
  init() { super.init("Test Repairing Gate") }

  override func computeOutput(
    _ inputs: [Value], _ numInputs: Int, _ state: any InstanceState
  ) throws -> Value {
    GateFunctions.computeOr(inputs, numInputs)
  }

  override var identity: Value { .falseValue }

  /// The canvas paints every component it holds, and `AbstractGate.paintShape` traps rather than
  /// drawing nothing. The silhouette is irrelevant to wire repair, so this draws nothing at all
  /// : the geometry that matters (`offsetBounds`, `ports`) is `AbstractGate`'s and is inherited.
  override func paintShape(_ painter: InstancePainter, _ width: Int, _ height: Int) {}

  /// `!data.getPoint().equals(instance.getLocation())`: the OR family's body verbatim.
  override func shouldRepairWire(
    _ component: StdInstanceComponent, _ data: WireRepairData
  ) -> Bool {
    data.point != component.location
  }
}

// MARK: - The gate

@Suite("WireRepair component conformers", .serialized)
@MainActor
struct WireRepairComponentTests {

  // ── 1. Splitter: always true ──────────────────────────────────────────────────────────────

  /// `Splitter implements WireRepair` (`Splitter.java:37`), `getFeature` answers `this` (`:191`),
  /// `shouldRepairWire` returns `true` (`:243`).
  @Test("a wire dragged one step past a splitter's end snaps back onto it")
  func splitterAbsorbsAnOvershoot() throws {
    let rig = try Rig(tool: WiringTool())
    let splitter = try rig.add(SplitterFactory.instance, at: (100, 100))

    // Default splitter: facing east, appear left, fanout 2, 2 bits. End 0 is the combined side at
    // the component's own location; ends 1 and 2 are the split side, 10 apart. Asserted rather
    // than assumed; if the geometry moves, this test must fail loudly instead of quietly
    // probing empty space.
    let ends = splitter.ends.map(\.location)
    #expect(ends == [at(100, 100), at(120, 80), at(120, 90)], "splitter ends: \(ends)")

    // The split ends face east, so "inward" from end 1 is −x, back across the body.
    let shot = Overshoot(port: at(120, 80), inward: -10, 0)
    expectGuardsAdmitTheRepair(shot, on: splitter, in: rig.circuit, label: "splitter")

    rig.drag(from: shot.press, to: shot.release)

    let wire = try soleWire(in: rig.circuit)
    // WITHOUT the conformance this is `shot.release`; the wire keeps the loose end the user
    // released, one grid step inside the splitter's body and connected to nothing.
    #expect(wire.end0 == shot.port, "end0 \(wire.end0), wanted \(shot.port)")
    #expect(wire.end1 == shot.press, "end1 \(wire.end1), wanted \(shot.press)")
    #expect(rig.project.canUndo)
  }

  // ── 2. ControlledBuffer: the control port only ─────────────────────────────────────────────

  /// `ControlledBuffer.getInstanceFeature` (`:132-137`):
  /// `data.getPoint().equals(instance.getPortLocation(2))`.
  @Test("a controlled buffer absorbs an overshoot at its CONTROL port")
  func controlledBufferAbsorbsAtTheControlPort() throws {
    let rig = try Rig(tool: WiringTool())
    let buffer = try rig.add(ControlledBuffer.factoryBuffer, at: (100, 100))

    // Port 0 output, port 1 input, port 2 control. Right-handed and facing east puts the control
    // line on the lower flank.
    let ends = buffer.ends.map(\.location)
    #expect(ends == [at(100, 100), at(80, 100), at(90, 110)], "buffer ends: \(ends)")

    // The control port is on the bottom edge, so inward is −y.
    let shot = Overshoot(port: at(90, 110), inward: 0, -10)
    expectGuardsAdmitTheRepair(shot, on: buffer, in: rig.circuit, label: "control port")

    rig.drag(from: shot.press, to: shot.release)

    let wire = try soleWire(in: rig.circuit)
    #expect(wire.end0 == shot.port, "end0 \(wire.end0), wanted \(shot.port)")
    #expect(wire.end1 == shot.press, "end1 \(wire.end1), wanted \(shot.press)")
  }

  /// The other half of the same lambda, and the reason a `return true` stub is not good enough:
  /// the *data* port must be left exactly where the user drew it.
  @Test("the same buffer REFUSES an overshoot at its input port")
  func controlledBufferRefusesAtTheInputPort() throws {
    let rig = try Rig(tool: WiringTool())
    let buffer = try rig.add(ControlledBuffer.factoryBuffer, at: (100, 100))

    // The input port is on the back (west) edge, so inward is +x.
    let shot = Overshoot(port: at(80, 100), inward: 10, 0)
    expectGuardsAdmitTheRepair(shot, on: buffer, in: rig.circuit, label: "input port")

    rig.drag(from: shot.press, to: shot.release)

    // Every guard in `checkForRepairs` passed and the feature lookup succeeded; the only thing
    // between this and a repaired endpoint is the component answering `false`. A conformance
    // that returned `true` unconditionally would drop the release point entirely.
    let ends = wireEnds(in: rig.circuit)
    #expect(ends.contains(shot.release), "wire ends \(ends.sorted()) lost \(shot.release)")
    #expect(ends.contains(shot.press), "wire ends \(ends.sorted()) lost \(shot.press)")
  }

  // ── 3. AbstractGate: the overridable hook, and its `false` default ─────────────────────────

  /// `AbstractGate.getInstanceFeature` (`:274-277`) vends a per-*instance* lambda that calls
  /// `shouldRepairWire(instance, data)`. This exercises the arm and the dispatch together.
  @Test("a gate that overrides shouldRepairWire absorbs the overshoot")
  func gateOverrideAbsorbsAnOvershoot() throws {
    let rig = try Rig(tool: WiringTool())
    let factory = RepairingGate()
    let gate = try rig.add(factory, at: (200, 100))

    // Inputs are on the back (west) edge for a gate facing east, so inward is +x.
    let input = try #require(gate.ends.dropFirst().first?.location)
    #expect(input.x < gate.location.x, "input \(input) is not behind the gate body")
    let shot = Overshoot(port: input, inward: 10, 0)
    expectGuardsAdmitTheRepair(shot, on: gate, in: rig.circuit, label: "gate input")

    rig.drag(from: shot.press, to: shot.release)

    let wire = try soleWire(in: rig.circuit)
    #expect(wire.end0 == shot.press, "end0 \(wire.end0), wanted \(shot.press)")
    #expect(wire.end1 == shot.port, "end1 \(wire.end1), wanted \(shot.port)")
  }

  /// `AbstractGate.shouldRepairWire` (`:592`) returns `false`, and an AND gate does not override
  /// it. So a stock gate leaves the wire alone; this is upstream behaviour, not a missing port,
  /// and it is what stops the `.wireRepair` arm from becoming a blanket "snap to any pin".
  @Test("a stock AND gate leaves the same overshoot alone")
  func stockGateRefusesTheSameOvershoot() throws {
    let rig = try Rig(tool: WiringTool())
    let gate = try rig.add(AndGate.factory, at: (200, 100))

    let input = try #require(gate.ends.dropFirst().first?.location)
    let shot = Overshoot(port: input, inward: 10, 0)
    expectGuardsAdmitTheRepair(shot, on: gate, in: rig.circuit, label: "AND gate input")

    rig.drag(from: shot.press, to: shot.release)

    let ends = wireEnds(in: rig.circuit)
    #expect(ends.contains(shot.release), "wire ends \(ends.sorted()) lost \(shot.release)")
    #expect(ends.contains(shot.press), "wire ends \(ends.sorted()) lost \(shot.press)")
  }

  // ── 4. The negative control: no conformer, no repair ──────────────────────────────────────

  /// The same gesture with nothing at the far end. Without this, every assertion above could be
  /// satisfied by a `WiringTool` that snapped endpoints on its own, with the component never
  /// consulted at all.
  @Test("with no component there, the wire keeps the endpoint the drag gave it")
  func emptySpaceIsNeverRepaired() throws {
    let rig = try Rig(tool: WiringTool())
    let shot = Overshoot(port: at(120, 80), inward: -10, 0)

    rig.drag(from: shot.press, to: shot.release)

    let wire = try soleWire(in: rig.circuit)
    #expect(wire.end0 == shot.release, "end0 \(wire.end0), wanted \(shot.release)")
    #expect(wire.end1 == shot.press, "end1 \(wire.end1), wanted \(shot.press)")
  }
}
