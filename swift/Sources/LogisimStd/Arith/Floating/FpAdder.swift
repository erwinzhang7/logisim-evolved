// FpAdder.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.arith.floating.FpAdder),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── The template for the whole floating-point family ─────────────────────────────────────────
//
// Thirteen of the seventeen components in `std/arith/floating` are exactly this file with a
// different operator: read the ports as `double`, apply one operation, write the result back at
// FP_WIDTH and raise ERR when the *result* is NaN. Read this one and the rest are skimmable.
//
// Four things are load-bearing and repeat in every sibling:
//
//   * **`toDoubleValueFromAnyFloat()` is the only decode.** It dispatches on the value's own
//     width, 8 → MiniFloat(1,4,3), 16 → binary16, 32 → binary32, 64 → binary64, and returns
//     NaN for any other width, including a floating (`NIL`) or partly-unknown input. The
//     component never inspects FP_WIDTH to decode; it reads whatever the wire actually carries.
//     That is upstream's behaviour and it is what makes a mismatched-width wire show up as NaN
//     on ERR rather than as a width error.
//   * **Everything is computed in `double`, then narrowed once** by
//     `Value.createKnownFloat(BitWidth, Double)`. At FP_WIDTH 8/16/32 that is a real rounding
//     step (`double` → `float` → the target format), so the intermediate is *not* the format
//     the component claims to be. Upstream is the same; do not "fix" it by computing in `Float`.
//   * **ERR is `Double.isNaN(out_val)`, on the OUTPUT, not the inputs.** So `∞ + -∞` raises ERR
//     while `∞ + 1` does not, and a NaN input propagates to ERR only because it propagates to
//     the output. `FpComparator`, `FpMinMax` and `FpTrigonometry` deliberately test the inputs
//     instead; those are the exceptions, and each says so.
//   * **The delay is `(FP_WIDTH + 2) * PER_DELAY`**, i.e. it tracks the *format* width, not the
//     width of anything on the wire.
//
// ── Equality note (once for the family) ──────────────────────────────────────────────────────
//
// Where a sibling compares an `AttributeOption` (`mode == ARB`), Java is comparing singleton
// references and this port compares `(name, payload)` structurally. Safe for the same reason
// `Comparator.swift` records: each file declares its options with distinct names and never
// constructs a third. See PATTERNS.md, "Equality".

import Foundation
import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.std.arith.floating.FpAdder`.
public final class FpAdder: InstanceFactoryBase {

  /// `FpAdder._ID`. Do not change, `.circ` files reference it.
  public static let id = "FPAdder"

  /// `PER_DELAY`.
  static let perDelay = 1

  // Port indices, keeping upstream's names.
  public static let in0 = 0
  public static let in1 = 1
  public static let out = 2
  public static let err = 3

  public init() {
    super.init(FpAdder.id, displayName: "Floating Point Adder")
    setAttributes([
      FpArithmeticAttributes.fpWidth.binding(FpArithmeticAttributes.defaultFpWidth)
    ])
    setOffsetBounds(Bounds.create(-40, -20, 40, 40))
    setPorts([
      Port(-40, -10, .input, FpArithmeticAttributes.fpWidth),  // IN0
      Port(-40, 10, .input, FpArithmeticAttributes.fpWidth),  // IN1
      Port(0, 0, .output, FpArithmeticAttributes.fpWidth),  // OUT
      Port(-20, 20, .output, 1),  // ERR
    ])
    // `setKeyConfigurator(new BitWidthConfigurator(FP_WIDTH))` / `setIcon`, UI (D9) and M6.
  }

  public override func propagate(_ state: any InstanceState) throws {
    let dataWidth = state.attributeValue(
      FpArithmeticAttributes.fpWidth, default: FpArithmeticAttributes.defaultFpWidth)

    let aValue = state.portValue(FpAdder.in0).toDoubleValueFromAnyFloat()
    let bValue = state.portValue(FpAdder.in1).toDoubleValueFromAnyFloat()

    let outValue = aValue + bValue

    let delay = (dataWidth.width + 2) * FpAdder.perDelay
    state.setPort(FpAdder.out, Value.createKnownFloat(dataWidth, outValue), delay)
    state.setPort(FpAdder.err, Value.createKnown(BitWidth.known(1), outValue.isNaN ? 1 : 0), delay)
  }

  // NOT PORTED: no HDL generator exists for this family upstream; `std/arith/floating` has no
  //             `*HdlGeneratorFactory`, unlike `std/plexers` and the integer `std/arith`.
  // PAINT (M6): the bounds box, all four ports, a "+" drawn as two strokes at (x-15…x-5, y) and
  //             (x-10, y-5…y+5), plus the family's three-stroke "F" glyph at x-35. See
  //             FpAdder.java:65-85.
}
