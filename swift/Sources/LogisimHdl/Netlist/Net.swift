// Net: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// `com/cburch/logisim/fpga/designrulecheck/Net.java`. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore licensed GPL-3.0-only.
// See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// This is the concrete type behind `HdlNet`: see `HdlNetlist.swift`, whose header explained
// that the protocols were placeholders "until a future `designrulecheck` port makes its
// concrete `Netlist`/`NetlistComponent` conform to these". That port is this directory.
//
// ── Deliberate departures ───────────────────────────────────────────────────────────────────
//
//   * Java's `Byte`/`byte` bit indices are `Int` here. Every one of them is bounded by a
//     `BitWidth` (1...64 by construction), so the narrower type carries no information; keeping
//     `Int8` would only add conversions at every call site. Java's `-1`-as-"not found"
//     sentinels are preserved where a caller tests for them (`bit(_:)`), and turned into
//     `Optional` only where no caller does.
//   * `Net` is a `final class` and is compared by **identity**. Java's `Net` overrides neither
//     `equals` nor `hashCode`, so `ArrayList.indexOf` and `HashSet` already key it by identity
//     there; `getNetId(net)` therefore means "index of this exact object".

import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.fpga.designrulecheck.Net`.
public final class Net {

  /// `Net.myPoints`.
  public private(set) var points: Set<Location> = []

  /// `Net.tunnelNames`.
  private(set) var tunnelNames: Set<String> = []

  /// `Net.segments`. Java's is a `HashSet<Wire>`, and `Wire` is value-equal on both sides
  /// (`e0`/`e1`), so a Swift `Set<Wire>` has identical membership semantics. Only DRC marking
  /// reads it, and that ignores order.
  private(set) var segments: Set<Wire> = []

  /// `Net.nrOfBits`.
  private(set) var nrOfBits: Int = 0

  /// `Net.myParent`.
  private(set) var parent: Net?

  /// `Net.requiresToBeRoot`.
  private(set) var requiresToBeRoot: Bool = false

  /// `Net.inheritedBits`.
  private var inheritedBits: [Int] = []

  private var sourceList: [[ConnectionPoint]] = []
  private var sinkList: [[ConnectionPoint]] = []
  private var sourceNetsList: [[ConnectionPoint]] = []
  private var sinkNetsList: [[ConnectionPoint]] = []

  /// `Net()`.
  public init() {}

  /// `Net(Location)`.
  public init(location: Location) {
    points.insert(location)
  }

  /// `Net(Location, int)`.
  public init(location: Location, width: Int) {
    points.insert(location)
    nrOfBits = width
  }

  // MARK: - Structure

  /// `Net.add(Wire)`.
  func add(_ segment: Wire) {
    points.insert(segment.end0)
    points.insert(segment.end1)
    segments.insert(segment)
  }

  /// `Net.getWires()`.
  public var wires: Set<Wire> { segments }

  /// `Net.addParentBit(byte)`. Returns `false` for a negative index, exactly as Java does.
  @discardableResult
  func addParentBit(_ bitId: Int) -> Bool {
    if bitId < 0 { return false }
    inheritedBits.append(bitId)
    return true
  }

  /// `Net.addTunnel(String)`.
  func addTunnel(_ tunnelName: String) {
    tunnelNames.insert(tunnelName)
  }

  /// `Net.getBitWidth()`.
  public var bitWidth: Int { nrOfBits }

  /// `Net.contains(Location)`.
  public func contains(_ point: Location) -> Bool { points.contains(point) }

  /// `Net.containsTunnel(String)`.
  public func containsTunnel(_ tunnelName: String) -> Bool { tunnelNames.contains(tunnelName) }

  /// `Net.forceRootNet()`.
  func forceRootNet() {
    parent = nil
    requiresToBeRoot = true
    inheritedBits.removeAll()
  }

  /// `Net.getBit(byte)`: the parent-net bit this net's `bit` inherits from, or `-1` when the
  /// index is out of range or this net is already a root.
  func bit(_ bit: Int) -> Int {
    if bit < 0 || bit >= inheritedBits.count || isRootNet { return -1 }
    return inheritedBits[bit]
  }

  /// `Net.isBus()`.
  public var isBus: Bool { nrOfBits > 1 }

  /// `Net.isEmpty()`.
  public var isEmpty: Bool { points.isEmpty }

  /// `Net.isForcedRootNet()`.
  public var isForcedRootNet: Bool { requiresToBeRoot }

  /// `Net.isRootNet()`.
  public var isRootNet: Bool { parent == nil || requiresToBeRoot }

  /// `Net.merge(Net)`; folds `other` into this one. Returns `false`, changing nothing, when the
  /// widths disagree; the caller turns that into a DRC error.
  @discardableResult
  func merge(_ other: Net) -> Bool {
    guard other.bitWidth == nrOfBits else { return false }
    points.formUnion(other.points)
    segments.formUnion(other.segments)
    tunnelNames.formUnion(other.tunnelNames)
    return true
  }

  /// `Net.setWidth(int)`; returns `false` when this net already has a *different* width, which
  /// is upstream's bit-width-mismatch DRC signal.
  @discardableResult
  func setWidth(_ width: Int) -> Bool {
    if nrOfBits > 0 && width != nrOfBits { return false }
    nrOfBits = width
    return true
  }

  /// `Net.setParent(Net)`. Refuses when this net is pinned as a root or already has a parent.
  @discardableResult
  func setParent(_ newParent: Net?) -> Bool {
    if requiresToBeRoot { return false }
    guard let newParent else { return false }
    if parent != nil { return false }
    parent = newParent
    return true
  }

  // MARK: - Sources and sinks

  /// `Net.initializeSourceSinks()`.
  func initializeSourceSinks() {
    let empty = [[ConnectionPoint]](repeating: [], count: max(0, nrOfBits))
    sourceList = empty
    sinkList = empty
    sourceNetsList = empty
    sinkNetsList = empty
  }

  @discardableResult
  func addSink(_ bitIndex: Int, _ sink: ConnectionPoint) -> Bool {
    guard bitIndex >= 0, bitIndex < sinkList.count else { return false }
    sinkList[bitIndex].append(sink)
    return true
  }

  @discardableResult
  func addSource(_ bitIndex: Int, _ source: ConnectionPoint) -> Bool {
    guard bitIndex >= 0, bitIndex < sourceList.count else { return false }
    sourceList[bitIndex].append(source)
    return true
  }

  @discardableResult
  func addSinkNet(_ bitIndex: Int, _ sinkNet: ConnectionPoint) -> Bool {
    guard bitIndex >= 0, bitIndex < sinkNetsList.count else { return false }
    sinkNetsList[bitIndex].append(sinkNet)
    return true
  }

  @discardableResult
  func addSourceNet(_ bitIndex: Int, _ sourceNet: ConnectionPoint) -> Bool {
    guard bitIndex >= 0, bitIndex < sourceNetsList.count else { return false }
    sourceNetsList[bitIndex].append(sourceNet)
    return true
  }

  /// `Net.getSinkNets(int)`.
  func sinkNets(_ bitIndex: Int) -> [ConnectionPoint] {
    guard bitIndex >= 0, bitIndex < sinkNetsList.count else { return [] }
    return sinkNetsList[bitIndex]
  }

  /// `Net.getSourceNets(int)`.
  func sourceNets(_ bitIndex: Int) -> [ConnectionPoint] {
    guard bitIndex >= 0, bitIndex < sourceNetsList.count else { return [] }
    return sourceNetsList[bitIndex]
  }

  /// `Net.hasBitSinks(int)`.
  func hasBitSinks(_ bitId: Int) -> Bool {
    (bitId < 0 || bitId >= sinkList.count) ? false : !sinkList[bitId].isEmpty
  }

  /// `Net.getBitSinks(int)`.
  ///
  /// Bug-for-bug: upstream range-checks `bitIndex` against `sourceNetsList` and then indexes
  /// `sinkList` (`Net.java:157-160`). The four lists are always allocated together in
  /// `initializeSourceSinks`, so the mismatched guard is harmless, but it is reproduced rather
  /// than "fixed", since a fix could only change behaviour if the invariant were already broken.
  func bitSinks(_ bitIndex: Int) -> [ConnectionPoint] {
    guard bitIndex >= 0, bitIndex < sourceNetsList.count else { return [] }
    return sinkList[bitIndex]
  }

  /// `Net.getBitSources(int)`; `nil` mirrors Java's `null` return for an out-of-range index
  /// (note it returns an empty list nowhere; the sole caller checks `hasBitSource` first).
  func bitSources(_ bitIndex: Int) -> [ConnectionPoint]? {
    guard bitIndex >= 0, bitIndex < sourceNetsList.count else { return nil }
    return sourceList[bitIndex]
  }

  /// `Net.hasBitSource(int)`.
  func hasBitSource(_ bitId: Int) -> Bool {
    (bitId < 0 || bitId >= sourceList.count) ? false : !sourceList[bitId].isEmpty
  }

  /// `Net.hasShortCircuit()`: any bit driven by more than one source.
  public var hasShortCircuit: Bool {
    for i in 0..<nrOfBits where i < sourceList.count && sourceList[i].count > 1 { return true }
    return false
  }

  /// `Net.hasSinks()`.
  public var hasSinks: Bool {
    for i in 0..<nrOfBits where i < sinkList.count && !sinkList[i].isEmpty { return true }
    return false
  }

  /// `Net.hasSource()`.
  public var hasSource: Bool {
    for i in 0..<nrOfBits where i < sourceList.count && !sourceList[i].isEmpty { return true }
    return false
  }

  /// `Net.hasTunnel()`.
  public var hasTunnel: Bool { !tunnelNames.isEmpty }

  /// `Net.cleanupSourceNets(int)`.
  func cleanupSourceNets(_ bitIndex: Int) {
    guard bitIndex >= 0, bitIndex < sourceNetsList.count else { return }
    if sourceNetsList[bitIndex].count > 1 {
      sourceNetsList[bitIndex] = [sourceNetsList[bitIndex][0]]
    }
  }
}

// MARK: - HdlNet

extension Net: HdlNet {}

// NOT PORTED: `Net.getSinks()`; returns a `HashSet<ConnectionPoint>` used only by
// `Netlist.netlistHasSinksWithoutSource`'s GUI marking, which needs `SimpleDrcContainer`'s
// Swing component-highlighting. The DRC *predicate* is ported (`Netlist.hasSinksWithoutSource`);
// the set of things to highlight is not, per D9.
