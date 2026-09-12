// NetlistTests.swift: part of logisim-evolved.
//
// Corpus-free tests for `Netlist`: hand-built circuits, so the suite still says something in a
// bare checkout where `LOGISIM_CORPUS` is unset and the jar oracle cannot run.
//
// These cover the *shape* of the answer, that the protocols have real conformers and that the
// pieces the HDL layer calls actually resolve, rather than duplicating the corpus gate, which
// is the authority on agreement with the jar.
//
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.

import Foundation
import LogisimFile
import LogisimHdl
import LogisimKernel
import LogisimStd
import Testing

/// `.serialized` because these tests share process-wide state that the D1 world deliberately
/// does not guard with a lock: `StdLibraries.registerAll()` mutates the builtin-library registry
/// and `HdlGeneratorLookup.shared` is a plain mutable singleton, exactly as upstream's statics
/// are. Running them in parallel segfaults in the registry, which is a property of the test
/// harness, not of the netlist.
/// Collects everything `Reporter` emits, so a DRC that ends in `.error` can say *why* instead of
/// just failing an equality. Upstream's `Reporter` logs to the console when no sink is attached,
/// and swift-testing swallows that, which is how "DRC returned 2" used to be the whole diagnosis.
final class CapturingReportSink: HdlReportSink {
  private(set) var errors: [String] = []
  private(set) var warnings: [String] = []

  func addErrorIncrement(_ message: String) { errors.append(message) }
  func addError(_ message: String) { errors.append(message) }
  func addFatalError(_ message: String) { errors.append(message) }
  func addSevereError(_ message: String) { errors.append(message) }
  func addInfo(_ message: String) {}
  func addSevereWarning(_ message: String) { warnings.append(message) }
  func addWarningIncrement(_ message: String) { warnings.append(message) }
  func addWarning(_ message: String) { warnings.append(message) }
  func clearConsole() {}
  func print(_ message: String) {}

  /// Attaches a sink for the duration of `body` and restores whatever was there before.
  static func capturing<T>(_ body: (CapturingReportSink) throws -> T) rethrows -> T {
    let previous = Reporter.shared.sink
    let sink = CapturingReportSink()
    Reporter.shared.sink = sink
    defer { Reporter.shared.sink = previous }
    return try body(sink)
  }
}

@Suite("Netlist — hand-built circuits", .serialized)
struct NetlistTests {

  /// Two pins joined by a two-segment wire run, plus a third pin on a stub of its own, so the
  /// fixture has one net that had to be assembled from two segments and one that did not.
  private func makeCircuit() throws -> Circuit {
    StdLibraries.registerAll()
    let circuit = try Circuit(name: "netlist_fixture")

    func pin(_ label: String, _ location: Location, input: Bool) throws -> any Component {
      let attrs = Pin.factory.createAttributeSet()
      try attrs.setValue(Pin.attrType, input ? Pin.input : Pin.output)
      try attrs.setValue(StdAttr.label, label)
      return try Pin.factory.createComponent(location: location, attributes: attrs)
    }

    try circuit.mutatorAdd(pin("A", Location.create(100, 100, hasToSnap: false), input: true))
    try circuit.mutatorAdd(pin("B", Location.create(100, 200, hasToSnap: false), input: true))
    try circuit.mutatorAdd(pin("Y", Location.create(300, 100, hasToSnap: false), input: false))
    try circuit.mutatorAdd(
      Wire.create(Location.create(100, 100, hasToSnap: false), Location.create(200, 100, hasToSnap: false)))
    try circuit.mutatorAdd(
      Wire.create(Location.create(200, 100, hasToSnap: false), Location.create(300, 100, hasToSnap: false)))
    try circuit.mutatorAdd(
      Wire.create(Location.create(100, 200, hasToSnap: false), Location.create(200, 200, hasToSnap: false)))
    return circuit
  }

