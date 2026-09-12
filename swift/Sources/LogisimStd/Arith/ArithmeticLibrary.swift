// ArithmeticLibrary.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.arith.ArithmeticLibrary),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── `FactoryDescription` is not ported ───────────────────────────────────────────────────────
//
// Same reasoning as `WiringLibrary.swift`/`IoLibrary.swift`/`MemoryLibrary.swift`: upstream
// routes all thirteen of its tools through `FactoryDescription`, the lazy/reflective machinery
// behind JAR-loaded libraries (D11), purely to defer loading each icon and factory class until
// the toolbar needs it. This port always holds a live `ComponentFactory`, so `DESCRIPTIONS`
// collapses into one flat list built with `AddTool(factory:)`, in upstream's declaration order.
// `cachedTools` is memoized for the identity reason `MemoryLibrary` documents: `AddTool
// .sharesSource` and `Library.indexOf` compare factories by reference (D4), so rebuilding the
// array per access would hand out a fresh, non-`===`-matching `AddTool` on every read.
//
// ── NOT PORTED: `Exponentiator`; one of the thirteen tools is missing here ──────────────────
//
// `com.cburch.logisim.std.arith.Exponentiator` is **deliberately absent**, and so is its entry
// in the list below. D15 waives it: `Exponentiator.java:73` computes `aa.pow(b)` on a
// `BigInteger`, which is unbounded (`3^100` alone is 5.15e47) and therefore cannot be expressed
// with `Int128`, `UInt128`, or any other fixed-width type Swift's standard library offers. It is
// blocked on an arbitrary-precision integer dependency, not on transcription effort.
//
// **The observable consequence, stated so it stays visible:** a `.circ` containing
// `<comp lib="…" name="Exponentiator">` will fail to resolve its component, and this library
// publishes twelve tools where upstream publishes thirteen. That is the intended failure mode:
// a loud gap rather than a silently wrong exponent. Restore the entry between `Negator` and
// `SquareRoot` (upstream's position) when the big-integer dependency lands.
//
// ── NOT PORTED: the `arith/floating` subpackage (18 files) ───────────────────────────────────
//
// `com.cburch.logisim.std.arith.floating`, the IEEE-754 component family (`FpAdder`,
// `FpSubtractor`, `FpMultiplier`, `FpDivider`, `FpNegator`, `FpComparator`, `FpToInt`,
// `IntToFp`, and their HDL/support files), is out of scope for this slice and is not ported
// anywhere in this module. It is a **separate library** upstream, `FPArithmeticLibrary` with
// `_ID = "FPArithmetic"` (`Builtin.fpArithmeticId`), so its absence does not perturb this
// library's tool list; `Builtin` still resolves `<lib desc="#FPArithmetic">` through a
// `BuiltinLibraryShell` with an empty tool list. Recorded here rather than left silent because
// this is the only `arith` file a reader would think to check.
//
// ── What did not come across ─────────────────────────────────────────────────────────────────
//
//   * `getDisplayName()`'s localisation (`S.get("arithmeticLibrary")`); D5/D9's precedent;
//     the string itself DOES come across; it lives with the library's identity in
//     `LogisimFile/Builtin.swift`'s `BuiltinLibraryShell` table, because that shell, not
//     this class, is the `Library` object the loader hands to the app. This class is
//     registered only as a tool provider.
//   * The `.gif` icon filenames threaded through `FactoryDescription`, M6 (D6).

import Foundation
import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.std.arith.ArithmeticLibrary`.
public final class ArithmeticLibrary: Library {

  /// `ArithmeticLibrary._ID`. Do not change: `.circ` files reference it via
  /// `<lib desc="#Arithmetic">`.
  public override class var libraryId: String { "Arithmetic" }

  private lazy var cachedTools: [Tool] = [
    // Upstream's `DESCRIPTIONS`, in order, resolved eagerly instead of through
    // `FactoryDescription`.
    AddTool(factory: Adder()),
    AddTool(factory: Subtractor()),
    AddTool(factory: Multiplier()),
    AddTool(factory: Divider()),
    AddTool(factory: Negator()),
    // `Exponentiator` belongs HERE: see the file header (D15).
    AddTool(factory: SquareRoot()),
    AddTool(factory: Absolute()),
    AddTool(factory: Comparator()),
    AddTool(factory: MinMax()),
    AddTool(factory: Shifter()),
    AddTool(factory: BitAdder()),
    AddTool(factory: BitFinder()),
  ]

  public override var tools: [Tool] { cachedTools }
}
