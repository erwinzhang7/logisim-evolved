// Ttl7404.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.ttl.Ttl7404),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

/// TTL 74x04: hex inverter gate.
///
/// `open`, not `final`: `Ttl7414` (Schmitt-trigger hex inverter) and `Ttl7419` (single Schmitt
/// inverter + 5 plain, per upstream) both extend this class unchanged; Logisim does not model
/// Schmitt hysteresis, so their logic is identical to this one's.
open class Ttl7404: AbstractTtlGate {

  /// `Ttl7404._ID`. "Unique identifier of the tool, used as reference in project files. Do NOT
  /// change as it will prevent project files from loading.": upstream's own comment.
  ///
  /// **Deviation (mechanism).** `class var`, not `static let`: see `Ttl7400.id` for why:
  /// `Ttl7414`/`Ttl7419` override it. No behavioural difference from Java's independent `_ID`
  /// fields.
  open class var id: String { "7404" }

  private static let pinCount = 14
  private static let outPins = [2, 4, 6, 8, 10, 12]

  public convenience init() {
    self.init(Ttl7404.id)
  }

  /// `Ttl7404(String name)`; kept so `Ttl7414`/`Ttl7419` can reuse this geometry under their
  /// own name.
  public init(_ name: String) {
    super.init(
      name,
      pins: Ttl7404.pinCount,
      outputPorts: Ttl7404.outPins,
      drawGates: true)
  }

  public override func propagateTtl(_ state: any InstanceState) throws {
    for i in stride(from: 1, to: 6, by: 2) {
      state.setPort(i, state.portValue(i - 1).not(), 1)
    }
    for i in stride(from: 6, to: 12, by: 2) {
      state.setPort(i, state.portValue(i + 1).not(), 1)
    }
  }

  open override func paintInternal(
    _ painter: SceneBuilder, _ state: any TtlPainter, x: Int, y: Int, height: Int, up: Bool
  ) {
    let portwidth = 12
    let portheight = 6
    let youtput = y + (up ? 20 : 40)
    Drawgates.paintNot(painter, x + 26, youtput, portwidth, portheight)
    Drawgates.paintOutputgate(
      painter, xpin: x + 30, y: y, xoutput: x + 26, youtput: youtput, up: up, height: height)
    Drawgates.paintSingleInputgate(
      painter, xpin: x + 10, y: y, xinput: x + 26 - portwidth, youtput: youtput, up: up,
      height: height)
  }
}
