// Ttl74299.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.ttl.Ttl74299),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// TTL 74x299: 8-bit universal shift/storage register with three-state outputs. Model based on
// https://www.ti.com/lit/ds/symlink/sn74f299.pdf (74F299 datasheet).
//
// **Deviation (mechanism).** See `Ttl74194.swift`'s header: `state` is threaded as an explicit
// parameter rather than stashed in a shared mutable factory field.
//
// Not ported: `checkForGatedClocks`/`clockPinIndex`, HDL/FPGA backlog (D11).

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

public final class Ttl74299: AbstractTtlGate {

  private enum Mode: Int {
    case hold = 0
    case shiftRight = 1
    case shiftLeft = 2
    case load = 3
  }

  /// `Ttl74299._ID`. "Unique identifier of the tool, used as reference in project files. Do NOT
  /// change as it will prevent project files from loading.", upstream's own comment.
  public static let id = "74299"

  private static let delay = 1

  // IC pin indices as specified in the datasheet.
  private static let s0 = 1
  private static let s1 = 19
  private static let sr = 11
  private static let sl = 18
  private static let nOe1 = 2
  private static let nOe2 = 3
  private static let clk = 12
  private static let nClr = 9
  private static let qa = 8
  private static let qh = 17
  private static let ioa = 7
  private static let iob = 13
  private static let ioc = 6
  private static let iod = 14
  private static let ioe = 5
  private static let iof = 15
  private static let iog = 4
  private static let ioh = 16
  private static let gnd = 10

  private static let data = [ioh, iog, iof, ioe, iod, ioc, iob, ioa]

  public init() {
    super.init(
      Ttl74299.id,
      pins: 20,
      outputPorts: [
        Ttl74299.qa, Ttl74299.qh, Ttl74299.ioa, Ttl74299.iob, Ttl74299.ioc, Ttl74299.iod,
        Ttl74299.ioe, Ttl74299.iof, Ttl74299.iog, Ttl74299.ioh,
      ],
      portNames: [
        "S0", "nOE1", "nOE2", "IOG", "IOE", "IOC", "IOA", "QA", "nCLR",
        "SR", "CLK", "IOB", "IOD", "IOF", "IOH", "QH", "SL", "S1",
      ])
  }

  /// IC pin indices are datasheet based (1-indexed), but ports are 0-indexed with GND/VCC
  /// omitted: the port-index contract every chip in this family shares
  /// (`AbstractTtlGate.swift`'s header).
  private func pinNrToPortNr(_ dsPinNr: Int) -> Int {
    dsPinNr <= Ttl74299.gnd ? dsPinNr - 1 : dsPinNr - 2
  }

  private func getPort(_ state: any InstanceState, _ dsPinNr: Int) -> Value {
    state.portValue(pinNrToPortNr(dsPinNr))
  }

  private func setPort(_ state: any InstanceState, _ dsPinNr: Int, _ v: Value) {
    state.setPort(pinNrToPortNr(dsPinNr), v, Ttl74299.delay)
  }

  private func getData(_ state: any InstanceState) -> TtlShiftRegisterData {
    if let existing = state.data as? TtlShiftRegisterData {
      return existing
    }
    let data = TtlShiftRegisterData(width: .one, length: 8)
    state.setData(data)
    return data
  }

  private func isTriggered(_ state: any InstanceState) throws -> Bool {
    try getData(state).clock.updateClock(getPort(state, Ttl74299.clk), trigger: StdAttr.triggerRising)
  }

  private func getMode(_ state: any InstanceState) -> Mode {
    let mode =
      (getPort(state, Ttl74299.s1) == .trueValue ? 2 : 0)
      + (getPort(state, Ttl74299.s0) == .trueValue ? 1 : 0)
    return Mode(rawValue: mode)!
  }

  private func isOutputEnabled(_ state: any InstanceState) -> Bool {
    getPort(state, Ttl74299.nOe1) == .falseValue
      && getPort(state, Ttl74299.nOe2) == .falseValue
      && (getPort(state, Ttl74299.s0) == .falseValue || getPort(state, Ttl74299.s1) == .falseValue)
  }

  private func propagateRegister(_ state: any InstanceState) throws {
    if getPort(state, Ttl74299.nClr) == .falseValue {  // CLR is active low and clear is async
      getData(state).clear()
    } else if try isTriggered(state) {
      switch getMode(state) {
      case .load:
        for i in 0..<8 {
          getData(state).set(i, getPort(state, Ttl74299.data[i]))
        }
      case .shiftLeft:
        getData(state).pushUp(getPort(state, Ttl74299.sl))
      case .shiftRight:
        getData(state).pushDown(getPort(state, Ttl74299.sr))
      case .hold:
        break
      }
    }
  }

  private func propagateOutputs(_ state: any InstanceState) {
    setPort(state, Ttl74299.qa, getData(state).get(7))  // Most significant bit
    setPort(state, Ttl74299.qh, getData(state).get(0))  // Least significant bit

    let enabled = isOutputEnabled(state)
    for i in 0..<8 {
      setPort(state, Ttl74299.data[i], enabled ? getData(state).get(i) : .unknownValue)
    }
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
