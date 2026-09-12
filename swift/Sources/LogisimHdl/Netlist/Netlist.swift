// Netlist: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// `com/cburch/logisim/fpga/designrulecheck/Netlist.java`. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore licensed GPL-3.0-only.
// See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ══ WHAT THIS FILE IS FOR ═══════════════════════════════════════════════════════════════════
//
// `HdlNetlist`/`HdlNetlistComponent`/`HdlNet` were declared with no conformer: the generation
// framework existed and the net graph that feeds it did not, so nothing in the module could be
// reached. This is that graph: `Netlist` walks a `Circuit`'s wires, tunnels and splitters,
// resolves every component pin down to (root net, bit index), and answers the questions
// `Hdl`/`AbstractHdlGeneratorFactory` ask.
//
// ── Net numbering is output, not bookkeeping ────────────────────────────────────────────────
//
// `getNetId(net)` is emitted verbatim as `s_LOGISIM_NET_<id>` / `s_LOGISIM_BUS_<id>`, and it is
// this class's `myNets` index. Upstream discovers nets by draining a `HashSet<Wire>`, so the
// numbering follows JVM hash order. `JavaHashSetOrder.swift` reproduces that exactly rather
// than letting Swift's seed-randomised `Set` permute every signal name in every generated file;
// its header has the argument for why the reproduction is faithful.
//
// ── Where this port stops ───────────────────────────────────────────────────────────────────
//
// Everything under "NOT PORTED, by Java member" at the bottom of this file, and see
// `ToplevelHdlGeneratorFactory.swift` for the one whole missing *file*. The short version: the
// connection graph, the clock tree and the connectivity DRC are here; the FPGA board/pin-mapping
// half (`com.cburch.logisim.fpga.data`, "bubbles", `MappableResourcesContainer`) is not, and it
// is what `constructHierarchyTree` and `getMappableResources` exist to serve.
//
// ── D13 ─────────────────────────────────────────────────────────────────────────────────────
//
// Nothing here traps. Upstream signals every malformed-circuit condition by returning `false`
// and pushing a message through `Reporter`, and that is preserved verbatim: a `.circ` with a
// splitter that has no bus connection, a subcircuit port that cannot be resolved, or a
// bit-width conflict produces a DRC error, never a crash. The one place upstream would throw
// (`ConnectionEnd.get` returning `null` into a dereference) is handled in
// `ConnectionPoint.swift`.

