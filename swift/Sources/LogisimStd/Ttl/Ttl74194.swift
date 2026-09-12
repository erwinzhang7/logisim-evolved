// Ttl74194.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.ttl.Ttl74194),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// TTL 74x194: 4-bit bidirectional universal shift register. Model based on
// https://www.ti.com/lit/ds/symlink/sn74ls194a.pdf (74LS194 datasheet).
//
// **Deviation (mechanism).** Upstream stashes the current `InstanceState` in a private instance
// field (`_state`) that every helper method reads, rather than threading it as a parameter;
// safe there only because a `FactoryDescription`-built factory is a single shared object and
// propagation is single-threaded/non-reentrant (D1/D2's precedent). This port threads `state`
// as an explicit parameter instead: behaviourally identical (nothing here is reentrant either
// way), and it avoids adding mutable state to a factory instance for no observable benefit.
//
// Not ported: `checkForGatedClocks`/`clockPinIndex`, HDL/FPGA backlog (D11).

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

public final class Ttl74194: AbstractTtlGate {

  private enum Mode: Int {
    case hold = 0
    case shiftRight = 1
    case shiftLeft = 2
    case load = 3
  }

  /// `Ttl74194._ID`. "Unique identifier of the tool, used as reference in project files. Do NOT
  /// change as it will prevent project files from loading.", upstream's own comment.
  public static let id = "74194"

  private static let delay = 1

  // IC pin indices as specified in the datasheet.
  private static let s0 = 9
  private static let s1 = 10
  private static let sr = 2
  private static let sl = 7
  private static let clk = 11
  private static let nClr = 1
  private static let a = 3
  private static let b = 4
  private static let c = 5
  private static let d = 6
  private static let qa = 15
  private static let qb = 14
  private static let qc = 13
  private static let qd = 12
  private static let gnd = 8

  private static let data = [d, c, b, a]

  public init() {
    super.init(
      Ttl74194.id,
      pins: 16,
      outputPorts: [Ttl74194.qa, Ttl74194.qb, Ttl74194.qc, Ttl74194.qd],
      portNames: [
        "nCLR", "SR", "A", "B", "C", "D", "SL",
        "S0", "S1", "CLK", "QD", "QC", "QB", "QA",
      ])
  }

  /// IC pin indices are datasheet based (1-indexed), but ports are 0-indexed with GND/VCC
  /// omitted: the port-index contract every chip in this family shares
  /// (`AbstractTtlGate.swift`'s header).
  private func pinNrToPortNr(_ dsPinNr: Int) -> Int {
    dsPinNr <= Ttl74194.gnd ? dsPinNr - 1 : dsPinNr - 2
  }

  private func getPort(_ state: any InstanceState, _ dsPinNr: Int) -> Value {
    state.portValue(pinNrToPortNr(dsPinNr))
  }

  private func setPort(_ state: any InstanceState, _ dsPinNr: Int, _ v: Value) {
    state.setPort(pinNrToPortNr(dsPinNr), v, Ttl74194.delay)
  }

  private func getData(_ state: any InstanceState) -> TtlShiftRegisterData {
    if let existing = state.data as? TtlShiftRegisterData {
      return existing
    }
    let data = TtlShiftRegisterData(width: .one, length: 4)
    state.setData(data)
    return data
  }

  private func isTriggered(_ state: any InstanceState) throws -> Bool {
    try getData(state).clock.updateClock(getPort(state, Ttl74194.clk), trigger: StdAttr.triggerRising)
  }

  private func getMode(_ state: any InstanceState) -> Mode {
    let mode =
      (getPort(state, Ttl74194.s1) == .trueValue ? 2 : 0)
      + (getPort(state, Ttl74194.s0) == .trueValue ? 1 : 0)
    return Mode(rawValue: mode)!
  }

  private func propagateRegister(_ state: any InstanceState) throws {
    if getPort(state, Ttl74194.nClr) == .falseValue {  // CLR is active low and clear is async
      getData(state).clear()
    } else if try isTriggered(state) {
      switch getMode(state) {
      case .load:
        for i in 0..<4 {
          getData(state).set(i, getPort(state, Ttl74194.data[i]))
        }
      case .shiftLeft:
        getData(state).pushUp(getPort(state, Ttl74194.sl))
      case .shiftRight:
        getData(state).pushDown(getPort(state, Ttl74194.sr))
      case .hold:
        break
      }
    }
  }

  private func propagateOutputs(_ state: any InstanceState) {
    setPort(state, Ttl74194.qa, getData(state).get(3))  // Most significant bit
    setPort(state, Ttl74194.qb, getData(state).get(2))
    setPort(state, Ttl74194.qc, getData(state).get(1))
    setPort(state, Ttl74194.qd, getData(state).get(0))  // Least significant bit
  }

  public override func propagateTtl(_ state: any InstanceState) throws {
    try propagateRegister(state)
    propagateOutputs(state)
  }

  public override func paintInternal(
    _ painter: SceneBuilder, _ state: any TtlPainter, x: Int, y: Int, height: Int, up: Bool
  ) {
    paintBase(painter, state, drawName: true, ghost: false)
    Drawgates.paintPortNames(painter, x: x, y: y, height: height, portNames: portNames ?? [])
  }
}
