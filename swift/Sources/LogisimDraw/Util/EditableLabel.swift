// EditableLabel.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// com/cburch/draw/util/EditableLabel.java. Copyright by the Logisim-evolution developers. This
// translation is a derivative work and is therefore licensed GPL-3.0-only. See LICENSE.md.
//
// `configureTextField(EditableLabelField, zoom)` is dropped along with `EditableLabelField`
// itself (`javax.swing.JTextField`; the in-place text-editing widget belongs to `draw/canvas`/
// `draw/tools`, Swing, explicitly out of scope: M6/M7). `paint(Graphics)` is dropped per this
// module's no-drawing-code rule; what it did beyond drawing, calling `computeDimensions` to
// (re)populate the cached metrics, is exposed directly as `measure(using:)`. See
// `TextMetrics.swift` for why metrics are seamed out to a provider instead of computed here,
// and for the latent "zero until measured" behaviour this preserves.
//
// `EditableLabel` is a Swift `struct`, not a class: Java's `Cloneable`/`clone()` exists purely
// to get value semantics on top of a class, which a struct provides for free.
//
// Equality and hashing MUST be written by hand, and the derived conformance is wrong here.
// `EditableLabel.equals`/`hashCode` compare exactly seven fields, x, y, text, font, color,
// horzAlign, vertAlign, and deliberately exclude the four measured metrics (`dimsKnown`,
// `width`, `ascent`, `descent`), which are a painting cache, not identity. Swift's synthesized
// `Hashable` includes every stored property, so it would fold the cache into equality: since
// `DrawText.matches` delegates straight to label equality, two structurally identical `DrawText`s
// would compare *unequal* the moment one of them had been painted and measured, quietly
// corrupting the `MatchingSet`-based appearance diffing. Hence the explicit `==`/`hash(into:)`
// below, over Java's field set only. The hash is mechanical rather than
// exact-arithmetic-matched to Java's `hashCode()`; nothing depends on the exact integer, only
// on its agreeing with `==`.
//
// Geometry note: Java's `getLeftX()`/`getBaseY()` return `float`, and `getBounds()` narrows with
// a single `(int)` cast at the very end. Doing the halving in `Int` instead truncates the
// quotient *before* the subtraction, which differs by one for odd widths, and centred is the
// common case, since `SvgReader` maps every `text-anchor` other than `start`/`end` to
// `HALIGN_CENTER`. So both accessors are `Float` here (32-bit, like Java's, so the rounding
// matches at large magnitudes too) and the truncation happens exactly where Java casts.

import LogisimKernel

/// `EditableLabel.LEFT/CENTER/RIGHT` (`javax.swing.JTextField`'s constants, verified against
/// the JDK: `LEFT=2, CENTER=0, RIGHT=4`).
public enum HorizontalTextAlign: Int32 {
  case left = 2
  case center = 0
  case right = 4
}

/// `EditableLabel.TOP/MIDDLE/BASELINE/BOTTOM`.
public enum VerticalTextAlign: Int32 {
  case top = 8
  case middle = 9
  case baseline = 10
  case bottom = 11
}

/// `com.cburch.draw.util.EditableLabel`.
public struct EditableLabel: Hashable {
  public var x: Int
  public var y: Int
  public var text: String
  public var font: FontSpec
  public var color: ColorSpec = .black
  public var horizontalAlignment: HorizontalTextAlign = .left
  public var verticalAlignment: VerticalTextAlign = .baseline

  // See the file header and `TextMetrics.swift`: these start at zero, exactly like Java's, and
  // only change via `measure(using:)`. `dimsKnown` is carried for fidelity even though, as in
  // Java, nothing actually reads it.
  private(set) var dimsKnown = false
  public private(set) var width = 0
  public private(set) var ascent = 0
  public private(set) var descent = 0

  public init(x: Int, y: Int, text: String, font: FontSpec) {
    self.x = x
    self.y = y
    self.text = text
    self.font = font
  }

