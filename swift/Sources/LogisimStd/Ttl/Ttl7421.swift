// Ttl7421.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.ttl.Ttl7421),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).

import Foundation
import LogisimFile
import LogisimKernel

/// TTL 74x21: dual 4-input AND, `Ttl7413` with `inverted = false`.
public final class Ttl7421: Ttl7413 {

  /// `Ttl7421._ID`. "Unique identifier of the tool, used as reference in project files. Do NOT
  /// change as it will prevent project files from loading.", upstream's own comment.
  public override class var id: String { "7421" }

  public init() {
    super.init(Ttl7421.id, inverted: false)
  }
}
