// FpTrigonometry.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.arith.floating.FpTrigonometry),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// One input, three simultaneous outputs, and a mode attribute that changes only *which* three
// functions are computed; the port array never changes shape, so unlike `FpExponentiator` and
// `FpLogarithm` this one keeps a fixed `setPorts`. The transcendental accuracy caveat in
// JavaMath.swift applies to all nine functions.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// UPSTREAM BUG, PRESERVED: THE `sin` PIN IS DECLARED AN **INPUT**
//
//     ps[SIN] = new Port(0, -10, Port.INPUT, StdAttr.FP_WIDTH); // FpTrigonometry.java:76
//     …
//     state.setPort(SIN, sin, delay); // FpTrigonometry.java:158
//
// `TAN` and `COS`, its neighbours on the same edge, are both `Port.OUTPUT`. `SIN` is not, and
// `propagate` drives it anyway. This is a typo in upstream, and it is transcribed exactly,
// because the direction is not decoration: it decides whether the end is exclusive, how the
// wire-width resolver treats the node, and whether connecting a driver to that point is a
// conflict. A circuit saved against upstream behaves the way the *bug* behaves, so "fixing" it
// here would make this port disagree with every existing file that uses the component; the
// precise failure a fidelity port exists to avoid.
//
// If it is ever fixed upstream, this is the line to change, and it should change only in step
// with a version check.
// ═════════════════════════════════════════════════════════════════════════════════════════════
//
// ── ERR tests the INPUT ──────────────────────────────────────────────────────────────────────
//
// `Double.isNaN(a_val)`, necessarily: there are three results and one error pin. So `tan(π/2)`
// overflowing, or `asin(2)` being NaN for an in-range-looking input, leaves ERR low.

import Foundation
import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.std.arith.floating.FpTrigonometry`.
public final class FpTrigonometry: InstanceFactoryBase {

  /// `FpTrigonometry._ID`. Do not change, `.circ` files reference it.
  public static let id = "FPTrigonometry"

  /// `PER_DELAY`.
  static let perDelay = 1

  public static let inPort = 0
  public static let sin = 1
  public static let tan = 2
  public static let cos = 3
  public static let err = 4

  /// `FpTrigonometry.TRIG`, sin/tan/cos.
  public static let trigOption = AttributeOption(value: "trig")
  /// `FpTrigonometry.ARC`, asin/atan/acos.
  public static let arcOption = AttributeOption(value: "arc")
  /// `FpTrigonometry.HYP`, sinh/tanh/cosh.
  public static let hypOption = AttributeOption(value: "hyp")

  /// `FpTrigonometry.TRIG_MODE`. The `.circ` token is `type`, not `mode`: the two sibling
  /// mode attributes in this family use `mode`, and this one does not.
  public static let trigMode: Attribute<AttributeOption> = Attributes.forOption(
    "type", choices: [trigOption, arcOption, hypOption])

  public init() {
    super.init(FpTrigonometry.id, displayName: "Floating Point Trigonometry")
    setAttributes([
      FpArithmeticAttributes.fpWidth.binding(FpArithmeticAttributes.defaultFpWidth),
      FpTrigonometry.trigMode.binding(FpTrigonometry.trigOption),
    ])
    setOffsetBounds(Bounds.create(-40, -20, 40, 40))
    setPorts([
      Port(-40, 0, .input, FpArithmeticAttributes.fpWidth),  // IN
      // `.input` is NOT a transcription slip: see the banner above. Upstream declares the sin
      // pin an input and then drives it.
      Port(0, -10, .input, FpArithmeticAttributes.fpWidth),  // SIN
      Port(0, 0, .output, FpArithmeticAttributes.fpWidth),  // TAN
      Port(0, 10, .output, FpArithmeticAttributes.fpWidth),  // COS
      Port(-20, 20, .output, 1),  // ERR
    ])
  }

  public override func propagate(_ state: any InstanceState) throws {
    let dataWidth = state.attributeValue(
      FpArithmeticAttributes.fpWidth, default: FpArithmeticAttributes.defaultFpWidth)
    let mode = state.attributeValue(FpTrigonometry.trigMode, default: FpTrigonometry.trigOption)

    let aValue = state.portValue(FpTrigonometry.inPort).toDoubleValueFromAnyFloat()

    let sinValue: Double
    let tanValue: Double
    let cosValue: Double

    if mode == FpTrigonometry.trigOption {
      // Module-qualified: the port-index constants above are named `sin`, `tan` and `cos` (the
      // Java field names, kept), and inside the type they shadow the libm functions.
      sinValue = Foundation.sin(aValue)
      tanValue = Foundation.tan(aValue)
      cosValue = Foundation.cos(aValue)
    } else if mode == FpTrigonometry.arcOption {
      sinValue = asin(aValue)
      tanValue = atan(aValue)
      cosValue = acos(aValue)
    } else {
      sinValue = sinh(aValue)
      tanValue = tanh(aValue)
      cosValue = cosh(aValue)
    }

    let delay = (dataWidth.width + 2) * FpTrigonometry.perDelay
    state.setPort(FpTrigonometry.sin, Value.createKnownFloat(dataWidth, sinValue), delay)
    state.setPort(FpTrigonometry.tan, Value.createKnownFloat(dataWidth, tanValue), delay)
    state.setPort(FpTrigonometry.cos, Value.createKnownFloat(dataWidth, cosValue), delay)
    // Note: the INPUT is tested, not any of the three results. See the header.
    state.setPort(
      FpTrigonometry.err, Value.createKnown(BitWidth.known(1), aValue.isNaN ? 1 : 0), delay)
  }

  // PAINT (M6): the bounds box, IN and ERR, and SIN/TAN/COS labelled to the west per mode:
  //             "sin"/"tan"/"cos", "asin"/"atan"/"acos" or "sinh"/"tanh"/"cosh": plus the
  //             family's "F" glyph at x-35. See FpTrigonometry.java:89-121.
}