import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.fpga.designrulecheck.Netlist`'s DRC status bits.
public struct NetlistDrcStatus: OptionSet, Sendable {
  public let rawValue: Int
  public init(rawValue: Int) { self.rawValue = rawValue }

  /// `Netlist.DRC_PASSED`.
  public static let passed = NetlistDrcStatus([])
  /// `Netlist.ANNOTATE_REQUIRED`.
  public static let annotateRequired = NetlistDrcStatus(rawValue: 1)
  /// `Netlist.DRC_ERROR`.
  public static let error = NetlistDrcStatus(rawValue: 2)
  /// `Netlist.DRC_REQUIRED`.
  public static let required = NetlistDrcStatus(rawValue: 4)
}

/// The per-project cache of netlists, one per `Circuit`.
///
/// **Seam.** Upstream hangs the netlist off the circuit itself (`Circuit.getNetList()`, a lazily
/// created field). `Circuit` lives in `LogisimFile` and this module sits above it, so the cache
/// is external and explicit instead. That is also strictly better for D3: the netlist holds its
/// circuit and every component in it strongly, and a field on `Circuit` would make that a
/// permanent cycle on every open circuit rather than a value the caller can drop.
public final class NetlistSet {

  private var byCircuit: [ObjectIdentifier: Netlist] = [:]

  /// The root of a standalone graph (`Netlist.standalone`), if this set is backing one.
  ///
  /// **Weak, and deliberately kept out of `byCircuit`.** Ownership runs the normal way round for
  /// every netlist this set vends, set holds netlist strongly, netlist points back weakly, but a
  /// standalone root has no external owner for its set, so for that one node the direction is
  /// inverted: the *root* holds the set. Filing it in `byCircuit` as well would close the loop
  /// `Netlist → NetlistSet → Netlist` and leak the whole graph, which is exactly the cycle D3's
  /// weak `owner` edge exists to prevent. Hence a separate, weak slot: lookups still find the root
  /// (so `subNetlist` and the DRC recursion see one netlist per circuit, not two), and nothing
  /// retains it.
  private weak var standaloneRoot: Netlist?

  public init() {}

  /// `Circuit.getNetList()`.
  public func netlist(for circuit: Circuit) -> Netlist {
    let key = ObjectIdentifier(circuit)
    if let root = standaloneRoot, ObjectIdentifier(root.circuit) == key { return root }
    if let existing = byCircuit[key] { return existing }
    let created = Netlist(circuit: circuit, owner: self)
    byCircuit[key] = created
    return created
  }

  /// Builds the root of a standalone graph. See `standaloneRoot` for why it is not cached, and
  /// `Netlist.standalone(for:)` for why the method exists at all.
  fileprivate func makeStandaloneRoot(for circuit: Circuit) -> Netlist {
    let root = Netlist(circuit: circuit, owner: self, retainingOwner: true)
    standaloneRoot = root
    return root
  }

  /// Drop every cached netlist. The caller does this after editing a circuit; upstream's
  /// equivalent is `Circuit.setNetList(null)` / the `DRC_REQUIRED` reset.
  ///
  /// A standalone root is not in the cache and so is not dropped here; it is the caller's own
  /// value, and dropping it is what releasing that value does.
  public func invalidateAll() {
    byCircuit.removeAll()
  }
}

/// `com.cburch.logisim.fpga.designrulecheck.Netlist`, one circuit's net graph.
public final class Netlist {

  // MARK: - Identity

  /// `Netlist.myCircuit`.
  public let circuit: Circuit

  /// The cache this netlist came from. `weak` because `NetlistSet` holds this object strongly
  /// (D3): this is the back-edge of that pair and closing it strongly would leak every netlist.
  private weak var weakOwner: NetlistSet?

  /// The same set, held strongly, and non-nil on exactly one netlist per graph: the root handed
  /// back by `standalone(for:)`, whose set nobody else holds. See `NetlistSet.standaloneRoot`;
  /// that set does *not* hold this netlist back, so the pair is a chain, not a cycle.
  private let strongOwner: NetlistSet?

  /// The set this netlist resolves subcircuits through.
  private var owner: NetlistSet? { strongOwner ?? weakOwner }

  /// `Netlist.circuitName`.
  private var circuitNameStorage: String = ""

  // MARK: - Contents

  /// `Netlist.myNets`, in discovery order; the order that becomes `getNetId`.
  public private(set) var nets: [Net] = []

  /// `Netlist.mySubCircuits`.
  public private(set) var subCircuits: [NetlistComponent] = []

  /// `Netlist.myComponents`: the synthesizable, non-structural components.
  public private(set) var normalComponents: [NetlistComponent] = []

  /// `Netlist.myClockGenerators`.
  public private(set) var clockGenerators: [NetlistComponent] = []

  /// `Netlist.myInputPorts`: `Pin`s that *drive* this circuit's interior, i.e. inputs.
  public private(set) var inputPorts: [NetlistComponent] = []

  /// `Netlist.myOutputPorts`.
  public private(set) var outputPorts: [NetlistComponent] = []

  /// `Netlist.myInOutPorts`. Always empty in 4.1.0: `processNormalComponent` sorts every `Pin`
  /// into exactly one of input/output by `getEnd(0).isInput()`, and nothing else ever appends
  /// here. Kept because the counts below are read by `ToplevelHdlGeneratorFactory`.
  public private(set) var inOutPorts: [NetlistComponent] = []

  /// `Netlist.mySplitters`.
  private var splitters: [any Component] = []

  /// `Netlist.myClockInformation`.
  public let clockInformation = ClockTreeFactory()

  /// `Netlist.currentHierarchyLevel`.
  private var hierarchyLevel: [String] = []

  /// `Netlist.drcStatus`.
  public private(set) var drcStatus: NetlistDrcStatus = .required

  /// `Netlist.localNrOfInportBubbles` and friends. Always `0` in this port: see the
  /// `constructHierarchyTree` note at the bottom of the file.
  public private(set) var localNrOfInportBubbles = 0
  public private(set) var localNrOfOutportBubbles = 0
  public private(set) var localNrOfInOutBubbles = 0

  /// `Netlist(Circuit)`.
  ///
  /// `retainingOwner` is set for a standalone root and for nothing else; `NetlistSet` is the only
  /// caller and `NetlistSet.standaloneRoot` explains the asymmetry.
  init(circuit: Circuit, owner: NetlistSet?, retainingOwner: Bool = false) {
    self.circuit = circuit
    self.weakOwner = owner
    self.strongOwner = retainingOwner ? owner : nil
    clear()
  }

  /// Builds a netlist for `circuit` with a private `NetlistSet` behind it, for a caller that has
  /// one circuit and no set to share.
  ///
  /// **The returned netlist owns that set**, which is the whole point: a subcircuit's netlist is
  /// reached through the set, so a set that died with this call would make every hierarchical
  /// design resolve to nil. It did. This used to read `NetlistSet().netlist(for: circuit)`, which
  /// left `owner` nil the moment it returned; the compiler said so, and `processSubcircuit` then
  /// failed the DRC with "BUG: Sub-circuit without a circuit behind it" for any circuit that
  /// instantiated another. A *flat* circuit never touched `owner` and so looked perfectly healthy,
  /// which is why every test here passed.
  ///
  /// Sub-netlists stay owned by the set as usual; only the root's edge is inverted, and the set
  /// does not point back at it strongly, so nothing here retains itself (D3).
  public static func standalone(for circuit: Circuit) -> Netlist {
    NetlistSet().makeStandaloneRoot(for: circuit)
  }

  // MARK: - Lifecycle

  /// `Netlist.clear()`.
  public func clear() {
    for subcircuit in subCircuits {
      if let sub = subcircuit.component.factory as? any SubcircuitFactory,
        let subCircuitObject = sub.subcircuit as? Circuit,
        let netlist = owner?.netlist(for: subCircuitObject)
      {
        netlist.clear()
      }
    }
    drcStatus = .required
    nets.removeAll()
    subCircuits.removeAll()
    normalComponents.removeAll()
    clockGenerators.removeAll()
    inputPorts.removeAll()
    inOutPorts.removeAll()
    outputPorts.removeAll()
    splitters.removeAll()
    localNrOfInportBubbles = 0
    localNrOfOutportBubbles = 0
    localNrOfInOutBubbles = 0
    hierarchyLevel.removeAll()
  }

  /// `Netlist.getName()`.
  public var name: String { circuit.name }

  /// `Netlist.isValid()`.
  public var isValid: Bool { drcStatus == .passed }

  /// `Netlist.setCurrentHierarchyLevel(List<String>)`.
  public func setCurrentHierarchyLevel(_ level: [String]) {
    hierarchyLevel = level
  }

  // MARK: - Subcircuit access

  /// The netlist of the circuit `component` instantiates, or `nil` when it is not a subcircuit.
  ///
  /// Upstream spells this `((SubcircuitFactory) comp.getFactory()).getSubcircuit().getNetList()`
  /// at every call site; it is one method here because the `NetlistSet` indirection (see that
  /// type's header) makes the spelling longer, not shorter. Public because the bubble tree is
  /// hierarchical and anything that walks it, the netlist gate's report, `MapComponent`'s
  /// eventual `getMappableResources`, needs to descend.
  public func subNetlist(of component: any Component) -> Netlist? {
    guard let factory = component.factory as? any SubcircuitFactory,
      let subCircuitObject = factory.subcircuit as? Circuit
    else { return nil }
    return owner?.netlist(for: subCircuitObject)
  }

  // MARK: - Design rule check

  /// `Netlist.designRuleCheckResult(boolean, ArrayList<String>)`.
  ///
  /// `sheetNames` accumulates across the recursion exactly as upstream's does; pass a fresh
  /// array at the top level.
  @discardableResult
  public func designRuleCheckResult(
    isTopLevel: Bool, sheetNames: inout [String]
  ) -> NetlistDrcStatus {
    if isTopLevel { clear() }
    if drcStatus == .passed { return .passed }
    drcStatus = .passed

    if circuit.name.isEmpty {
      Reporter.shared.addFatalError("Found a sheet with an empty name")
      drcStatus.formUnion(.error)
    }
    if sheetNames.contains(circuit.name) {
      Reporter.shared.addFatalErrorFmt("Multiple sheets with the name \"%s\" found", circuit.name)
      drcStatus.formUnion(.error)
    } else {
      sheetNames.append(circuit.name)
    }

    // Build every subcircuit's netlist first: this one's `processSubcircuit` reads their port
    // lists.
    var handledCircuits: [ObjectIdentifier] = []
    for component in circuit.nonWires {
      guard let factory = component.factory as? any SubcircuitFactory,
        let subCircuitObject = factory.subcircuit as? Circuit
      else { continue }
      let key = ObjectIdentifier(subCircuitObject)
      if handledCircuits.contains(key) { continue }
      handledCircuits.append(key)
      guard let subNetlist = owner?.netlist(for: subCircuitObject) else { continue }
      if subNetlist.designRuleCheckResult(isTopLevel: false, sheetNames: &sheetNames) != .passed {
        drcStatus = .required
        return .error
      }
    }

    if !checkComponentsAndLabels() { return drcStatus }

    Reporter.shared.addInfo("Building netlist for \(circuit.name)")
    if !generateNetlist() {
      clear()
      drcStatus = .error
      return drcStatus
    }
    if hasShortCircuits() {
      clear()
      drcStatus = .error
      return drcStatus
    }
    reportSinksWithoutSource()
    reportUnconnectedPins()

    if isTopLevel {
      if !detectClockTree() {
        drcStatus = .error
        return drcStatus
      }
      // `Netlist.java:471`. This is what makes the three bubble counters mean anything, and the
      // count below is upstream's toplevel-has-IO test: a design whose only board-facing signals
      // are LEDs and buttons has no `Pin` at all and passes purely on bubbles.
      constructHierarchyTree()
      let ports = inputPorts.count + outputPorts.count
        + localNrOfInportBubbles + localNrOfOutportBubbles + localNrOfInOutBubbles
      if ports == 0 {
        Reporter.shared.addFatalErrorFmt(
          "Toplevel \"%s\" has no input(s) and/or no output(s)!", circuit.name)
        drcStatus = .error
        return drcStatus
      }
    }

    Reporter.shared.addInfo(
      "Circuit \"\(circuit.name)\" has \(numberOfNets) nets and \(numberOfBusses) busses.")
    Reporter.shared.addInfo("Circuit \"\(circuit.name)\" passed DRC check")
    drcStatus = .passed
    return drcStatus
  }

  /// The "preparing stage" of `designRuleCheckResult`: HDL support, label rules, tri-state.
  /// Returns whether the netlist may be built.
  private func checkComponentsAndLabels() -> Bool {
    var componentNames: [String] = []
    for component in circuit.nonWires {
      let name = HdlGeneratorLookup.shared.hdlName(for: component)
      if !componentNames.contains(name) { componentNames.append(name) }
    }

    var labels: [String: any Component] = [:]
    for component in circuit.nonWires {
      if !HdlGeneratorLookup.shared.isSupported(component) {
        Reporter.shared.addError(
          "Component \"\(component.factory.displayName)\" is not supported for HDL generation")
        drcStatus.formUnion(.error)
      }
      if component.factory.requiresNonZeroLabel {
        let rawLabel = component.attributeSet.getValue(StdAttr.label) ?? ""
        let label = CorrectLabel.correctLabel(rawLabel).uppercased()
        let componentName = HdlGeneratorLookup.shared.hdlName(for: component)
        if label.isEmpty {
          Reporter.shared.addError(
            "Component \"\(component.factory.displayName)\" has no label — annotation required")
          drcStatus.formUnion(.annotateRequired)
        } else {
          if componentNames.contains(label) {
            Reporter.shared.addError("Component label \"\(label)\" equals a component name")
            drcStatus.formUnion(.error)
          }
          if CorrectLabel.nameErrors(label, "Component label") != nil {
            Reporter.shared.addError("Component label \"\(label)\" is invalid")
            drcStatus.formUnion(.error)
          }
          if labels[label] != nil {
            Reporter.shared.addError("Duplicated component label \"\(label)\"")
            drcStatus.formUnion(.error)
          } else {
            labels[label] = component
          }
        }
        if component.factory is any SubcircuitFactory {
          if label == componentName.uppercased() {
            Reporter.shared.addError("Sub-circuit label \"\(label)\" equals its circuit name")
            drcStatus.formUnion(.error)
          }
          if !CorrectLabel.isCorrectLabel(
            component.factory.name,
            "Found bad component \"\(component.factory.name)\" in circuit \"\(circuit.name)\"")
          {
            drcStatus.formUnion(.error)
          }
          // `Netlist.java:355-357`. Every value this writes is overwritten by
          // `constructHierarchyTree`, which resets all three to 0 before recomputing them, so
          // this only matters for a netlist whose DRC ran *without* the toplevel pass, i.e. a
          // sub-netlist inspected on its own. Ported because a reader who finds the counters
          // populated there would otherwise have no idea where the numbers came from.
          if let subNetlist = subNetlist(of: component) {
            localNrOfInportBubbles += subNetlist.localNrOfInportBubbles
            localNrOfOutportBubbles += subNetlist.localNrOfOutportBubbles
            localNrOfInOutBubbles += subNetlist.localNrOfInOutBubbles
          }
        }
      }
      if component.factory.hasThreeStateDrivers(component.attributeSet) {
        Reporter.shared.addError(
          "Component \"\(component.factory.displayName)\" has tri-state drivers")
        drcStatus.formUnion(.error)
      }
    }
    return drcStatus == .passed
  }

  // MARK: - Netlist construction

  /// `Netlist.generateNetlist()`.
  @discardableResult
  public func generateNetlist() -> Bool {
    circuitNameStorage = circuit.name

    // FIRST PASS: gather wire segments into nets.
    //
    // `remainingWires` stands in for Java's `HashSet<Wire> wires`, ordered to match how the JVM
    // would iterate it, see `JavaHashSetOrder.swift`.
    var remainingWires = JavaHashSet.order(circuit.wires) { Self.javaHashCode(of: $0) }
    while !remainingWires.isEmpty {
      let newNet = Net()
      collectNet(from: &remainingWires, into: newNet)
      if !newNet.isEmpty { nets.append(newNet) }
    }

    let components = circuit.nonWires
    var tunnelList: [any Component] = []
    splitters.removeAll()
    var bitWidthConflict = false

    // A `Probe` is deliberately transparent to the netlist: upstream removes it so that a design
    // can keep its debugging probes and still be downloaded (`Netlist.java:601-608`).
    for component in components {
      if component.factory.name == NetlistFactoryNames.probe { continue }
      if Self.isSplitter(component) { splitters.append(component) }
      if component.factory.isTunnel { tunnelList.append(component) }
      // Upstream's `ignore` flag guards only the `outputsList`/`inputsList` location sets, and
      // the single DRC check that read them is commented out in 4.1.0
      // (`Netlist.java:617-624`). Neither set is read anywhere else, so both are dropped along
      // with the flag; the bit-width marking below runs for every component either way, exactly
      // as it does upstream.
      for end in component.ends {
        let width = end.width.width
        for net in nets where net.contains(end.location) {
          if !net.setWidth(width) { bitWidthConflict = true }
        }
      }
    }
    if bitWidthConflict {
      Reporter.shared.addError(
        "Not all bus widths in circuit \"\(circuit.name)\" are the same on a net")
      return false
    }

    // Direct component-to-component connections: two pins sharing a location with no wire.
    var points: [Location: Int] = [:]
    var widthMismatch = false
    for component in components {
      for end in component.ends {
        let location = end.location
        if let bitWidth = points[location] {
          var newNet = true
          for net in nets where net.contains(location) { newNet = false }
          if newNet {
            if bitWidth == end.width.width {
              nets.append(Net(location: location, width: bitWidth))
            } else {
              widthMismatch = true
            }
          }
        } else {
          points[location] = end.width.width
        }
      }
    }
    if widthMismatch {
      Reporter.shared.addError(
        "Component has a different bus width than its connected net in circuit "
          + "\"\(circuit.name)\"")
      return false
    }

    // Tunnels: merge nets that share a tunnel label.
    var areTunnelsPresent = false
    for component in tunnelList {
      let label = component.attributeSet.getValue(StdAttr.label) ?? ""
      for end in component.ends {
        for net in nets where net.contains(end.location) {
          net.addTunnel(label)
          areTunnelsPresent = true
        }
      }
    }
    if areTunnelsPresent && !mergeTunnelNets() { return false }

    removeDuplicateSplitters()

    // Drop unconnected (zero-width) nets.
    nets.removeAll { $0.bitWidth == 0 }

    if !collapseSingleFanoutSplitters() { return false }
    if !linkSplitterChildNets() { return false }

    for net in nets where net.isRootNet { net.initializeSourceSinks() }

    for component in components {
      if component.factory is any SubcircuitFactory {
        if !processSubcircuit(component) {
          clear()
          return false
        }
      } else if component.factory.isPin
        // `Netlist.java:1002`, `containsAttribute(StdAttr.MAPINFO)`, a *declaration* test. Every
        // 4.1.0 factory that declares it also has an HDL generator, so this clause admits nothing
        // the next one would not; it is upstream's condition and it is here so it stays that way.
        || HdlGeneratorLookup.shared.declaresMapInformation(component)
        || HdlGeneratorLookup.shared.hasGenerator(for: component)
      {
        if !processNormalComponent(component) {
          clear()
          return false
        }
      }
    }

    processComplexSplitters()
    return true
  }

  /// `Netlist.getNet(Wire, Net)`.
  ///
  /// Java recurses once per wire in the net; this is the same traversal as an explicit stack, so
  /// a 10 000-segment bus cannot overflow the Swift stack (D13: no traps reachable from a
  /// `.circ`). Membership is order-independent, `Net` stores points and segments in sets, so
  /// only the *seed* wire matters for the result, and that is `remaining.first`, exactly as
  /// Java's `iterator().next()` is under the reproduced hash order.
  private func collectNet(from remaining: inout [Wire], into net: Net) {
    guard let seed = remaining.first else { return }
    remaining.removeFirst()
    net.add(seed)
    var frontier = [seed]
    while let current = frontier.popLast() {
      var index = 0
      while index < remaining.count {
        if remaining[index].sharesEnd(with: current) {
          let matched = remaining.remove(at: index)
          net.add(matched)
          frontier.append(matched)
        } else {
          index += 1
        }
      }
    }
  }

  /// The tunnel-merge loop of `generateNetlist`.
  private func mergeTunnelNets() -> Bool {
    var mergeFailed = false
    var index = 0
    while index < nets.count {
      let thisNet = nets[index]
      if thisNet.hasTunnel && index < nets.count - 1 {
        var merged = false
        var searchIndex = index + 1
        while searchIndex < nets.count && !merged {
          let searchNet = nets[searchIndex]
          for name in thisNet.tunnelNames where searchNet.containsTunnel(name) && !merged {
            merged = true
            if !searchNet.merge(thisNet) { mergeFailed = true }
          }
          searchIndex += 1
        }
        if merged {
          nets.remove(at: index)
          continue
        }
      }
      index += 1
    }
    if mergeFailed {
      Reporter.shared.addError(
        "Tunnels in circuit \"\(circuit.name)\" connect nets of different bus widths")
      return false
    }
    return true
  }

  /// The duplicate-splitter sweep of `generateNetlist`.
  private func removeDuplicateSplitters() {
    var index = 0
    while index < splitters.count {
      let thisSplitter = splitters[index]
      if index < splitters.count - 1 {
        var duplicateFound = false
        var searchIndex = index + 1
        while searchIndex < splitters.count && !duplicateFound {
          let candidate = splitters[searchIndex]
          if candidate.location == thisSplitter.location {
            duplicateFound = true
            let candidateEnds = candidate.ends
            let thisEnds = thisSplitter.ends
            // **D13.** Upstream indexes `thisSplitter.getEnd(i)` with `i` bounded by the *other*
            // splitter's end count (`Netlist.java:747-751`), so two splitters at the same
            // location with different fanouts throw `IndexOutOfBoundsException` there. Differing
            // end counts mean they are not duplicates, which is the answer the comparison was
            // reaching for anyway.
            if candidateEnds.count != thisEnds.count {
              duplicateFound = false
            } else {
              for i in 0..<candidateEnds.count
              where candidateEnds[i].location != thisEnds[i].location {
                duplicateFound = false
              }
            }
          }
          searchIndex += 1
        }
        if duplicateFound {
          Reporter.shared.addWarning(
            "Duplicated splitter found in circuit \"\(circuit.name)\"; the copy is ignored")
          splitters.remove(at: index)
          continue
        }
      }
      index += 1
    }
  }

  /// The "stupid situation first" sweep: a splitter whose bus end is a single full-width fanout
  /// is not a splitter at all, so its two nets merge and the splitter drops out.
  private func collapseSingleFanoutSplitters() -> Bool {
    var index = 0
    while index < splitters.count {
      let splitter = splitters[index]
      let ends = splitter.ends
      guard !ends.isEmpty else { index += 1; continue }
      let busWidth = ends[0].width.width
      var maxFanoutWidth = 0
      var fanoutIndex = -1
      for i in 1..<max(1, ends.count) where ends[i].width.width > maxFanoutWidth {
        maxFanoutWidth = ends[i].width.width
        fanoutIndex = i
      }
      guard busWidth == maxFanoutWidth, fanoutIndex >= 0 else { index += 1; continue }

      var busNet: Net?
      var connectedNet: Net?
      let busLocation = ends[0].location
      let connectedLocation = ends[fanoutIndex].location
      for net in nets {
        if net.contains(busLocation) {
          if busNet != nil {
            Reporter.shared.addFatalError(
              "BUG: Multiple bus nets found for a single splitter")
            return false
          }
          busNet = net
        }
        if net.contains(connectedLocation) {
          if connectedNet != nil {
            Reporter.shared.addFatalError(
              "BUG: Multiple nets found for a single splitter split connection")
            return false
          }
          connectedNet = net
        }
      }
      var issueWarning = true
      if let connectedNet, let busNet {
        if !busNet.merge(connectedNet) {
          Reporter.shared.addFatalError("BUG: Splitter bus merge error")
          return false
        }
        nets.removeAll { $0 === connectedNet }
        issueWarning = false
      }
      if issueWarning {
        Reporter.shared.addWarning(
          "Splitter in circuit \"\(circuit.name)\" has no connection to its bus end")
      }
      splitters.remove(at: index)
    }
    return true
  }

  /// The evident-splitter pass: give each split-off net its parent and its inherited bits.
  private func linkSplitterChildNets() -> Bool {
    for splitter in splitters {
      let ends = splitter.ends
      guard let combinedEnd = ends.first else { continue }
      var rootNetIndex = -1
      for i in 0..<nets.count where rootNetIndex < 0 {
        if nets[i].contains(combinedEnd.location) { rootNetIndex = i }
      }
      if rootNetIndex < 0 {
        Reporter.shared.addFatalError("BUG: Splitter without a bus connection")
        clear()
        return false
      }
      var connections: [Int] = []
      for i in 1..<max(1, ends.count) {
        var connectedNet = -1
        // Bug-for-bug: upstream's guard is `connectedNet < 1`, not `< 0`, so a net at index 0
        // does not stop the scan and a later match wins (`Netlist.java:923`).
        for j in 0..<nets.count where connectedNet < 1 {
          if nets[j].contains(ends[i].location) { connectedNet = j }
        }
        connections.append(connectedNet)
      }
      var unconnectedEnds = false
      var connectedUnknownEnds = false
      let bitEnd = Self.splitterBitEnd(splitter)
      for i in 1..<max(1, ends.count) {
        let connectedNet = connections[i - 1]
        if connectedNet >= 0 {
          connectedUnknownEnds = connectedUnknownEnds || Self.isNoConnect(bitEnd, end: i)
          if !nets[connectedNet].setParent(nets[rootNetIndex]) {
            nets[connectedNet].forceRootNet()
          }
          for b in 0..<bitEnd.count where bitEnd[b] == i {
            nets[connectedNet].addParentBit(b)
          }
        } else {
          unconnectedEnds = true
        }
      }
      if unconnectedEnds {
        Reporter.shared.addWarning(
          "Splitter in circuit \"\(circuit.name)\" has unconnected ends")
      }
      if connectedUnknownEnds {
        Reporter.shared.addWarning(
          "Splitter in circuit \"\(circuit.name)\" has a connected end that is routed nowhere")
      }
    }
    return true
  }

  /// The complex-splitter pass: mark, for every forced-root net, whether each bit is a hidden
  /// source or a hidden sink of the splitter tree it hangs off.
  private func processComplexSplitters() {
    for thisNet in nets where thisNet.isForcedRootNet {
      for bit in 0..<thisNet.bitWidth {
        for splitter in splitters {
          let ends = splitter.ends
          guard let combinedEnd = ends.first else { continue }
          var connectedBus = -1
          for i in 0..<nets.count where connectedBus < 0 {
            if nets[i].contains(combinedEnd.location) { connectedBus = i }
          }
          if connectedBus < 0 {
            // Already excluded by `linkSplitterChildNets`; upstream calls this "embarrassing".
            Reporter.shared.addFatalError(
              "BUG: A splitter lost its bus connection between passes")
            continue
          }
          let bitEnd = Self.splitterBitEnd(splitter)
          for endId in 1..<max(1, ends.count) {
            if Self.isNoConnect(bitEnd, end: endId) { continue }
            guard thisNet.contains(ends[endId].location) else { continue }
            var indexBits: [Int] = []
            for b in 0..<bitEnd.count where bitEnd[b] == endId { indexBits.append(b) }
            guard bit < indexBits.count else { continue }
            var connectedBusIndex = indexBits[bit]
            var rootBus = nets[connectedBus]
            while !rootBus.isRootNet {
              connectedBusIndex = rootBus.bit(connectedBusIndex)
              guard let parent = rootBus.parent else { break }
              rootBus = parent
            }
            let solderPoint = ConnectionPoint(component: splitter)
            solderPoint.setParentNet(rootBus, bitIndex: connectedBusIndex)
            var isSink = true
            if !thisNet.hasBitSource(bit) {
              var handled: Set<String> = []
              if hasHiddenSource(
                fanoutNet: thisNet, fanoutBitIndex: bit, combinedNet: rootBus,
                combinedBitIndex: connectedBusIndex, handledNets: &handled,
                ignoreSplitter: splitter)
              {
                isSink = false
              }
            }
            if isSink {
              thisNet.addSinkNet(bit, solderPoint)
            } else {
              thisNet.addSourceNet(bit, solderPoint)
            }
          }
        }
      }
    }
  }

  /// `Netlist.processNormalComponent(Component)`.
  private func processNormalComponent(_ component: any Component) -> Bool {
    let normalComponent = NetlistComponent(component: component)
    let ends = component.ends
    for (pinId, thisPin) in ends.enumerated() {
      guard let connection = findConnectedNet(thisPin.location) else { continue }
      let pinIsSink = thisPin.isInput
      guard let thisEnd = normalComponent.connectionEnd(at: pinId) else { continue }
      guard let rootNet = Self.rootNet(of: connection) else {
        Reporter.shared.addFatalError("BUG: Unable to find a root net for a normal component")
        return false
      }
      for bitId in 0..<thisPin.width.width {
        let rootNetBitIndex = Self.rootNetIndex(of: connection, bitIndex: bitId)
        if rootNetBitIndex < 0 {
          Reporter.shared.addFatalError(
            "BUG: Unable to find a root-net bit-index for a normal component")
          return false
        }
        guard let solderPoint = thisEnd.connection(at: bitId) else { continue }
        solderPoint.setParentNet(rootNet, bitIndex: rootNetBitIndex)
        if pinIsSink {
          rootNet.addSink(rootNetBitIndex, solderPoint)
        } else {
          rootNet.addSource(rootNetBitIndex, solderPoint)
        }
      }
    }
    if NetlistFactoryNames.isClock(component.factory) {
      clockGenerators.append(normalComponent)
    } else if component.factory.isPin {
      if component.end(at: 0).isInput {
        outputPorts.append(normalComponent)
      } else {
        inputPorts.append(normalComponent)
      }
    } else {
      normalComponents.append(normalComponent)
    }
    return true
  }

  /// `attrs.getPinInstances()`: a subcircuit placement's pin components, in the same order as its
  /// ends, which is the order `portInfo(label:)` is asked about.
  ///
  /// **Deliberately not `CircuitAttributes.pinInstances`,** which is what upstream reads and what
  /// this method used to read. Nothing in this port ever writes that property: it is typed
  /// `[InstanceComponent]`, and a `Pin` read from a `.circ` is a `StdInstanceComponent`, a
  /// sibling type, not a subclass, so `CircuitSubcircuitFactory.computePorts` files the list on
  /// the factory instead and leaves the attribute empty. `SubcircuitPropagation` was written
  /// against the factory and has the same note; this call site was written against the attribute
  /// and so read an always-empty array.
  ///
  /// The consequence was not subtle once looked for: `processSubcircuit`'s first loop iteration
  /// hit `pinId < subPins.count` with `subPins.count == 0` and failed the DRC with "BUG: Unable to
  /// find pin in sub-circuit", for **every** subcircuit placement that has at least one port. It
  /// went unseen because it is invisible in the corpus: of the 147 circuits the netlist gate
  /// compares, exactly five contain a subcircuit with `ends > 0`, and all five were already on
  /// `NetlistGateTests.knownDivergences` under other explanations.
  ///
  /// The attribute is still the fallback, so if `pinInstances` is ever populated for real this
  /// keeps working.
  private static func subcircuitPins(of component: any Component) -> [any Component] {
    if let placement = component as? InstanceComponent,
      let factory = component.factory as? CircuitSubcircuitFactory
    {
      let pins = factory.pinComponents(for: placement)
      if !pins.isEmpty { return pins }
    }
    let attributePins = (component.attributeSet as? CircuitAttributes)?.pinInstances ?? []
    return attributePins.map { $0 as any Component }
  }

  /// `Netlist.processSubcircuit(Component)`.
  private func processSubcircuit(_ component: any Component) -> Bool {
    let subCircuit = NetlistComponent(component: component)
    guard component.attributeSet is CircuitAttributes,
      let subNetlist = subNetlist(of: component)
    else {
      Reporter.shared.addFatalError("BUG: Sub-circuit without a circuit behind it")
      return false
    }
    let subPins = Self.subcircuitPins(of: component)
    for (pinId, thisPin) in component.ends.enumerated() {
      let connection = findConnectedNet(thisPin.location)
      guard pinId < subPins.count else {
        Reporter.shared.addFatalError("BUG: Unable to find pin in sub-circuit")
        return false
      }
      let label = subPins[pinId].attributeSet.getValue(StdAttr.label) ?? ""
      let subPortIndex = subNetlist.portInfo(label: label)
      if subPortIndex < 0 {
        Reporter.shared.addFatalError("BUG: Unable to find pin in sub-circuit")
        return false
      }
      guard let end = subCircuit.connectionEnd(at: pinId) else { continue }
      if let connection {
        let pinIsSink = thisPin.isInput
        guard let rootNet = Self.rootNet(of: connection) else {
          Reporter.shared.addFatalError("BUG: Unable to find a root net for sub-circuit")
          return false
        }
        for bitId in 0..<thisPin.width.width {
          let rootNetBitIndex = Self.rootNetIndex(of: connection, bitIndex: bitId)
          if rootNetBitIndex < 0 {
            Reporter.shared.addFatalError(
              "BUG: Unable to find a root-net bit-index for sub-circuit")
            return false
          }
          guard let solderPoint = end.connection(at: bitId) else { continue }
          solderPoint.setParentNet(rootNet, bitIndex: rootNetBitIndex)
          if pinIsSink {
            rootNet.addSink(rootNetBitIndex, solderPoint)
          } else {
            rootNet.addSource(rootNetBitIndex, solderPoint)
          }
          solderPoint.setChildsPortIndex(subPortIndex)
        }
      } else {
        for bitId in 0..<thisPin.width.width {
          end.connection(at: bitId)?.setChildsPortIndex(subPortIndex)
        }
      }
    }
    subCircuits.append(subCircuit)
    return true
  }

  // MARK: - Net queries

  /// `Netlist.findConnectedNet(Location)`.
  private func findConnectedNet(_ location: Location) -> Net? {
    nets.first { $0.contains(location) }
  }

  /// `Netlist.getRootNet(Net)`.
  private static func rootNet(of child: Net?) -> Net? {
    guard let child else { return nil }
    if child.isRootNet { return child }
    var root = child.parent
    while let current = root, !current.isRootNet { root = current.parent }
    return root
  }

  /// `Netlist.getRootNetIndex(Net, byte)`. `-1` when the chain cannot be followed.
  private static func rootNetIndex(of child: Net?, bitIndex: Int) -> Int {
    guard let child, bitIndex >= 0, bitIndex <= child.bitWidth else { return -1 }
    if child.isRootNet { return bitIndex }
    var root = child.parent
    var index = child.bit(bitIndex)
    while let current = root, !current.isRootNet {
      index = current.bit(index)
      root = current.parent
    }
    return index
  }

  /// `Netlist.getNetId(Net)`; the index that becomes the generated signal's name.
  public func netId(of net: Net) -> Int {
    nets.firstIndex { $0 === net } ?? -1
  }

  /// `Netlist.numberOfNets()`, single-bit root nets.
  public var numberOfNets: Int {
    nets.filter { $0.isRootNet && !$0.isBus }.count
  }

  /// `Netlist.numberOfBusses()`.
  public var numberOfBusses: Int {
    nets.filter { $0.isRootNet && $0.isBus }.count
  }

  /// `Netlist.getNumberOfInputPortBits()`.
  public var numberOfInputPortBits: Int {
    inputPorts.reduce(0) { $0 + ($1.connectionEnd(at: 0)?.nrOfBitsValue ?? 0) }
  }

  /// `Netlist.numberOfOutputPortBits()`.
  public var numberOfOutputPortBits: Int {
    outputPorts.reduce(0) { $0 + ($1.connectionEnd(at: 0)?.nrOfBitsValue ?? 0) }
  }

  /// `Netlist.numberOfInOutPortBits()`.
  public var numberOfInOutPortBits: Int {
    inOutPorts.reduce(0) { $0 + ($1.connectionEnd(at: 0)?.nrOfBitsValue ?? 0) }
  }

  /// `Netlist.numberOfClockTrees()`.
  public var numberOfClockTrees: Int { clockInformation.sourceContainer.nrOfSources }

  // MARK: - FPGA bubble hierarchy

  /// `Netlist.getNumberOfInputBubbles()`.
  public var numberOfInputBubbles: Int { localNrOfInportBubbles }
  /// `Netlist.numberOfOutputBubbles()`.
  public var numberOfOutputBubbles: Int { localNrOfOutportBubbles }
  /// `Netlist.numberOfInOutBubbles()`.
  public var numberOfInOutBubbles: Int { localNrOfInOutBubbles }

  /// `Netlist.constructHierarchyTree(null, new ArrayList<>(), 0, 0, 0)`, the toplevel entry.
  public func constructHierarchyTree() {
    var circuits: Set<String> = []
    constructHierarchyTree(
      circuits: &circuits, name: [], gInputId: 0, gOutputId: 0, gInOutId: 0)
  }

  /// `Netlist.constructHierarchyTree(Set<String>, ArrayList<String>, Integer, Integer, Integer)`.
  ///
  /// Numbers every board-facing *bubble* in the design twice: a **local** index within each
  /// sheet, and a **global** index keyed by the instance's hierarchy path. The globals are what
  /// `MapComponent` binds to a physical FPGA pin and what indexes
  /// `s_LOGISIM_INPUT_BUBBLES`/`_OUTPUT_`/`_INOUT_` in the generated toplevel, so, like
  /// `getNetId`, the *order* is output, not bookkeeping. `tools/hdlbridge/NetlistBridge.java`
  /// dumps the real tree and `NetlistGateTests` diffs it.
  ///
  /// **`gInputId` and friends are `Integer` upstream, i.e. passed by value.** The `+=` inside
  /// the loop rebinds the local only; the caller never sees it. That is not an accident and is
  /// not a leak either: the parent adds the *whole subtree's* count itself, immediately after
  /// recursing, so the child's own increments would double-count. Swift `Int` parameters
  /// reproduce it exactly, which is the one thing about this method worth being careful with.
  ///
  /// `circuits` is shared across the whole recursion (Java passes the same `HashSet` down) and
  /// is what makes a circuit instantiated twice recurse once: the second instance takes the
  /// `enumerateGlobalBubbleTree` path instead, re-walking the already-numbered sub-tree to give
  /// it global ids under the *second* hierarchy path.
  public func constructHierarchyTree(
    circuits: inout Set<String>, name: [String],
    gInputId: Int, gOutputId: Int, gInOutId: Int
  ) {
    var gInputId = gInputId
    var gOutputId = gOutputId
    var gInOutId = gInOutId

    localNrOfInportBubbles = 0
    localNrOfOutportBubbles = 0
    localNrOfInOutBubbles = 0

    for comp in subCircuits {
      guard let factory = comp.component.factory as? any SubcircuitFactory,
        let subNetlist = subNetlist(of: comp.component)
      else { continue }
      let names = name + [Self.hierarchyName(of: comp)]
      let firstTime = !circuits.contains(factory.name)
      if firstTime {
        circuits.insert(factory.name)
        subNetlist.constructHierarchyTree(
          circuits: &circuits, name: names,
          gInputId: gInputId, gOutputId: gOutputId, gInOutId: gInOutId)
      }
      let subInputBubbles = subNetlist.localNrOfInportBubbles
      let subInOutBubbles = subNetlist.localNrOfInOutBubbles
      let subOutputBubbles = subNetlist.localNrOfOutportBubbles
      comp.setLocalBubbleId(
        inputStart: localNrOfInportBubbles, nrOfInput: subInputBubbles,
        outputStart: localNrOfOutportBubbles, nrOfOutput: subOutputBubbles,
        inOutStart: localNrOfInOutBubbles, nrOfInOut: subInOutBubbles)
      localNrOfInportBubbles += subInputBubbles
      localNrOfInOutBubbles += subInOutBubbles
      localNrOfOutportBubbles += subOutputBubbles
      comp.addGlobalBubbleId(
        hierarchyName: names,
        inputStart: gInputId, nrOfInput: subInputBubbles,
        outputStart: gOutputId, nrOfOutput: subOutputBubbles,
        inOutStart: gInOutId, nrOfInOut: subInOutBubbles)
      if !firstTime {
        subNetlist.enumerateGlobalBubbleTree(
          hierarchyName: names,
          startInputId: gInputId, startOutputId: gOutputId, startInOutId: gInOutId)
      }
      gInputId += subInputBubbles
      gInOutId += subInOutBubbles
      gOutputId += subOutputBubbles
    }

    for comp in normalComponents {
      guard let map = comp.mapInformation else { continue }
      let myHierarchyName = name + [Self.hierarchyName(of: comp)]
      let subInputBubbles = map.numberOfInputBubbles
      let subInOutBubbles = map.numberOfInOutBubbles
      let subOutputBubbles = map.numberOfOutputBubbles
      comp.setLocalBubbleId(
        inputStart: localNrOfInportBubbles, nrOfInput: subInputBubbles,
        outputStart: localNrOfOutportBubbles, nrOfOutput: subOutputBubbles,
        inOutStart: localNrOfInOutBubbles, nrOfInOut: subInOutBubbles)
      localNrOfInportBubbles += subInputBubbles
      localNrOfInOutBubbles += subInOutBubbles
      localNrOfOutportBubbles += subOutputBubbles
      comp.addGlobalBubbleId(
        hierarchyName: myHierarchyName,
        inputStart: gInputId, nrOfInput: subInputBubbles,
        outputStart: gOutputId, nrOfOutput: subOutputBubbles,
        inOutStart: gInOutId, nrOfInOut: subInOutBubbles)
      gInputId += subInputBubbles
      gInOutId += subInOutBubbles
      gOutputId += subOutputBubbles
    }
  }

  /// `Netlist.enumerateGlobalBubbleTree(ArrayList<String>, int, int, int)`; give an
  /// already-numbered sub-tree a second set of global ids, under a different hierarchy path.
  ///
  /// Reached only from `constructHierarchyTree`'s `!firstTime` branch, i.e. for the second and
  /// later instances of one circuit.
  ///
  /// **Bug-for-bug:** the normal-component branch passes `startInOutId` *without* adding
  /// `localBubbleInOutStartId`, while its input and output siblings both add theirs
  /// (`Netlist.java:531-539`). The asymmetry is upstream's; a design with in-out bubbles below a
  /// repeated subcircuit gets in-out ids that collide. Reproduced rather than corrected, because
  /// this file's job is to agree with the jar.
  func enumerateGlobalBubbleTree(
    hierarchyName: [String], startInputId: Int, startOutputId: Int, startInOutId: Int
  ) {
    for comp in subCircuits {
      guard let subNetlist = subNetlist(of: comp.component) else { continue }
      let myHierarchyName = hierarchyName + [Self.hierarchyName(of: comp)]
      subNetlist.enumerateGlobalBubbleTree(
        hierarchyName: myHierarchyName,
        startInputId: startInputId + comp.localBubbleInputStartId,
        startOutputId: startOutputId + comp.localBubbleOutputStartId,
        startInOutId: startInOutId + comp.localBubbleInOutStartId)
    }
    for comp in normalComponents {
      guard let map = comp.mapInformation else { continue }
      let myHierarchyName = hierarchyName + [Self.hierarchyName(of: comp)]
      comp.addGlobalBubbleId(
        hierarchyName: myHierarchyName,
        inputStart: startInputId + comp.localBubbleInputStartId,
        nrOfInput: map.numberOfInputBubbles,
        outputStart: startOutputId + comp.localBubbleOutputStartId,
        nrOfOutput: map.numberOfOutputBubbles,
        inOutStart: startInOutId,
        nrOfInOut: map.numberOfInOutBubbles)
    }
  }

  /// `CorrectLabel.getCorrectLabel(comp.getComponent().getAttributeSet().getValue(StdAttr.LABEL))`
  /// : one path segment of a hierarchy name.
  static func hierarchyName(of comp: NetlistComponent) -> String {
    CorrectLabel.correctLabel(comp.component.attributeSet.getValue(StdAttr.label) ?? "")
  }

  /// `Netlist.getMappableResources(List<String>, boolean)`; every component in the design that
  /// can be bound to a physical FPGA pin, keyed by hierarchy path.
  ///
  /// `MappableResourcesContainer` calls this with `[boardName]` and `toplevel: true`, which is
  /// why every key starts with the board name and every `FpgaMapComponent` string method skips
  /// element 0.
  ///
  /// Upstream returns a `HashMap`, and nothing downstream iterates it in order; every consumer
  /// looks a path up. So the port returns an array of pairs in *deterministic* order (the walk's
  /// own: subcircuits depth-first, then local map-carrying components, then the toplevel pins),
  /// which is strictly more useful and cannot introduce a divergence a `HashMap` would have
  /// hidden. `putAll` semantics are preserved: a later entry with the same path replaces an
  /// earlier one.
  public func mappableResources(
    hierarchy: [String], isTopLevel: Bool
  ) -> [(path: [String], component: NetlistComponent)] {
    var result: [(path: [String], component: NetlistComponent)] = []
    // A side index, because `put` is `HashMap.put` and a linear scan would make this quadratic
    // in the number of mappable resources: 890 on the corpus, but a real board design is
    // thousands and upstream pays O(1) here.
    var indexByPath: [[String]: Int] = [:]
    func put(_ path: [String], _ component: NetlistComponent) {
      if let existing = indexByPath[path] {
        result[existing] = (path, component)
      } else {
        indexByPath[path] = result.count
        result.append((path, component))
      }
    }

    for comp in subCircuits {
      guard let subNetlist = subNetlist(of: comp.component) else { continue }
      let path = hierarchy + [Self.hierarchyName(of: comp)]
      for entry in subNetlist.mappableResources(hierarchy: path, isTopLevel: false) {
        put(entry.path, entry.component)
      }
    }
    for comp in normalComponents where comp.mapInformation != nil {
      put(hierarchy + [Self.hierarchyName(of: comp)], comp)
    }
    if isTopLevel {
      for comp in inputPorts { put(hierarchy + [Self.hierarchyName(of: comp)], comp) }
      for comp in inOutPorts { put(hierarchy + [Self.hierarchyName(of: comp)], comp) }
      for comp in outputPorts { put(hierarchy + [Self.hierarchyName(of: comp)], comp) }
    }
    return result
  }

  /// `Netlist.getPortInfo(String)`: the index of the named pin among the inputs, in-outs or
  /// outputs, or `-1`.
  public func portInfo(label: String) -> Int {
    let source = CorrectLabel.correctLabel(label)
    func search(_ list: [NetlistComponent]) -> Int? {
      for (index, port) in list.enumerated() {
        let portLabel = CorrectLabel.correctLabel(
          port.component.attributeSet.getValue(StdAttr.label) ?? "")
        if portLabel == source { return index }
      }
      return nil
    }
    if let index = search(inputPorts) { return index }
    if let index = search(inOutPorts) { return index }
    if let index = search(outputPorts) { return index }
    return -1
  }

  /// `Netlist.getInputPin(int)`.
  public func inputPin(at index: Int) -> NetlistComponent? {
    (index < 0 || index >= inputPorts.count) ? nil : inputPorts[index]
  }

  /// `Netlist.getOutputPin(int)`.
  public func outputPin(at index: Int) -> NetlistComponent? {
    (index < 0 || index >= outputPorts.count) ? nil : outputPorts[index]
  }

  /// `Netlist.isContinuesBus(netlistComponent, int)`: whether an end maps onto consecutive bits
  /// of one bus, and can therefore be written as a slice instead of bit by bit.
  public func isContinuesBus(_ comp: NetlistComponent, endIndex: Int) -> Bool {
    if endIndex < 0 || endIndex >= comp.nrOfEndsValue { return true }
    guard let connInfo = comp.connectionEnd(at: endIndex) else { return true }
    let nrOfBits = connInfo.nrOfBitsValue
    if nrOfBits == 1 { return true }
    guard let first = connInfo.connection(at: 0) else { return true }
    let connectedNet = first.net
    var connectedNetIndex = first.netBitIndex
    var continuesBus = true
    var i = 1
    while i < nrOfBits && continuesBus {
      guard let point = connInfo.connection(at: i) else { break }
      if connectedNet !== point.net { continuesBus = false }
      // Bug-for-bug: upstream increments `connectedNetIndex` only in the `else` branch, so a
      // net change alone does not stop the index walk (`Netlist.java:1523-1529`).
      if connectedNetIndex + 1 != point.netBitIndex {
        continuesBus = false
      } else {
        connectedNetIndex += 1
      }
      i += 1
    }
    return continuesBus
  }

  /// `Netlist.getNetlistConnectionForSubCircuit(String, int, byte)`.
  func netlistConnectionForSubCircuit(
    label: String, portIndex: Int, bitIndex: Int
  ) -> ConnectionPoint? {
    for search in subCircuits {
      let circuitLabel = CorrectLabel.correctLabel(
        search.component.attributeSet.getValue(StdAttr.label) ?? "")
      guard circuitLabel == label else { continue }
      for i in 0..<search.nrOfEndsValue {
        guard let thisEnd = search.connectionEnd(at: i), thisEnd.isOutput,
          bitIndex < thisEnd.nrOfBitsValue, let point = thisEnd.connection(at: bitIndex)
        else { continue }
        if point.childsPortIndex == portIndex { return point }
      }
    }
    return nil
  }

  // MARK: - Hidden sources and sinks

  /// `Netlist.hasHiddenSource(...)`; is this bit driven through a splitter chain?
  private func hasHiddenSource(
    fanoutNet: Net?, fanoutBitIndex: Int, combinedNet: Net, combinedBitIndex: Int,
    handledNets: inout Set<String>, ignoreSplitter: (any Component)?
  ) -> Bool {
    if let fanoutNet {
      let key = "\(netId(of: fanoutNet))-\(fanoutBitIndex)"
      if !handledNets.insert(key).inserted { return false }
    }
    let key = "\(netId(of: combinedNet))-\(combinedBitIndex)"
    if !handledNets.insert(key).inserted { return false }
    if combinedNet.hasBitSource(combinedBitIndex) { return true }

    for splitter in splitters {
      if let ignoreSplitter, splitter === ignoreSplitter { continue }
      let ends = splitter.ends
      for end in 0..<ends.count where combinedNet.contains(ends[end].location) {
        let bitEnd = Self.splitterBitEnd(splitter)
        if end == 0 {
          guard combinedBitIndex >= 0, combinedBitIndex < bitEnd.count else { continue }
          let splitterEnd = bitEnd[combinedBitIndex]
          guard splitterEnd >= 0, splitterEnd < ends.count else { continue }
          var netIndex = 0
          for index in 0..<combinedBitIndex where bitEnd[index] == splitterEnd { netIndex += 1 }
          var slaveNet: Net?
          for net in nets where net.contains(ends[splitterEnd].location) { slaveNet = net }
          if let slaveNet,
            hasHiddenSource(
              fanoutNet: nil, fanoutBitIndex: 0, combinedNet: slaveNet,
              combinedBitIndex: netIndex, handledNets: &handledNets, ignoreSplitter: splitter)
          {
            return true
          }
        } else {
          var rootIndices: [Int] = []
          for b in 0..<bitEnd.count where bitEnd[b] == end { rootIndices.append(b) }
          var rootNet: Net?
          for net in nets where net.contains(ends[0].location) { rootNet = net }
          guard let rootNet, combinedBitIndex >= 0, combinedBitIndex < rootIndices.count
          else { continue }
          if hasHiddenSource(
            fanoutNet: nil, fanoutBitIndex: 0, combinedNet: rootNet,
            combinedBitIndex: rootIndices[combinedBitIndex], handledNets: &handledNets,
            ignoreSplitter: splitter)
          {
            return true
          }
        }
      }
    }
    return false
  }

  /// `Netlist.getHiddenSinks(...)`; the sinks this bit reaches through splitter chains.
  private func hiddenSinks(
    net thisNet: Net, bitIndex: Int, handledNets: inout Set<String>, isSourceNet: Bool
  ) -> [ConnectionPoint] {
    var result: [ConnectionPoint] = []
    let key = "\(netId(of: thisNet))-\(bitIndex)"
    if !handledNets.insert(key).inserted { return result }

    if thisNet.hasBitSinks(bitIndex) && !isSourceNet && thisNet.isRootNet {
      result.append(contentsOf: thisNet.bitSinks(bitIndex))
    }
    for splitter in splitters {
      let ends = splitter.ends
      let bitEnd = Self.splitterBitEnd(splitter)
      for end in 0..<ends.count {
        if end > 0 && Self.isNoConnect(bitEnd, end: end) { continue }
        guard thisNet.contains(ends[end].location) else { continue }
        if end == 0 {
          guard bitIndex >= 0, bitIndex < bitEnd.count else { continue }
          let splitterEnd = bitEnd[bitIndex]
          guard splitterEnd >= 0, splitterEnd < ends.count else { continue }
          var netIndex = 0
          for index in 0..<bitIndex where bitEnd[index] == splitterEnd { netIndex += 1 }
          var slaveNet: Net?
          for net in nets where net.contains(ends[splitterEnd].location) { slaveNet = net }
          if let slaveNet {
            result.append(
              contentsOf: hiddenSinks(
                net: slaveNet, bitIndex: netIndex, handledNets: &handledNets,
                isSourceNet: false))
          }
        } else {
          var rootIndices: [Int] = []
          for b in 0..<bitEnd.count where bitEnd[b] == end { rootIndices.append(b) }
          var rootNet: Net?
          for net in nets where net.contains(ends[0].location) { rootNet = net }
          guard let rootNet, bitIndex >= 0, bitIndex < rootIndices.count else { continue }
          result.append(
            contentsOf: hiddenSinks(
              net: rootNet, bitIndex: rootIndices[bitIndex], handledNets: &handledNets,
              isSourceNet: false))
        }
      }
    }
    return result
  }

  // MARK: - Connectivity DRC

  /// `Netlist.netlistHasShortCircuits()`.
  ///
  /// The multi-driver half of upstream's check needs `getHiddenSource`'s full `SourceInfo`
  /// return to name the offending component in the GUI marking; here the *predicate* is the
  /// same, more than one hidden source on a single-bit net is a short, and the marking is
  /// dropped with the rest of `SimpleDrcContainer` (D9).
  public func hasShortCircuits() -> Bool {
    var result = false
    for net in nets where net.isRootNet {
      if net.hasShortCircuit {
        Reporter.shared.addError("Short circuit in circuit \"\(circuit.name)\"")
        result = true
      } else if net.bitWidth == 1 && net.sourceNets(0).count > 1 {
        var driverCount = 0
        for sourceNet in net.sourceNets(0) {
          guard let connectedNet = sourceNet.net else { continue }
          var handled: Set<String> = []
          if hasHiddenSource(
            fanoutNet: net, fanoutBitIndex: 0, combinedNet: connectedNet,
            combinedBitIndex: sourceNet.netBitIndex, handledNets: &handled, ignoreSplitter: nil)
          {
            driverCount += 1
          }
        }
        if driverCount > 1 {
          Reporter.shared.addError("Short circuit in circuit \"\(circuit.name)\"")
          result = true
        } else {
          net.cleanupSourceNets(0)
        }
      }
    }
    return result
  }

  /// `Netlist.netlistHasSinksWithoutSource()`; warnings only; upstream always returns `false`.
  @discardableResult
  public func reportSinksWithoutSource() -> Bool {
    for thisNet in nets where thisNet.isRootNet {
      for i in 0..<thisNet.bitWidth where thisNet.hasBitSource(i) {
        var hasSink = !thisNet.bitSinks(i).isEmpty
        var handled: Set<String> = []
        let hidden = hiddenSinks(
          net: thisNet, bitIndex: i, handledNets: &handled, isSourceNet: true)
        hasSink = hasSink || !hidden.isEmpty
        if !hasSink {
          Reporter.shared.addWarning(
            "Source without a sink in circuit \"\(circuit.name)\"")
        }
      }
    }
    return false
  }

  /// The four unconnected-pin warning loops at the end of `designRuleCheckResult`.
  private func reportUnconnectedPins() {
    func warnOpenInputs(_ list: [NetlistComponent], inputsOnly: Bool, message: String) {
      for comp in list {
        var open = false
        for j in 0..<comp.nrOfEndsValue {
          if inputsOnly {
            if comp.isEndInput(j) && !comp.isEndConnectedValue(j) { open = true }
          } else if !comp.isEndConnectedValue(j) {
            open = true
          }
        }
        if open {
          Reporter.shared.addWarning(
            "\(message) on \(comp.displayName) in circuit \"\(circuit.name)\"")
        }
      }
    }
    warnOpenInputs(normalComponents, inputsOnly: true, message: "Unconnected input(s)")
    warnOpenInputs(subCircuits, inputsOnly: true, message: "Unconnected input(s)")
    warnOpenInputs(inputPorts, inputsOnly: false, message: "Unconnected input pin")
    warnOpenInputs(outputPorts, inputsOnly: false, message: "Unconnected output pin")
  }

  // MARK: - Clock tree

  /// `Netlist.detectClockTree()`.
  @discardableResult
  public func detectClockTree() -> Bool {
    let clockSources = clockInformation.sourceContainer
    cleanClockTree(clockSources)
    return markClockSourceComponents(
      hierarchyNames: [], hierarchyNetlists: [self], clockSources: clockSources)
  }

  /// `Netlist.cleanClockTree(ClockSourceContainer)`.
  public func cleanClockTree(_ clockSources: ClockSourceContainer) {
    clockInformation.clean()
    clockInformation.setSourceContainer(clockSources)
    for sub in subCircuits {
      subNetlist(of: sub.component)?.cleanClockTree(clockSources)
    }
  }

  /// `Netlist.markClockSourceComponents(...)`.
  @discardableResult
  public func markClockSourceComponents(
    hierarchyNames: [String], hierarchyNetlists: [Netlist], clockSources: ClockSourceContainer
  ) -> Bool {
    for sub in subCircuits {
      guard let subNet = subNetlist(of: sub.component) else { continue }
      var newNames = hierarchyNames
      newNames.append(
        CorrectLabel.correctLabel(sub.component.attributeSet.getValue(StdAttr.label) ?? ""))
      var newNetlists = hierarchyNetlists
      newNetlists.append(subNet)
      if !subNet.markClockSourceComponents(
        hierarchyNames: newNames, hierarchyNetlists: newNetlists, clockSources: clockSources)
      {
        return false
      }
    }
    for component in circuit.nonWires where component.factory.requiresGlobalClock {
      clockSources.setRequiresFpgaGlobalClock()
    }
    for clockSource in clockGenerators {
      if clockSource.nrOfEndsValue != 1 {
        Reporter.shared.addFatalError("BUG: Found a clock source with more than 1 connection")
        return false
      }
      guard let clockConnection = clockSource.connectionEnd(at: 0) else { return false }
      if clockConnection.nrOfBitsValue != 1 {
        Reporter.shared.addFatalError("BUG: Found a clock source with a bus as output")
        return false
      }
      guard let solderPoint = clockConnection.connection(at: 0) else { return false }
      guard let parentNet = solderPoint.net else { continue }
      let clockId = clockSources.clockId(for: clockSource.component)
      if clockId < 0 { continue }
      clockInformation.addClockSource(
        hierarchyNames: hierarchyNames, clockSourceId: clockId, connection: solderPoint)
      if !traceClockNet(
        clockNet: parentNet, clockNetBitIndex: solderPoint.netBitIndex, clockSourceId: clockId,
        isPinSource: false, hierarchyNames: hierarchyNames, hierarchyNetlists: hierarchyNetlists)
      {
        return false
      }
    }
    return true
  }

  /// `Netlist.markClockNet(...)`.
  public func markClockNet(
    hierarchyNames: [String], clockSourceId: Int, connection: ConnectionPoint,
    isPinClockSource: Bool
  ) {
    clockInformation.addClockNet(
      hierarchyNames: hierarchyNames, clockSourceId: clockSourceId, connection: connection,
      isPinClock: isPinClockSource)
  }

  /// `Netlist.traceClockNet(...)`.
  @discardableResult
  public func traceClockNet(
    clockNet: Net, clockNetBitIndex: Int, clockSourceId: Int, isPinSource: Bool,
    hierarchyNames: [String], hierarchyNetlists: [Netlist]
  ) -> Bool {
    var handled: Set<String> = []
    let hiddenComps = hiddenSinks(
      net: clockNet, bitIndex: clockNetBitIndex, handledNets: &handled, isSourceNet: false)
    for point in hiddenComps {
      markClockNet(
        hierarchyNames: hierarchyNames, clockSourceId: clockSourceId, connection: point,
        isPinClockSource: isPinSource)
      guard let component = point.component else { continue }
      if component.factory is any SubcircuitFactory {
        if !traceDownSubcircuit(
          point: point, clockSourceId: clockSourceId, hierarchyNames: hierarchyNames,
          hierarchyNetlists: hierarchyNetlists)
        {
          return false
        }
      }
      if hierarchyNames.isEmpty { continue }
      guard component.factory.isPin else { continue }
      guard let outputPort = outPort(for: component) else {
        Reporter.shared.addFatalError("BUG: Could not find an output port!")
        return false
      }
      guard let parentNet = point.net else { continue }
      let bitIndex = outputPort.connectionBitIndex(
        rootNet: parentNet, bitIndex: point.netBitIndex)
      guard hierarchyNetlists.count >= 2, let parentIndex = outputPorts.firstIndex(
        where: { $0 === outputPort })
      else {
        Reporter.shared.addFatalError(
          "BUG: Could not find a sub-circuit connection in overlying hierarchy level!")
        return false
      }
      let parentNetlist = hierarchyNetlists[hierarchyNetlists.count - 2]
      guard let subClockNet = parentNetlist.netlistConnectionForSubCircuit(
        label: hierarchyNames[hierarchyNames.count - 1], portIndex: parentIndex,
        bitIndex: bitIndex)
      else {
        Reporter.shared.addFatalError(
          "BUG: Could not find a sub-circuit connection in overlying hierarchy level!")
        return false
      }
      guard let subClockParent = subClockNet.net else { continue }
      var newNames = hierarchyNames
      newNames.removeLast()
      var newNetlists = hierarchyNetlists
      newNetlists.removeLast()
      parentNetlist.markClockNet(
        hierarchyNames: newNames, clockSourceId: clockSourceId, connection: subClockNet,
        isPinClockSource: true)
      if !parentNetlist.traceClockNet(
        clockNet: subClockParent, clockNetBitIndex: subClockNet.netBitIndex,
        clockSourceId: clockSourceId, isPinSource: true, hierarchyNames: newNames,
        hierarchyNetlists: newNetlists)
      {
        return false
      }
    }
    return true
  }

  /// `Netlist.traceDownSubcircuit(...)`.
  private func traceDownSubcircuit(
    point: ConnectionPoint, clockSourceId: Int, hierarchyNames: [String],
    hierarchyNetlists: [Netlist]
  ) -> Bool {
    if point.childsPortIndex < 0 {
      Reporter.shared.addFatalError("BUG: Subcircuit port is not annotated!")
      return false
    }
    guard let component = point.component, let subNet = subNetlist(of: component) else {
      Reporter.shared.addFatalError("BUG: Unable to find Subcircuit!")
      return false
    }
    guard let inputPort = subNet.inputPin(at: point.childsPortIndex) else {
      Reporter.shared.addFatalError("BUG: Unable to find Subcircuit input port!")
      return false
    }
    guard let subCirc = subCircuits.first(where: { $0.component === component }) else {
      Reporter.shared.addFatalError("BUG: Unable to find Subcircuit!")
      return false
    }
    guard let parentNet = point.net else { return true }
    let bitIndex = subCirc.connectionBitIndex(rootNet: parentNet, bitIndex: point.netBitIndex)
    if bitIndex < 0 {
      Reporter.shared.addFatalError(
        "BUG: Unable to find the bit index of a Subcircuit input port!")
      return false
    }
    guard let end = inputPort.connectionEnd(at: 0),
      let subClockNet = end.connection(at: bitIndex)
    else { return true }
    guard let subClockParent = subClockNet.net else { return true }
    var newNames = hierarchyNames
    newNames.append(
      CorrectLabel.correctLabel(subCirc.component.attributeSet.getValue(StdAttr.label) ?? ""))
    var newNetlists = hierarchyNetlists
    newNetlists.append(subNet)
    subNet.markClockNet(
      hierarchyNames: newNames, clockSourceId: clockSourceId, connection: subClockNet,
      isPinClockSource: true)
    return subNet.traceClockNet(
      clockNet: subClockParent, clockNetBitIndex: subClockNet.netBitIndex,
      clockSourceId: clockSourceId, isPinSource: true, hierarchyNames: newNames,
      hierarchyNetlists: newNetlists)
  }

  /// `Netlist.getOutPort(Component)`.
  private func outPort(for component: any Component) -> NetlistComponent? {
    outputPorts.first { $0.component === component }
  }

  // MARK: - Splitter helpers

  /// `comp.getFactory() instanceof SplitterFactory`, answered through
  /// `LogisimKernel.WireComponentRole` rather than by naming `LogisimStd.Splitter`.
  private static func isSplitter(_ component: any Component) -> Bool {
    (component as? any WireComponent)?.wireRole == .splitter
  }

  /// `((Splitter) comp).getEndpoints()`: for each bit of end 0, which end it routes to.
  private static func splitterBitEnd(_ component: any Component) -> [Int] {
    (component as? any WireSplitterComponent)?.splitterBitEnd ?? []
  }

  /// `((SplitterAttributes) attrs).isNoConnect(index)`: no bit routes to this end.
  private static func isNoConnect(_ bitEnd: [Int], end: Int) -> Bool {
    !bitEnd.contains(end)
  }

  // MARK: - Java hashes

  /// `Location.hashCode()`: `31 * x + y`, in Java `int` arithmetic.
  static func javaHashCode(of location: Location) -> Int {
    wrap32(wrap32(31 &* location.x) &+ location.y)
  }

  /// `Wire.hashCode()`, `e0.hashCode() * 31 + e1.hashCode()`.
  static func javaHashCode(of wire: Wire) -> Int {
    wrap32(wrap32(javaHashCode(of: wire.end0) &* 31) &+ javaHashCode(of: wire.end1))
  }
}

// MARK: - HdlNetlist

extension Netlist: HdlNetlist {

  /// `Netlist.getNetId(Net)`.
  public func netId(for net: any HdlNet) -> Int {
    guard let concrete = net as? Net else { return -1 }
    return netId(of: concrete)
  }

  public func isContinuesBus(_ component: any HdlNetlistComponent, endIndex: Int) -> Bool {
    guard let concrete = component as? NetlistComponent else { return true }
    return isContinuesBus(concrete, endIndex: endIndex)
  }

  /// `Netlist.getCurrentHierarchyLevel()`.
  ///
  /// The protocol types this `Optional` to distinguish "never set". Upstream's field is an empty
  /// `ArrayList` until `setCurrentHierarchyLevel` runs, and `Hdl.getClockNetName` is the only
  /// reader; it passes the list straight to `getClockSourceId`, which answers `-1` for an
  /// unknown hierarchy either way. So an empty level and a `nil` level produce identical text;
  /// the empty list is reported as-is rather than inventing a distinction upstream lacks.
  public var currentHierarchyLevel: [String]? { hierarchyLevel }

  public func clockSourceId(hierarchyLevel: [String], net: any HdlNet, bitIndex: Int) -> Int {
    guard let concrete = net as? Net else { return -1 }
    return clockInformation.clockSourceId(
      hierarchy: hierarchyLevel, net: concrete, bitIndex: bitIndex)
  }

  /// `Netlist.getClockSourceId(Component)` (`Netlist.java:1113-1115`):
  /// `myClockInformation.getClockSourceId(comp)`, a different lookup from the net-keyed overload
  /// above. `ClockTreeFactory.clockSourceId(for:)` was already ported; only this forwarding
  /// method and the protocol requirement were missing, so nothing could reach it.
  ///
  /// A `netlistComponent` this netlist did not build is not an error upstream either: the
  /// container simply finds no matching source and answers `-1`.
  public func clockSourceId(for component: any HdlNetlistComponent) -> Int {
    guard let concrete = component as? NetlistComponent else { return -1 }
    return clockInformation.clockSourceId(for: concrete.component)
  }

  /// `Netlist.getCircuitName()`.
  public var circuitName: String {
    circuitNameStorage.isEmpty ? circuit.name : circuitNameStorage
  }

  /// `Netlist.projName()`.
  public var projName: String { circuit.projectName }

  /// `Netlist.requiresGlobalClockConnection()`.
  public var requiresGlobalClockConnection: Bool {
    clockInformation.sourceContainer.requiresFpgaGlobalClock
  }
}

// NOT PORTED, by Java member (`fpga/designrulecheck/Netlist.java`):
//
//   * `getMappableResources` / `getInOutPin` / `getInOutPort` / `getInputPort`; the accessors
//     that hand the bubble tree to `MappableResourcesContainer`. `constructHierarchyTree` and
//     `enumerateGlobalBubbleTree` **are** now ported (see "FPGA bubble hierarchy" above), and
//     `localNrOfInportBubbles` and its two siblings therefore carry real counts; what is still
//     missing above them is `MapComponent`, which is what `getMappableResources` returns a map
//     of. See `Fpga/FpgaNotPorted.swift` for that ledger.
//   * `detectGatedClocks` / `getGatedClockComponents` / `hasGatedClock` /
//     `warningTraceForGatedClock` / `warningForGatedClock` / `getEntryIndex` /
//     `netlistComponent.setIsGatedInstance` callers; ~420 lines whose entire product is
//     `Reporter` warnings plus `SimpleDrcContainer` GUI marking, and which additionally need
//     `MapComponent`/`FpgaIoInformationContainer`. `isGatedInstance` is kept on
//     `NetlistComponent` (the `HdlNetlistComponent` protocol reads it) and stays `false`; the
//     only generator that consults it, upstream's flip-flop family, is not ported either.
//   * `isFlipFlop(AttributeSet)`; reads `StdAttr.TRIGGER`/`Memory` factories in `LogisimStd`
//     and is used only by the gated-clock detector above.
//   * `SimpleDrcContainer` and the `Color` constants (`DRC_INSTANCE_MARK_COLOR` &c.): Swing
//     component highlighting, D9. Every DRC *finding* above still reaches `Reporter`; only the
//     "which shapes to paint red" payload is dropped.
//   * `getHiddenSource`'s `SourceInfo` return: see `hasShortCircuits()`.
//   * `getAllNets` / `getSplitters` / `getAllClockSources` / `getClockSources` /
//     `getEndIndex` / `getNetlistConnectionForSubCircuitInput`; accessors with no in-tree
//     caller once the two subsystems above are out. `nets`, `subCircuits`, `normalComponents`,
//     `inputPorts` and `outputPorts` are public here, so a later port needs no new surface.
