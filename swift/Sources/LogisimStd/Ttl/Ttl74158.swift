// Ttl74158.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.ttl.Ttl74158),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// TTL 74x158: quadruple 2-line to 1-line data selector, inverted output. Model based on
// https://www.ti.com/product/SN74LS157 datasheet (74x158 is 74x157 with inverted outputs).

import Foundation
import LogisimFile
import LogisimKernel

public final class Ttl74158: Ttl74157 {

  /// `Ttl74158._ID`. "Unique identifier of the tool, used as reference in project files. Do NOT
  /// change as it will prevent project files from loading.", upstream's own comment.
  public override class var id: String { "74158" }

  public init() {
    super.init(Ttl74158.id, invertOutput: true)
  }
}
