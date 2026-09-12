// PinAttributes.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.wiring.PinAttributes),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── The one structurally unusual thing here: the attribute *list* changes shape ─────────────
//
// `getAttributes()` returns one of three lists depending on two other attributes' values:
//
//     type == INPUT && behavior == TRISTATE  ->  TRISTATE_ATTRIBUTES  (no ATTR_INITIAL)
//     type == INPUT                          ->  INPIN_ATTRIBUTES     (all ten)
//     type == OUTPUT                         ->  OUTPIN_ATTRIBUTES    (no ATTR_BEHAVIOR,
//                                                                      no ATTR_INITIAL)
//
// That is why `setValue` fires `fireAttributeListChanged()` on ATTR_TYPE and on any
// behavior change that crosses the TRISTATE boundary. It also means the `.circ` writer iterates a
// *different* attribute list for an output pin than for an input pin; an output pin never writes
// `behavior` or `initial`, whatever those fields hold. Get the list membership wrong and the
// round-trip gate moves.
//
// The comments `/*, Pin.ATTR_INITIAL */` and `/*Pin.ATTR_BEHAVIOR, */` in the Java are upstream's
// own; the attributes really are commented out of those two lists.
//
// ── Field hiding ────────────────────────────────────────────────────────────────────────────
//
// `PinAttributes.width` *hides* `ProbeAttributes.width` in Java (same name, same type, redeclared
// in the subclass) rather than overriding it. Swift has no stored-property hiding; see
// `ProbeAttributes.width`'s doc comment for why the single shared field is unobservable.