  /// `EditableLabel.computeDimensions(Graphics)`, generalised over `TextMetricsProviding`.
  public mutating func measure(using provider: TextMetricsProviding) {
    let metrics = provider.measure(text: text, font: font)
    width = metrics.width
    ascent = metrics.ascent
    descent = metrics.descent
    dimsKnown = true
  }

  /// `EditableLabel.contains(int, int)`. Java compares the two `int` arguments against the
  /// `float` results of `getLeftX()`/`getBaseY()`, so the comparisons happen in floating point
  /// and a half-pixel left edge is honoured; `qx >= 6.5` is not `qx >= 6`. Kept in `Float`
  /// here for the same reason `bounds` is.
  public func contains(_ qx: Int, _ qy: Int) -> Bool {
    let x0 = leftX
    let y0 = baseY
    let fqx = Float(qx)
    let fqy = Float(qy)
    return fqx >= x0 && fqx < x0 + Float(width) && fqy >= y0 - Float(ascent)
      && fqy < y0 + Float(descent)
  }

  /// `getBaseY()`: `float`, per the file header. The `TOP`/`BOTTOM` arms are `int` expressions
  /// in Java that are only widened to `float` afterwards; only the `MIDDLE` arm divides, and it
  /// divides by `2.0F`.
  private var baseY: Float {
    switch verticalAlignment {
    case .top: return Float(y + ascent)
    case .middle: return Float(y) + Float(ascent - descent) / 2.0
    case .baseline: return Float(y)
    case .bottom: return Float(y - descent)
    }
  }

  /// `getLeftX()`: `float`, per the file header. `CENTER` is `x - width / 2.0F`, so an odd
  /// width leaves a `.5` that only the caller's `(int)` cast removes.
  private var leftX: Float {
    switch horizontalAlignment {
    case .left: return Float(x)
    case .center: return Float(x) - Float(width) / 2.0
    case .right: return Float(x - width)
    }
  }

  /// `getBounds()`. Java: `int x0 = (int) getLeftX(); int y0 = (int) getBaseY() - ascent;`:
  /// note the cast binds to `getBaseY()` alone, so the truncation happens *before* `ascent` is
  /// subtracted. Truncate once, exactly where Java casts.
  public var bounds: Bounds {
    let x0 = javaIntCast(leftX)
    let y0 = javaIntCast(baseY) - ascent
    return Bounds.create(x0, y0, width, ascent + descent)
  }

  public mutating func setLocation(x: Int, y: Int) {
    self.x = x
    self.y = y
  }

  // MARK: - Equality and hashing (Java's field set only — see the file header)

  public static func == (lhs: EditableLabel, rhs: EditableLabel) -> Bool {
    lhs.x == rhs.x && lhs.y == rhs.y && lhs.text == rhs.text && lhs.font == rhs.font
      && lhs.color == rhs.color && lhs.horizontalAlignment == rhs.horizontalAlignment
      && lhs.verticalAlignment == rhs.verticalAlignment
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(x)
    hasher.combine(y)
    hasher.combine(text)
    hasher.combine(font)
    hasher.combine(color)
    hasher.combine(horizontalAlignment)
    hasher.combine(verticalAlignment)
  }
}

/// Java's `(int)` narrowing of a `float` (JLS 5.1.3): round toward zero, `NaN` to 0, and
/// saturate at `Integer.MIN_VALUE`/`MAX_VALUE`. Swift's `Int(_: Float)` traps instead of
/// saturating, and a trap on file-derived geometry is exactly what D13 forbids; every value
/// reaching here came out of a `.circ` `<appear>` section.
private func javaIntCast(_ value: Float) -> Int {
  if value.isNaN { return 0 }
  // `Float(Int32.max)` rounds up to 2^31, so this bound is `>=` and catches 2^31 itself.
  if value >= Float(Int32.max) { return Int(Int32.max) }
  if value <= Float(Int32.min) { return Int(Int32.min) }
  return Int(value)
}
