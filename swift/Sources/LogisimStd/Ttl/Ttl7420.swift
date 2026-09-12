// Ttl7420.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.ttl.Ttl7420),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).

import Foundation
import LogisimFile
import LogisimKernel

/// TTL 74x20: dual 4-input NAND (no Schmitt trigger), identical logic to `Ttl7413`.
public final class Ttl7420: Ttl7413 {

  /// `Ttl7420._ID`. "Unique identifier of the tool, used as reference in project files. Do NOT
  /// change as it will prevent project files from loading.", upstream's own comment.
  public override class var id: String { "7420" }

  public init() {
    // Must call `Ttl7413`'s designated initializer directly; `Ttl7413(String)` is itself a
    // convenience initializer, and Swift forbids calling a superclass's convenience
    // initializer from a subclass. `inverted: true` reproduces upstream's default exactly.
    super.init(Ttl7420.id, inverted: true)
  }
}
