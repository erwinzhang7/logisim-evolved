// Ttl74240.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.ttl.Ttl74240),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// TTL 74x240: octal buffers and line drivers with three-state inverted outputs. Model based on
// https://www.ti.com/product/SN74LS240 datasheet.

import Foundation
import LogisimFile
import LogisimKernel

public final class Ttl74240: AbstractOctalBuffers {

  /// `Ttl74240._ID`. "Unique identifier of the tool, used as reference in project files. Do NOT
  /// change as it will prevent project files from loading.", upstream's own comment.
  public static let id = "74240"

  public init() {
    super.init(
      Ttl74240.id,
      pins: 20,
      outputPorts: [3, 5, 7, 9, 12, 14, 16, 18],
      portNames: [
        "n1G", "1A1", "n2Y4", "1A2", "n2Y3", "1A3", "n2Y2", "1A4", "n2Y1",
        "2A1", "n1Y4", "2A2", "n1Y3", "2A3", "n1Y2", "2A4", "n1Y1", "n2G",
      ])
    setOutputInverted(true, true)
    setEnableInverted(true, true)
  }
}
