// MinMax.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.arith.MinMax),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── The signedness default is NOT the same as Comparator's ───────────────────────────────────
//
// `MinMax` and `Comparator` share one attribute object (`Comparator.MODE_ATTR`) but declare
// different defaults for it: `Comparator` defaults to `SIGNED_OPTION` ("twosComplement"),
// `MinMax` to `UNSIGNED_OPTION` ("unsigned"). Defaults are gate-visible, `XmlWriter` writes an
// `<a name="mode">` element only when the value differs from the factory default, so copying
// Comparator's default here would flip which files carry the element and which do not.
// `Divider` and `Multiplier` also default to unsigned; `Comparator` is the odd one out.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

/// `com.cburch.logisim.std.arith.MinMax`.
public final class MinMax: InstanceFactoryBase {

  /// `MinMax._ID`. Do not change, `.circ` files reference it.
  public static let id = "MinMax"

  /// `MinMax.PER_DELAY`. Declared locally upstream rather than reusing `Adder.PER_DELAY`, even
  /// though both are 1; kept local for the same reason.
  static let perDelay = 1

  // Port indices, kept named per the arith-family convention (PATTERNS.md §4).
  public static let in0 = 0
  public static let in1 = 1
  public static let min = 2
  public static let max = 3

  public init() {
    super.init(MinMax.id, displayName: "Minimum and Maximum")
    // Java: `BitWidth.create(8)`: a literal (D13's non-throwing carve-out). See the file header
    // for why the mode default is `unsignedOption` and not `signedOption`.
    setAttributes([
      StdAttr.width.binding(BitWidth.known(8)),
      Comparator.modeAttr.binding(Comparator.unsignedOption),
    ])
    setOffsetBounds(Bounds.create(-40, -20, 40, 40))
    // Upstream fills `ps` by index, and the indices are NOT in declaration order; `ps[MAX]` is
    // assigned before `ps[MIN]`, so MIN (index 2) is the *upper* output at y = -10 and MAX
    // (index 3) the lower one at y = +10. Transcribed in index order, which is what `setPorts`
    // and `propagate` both address.
    setPorts([
      Port(-40, -10, .input, StdAttr.width),  // IN0
      Port(-40, 10, .input, StdAttr.width),  // IN1
      Port(0, -10, .output, StdAttr.width),  // MIN
      Port(0, 10, .output, StdAttr.width),  // MAX
    ])
  }

  /// `MinMax.propagate(InstanceState)` (`MinMax.java:90-129`).
  public override func propagate(_ state: any InstanceState) throws {
    let dataWidth = state.attributeValue(StdAttr.width, default: .one)
    // Deviation (mechanism): Java compares `AttributeOption`s by reference; this port's
    // `AttributeOption` is a `Hashable` struct with a distinct `name` per option, so the
    // structural comparison agrees. See PATTERNS.md's "Equality" section.
    let unsigned =
      state.attributeValue(Comparator.modeAttr, default: Comparator.unsignedOption)
      == Comparator.unsignedOption

    let a = state.portValue(MinMax.in0)
    let b = state.portValue(MinMax.in1)
    let minValue: Value
    let maxValue: Value

    if a.isFullyDefined() && b.isFullyDefined() {
      let minRaw: Int64
      let maxRaw: Int64
      if unsigned {
        // `Long.compareUnsigned(a, b)`; reinterpret both bit patterns as unsigned and compare.
        // Note upstream reads `toLongValue()` here (the raw masked bits) and
        // `toSignExtendedLongValue()` on the signed path; the two differ above bit `width - 1`.
        let aRaw = a.toLongValue()
        let bRaw = b.toLongValue()
        let aUnsigned = UInt64(bitPattern: aRaw)
        let bUnsigned = UInt64(bitPattern: bRaw)
        // Both comparisons are strict, so on a tie both fall to `b`, which equals `a` anyway.
        // Transcribed as-is rather than "balanced" into `<=`/`>=`.
        minRaw = aUnsigned < bUnsigned ? aRaw : bRaw
        maxRaw = aUnsigned > bUnsigned ? aRaw : bRaw
      } else {
        let aRaw = a.toSignExtendedLongValue()
        let bRaw = b.toSignExtendedLongValue()
        minRaw = Swift.min(aRaw, bRaw)
        maxRaw = Swift.max(aRaw, bRaw)
      }
      // Upstream passes `dataWidth.getWidth()` (the `int` overload), not `dataWidth` itself, so
      // the result is truncated to the WIDTH attribute even when the inputs were wider.
      minValue = Value.createKnown(dataWidth.width, minRaw)
      maxValue = Value.createKnown(dataWidth.width, maxRaw)
    } else {
      // Note: unlike most of the family there is no separate UNKNOWN branch. Any bit that is not
      // fully defined, X as well as E, produces ERROR on both outputs. Preserved.
      minValue = Value.createError(dataWidth)
      maxValue = Value.createError(dataWidth)
    }

    let delay = (dataWidth.width + 2) * MinMax.perDelay
    state.setPort(MinMax.min, minValue, delay)
    state.setPort(MinMax.max, maxValue, delay)
  }

  // NOT PORTED: `configureNewInstance`/`instanceAttributeChanged`; the only body is
  // `instance.fireInvalidated()`, a repaint request (M6). Neither ports nor bounds depend on any
  // attribute here, so nothing else is lost (PATTERNS.md §0).
  //
  /// Like `Comparator`, upstream never switches to the secondary colour here.
  public func paintInstance(_ painter: SceneBuilder, _ state: any InstanceState) {
    painter.color = ArithPaint.componentColor
    painter.drawBounds(state.component.bounds)
    ArithPaint.drawPort(painter, state, MinMax.in0)
    ArithPaint.drawPort(painter, state, MinMax.in1)
    ArithPaint.drawPort(painter, state, MinMax.min, label: "Min", direction: .west)
    ArithPaint.drawPort(painter, state, MinMax.max, label: "Max", direction: .west)
  }
}
