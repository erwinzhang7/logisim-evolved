// CircuitLabelValidator.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.circuit.CircuitLabelValidator),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only.
// SPDX-License-Identifier: GPL-3.0-only
//
// This is small but load-bearing at *load* time: `Circuit.mutatorAdd` clears a component's label
// when it collides with another, and it decides collision through here. Get the case rule wrong
// and a perfectly good `.circ` file loads with labels silently blanked, which then persists on
// the next save.
//
// ── Version note: this class does NOT exist in v4.1.0 ───────────────────────────────────────
//
// `CircuitLabelValidator.java` was added after the 4.1.0 release. At 4.1.0 every one of these
// comparisons is a hardcoded `String.equalsIgnoreCase` / `String.toUpperCase()` at the call site,
// with no HDL-type dependence at all; i.e. permanently `hdlCompatible`.
//
// D0 targets 4.1.0 and the oracle is the shipped 4.1.0 jar, so **`hdlCompatible` is the only
// identity 4.1.0 can produce**, and it is the default everywhere here. `caseSensitive` exists
// solely so the `main`-era behaviour has a name; nothing in the port selects it unless a caller
// sets `Circuit.hdlType` to a non-VHDL value, which no `.circ` file can do.
//
// One place where following `main` would have been a real defect rather than a harmless
// generalisation is documented on `Circuit.clearDuplicateLabel`: `main` made the circuit-name
// collision symmetric, and 4.1.0's is deliberately not.

import Foundation

/// `CircuitLabelValidator.LabelIdentity`.
public enum LabelIdentity: Sendable {
  /// Labels are compared case-insensitively, because VHDL identifiers are.
  case hdlCompatible
  /// Labels are compared exactly.
  case caseSensitive
}

/// `com.cburch.logisim.circuit.CircuitLabelValidator`.
public enum CircuitLabelValidator {

  /// `HdlGeneratorFactory.VHDL`.
  public static let vhdlHdlType = "VHDL"
  /// `HdlGeneratorFactory.VERILOG`.
  public static let verilogHdlType = "Verilog"

  /// `labelIdentityForHdlType(String)`.
  ///
  /// D9: upstream's callers read `AppPreferences.HdlType.get()`, which the model may not do. The
  /// string arrives as a parameter instead; `Circuit.labelIdentity` carries the shipped
  /// preference default (`VHDL`, `AppPreferences.java:556`), so behaviour on a default install is
  /// unchanged.
  public static func labelIdentity(forHdlType hdlType: String) -> LabelIdentity {
    hdlType == vhdlHdlType ? .hdlCompatible : .caseSensitive
  }

  /// `labelKey(String, LabelIdentity)`.
  ///
  /// `toUpperCase(Locale.ROOT)` is full (not simple) uppercase mapping and is locale-independent,
  /// which is exactly what Swift's `uppercased()` is.
  public static func labelKey(_ label: String, _ identity: LabelIdentity = .hdlCompatible)
    -> String
  {
    identity == .caseSensitive ? label : label.uppercased()
  }

  /// `labelsMatch(String, String, LabelIdentity)`.
  public static func labelsMatch(
    _ first: String, _ second: String, _ identity: LabelIdentity = .hdlCompatible
  ) -> Bool {
    identity == .caseSensitive ? first == second : javaEqualsIgnoreCase(first, second)
  }

  /// `String.equalsIgnoreCase`, reproduced rather than approximated with
  /// `caseInsensitiveCompare`.
  ///
  /// Java's rule is per-character and uses *simple* case mapping: for each pair it tries
  /// `Character.toUpperCase`, and if that does not settle it, `Character.toLowerCase` of the
  /// uppercased forms. A character whose uppercase form is not a single character, `ß`, whose
  /// uppercase is `SS`, is returned unchanged by `Character.toUpperCase(char)`, so Java says
  /// `"ß".equalsIgnoreCase("SS") == false`. Foundation's case-insensitive comparison and
  /// `String.uppercased()` both perform *full* mapping and would answer differently, which is
  /// why this is spelled out.
  ///
  /// Iterating Unicode scalars rather than UTF-16 code units is not a divergence: Java case-maps
  /// lone surrogates to themselves, so a non-BMP character compares by identity either way, and
  /// the length guard rejects the same pairs.
  static func javaEqualsIgnoreCase(_ first: String, _ second: String) -> Bool {
    if first == second { return true }
    let lhs = Array(first.unicodeScalars)
    let rhs = Array(second.unicodeScalars)
    guard lhs.count == rhs.count else { return false }
    for index in lhs.indices {
      let a = lhs[index]
      let b = rhs[index]
      if a == b { continue }
      let upperA = simpleUppercase(a)
      let upperB = simpleUppercase(b)
      if upperA == upperB { continue }
      if simpleLowercase(upperA) == simpleLowercase(upperB) { continue }
      return false
    }
    return true
  }

  /// `Character.toUpperCase(char)`; returns the argument unchanged when the uppercase mapping
  /// is not exactly one character.
  private static func simpleUppercase(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
    let mapped = String(scalar).uppercased().unicodeScalars
    guard mapped.count == 1, let only = mapped.first else { return scalar }
    return only
  }

  /// `Character.toLowerCase(char)`, with the same one-character restriction.
  private static func simpleLowercase(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
    let mapped = String(scalar).lowercased().unicodeScalars
    guard mapped.count == 1, let only = mapped.first else { return scalar }
    return only
  }
}
