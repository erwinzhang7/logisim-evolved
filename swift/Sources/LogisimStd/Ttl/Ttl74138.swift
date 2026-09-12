// Ttl74138.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.ttl.Ttl74138),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// TTL 74x138: 3-line to 8-line decoder/demultiplexer. Model based on
// https://www.ti.com/product/SN74LS138 datasheet.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

public final class Ttl74138: AbstractTtlGate {

  /// `Ttl74138._ID`. "Unique identifier of the tool, used as reference in project files. Do NOT
  /// change as it will prevent project files from loading.", upstream's own comment.
  public static let id = "74138"

  // IC pin indices as specified in the datasheet.
  private static let a = 1
  private static let b = 2
  private static let c = 3
  private static let nEn2A = 4
  private static let nEn2B = 5
  private static let en1 = 6
  private static let nY7 = 7
  private static let gnd = 8
  private static let nY6 = 9
  private static let nY5 = 10
  private static let nY4 = 11
  private static let nY3 = 12
  private static let nY2 = 13
  private static let nY1 = 14
  private static let nY0 = 15

  private static let delay = 1

  public init() {
    super.init(
      Ttl74138.id,
      pins: 16,
      outputPorts: [
        Ttl74138.nY0, Ttl74138.nY1, Ttl74138.nY2, Ttl74138.nY3, Ttl74138.nY4, Ttl74138.nY5,
        Ttl74138.nY6, Ttl74138.nY7,
      ],
      portNames: [
        "A", "B", "C", "nG2A Enable (active LOW)", "nG2B Enable (active LOW)",
        "G1 Enable (active HIGH)", "nY7", "nY6", "nY5", "nY4", "nY3", "nY2", "nY1", "nY0",
      ])
  }

  /// IC pin indices are datasheet based (1-indexed), but ports are 0-indexed with GND/VCC
  /// omitted: the port-index contract every chip in this family shares
  /// (`AbstractTtlGate.swift`'s header).
  private func mapPort(_ dsIdx: Int) -> Int {
    dsIdx <= Ttl74138.gnd ? dsIdx - 1 : dsIdx - 2
  }

  public override func propagateTtl(_ state: any InstanceState) throws {
    let enabled =
      state.portValue(mapPort(Ttl74138.en1)) == .trueValue  // Active HIGH
      && state.portValue(mapPort(Ttl74138.nEn2A)) == .falseValue  // Active LOW
      && state.portValue(mapPort(Ttl74138.nEn2B)) == .falseValue  // Active LOW
    let a = state.portValue(mapPort(Ttl74138.a)) == .trueValue ? 1 : 0
    let b = state.portValue(mapPort(Ttl74138.b)) == .trueValue ? 2 : 0
    let c = state.portValue(mapPort(Ttl74138.c)) == .trueValue ? 4 : 0
    let selected = a + b + c

    let outPorts = [
      Ttl74138.nY0, Ttl74138.nY1, Ttl74138.nY2, Ttl74138.nY3, Ttl74138.nY4, Ttl74138.nY5,
      Ttl74138.nY6, Ttl74138.nY7,
    ]
    // Upstream indexes an explicit 8x8 one-hot table (`outputPortStates[A+B+C][i]`); since row
    // `selected` is 1 only at column `selected`, `i == selected` is the same test.
    for i in 0..<8 {  // Active LOW
      let val: Value = enabled ? (i == selected ? .falseValue : .trueValue) : .trueValue
      state.setPort(mapPort(outPorts[i]), val, Ttl74138.delay)
    }
  }

  public override func paintInternal(
    _ painter: SceneBuilder, _ state: any TtlPainter, x: Int, y: Int, height: Int, up: Bool
  ) {
    let names = Drawgates.shortenPortNames(portNames ?? [])
    paintBase(painter, state, drawName: true, ghost: false)
    Drawgates.paintPortNames(painter, x: x, y: y, height: height, portNames: names)
  }
}
