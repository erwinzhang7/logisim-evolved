// Ttl7414.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.ttl.Ttl7414),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).

import Foundation
import LogisimFile
import LogisimKernel

/// TTL 74x14: hex Schmitt-trigger inverter; identical logic to `Ttl7404` (Logisim does not
/// model hysteresis), same pin layout, different name/label.
public final class Ttl7414: Ttl7404 {

  /// `Ttl7414._ID`. "Unique identifier of the tool, used as reference in project files. Do NOT
  /// change as it will prevent project files from loading.", upstream's own comment.
  public override class var id: String { "7414" }

  public init() {
    super.init(Ttl7414.id)
  }
}
