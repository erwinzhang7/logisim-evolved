// logisim-evolved: a native Swift/macOS port of logisim-evolution.
// Derived from logisim-evolution, which is GPL-3.0-only. This port is a derivative work and is
// therefore GPL-3.0-only.
// SPDX-License-Identifier: GPL-3.0-only
//
// Selecting an ordinary 64-bit Constant can end the process, and a smaller one loses digits.
//
// ── Where this came from, and what was and was not already proved ────────────────────────────
//
// An external fidelity review found it and was careful to state its own limit: its probes executed
// *extracted copies* of the production method bodies, and the user path was **source-traced, not
// executed**. That is the half this file closes: everything below drives the real
// `LogisimFileProjectHost.inspectorForm(for:)` on a real loaded document, so "a user can reach
// this" stops being an inference.
//
// ── The defect, which is four lines of `InspectorPane.swift` ─────────────────────────────────
//
//     case .integer(let value):
//       NumberField(value: Double(value), range: nil) { commit(.integer(Int($0.rounded()))) }
//
//     private static func format(_ value: Double) -> String {
//       value == value.rounded() ? String(Int(value)) : String(value)
//     }
//
// An `Int` attribute is routed **through `Double`** and back, which breaks in three ways:
//
//   * `String(Int(value))` inside `format`: for `Int.max` the `Double` rounds to 2^63, one above
//     `Int.max`, and `Int(_:)` is a partial function. It traps while the field is being
//     CONSTRUCTED, before any validation, so there is no catchable error and nothing to report.
//   * `Int($0.rounded())` in the commit callback: `NumberField` accepts `Double("NaN")` with no
//     finite check, and the conversion traps.
//   * `Double(value)` cannot represent odd integers above 2^53, so `9007199254740993` silently
//     becomes `…992`: and the callback then hands that wrong value onward as if the user typed it.
//
// ── 4.1.0 does none of this, which makes it a parity defect and not merely a robustness one ──
//
// Measured against `/Applications/Logisim-evolution.app/Contents/app/logisim-evolution-4.1.0-all.jar`
// by the review that found it: `0x7fffffffffffffff` displays as `0x7fffffffffffffff`,
// `0x20000000000001` displays exactly, and `NaN` is *rejected with a catchable
// `NumberFormatException`*. `Constant.ATTR_VALUE` really is `Attributes.forHexLong`, so a 64-bit
// value is ordinary and expected input, not an edge case someone has to go looking for.

import Foundation
import LogisimFile
import Testing
import UniformTypeIdentifiers

@testable import LogisimUI

/// A document holding one Constant at the largest value its own attribute type accepts.
private let constantAtIntMax = """
  <?xml version="1.0" encoding="UTF-8" standalone="no"?>
  <project source="4.1.0" version="1.0">
    <lib desc="#Base" name="0"/>
    <lib desc="#Wiring" name="1"/>
    <main name="main"/>
    <circuit name="main">
      <comp lib="1" loc="(120,100)" name="Constant">
        <a name="width" val="64"/>
        <a name="value" val="0x7fffffffffffffff"/>
      </comp>
    </circuit>
  </project>
  """

@Suite("Inspector — a 64-bit integer attribute survives being inspected")
@MainActor
struct InspectorIntegerFidelityTests {

  private func inspectTheConstant() throws -> InspectorForm {
    let host = try #require(
      LogisimFileProjectHostFactory().openProject(
        data: Data(constantAtIntMax.utf8), url: nil, contentType: LogisimDocumentType.circuit)
        as? LogisimFileProjectHost)
    let circuit = try #require(host.currentCircuitObject)
    let constant = try #require(circuit.nonWires.first)
    host.setSelection(.components([CircuitSceneSource.identity(of: constant)]))
    return host.inspectorForm(for: host.selection)
  }

  /// **The calibration, and it is the load-bearing half of this file.** The review that found this
  /// could only source-trace the user path; if the fixture does not actually produce an `.integer`
  /// row carrying the full value, every assertion below is about code no user reaches, and the
  /// finding would be latent rather than live. So the reachability is asserted first, explicitly.
  @Test("selecting the Constant really does produce an integer row holding the full 64-bit value")
  func theRowIsReachableAndHoldsTheValue() throws {
    let form = try inspectTheConstant()
    let integerValues: [Int] = form.sections.flatMap(\.rows).compactMap { row in
      if case .integer(let value) = row.value { return value }
      return nil
    }
    #expect(
      integerValues.contains(Int.max),
      """
      the inspector produced no integer row carrying 0x7fffffffffffffff, so this file is not \
      exercising the path the review described. Rows seen: \
      \(form.sections.flatMap(\.rows).map { "\($0.displayName): \($0.value)" })
      """)
  }

  /// **The crash.** `NumberField.format` is what the row's view calls while constructing itself.
  /// Before the fix this did not return a wrong string; it ended the process, so there is no
  /// "actual value" to compare against and reaching the assertion at all is the claim.
  @Test("formatting the largest 64-bit value returns a string instead of trapping")
  func formattingIntMaxDoesNotTrap() throws {
    let rendered = InspectorIntegerText.display(Int.max)
    #expect(
      !rendered.isEmpty,
      "the formatter produced nothing for Int.max; 4.1.0 shows 0x7fffffffffffffff")
  }

  /// The second trigger of the same unsafe boundary, on the commit side rather than the display
  /// side: `NumberField` has no finite check, so a typed `NaN` reaches `Int(_:)`.
  @Test("committing a non-finite value is refused rather than trapping")
  func committingNaNDoesNotTrap() throws {
    #expect(InspectorIntegerText.parse("NaN") == nil, "NaN was accepted as an integer")
    #expect(InspectorIntegerText.parse("inf") == nil, "infinity was accepted")
    #expect(InspectorIntegerText.parse("1e400") == nil, "an unrepresentable value was accepted")
    #expect(
      InspectorIntegerText.parse("3.7") == 4,
      "an ordinary decimal draft stopped round-tripping — the guard is too broad")
    #expect(InspectorIntegerText.parse("42") == 42, "an ordinary integer draft was refused")
  }

  /// **The silent one, which is worse than the crash.** A crash is at least noticed. This changes
  /// a student's constant by one and reports nothing: `Double` cannot represent odd integers above
  /// 2^53, and 4.1.0 displays the value exactly.
  @Test("an integer above 2^53 keeps every digit")
  func largeIntegersDoNotLosePrecision() throws {
    let awkward = 9_007_199_254_740_993  // 2^53 + 1, the smallest Int a Double cannot hold
    #expect(
      InspectorIntegerText.display(awkward) == "9007199254740993",
      """
      the inspector displays 9007199254740993 as 9007199254740992 — a digit changed with no \
      diagnostic, and the edit callback passes the wrong value onward. 4.1.0 shows it exactly.
      """)
  }
}
