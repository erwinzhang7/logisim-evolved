// ComponentToolTipTests.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.gui.main.Canvas.getToolTipText,
// com.cburch.logisim.circuit.Splitter.getToolTip), https://github.com/logisim-evolution/logisim-evolution.
// Copyright by the Logisim-evolution developers. This translation is a derivative work and is
// therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: the shipping 4.1.0 jar at /Applications/Logisim-evolution.app/Contents/app/
// logisim-evolution-4.1.0-all.jar, read with `javap -c`. (D16.)
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// WHAT A HOVER SAYS, AS A STRING.
//
// A tool tip is a floating panel put up by AppKit after a delay, and there is no way to assert
// that from a unit test with no window and no run loop. What *can* be asserted, and is the only
// part that can be wrong in an interesting way, is the function underneath it: given a world
// point, what string comes out. `ComponentToolTips.upstreamText` / `.hoverText` are pure for
// exactly that reason, and every test below calls one of them with a coordinate.
//
// ── WHAT REMAINS UNASSERTED HERE, STATED PLAINLY ─────────────────────────────────────────────
//
//   * That AppKit ever calls back. `CanvasHostNSView.view(_:stringForToolTip:point:userData:)`
//     runs only when the pointer settles inside a registered tool-tip rect in a real window.
//     Nothing here creates one.
//   * The hover delay, the panel's appearance, and its placement: all system behaviour, which is
//     precisely why `NSViewToolTipOwner` was chosen over a hand-rolled panel.
//   * That `refreshToolTipRect(hasText:)` is re-run often enough, and that AppKit arms a rect
//     added while the pointer is already inside it. Both are driven from `updateTrackingAreas`
//     and `mouseMoved`, which only AppKit calls.
//   * View-point → world-point conversion. That is `CanvasViewport.viewToWorld`, which the drag,
//     click and marquee paths already depend on and which has its own coverage.
//
// So this file gates the content and the join, and says so rather than implying more.
// ═════════════════════════════════════════════════════════════════════════════════════════════

import CoreGraphics
import Foundation
import LogisimFile
import LogisimKernel
import LogisimStd
import Testing

@testable import LogisimUI

// MARK: - Harness

/// A real project, its real circuit and the real render surface over it; the same shape
/// `LabelHitTestTests.Rig` uses, and for the same reason: the question is what the shipping canvas
/// says, so every part is a shipping one.
@MainActor
private struct Rig {
  let circuit: Circuit
  let surface: CircuitCanvasSurface

  init() throws {
    StdLibraries.registerAll()
    let made = try LogisimFileProjectHostFactory().makeEmptyProject()
    let host = try #require(made as? LogisimFileProjectHost)
    circuit = try #require(host.currentCircuitObject)
    surface = try #require(host.makeRenderSurface() as? CircuitCanvasSurface)
    surface.setCircuit(circuit)
  }

  @discardableResult
  func add(
    _ factory: any ComponentFactory, at point: (Int, Int), label: String? = nil
  ) throws -> any Component {
    let attributes = factory.createAttributeSet()
    if let label { try attributes.setValue(StdAttr.label, label) }
    let component = try factory.createComponent(
      location: Location.create(point.0, point.1, hasToSnap: false), attributes: attributes)
    try circuit.mutatorAdd(component)
    return component
  }

  /// Every component the resolver would be handed by the canvas.
  var components: [any Component] { surface.build.components }

  func upstream(_ x: Double, _ y: Double) -> String? {
    ComponentToolTips.upstreamText(over: components, atWorld: CGPoint(x: x, y: y))
  }

  func hover(_ x: Double, _ y: Double) -> String? {
    ComponentToolTips.hoverText(over: surface, atWorld: CGPoint(x: x, y: y))
  }
}

/// `Ttl7408` reached through its registered library tool, not a fresh instance; the same
/// discipline `LabelHitTestTests` uses for `Register`, so the factory under test is the shipping
/// one.
@MainActor
private func ttl7408() throws -> any ComponentFactory {
  try #require(
    TtlLibrary().tools.compactMap { ($0 as? AddTool)?.factory }
      .first { $0.name == Ttl7408.id })
}

