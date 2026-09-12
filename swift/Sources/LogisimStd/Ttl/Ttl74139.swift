// Ttl74139.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.ttl.Ttl74139),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// TTL 74x139: dual 2-line to 4-line decoder/demultiplexer. Model based on
// https://www.ti.com/product/SN74LS139A datasheet.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

public final class Ttl74139: AbstractTtlGate {

  /// `Ttl74139._ID`. "Unique identifier of the tool, used as reference in project files. Do NOT
  /// change as it will prevent project files from loading.", upstream's own comment.
  public static let id = "74139"

  // IC pin indices as specified in the datasheet.
  private static let l1NEn = 1
  private static let l1A = 2
  private static let l1B = 3
  private static let l1NY0 = 4
  private static let l1NY1 = 5
  private static let l1NY2 = 6
  private static let l1NY3 = 7
  private static let gnd = 8
  private static let l2NY3 = 9
  private static let l2NY2 = 10
  private static let l2NY1 = 11
  private static let l2NY0 = 12
  private static let l2B = 13
  private static let l2A = 14
  private static let l2NEn = 15

  private static let delay = 1

  public init() {
    super.init(
      Ttl74139.id,
      pins: 16,
      outputPorts: [
        Ttl74139.l1NY0, Ttl74139.l1NY1, Ttl74139.l1NY2, Ttl74139.l1NY3,
        Ttl74139.l2NY0, Ttl74139.l2NY1, Ttl74139.l2NY2, Ttl74139.l2NY3,
      ],
      portNames: [
        "1nG Enable (active LOW)", "1A", "1B", "1nY0", "1nY1", "1nY2", "1nY3",
        "2nY3", "2nY2", "2nY1", "2nY0", "2B", "2A", "2nG Enable (active LOW)",
      ])
  }

  /// IC pin indices are datasheet based (1-indexed), but ports are 0-indexed with GND/VCC
  /// omitted: the port-index contract every chip in this family shares
  /// (`AbstractTtlGate.swift`'s header).
  private func mapPort(_ dsIdx: Int) -> Int {
    dsIdx <= Ttl74139.gnd ? dsIdx - 1 : dsIdx - 2
  }

  private func computeState(
    _ state: any InstanceState, en: Int, a: Int, b: Int, outPorts: [Int]
  ) {
    let enabled = state.portValue(mapPort(en)) == .falseValue  // Active LOW
    let aVal = state.portValue(mapPort(a)) == .trueValue ? 1 : 0
    let bVal = state.portValue(mapPort(b)) == .trueValue ? 2 : 0
    let selected = aVal + bVal

    for i in 0..<4 {  // Active LOW
      let val: Value = enabled ? (i == selected ? .falseValue : .trueValue) : .trueValue
      state.setPort(mapPort(outPorts[i]), val, Ttl74139.delay)
    }
  }

  public override func propagateTtl(_ state: any InstanceState) throws {
    computeState(
      state, en: Ttl74139.l1NEn, a: Ttl74139.l1A, b: Ttl74139.l1B,
      outPorts: [Ttl74139.l1NY0, Ttl74139.l1NY1, Ttl74139.l1NY2, Ttl74139.l1NY3])
    computeState(
      state, en: Ttl74139.l2NEn, a: Ttl74139.l2A, b: Ttl74139.l2B,
      outPorts: [Ttl74139.l2NY0, Ttl74139.l2NY1, Ttl74139.l2NY2, Ttl74139.l2NY3])
  }

  public override func paintInternal(
    _ painter: SceneBuilder, _ state: any TtlPainter, x: Int, y: Int, height: Int, up: Bool
  ) {
    let names = Drawgates.shortenPortNames(portNames ?? [])
    paintBase(painter, state, drawName: true, ghost: false)
    Drawgates.paintPortNames(painter, x: x, y: y, height: height, portNames: names)
  }
}
