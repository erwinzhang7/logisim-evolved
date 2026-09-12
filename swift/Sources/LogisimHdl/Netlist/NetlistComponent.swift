// NetlistComponent: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// `com/cburch/logisim/fpga/designrulecheck/{netlistComponent,BubbleInformationContainer}.java`.
// Copyright by the Logisim-evolution developers. This translation is a derivative work and is
// therefore licensed GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// Named `NetlistComponent`: Swift convention, and the name `HdlNetlist.swift` already
// anticipated.

import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.fpga.designrulecheck.BubbleInformationContainer`: the range of global
/// I/O "bubble" indices a component or subcircuit occupies.
///
/// **Java's six `int` fields have no initialiser, so they default to `0`, not to `-1`.** An
/// earlier version of this header said `-1`, which is the natural guess and is wrong; it matters
/// because `MapComponent` reads `getInputStartIndex()` off a container whose *input* range was
/// never set, a component with only output bubbles, and gets Java's `0`. Verified against the
/// jar: `tools/hdlbridge/netlist-4.1.0.oracle` shows an `LED` with `local=0..0,1..1,0..0`, where
/// the leading `0..0` is exactly this unset-means-zero and the `1..1` is the real output range.
///
/// So the port keeps `nil` ranges and every *index* accessor answers `0` when absent, which is
/// what upstream's uninitialised field answers.
///
/// `hasInputBubbles()` / `nrOfInputBubbles()` and their siblings are deliberately **not** ported.
/// They are dead upstream, nothing outside `BubbleInformationContainer` calls any of the six,
/// and they are dead *wrongly*: on a default-constructed container `hasInputBubbles()` is `true`
/// and `nrOfInputBubbles()` is `1`, because `(0 - 0) + 1 == 1`. Reproducing that would encode a
/// bug nothing reads; answering `0` instead would silently disagree with the Java. Omitting them
/// is the only option that is not a lie.
public struct BubbleInformationContainer: Equatable, Sendable {
  public var inputRange: ClosedRange<Int>?
  public var outputRange: ClosedRange<Int>?
  public var inOutRange: ClosedRange<Int>?

  public init() {}

  public mutating func setInputBubbles(start: Int, end: Int) {
    inputRange = start <= end ? start...end : nil
  }
  public mutating func setOutputBubbles(start: Int, end: Int) {
    outputRange = start <= end ? start...end : nil
  }
  public mutating func setInOutBubbles(start: Int, end: Int) {
    inOutRange = start <= end ? start...end : nil
  }

  /// `getInputStartIndex()` / `getInputEndIndex()` and their four siblings.
  public var inputStartIndex: Int { inputRange?.lowerBound ?? 0 }
  public var inputEndIndex: Int { inputRange?.upperBound ?? 0 }
  public var outputStartIndex: Int { outputRange?.lowerBound ?? 0 }
  public var outputEndIndex: Int { outputRange?.upperBound ?? 0 }
  public var inOutStartIndex: Int { inOutRange?.lowerBound ?? 0 }
  public var inOutEndIndex: Int { inOutRange?.upperBound ?? 0 }
}

/// `com.cburch.logisim.fpga.designrulecheck.netlistComponent`; a placed component together with
/// the per-pin connection information the HDL layer reads.
public final class NetlistComponent {

  /// `netlistComponent.compReference`.
  public let component: any Component

  /// `netlistComponent.endEnds`.
  private var endEnds: [ConnectionEnd]

  /// `netlistComponent.globalIds`, keyed by hierarchy path.
  private var globalIds: [[String]: BubbleInformationContainer] = [:]

  /// `netlistComponent.localId`.
  private var localId: BubbleInformationContainer?

  /// `netlistComponent.isGatedInstance`.
  public private(set) var isGated: Bool = false

  /// `netlistComponent.myMapInformation`: how many board-facing bubbles this component
  /// contributes, and what each is called.
  ///
  /// Upstream reads it out of `StdAttr.MAPINFO` (or derives it for a `Pin`) and **clones** it, so
  /// that `constructHierarchyTree`'s consumers cannot mutate the live component's copy. The port
  /// gets both branches from `HdlGeneratorLookup.mapInformation(for:)`, which is where the
  /// module-boundary argument lives; the clone happens there.
  public let mapInformation: ComponentMapInformationContainer?

  /// `netlistComponent(Component)`.
  public init(component: any Component) {
    self.component = component
    self.endEnds = component.ends.map { end in
      ConnectionEnd(
        isOutputEnd: end.isOutput, nrOfBits: end.width.width, component: component)
    }
    self.mapInformation = HdlGeneratorLookup.shared.mapInformation(for: component)
  }

  // MARK: - Ends

  /// `netlistComponent.nrOfEnds()`.
  public var nrOfEndsValue: Int { endEnds.count }

  /// `netlistComponent.getEnd(int)`: `nil` out of range, matching Java's `null`.
  public func connectionEnd(at index: Int) -> ConnectionEnd? {
    guard index >= 0, index < endEnds.count else { return nil }
    return endEnds[index]
  }

  /// `netlistComponent.setEnd(int, ConnectionEnd)`.
  @discardableResult
  func setEnd(_ index: Int, _ end: ConnectionEnd) -> Bool {
    guard index >= 0, index < endEnds.count else { return false }
    endEnds[index] = end
    return true
  }

  /// `netlistComponent.isEndConnected(int)`.
  public func isEndConnectedValue(_ index: Int) -> Bool {
    guard let end = connectionEnd(at: index) else { return false }
    for bit in 0..<end.nrOfBitsValue where end.connection(at: bit)?.net != nil { return true }
    return false
  }

  /// `netlistComponent.isEndInput(int)`.
  public func isEndInput(_ index: Int) -> Bool {
    guard index >= 0, index < endEnds.count else { return false }
    return component.end(at: index).isInput
  }

  /// `netlistComponent.getConnectionBitIndex(Net, byte)`, which bit of which end solders to
  /// `rootNet` bit `bitIndex`. `-1` when none does, exactly as upstream.
  public func connectionBitIndex(rootNet: Net, bitIndex: Int) -> Int {
    for end in endEnds {
      for bit in 0..<end.nrOfBitsValue {
        guard let connection = end.connection(at: bit) else { continue }
        if connection.net === rootNet && connection.netBitIndex == bitIndex { return bit }
      }
    }
    return -1
  }

  /// `netlistComponent.getConnections(Net, byte, boolean)`.
  public func connections(rootNet: Net, bitIndex: Int, isOutput: Bool) -> [ConnectionPoint] {
    var result: [ConnectionPoint] = []
    for end in endEnds where end.isOutput == isOutput {
      for bit in 0..<end.nrOfBitsValue {
        guard let connection = end.connection(at: bit) else { continue }
        if connection.net === rootNet && connection.netBitIndex == bitIndex {
          result.append(connection)
        }
      }
    }
    return result
  }

  /// `netlistComponent.hasConnection(Net, byte)`.
  public func hasConnection(rootNet: Net, bitIndex: Int) -> Bool {
    connectionBitIndex(rootNet: rootNet, bitIndex: bitIndex) >= 0
  }

  /// `netlistComponent.setIsGatedInstance()`.
  func setIsGatedInstance() { isGated = true }

  // MARK: - Bubbles

  /// `netlistComponent.addGlobalBubbleId(...)`.
  func addGlobalBubbleId(
    hierarchyName: [String],
    inputStart: Int, nrOfInput: Int,
    outputStart: Int, nrOfOutput: Int,
    inOutStart: Int, nrOfInOut: Int
  ) {
    if nrOfInput == 0 && nrOfOutput == 0 && nrOfInOut == 0 { return }
    var info = BubbleInformationContainer()
    if nrOfInput > 0 { info.setInputBubbles(start: inputStart, end: inputStart + nrOfInput - 1) }
    if nrOfInOut > 0 { info.setInOutBubbles(start: inOutStart, end: inOutStart + nrOfInOut - 1) }
    if nrOfOutput > 0 {
      info.setOutputBubbles(start: outputStart, end: outputStart + nrOfOutput - 1)
    }
    globalIds[hierarchyName] = info
  }

  /// `netlistComponent.getGlobalBubbleId(List<String>)`.
  public func globalBubbleId(hierarchyName: [String]) -> BubbleInformationContainer? {
    globalIds[hierarchyName]
  }

  /// `netlistComponent.setLocalBubbleID(...)`.
  func setLocalBubbleId(
    inputStart: Int, nrOfInput: Int,
    outputStart: Int, nrOfOutput: Int,
    inOutStart: Int, nrOfInOut: Int
  ) {
    var info = localId ?? BubbleInformationContainer()
    if nrOfInput > 0 { info.setInputBubbles(start: inputStart, end: inputStart + nrOfInput - 1) }
    if nrOfInOut > 0 { info.setInOutBubbles(start: inOutStart, end: inOutStart + nrOfInOut - 1) }
    if nrOfOutput > 0 {
      info.setOutputBubbles(start: outputStart, end: outputStart + nrOfOutput - 1)
    }
    localId = info
  }

  public var localBubbleInputStartId: Int { localId?.inputRange?.lowerBound ?? 0 }
  public var localBubbleInputEndId: Int { localId?.inputRange?.upperBound ?? 0 }
  public var localBubbleOutputStartId: Int { localId?.outputRange?.lowerBound ?? 0 }
  public var localBubbleOutputEndId: Int { localId?.outputRange?.upperBound ?? 0 }
  public var localBubbleInOutStartId: Int { localId?.inOutRange?.lowerBound ?? 0 }
  public var localBubbleInOutEndId: Int { localId?.inOutRange?.upperBound ?? 0 }
}

// MARK: - HdlNetlistComponent

extension NetlistComponent: HdlNetlistComponent {
  public var nrOfEnds: Int { nrOfEndsValue }

  /// `HdlNetlistComponent.end(at:)`.
  ///
  /// **D13.** Java's `getEnd(int)` returns `null` out of range and `Hdl` dereferences it. The
  /// protocol declares this non-optional, so an out-of-range index answers a detached,
  /// zero-bit end instead of trapping: every `Hdl` caller range-checks `endIndex` against
  /// `nrOfEnds` first, so this is unreachable from a well-formed netlist.
  public func end(at index: Int) -> any HdlConnectionEnd {
    connectionEnd(at: index)
      ?? ConnectionEnd(isOutputEnd: false, nrOfBits: 0, component: component)
  }

  public func isEndConnected(_ index: Int) -> Bool { isEndConnectedValue(index) }

  public var isGatedInstance: Bool { isGated }

  public var attributeSet: any AttributeSet { component.attributeSet }

  /// `netlistComponent.getComponent().getFactory().getHDLName(attrs)`.
  ///
  /// Upstream's default (`AbstractComponentFactory.getHDLName`) is
  /// `CorrectLabel.getCorrectLabel(getName())`, and the handful of factories that override it
  /// are per-component HDL generators that this port does not carry yet: see
  /// `HdlGeneratorLookup.swift`. Overriding factories therefore change this string when they
  /// land; the seam is `HdlGeneratorLookup.hdlName`, not this property.
  public var hdlName: String {
    HdlGeneratorLookup.shared.hdlName(for: component)
  }

  /// `netlistComponent.getComponent().getFactory().getDisplayName()`.
  public var displayName: String { component.factory.displayName }
}

// NOT PORTED, by Java file:
//
//   * `BubbleInformationContainer.hasInputBubbles()` / `nrOfInputBubbles()` and their four
//     siblings; see the type's own header for why reproducing them would be worse than
//     omitting them.
