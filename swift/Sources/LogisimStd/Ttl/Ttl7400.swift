// Ttl7400.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.ttl.Ttl7400),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// THE TEMPLATE FOR 65 CHIPS. A TTL chip is: an `_ID`, a pin count, the output pin numbers, and
// `propagateTtl`. Nothing else. Copy this file, change those four things, and stop.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

/// TTL 74x00: quad 2-input NAND gate.
///
/// `open`, not `final`: `Ttl7424` (74x24, same pin/port layout) extends this class in upstream
/// and is ported that way too, see `Ttl7424.swift`.
open class Ttl7400: AbstractTtlGate {

  /// `Ttl7400._ID`. "Unique identifier of the tool, used as reference in project files. Do NOT
  /// change as it will prevent project files from loading.": upstream's own comment.
  ///
  /// **Deviation (mechanism).** A `class var`, not `static let`: Swift forbids a subclass from
  /// re-declaring a stored `static let` of the same name ("cannot override with a stored
  /// property"), which every other component in this module uses without incident because none
  /// of them are subclassed. `Ttl7424` overrides this one. Java has no such restriction,
  /// `_ID` fields are independent per class, not polymorphic, so this is purely a Swift
  /// name-resolution workaround with no behavioural difference: `Ttl7400.id` still reads
  /// "7400" and `Ttl7424.id` still reads "7424".
  open class var id: String { "7400" }

  private static let pinCount = 14
  /// Output pin numbers as printed on the package (1-based), NOT port indices.
  private static let outPins = [3, 6, 8, 11]

  public convenience init() {
    self.init(Ttl7400.id)
  }

  /// `Ttl7400(String name)`; upstream keeps this second constructor so a near-identical chip
  /// can reuse the geometry under its own name. Retained.
  public init(_ name: String) {
    super.init(
      name,
      pins: Ttl7400.pinCount,
      outputPorts: Ttl7400.outPins,
      drawGates: true)
  }

  /// Four NAND gates. The indices are *port* indices, and the two loops exist because the two
  /// rows of the package run in opposite directions:
  ///
  ///   * lower row (pins 1-6 → ports 0-5): output at port `i`, inputs at `i-1` and `i-2`;
  ///   * upper row (pins 8-13 → ports 6-11): output at port `i`, inputs at `i+1` and `i+2`.
  ///
  /// Port 12 is GND and port 13 is Vcc when `VCC_GND` is on; neither is touched here, because
  /// `AbstractTtlGate.propagate` has already checked them.
  public override func propagateTtl(_ state: any InstanceState) throws {
    for i in stride(from: 2, to: 6, by: 3) {
      state.setPort(i, state.portValue(i - 1).and(state.portValue(i - 2)).not(), 1)
    }
    for i in stride(from: 6, to: 12, by: 3) {
      state.setPort(i, state.portValue(i + 1).and(state.portValue(i + 2)).not(), 1)
    }
  }

  /// One NAND (AND-with-bubble) gate per call; `drawGates` fans this out over four calls.
  open override func paintInternal(
    _ painter: SceneBuilder, _ state: any TtlPainter, x: Int, y: Int, height: Int, up: Bool
  ) {
    let portwidth = 19
    let portheight = 15
    let youtput = y + (up ? 20 : 40)
    Drawgates.paintAnd(painter, x + 40, youtput, portwidth - 4, portheight, true)
    Drawgates.paintOutputgate(
      painter, xpin: x + 50, y: y, xoutput: x + 44, youtput: youtput, up: up, height: height)
    Drawgates.paintDoubleInputgate(
      painter, rightPinX: x + 30, y: y, inputX: x + 44 - portwidth, outputY: youtput,
      portHeight: portheight, up: up, rightToLeft: false, height: height)
  }
}
