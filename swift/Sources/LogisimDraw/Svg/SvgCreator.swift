// SvgCreator.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// com/cburch/draw/shapes/SvgCreator.java. Copyright by the Logisim-evolution developers. This
// translation is a derivative work and is therefore licensed GPL-3.0-only. See LICENSE.md.
//
// Element names, attribute names, and number formatting are all transcribed verbatim; this is
// the half of the SVG round trip a `<appear>` section's fidelity depends on. `getColorString`
// here is deliberately a *separate* function from `ColorSpec.standardString` (Kernel): Java's is
// `"#%02x%02x%02x"`, RGB only, lowercase, always two digits, never the alpha-suffixed
// `.circ`-attribute form.
//
// The `setAttribute` calls below are kept in the Java's order purely so the two files diff
// line-for-line. **That order is not the emitted order** and nothing here may depend on it:
// upstream serialises through `DocumentBuilder`/`TransformerFactory`, and the JDK's Xerces
// `NamedNodeMapImpl` keeps attributes in a name-sorted list, so every element 4.1.0 writes comes
// out alphabetical. `SvgElement.attributes` reproduces that. See `SvgElement.swift`'s header for
// the corpus evidence and for what "alphabetical" means exactly (UTF-16 code units, so
// `stroke` < `stroke-width`).
//
// The one ordering-adjacent thing that *is* semantic is `populateFill`'s set-then-remove of
// `fill`, which must leave no attribute behind rather than an empty one.

import Foundation
import LogisimKernel

/// `com.cburch.draw.shapes.SvgCreator`.
public enum SvgCreator {
  public static func colorMatches(_ a: ColorSpec, _ b: ColorSpec) -> Bool {
    a.red == b.red && a.green == b.green && a.blue == b.blue
  }

  public static func createCurve(_ curve: Curve) -> SvgElement {
    let elt = SvgElement("path")
    let e0 = curve.end0
    let e1 = curve.end1
    let ct = curve.control
    elt.setAttribute("d", "M\(e0.x),\(e0.y) Q\(ct.x),\(ct.y) \(e1.x),\(e1.y)")
    populateFill(elt, curve)
    return elt
  }

  public static func createLine(_ line: Line) -> SvgElement {
    let elt = SvgElement("line")
    let v1 = line.end0
    let v2 = line.end1
    elt.setAttribute("x1", "\(v1.x)")
    elt.setAttribute("y1", "\(v1.y)")
    elt.setAttribute("x2", "\(v2.x)")
    elt.setAttribute("y2", "\(v2.y)")
    populateStroke(elt, line)
    return elt
  }

  public static func createOval(_ oval: Oval) -> SvgElement {
    let x = oval.x
    let y = oval.y
    let width = oval.width
    let height = oval.height
    let elt = SvgElement("ellipse")
    elt.setAttribute("cx", "\(x + width / 2)")
    elt.setAttribute("cy", "\(y + height / 2)")
    elt.setAttribute("rx", "\(width / 2)")
    elt.setAttribute("ry", "\(height / 2)")
    populateFill(elt, oval)
    return elt
  }

  public static func createPoly(_ poly: Poly) -> SvgElement {
    let elt = SvgElement(poly.isClosed ? "polygon" : "polyline")
    let points = poly.currentHandles.map { "\($0.x),\($0.y)" }.joined(separator: " ")
    elt.setAttribute("points", points)
    populateFill(elt, poly)
    return elt
  }

  public static func createRectangle(_ rect: DrawRectangle) -> SvgElement {
    createRectangular(rect)
  }

  private static func createRectangular(_ rect: Rectangular) -> SvgElement {
    let elt = SvgElement("rect")
    elt.setAttribute("x", "\(rect.x)")
    elt.setAttribute("y", "\(rect.y)")
    elt.setAttribute("width", "\(rect.width)")
    elt.setAttribute("height", "\(rect.height)")
    populateFill(elt, rect)
    return elt
  }

  public static func createRoundRectangle(_ rrect: RoundRectangle) -> SvgElement {
    let elt = createRectangular(rrect)
    elt.setAttribute("rx", "\(rrect.cornerRadius)")
    elt.setAttribute("ry", "\(rrect.cornerRadius)")
    return elt
  }

