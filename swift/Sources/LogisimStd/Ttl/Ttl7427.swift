// Ttl7427.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.ttl.Ttl7427),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).

import Foundation
import LogisimFile
import LogisimKernel

/// TTL 74x27: triple 3-input NOR: `Ttl7410` with `inverted = true`, `isOR = true`.
public final class Ttl7427: Ttl7410 {

  /// `Ttl7427._ID`. "Unique identifier of the tool, used as reference in project files. Do NOT
  /// change as it will prevent project files from loading.", upstream's own comment.
  public override class var id: String { "7427" }

  public init() {
    super.init(Ttl7427.id, inverted: true, isOR: true)
  }
}
