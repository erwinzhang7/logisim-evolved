// FpArithmeticLibrary.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.arith.floating.FPArithmeticLibrary),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── `FactoryDescription` is not ported ───────────────────────────────────────────────────────
//
// As in `ArithmeticLibrary`/`PlexersLibrary`/`MemoryLibrary`: upstream's `DESCRIPTIONS` array is
// the lazy/reflective machinery behind JAR-loaded libraries (D11), used here only to defer
// loading each icon and factory class. This port holds live `ComponentFactory`s, so it collapses
// to a flat `AddTool(factory:)` list in upstream's declaration order, which is load-bearing,
// being the order the toolbar presents. `cachedTools` is memoized because `AddTool.sharesSource`
// and `Library.indexOf` compare factories by reference (D4).
//
// Note the last three entries use upstream's two-argument `FactoryDescription` (no icon file),
// which is a UI difference only and changes nothing here.
//
// ── This library is COMPLETE: all seventeen tools ───────────────────────────────────────────
//
// Unlike `ArithmeticLibrary`, which publishes twelve of thirteen because D15 waives the integer
// `Exponentiator`, every component upstream declares is present here. In particular
// `FpExponentiator` **is** ported: it computes `Math.pow`/`exp`/`expm1` on `double`s and has no
// arbitrary-precision dependency, so D15's waiver, which is specifically about
// `BigInteger.pow` in `com.cburch.logisim.std.arith.Exponentiator`, does not reach it. The long
// note at the top of `FpExponentiator.swift` exists so that distinction survives.
//
// ── The `_ID` strings ────────────────────────────────────────────────────────────────────────
//
// Checked one by one against the Java, because a typo does not error; the component falls
// through to D8's opaque-placeholder path and the file looks corrupt to the user. Two traps in
// this set:
//
//   * The class names are `FpAdder`, `FpToFp`, `IntToFp` … but the `_ID`s are `FPAdder`,
//     `FPToFP`, `IntToFP`: capital `FP`, and inconsistently so. `IntToFp` is the worst: `Int`
//     keeps its lowercase tail while `FP` is capitalised, in the same identifier.
//   * `FPSquareRoot`, `FPMinMax`, `FPToInt` are single words with no separator, unlike the
//     plexers' `"Priority Encoder"`.
//
// ── What did not come across ─────────────────────────────────────────────────────────────────
//
//   * `getDisplayName()`'s localisation (`S.get("fpArithmeticLibrary")`); D5/D9's precedent;
//     the string itself DOES come across; it lives with the library's identity in
//     `LogisimFile/Builtin.swift`'s `BuiltinLibraryShell` table, because that shell, not
//     this class, is the `Library` object the loader hands to the app. This class is
//     registered only as a tool provider.
//   * The `.gif` icon filenames threaded through `FactoryDescription`: M6 (D6).
//   * No HDL: `std/arith/floating` ships no `*HdlGeneratorFactory` at all, so unlike the plexers
//     there is nothing here to strip.

import Foundation
import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.std.arith.floating.FPArithmeticLibrary`.
public final class FpArithmeticLibrary: Library {

  /// `FPArithmeticLibrary._ID`. Do not change: `.circ` files reference it via
  /// `<lib desc="#FPArithmetic">`.
  public override class var libraryId: String { "FPArithmetic" }

  private lazy var cachedTools: [Tool] = [
    // Upstream's `DESCRIPTIONS`, in order.
    AddTool(factory: FpAdder()),  // FPAdder
    AddTool(factory: FpSubtractor()),  // FPSubtractor
    AddTool(factory: FpMultiplier()),  // FPMultiplier
    AddTool(factory: FpDivider()),  // FPDivider
    AddTool(factory: FpNegator()),  // FPNegator
    AddTool(factory: FpExponentiator()),  // FPExponentiator
    AddTool(factory: FpLogarithm()),  // FPLogarithm
    AddTool(factory: FpSquareRoot()),  // FPSquareRoot
    AddTool(factory: FpAbsolute()),  // FPAbsolute
    AddTool(factory: FpComparator()),  // FPComparator
    AddTool(factory: FpMinMax()),  // FPMinMax
    AddTool(factory: FpRound()),  // FPRound
    AddTool(factory: FpTrigonometry()),  // FPTrigonometry
    AddTool(factory: FpClassificator()),  // FPClassificator
    AddTool(factory: FpToFp()),  // FPToFP
    AddTool(factory: FpToInt()),  // FPToInt
    AddTool(factory: IntToFp()),  // IntToFP
  ]

  public override var tools: [Tool] { cachedTools }
}
