// Ttl7443.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.ttl.Ttl7443),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).

import Foundation
import LogisimFile
import LogisimKernel

/// TTL 74x43: excess-3-to-decimal decoder, `Ttl7442` with `encoding = 1`.
public final class Ttl7443: Ttl7442 {

  /// `Ttl7443._ID`. "Unique identifier of the tool, used as reference in project files. Do NOT
  /// change as it will prevent project files from loading.", upstream's own comment.
  public override class var id: String { "7443" }

  public init() {
    super.init(Ttl7443.id, encoding: 1)
  }
}
