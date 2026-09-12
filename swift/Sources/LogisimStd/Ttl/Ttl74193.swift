// Ttl74193.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.ttl.Ttl74193),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// TTL 74x193: synchronous 4-bit up/down binary counter: same pin/port layout and logic as
// `Ttl74192`, just with `maxVal` 15 instead of 9 (binary instead of decade).

import Foundation
import LogisimFile
import LogisimKernel

public final class Ttl74193: Ttl74192 {

  /// `Ttl74193._ID`. "Unique identifier of the tool, used as reference in project files. Do NOT
  /// change as it will prevent project files from loading.", upstream's own comment.
  public override class var id: String { "74193" }

  public init() {
    super.init(Ttl74193.id, maxVal: 15)
  }
}