/// A probe on the **10-unit** grid.
///
/// `Location.create(x, y, hasToSnap: true)` is NOT this: it snaps to multiples of 5
/// (`Location.swift:103-110`, Java's `(v / 5) * 5`), and the resolver snaps to 10. A probe built
/// with `hasToSnap: true` can therefore sit on a 5-multiple that the resolver then *moves*, so
/// every distance the test asserted about it describes a point the code never looked at. That is
/// how the overlap test below first went red, and it was the test that was wrong.
private func onTheGrid(_ x: Int, _ y: Int) -> Location {
  Location.create(CanvasGrid.snapXToGrid(x), CanvasGrid.snapYToGrid(y), hasToSnap: false)
}

/// A splitter whose ends are far enough apart that the middle of its own box is out of every
/// end's 10-unit window; the only shape for which `Splitter.getToolTip` takes its null arm.
/// A default splitter is 21×21 and has no such point.
@MainActor
private func spreadSplitter(at point: (Int, Int)) throws -> Splitter {
  let attributes = SplitterFactory.instance.createAttributeSet()
  try attributes.setValue(SplitterAttributes.attrFanout, 8)
  try attributes.setValue(SplitterAttributes.attrSpacing, 4)
  return try #require(
    try SplitterFactory.instance.createComponent(
      location: Location.create(point.0, point.1, hasToSnap: true), attributes: attributes)
      as? Splitter)
}

// MARK: - The gate

@Suite("Hover text — the ToolTipMaker seam, joined")
struct ComponentToolTipTests {

  // ── Half one: the seam itself ──────────────────────────────────────────────────────────────

  /// The audit's two facts, re-checked from the consumer side rather than taken on trust.
  ///
  /// `Splitter.feature(_:)`, the component's own `getFeature`, still answers `nil` for
  /// `.toolTipMaker`, because `LogisimStd` cannot name a protocol declared in `LogisimUI`. It is
  /// `Component.feature(_:key:)`'s new arm that makes the key answer. If someone "simplifies" the
  /// arm away by pushing the conformance down, the first assertion here starts failing and the
  /// second keeps passing, which says exactly what happened.
  @Test("the raw feature key is still unanswered; the typed lookup answers")
  @MainActor
  func theArmIsWhatJoinsIt() throws {
    let splitter = Splitter(
      location: Location.create(100, 100, hasToSnap: true), attributes: SplitterAttributes())
    #expect(splitter.feature(.toolTipMaker) == nil)
    #expect(splitter.feature((any ToolTipMaker).self, key: .toolTipMaker) != nil)
  }

  /// The end-to-end join: a world point handed to the shipping surface produces the string.
  /// Everything else in this file works on a component list; this one proves the list the canvas
  /// would actually pass is reachable through `CircuitRenderSurface`.
  @Test("a world point over the surface produces the same string as the component list")
  @MainActor
  func theSurfacePathAgrees() throws {
    let rig = try Rig()
    try rig.add(ttl7408(), at: (200, 200))
    let point = rig.components[0].bounds
    let x = Double(point.x + point.width / 2)
    let y = Double(point.y + point.height / 2)
    #expect(rig.hover(x, y) == "7408")
  }

  // ── Half two: upstream parity, where the port can reach it ─────────────────────────────────

