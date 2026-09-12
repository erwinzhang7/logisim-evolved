// Ttl74244.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.ttl.Ttl74244),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// TTL 74x244: octal buffers and line drivers with three-state outputs. Model based on
// https://www.ti.com/product/SN74LS244 datasheet.

import Foundation
import LogisimFile
import LogisimKernel

public final class Ttl74244: AbstractOctalBuffers {

  /// `Ttl74244._ID`. "Unique identifier of the tool, used as reference in project files. Do NOT
  /// change as it will prevent project files from loading.", upstream's own comment.
  public static let id = "74244"

  public init() {
    super.init(
      Ttl74244.id,
      pins: 20,
      outputPorts: [3, 5, 7, 9, 12, 14, 16, 18],
      portNames: [
        "n1G", "1A1", "2Y4", "1A2", "2Y3", "1A3", "2Y2", "1A4", "2Y1",
        "2A1", "1Y4", "2A2", "1Y3", "2A3", "1Y2", "2A4", "1Y1", "n2G",
      ])
    setOutputInverted(false, false)
    setEnableInverted(true, true)
  }
}
