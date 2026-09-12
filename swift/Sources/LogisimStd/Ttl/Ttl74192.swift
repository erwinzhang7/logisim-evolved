// Ttl74192.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.ttl.Ttl74192),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// TTL 74x192: synchronous 4-bit up/down decade counter (`maxVal` 9).
//
// `open`, not `final`: `Ttl74193` (74x193, same layout but a 4-bit *binary* counter, `maxVal`
// 15) extends this class in upstream via the `(String, int)` constructor and is ported that way
// too; see `Ttl74193.swift`. `updateState`/`getStateData` are Java `static` helpers, inherited
// the same way `Ttl74161`'s are (see that file's header).
//
// ── Edge detection without `TtlClockState` ──────────────────────────────────────────────────
//
// This chip has two independent clock-like inputs (`UP`, `DOWN`) whose *combination* of edges
// and levels selects count-up/count-down/carry/borrow: not expressible as one
// `TtlClockState.updateClock` call, so upstream hand-rolls rising/falling/unchanged detection
// against `UpDownCounterData.upPrev`/`downPrev` directly, and this port preserves that exactly.
//
// ── Not ported ──────────────────────────────────────────────────────────────────────────────
//
//   * `Poker` (mouse-driven bit toggling): depends on `getTranslatedTtlXY`, itself not ported.
import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

public class Ttl74192: AbstractTtlGate {

  /// `Ttl74192._ID`. "Unique identifier of the tool, used as reference in project files. Do NOT
  /// change as it will prevent project files from loading.": upstream's own comment.
  ///
  /// **Deviation (mechanism).** `class var`, not `static let`: see `Ttl7400.id`'s header:
  /// `Ttl74193` overrides it.
  open class var id: String { "74192" }

  public static let portIndexB = 0
  public static let portIndexQB = 1
  public static let portIndexQA = 2
  public static let portIndexDown = 3
  public static let portIndexUp = 4
  public static let portIndexQC = 5
  public static let portIndexQD = 6
  public static let portIndexD = 7
  public static let portIndexC = 8
  public static let portIndexLoad = 9
  public static let portIndexCarry = 10
  public static let portIndexBorrow = 11
  public static let portIndexClear = 12
  public static let portIndexA = 13

  private static let portNames = [
    "Data Input B", "Data Output B", "Data Output A", "Count Down", "Count Up",
    "Data Output C", "Data Output D", "Data Input D", "Data Input C", "Load",
    "Carry", "Borrow", "Clear", "Data Input A",
  ]
  private static let outputPorts: [Int] = [2, 3, 6, 7, 12, 13]

  private static let width = BitWidth.known(4)

  private let maxVal: Int64

  public convenience init() {
    self.init(Self.id, maxVal: 9)
  }

  public init(_ name: String, maxVal: Int64) {
    self.maxVal = maxVal
    super.init(name, pins: 16, outputPorts: Ttl74192.outputPorts, portNames: Ttl74192.portNames)
  }

  static func updateState(
    _ state: any InstanceState, _ value: Value, _ carry: Value, _ borrow: Value, _ down: Value,
    _ up: Value
  ) {
    let data = getStateData(state)

    data.setAll(value: value, carry: carry, borrow: borrow, down: down, up: up)
    let vA = data.value.get(0)
    let vB = data.value.get(1)
    let vC = data.value.get(2)
    let vD = data.value.get(3)
    let vCar = data.carry
    let vBor = data.borrow

    state.setPort(portIndexQA, vA, 4)
    state.setPort(portIndexQB, vB, 4)
    state.setPort(portIndexQC, vC, 4)
    state.setPort(portIndexQD, vD, 4)
    state.setPort(portIndexCarry, vCar, 4)
    state.setPort(portIndexBorrow, vBor, 4)
  }

  static func getStateData(_ state: any InstanceState) -> UpDownCounterData {
    if let existing = state.data as? UpDownCounterData {
      return existing
    }
    let data = UpDownCounterData()
    state.setData(data)
    return data
  }

  public override func propagateTtl(_ state: any InstanceState) throws {
    let data = Ttl74192.getStateData(state)

    var carry: Value = .trueValue
    var borrow: Value = .trueValue
    var counter = data.value.toLongValue()

    let downPrev = data.downPrev
    let upPrev = data.upPrev
    let downCur = state.portValue(Ttl74192.portIndexDown)
    let upCur = state.portValue(Ttl74192.portIndexUp)
    let downFalling = downPrev == .trueValue && downCur == .falseValue
    let downRising = downPrev == .falseValue && downCur == .trueValue
    let upFalling = upPrev == .trueValue && upCur == .falseValue
    let upRising = upPrev == .falseValue && upCur == .trueValue
    let downUnchangedHigh = downPrev == .trueValue && downCur == .trueValue
    let upUnchangedHigh = upPrev == .trueValue && upCur == .trueValue

    if state.portValue(Ttl74192.portIndexClear) == .trueValue {  // reset
      counter = 0
    } else if state.portValue(Ttl74192.portIndexLoad) == .falseValue {  // load value
      var inputValue = state.portValue(Ttl74192.portIndexA).toLongValue()
      inputValue += state.portValue(Ttl74192.portIndexB).toLongValue() << 1
      inputValue += state.portValue(Ttl74192.portIndexC).toLongValue() << 2
      inputValue += state.portValue(Ttl74192.portIndexD).toLongValue() << 3
      counter = inputValue > maxVal ? 0 : inputValue  // TODO: not sure
    } else if downRising && upUnchangedHigh {  // count down
      counter -= 1
      if counter < 0 {
        counter = maxVal
      }
    } else if upRising && downUnchangedHigh {  // count up
      counter += 1
      if counter > maxVal {
        counter = 0
      }
    } else if upFalling && downUnchangedHigh {  // carry
      if counter == maxVal {
        carry = .falseValue
      }
    } else if downFalling && upUnchangedHigh {  // borrow
      if counter == 0 {
        borrow = .falseValue
      }
    } else {  // state does not change
      carry = data.carry
      borrow = data.borrow
    }
    Ttl74192.updateState(
      state, Value.createKnown(Ttl74192.width, counter), carry, borrow, downCur, upCur)
  }

  public override func paintInternal(
    _ painter: SceneBuilder, _ state: any TtlPainter, x: Int, y: Int, height: Int, up: Bool
  ) {
    paintBase(painter, state, drawName: false, ghost: false)
    Drawgates.paintPortNames(
      painter, x: x, y: y, height: height,
      portNames: ["B", "QB", "QA", "CntD", "CntU", "QC", "QD", "D", "C", "LOAD", "CAR", "BOR", "CLR", "A"])
    drawState(painter, x: x, y: y, height: height, data: state.data as? UpDownCounterData)
  }

  private func drawState(
    _ painter: SceneBuilder, x: Int, y: Int, height: Int, data: UpDownCounterData?
  ) {
    guard let data else { return }
    let value = data.value
    for i in 0..<4 {
      let bitValue = value.get(3 - i)
      painter.withColor(.palette(bitValue.paletteIndex)) {
        painter.fillOval(x + 52 + i * 10, y + height / 2 - 4, 8, 8)
      }
      painter.withColor(.white) {
        painter.drawCenteredText(
          bitValue == .trueValue ? "1" : "0", x: x + 56 + i * 10, y: y + height / 2)
      }
    }
  }
}
