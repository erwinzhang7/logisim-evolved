// Ttl7442.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.ttl.Ttl7442),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── Deviation (mechanism) ────────────────────────────────────────────────────────────────────
// Java compares `getPortValue(i) == Value.TRUE`, a reference comparison safe here because every
// port this reads is declared width 1 and one-bit `Value`s are interned upstream (PATTERNS.md
// §"Equality"). Structural comparison on a `Value` struct answers identically.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

/// TTL 74x42: 4-line BCD-to-decimal decoder (one-of-ten, active low).
///
/// `open`, not `final`: `Ttl7443` (excess-3-to-decimal) and `Ttl7444` (Gray-to-decimal) extend
/// this class, changing only the decode table selected by `encoding`.
open class Ttl7442: AbstractTtlGate {

  /// `Ttl7442._ID`. "Unique identifier of the tool, used as reference in project files. Do NOT
  /// change as it will prevent project files from loading.": upstream's own comment.
  ///
  /// **Deviation (mechanism).** `class var`, not `static let`: see `Ttl7400.id` for why:
  /// `Ttl7443`/`Ttl7444` override it. No behavioural difference from Java's independent `_ID`
  /// fields.
  open class var id: String { "7442" }

  private static let pinCount = 16
  private static let outPins = [1, 2, 3, 4, 5, 6, 7, 9, 10, 11]
  private static let pinNames = [
    "O0", "O1", "O2", "O3", "O4", "O5", "O6", "O7", "O8", "O9", "D", "C", "B", "A",
  ]

  private let isExec3: Bool
  private let isGray: Bool

  /// Plain BCD-to-decimal (`encoding` 0).
  public convenience init() {
    self.init(Ttl7442.id, encoding: 0)
  }

  /// `Ttl7442(String name, int encoding)`: `encoding` 0 = BCD, 1 = excess-3, 2 = Gray, matching
  /// upstream's `isExec3`/`isGray` derivation exactly (anything else is neither).
  public init(_ name: String, encoding: Int) {
    self.isExec3 = encoding == 1
    self.isGray = encoding == 2
    super.init(
      name,
      pins: Ttl7442.pinCount,
      outputPorts: Ttl7442.outPins,
      portNames: Ttl7442.pinNames)
  }

  public override func propagateTtl(_ state: any InstanceState) throws {
    var decode = -1
    if !(state.portValue(13).isErrorValue() || state.portValue(13).isUnknown()) {
      decode = state.portValue(13) == .trueValue ? 1 : 0
      if !(state.portValue(12).isErrorValue() || state.portValue(12).isUnknown()) {
        decode |= state.portValue(12) == .trueValue ? 2 : 0
        if !(state.portValue(11).isErrorValue() || state.portValue(11).isUnknown()) {
          decode |= state.portValue(11) == .trueValue ? 4 : 0
          if !(state.portValue(10).isErrorValue() || state.portValue(10).isUnknown()) {
            decode |= state.portValue(10) == .trueValue ? 8 : 0
          } else {
            decode = -1
          }
        } else {
          decode = -1
        }
      } else {
        decode = -1
      }
    }

    if decode < 0 {
      for port in 0..<10 {
        state.setPort(port, .unknownValue, 1)
      }
    } else if isGray {
      // Gray-code decode table, transcribed as the literal (port, matching `decode`) pairs
      // upstream lists; the mapping is not `port == decode`, so no loop compaction here.
      state.setPort(0, decode == 2 ? .falseValue : .trueValue, 1)
      state.setPort(1, decode == 6 ? .falseValue : .trueValue, 1)
      state.setPort(2, decode == 7 ? .falseValue : .trueValue, 1)
      state.setPort(3, decode == 5 ? .falseValue : .trueValue, 1)
      state.setPort(4, decode == 4 ? .falseValue : .trueValue, 1)
      state.setPort(5, decode == 12 ? .falseValue : .trueValue, 1)
      state.setPort(6, decode == 13 ? .falseValue : .trueValue, 1)
      state.setPort(7, decode == 15 ? .falseValue : .trueValue, 1)
      state.setPort(8, decode == 14 ? .falseValue : .trueValue, 1)
      state.setPort(9, decode == 10 ? .falseValue : .trueValue, 1)
    } else {
      if isExec3 { decode -= 3 }
      // BCD/excess-3: port `i` goes low exactly when `decode == i`, so upstream's ten explicit
      // `decode == i ? FALSE : TRUE` lines collapse into one loop without changing behaviour.
      for port in 0..<10 {
        state.setPort(port, decode == port ? .falseValue : .trueValue, 1)
      }
    }
  }

  open override func paintInternal(
    _ painter: SceneBuilder, _ state: any TtlPainter, x: Int, y: Int, height: Int, up: Bool
  ) {
    paintBase(painter, state, drawName: false, ghost: false)
    painter.drawRect(x + 18, y + 10, 84, 18)
    var mask = 1
    for i in 0..<10 {
      painter.drawOval(x + 22 + i * 8, y + 28, 4, 4)
      painter.drawLine(
        x + 24 + i * 8, y + 32, x + 24 + i * 8,
        y + height - AbstractTtlGate.pinHeight - (i + 1) * 2)
      painter.drawString(String(i), x: x + 22 + i * 8, y: y + 26)
      if i < 4 {
        painter.drawString(String(mask), x: x + 27 + i * 20, y: y + 16)
        mask <<= 1
        painter.drawLine(x + 30 + i * 20, y + AbstractTtlGate.pinHeight, x + 30 + i * 20, y + 10)
      }
      if i < 7 {
        painter.drawLine(
          x + 10 + i * 20, y + height - AbstractTtlGate.pinHeight, x + 10 + i * 20,
          y + height - AbstractTtlGate.pinHeight - (i + 1) * 2)
        painter.drawLine(
          x + 10 + i * 20, y + height - AbstractTtlGate.pinHeight - (i + 1) * 2, x + 24 + i * 8,
          y + height - AbstractTtlGate.pinHeight - (i + 1) * 2)
      } else {
        let j = i == 7 ? 9 : (i == 9 ? 7 : 8)
        painter.drawLine(
          x + i * 20 - 30, y + AbstractTtlGate.pinHeight, x + i * 20 - 30,
          y + height - AbstractTtlGate.pinHeight - (j + 1) * 2)
        painter.drawLine(
          x + i * 20 - 30, y + height - AbstractTtlGate.pinHeight - (j + 1) * 2, x + 24 + j * 8,
          y + height - AbstractTtlGate.pinHeight - (j + 1) * 2)
      }
    }
  }
}
