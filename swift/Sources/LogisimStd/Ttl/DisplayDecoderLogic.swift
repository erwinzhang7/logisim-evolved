// DisplayDecoderLogic.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.ttl.DisplayDecoder: the two static
// decode helpers only), https://github.com/logisim-evolution/logisim-evolution. Copyright by
// the Logisim-evolution developers. This translation is a derivative work and is therefore
// GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// `DisplayDecoder` itself is a standalone `InstanceFactory`, its own `_ID` ("DisplayDecoder"),
// its own ports, its own `paintInstance`/`propagate`, not a 74xx chip, and out of scope for
// this file set (the 74xx range 7400-7448). It is ported here only as far as `Ttl7447` needs:
// the two `static` helpers that turn a BCD/excess-3/whatever input into seven-segment outputs
// with lamp-test/blanking overrides. If a later chip in this family (7448, 74247, 74248, ...)
// or the standalone `DisplayDecoder` component itself is ported, it should reuse these, not
// duplicate them.

import Foundation
import LogisimFile
import LogisimKernel

enum DisplayDecoderLogic {

  /// `DisplayDecoder.computeDisplayDecoderOutputs`. `inputValue` is the caller's pre-decoded
  /// 0-15 value (`Ttl7447` supplies it via `getDecVal`); `LT`/`BI`/`RBI` override it exactly as
  /// upstream, and the segment table below is transcribed case-for-case from the Java `switch`.
  ///
  /// **Deviation (mechanism).** Java compares `getPortValue(...) == Value.FALSE`, a reference
  /// comparison safe only because one-bit `Value`s are interned upstream. Every port compared
  /// here (`bi`, `lt`, `rbi`) is declared width 1, so structural comparison on the `Value`
  /// struct answers identically (PATTERNS.md §"Equality").
  static func computeOutputs(
    _ state: any InstanceState,
    inputValue: Int,
    aPortIndex: Int,
    bPortIndex: Int,
    cPortIndex: Int,
    dPortIndex: Int,
    ePortIndex: Int,
    fPortIndex: Int,
    gPortIndex: Int,
    ltPortIndex: Int,
    biPortIndex: Int,
    rbiPortIndex: Int
  ) {
    var value = inputValue
    if state.portValue(biPortIndex) == .falseValue {
      value = 15
    } else if state.portValue(ltPortIndex) == .falseValue {
      value = 8
    } else if state.portValue(rbiPortIndex) == .falseValue && value == 0 {
      value = 15
    }

    let delay = PlexersLibraryAttributes.delay

    // The output values are inverted (upstream's comment); segment "on" is Value.FALSE. Every
    // case below is a direct transcription of the Java `switch`.
    switch value {
    case 0:
      state.setPort(aPortIndex, .falseValue, delay)
      state.setPort(bPortIndex, .falseValue, delay)
      state.setPort(cPortIndex, .falseValue, delay)
      state.setPort(dPortIndex, .falseValue, delay)
      state.setPort(ePortIndex, .falseValue, delay)
      state.setPort(fPortIndex, .falseValue, delay)
      state.setPort(gPortIndex, .trueValue, delay)
    case 1:
      state.setPort(aPortIndex, .trueValue, delay)
      state.setPort(bPortIndex, .falseValue, delay)
      state.setPort(cPortIndex, .falseValue, delay)
      state.setPort(dPortIndex, .trueValue, delay)
      state.setPort(ePortIndex, .trueValue, delay)
      state.setPort(fPortIndex, .trueValue, delay)
      state.setPort(gPortIndex, .trueValue, delay)
    case 2:
      state.setPort(aPortIndex, .falseValue, delay)
      state.setPort(bPortIndex, .falseValue, delay)
      state.setPort(cPortIndex, .trueValue, delay)
      state.setPort(dPortIndex, .falseValue, delay)
      state.setPort(ePortIndex, .falseValue, delay)
      state.setPort(fPortIndex, .trueValue, delay)
      state.setPort(gPortIndex, .falseValue, delay)
    case 3:
      state.setPort(aPortIndex, .falseValue, delay)
      state.setPort(bPortIndex, .falseValue, delay)
      state.setPort(cPortIndex, .falseValue, delay)
      state.setPort(dPortIndex, .falseValue, delay)
      state.setPort(ePortIndex, .trueValue, delay)
      state.setPort(fPortIndex, .trueValue, delay)
      state.setPort(gPortIndex, .falseValue, delay)
    case 4:
      state.setPort(aPortIndex, .trueValue, delay)
      state.setPort(bPortIndex, .falseValue, delay)
      state.setPort(cPortIndex, .falseValue, delay)
      state.setPort(dPortIndex, .trueValue, delay)
      state.setPort(ePortIndex, .trueValue, delay)
      state.setPort(fPortIndex, .falseValue, delay)
      state.setPort(gPortIndex, .falseValue, delay)
    case 5:
      state.setPort(aPortIndex, .falseValue, delay)
      state.setPort(bPortIndex, .trueValue, delay)
      state.setPort(cPortIndex, .falseValue, delay)
      state.setPort(dPortIndex, .falseValue, delay)
      state.setPort(ePortIndex, .trueValue, delay)
      state.setPort(fPortIndex, .falseValue, delay)
      state.setPort(gPortIndex, .falseValue, delay)
    case 6:
      state.setPort(aPortIndex, .trueValue, delay)
      state.setPort(bPortIndex, .trueValue, delay)
      state.setPort(cPortIndex, .falseValue, delay)
      state.setPort(dPortIndex, .falseValue, delay)
      state.setPort(ePortIndex, .falseValue, delay)
      state.setPort(fPortIndex, .falseValue, delay)
      state.setPort(gPortIndex, .falseValue, delay)
    case 7:
      state.setPort(aPortIndex, .falseValue, delay)
      state.setPort(bPortIndex, .falseValue, delay)
      state.setPort(cPortIndex, .falseValue, delay)
      state.setPort(dPortIndex, .trueValue, delay)
      state.setPort(ePortIndex, .trueValue, delay)
      state.setPort(fPortIndex, .trueValue, delay)
      state.setPort(gPortIndex, .trueValue, delay)
    case 8:
      state.setPort(aPortIndex, .falseValue, delay)
      state.setPort(bPortIndex, .falseValue, delay)
      state.setPort(cPortIndex, .falseValue, delay)
      state.setPort(dPortIndex, .falseValue, delay)
      state.setPort(ePortIndex, .falseValue, delay)
      state.setPort(fPortIndex, .falseValue, delay)
      state.setPort(gPortIndex, .falseValue, delay)
    case 9:
      state.setPort(aPortIndex, .falseValue, delay)
      state.setPort(bPortIndex, .falseValue, delay)
      state.setPort(cPortIndex, .falseValue, delay)
      state.setPort(dPortIndex, .trueValue, delay)
      state.setPort(ePortIndex, .trueValue, delay)
      state.setPort(fPortIndex, .falseValue, delay)
      state.setPort(gPortIndex, .falseValue, delay)
    case 10:
      state.setPort(aPortIndex, .trueValue, delay)
      state.setPort(bPortIndex, .trueValue, delay)
      state.setPort(cPortIndex, .trueValue, delay)
      state.setPort(dPortIndex, .falseValue, delay)
      state.setPort(ePortIndex, .falseValue, delay)
      state.setPort(fPortIndex, .trueValue, delay)
      state.setPort(gPortIndex, .falseValue, delay)
    case 11:
      state.setPort(aPortIndex, .trueValue, delay)
      state.setPort(bPortIndex, .trueValue, delay)
      state.setPort(cPortIndex, .falseValue, delay)
      state.setPort(dPortIndex, .falseValue, delay)
      state.setPort(ePortIndex, .trueValue, delay)
      state.setPort(fPortIndex, .trueValue, delay)
      state.setPort(gPortIndex, .falseValue, delay)
    case 12:
      state.setPort(aPortIndex, .trueValue, delay)
      state.setPort(bPortIndex, .falseValue, delay)
      state.setPort(cPortIndex, .trueValue, delay)
      state.setPort(dPortIndex, .trueValue, delay)
      state.setPort(ePortIndex, .trueValue, delay)
      state.setPort(fPortIndex, .falseValue, delay)
      state.setPort(gPortIndex, .falseValue, delay)
    case 13:
      state.setPort(aPortIndex, .falseValue, delay)
      state.setPort(bPortIndex, .trueValue, delay)
      state.setPort(cPortIndex, .trueValue, delay)
      state.setPort(dPortIndex, .falseValue, delay)
      state.setPort(ePortIndex, .trueValue, delay)
      state.setPort(fPortIndex, .falseValue, delay)
      state.setPort(gPortIndex, .falseValue, delay)
    case 14:
      state.setPort(aPortIndex, .trueValue, delay)
      state.setPort(bPortIndex, .trueValue, delay)
      state.setPort(cPortIndex, .trueValue, delay)
      state.setPort(dPortIndex, .falseValue, delay)
      state.setPort(ePortIndex, .falseValue, delay)
      state.setPort(fPortIndex, .falseValue, delay)
      state.setPort(gPortIndex, .falseValue, delay)
    case 15:
      state.setPort(aPortIndex, .trueValue, delay)
      state.setPort(bPortIndex, .trueValue, delay)
      state.setPort(cPortIndex, .trueValue, delay)
      state.setPort(dPortIndex, .trueValue, delay)
      state.setPort(ePortIndex, .trueValue, delay)
      state.setPort(fPortIndex, .trueValue, delay)
      state.setPort(gPortIndex, .trueValue, delay)
    default:
      state.setPort(aPortIndex, .unknownValue, delay)
      state.setPort(bPortIndex, .unknownValue, delay)
      state.setPort(cPortIndex, .unknownValue, delay)
      state.setPort(dPortIndex, .unknownValue, delay)
      state.setPort(ePortIndex, .unknownValue, delay)
      state.setPort(fPortIndex, .unknownValue, delay)
      state.setPort(gPortIndex, .unknownValue, delay)
    }
  }

