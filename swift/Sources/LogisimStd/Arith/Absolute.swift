// Absolute.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.arith.Absolute),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// The `Adder` shape: fixed bounds, fixed ports, one attribute, all the interest in `propagate`.
// Upstream has no `computeResult` helper for this one, the arithmetic is inline, so it stays
// inline here too rather than being hoisted into a static the Java does not have.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

/// `com.cburch.logisim.std.arith.Absolute`.
public final class Absolute: InstanceFactoryBase {

  /// `Absolute._ID`. Do not change, `.circ` files reference it.
  public static let id = "Absolute"

  // Port indices, kept named per the arith-family convention (PATTERNS.md §4).
  public static let inPort = 0
  public static let out = 1
  public static let overflow = 2

  public init() {
    super.init(Absolute.id)
    // Java: `BitWidth.create(8)`: a literal, so the non-throwing `known` (D13).
    setAttributes([StdAttr.width.binding(BitWidth.known(8))])
    setOffsetBounds(Bounds.create(-40, -20, 40, 40))
    setPorts([
      Port(-40, 0, .input, StdAttr.width),  // IN
      Port(0, 0, .output, StdAttr.width),  // OUT
      Port(-20, 20, .output, 1),  // OVERFLOW
    ])
    // `setKeyConfigurator` / `setIcon` / the three `setToolTip` calls, UI (D9) and M6.
  }

  /// `Absolute.propagate(InstanceState)` (`Absolute.java:70-110`).
  ///
  /// D13: `Value.create([Value])` and `Value.getBitWidth()` both throw, so this throws.
  public override func propagate(_ state: any InstanceState) throws {
    let dataWidth = state.attributeValue(StdAttr.width, default: .one)

    let inValue = state.portValue(Absolute.inPort)
    let out: Value
    let overflowValue: Value

    if inValue.isFullyDefined() {
      let val = inValue.toSignExtendedLongValue()
      // Java's `-val` on a `long`; Swift's prefix `-` traps on `Int64.min`. `0 &- val` wraps the
      // way Java does, and the wrap is the whole point of the OVERFLOW port: at width 64 the
      // absolute value of `Long.MIN_VALUE` is itself, still negative, which is exactly what the
      // next line reports. Using `-` here would turn upstream's reported overflow into a crash.
      let result = val < 0 ? 0 &- val : val
      // `in.getBitWidth()`, not the WIDTH attribute; they differ whenever a mismatched-width
      // wire drives IN. Preserved. It throws only for a width outside 0...64, which
      // `isFullyDefined()` (width > 0) plus `Value`'s own 64-bit ceiling already rules out.
      out = Value.createKnown(try inValue.getBitWidth(), result)
      overflowValue = out.toSignExtendedLongValue() < 0 ? .trueValue : .falseValue
    } else {
      // The partially-defined path: walk up from bit 0 propagating a "fill" bit until the first
      // TRUE, which is the point at which two's-complement negation stops copying and starts
      // inverting. Note it does NOT then invert the remaining bits; the loop simply stops and
      // the high bits are emitted unchanged. That is upstream's approximation for an input it
      // cannot negate exactly, not an oversight this port should "finish".
      var bits = inValue.getAll()
      var fill: Value = .falseValue
      var pos = 0
      while pos < bits.count {
        if bits[pos] == .falseValue {
          bits[pos] = fill
        } else if bits[pos] == .trueValue {
          if fill != .falseValue { bits[pos] = fill }
          pos += 1
          break
        } else if bits[pos] == .errorValue {
          fill = .errorValue
        } else {
          if fill == .falseValue { fill = bits[pos] } else { bits[pos] = fill }
        }
        pos += 1
      }
      // `pos` is dead after the loop in Java too; the `pos++` before the `break` has no reader.
      // Kept so the loop body is a line-for-line transcription.
      _ = pos
      out = try Value.create(bits)
      overflowValue = .errorValue
    }

    let delay = (dataWidth.width + 2) * Adder.perDelay
    state.setPort(Absolute.out, out, delay)
    state.setPort(Absolute.overflow, overflowValue, delay)
  }

  // Deviation (mechanism): the `bits[pos] == Value.FALSE` / `TRUE` / `ERROR` comparisons are
  // reference equality in Java against interned width-1 singletons; `Value` here is a struct and
  // compares structurally. Safe for width-1 values; see PATTERNS.md's "Equality" section.
  //
  /// The "Abs" label is drawn in the *primary* colour (the secondary switch happens only
  /// afterward, before the unlabelled IN/OVERFLOW ports), upstream's own sequencing, preserved.
  public func paintInstance(_ painter: SceneBuilder, _ state: any InstanceState) {
    painter.color = ArithPaint.componentColor
    painter.drawBounds(state.component.bounds)
    ArithPaint.drawPort(painter, state, Absolute.out, label: "Abs", direction: .west)
    painter.color = ArithPaint.secondaryColor
    ArithPaint.drawPort(painter, state, Absolute.inPort)
    ArithPaint.drawPort(painter, state, Absolute.overflow)
  }
}
