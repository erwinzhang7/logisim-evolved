// ClockTree: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// `com/cburch/logisim/fpga/designrulecheck/{ClockSourceContainer,ClockTreeContainer,
// ClockTreeFactory}.java`. Copyright by the Logisim-evolution developers. This translation is a
// derivative work and is therefore licensed GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).

import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.fpga.designrulecheck.ClockSourceContainer`: the distinct clock
/// *shapes* in a design. Two `Clock` components with identical phase/high/low durations share
/// one clock id and therefore one clock tree.
public final class ClockSourceContainer {

  /// `ClockSourceContainer.sources`.
  public private(set) var sources: [any Component] = []

  /// `ClockSourceContainer.requiresFpgaGlobalClock`.
  public private(set) var requiresFpgaGlobalClock = false

  public init() {}

  /// `ClockSourceContainer.clear()`.
  public func clear() {
    sources.removeAll()
    requiresFpgaGlobalClock = false
  }

  /// The three `Clock` attributes upstream compares, by their `.circ` names.
  ///
  /// **Seam.** `ClockSourceContainer.equals` reads `Clock.ATTR_PHASE`/`ATTR_HIGH`/`ATTR_LOW`
  /// directly. `Clock` lives in `LogisimStd`, which this module must not depend on (see
  /// `HdlGeneratorLookup.swift`), so the attributes are looked up by name; the same names the
  /// XML carries and that `Clock.swift` declares (`phaseOffset`, `highDuration`,
  /// `lowDuration`). Comparing the stored `AttributeValue`s is exact: `AttributeValue` is
  /// `Hashable` and a duration is stored as one integer case.
  private static let clockShapeAttributes = ["phaseOffset", "highDuration", "lowDuration"]

  /// `ClockSourceContainer.equals(Component, Component)`.
  private static func sameClockShape(_ a: any Component, _ b: any Component) -> Bool {
    for name in clockShapeAttributes {
      let lhs = a.attributeSet.attribute(named: name).flatMap { a.attributeSet.rawValue($0) }
      let rhs = b.attributeSet.attribute(named: name).flatMap { b.attributeSet.rawValue($0) }
      if lhs != rhs { return false }
    }
    return true
  }

  /// `ClockSourceContainer.getClockId(Component)`; registers the component if its shape is new.
  /// `-1` for a non-clock, exactly as upstream.
  @discardableResult
  public func clockId(for component: any Component) -> Int {
    guard NetlistFactoryNames.isClock(component.factory) else { return -1 }
    for (index, clock) in sources.enumerated() where Self.sameClockShape(component, clock) {
      return index
    }
    sources.append(component)
    return sources.count - 1
  }

  /// `ClockSourceContainer.getNrofSources()`.
  public var nrOfSources: Int { sources.count }

  /// `ClockSourceContainer.setRequiresFpgaGlobalClock()`.
  public func setRequiresFpgaGlobalClock() { requiresFpgaGlobalClock = true }
}

/// `com.cburch.logisim.fpga.designrulecheck.ClockTreeContainer`; every solder point one clock
/// id reaches at one hierarchy level.
public final class ClockTreeContainer {

  private var clockSources: [ConnectionPoint] = []
  private var clockNets: [ConnectionPoint] = []
  private let clockSourceId: Int
  private let hierarchyId: [String]

  /// `ClockTreeContainer.isPinClockSource`.
  public private(set) var isPinClockSource: Bool

  public init(hierarchy: [String], sourceId: Int, pinClockSource: Bool) {
    self.clockSourceId = sourceId
    self.hierarchyId = hierarchy
    self.isPinClockSource = pinClockSource
  }

  func addNet(_ netInfo: ConnectionPoint) { clockNets.append(netInfo) }
  func addSource(_ netInfo: ConnectionPoint) { clockSources.append(netInfo) }

  func clear() {
    clockSources.removeAll()
    clockNets.removeAll()
  }

  func setPinClock() { isPinClockSource = true }

  /// `ClockTreeContainer.equals(List<String>, int)`.
  func matches(hierarchy: [String], sourceId: Int) -> Bool {
    sourceId == clockSourceId && hierarchyId == hierarchy
  }

  /// `ClockTreeContainer.getClockEntries(Net)`.
  ///
  /// Java compares with `ConnectionPoint.getParentNet().equals(netInfo)`; `Net` overrides
  /// neither `equals` nor `hashCode`, so that is identity, `===` here.
  func clockEntries(for net: Net) -> [Int] {
    var result: [Int] = []
    for point in clockSources where point.net === net { result.append(point.netBitIndex) }
    for point in clockNets where point.net === net { result.append(point.netBitIndex) }
    return result
  }

  /// `ClockTreeContainer.netContainsClockConnection(Net)`.
  public func containsClockConnection(_ net: Net) -> Bool {
    clockSources.contains { $0.net === net } || clockNets.contains { $0.net === net }
  }

  /// `ClockTreeContainer.netContainsClockSource(Net)`.
  public func containsClockSource(_ net: Net) -> Bool {
    clockSources.contains { $0.net === net }
  }
}

/// `com.cburch.logisim.fpga.designrulecheck.ClockTreeFactory`.
public final class ClockTreeFactory {

  private var sources: ClockSourceContainer?
  private var sourceTrees: [ClockTreeContainer] = []

  public init() {}

  private func tree(hierarchy: [String], sourceId: Int) -> ClockTreeContainer? {
    // Java keeps scanning after a hit and uses the *last* match. There can only be one, since
    // every insertion path looks the key up first, but the traversal is preserved anyway.
    var found: ClockTreeContainer?
    for candidate in sourceTrees where candidate.matches(hierarchy: hierarchy, sourceId: sourceId) {
      found = candidate
    }
    return found
  }

  /// `ClockTreeFactory.addClockNet(...)`.
  func addClockNet(
    hierarchyNames: [String], clockSourceId: Int, connection: ConnectionPoint, isPinClock: Bool
  ) {
    let destination: ClockTreeContainer
    if let existing = tree(hierarchy: hierarchyNames, sourceId: clockSourceId) {
      if !existing.isPinClockSource && isPinClock { existing.setPinClock() }
      destination = existing
    } else {
      destination = ClockTreeContainer(
        hierarchy: hierarchyNames, sourceId: clockSourceId, pinClockSource: isPinClock)
      sourceTrees.append(destination)
    }
    destination.addNet(connection)
  }

  /// `ClockTreeFactory.addClockSource(...)`.
  func addClockSource(
    hierarchyNames: [String], clockSourceId: Int, connection: ConnectionPoint
  ) {
    let destination: ClockTreeContainer
    if let existing = tree(hierarchy: hierarchyNames, sourceId: clockSourceId) {
      destination = existing
    } else {
      destination = ClockTreeContainer(
        hierarchy: hierarchyNames, sourceId: clockSourceId, pinClockSource: false)
      sourceTrees.append(destination)
    }
    destination.addSource(connection)
  }

  /// `ClockTreeFactory.clean()`.
  func clean() {
    for tree in sourceTrees { tree.clear() }
    sourceTrees.removeAll()
    sources?.clear()
  }

  /// `ClockTreeFactory.getClockSourceId(List<String>, Net, byte)`. `-1` when no tree matches.
  public func clockSourceId(hierarchy: [String], net: Net, bitIndex: Int) -> Int {
    guard let sources else { return -1 }
    for i in 0..<sources.nrOfSources {
      for clockNet in sourceTrees where clockNet.matches(hierarchy: hierarchy, sourceId: i) {
        if clockNet.clockEntries(for: net).contains(bitIndex) { return i }
      }
    }
    return -1
  }

  /// `ClockTreeFactory.getClockSourceId(Component)`.
  public func clockSourceId(for component: any Component) -> Int {
    guard let sources else { return -1 }
    return sources.clockId(for: component)
  }

  /// `ClockTreeFactory.getSourceContainer()`: creates one on first use, as Java does.
  public var sourceContainer: ClockSourceContainer {
    if let sources { return sources }
    let container = ClockSourceContainer()
    sources = container
    return container
  }

  /// `ClockTreeFactory.setSourceContainer(ClockSourceContainer)`.
  func setSourceContainer(_ container: ClockSourceContainer) { sources = container }
}
