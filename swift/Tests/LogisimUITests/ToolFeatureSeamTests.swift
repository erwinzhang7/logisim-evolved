// ToolFeatureSeamTests.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.tools.{CustomHandles, WireRepair,
// WireRepairData, TextEditable}, com.cburch.logisim.circuit.Wire,
// com.cburch.logisim.gui.main.Selection, com.cburch.logisim.tools.WiringTool),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// THREE COMPONENT-FEATURE SEAMS, AND WHAT EACH TEST IS ACTUALLY WORTH
//
// `seamcheck` reported `CustomHandles`, `WireRepair` and `TextEditable` as declared, referenced
// and unconformed. They are three different facts wearing the same clothes, and the tests below
// are deliberately of three different strengths. Read the strength before trusting the green.
//
//   1. `CustomHandles` was a REAL unwired seam and is now wired. `LogisimFile/Wire.swift:178`
//      already answered `.customHandles` with `self`, but `Wire` did not conform, so the `as?`
//      inside `Component.feature(_:key:)` could never match. `customHandlesReachesTheWire` FAILS
//      without `extension Wire: CustomHandles {}`: verified by deleting that line and running
//      the suite, not by inspection. That is the only test here with that property.
//
//   2. `WireRepair` WAS a live seam this module could not close: every upstream implementor is a
//      component, in this port every component lives in `LogisimStd`, *below* `LogisimUI`, so
//      none of them could name a protocol declared up here. **The protocol has since moved down**
//      (`LogisimStd/Instance/WireRepair.swift`) and `Splitter`, `AbstractGate` and
//      `ControlledBuffer` conform. `wireRepairSocketAcceptsAConformer` still proves only the
//      tool-side half, the lookup, the cast, and the `shouldRepairWire` call, against a
//      conformer declared in this file, and it would pass with or without the component work.
//      It is NOT evidence that wire repair works. `WireRepairComponentTests` is: it drives real
//      drags through `WiringTool` and asserts the endpoints the repair moves.
//
//   3. `TextEditable` is an acknowledged gap, not a seam: upstream's only implementor is
//      `InstanceTextField`, which needs four unported interactive-UI classes. There is no test
//      for it, because the honest assertion, "nothing conforms", is a change detector that
//      fails on the day someone fixes it. The marker at the declaration is the record.
// ═════════════════════════════════════════════════════════════════════════════════════════════

import Foundation
import LogisimFile
import LogisimKernel
import LogisimStd
import Testing

@testable import LogisimUI

/// A component that answers no feature at all; upstream's `null` from `getFeature`.
///
/// `UnresolvedComponent` is the real D8 placeholder rather than a hand-written double: its
/// `feature(_:)` returns nil for every key (`UnresolvedComponent.swift:263`), which is exactly
/// the shape `Selection.java:76-79` branches on, and using a shipping type means the test cannot
/// pass against a double that has drifted from `Component`.
@MainActor
private func featurelessComponent() -> any Component {
  UnresolvedComponent(
    factory: WireFactory.instance,
    location: Location.create(0, 0, hasToSnap: false),
    attributes: AttributeSets.empty)
}

/// A minimal conformer, kept so this suite still exercises the *socket*, the lookup and the cast
/// , independently of any real component. The real conformers now exist in `LogisimStd` and are
/// driven end-to-end through `WiringTool` by `WireRepairComponentTests`.
///
/// `LogisimStd.WireRepair`, spelled out: `LogisimFile` exports an unrelated `WireRepair` (the
/// `CircuitTransaction` repair pass) and this file imports both modules, so the bare name is
/// ambiguous here.
///
/// Deliberately NOT `@MainActor`: `LogisimStd.WireRepair` is nonisolated, exactly like
/// `InstancePoker` beside it, because a component answers it from wherever the editing gesture
/// runs. A main-actor conformer is a compile error, which is the right way round.
private final class RepairAnswer: LogisimStd.WireRepair {
  private let answer: Bool
  init(_ answer: Bool) { self.answer = answer }
  func shouldRepairWire(_ data: WireRepairData) -> Bool { answer }
}