  /// `DisplayDecoder.getdecval`. Returns -1 when the BCD/excess-3 inputs are not all known
  /// (non-multibit mode), or the raw multibit value otherwise.
  static func getDecVal(
    _ state: any InstanceState,
    multibit: Bool,
    multibitInputIndex: Int,
    aIndex: Int,
    bIndex: Int,
    cIndex: Int,
    dIndex: Int
  ) -> Int {
    var decval = -1
    var powval = 0
    let inputIndex = [aIndex, bIndex, cIndex, dIndex]
    if !multibit
      && state.portValue(aIndex) != .unknownValue
      && state.portValue(bIndex) != .unknownValue
      && state.portValue(cIndex) != .unknownValue
      && state.portValue(dIndex) != .unknownValue
    {
      for i in 0..<4 {
        if state.portValue(inputIndex[i]) == .trueValue {
          powval |= 1 << i
        }
      }
      decval += powval + 1
    } else if multibit && state.portValue(multibitInputIndex) != .unknownValue {
      // ── UPSTREAM BUG, PRESERVED ──
      // Java's guard is `getPortValue(MultibitInputIndex) != Value.UNKNOWN`: a *reference*
      // comparison against the width-1 UNKNOWN singleton, while this port is declared width 4.
      // Two `Value`s of different width can never be the same object, so the guard is
      // vacuously true whenever `multibit` is set: it never actually checks the multibit input
      // for unknown/error bits. Structural comparison against a width-1 `.unknownValue` is
      // equally always-unequal for a width-4 operand (the `width` field alone differs), so the
      // branch is taken exactly as often here; the mechanism differs, the bug does not.
      // "Fixing" this would mean checking `isFullyDefined()` instead, which upstream does not.
      decval = Int(truncatingIfNeeded: state.portValue(multibitInputIndex).toLongValue())
    }
    return decval
  }
}
