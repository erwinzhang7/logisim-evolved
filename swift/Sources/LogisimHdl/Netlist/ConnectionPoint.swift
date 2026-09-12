// ConnectionPoint / ConnectionEnd: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// `com/cburch/logisim/fpga/designrulecheck/{ConnectionPoint,ConnectionEnd,
// ConnectionPointArray}.java`. Copyright by the Logisim-evolution developers. This translation
// is a derivative work and is therefore licensed GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// `ConnectionPointArray` does not come across as a type: it is a 24-line wrapper around one
// `ArrayList<ConnectionPoint>` with `add`/`clear`/`getAll`/`size`, and `Net` is its only user.
// `Net` holds `[[ConnectionPoint]]` directly instead: same semantics, one fewer indirection.

import LogisimFile

/// `com.cburch.logisim.fpga.designrulecheck.ConnectionPoint`: one bit of one end of one placed
/// component, and the root net (if any) that bit solders to.
public final class ConnectionPoint {

  /// `ConnectionPoint.myComp`. Held **strongly**, as Java's field is; the netlist is a
  /// short-lived analysis product that the circuit does not point back into, so this closes no
  /// cycle (D3).
  ///
  /// Optional only for the detached placeholder `solderPoint(atBit:)` returns out of range;
  /// see its documentation. Java's field is non-null for every point the netlist builds.
  public let component: (any Component)?

  /// `ConnectionPoint.myOwnNet`.
  public private(set) var net: Net?

  /// `ConnectionPoint.myOwnNetBitIndex`. `-1` until `setParentNet` runs, exactly as Java's
  /// `Byte` field is initialised.
  public private(set) var netBitIndex: Int = -1

  /// `ConnectionPoint.myChildsPortIndex`.
  public private(set) var childsPortIndex: Int = -1

  /// `ConnectionPoint(Component)`.
  public init(component: (any Component)?) {
    self.component = component
  }

  /// `ConnectionPoint.setParentNet(Net, Byte)`.
  func setParentNet(_ connectedNet: Net?, bitIndex: Int) {
    net = connectedNet
    netBitIndex = bitIndex
  }

  /// `ConnectionPoint.setChildsPortIndex(int)`.
  func setChildsPortIndex(_ index: Int) {
    childsPortIndex = index
  }
}

extension ConnectionPoint: HdlSolderPoint {
  /// `ConnectionPoint.getParentNet()`.
  public var parentNet: (any HdlNet)? { net }
  /// `ConnectionPoint.getParentNetBitIndex()`.
  public var parentNetBitIndex: Int { netBitIndex }
}

/// `com.cburch.logisim.fpga.designrulecheck.ConnectionEnd`: one pin (possibly multi-bit) of one
/// placed component.
public final class ConnectionEnd {

  /// `ConnectionEnd.isOutput`.
  public let isOutput: Bool

  /// `ConnectionEnd.myConnections`, one per bit.
  private(set) var connections: [ConnectionPoint]

  /// `ConnectionEnd(boolean, Byte, Component)`.
  public init(isOutputEnd: Bool, nrOfBits: Int, component: any Component) {
    self.isOutput = isOutputEnd
    self.connections = (0..<max(0, nrOfBits)).map { _ in ConnectionPoint(component: component) }
  }

  /// `ConnectionEnd.getNrOfBits()`.
  public var nrOfBitsValue: Int { connections.count }

  /// `ConnectionEnd.get(Byte)`: `nil` out of range, matching Java's `null`.
  public func connection(at bitIndex: Int) -> ConnectionPoint? {
    guard bitIndex >= 0, bitIndex < connections.count else { return nil }
    return connections[bitIndex]
  }

  /// `ConnectionEnd.setConnection(ConnectionPoint, Byte)`.
  @discardableResult
  func setConnection(_ connection: ConnectionPoint, at bitIndex: Int) -> Bool {
    guard bitIndex >= 0, bitIndex < connections.count else { return false }
    connections[bitIndex] = connection
    return true
  }
}

extension ConnectionEnd: HdlConnectionEnd {
  public var nrOfBits: Int { nrOfBitsValue }
  public var isOutputEnd: Bool { isOutput }

  /// `HdlConnectionEnd.solderPoint(atBit:)`.
  ///
  /// **D13.** Java's `ConnectionEnd.get(byte)` returns `null` out of range and every caller in
  /// `Hdl` dereferences the result immediately, so upstream throws `NullPointerException` on a
  /// malformed netlist. `HdlConnectionEnd` declares this non-optional, so the port answers with
  /// a detached, permanently unconnected point instead of trapping: every `Hdl` helper already
  /// treats "no parent net" as "unconnected pin" and emits the floating-value text for it,
  /// which is the same output an out-of-range index could ever have produced meaningfully.
  /// Every in-tree caller range-checks before calling, so this path is unreachable from a
  /// well-formed netlist.
  public func solderPoint(atBit bit: Int) -> any HdlSolderPoint {
    connection(at: bit) ?? ConnectionPoint(component: nil)
  }
}

// NOT PORTED: `ConnectionEnd.setChildPortIndex(Net, Byte, int)`: dead upstream. It ignores its
// `Net` argument and forwards to `ConnectionPoint.setChildsPortIndex`, and no caller exists in
// 4.1.0 (`Netlist.processSubcircuit` calls the `ConnectionPoint` method directly).
