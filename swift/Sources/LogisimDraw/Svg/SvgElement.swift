// SvgElement.swift: part of logisim-evolved.
//
// A minimal stand-in for the slice of `org.w3c.dom.{Document,Element}` that
// `com.cburch.draw.shapes.{SvgCreator,SvgReader}` actually uses. This module owns the shape
// model, not an XML library or a dependency on `LogisimFile`'s eventual `.circ`/SVG writer;
// see `AbstractCanvasObject.toSvgElement()`'s header for why the `Document` factory parameter
// is dropped entirely (there is nothing here for a document to factor).
//
// ── The attribute-order contract: ALPHABETICAL, not insertion order ─────────────────────────
//
// The task this module exists to unblock is byte-exact `<appear>` round-tripping, so the order
// attributes serialise in is part of the contract. That order is **not** the order `SvgCreator`
// calls `setAttribute` in; it is ascending order of attribute name.
//
// Why: `XmlWriter.java:184/198-204` builds the whole document with `DocumentBuilder` and writes
// it with `TransformerFactory`, i.e. everything upstream emits goes through the JDK's bundled
// Xerces DOM. `NamedNodeMapImpl` keeps its nodes in a single `ArrayList` that it maintains as a
// *sorted* list: `setNamedItem` locates the slot with `findNamePoint`, a binary search using
// `String.compareTo` on the node name, and inserts there. The serializer then walks the map by
// index. So the DOM never preserves call order in the first place; every element 4.1.0 writes
// comes out name-sorted, whatever order the creator happened to set the attributes in.
//
// Corpus evidence (577 harvested `.circ` files; attribute *values* stripped, forms deduped):
//
//   <rect fill height rx ry stroke stroke-width width x y/>
//   <ellipse cx cy fill rx ry stroke/>
//   <polygon fill points stroke stroke-width/>
//   <path d fill stroke stroke-width/>
//   <text dominant-baseline fill font-family font-size font-weight text-anchor x y>
//   <text font-family font-size font-style text-anchor x y>
//   <circ-anchor facing height width x y/>
//
// Every observed form is sorted; no non-sorted form occurs anywhere in the corpus. Note this is
// unreachable by insertion order; `SvgCreator.createRectangular` sets x, y, width, height and
// only *then* the fill/stroke group, and `createRoundRectangle` appends rx/ry after all of that,
// yet `rect` still emits fill-height-rx-ry-stroke-stroke-width-width-x-y.
//
// Reproduce with:
//   grep -h -o '<rect [^>]*>' $LOGISIM_CORPUS/harvested/*.circ \
//     | sed 's/="[^"]*"//g' | sort -u
//
// ── What "alphabetical" means precisely ─────────────────────────────────────────────────────
//
// `String.compareTo` compares UTF-16 code units, so this is codepoint order, *not* locale-aware
// collation and not case-insensitive. The distinction is load-bearing for the hyphenated names,
// because '-' is U+002D: below every letter and digit:
//
//   stroke < stroke-opacity < stroke-width      (a prefix sorts before its extensions)
//   fill   < fill-opacity   < font-family       ('i' U+0069 < 'o' U+006F)
//   font-size < font-style  < font-weight       ('i' < 't' < 'w' at the same offset)
//   dominant-baseline < fill                    ('d' < 'f')
//   x < x1 < x2 < y < y1 < y2
//
// which is exactly where the corpus puts them. Swift's `String.<` is *not* codepoint order (it
// orders by Unicode canonical equivalence), so `attributes` compares `.utf16` views explicitly
// rather than the strings, matching the JDK on any name a `.circ` could carry.
//
// ── What is still DOM insertion/mutation semantics ──────────────────────────────────────────
//
// Sorting on emit does not make the mutation methods trivial: `SvgCreator.populateFill` calls
// `setAttribute("fill", "none")` and later, for the same element, `setAttribute("fill", …)` or
// `removeAttribute("fill")`. So set-then-overwrite must keep exactly one slot, and
// `removeAttribute` must actually delete it (an emitted `fill=""` would be a byte difference).
// `getAttribute` for a name never set returns `""` (`org.w3c.dom.Element.getAttribute`'s
// documented behaviour: never `nil`), which is what lets `SvgReader` port its `"".equals(...)`/
// `"none".equals(...)` checks unchanged.

/// A `<tag attr="value" …>text</tag>` element. Attributes serialise in ascending UTF-16 order of
/// name, reproducing the JDK Xerces `NamedNodeMapImpl` sorted-list behaviour that upstream's
/// `DocumentBuilder`/`Transformer` output goes through, see the file header.
public final class SvgElement {
  public let tagName: String
  private var values: [String: String] = [:]
  public var textContent: String = ""

  public init(_ tagName: String) {
    self.tagName = tagName
  }

  /// `Element.setAttribute(name, value)`. Replaces the value if `name` is already present.
  public func setAttribute(_ name: String, _ value: String) {
    values[name] = value
  }

  /// `Element.removeAttribute(name)`. No-op if absent.
  public func removeAttribute(_ name: String) {
    values.removeValue(forKey: name)
  }

  /// `Element.getAttribute(name)`, `""`, never `nil`, when `name` is not present.
  public func getAttribute(_ name: String) -> String { values[name] ?? "" }

  public func hasAttribute(_ name: String) -> Bool { values[name] != nil }

  /// `(name, value)` pairs in the order they serialise: ascending by name in UTF-16 code-unit
  /// order, matching `java.lang.String.compareTo`, which is what Xerces' `NamedNodeMapImpl`
  /// binary-searches on. Consumed by whatever XML writer emits the `<appear>` section (owned
  /// elsewhere, see the file header).
  public var attributes: [(name: String, value: String)] {
    values.keys
      .sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
      .map { ($0, values[$0] ?? "") }
  }

  public func appendTextNode(_ text: String) {
    textContent += text
  }
}
