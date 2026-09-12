// ReptarLocalBus.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.io.ReptarLocalBus),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── This component's simulation is unimplemented upstream too ──────────────────────────────────
//
// `ReptarLocalBus.propagate` is, verbatim: `throw new UnsupportedOperationException("Reptar
// Local Bus simulation not implemented")`, with the entire intended body commented out. This is
// a board-specific FPGA local-bus adapter whose only real job is HDL generation
// (`ReptarLocalBusHdlGeneratorFactory`, not ported; HDL is stripped per the task brief) driving
// a physical Reptar board; there was never a Logisim-side simulation to port. Faithfully
// reproduced: `propagate` throws (D13; `Simulator` catches it and reports a circuit error,
// exactly the behaviour a user placing this component in a simulated, non-FPGA-downloaded
// circuit already sees upstream).
//
// ── What did not come across ─────────────────────────────────────────────────────────────────
//
//   (`paintInstance` IS ported; see the Paint section at the end of this file.)
//   * `getHDLName` / `ReptarLocalBusHdlGeneratorFactory`: HDL (stripped per the task brief).
//   * `StdAttr.MAPINFO`'s `ComponentMapInformationContainer` payload; same gap as `PortIo`; see
//     that file's header for the exact shape needed.

import Foundation
import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.std.io.ReptarLocalBus`.
public final class ReptarLocalBus: InstanceFactoryBase {

  /// `ReptarLocalBus._ID`.
  public static let id = "ReptarLB"

  private static let defaultLocalBusName = "LocalBus"

  public static let cs3Out = 0
  public static let advAleOut = 1
  public static let reOeOut = 2
  public static let weOut = 3
  public static let wait3In = 4
  public static let addrDataOut = 5
  public static let addrDataIn = 6
  public static let addrDataTrisIn = 7
  public static let addrOut = 8
  public static let irqIn = 9

  /// `ReptarLocalBus.getInputLabel(int)`.
  public static func inputLabel(_ id: Int) -> String {
    if id < 5 {
      switch id {
      case 0: return "SP6_LB_nCS3_i"
      case 1: return "SP6_LB_nADV_ALE_i"
      case 2: return "SP6_LB_RE_nOE_i"
      case 3: return "SP6_LB_nWE_i"
      default: break
      }
    }
    if id < 13 { return "Addr_LB_i_\(id + 11)" }
    return "Undefined"
  }

  /// `ReptarLocalBus.getOutputLabel(int)`.
  public static func outputLabel(_ id: Int) -> String {
    switch id {
    case 0: return "SP6_LB_WAIT3_o"
    case 1: return "IRQ_o"
    default: return "Undefined"
    }
  }

  /// `ReptarLocalBus.getIoLabel(int)`.
  public static func ioLabel(_ id: Int) -> String {
    id < 16 ? "Addr_Data_LB_io_\(id)" : "Undefined"
  }

  public init() {
    super.init(ReptarLocalBus.id, displayName: "Reptar Local Bus", requiresGlobalClock: true)
    setAttributes([
      StdAttr.label.binding(ReptarLocalBus.defaultLocalBusName),
      StdAttr.mapInfo.binding(nil),  // see the file header
    ])
    setOffsetBounds(Bounds.create(-110, -10, 110, 110))

    setPorts([
      Port(0, 0, .output, 1),
      Port(0, 10, .output, 1),
      Port(0, 20, .output, 1),
      Port(0, 30, .output, 1),
      Port(0, 40, .input, 1),
      Port(0, 50, .output, 16),
      Port(0, 60, .input, 16),
      Port(0, 70, .input, 1),
      Port(0, 80, .output, 9),
      Port(0, 90, .input, 1),
    ])
  }

  /// `ReptarLocalBus.createComponent`: `attrs.setReadOnly(StdAttr.LABEL, true)`. This board
  /// adapter's name is load-bearing for (not-ported) HDL generation, so upstream locks it
  /// against editing at placement time.
  public override func createComponent(
    location: Location, attributes: any AttributeSet
  ) throws -> any Component {
    attributes.setReadOnly(StdAttr.label, true)
    return try super.createComponent(location: location, attributes: attributes)
  }

  /// `ReptarLocalBus.propagate`: see the file header: unimplemented upstream too.
  public enum NotImplementedError: Error, CustomStringConvertible {
    case reptarLocalBusSimulation
    public var description: String { "Reptar Local Bus simulation not implemented" }
  }

  public override func propagate(_ state: any InstanceState) throws {
    throw NotImplementedError.reptarLocalBusSimulation
  }

  // MARK: - Paint (D6)

  /// `paintInstance(InstancePainter)`; `ReptarLocalBus.java:141-169`.
  ///
  /// Just a labelled box: every port draws its own signal name to the west of its marker, in a
  /// font two points smaller than the ambient one. The commented-out arrow-glyph block at the
  /// end of the Java is left commented out here too rather than resurrected.
  ///
  /// Note the label strings are the **`_o`/`_i` suffixed** forms and do not all match the
  /// `getInputLabel`/`getOutputLabel` names this class already carries for HDL: `IRQ_i` here vs.
  /// `IRQ_o` there, and `SP6_LB_nCS3_o` here vs. `SP6_LB_nCS3_i` there. The suffix is relative
  /// to opposite ends of the connection, and upstream is consistent about that; transcribed as
  /// written rather than unified.
  public func paintInstance(_ painter: any IoInstancePainter) {
    let g = painter.scene
    g.color = painter.componentColor
    g.font = g.font.withSize(g.font.size - 2)

    painter.drawBounds()
    painter.drawPort(ReptarLocalBus.cs3Out, "SP6_LB_nCS3_o", .west)
    painter.drawPort(ReptarLocalBus.advAleOut, "SP6_LB_nADV_ALE_o", .west)
    painter.drawPort(ReptarLocalBus.reOeOut, "SP6_LB_RE_nOE_o", .west)
    painter.drawPort(ReptarLocalBus.weOut, "SP6_LB_nWE_o", .west)
    painter.drawPort(ReptarLocalBus.wait3In, "SP6_LB_WAIT3_i", .west)
    painter.drawPort(ReptarLocalBus.addrDataOut, "Addr_Data_LB_o", .west)
    painter.drawPort(ReptarLocalBus.addrDataIn, "Addr_Data_LB_i", .west)
    painter.drawPort(ReptarLocalBus.addrDataTrisIn, "Addr_Data_LB_tris_i", .west)
    painter.drawPort(ReptarLocalBus.addrOut, "Addr_LB_o", .west)
    painter.drawPort(ReptarLocalBus.irqIn, "IRQ_i", .west)
  }
}

extension ReptarLocalBus: IoPaintable {}