  @Test("a Netlist is a real HdlNetlist, and its parts are real HdlNet/HdlNetlistComponents")
  func protocolsHaveConformers() throws {
    let circuit = try makeCircuit()
    let netlist = Netlist.standalone(for: circuit)
    #expect(netlist.generateNetlist())

    // The point of the whole exercise: the three protocols that had no conformer now do, and
    // `Hdl`'s netlist-facing helpers can be called on the result.
    let asProtocol: any HdlNetlist = netlist
    #expect(asProtocol.circuitName == "netlist_fixture")
    #expect(asProtocol.requiresGlobalClockConnection == false)

    let port = try #require(netlist.inputPorts.first)
    let asComponent: any HdlNetlistComponent = port
    #expect(asComponent.nrOfEnds == 1)
    #expect(asComponent.isEndConnected(0))

    let end = asComponent.end(at: 0)
    let solder = end.solderPoint(atBit: 0)
    let net = try #require(solder.parentNet)
    #expect(net.bitWidth == 1)
    #expect(net.isBus == false)
    #expect(asProtocol.netId(for: net) >= 0)

    // And the generation framework can now produce text from it.
    let name = Hdl.getNetName(
      asComponent, endIndex: 0, floatingNetTiedToGround: true, netlist: asProtocol)
    #expect(!name.isEmpty)
  }

