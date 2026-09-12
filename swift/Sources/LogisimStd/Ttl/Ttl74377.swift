// Ttl74377.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.ttl.Ttl74377),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).

import Foundation
import LogisimFile
import LogisimKernel

/// TTL 74x377: octal D flip-flop with clock enable (no async clear).
public final class Ttl74377: AbstractOctalFlops {

  /// `Ttl74377._ID`. "Unique identifier of the tool, used as reference in project files. Do NOT
  /// change as it will prevent project files from loading.", upstream's own comment.
  public static let id = "74377"

  public init() {
    super.init(
      Ttl74377.id,
      pins: 20,
      outputPorts: [2, 5, 6, 9, 12, 15, 16, 19],
      portNames: [
        "nCLKen", "Q1", "D1", "D2", "Q2", "Q3", "D3", "D4", "Q4", "CLK", "Q5", "D5", "D6", "Q6",
        "Q7", "D7", "D8", "Q8",
      ])
    setWe(true)
  }
}
