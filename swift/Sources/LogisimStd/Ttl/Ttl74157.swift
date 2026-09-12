// Ttl74157.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.ttl.Ttl74157),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// TTL 74x157: quadruple 2-line to 1-line data selector. Model based on
// https://www.ti.com/product/SN74LS157 datasheet.
//
// `open`, not `final`: `Ttl74158` (74x157 with inverted outputs) extends this class in
// upstream and is ported that way too, see `Ttl74158.swift`.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

open class Ttl74157: AbstractTtlGate {

  /// `Ttl74157._ID`. "Unique identifier of the tool, used as reference in project files. Do NOT
  /// change as it will prevent project files from loading.": upstream's own comment.
  ///
  /// **Deviation (mechanism).** `class var`, not `static let`: see `Ttl7400.id`'s header for
  /// why: `Ttl74158` overrides it. No behavioural difference from Java's independent `_ID`
  /// fields.
  open class var id: String { "74157" }

  private static let delay = 1

  // IC pin indices as specified in the datasheet.
  private static let select = 1
  private static let l1A = 2
  private static let l1B = 3
  private static let l1Y = 4
  private static let l2A = 5
  private static let l2B = 6
  private static let l2Y = 7
  private static let gnd = 8
  private static let l3Y = 9
  private static let l3B = 10
  private static let l3A = 11
  private static let l4Y = 12
  private static let l4B = 13
  private static let l4A = 14
  private static let strobe = 15

  private static let pinNames = [
    "SELECT", "1A", "1B", "1Y", "2A", "2B", "2Y",
    "3Y", "3B", "3A", "4Y", "4B", "4A", "nSTROBE (active LOW)",
  ]
  private static let outPins = [Ttl74157.l1Y, Ttl74157.l2Y, Ttl74157.l3Y, Ttl74157.l4Y]

  /// Needed for the `Ttl74158` implementation, which is `Ttl74157` with inverted output.
  private let invertOutput: Bool

  public convenience init() {
    self.init(Self.id, invertOutput: false)
  }

  public init(_ icName: String, invertOutput: Bool) {
    self.invertOutput = invertOutput
    super.init(icName, pins: 16, outputPorts: Ttl74157.outPins, portNames: Ttl74157.pinNames)
  }

  /// IC pin indices are datasheet based (1-indexed), but ports are 0-indexed with GND/VCC
  /// omitted: the port-index contract every chip in this family shares
  /// (`AbstractTtlGate.swift`'s header).
  private func mapPort(_ dsIdx: Int) -> Int {
    dsIdx <= Ttl74157.gnd ? dsIdx - 1 : dsIdx - 2
  }

  private func computeState(_ state: any InstanceState, inA: Int, inB: Int) -> Value {
    let strobe = state.portValue(mapPort(Ttl74157.strobe)) == .trueValue
    let select = state.portValue(mapPort(Ttl74157.select)) == .trueValue
    let a = state.portValue(mapPort(inA)) == .trueValue
    let b = state.portValue(mapPort(inB)) == .trueValue

    var y = strobe ? false : (select ? b : a)
    if invertOutput { y = !y }

    return y ? .trueValue : .falseValue
  }

  public override func propagateTtl(_ state: any InstanceState) throws {
    state.setPort(
      mapPort(Ttl74157.l1Y), computeState(state, inA: Ttl74157.l1A, inB: Ttl74157.l1B),
      Ttl74157.delay)
    state.setPort(
      mapPort(Ttl74157.l2Y), computeState(state, inA: Ttl74157.l2A, inB: Ttl74157.l2B),
      Ttl74157.delay)
    state.setPort(
      mapPort(Ttl74157.l3Y), computeState(state, inA: Ttl74157.l3A, inB: Ttl74157.l3B),
      Ttl74157.delay)
    state.setPort(
      mapPort(Ttl74157.l4Y), computeState(state, inA: Ttl74157.l4A, inB: Ttl74157.l4B),
      Ttl74157.delay)
  }

  open override func paintInternal(
    _ painter: SceneBuilder, _ state: any TtlPainter, x: Int, y: Int, height: Int, up: Bool
  ) {
    let names = Drawgates.shortenPortNames(portNames ?? [])
    paintBase(painter, state, drawName: true, ghost: false)
    Drawgates.paintPortNames(painter, x: x, y: y, height: height, portNames: names)
  }
}