  public static func createText(_ text: DrawText) -> SvgElement {
    let elt = SvgElement("text")
    let loc = text.location
    let font = text.getValue(DrawAttr.font) ?? FontSpec(family: "SansSerif")
    let fill = text.getValue(DrawAttr.fillColor) ?? .black
    let halign = text.getValue(DrawAttr.halignment)
    let valign = text.getValue(DrawAttr.valignment)
    elt.setAttribute("x", "\(loc.x)")
    elt.setAttribute("y", "\(loc.y)")
    if !colorMatches(fill, .black) {
      elt.setAttribute("fill", getColorString(fill))
    }
    if showOpacity(fill) {
      elt.setAttribute("fill-opacity", getOpacityString(fill))
    }
    setFontAttribute(elt, font, prefix: "")
    if halign == DrawAttr.halignLeft {
      elt.setAttribute("text-anchor", "start")
    } else if halign == DrawAttr.halignRight {
      elt.setAttribute("text-anchor", "end")
    } else {
      elt.setAttribute("text-anchor", "middle")
    }
    if valign == DrawAttr.valignTop {
      elt.setAttribute("dominant-baseline", "top")
    } else if valign == DrawAttr.valignBottom {
      elt.setAttribute("dominant-baseline", "bottom")
    } else if valign == DrawAttr.valignBaseline {
      elt.setAttribute("dominant-baseline", "alphabetic")
    } else {
      elt.setAttribute("dominant-baseline", "central")
    }
    elt.appendTextNode(text.text)
    return elt
  }

  public static func setFontAttribute(_ elt: SvgElement, _ font: FontSpec, prefix: String) {
    elt.setAttribute(prefix + "font-family", font.family)
    elt.setAttribute(prefix + "font-size", "\(font.size)")
    if font.style.contains(.italic) {
      elt.setAttribute(prefix + "font-style", "italic")
    }
    if font.style.contains(.bold) {
      elt.setAttribute(prefix + "font-weight", "bold")
    }
  }

  /// `SvgCreator.getColorString`: RGB only, lowercase, always two digits. Distinct from
  /// `ColorSpec.standardString` (the `.circ` `<a>`-attribute form, which conditionally appends
  /// an alpha byte); SVG opacity is always a separate `*-opacity` attribute instead.
  public static func getColorString(_ color: ColorSpec) -> String {
    func hex(_ component: UInt8) -> String {
      let digits = String(component, radix: 16)
      return component < 16 ? "0" + digits : digits
    }
    return "#" + hex(color.red) + hex(color.green) + hex(color.blue)
  }

  /// `String.format("%5.3f", alpha / 255.0)`. The field-width-5 padding never actually binds;
  /// every value in `0.000...1.000` is already at least 5 characters, so this only needs
  /// 3-decimal fixed-point rounding, done by hand to avoid `String(format:)`'s C-varargs
  /// argument-size pitfalls for a value this small.
  private static func getOpacityString(_ color: ColorSpec) -> String {
    let milli = Int(((Double(color.alpha) / 255.0) * 1000).rounded())
    let whole = milli / 1000
    var frac = String(milli % 1000)
    while frac.count < 3 { frac = "0" + frac }
    return "\(whole).\(frac)"
  }

  private static func populateFill(_ elt: SvgElement, _ shape: AbstractCanvasObject) {
    let type = shape.getValue(DrawAttr.paintType)
    if type == DrawAttr.paintFill {
      elt.setAttribute("stroke", "none")
    } else {
      populateStroke(elt, shape)
    }
    if type == DrawAttr.paintStroke {
      elt.setAttribute("fill", "none")
    } else {
      let fill = shape.getValue(DrawAttr.fillColor) ?? .black
      if colorMatches(fill, .black) {
        elt.removeAttribute("fill")
      } else {
        elt.setAttribute("fill", getColorString(fill))
      }
      if showOpacity(fill) {
        elt.setAttribute("fill-opacity", getOpacityString(fill))
      }
    }
  }

  private static func populateStroke(_ elt: SvgElement, _ shape: AbstractCanvasObject) {
    let width = shape.getValue(DrawAttr.strokeWidth)
    if let width, width != 1 {
      elt.setAttribute("stroke-width", "\(width)")
    }
    let stroke = shape.getValue(DrawAttr.strokeColor) ?? .black
    elt.setAttribute("stroke", getColorString(stroke))
    if showOpacity(stroke) {
      elt.setAttribute("stroke-opacity", getOpacityString(stroke))
    }
    elt.setAttribute("fill", "none")
  }

  private static func showOpacity(_ color: ColorSpec) -> Bool { color.alpha != 255 }
}
