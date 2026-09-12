// ClockSourceIdTests; part of logisim-evolved.
//
// `Netlist.getClockSourceId(Component)` (`Netlist.java:1113-1115`) is a **different lookup**
// from `getClockSourceId(List<String>, Net, Byte)` (`:1109-1111`), not a convenience over it.
// Only the net-keyed one had been ported, so `ClockHdlGeneratorFactory.getPortMap` took an
// injected closure that defaulted to `-1`, and `-1` means "no clock tree", which maps `clockBus`
// to the empty string. A real clock in a real netlist therefore emitted an unconnected clock bus,
// and the default made that look intentional.
//
// The implementation on `ClockTreeFactory` was already there and simply unreachable: nothing
// declared the overload, so nothing could call it. Same shape as this project's other nine
// registry defects; the code exists, the call site does not.
//
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimStd
import Testing

@testable import LogisimHdl

@Suite("Netlist.getClockSourceId(Component) — the component-keyed overload", .serialized)
struct ClockSourceIdTests {

  /// The container assigns ids in first-seen order and answers `-1` for a non-clock, exactly as
  /// `ClockSourceContainer.getClockId` does. Driving it directly proves the lookup the overload
  /// forwards to is real, independently of whether a netlist was built.
  @Test("the clock source container assigns ids in order and rejects non-clocks")
  func containerAssignsIds() throws {
    let container = ClockSourceContainer()

    let clockFactory = Clock.factory
    let clockAttrs = clockFactory.createAttributeSet()
    let clock = try clockFactory.createComponent(
      location: Location.create(100, 100, hasToSnap: false), attributes: clockAttrs)

    #expect(container.nrOfSources == 0)
    let first = container.clockId(for: clock)
    #expect(first == 0, "the first clock should be source 0, got \(first)")
    #expect(container.nrOfSources == 1)

    // A second clock of the same shape reuses the id rather than adding a source; that
    // de-duplication is the whole reason the container exists.
    let sameShape = try clockFactory.createComponent(
      location: Location.create(200, 200, hasToSnap: false), attributes: clockAttrs)
    #expect(container.clockId(for: sameShape) == 0)
    #expect(container.nrOfSources == 1, "an identically-shaped clock added a second source")

    // A non-clock is `-1` and does not become a source.
    let andFactory = AndGate.factory
    let andComponent = try andFactory.createComponent(
      location: Location.create(300, 300, hasToSnap: false),
      attributes: andFactory.createAttributeSet())
    #expect(container.clockId(for: andComponent) == -1)
    #expect(container.nrOfSources == 1)
  }

  /// The overload exists on the protocol, and a conformer that does not implement it answers
  /// `-1` rather than failing to compile. That default is what keeps every synthetic oracle
  /// netlist working unchanged.
  @Test("a netlist with no clock tree answers -1 through the protocol default")
  func protocolDefaultIsMinusOne() throws {
    let netlist: any HdlNetlist = NoClockTreeNetlist()
    let factory = AndGate.factory
    let component = try factory.createComponent(
      location: Location.create(100, 100, hasToSnap: false),
      attributes: factory.createAttributeSet())
    let placed = NetlistComponent(component: component)
    #expect(netlist.clockSourceId(for: placed) == -1)
  }

  /// `ClockHdlGeneratorFactory` now asks the netlist by default instead of answering `-1`.
  ///
  /// Asserted through `getPortMap`, which is where the value is actually consumed: a negative id
  /// maps `clockBus` to `""` and a non-negative one to `s_LOGISIM_CLOCK_TREE_<id>`. Two netlists
  /// that differ only in what the overload answers must produce two different port maps; if the
  /// generator were still hard-wired to `-1`, both would say `""` and this fails.
  @Test("getPortMap resolves clockBus through the netlist rather than a hardcoded -1")
  func portMapUsesTheNetlistAnswer() throws {
    try withHdlGlobals {
      HdlSettings.language = .vhdl

      let generator = ClockHdlGeneratorFactory(
        bindings: ClockHdlBindings(
          width: StdAttr.width, high: Clock.attrHigh, low: Clock.attrLow, phase: Clock.attrPhase))

      let factory = Clock.factory
      let component = try factory.createComponent(
        location: Location.create(100, 100, hasToSnap: false),
        attributes: factory.createAttributeSet())
      let placed = NetlistComponent(component: component)

      let unconnected = generator.getPortMap(
        netlist: NoClockTreeNetlist(), componentInfo: placed)
      #expect(
        unconnected["clockBus"] == "",
        "a netlist with no clock tree must leave clockBus empty, got \(unconnected["clockBus"] ?? "nil")")

      let connected = generator.getPortMap(netlist: FixedClockIdNetlist(id: 3), componentInfo: placed)
      #expect(
        connected["clockBus"] == "s_\(HdlGeneratorNames.clockTreeName)3",
        "clockBus did not follow the netlist's answer — the generator is still hardcoded to -1; got \(connected["clockBus"] ?? "nil")")
    }
  }
}

/// Takes the protocol default for `clockSourceId(for:)`.
private final class NoClockTreeNetlist: HdlNetlist {
  func netId(for net: any HdlNet) -> Int { -1 }
  func isContinuesBus(_ component: any HdlNetlistComponent, endIndex: Int) -> Bool { false }
  var currentHierarchyLevel: [String]? { nil }
  func clockSourceId(hierarchyLevel: [String], net: any HdlNet, bitIndex: Int) -> Int { -1 }
  var circuitName: String { "clockTest" }
  var projName: String { "clockTest" }
  var requiresGlobalClockConnection: Bool { false }
}

/// Overrides it, so the two cases differ only in the overload's answer.
private final class FixedClockIdNetlist: HdlNetlist {
  let id: Int
  init(id: Int) { self.id = id }
  func netId(for net: any HdlNet) -> Int { -1 }
  func isContinuesBus(_ component: any HdlNetlistComponent, endIndex: Int) -> Bool { false }
  var currentHierarchyLevel: [String]? { nil }
  func clockSourceId(hierarchyLevel: [String], net: any HdlNet, bitIndex: Int) -> Int { -1 }
  func clockSourceId(for component: any HdlNetlistComponent) -> Int { id }
  var circuitName: String { "clockTest" }
  var projName: String { "clockTest" }
  var requiresGlobalClockConnection: Bool { false }
}
