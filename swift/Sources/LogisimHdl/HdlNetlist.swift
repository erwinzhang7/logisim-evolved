// HdlNetlist: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// the surface of `com/cburch/logisim/fpga/designrulecheck/{Netlist,netlistComponent}.java`
// that `com.cburch.logisim.fpga.hdlgenerator` actually calls. Copyright by the
// Logisim-evolution developers. This translation is a derivative work and is therefore
// licensed GPL-3.0-only. See LICENSE.md.
//
// ── Why protocols, not a port of `Netlist`/`netlistComponent` ───────────────────────────────
//
// `Netlist` (2,478 lines) and `netlistComponent` (235 lines) are the design-rule-check engine:
// they walk a `Circuit`'s wires and splitters to build the net graph the HDL layer reads from.
// That is a distinct subsystem from HDL *generation*, this task ports the generation
// framework `com.cburch.logisim.fpga.hdlgenerator` names, not `designrulecheck`, and it needs
// `Component`/`AttributeSet` types owned by modules this task does not touch.
//
// So this file captures exactly the read-only surface `Hdl` and `AbstractHdlGeneratorFactory`
// call on a netlist and a placed component, nothing more, as protocols. A future
// `designrulecheck` port makes its concrete `Netlist`/`NetlistComponent` conform to these
// (or this file's protocols could move to sit alongside that port); either way, today's
// `AbstractHdlGeneratorFactory` subclasses in `LogisimStd` can already be written and tested
// against these protocols using a lightweight fake, which is the "shape they will need" this
// task was asked to leave behind.
//
// Naming follows Swift convention (`NetlistComponent`, not `netlistComponent`) and drops the
// generic go-between whose call sites are shown in the naming here in favour of clearer,
// idiomatic-Swift member names (`bitWidth` for `getBitWidth()`, etc.); the same style already
// used for `AttributeSet`/`Attribute<V>` in `LogisimKernel`.

import LogisimKernel

/// `com.cburch.logisim.fpga.designrulecheck.Net`, exposed just far enough for HDL text
/// generation: its identity (for `getNetId`), width and bus-ness.
public protocol HdlNet: AnyObject {
  /// `Net.getBitWidth()`.
  var bitWidth: Int { get }
  /// `Net.isBus()`.
  var isBus: Bool { get }
}

/// `com.cburch.logisim.fpga.designrulecheck.ConnectionPoint`: one bit of one end of one
/// placed component, and the net (if any) it solders to.
public protocol HdlSolderPoint {
  /// `ConnectionPoint.getParentNet()`. `nil` when this bit is unconnected.
  var parentNet: (any HdlNet)? { get }
  /// `ConnectionPoint.getParentNetBitIndex()`.
  var parentNetBitIndex: Int { get }
}

/// `com.cburch.logisim.fpga.designrulecheck.ConnectionEnd`: one pin (possibly multi-bit) of a
/// placed component.
public protocol HdlConnectionEnd {
  /// `ConnectionEnd.getNrOfBits()`.
  var nrOfBits: Int { get }
  /// `ConnectionEnd.isOutputEnd()`.
  var isOutputEnd: Bool { get }
  /// `ConnectionEnd.get(byte)`.
  func solderPoint(atBit bit: Int) -> any HdlSolderPoint
}

/// `com.cburch.logisim.fpga.designrulecheck.netlistComponent`: a placed component together
/// with its per-pin connection information, as the HDL layer needs it.
public protocol HdlNetlistComponent: AnyObject {
  /// `netlistComponent.nrOfEnds()`.
  var nrOfEnds: Int { get }
  /// `netlistComponent.getEnd(int)`.
  func end(at index: Int) -> any HdlConnectionEnd
  /// `netlistComponent.isEndConnected(int)`.
  func isEndConnected(_ index: Int) -> Bool
  /// `netlistComponent.isGatedInstance()`.
  var isGatedInstance: Bool { get }

  /// `netlistComponent.getComponent().getAttributeSet()`.
  var attributeSet: any AttributeSet { get }
  /// `netlistComponent.getComponent().getFactory().getHDLName(attrs)`.
  var hdlName: String { get }
  /// `netlistComponent.getComponent().getFactory().getDisplayName()`.
  var displayName: String { get }
}

/// `com.cburch.logisim.fpga.designrulecheck.Netlist`: one circuit's net graph, as the HDL
/// layer needs to read it.
public protocol HdlNetlist: AnyObject {
  /// `Netlist.getNetId(Net)`.
  func netId(for net: any HdlNet) -> Int
  /// `Netlist.isContinuesBus(netlistComponent, int)`.
  func isContinuesBus(_ component: any HdlNetlistComponent, endIndex: Int) -> Bool
  /// `Netlist.getCurrentHierarchyLevel()`. `nil` before the hierarchy walk has set one.
  var currentHierarchyLevel: [String]? { get }
  /// `Netlist.getClockSourceId(List<String>, Net, Byte)`. Negative when no clock source
  /// matches, exactly as upstream returns `-1`.
  func clockSourceId(hierarchyLevel: [String], net: any HdlNet, bitIndex: Int) -> Int

  /// `Netlist.getClockSourceId(Component)` (`Netlist.java:1113-1115`): the **component-keyed**
  /// overload, which is a different lookup from the net-keyed one above, not a convenience over
  /// it. Java has both; only the net-keyed one was ported, so
  /// `ClockHdlGeneratorFactory.getPortMap` had to take an injected closure defaulting to `-1`
  /// and a real clock could never resolve its own source id through a netlist.
  ///
  /// Takes the `netlistComponent` rather than the raw `Component` because this protocol
  /// deliberately does not name `Component` (see the file header); a conformer that wraps a real
  /// one forwards to `ClockTreeFactory.clockSourceId(for:)`.
  func clockSourceId(for component: any HdlNetlistComponent) -> Int

  /// `Netlist.getCircuitName()`.
  var circuitName: String { get }
  /// `Netlist.projName()`.
  var projName: String { get }
  /// `Netlist.requiresGlobalClockConnection()`.
  var requiresGlobalClockConnection: Bool { get }
}

extension HdlNetlist {
  /// Default for netlists with no clock tree: the synthetic ones the oracle harnesses build,
  /// and any conformer written before this overload existed. `-1` is upstream's own
  /// "no clock source matches" answer, so a conformer that does not override this behaves
  /// exactly as an unconnected clock does rather than as something new.
  public func clockSourceId(for component: any HdlNetlistComponent) -> Int { -1 }
}