  /// `Splitter.getToolTip`, end 0 (circuit/Splitter.class:
  /// `if (end == 0) return S.get("splitterCombinedTip")`). The string is
  /// `resources/logisim/strings/circuit/circuit.properties:71` in the same jar.
  ///
  /// End locations come from `splitter.ends` rather than being written out, so a change to
  /// `SplitterParameters` moves the probes with it: `SplitterContainsToleranceTests` already
  /// pins the geometry itself, and pinning it twice would make a geometry drift fail here as an
  /// inexplicable string mismatch.
  @Test("the splitter's combined end says so")
  @MainActor
  func splitterCombinedEnd() throws {
    let rig = try Rig()
    let splitter = try #require(
      try rig.add(SplitterFactory.instance, at: (100, 100)) as? Splitter)
    let end0 = splitter.ends[0].location
    #expect(rig.upstream(Double(end0.x), Double(end0.y)) == "Combined end of splitter")
  }

  /// The split ends. A default splitter is fanout 2 over 2 bits, so
  /// `computeDistribution(fanout: 2, bits: 2, order: 1)` gives `bitEnd == [1, 2]`, one bit per
  /// end, and `bits == 1` selects `splitterSplit1Tip` ("Bit %s from combined end",
  /// circuit.properties:73) rather than the plural form.
  @Test("each split end names the bit it carries")
  @MainActor
  func splitterSplitEnds() throws {
    let rig = try Rig()
    let splitter = try #require(
      try rig.add(SplitterFactory.instance, at: (100, 100)) as? Splitter)
    #expect(splitter.splitterBitEnd == [1, 2], "the default distribution moved")

    let end1 = splitter.ends[1].location
    let end2 = splitter.ends[2].location
    #expect(rig.upstream(Double(end1.x), Double(end1.y)) == "Bit 0 from combined end")
    #expect(rig.upstream(Double(end2.x), Double(end2.y)) == "Bit 1 from combined end")
  }

  /// The plural form and the ordering inside it.
  ///
  /// `appendBuf(buf, i - 1, beginString)` in circuit/Splitter.class appends the run's HIGH index
  /// first, so a two-bit run reads "1-0", not "0-1". That is Logisim's MSB-first convention and
  /// it is invisible on a one-bit run, which is every run a default splitter has, so without a
  /// wider splitter here the argument order could be reversed and nothing would notice.
  ///
  /// Width 4 over fanout 2 gives `computeDistribution(fanout: 2, bits: 4, order: 1)` = [1,1,2,2],
  /// so end 1 carries bits 0-1 and `bits == 2` selects `splitterSplitManyTip`
  /// ("Bits %s from combined end", circuit.properties:74).
  @Test("a multi-bit end names its range, high index first")
  @MainActor
  func splitterBitRange() throws {
    let rig = try Rig()
    let attributes = SplitterFactory.instance.createAttributeSet()
    try attributes.setValue(SplitterAttributes.attrWidth, BitWidth.known(4))
    let splitter = try #require(
      try SplitterFactory.instance.createComponent(
        location: Location.create(100, 100, hasToSnap: true), attributes: attributes) as? Splitter)
    try rig.circuit.mutatorAdd(splitter)
    #expect(splitter.splitterBitEnd == [1, 1, 2, 2], "the distribution for 4 bits moved")

    let end1 = splitter.ends[1].location
    let end2 = splitter.ends[2].location
    #expect(rig.upstream(Double(end1.x), Double(end1.y)) == "Bits 1-0 from combined end")
    #expect(rig.upstream(Double(end2.x), Double(end2.y)) == "Bits 3-2 from combined end")
  }

  /// Precedence: a component that answers the feature must beat the naming fallback, or the
  /// divergence quietly swallows the parity work. Hovering a splitter end has to say what
  /// 4.1.0 says, not "Splitter".
  @Test("parity wins over the fallback where both could answer")
  @MainActor
  func parityBeatsTheFallback() throws {
    let rig = try Rig()
    let splitter = try #require(
      try rig.add(SplitterFactory.instance, at: (100, 100)) as? Splitter)
    let end0 = splitter.ends[0].location
    #expect(rig.hover(Double(end0.x), Double(end0.y)) == "Combined end of splitter")
    #expect(
      SplitterFactory.instance.displayName != "Combined end of splitter",
      "the fallback and the parity answer have to be distinguishable for this to mean anything")
  }

  /// `SubcircuitFactory` is the only `setDefaultToolTip` call site in the whole 4.1.0 jar, and
  /// `CircuitFeature.toString()` (circuit/SubcircuitFactory$CircuitFeature.class) returns
  /// `source.getName()`. So a subcircuit's hover text is its circuit's name in both trees.
  ///
  /// **`upstream` is what gates this, not `hover`.** A subcircuit factory's `displayName` is also
  /// its circuit's name, so the naming fallback produces the same string by a different route:
  /// measured, by deleting `SubcircuitToolTip` and watching the `hover` line stay green while the
  /// `upstream` line went red. The second assertion is therefore only checking that `hover` does
  /// not *lose* the answer; the parity claim rests on the first.
  @Test("a subcircuit says its circuit's name, as 4.1.0 does")
  @MainActor
  func subcircuitNamesItsCircuit() throws {
    let rig = try Rig()
    let inner = try Circuit(name: "adder4", defaultAppearance: CircuitAttributes.appearEvolution)
    try inner.staticAttributes.setValue(
      CircuitAttributes.appearance, CircuitAttributes.appearEvolution)
    let factory = try #require(inner.subcircuitFactory as? CircuitSubcircuitFactory)
    let placed = try factory.createComponent(
      location: Location.create(200, 200, hasToSnap: true),
      attributes: factory.createAttributeSet())
    try rig.circuit.mutatorAdd(placed)

    let box = placed.bounds
    let x = Double(box.x + box.width / 2)
    let y = Double(box.y + box.height / 2)
    #expect(rig.upstream(x, y) == "adder4")
    #expect(rig.hover(x, y) == "adder4")
  }

  /// `Splitter.getToolTip` returns null when the point is inside the splitter but more than 10
  /// away from every end, and upstream's Canvas loop *keeps going* on a null rather than
  /// stopping. With nothing else under the point the answer is nil.
  ///
  /// A default splitter is only 21×21, so no point inside it is far enough from all three ends.
  /// Fanout 8 with spacing 4 spreads the ends far enough apart that the middle of the box is out
  /// of range of all of them, which is the case the null arm exists for.
  @Test("a point inside a splitter but away from every end says nothing")
  @MainActor
  func splitterAwayFromEnds() throws {
    let rig = try Rig()
    let splitter = try spreadSplitter(at: (100, 100))
    try rig.circuit.mutatorAdd(splitter)

    // The end furthest from end 0, halved: guaranteed inside the box, and, with the ends this
    // far apart, more than 10 from all of them. Asserted, not assumed.
    let last = splitter.ends[splitter.ends.count - 1].location
    let probe = onTheGrid((last.x + 100) / 2, (last.y + 100) / 2)
    for end in splitter.ends {
      #expect(
        end.location.manhattanDistance(to: probe) >= 10,
        "probe \(probe) is within 10 of end \(end.location); the geometry moved")
    }
    #expect(splitter.contains(probe), "probe \(probe) fell outside the splitter")
    #expect(rig.upstream(Double(probe.x), Double(probe.y)) == nil)
  }

  /// **A maker that answers null does not end the loop.** `Canvas.getToolTipText`'s
  /// `if (ret != null) { … return ret; }` sits *inside* the iteration (gui/main/Canvas.class,
  /// offsets 131-144: a null falls through to `goto 48`, the loop head). Writing it as
  /// "first component with the feature wins" compiles, reads the same, and silently blanks the
  /// tip wherever two components overlap.
  ///
  /// The construction: a wide splitter that answers null at the probe, added first, and a second
  /// splitter whose combined end sits exactly on that probe. One answer is reachable only by
  /// continuing past the first null.
  @Test("a maker that answers nothing does not stop the search")
  @MainActor
  func nullDoesNotEndTheLoop() throws {
    let rig = try Rig()
    let wide = try spreadSplitter(at: (100, 100))
    try rig.circuit.mutatorAdd(wide)
    let last = wide.ends[wide.ends.count - 1].location
    let probe = onTheGrid((last.x + 100) / 2, (last.y + 100) / 2)
    for end in wide.ends {
      #expect(end.location.manhattanDistance(to: probe) >= 10, "the wide splitter's geometry moved")
    }
    #expect(wide.contains(probe))
    #expect(rig.upstream(Double(probe.x), Double(probe.y)) == nil, "precondition: first is silent")

    let second = try #require(
      try rig.add(SplitterFactory.instance, at: (probe.x, probe.y)) as? Splitter)
    #expect(second.ends[0].location == probe, "the second splitter's end 0 moved off the probe")
    #expect(rig.components.count == 2)
    #expect(rig.upstream(Double(probe.x), Double(probe.y)) == "Combined end of splitter")
  }

  /// Upstream snaps the point to the 10-unit grid *before* the distance test
  /// (`Canvas.getToolTipText` calls `Canvas.snapToGrid(event)` first, gui/main/Canvas.class), so
  /// a pointer a few pixels off a grid line answers as if it were on it. Without the snap the
  /// same probe would be 4 further from the end and the ±10 window would shift under it.
  @Test("the point is snapped to the grid before anything is measured")
  @MainActor
  func theProbeIsSnapped() throws {
    let rig = try Rig()
    let splitter = try #require(
      try rig.add(SplitterFactory.instance, at: (100, 100)) as? Splitter)
    let end0 = splitter.ends[0].location
    #expect(
      ComponentToolTips.snapped(CGPoint(x: Double(end0.x) + 4, y: Double(end0.y) - 4)) == end0)
    #expect(
      rig.upstream(Double(end0.x) + 4, Double(end0.y) - 4) == "Combined end of splitter")
  }

  // ── Half three: the divergence, which is the reason the task exists ────────────────────────

  /// **The owner's actual complaint, as an assertion.** In 4.1.0 this is empty: a grid-snapped
  /// point in the middle of a 14-pin chip is more than 10 from every end, so
  /// `InstanceComponent.getToolTip` falls through to `getDefaultToolTip()`, which
  /// `AbstractTtlGate` never sets. Both halves are asserted here, parity says nothing, the
  /// shipping hover names the chip, so if the fallback is ever removed the failure names it.
  @Test("hovering a 7408 body says 7408, where 4.1.0 says nothing")
  @MainActor
  func ttlBodyIsNamed() throws {
    let rig = try Rig()
    let chip = try rig.add(ttl7408(), at: (200, 200))
    let box = chip.bounds
    let x = Double(box.x + box.width / 2)
    let y = Double(box.y + box.height / 2)

    // ── The 4.1.0 half of that sentence, measured rather than inferred ───────────────────────
    //
    // "4.1.0 says nothing here" rests on the grid-snapped centre being outside every end's
    // 10-unit window, since that is the only thing `InstanceComponent.getToolTip` tests before
    // falling through to the default tip a TTL factory never sets. `rig.upstream(...) == nil`
    // below does NOT establish that: it is nil in this port for the unrelated reason that
    // `Port.toolTip` was dropped, so it would stay nil at any distance. The distance is a fact
    // about geometry, which this port does share with 4.1.0, so it is asserted directly.
    // Measured: 30 to 90 across the 14 pins.
    let centre = ComponentToolTips.snapped(CGPoint(x: x, y: y))
    #expect(!chip.ends.isEmpty, "a 7408 with no ends would make the loop below vacuous")
    for end in chip.ends {
      #expect(
        end.location.manhattanDistance(to: centre) >= 10,
        "end \(end.location) is inside 4.1.0's port window around the body centre \(centre)")
    }

    #expect(rig.upstream(x, y) == nil, "upstream parity should have nothing to say here")
    #expect(rig.hover(x, y) == "7408")
  }

  /// The label is the disambiguator on the circuit that produced the report: several pins, all
  /// drawn the same, told apart only by their labels. Upstream's answer at this point is
  /// "Add an input pin" (std/wiring/Pin.class sets `pinInputToolTip` on the port, and
  /// `resources/logisim/strings/std/std.properties:1073` defines it as the *toolbar* string).
  @Test("a labelled component names itself and its label")
  @MainActor
  func labelIsAppended() throws {
    let rig = try Rig()
    let pin = try rig.add(Pin(), at: (300, 300), label: "CLK")
    let box = pin.bounds
    let x = Double(box.x + box.width / 2)
    let y = Double(box.y + box.height / 2)
    #expect(rig.hover(x, y) == "Pin — CLK")

    let bare = try rig.add(Pin(), at: (400, 400))
    let bareBox = bare.bounds
    #expect(
      rig.hover(Double(bareBox.x + bareBox.width / 2), Double(bareBox.y + bareBox.height / 2))
        == "Pin")
  }

  /// Empty canvas answers nothing. The cheapest way for a fallback to be wrong is to answer
  /// unconditionally.
  @Test("empty space says nothing")
  @MainActor
  func emptySpaceIsSilent() throws {
    let rig = try Rig()
    try rig.add(ttl7408(), at: (200, 200))
    #expect(rig.upstream(-5000, -5000) == nil)
    #expect(rig.hover(-5000, -5000) == nil)
  }

  /// Wires are excluded on purpose: `Wire` implements no `ToolTipMaker` in 4.1.0, and a tip
  /// reading "Wire" would follow the pointer along every connection in the circuit.
  @Test("a wire says nothing")
  @MainActor
  func wiresAreSilent() throws {
    let rig = try Rig()
    let wire = Wire.create(
      Location.create(500, 500, hasToSnap: true), Location.create(600, 500, hasToSnap: true))
    try rig.circuit.mutatorAdd(wire)
    #expect(rig.upstream(550, 500) == nil)
    #expect(rig.hover(550, 500) == nil)
  }
}
