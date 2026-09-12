// DurationAttribute.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.wiring.DurationAttribute),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// Java subclasses `Attribute<Integer>` to get a bespoke `parse`/`toDisplayString`/`getCellEditor`.
// D5 says the port does not subclass `Attribute<V>` for this, every concrete kind gets a codec
// instead, so `DurationAttribute` becomes a factory function producing an `Attribute<Int32>`
// with the right `parse`, exactly like `Attributes.forIntegerRange` next to it in the kernel.
//
// **Not ported**: `getCellEditor` (a `JTextField`, UI) and the `TickUnits` half of
// `toDisplayString` (localised "N ticks" vs "N ms"; D5's precedent: display strings are a UI
// concern, not a model one). Both parameters are still accepted so call sites transcribe
// unchanged; `isTicks` is simply unused here. Two call sites need this factory: `Clock`'s three
// duration attributes (`isTicks: true`) and `PowerOnReset`'s `"PorHighDuration"` (`isTicks:
// false`).
//
// ── UPSTREAM BUG, PRESERVED (harmless) ──────────────────────────────────────────────────────
//
// Java's `parse` wraps the whole body, including the two range-check `throw`s it performs
// itself, in one `try { … } catch (NumberFormatException e) { throw new
// NumberFormatException(S.get("freqInvalidMessage")); }`. So a value below `min` or above `max`
// throws the *generic* "invalid frequency" message, never the specific "must be at least/most N"
// message it visibly constructs first; that string is built and immediately discarded. This
// only affects a discarded, unlocalised message string; the port has no localisation (D5) and
// `AttributeParseError` messages are not serialized, so there is nothing to preserve except the
// fact that both the syntax error and the range errors throw. Both do here too.

import Foundation
import LogisimKernel

/// `com.cburch.logisim.std.wiring.DurationAttribute`.
public enum DurationAttribute {

  /// `new DurationAttribute(name, disp, min, max, isTicks)`.
  ///
  /// `isTicks` is accepted (matching every Java call site) but unused, see the file header.
  public static func make(
    _ name: String, min: Int32, max: Int32, isTicks: Bool = true
  ) -> Attribute<Int32> {
    Attribute(
      name: name,
      codec: AttributeCodec(
        parse: { text in
          // `Integer.parseInt(value)`: strict signed 32-bit decimal, unlike
          // `Attributes.forIntegerRange`'s widen-then-narrow `Long.parseLong`. A `DurationAttribute`
          // range violation is therefore never masked by 32-bit wraparound the way
          // `forIntegerRange`'s is; it is a straightforward min/max check on the parsed `Int32`.
          let value = try AttributeTextFormat.parseSigned(text, radix: 10, bits: 32)
          let narrowed = Int32(value)
          if narrowed < min {
            throw AttributeParseError.numberFormat("duration must be at least \(min)")
          }
          if narrowed > max {
            throw AttributeParseError.numberFormat("duration must be at most \(max)")
          }
          return narrowed
        },
        toStandardString: { AttributeTextFormat.standardScrub(String($0)) },
        encode: { .integer($0) },
        decode: { if case .integer(let value) = $0 { return value } else { return nil } }))
  }
}
