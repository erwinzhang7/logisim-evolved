// Text.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.base.Text),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── An annotation, not a circuit element ─────────────────────────────────────────────────────
//
// `Text` is the free-floating label a user drops on a schematic. It is an `InstanceFactory` like
// every other component, but it declares **no ports** (`setPorts` is never called, so the
// inherited empty array stands) and its `propagate` is empty. Nothing about it participates in
// simulation; the only things that matter for this port are that
// `<comp lib="0" name="Text" loc="…">` resolves to a factory at all, and that its five
// attributes round-trip byte-identically. Both of those are decided by `TextAttributes` and by
// `BaseLibrary`'s `tool(named:)` special case; see `BaseLibrary.swift`.
//
// `setShouldSnap(false)` is the one other observable: a text annotation is the sole builtin that
// is not snapped to the 10-pixel grid when placed.

import Foundation
import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.std.base.Text`.
public final class Text: InstanceFactoryBase {

  /// `Text._ID`. Do not change: `.circ` files reference it, and `BaseLibrary.getTool(String)`
  /// special-cases this exact string.
  public static let id = "Text"

  /// `Text.ATTR_TEXT`.
  public static let attrText: Attribute<String> = Attributes.forString("text")
  /// `Text.ATTR_FONT`.
  public static let attrFont: Attribute<FontSpec> = Attributes.forFont("font")
  /// `Text.ATTR_COLOR`.
  public static let attrColor: Attribute<ColorSpec> = Attributes.forColor("color")
  /// `Text.ATTR_HALIGN`.
  public static let attrHAlign: Attribute<TextHorizontalAlign> = Attributes.forOption("halign")
  /// `Text.ATTR_VALIGN`.
  public static let attrVAlign: Attribute<TextVerticalAlign> = Attributes.forOption("valign")

  /// Java's `public static final Text FACTORY = new Text()`, and, because the initialiser below
  /// is `private`, exactly as upstream's is, the only instance that exists.
  ///
  /// That singleton-ness is load-bearing under D4: `AddTool.sharesSource`, `Library.indexOf` and
  /// `BaseLibrary.contains` all compare factories with `===`, so a second `Text` would make a
  /// placed annotation unattributable to its library and `XmlWriter` would fail to resolve it.
  /// Note this is the opposite convention from the rest of the `arith`/`io` families, where the
  /// registrar constructs a fresh factory per library; those types have no `FACTORY` constant
  /// upstream either.
  public static let factory = Text()

  private init() {
    super.init(Text.id)
    setShouldSnap(false)
    // No `setAttributes`: `createAttributeSet()` builds a bespoke `TextAttributes`, which is
    // what upstream's `attrs == null` state means (see `InstanceFactoryBase`'s header).
    // No `setPorts` either: this component has none. See the file header.
  }

  public override func createAttributeSet() -> any AttributeSet { TextAttributes() }

  public override func validateAttributeSet(_ attributes: any AttributeSet) throws {
    guard attributes is TextAttributes else {
      throw ComponentError.wrongAttributeSet(factory: Text.id)
    }
  }

  /// `StringUtil.estimateBounds(String, Font, int hAlign, int vAlign)`
  /// (`com/cburch/logisim/util/StringUtil.java:59-100`).
  ///
  /// Housed here rather than in a shared `StringUtil` port because this slice owns
  /// `Base/` alone and `Text.getOffsetBounds` is upstream's only caller of the four-argument
  /// overload. **If a `LogisimKernel`/`LogisimDraw` `StringUtil` is ever ported, this belongs
  /// there and this copy should go**; it is transcribed verbatim, including the leading
  /// `text = "X"` substitution for an empty string (which `Text.getOffsetBounds` can never
  /// trigger, having already returned `EMPTY_BOUNDS` for that case) and the deliberately crude
  /// `size * n * 2 / 3` width model upstream's own comment describes as "assume approx monospace
  /// 12x8 aspect ratio".
  ///
  /// D9-clean: no font metrics, no graphics context; the estimate is arithmetic on the font's
  /// point size and the character count, which is exactly why it can live in this module.
  static func estimateBounds(
    _ rawText: String, _ font: FontSpec, _ hAlign: Int, _ vAlign: Int
  ) -> Bounds {
    // Java: `if (text == null || text.length() == 0) text = "X";`; the commented-out
    // `return Bounds.EMPTY_BOUNDS` next to it is upstream's, and is not what runs.
    let text = rawText.isEmpty ? "X" : rawText

    var widest = 0
    var column = 0
    var lines = 0
    for character in text {
      if character == "\n" {
        widest = Swift.max(column, widest)
        column = 0
        lines = wrap32(lines + 1)
      } else if character == "\t" {
        column = wrap32(column + 4)
      } else {
        column = wrap32(column + 1)
      }
    }
    if text.last != "\n" {
      widest = Swift.max(column, widest)
      lines = wrap32(lines + 1)
    }

    let size = Int(font.size)
    let height = wrap32(size * lines)
    // Upstream's comment: "assume approx monospace 12x8 aspect ratio".
    let width = wrap32(wrap32(size * widest) * 2 / 3)

    // `GraphicsUtil.H_LEFT` / `H_RIGHT`, and `V_TOP` / `V_CENTER`; every other alignment falls
    // into the `else`, which is why `V_BASELINE` and `V_BOTTOM` share the `-h` branch.
    let x: Int
    if hAlign == -1 {
      x = 0
    } else if hAlign == 1 {
      x = -width
    } else {
      x = -width / 2
    }
    let y: Int
    if vAlign == -1 {
      y = 0
    } else if vAlign == 0 {
      y = -height / 2
    } else {
      y = -height
    }
    return Bounds.create(x, y, width, height)
  }

  /// `Text.getOffsetBounds(AttributeSet)` (`Text.java:102-121`).
  ///
  /// The `bds == null ? Bounds.EMPTY_BOUNDS : bds` at the end of the Java is dead,
  /// `estimateBounds` never returns null, and is not reproduced.
  public override func offsetBounds(_ attributes: any AttributeSet) -> Bounds {
    guard let attrs = attributes as? TextAttributes else { return Bounds.empty }
    if attrs.text.isEmpty { return Bounds.empty }
    if let cached = attrs.offsetBounds { return cached }
    let bounds = Text.estimateBounds(
      attrs.text, attrs.font, attrs.horizontalAlign, attrs.verticalAlign)
    attrs.setOffsetBoundsCache(bounds)
    return bounds
  }

  /// `Text.propagate(InstanceState)`: empty upstream. A text annotation drives nothing.
  public override func propagate(_ state: any InstanceState) throws {}

  // NOT PORTED: `configureNewInstance`/`configureLabel`: both exist only to call
  // `instance.setTextField(ATTR_TEXT, ATTR_FONT, x, y, halign, valign)`, which installs the
  // in-canvas editable text field. `TextField`/`EditableLabel` is interactive UI (D9) and the
  // whole seam is M6/M7. Nothing about the saved bytes depends on it: the field reads and writes
  // the same two attributes this factory already carries.
  //
  // NOT PORTED: `instanceAttributeChanged`; its only body is the `configureLabel` call above,
  // for HALIGN/VALIGN. Bounds are recomputed from `offsetBounds(attributes)` on every read and
  // `TextAttributes.setRawValue` already clears the one cache, so nothing is stale
  // (PATTERNS.md §0).
  //
  // NOT PORTED: `isHDLSupportedComponent`, which returns `true` so a text annotation does not
  // block HDL export of the circuit it sits in. HDL generation is stripped from this port (D11),
  // so there is no consumer for the answer.
  //
  // PAINT (M6): `paintGhost` draws the text at the origin with the attribute font and alignment
  // via `GraphicsUtil.drawText`, then re-measures it with real `FontMetrics`
  // (`GraphicsUtil.getTextBounds` expanded by 4) and writes that back through
  // `TextAttributes.setOffsetBounds`, calling `instance.recomputeBounds()` when it changed;
  // i.e. the estimate above is refined to true metrics the first time the annotation is drawn,
  // and one trailing space is trimmed before measuring. `paintInstance` translates to the
  // component's location, sets ATTR_COLOR and delegates to `paintGhost`. `paintIcon` draws
  // `TextIcon`. See Text.java:138-185.
}