  @Test("two wires sharing an end become one net; a disconnected wire becomes another")
  func netsFollowConnectivity() throws {
    let circuit = try makeCircuit()
    let netlist = Netlist.standalone(for: circuit)
    #expect(netlist.generateNetlist())

    #expect(netlist.nets.count == 2)
    #expect(netlist.numberOfNets == 2)
    #expect(netlist.numberOfBusses == 0)

    let joined = try #require(
      netlist.nets.first { $0.contains(Location.create(200, 100, hasToSnap: false)) })
    #expect(joined.contains(Location.create(100, 100, hasToSnap: false)))
    #expect(joined.contains(Location.create(300, 100, hasToSnap: false)))
    #expect(joined.wires.count == 2)
  }

  @Test("A and Y sit on the same net, so the pin sorting is input/output, not left/right")
  func pinsAreSortedByDirection() throws {
    let circuit = try makeCircuit()
    let netlist = Netlist.standalone(for: circuit)
    #expect(netlist.generateNetlist())
    #expect(netlist.inputPorts.count == 2)
    #expect(netlist.outputPorts.count == 1)
    let outputLabel = netlist.outputPorts[0].component.attributeSet.getValue(StdAttr.label)
    #expect(outputLabel == "Y")
  }

  @Test("an empty circuit produces an empty netlist rather than throwing")
  func emptyCircuit() throws {
    StdLibraries.registerAll()
    let circuit = try Circuit(name: "empty")
    let netlist = Netlist.standalone(for: circuit)
    #expect(netlist.generateNetlist())
    #expect(netlist.nets.isEmpty)
    #expect(netlist.netId(of: Net()) == -1)
  }

  @Test("netId of a net from another netlist is -1, not a wrong index")
  func netIdOfForeignNet() throws {
    let circuit = try makeCircuit()
    let netlist = Netlist.standalone(for: circuit)
    #expect(netlist.generateNetlist())
    let foreign = Net(location: Location.create(0, 0, hasToSnap: false), width: 1)
    #expect(netlist.netId(of: foreign) == -1)
    #expect(netlist.netId(for: foreign) == -1)
  }

  @Test("isContinuesBus is true for a single-bit end, per upstream's early return")
  func continuesBusSingleBit() throws {
    let circuit = try makeCircuit()
    let netlist = Netlist.standalone(for: circuit)
    #expect(netlist.generateNetlist())
    let port = try #require(netlist.inputPorts.first)
    #expect(netlist.isContinuesBus(port, endIndex: 0))
    // Out of range answers `true`, exactly as `Netlist.java:1514` does.
    #expect(netlist.isContinuesBus(port, endIndex: 99))
    #expect(netlist.isContinuesBus(port, endIndex: -1))
  }

  // MARK: - Standalone netlists and the hierarchy

  /// An `inner` circuit with one input and one output pin, and an `outer` circuit that places it.
  ///
  /// **Every caller must bind `inner`, not `_`.** `CircuitSubcircuitFactory → Circuit` is
  /// `unowned` per D3, upstream's file owns every circuit and the factory only points at one, so
  /// a fixture that drops the child circuit makes `factory.subcircuit` a dangling unowned read and
  /// the next `subNetlist(of:)` traps. In the app `LogisimFile.ownedCircuits` plays this role;
  /// here the test does.
  private func makeHierarchy() throws -> (outer: Circuit, inner: Circuit, placement: any Component)
  {
    StdLibraries.registerAll()

    func pin(_ label: String, _ location: Location, input: Bool) throws -> any Component {
      let attrs = Pin.factory.createAttributeSet()
      try attrs.setValue(Pin.attrType, input ? Pin.input : Pin.output)
      try attrs.setValue(StdAttr.label, label)
      return try Pin.factory.createComponent(location: location, attributes: attrs)
    }

    let inner = try Circuit(name: "inner")
    try inner.mutatorAdd(pin("a", Location.create(100, 100, hasToSnap: true), input: true))
    try inner.mutatorAdd(pin("y", Location.create(300, 100, hasToSnap: true), input: false))

    let outer = try Circuit(name: "outer")
    let factory = inner.subcircuitFactory
    let placement = try factory.createComponent(
      location: Location.create(300, 300, hasToSnap: true),
      attributes: factory.createAttributeSet())
    try outer.mutatorAdd(placement)

    // Give every port of the placement a wire and a toplevel `Pin`, so the fixture is a circuit
    // the real DRC will accept: `processSubcircuit` needs a net at each end to have anything to
    // bind, and the toplevel needs at least one port or `designRuleCheckResult` rejects it. Inputs
    // sit on the west edge of the box and outputs on the east, so the stub runs outward.
    for (index, end) in placement.ends.enumerated() {
      let outward = end.isInput ? -100 : 100
      let far = Location.create(end.location.x + outward, end.location.y, hasToSnap: false)
      try outer.mutatorAdd(Wire.create(end.location, far))
      try outer.mutatorAdd(pin(end.isInput ? "in\(index)" : "out\(index)", far, input: end.isInput))
    }
    return (outer, inner, placement)
  }

  /// The regression this suite could not previously see. `standalone` used to build its
  /// `NetlistSet` as a temporary, so `Netlist.owner` was nil the instant the method returned and
  /// every subcircuit lookup answered nil, which a *flat* circuit never notices, and which every
  /// other test in this file is flat. Before the fix `subNetlist` returned nil here and
  /// `generateNetlist` failed with "BUG: Sub-circuit without a circuit behind it".
  @Test("a standalone netlist resolves the netlist of a subcircuit it contains")
  func standaloneResolvesSubcircuits() throws {
    let (outer, inner, placement) = try makeHierarchy()
    defer { withExtendedLifetime(inner) {} }
    let netlist = Netlist.standalone(for: outer)

    let sub = try #require(
      netlist.subNetlist(of: placement),
      "a standalone netlist could not reach its subcircuit's netlist — its NetlistSet is gone")
    #expect(sub.circuit === inner)
    #expect(sub.name == "inner")

    // The set is a *cache*, so the second lookup must hand back the same object rather than a
    // fresh netlist: that is what makes the DRC's "build every subcircuit first" pass meaningful.
    let again = try #require(netlist.subNetlist(of: placement))
    #expect(again === sub)
  }

  /// The end-to-end consequence, and the test that found the *second* defect.
  ///
  /// `designRuleCheckResult` is the real entry point, it is what builds every subcircuit's
  /// netlist before this one's `processSubcircuit` reads their port lists, and it is entirely
  /// routed through `owner`. It failed twice, for two independent reasons, and that is worth
  /// recording because fixing the first left this test still red:
  ///
  ///   1. the dead `NetlistSet`, so `processSubcircuit` reported "BUG: Sub-circuit without a
  ///      circuit behind it";
  ///   2. and then, with the owner alive, "BUG: Unable to find pin in sub-circuit"; because
  ///      `processSubcircuit` read `CircuitAttributes.pinInstances`, which nothing populates.
  ///      See `Netlist.subcircuitPins(of:)`. That one was invisible to the corpus gate and cost
  ///      it five circuits, all filed under other explanations.
  ///
  /// The captured sink is why the second one was diagnosable at all: without it a failing DRC
  /// says only "expected 0, got 2".
  @Test("a standalone netlist passes DRC on a hierarchical circuit, and records the subcircuit")
  func standaloneDrcAcceptsAHierarchicalCircuit() throws {
    let (outer, inner, placement) = try makeHierarchy()
    defer { withExtendedLifetime(inner) {} }
    let netlist = Netlist.standalone(for: outer)

    var sheetNames: [String] = []
    let status = CapturingReportSink.capturing { sink -> NetlistDrcStatus in
      let status = netlist.designRuleCheckResult(isTopLevel: true, sheetNames: &sheetNames)
      #expect(status == .passed, "DRC errors: \(sink.errors)")
      return status
    }
    #expect(status == .passed)
    #expect(netlist.subCircuits.count == 1)
    #expect(netlist.subCircuits.first?.component === placement)

    // The recursion really descended: `inner` was walked too, and got its own sheet name.
    #expect(sheetNames.sorted() == ["inner", "outer"])
    let sub = try #require(netlist.subNetlist(of: placement))
    #expect(sub.isValid)
    #expect(sub.inputPorts.count == 1)
    #expect(sub.outputPorts.count == 1)
  }

  /// The hierarchy walk that landed alongside this defect. `constructHierarchyTree` descends
  /// through `subNetlist(of:)`, so on a standalone netlist it used to walk an empty tree and
  /// number nothing: silently, since a tree with no bubbles and a tree that was never visited
  /// produce the same three zeroes. `setLocalBubbleId` on the placement is the difference: it is
  /// only ever called from inside the loop over `subCircuits` that the walk skipped.
  @Test("constructHierarchyTree descends into a standalone netlist's subcircuits")
  func standaloneHierarchyTreeDescends() throws {
    let (outer, inner, placement) = try makeHierarchy()
    defer { withExtendedLifetime(inner) {} }
    let netlist = Netlist.standalone(for: outer)

    var sheetNames: [String] = []
    #expect(netlist.designRuleCheckResult(isTopLevel: true, sheetNames: &sheetNames) == .passed)

    let sub = try #require(netlist.subNetlist(of: placement))
    let subComponent = try #require(netlist.subCircuits.first)
    // `designRuleCheckResult` already ran the walk at toplevel; run it again explicitly so the
    // assertion is about this method rather than about DRC ordering.
    netlist.constructHierarchyTree()

    #expect(subComponent.localBubbleInputStartId == 0)
    #expect(subComponent.localBubbleOutputStartId == 0)
    #expect(netlist.numberOfInputBubbles == sub.numberOfInputBubbles)
    #expect(netlist.numberOfOutputBubbles == sub.numberOfOutputBubbles)
    // Still reachable after the walk, i.e. the walk did not lean on a set that had already died.
    #expect(netlist.subNetlist(of: placement) === sub)
  }

  /// The other half of the fix, and the reason `owner` cannot simply become `strong`.
  ///
  /// A standalone root owns its `NetlistSet` so that sub-netlists stay reachable. If that set also
  /// held the *root*, as it does every other netlist it vends, the pair would retain each other
  /// and the whole graph would leak, which is precisely the cycle D3's weak `owner` edge exists to
  /// prevent and which no functional test would ever notice. So: drop the root, and the sub-netlist
  /// must go with it.
  @Test("dropping a standalone netlist releases its set and its sub-netlists (D3: no cycle)")
  func standaloneGraphIsAcyclic() throws {
    let (outer, inner, placement) = try makeHierarchy()
    defer { withExtendedLifetime(inner) {} }

    weak var releasedSubNetlist: Netlist?
    do {
      let netlist = Netlist.standalone(for: outer)
      let sub = try #require(netlist.subNetlist(of: placement))
      #expect(sub.circuit === inner)
      releasedSubNetlist = sub
    }
    #expect(
      releasedSubNetlist == nil,
      "the standalone netlist graph retains itself — a D3 cycle, invisible to every other test")
  }

  @Test("an out-of-range solder point is inert, not a trap (D13)")
  func outOfRangeSolderPointIsInert() throws {
    let circuit = try makeCircuit()
    let netlist = Netlist.standalone(for: circuit)
    #expect(netlist.generateNetlist())
    let comp: any HdlNetlistComponent = try #require(netlist.inputPorts.first)
    let end = comp.end(at: 0)
    #expect(end.solderPoint(atBit: 99).parentNet == nil)
    #expect(end.solderPoint(atBit: -1).parentNetBitIndex == -1)
    // And an out-of-range end is a zero-bit end rather than a crash.
    #expect(comp.end(at: 99).nrOfBits == 0)
  }
}