/// A component whose `getFeature(WireRepair.class)` answers, the way `circuit.Splitter` and the
/// gates' `getInstanceFeature` lambdas do upstream.
private final class RepairingComponent: Component {
  private let repair: RepairAnswer

  @MainActor
  init(answer: Bool) { self.repair = RepairAnswer(answer) }

  let factory: any ComponentFactory = WireFactory.instance
  let location = Location.create(50, 0, hasToSnap: false)
  var attributeSet: any AttributeSet { AttributeSets.empty }
  var bounds: Bounds { Bounds.create(40, -10, 20, 20) }
  var ends: [EndData] { [] }

  func end(at index: Int) -> EndData { ends[index] }
  func contains(_ point: Location) -> Bool { bounds.contains(point) }
  func endsAt(_ point: Location) -> Bool { point == location }
  func feature(_ key: ComponentFeatureKey) -> Any? { key == .wireRepair ? repair : nil }
}

@Suite("Tool feature seams")
@MainActor
struct ToolFeatureSeamTests {

  // MARK: - CustomHandles

  @Test("a wire's CustomHandles feature is reachable AS CustomHandles, not merely returned")
  func customHandlesReachesTheWire() throws {
    let wire = Wire.create(
      Location.create(0, 0, hasToSnap: false), Location.create(30, 0, hasToSnap: false))

    // `Wire.feature(.customHandles)` has always returned `self` (`Wire.swift:178`, upstream
    // `Wire.java:237-238`). The seam was that the value could not be *used* as the protocol, so
    // this first expectation passed all along and told nobody anything.
    #expect(wire.feature(.customHandles) != nil)

    // This is the assertion that fails without `extension Wire: CustomHandles {}`.
    let handles = try #require(
      wire.feature((any CustomHandles).self, key: .customHandles),
      "the CustomHandles cast must succeed — this is the seam")
    #expect(handles.drawsOwnHandles)
  }

  @Test("Selection.java:74-81's branch: a wire draws its own handles, a featureless one does not")
  func customHandlesPredicateMatchesUpstreamBranch() {
    let wire = Wire.create(
      Location.create(10, 10, hasToSnap: false), Location.create(10, 40, hasToSnap: false))
    #expect(wire.hasCustomHandles)
    #expect(!featurelessComponent().hasCustomHandles)
  }

  // MARK: - WireRepair

  @Test("the WireRepair lookup and call work when a component supplies a conformer")
  func wireRepairSocketAcceptsAConformer() throws {
    // Upstream `circuit.Splitter.shouldRepairWire` returns `true` unconditionally
    // (`Splitter.java:243`); `AbstractGate`'s base returns `false` (`AbstractGate.java:592`).
    // Both shapes, through the one lookup `WiringTool.checkForRepairs` uses.
    let wire = Wire.create(
      Location.create(0, 0, hasToSnap: false), Location.create(40, 0, hasToSnap: false))
    let data = WireRepairData(wire: wire, point: Location.create(50, 0, hasToSnap: false))

    let yes = try #require(RepairingComponent(answer: true).wireRepairFeature())
    #expect(yes.shouldRepairWire(data))

    let no = try #require(RepairingComponent(answer: false).wireRepairFeature())
    #expect(!no.shouldRepairWire(data))

    #expect(featurelessComponent().wireRepairFeature() == nil)
  }

  @Test("the two feature keys do not cross-match")
  func featureKeysDoNotCrossMatch() {
    // `ComponentFeatureKey` is a string, not a metatype, so a lookup that asked for the wrong
    // key would still typecheck. `Wire` answers `.customHandles` and nothing else, upstream
    // `Wire.java:237-243` is the same, so it is the natural probe for that mistake.
    let wire = Wire.create(
      Location.create(0, 0, hasToSnap: false), Location.create(20, 0, hasToSnap: false))
    #expect(wire.wireRepairFeature() == nil)

    let repairing = RepairingComponent(answer: true)
    #expect(!repairing.hasCustomHandles)
  }
}