import Foundation
import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.std.wiring.PinAttributes` (package-private upstream).
public final class PinAttributes: ProbeAttributes {

  // MARK: The three attribute lists

  /// `PinAttributes.INPIN_ATTRIBUTES`.
  static let inputPinAttributes: [AnyAttribute] = [
    StdAttr.facing,
    Pin.attrType,
    StdAttr.width,
    Pin.attrBehavior,
    StdAttr.label,
    stdAttrLabelLocation,
    StdAttr.labelFont,
    RadixOption.attribute,
    ProbeAttributes.probeAppearance,
    Pin.attrInitial,
  ]

  /// `PinAttributes.TRISTATE_ATTRIBUTES`; `INPIN_ATTRIBUTES` minus `ATTR_INITIAL`. A tristate
  /// input has no reset value because its reset value is always `UNKNOWN`.
  static let tristateAttributes: [AnyAttribute] = [
    StdAttr.facing,
    Pin.attrType,
    StdAttr.width,
    Pin.attrBehavior,
    StdAttr.label,
    stdAttrLabelLocation,
    StdAttr.labelFont,
    RadixOption.attribute,
    ProbeAttributes.probeAppearance,
  ]

  /// `PinAttributes.OUTPIN_ATTRIBUTES`; no `ATTR_BEHAVIOR` and no `ATTR_INITIAL`. Behaviour is
  /// meaningless for an output pin; see the comment block at the foot of `Pin.swift`.
  static let outputPinAttributes: [AnyAttribute] = [
    StdAttr.facing,
    Pin.attrType,
    StdAttr.width,
    StdAttr.label,
    stdAttrLabelLocation,
    StdAttr.labelFont,
    RadixOption.attribute,
    ProbeAttributes.probeAppearance,
  ]

  // MARK: Fields — Java's field initialisers, verbatim

  /// `AttributeOption type = Pin.INPUT`.
  public var type: AttributeOption = Pin.input

  /// `AttributeOption behavior = Pin.SIMPLE`.
  public var behavior: AttributeOption = Pin.simple

  /// `Long initialValue = 0L`.
  public var initialValue: Int64 = 0

  public override init() {
    super.init()
    // `BitWidth width = BitWidth.ONE`: the subclass field initialiser, which in Java hides the
    // identically-initialised base field. Written explicitly so the intent survives the merge.
    width = .one
  }

  // MARK: AbstractAttributeSet

  /// `getAttributes()`.
  public override var attributes: [AnyAttribute] {
    type == Pin.input
      ? (behavior == Pin.tristate
        ? PinAttributes.tristateAttributes : PinAttributes.inputPinAttributes)
      : PinAttributes.outputPinAttributes
  }

  /// `getValue(Attribute<V>)`.
  public override func rawValue(_ attribute: AnyAttribute) -> AttributeValue? {
    if attribute === StdAttr.width { return StdAttr.width.encode(width) }
    if attribute === Pin.attrType { return Pin.attrType.encode(type) }
    if attribute === Pin.attrBehavior { return Pin.attrBehavior.encode(behavior) }
    if attribute === ProbeAttributes.probeAppearance {
      return ProbeAttributes.probeAppearance.encode(appearance)
    }
    if attribute === Pin.attrInitial { return Pin.attrInitial.encode(initialValue) }
    return super.rawValue(attribute)
  }

  /// `setValue(Attribute<V>, V)`.
  ///
  /// Two branches deliberately `return` early *without* the trailing
  /// `fireAttributeValueChanged`: `RadixOption.ATTRIBUTE` (because `super.setValue` already
  /// fired) and the `else` fall-through (same reason). Everything else falls through to the
  /// single fire at the bottom, with a null old value.
  public override func setRawValue(
    _ attribute: AnyAttribute, _ newValue: AttributeValue?
  ) throws {
    if attribute === StdAttr.width {
      guard let decoded = newValue.flatMap(StdAttr.width.decode) else {
        throw ComponentError.unsupportedAttributeValue(
          factory: Pin.id, attribute: attribute.name)
      }
      // Java compares `BitWidth` with `==`; `BitWidth.create` interns 0…64, so that is value
      // equality, which is what a Swift struct comparison already gives.
      if width == decoded { return }
      width = decoded
      // A wide pin drawn in the new style cannot fit binary digits, so it force-switches to hex.
      // Note this fires a *second* value-changed event (for `radix`) before the one for `width`,
      // and that the guard reads the freshly assigned `width`.
      if width.width > 8 && appearance == ProbeAttributes.appearEvolutionNew {
        try super.setRawValue(
          RadixOption.attribute, RadixOption.attribute.encode(.radix16))
      }
    } else if attribute === Pin.attrType {
      guard let decoded = newValue.flatMap(Pin.attrType.decode) else {
        throw ComponentError.unsupportedAttributeValue(
          factory: Pin.id, attribute: attribute.name)
      }
      if type == decoded { return }
      type = decoded
      // The attribute list differs between input and output pins, see the file header.
      fireAttributeListChanged()
    } else if attribute === Pin.attrBehavior {
      guard let decoded = newValue.flatMap(Pin.attrBehavior.decode) else {
        throw ComponentError.unsupportedAttributeValue(
          factory: Pin.id, attribute: attribute.name)
      }
      if behavior == decoded { return }
      // The list only changes when TRISTATE is entered or left; simple↔pullup↔pulldown do not
      // move `ATTR_INITIAL` in or out of the list.
      let attributeListChanged = behavior == Pin.tristate || decoded == Pin.tristate
      behavior = decoded
      if attributeListChanged { fireAttributeListChanged() }
    } else if attribute === ProbeAttributes.probeAppearance {
      guard let decoded = newValue.flatMap(ProbeAttributes.probeAppearance.decode) else {
        throw ComponentError.unsupportedAttributeValue(
          factory: Pin.id, attribute: attribute.name)
      }
      // Note this writes the *base class's* field directly rather than delegating to
      // `super.setValue`, so the base's own short-circuit and fire are bypassed and the single
      // fire at the bottom of this method covers it. Transcribed as written.
      if appearance == decoded { return }
      appearance = decoded
    } else if attribute === RadixOption.attribute {
      // ── UPSTREAM BUG, PRESERVED ──
      // At width 1 the requested radix is discarded and RADIX_2 is written instead: including
      // when the caller asked for RADIX_2 anyway, in which case `super.setValue` short-circuits
      // and nothing fires. So a 1-bit pin can never be shown in hex/decimal/float, and the
      // attribute table silently snaps back. "Fixing" it would let `radix="16"` persist on a
      // 1-bit pin and change `Probe.getOffsetBounds`, i.e. the component's bounds in saved
      // files.
      if width.width == 1 {
        try super.setRawValue(
          RadixOption.attribute, RadixOption.attribute.encode(.radix2))
      } else {
        try super.setRawValue(attribute, newValue)
      }
      return
    } else if attribute === Pin.attrInitial {
      guard let decoded = newValue.flatMap(Pin.attrInitial.decode) else {
        throw ComponentError.unsupportedAttributeValue(
          factory: Pin.id, attribute: attribute.name)
      }
      // ── UPSTREAM BUG, PRESERVED ──
      // Java writes `if (newInitial == initialValue) return;` on two boxed `Long`s, so this is a
      // *reference* comparison. `Long.valueOf` caches −128…127, so the short-circuit works for
      // small values and silently fails for everything else: re-setting `initial` to the value it
      // already holds re-assigns and fires a redundant change event once |value| > 127. The
      // effect is listener churn (a repaint, an undo entry), never a different stored value, so
      // it is cheap to reproduce exactly.
      if decoded == initialValue && (-128...127).contains(decoded) { return }
      initialValue = decoded
    } else {
      try super.setRawValue(attribute, newValue)
      return
    }
    fireAttributeValueChanged(attribute, value: newValue, oldValue: nil)
  }

  public override func makeCopyInstance() -> AbstractAttributeSet {
    PinAttributes()
  }

  public override func copyInto(_ destination: AbstractAttributeSet) {
    super.copyInto(destination)
    guard let destination = destination as? PinAttributes else { return }
    destination.type = type
    destination.behavior = behavior
    destination.initialValue = initialValue
  }

  // MARK: Pin-specific queries

  /// `isInput()`.
  public var isInput: Bool { type == Pin.input }

  /// `isOutput()`.
  public var isOutput: Bool { type == Pin.output }

  /// `defaultBitValue()`; what `Value.extendWidth` fills new high bits with when the pin gets
  /// wider.
  ///
  /// An output pin's extra bits are UNKNOWN (it is displaying whatever arrived); an input pin's
  /// are TRUE under pull-up and FALSE otherwise; note **tristate is not special-cased here**, so
  /// widening a tristate input fills with FALSE, not UNKNOWN, even though its *initial* value is
  /// UNKNOWN.
  public var defaultBitValue: Value {
    isOutput ? .unknownValue : (behavior == Pin.pullUp ? .trueValue : .falseValue)
  }

  /// `isClock()`; a pin counts as a clock for HDL/FPGA purposes if its label mentions "clk" or
  /// "clock", case-insensitively, anywhere.
  ///
  /// Java: `lbl.matches("(?i).*(clk|clock).*")`. `String.matches` anchors at both ends and the
  /// pattern is built only from `.` and literals, so this is a case-insensitive substring test:
  /// with one wrinkle preserved below: without `DOTALL`, `.` does not match a line terminator,
  /// and the match must consume the *whole* string, so a label containing **any** line terminator
  /// never matches however it is spelled. (`Pin` labels are single-line in the UI, so this only
  /// shows up for a `.circ` file that carries a multi-line label.)
  ///
  /// **Deviation (mechanism), unobservable in practice:** Java's `(?i)` without `UNICODE_CASE`
  /// folds ASCII only, while Swift's `lowercased()` folds the full Unicode table. The two
  /// disagree on exactly one relevant input, U+212A KELVIN SIGN, which Swift lowers to `k` and
  /// Java does not fold, so a label spelled `CL\u{212A}` would count as a clock here and not
  /// upstream.
  public var isClock: Bool {
    if isOutput { return false }
    // `getValue(StdAttr.LABEL)` cannot return null here (the field is initialised to ""), but
    // the null guard is upstream's and costs nothing.
    let lbl = label
    // `Pattern`'s default line terminators are LF, CR, U+0085, U+2028 and U+2029
    // (the CRLF pair is already covered by its two halves).
    for scalar in lbl.unicodeScalars
    where scalar == "\n" || scalar == "\r" || scalar == "\u{0085}"
      || scalar == "\u{2028}" || scalar == "\u{2029}" {
      return false
    }
    let lowered = lbl.lowercased()
    return lowered.contains("clk") || lowered.contains("clock")
  }

  // NOT PORTED: `isToSave(Attribute<?>)`. Upstream's override is `return attr.isToSave()`,
  // which is character-for-character what `AbstractAttributeSet.isToSave` already does
  // (`AbstractAttributeSet.java:81-83`). A no-op override.
}
