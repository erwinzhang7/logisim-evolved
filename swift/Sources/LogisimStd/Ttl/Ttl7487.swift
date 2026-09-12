// Ttl7487.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.ttl.Ttl7487),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// TTL 74x87: 4-bit true/complement, zero/one element. Takes a 4-bit input (A1-A4) and, per the
// B/C control lines, outputs the input unchanged, its complement, all-high, or all-low;
// typically used ahead of an adder to select add/subtract, increment/decrement/transparent
// alongside the adder's carry-in. Datasheet:
// https://archive.org/details/bitsavers_tidataBookVol2_45945352/page/n404/mode/1up?view=theater

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

public final class Ttl7487: AbstractTtlGate {

  /// `Ttl7487._ID`. "Unique identifier of the tool, used as reference in project files. Do NOT
  /// change as it will prevent project files from loading.", upstream's own comment.
  public static let id = "7487"

  // Port indices (0-based, after the GND/Vcc squeeze), transcribed verbatim from upstream's
  // named `byte` constants.
  private static let a1 = 1
  private static let a2 = 3
  private static let a3 = 7
  private static let a4 = 9
  private static let b = 5
  private static let c = 0
  private static let y1 = 2
  private static let y2 = 4
  private static let y3 = 6
  private static let y4 = 8
  private static let delay = 1

  public init() {
    super.init(
      Ttl7487.id,
      pins: 14,
      outputPorts: [3, 6, 9, 12],
      notUsedPins: [4, 11],
      portNames: ["C", "A1", "Y1", "A2", "Y2", "B", "Y3", "A3", "Y4", "A4"])
  }

  public override func propagateTtl(_ state: any InstanceState) throws {
    let b = state.portValue(Ttl7487.b)
    let c = state.portValue(Ttl7487.c)
    if b == .trueValue {
      // High or low output
      state.setPort(Ttl7487.y1, c.not(), Ttl7487.delay)
      state.setPort(Ttl7487.y2, c.not(), Ttl7487.delay)
      state.setPort(Ttl7487.y3, c.not(), Ttl7487.delay)
      state.setPort(Ttl7487.y4, c.not(), Ttl7487.delay)
    } else if b == .falseValue {
      if c == .trueValue {
        // not inverted
        state.setPort(Ttl7487.y1, state.portValue(Ttl7487.a1), Ttl7487.delay)
        state.setPort(Ttl7487.y2, state.portValue(Ttl7487.a2), Ttl7487.delay)
        state.setPort(Ttl7487.y3, state.portValue(Ttl7487.a3), Ttl7487.delay)
        state.setPort(Ttl7487.y4, state.portValue(Ttl7487.a4), Ttl7487.delay)
      } else if c == .falseValue {
        // inverted
        state.setPort(Ttl7487.y1, state.portValue(Ttl7487.a1).not(), Ttl7487.delay)
        state.setPort(Ttl7487.y2, state.portValue(Ttl7487.a2).not(), Ttl7487.delay)
        state.setPort(Ttl7487.y3, state.portValue(Ttl7487.a3).not(), Ttl7487.delay)
        state.setPort(Ttl7487.y4, state.portValue(Ttl7487.a4).not(), Ttl7487.delay)
      } else {
        state.setPort(Ttl7487.y1, .errorValue, Ttl7487.delay)
        state.setPort(Ttl7487.y2, .errorValue, Ttl7487.delay)
        state.setPort(Ttl7487.y3, .errorValue, Ttl7487.delay)
        state.setPort(Ttl7487.y4, .errorValue, Ttl7487.delay)
      }
    } else {
      state.setPort(Ttl7487.y1, .errorValue, Ttl7487.delay)
      state.setPort(Ttl7487.y2, .errorValue, Ttl7487.delay)
      state.setPort(Ttl7487.y3, .errorValue, Ttl7487.delay)
      state.setPort(Ttl7487.y4, .errorValue, Ttl7487.delay)
    }
  }

  public override func paintInternal(
    _ painter: SceneBuilder, _ state: any TtlPainter, x: Int, y: Int, height: Int, up: Bool
  ) {
    paintBase(painter, state, drawName: true, ghost: false)
    Drawgates.paintPortNames(painter, x: x, y: y, height: height, portNames: portNames ?? [])
  }
}
