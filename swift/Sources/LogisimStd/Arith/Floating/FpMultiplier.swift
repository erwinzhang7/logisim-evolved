// FpMultiplier.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.arith.floating.FpMultiplier),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── The FMA must be fused ────────────────────────────────────────────────────────────────────
//
// In `fusedMultiplyAdd` mode upstream calls `Math.fma(a, b, c)`, which computes `a*b + c` with a
// **single** rounding; the exact product is kept to full width before the add. Writing
// `aValue * bValue + cValue` instead rounds twice and is a different function; it is the whole
// point of the mode existing, and the discrepancy shows up precisely when the product's low bits
// matter, which is when someone reaches for an FMA. Swift's `addingProduct` is the fused form:
// `c.addingProduct(a, b)` is `fma(a, b, c)`, with the receiver as the *addend*. Note the operand
// order is rotated relative to Java's; getting it backwards silently computes `a + b*c`.
//
// ── Ports depend on the mode ─────────────────────────────────────────────────────────────────
//
// `MUL_MODE` adds a fifth port, so this is one of the family's four components with a computed
// port list. Per PATTERNS.md the port list is a pure function of the attributes and upstream's
// `configurePorts(Instance)` / `instanceAttributeChanged` pair disappears: `StdInstanceComponent`
// recomputes and diffs, which reproduces exactly what upstream's `attr == MUL_MODE` filter did.
//
// **The index of the extra port is 4, after ERR, not 2.** Upstream numbers `IN2 = 4` and fills
// `ps[4]` first, so the array reads `[IN0, IN1, OUT, ERR, IN2]`. Appending IN2 in the middle
// would renumber ERR and OUT, and since `propagate` addresses ports by index the component would
// drive its error pin with the product.

import Foundation
import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.std.arith.floating.FpMultiplier`.
public final class FpMultiplier: InstanceFactoryBase {

  /// `FpMultiplier._ID`. Do not change, `.circ` files reference it.
  public static let id = "FPMultiplier"

  /// `PER_DELAY`.
  static let perDelay = 1

  public static let in0 = 0
  public static let in1 = 1
  public static let out = 2
  public static let err = 3
  /// `IN2`: the FMA addend. Present only in `fusedMultiplyAdd` mode; see the header on why it
  /// is numbered after ERR.
  public static let in2 = 4

  /// `FpMultiplier.MUL`.
  public static let mulOption = AttributeOption(value: "multiply")
  /// `FpMultiplier.FMA`.
  public static let fmaOption = AttributeOption(value: "fusedMultiplyAdd")
  /// `FpMultiplier.MUL_MODE`. The `.circ` token is `multiplyMode`.
  public static let mulMode: Attribute<AttributeOption> = Attributes.forOption(
    "multiplyMode", choices: [mulOption, fmaOption])

  public init() {
    super.init(FpMultiplier.id, displayName: "Floating Point Multiplier")
    setAttributes([
      FpArithmeticAttributes.fpWidth.binding(FpArithmeticAttributes.defaultFpWidth),
      FpMultiplier.mulMode.binding(FpMultiplier.mulOption),
    ])
    setOffsetBounds(Bounds.create(-40, -20, 40, 40))
    // No `setPorts`; upstream has none either; the list comes from `configurePorts`, which is
    // `ports(_:)` below.
  }

  /// `configurePorts(Instance)`.
  public override func ports(_ attributes: any AttributeSet) -> [Port] {
    let isFma =
      attributes[FpMultiplier.mulMode, default: FpMultiplier.mulOption] == FpMultiplier.fmaOption
    var ports: [Port] = [
      Port(-40, -10, .input, FpArithmeticAttributes.fpWidth),  // IN0
      Port(-40, 10, .input, FpArithmeticAttributes.fpWidth),  // IN1
      Port(0, 0, .output, FpArithmeticAttributes.fpWidth),  // OUT
      Port(-20, 20, .output, 1),  // ERR
    ]
    if isFma {
      ports.append(Port(-20, -20, .input, FpArithmeticAttributes.fpWidth))  // IN2
    }
    return ports
  }

  public override func propagate(_ state: any InstanceState) throws {
    let dataWidth = state.attributeValue(
      FpArithmeticAttributes.fpWidth, default: FpArithmeticAttributes.defaultFpWidth)
    let mulMode = state.attributeValue(FpMultiplier.mulMode, default: FpMultiplier.mulOption)

    let aValue = state.portValue(FpMultiplier.in0).toDoubleValueFromAnyFloat()
    let bValue = state.portValue(FpMultiplier.in1).toDoubleValueFromAnyFloat()

    let outValue: Double
    if mulMode == FpMultiplier.mulOption {
      outValue = aValue * bValue
    } else {
      let cValue = state.portValue(FpMultiplier.in2).toDoubleValueFromAnyFloat()
      // Java: `Math.fma(a_val, b_val, c_val)`. Receiver is the addend, see the header.
      outValue = cValue.addingProduct(aValue, bValue)
    }

    let delay = (dataWidth.width + 2) * FpMultiplier.perDelay
    state.setPort(FpMultiplier.out, Value.createKnownFloat(dataWidth, outValue), delay)
    state.setPort(
      FpMultiplier.err, Value.createKnown(BitWidth.known(1), outValue.isNaN ? 1 : 0), delay)
  }

  // PAINT (M6): the bounds box, the four fixed ports plus IN2 when in FMA mode, an "×" drawn as
  //             two crossing strokes at x-15…x-5, and the family's "F" glyph at x-35.
  //             See FpMultiplier.java:104-132.
}
