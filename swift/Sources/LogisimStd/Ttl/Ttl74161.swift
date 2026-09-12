// Ttl74161.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.ttl.Ttl74161),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// TTL 74x161: 4-bit synchronous binary counter with asynchronous clear.
//
// `open`, not `final`: `Ttl74163` (74x163, same pin/port layout but *synchronous* clear)
// extends this class in upstream and is ported that way too; see `Ttl74163.swift`. Both
// `updateState`/`getStateData` are Java `static` helpers on `Ttl74161`; Swift inherits `static
// func`s the same way, so `Ttl74163.propagateTtl` can call `getStateData`/`updateState`
// unqualified exactly as upstream does.
//
// ── Not ported ──────────────────────────────────────────────────────────────────────────────
//
//   * `Poker` (mouse-driven bit toggling on the internal register): depends on
//     `getTranslatedTtlXY`, itself not ported (`AbstractTtlGate.swift`'s header).
//   * `checkForGatedClocks`/`clockPinIndex`, HDL/FPGA backlog (D11).

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

public class Ttl74161: AbstractTtlGate {

  /// `Ttl74161._ID`. "Unique identifier of the tool, used as reference in project files. Do NOT
  /// change as it will prevent project files from loading.": upstream's own comment.
  ///
  /// **Deviation (mechanism).** `class var`, not `static let`: see `Ttl7400.id`'s header:
  /// `Ttl74163` overrides it.
  open class var id: String { "74161" }

  public static let portIndexNClr = 0
  public static let portIndexClk = 1
  public static let portIndexA = 2
  public static let portIndexB = 3
  public static let portIndexC = 4
  public static let portIndexD = 5
  public static let portIndexEnP = 6
  public static let portIndexNLoad = 7
  public static let portIndexEnT = 8
  public static let portIndexQD = 9
  public static let portIndexQC = 10
  public static let portIndexQB = 11
  public static let portIndexQA = 12
  public static let portIndexRC0 = 13

  private static let portNames = [
    "MR/CLR (Reset, active LOW)",
    "CP/CLK (Clock)",
    "D0/A",
    "D1/B",
    "D2/C",
    "D3/D",
    "CE/ENP (Count Enable)",
    "PE/LOAD (Parallel Enable, active LOW)",
    "CET/ENT (Count Enable Carry)",
    "Q3/QD",
    "Q2/QC",
    "A1/QB",
    "A0/QA",
    "TC/RC0 (Terminal Count)",
  ]
  private static let outputPorts = [11, 12, 13, 14, 15]

  public convenience init() {
    self.init(Self.id)
  }

  public init(_ name: String) {
    super.init(name, pins: 16, outputPorts: Ttl74161.outputPorts, portNames: Ttl74161.portNames)
  }

  static func updateState(_ state: any InstanceState, _ value: Int64) {
    let data = getStateData(state)

    data.setValue(Value.createKnown(BitWidth.known(4), value))
    let vA = data.getValue().get(0)
    let vB = data.getValue().get(1)
    let vC = data.getValue().get(2)
    let vD = data.getValue().get(3)

    state.setPort(portIndexQA, vA, 1)
    state.setPort(portIndexQB, vB, 1)
    state.setPort(portIndexQC, vC, 1)
    state.setPort(portIndexQD, vD, 1)

    // RC0 = QA AND QB AND QC AND QD AND ENT
    state.setPort(
      portIndexRC0, state.portValue(portIndexEnT).and(vA).and(vB).and(vC).and(vD), 1)
  }

  static func getStateData(_ state: any InstanceState) -> TtlRegisterData {
    if let existing = state.data as? TtlRegisterData {
      return existing
    }
    let data = TtlRegisterData(width: BitWidth.known(4))
    state.setData(data)
    return data
  }

  public override func propagateTtl(_ state: any InstanceState) throws {
    let data = Ttl74161.getStateData(state)
    let triggered = try data.clock.updateClock(
      state.portValue(Ttl74161.portIndexClk), trigger: StdAttr.triggerRising)
    let nClear = state.portValue(Ttl74161.portIndexNClr).toLongValue()
    var counter = data.getValue().toLongValue()

    if nClear == 0 {
      counter = 0
    } else if triggered {
      let nLoad = state.portValue(Ttl74161.portIndexNLoad)
      if nLoad.toLongValue() == 0 {
        counter = state.portValue(Ttl74161.portIndexA).toLongValue()
        counter += state.portValue(Ttl74161.portIndexB).toLongValue() << 1
        counter += state.portValue(Ttl74161.portIndexC).toLongValue() << 2
        counter += state.portValue(Ttl74161.portIndexD).toLongValue() << 3
      } else {
        let enpAndEnt =
          state.portValue(Ttl74161.portIndexEnP).and(state.portValue(Ttl74161.portIndexEnT))
          .toLongValue()
        if enpAndEnt == 1 {
          counter += 1
          if counter > 15 {
            counter = 0
          }
        }
      }
    }
    Ttl74161.updateState(state, counter)
  }

  public override func paintInternal(
    _ painter: SceneBuilder, _ state: any TtlPainter, x: Int, y: Int, height: Int, up: Bool
  ) {
    paintBase(painter, state, drawName: false, ghost: false)
    Drawgates.paintPortNames(
      painter, x: x, y: y, height: height,
      portNames: [
        "nClr", "Clk", "A", "B", "C", "D", "EnP", "nLD", "EnT", "Qd", "Qc", "Qb", "Qa", "RC0",
      ])
    drawState(painter, x: x, y: y, height: height, data: state.data as? TtlRegisterData)
  }

  private func drawState(_ painter: SceneBuilder, x: Int, y: Int, height: Int, data: TtlRegisterData?) {
    guard let data else { return }
    let value = data.getValue().toLongValue()
    for i in 0..<4 {
      let isSet = (value & (1 << (3 - i))) != 0
      painter.withColor(.palette(isSet ? .trueValue : .falseValue)) {
        painter.fillOval(x + 52 + i * 10, y + height / 2 - 4, 8, 8)
      }
      painter.withColor(.white) {
        painter.drawCenteredText(isSet ? "1" : "0", x: x + 56 + i * 10, y: y + height / 2)
      }
    }
  }
}
