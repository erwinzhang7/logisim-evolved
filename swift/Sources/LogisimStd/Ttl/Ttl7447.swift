// Ttl7447.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.ttl.Ttl7447),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// The decode logic lives in `DisplayDecoderLogic.swift` (shared with the standalone
// `DisplayDecoder` component, out of scope here, see that file's header).

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

/// TTL 74x47: BCD-to-seven-segment decoder/driver (active-low outputs, open-collector).
public final class Ttl7447: AbstractTtlGate {

  /// `Ttl7447._ID`. "Unique identifier of the tool, used as reference in project files. Do NOT
  /// change as it will prevent project files from loading.", upstream's own comment.
  public static let id = "7447"

  // Port indices (0-based, after `AbstractTtlGate`'s GND/Vcc squeeze), transcribed verbatim
  // from upstream's `PORT_INDEX_*` constants.
  public static let portIndexB = 0
  public static let portIndexC = 1
  public static let portIndexLT = 2
  public static let portIndexBI = 3
  public static let portIndexRBI = 4
  public static let portIndexD = 5
  public static let portIndexA = 6
  public static let portIndexQE = 7
  public static let portIndexQD = 8
  public static let portIndexQC = 9
  public static let portIndexQB = 10
  public static let portIndexQA = 11
  public static let portIndexQG = 12
  public static let portIndexQF = 13

  public init() {
    super.init(
      Ttl7447.id,
      pins: 16,
      outputPorts: [9, 10, 11, 12, 13, 14, 15],
      portNames: ["B", "C", "LT", "BI", "RBI", "D", "A", "e", "d", "c", "b", "a", "g", "f"])
  }

  public override func propagateTtl(_ state: any InstanceState) throws {
    let decoded = DisplayDecoderLogic.getDecVal(
      state,
      multibit: false,
      multibitInputIndex: 0,
      aIndex: Ttl7447.portIndexA,
      bIndex: Ttl7447.portIndexB,
      cIndex: Ttl7447.portIndexC,
      dIndex: Ttl7447.portIndexD)
    DisplayDecoderLogic.computeOutputs(
      state,
      inputValue: decoded,
      aPortIndex: Ttl7447.portIndexQA,
      bPortIndex: Ttl7447.portIndexQB,
      cPortIndex: Ttl7447.portIndexQC,
      dPortIndex: Ttl7447.portIndexQD,
      ePortIndex: Ttl7447.portIndexQE,
      fPortIndex: Ttl7447.portIndexQF,
      gPortIndex: Ttl7447.portIndexQG,
      ltPortIndex: Ttl7447.portIndexLT,
      biPortIndex: Ttl7447.portIndexBI,
      rbiPortIndex: Ttl7447.portIndexRBI)
  }

  public override func paintInternal(
    _ painter: SceneBuilder, _ state: any TtlPainter, x: Int, y: Int, height: Int, up: Bool
  ) {
    paintBase(painter, state, drawName: true, ghost: false)
    Drawgates.paintPortNames(painter, x: x, y: y, height: height, portNames: portNames ?? [])
  }
}
