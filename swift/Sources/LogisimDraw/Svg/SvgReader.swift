// SvgReader.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// com/cburch/draw/shapes/SvgReader.java. Copyright by the Logisim-evolution developers. This
// translation is a derivative work and is therefore licensed GPL-3.0-only. See LICENSE.md.
//
// ── D13-style: malformed SVG throws, it does not trap ────────────────────────────────────────
//
// Every `Integer.parseInt`/`Double.parseDouble`/`NumberFormatException` in the Java is
// reachable from a hand-edited or corrupted `<appear>` section in a `.circ` file, so: per the
// project's D13 rule ("a catchable Java exception becomes a Swift `throw`, never a trap");
// this throws `SvgParseError` rather than trapping. The eventual `.circ` reader (owned
// elsewhere) is expected to catch per-shape and skip, exactly as upstream's caller does.

import LogisimKernel

/// Mirrors the several distinct `NumberFormatException` messages `SvgReader.java` throws.
public enum SvgParseError: Error, CustomStringConvertible, Equatable {
  case unrecognizedPathCommand(String)
  case unexpectedCurveFormat
  case unrecognizedPath
  case malformedNumber(String)
  /// Not a `NumberFormatException`: `new Color(r, g, b, a)` throws `IllegalArgumentException`
  /// from `testColorValueRange` when a component is outside `0..255`. Still a *catchable*
  /// Java exception, so D13 makes it a `throw` here rather than a trap.
  case colorOutOfRange(component: String)

  public var description: String {
    switch self {
    case .unrecognizedPathCommand(let token): return "Unrecognized path command '\(token)'"
    case .unexpectedCurveFormat: return "Unexpected format for curve"
    case .unrecognizedPath: return "Unrecognized path"
    case .malformedNumber(let text): return "For input string: \"\(text)\""
    case .colorOutOfRange(let component):
      return "Color parameter outside of expected range: \(component)"
    }
  }
}

/// `com.cburch.draw.shapes.SvgReader`.
public enum SvgReader {

  // MARK: - Per-element-type constructors

  private static func createLine(_ elt: SvgElement) throws -> AbstractCanvasObject {
    let x0 = try parseJavaInt(elt.getAttribute("x1"))
    let y0 = try parseJavaInt(elt.getAttribute("y1"))
    let x1 = try parseJavaInt(elt.getAttribute("x2"))
    let y1 = try parseJavaInt(elt.getAttribute("y2"))
    return Line(x0: x0, y0: y0, x1: x1, y1: y1)
  }

  private static func createOval(_ elt: SvgElement) throws -> AbstractCanvasObject {
    let cx = try parseJavaDouble(elt.getAttribute("cx"))
    let cy = try parseJavaDouble(elt.getAttribute("cy"))
    let rx = try parseJavaDouble(elt.getAttribute("rx"))
    let ry = try parseJavaDouble(elt.getAttribute("ry"))
    // `(int) Math.round(double)`: NOT `Double.rounded()`, and NOT `Int(_:)`. See
    // `javaRoundToInt`: the tie direction differs on negative halves, and both the `Math.round`
    // saturation and the `(int)` wrap are reachable from a `.circ` `<ellipse>` element.
    let x = javaRoundToInt(cx - rx)
    let y = javaRoundToInt(cy - ry)
    let w = javaRoundToInt(rx * 2)
    let h = javaRoundToInt(ry * 2)
    return Oval(x: x, y: y, w: w, h: h)
  }

  /// `PATH_REGEX = Pattern.compile("[a-zA-Z]|[-\\d.]+")`: a single ASCII letter, or a run of
  /// ASCII digits/`-`/`.`. Everything else (spaces, commas) is a separator and is skipped,
  /// matching `Matcher.find()`'s scan-forward behaviour.
  private static func tokenizePath(_ d: String) -> [String] {
    let chars = Array(d)
    var tokens: [String] = []
    var i = 0
    while i < chars.count {
      let c = chars[i]
      if c.isASCII && c.isLetter {
        tokens.append(String(c))
        i += 1
      } else if c == "-" || c == "." || (c.isASCII && c.isNumber) {
        var j = i + 1
        while j < chars.count, chars[j] == "-" || chars[j] == "." || (chars[j].isASCII && chars[j].isNumber)
        {
          j += 1
        }
        tokens.append(String(chars[i..<j]))
        i = j
      } else {
        i += 1
      }
    }
    return tokens
  }

  private static func createPath(_ elt: SvgElement) throws -> AbstractCanvasObject {
    let tokens = tokenizePath(elt.getAttribute("d"))
    var type = -1  // -1 error/unset, 0 start, 1 curve
    for token in tokens {
      guard let first = token.first, first.isLetter else { continue }
      switch first {
      case "M": type = (type == -1) ? 0 : -1
      case "Q", "q": type = (type == 0) ? 1 : -1
      default: type = -1
      }
      if type == -1 {
        throw SvgParseError.unrecognizedPathCommand(String(first))
      }
    }

    guard type == 1 else { throw SvgParseError.unrecognizedPath }
    guard tokens.count == 8, tokens[0] == "M", tokens[3].uppercased() == "Q" else {
      throw SvgParseError.unexpectedCurveFormat
    }
    let x0 = try parseJavaInt(tokens[1])
    let y0 = try parseJavaInt(tokens[2])
    var x1 = try parseJavaInt(tokens[4])
    var y1 = try parseJavaInt(tokens[5])
    var x2 = try parseJavaInt(tokens[6])
    var y2 = try parseJavaInt(tokens[7])
    if tokens[3] == "q" {
      x1 += x0
      y1 += y0
      x2 += x0
      y2 += y0
    }
    let e0 = Location.create(x0, y0, hasToSnap: false)
    let e1 = Location.create(x2, y2, hasToSnap: false)
    let ct = Location.create(x1, y1, hasToSnap: false)
    return Curve(end0: e0, end1: e1, control: ct)
  }

  private static func createPolygon(_ elt: SvgElement) throws -> AbstractCanvasObject {
    // `Poly.init` itself throws (`PolyError.noPoints`): Java's `setHandles` indexes `hs[0]`
    // unguarded, so `<polygon points=""/>` is an ArrayIndexOutOfBoundsException upstream and a
    // D13 `throw` here. The call therefore needs its own `try`; without it LogisimDraw does not
    // compile.
    let points = try parsePoints(elt.getAttribute("points"))
    return try Poly(closed: true, locations: points)
  }

  private static func createPolyline(_ elt: SvgElement) throws -> AbstractCanvasObject {
    let points = try parsePoints(elt.getAttribute("points"))
    return try Poly(closed: false, locations: points)
  }

  private static func createRectangle(_ elt: SvgElement) throws -> AbstractCanvasObject {
    let x = try parseJavaInt(elt.getAttribute("x"))
    let y = try parseJavaInt(elt.getAttribute("y"))
    let w = try parseJavaInt(elt.getAttribute("width"))
    let h = try parseJavaInt(elt.getAttribute("height"))
    if elt.hasAttribute("rx") {
      let ret = RoundRectangle(x: x, y: y, w: w, h: h)
      let rx = try parseJavaInt(elt.getAttribute("rx"))
      try ret.setValue(DrawAttr.cornerRadius, Int32(rx))
      return ret
    }
    return DrawRectangle(x: x, y: y, w: w, h: h)
  }

  // MARK: - Dispatch + shared attribute post-processing

  public static func createShape(_ elt: SvgElement) throws -> AbstractCanvasObject? {
    guard let ret = try createShapeObject(elt) else { return nil }

    var attrs = ret.attributes
    if attrs.contains(where: { $0 === DrawAttr.paintType }) {
      let stroke = elt.getAttribute("stroke")
      let fill = elt.getAttribute("fill")
      if stroke.isEmpty || stroke == "none" {
        try ret.setValue(DrawAttr.paintType, DrawAttr.paintFill)
      } else if fill == "none" {
        try ret.setValue(DrawAttr.paintType, DrawAttr.paintStroke)
      } else {
        try ret.setValue(DrawAttr.paintType, DrawAttr.paintStrokeFill)
      }
    }
    attrs = ret.attributes  // changing paintType can change the attribute list
    if attrs.contains(where: { $0 === DrawAttr.strokeWidth }), elt.hasAttribute("stroke-width") {
      let width = try parseJavaInt(elt.getAttribute("stroke-width"))
      try ret.setValue(DrawAttr.strokeWidth, Int32(width))
    }
    if attrs.contains(where: { $0 === DrawAttr.strokeColor }) {
      let color = elt.getAttribute("stroke")
      let opacity = elt.getAttribute("stroke-opacity")
      if color != "none" {
        try ret.setValue(DrawAttr.strokeColor, try getColor(color, opacity))
      }
    }
    if attrs.contains(where: { $0 === DrawAttr.fillColor }) {
      var color = elt.getAttribute("fill")
      // FIXME (upstream): hardcoded default colour value.
      if color.isEmpty { color = "#000000" }
      let opacity = elt.getAttribute("fill-opacity")
      if color != "none" {
        try ret.setValue(DrawAttr.fillColor, try getColor(color, opacity))
      }
    }
    return ret
  }

  private static func createShapeObject(_ elt: SvgElement) throws -> AbstractCanvasObject? {
    switch elt.tagName {
    case "ellipse": return try createOval(elt)
    case "line": return try createLine(elt)
    case "path": return try createPath(elt)
    case "polyline": return try createPolyline(elt)
    case "polygon": return try createPolygon(elt)
    case "rect": return try createRectangle(elt)
    case "text": return try createText(elt)
    default: return nil
    }
  }

  private static func createText(_ elt: SvgElement) throws -> AbstractCanvasObject {
    let x = try parseJavaInt(elt.getAttribute("x"))
    let y = try parseJavaInt(elt.getAttribute("y"))
    let text = elt.textContent
    let ret = DrawText(x: x, y: y, text: text)

    let fontFamily = elt.getAttribute("font-family")
    let fontStyle = elt.getAttribute("font-style")
    let fontWeight = elt.getAttribute("font-weight")
    let fontSize = elt.getAttribute("font-size")
    var style: FontStyle = []
    if isItalic(fontStyle) { style.insert(.italic) }
    if isBold(fontWeight) { style.insert(.bold) }
    let size = try parseJavaInt(fontSize)
    try ret.setValue(DrawAttr.font, FontSpec(family: fontFamily, style: style, size: Int32(size)))

    let hAlignStr = elt.getAttribute("text-anchor")
    let hAlign: AttributeOption
    if hAlignStr == "start" {
      hAlign = DrawAttr.halignLeft
    } else if hAlignStr == "end" {
      hAlign = DrawAttr.halignRight
    } else {
      hAlign = DrawAttr.halignCenter
    }
    try ret.setValue(DrawAttr.halignment, hAlign)

    let vAlignStr = elt.getAttribute("dominant-baseline")
    try ret.setValue(DrawAttr.valignment, alignment(for: vAlignStr))

    // Fill colour is handled by the caller (`createShape`), after this returns, matching Java.
    return ret
  }

  private static func alignment(for valignStr: String) -> AttributeOption {
    switch valignStr {
    case "top": return DrawAttr.valignTop
    case "bottom": return DrawAttr.valignBottom
    case "alphabetic": return DrawAttr.valignBaseline
    default: return DrawAttr.valignMiddle
    }
  }

  /// `SvgReader.getFontAttribute`; used by other component families that embed a font
  /// attribute directly in a `.circ` XML element with a prefix (e.g. `"label-"`), not only by
  /// shapes.
  public static func getFontAttribute(
    _ elt: SvgElement, prefix: String, defaultFamily: String, defaultSize: Int32
  ) -> FontSpec {
    var fontFamily = elt.getAttribute(prefix + "font-family")
    let fontStyleAttr = elt.getAttribute(prefix + "font-style")
    let fontWeightAttr = elt.getAttribute(prefix + "font-weight")
    let fontSize = elt.getAttribute(prefix + "font-size")

    if fontFamily.isEmpty { fontFamily = defaultFamily }
    let fontStyle = fontStyleAttr.isEmpty ? "plain" : fontStyleAttr
    let fontWeight = fontWeightAttr.isEmpty ? "plain" : fontWeightAttr
    var style: FontStyle = []
    if isItalic(fontStyle) { style.insert(.italic) }
    if isBold(fontWeight) { style.insert(.bold) }

    var size = defaultSize
    if !fontSize.isEmpty, let parsed = try? parseJavaInt(fontSize) {
      size = Int32(parsed)
    }
    return FontSpec(family: fontFamily, style: style, size: size)
  }

  /// `SvgReader.getColor(String hue, String opacity)`.
  public static func getColor(_ hue: String, _ opacity: String) throws -> ColorSpec {
    var r: UInt8 = 0
    var g: UInt8 = 0
    var b: UInt8 = 0
    if !hue.isEmpty, hue.count == 7 {
      let chars = Array(hue)
      // Bug-for-bug: Java never checks that `chars[0] == '#'` before slicing `[1,3)`/`[3,5)`/
      // `[5,7)`; any 7-character string parses as long as those three 2-character slices are
      // valid hex. A `NumberFormatException` here is caught upstream and defaults silently to
      // 0; reproduced the same way (fall through to r=g=b=0 on parse failure).
      if let rv = UInt8(String(chars[1...2]), radix: 16),
        let gv = UInt8(String(chars[3...4]), radix: 16),
        let bv = UInt8(String(chars[5...6]), radix: 16)
      {
        r = rv
        g = gv
        b = bv
      }
    }
    var alpha = 255
    if !opacity.isEmpty {
      let tmpOpacity: Double
      if let value = Double(opacity) {
        tmpOpacity = value
      } else {
        // Java retries with the last comma turned into a decimal point (some locales format
        // floats with a comma), and only then rethrows the original exception.
        guard let commaIndex = opacity.lastIndex(of: ",") else {
          throw SvgParseError.malformedNumber(opacity)
        }
        let replacement = opacity[opacity.startIndex..<commaIndex] + "."
          + opacity[opacity.index(after: commaIndex)...]
        guard let retried = Double(replacement) else {
          throw SvgParseError.malformedNumber(opacity)
        }
        tmpOpacity = retried
      }
      // `alpha = (int) Math.round(tmpOpacity * 255)`. This is NOT clamped: `Math.round`
      // saturates to `Long.MAX_VALUE` and the `(int)` cast then wraps, so `opacity="1e30"`
      // gives alpha == -1 (verified on OpenJDK 21), and an opacity whose scaled product lands
      // on a multiple of 2^32 wraps back *into* range and is accepted.
      alpha = javaRoundToInt(tmpOpacity * 255)
    }
    // `new Color(r, g, b, alpha)` calls `testColorValueRange`, which throws
    // `IllegalArgumentException`: catchable, so D13 says throw rather than clamp or trap.
    // The old `UInt8(clamping:)` silently turned upstream's rejection into alpha 0 or 255,
    // and the `Int((value * 255).rounded())` feeding it trapped outright on `1e30`.
    guard (0...255).contains(alpha) else {
      throw SvgParseError.colorOutOfRange(component: "Alpha")
    }
    return ColorSpec(red: r, green: g, blue: b, alpha: UInt8(alpha))
  }

  /// Java: `Pattern.compile("[ ,\n\r\t]+").split(points)`, then `new Location[toks.length / 2]`
  /// and a loop over `ret.length`.
  ///
  /// Two upstream behaviours the port must NOT "improve" on. Both verified on OpenJDK 21:
  ///
  ///  * **The array is sized by integer division**, so an odd token count silently drops the
  ///    trailing unpaired token: `points="1,2 3"` is a *one*-point `Poly` upstream, not an
  ///    error. This port previously had a `tokens.count % 2 == 0` guard that upstream does not
  ///    have, which meant a file that opens fine in Logisim failed to open here.
  ///  * **`Pattern.split` keeps a LEADING empty token** when the input starts with a separator
  ///    : at limit 0 only *trailing* empties are stripped. So `points=" 1,2"` splits to
  ///    `["", "1", "2"]`, the pair read is `("", "1")`, and `Integer.parseInt("")` throws.
  ///    Splitting with `omittingEmptySubsequences: true` parsed that cleanly instead, i.e. the
  ///    port accepted a file upstream rejects. Both directions matter; match Java exactly.
  private static func parsePoints(_ points: String) throws -> [Location] {
    let tokens = javaSplitOnSeparatorRun(points)
    let count = tokens.count / 2
    var result: [Location] = []
    result.reserveCapacity(count)
    for i in 0..<count {
      let x = try parseJavaInt(tokens[2 * i])
      let y = try parseJavaInt(tokens[2 * i + 1])
      result.append(Location.create(x, y, hasToSnap: false))
    }
    return result
  }

  /// `Pattern.compile("[ ,\n\r\t]+").split(s)` at the default limit of 0.
  ///
  /// Runs of separators collapse (the `+`), a non-zero-width match at index 0 produces a
  /// leading empty token, all trailing empty tokens are stripped, and an input containing no
  /// separator at all comes back as a one-element array holding the whole input, which is why
  /// `""` splits to `[""]` (one token) while `" "` splits to `[]` (none).
  ///
  /// This walks **unicode scalars, not `Character`s**, and that is not a stylistic choice.
  /// Swift's `Character` is a grapheme cluster, so `"\r\n"` is a *single* `Character` that
  /// equals neither `"\r"` nor `"\n"`; a `Character`-based separator test silently fails to
  /// split a CRLF-delimited `points` list and then throws on `"4\r\n"`. Java's regex engine
  /// matches UTF-16 code units, so CR and LF are two independent separators there. (The
  /// version of this method that this replaced had the same latent defect.)
  private static func javaSplitOnSeparatorRun(_ s: String) -> [String] {
    func isSeparator(_ u: Unicode.Scalar) -> Bool {
      u == " " || u == "," || u == "\n" || u == "\r" || u == "\t"
    }
    guard s.unicodeScalars.contains(where: isSeparator) else { return [s] }
    var tokens: [String] = []
    var current = String.UnicodeScalarView()
    var inSeparator = false
    for u in s.unicodeScalars {
      if isSeparator(u) {
        if !inSeparator {
          tokens.append(String(current))
          current = String.UnicodeScalarView()
          inSeparator = true
        }
      } else {
        inSeparator = false
        current.append(u)
      }
    }
    tokens.append(String(current))
    while let last = tokens.last, last.isEmpty { tokens.removeLast() }
    return tokens
  }

  private static func isBold(_ fontStyle: String) -> Bool { fontStyle == "bold" }
  private static func isItalic(_ fontStyle: String) -> Bool { fontStyle == "italic" }

  // MARK: - Java-parity numeric parsing

  /// `Integer.parseInt(String)`: strict, ASCII-digit-only, optional leading `-`/`+`, 32-bit
  /// range.
  static func parseJavaInt(_ text: String) throws -> Int {
    guard let value = javaParseInt32(text) else {
      throw SvgParseError.malformedNumber(text)
    }
    return value
  }

  /// `Double.parseDouble(String)`. Swift's `Double.init?(String)` accepts the same decimal/
  /// exponent syntax Java's does for the inputs this reader ever sees (plain and exponential
  /// decimals written by `SvgCreator`/other SVG producers); it additionally accepts a few forms
  /// Java also accepts (`"Infinity"`, `"NaN"`) and does not accept Java's trailing `f`/`F`/`d`/
  /// `D` type suffixes, which never appear in generated SVG.
  static func parseJavaDouble(_ text: String) throws -> Double {
    guard let value = Double(text) else {
      throw SvgParseError.malformedNumber(text)
    }
    return value
  }

  /// Java's `(int) Math.round(someDouble)`: the *whole* two-step expression, because both
  /// steps are observable and neither is what Swift does by default.
  ///
  /// `Math.round` returns a `long` and **saturates** at the `long` bounds; the `(int)` cast
  /// then **wraps**, keeping the low 32 bits. So `(int) Math.round(1e30)` is `-1`, not a crash
  /// and not `Int32.max`. `Int((1e30).rounded())` traps ("Double value cannot be converted to
  /// Int because the result would be greater than Int.max"), which turns a hand-edited
  /// `<ellipse cx="1e30" .../>` in a `.circ` file into a process death with the user's unsaved
  /// work in it; exactly the D13 failure mode. Clamping instead of wrapping is also wrong:
  /// the resulting coordinate is stored on the shape and is observable.
  ///
  /// Measured against OpenJDK 21: `1e30 → -1`, `-1e30 → 0`, `4.5e18 → 1900150784`,
  /// `Infinity → -1`, `NaN → 0`.
  static func javaRoundToInt(_ a: Double) -> Int {
    wrap32(Int(truncatingIfNeeded: javaMathRound(a)))
  }

  /// `java.lang.Math.round(double)`, transliterated.
  ///
  /// Two separate divergences from `Double.rounded()`:
  ///
  ///  * Swift's default rule is `.toNearestOrAwayFromZero`; Java rounds ties toward **positive
  ///    infinity**. They disagree on every exact negative half; `Math.round(-2.5)` is `-2`
  ///    while `(-2.5).rounded()` is `-3`, and `Math.round(-0.5)` is `0` while `(-0.5).rounded()`
  ///    is `-1`. That is a wrong-geometry bug for any `<ellipse>` on a half-grid coordinate.
  ///  * It is also *not* the `(long) Math.floor(a + 0.5)` the javadoc used to specify.
  ///    JDK-6430675 replaced that in Java 7 because `a + 0.5` can itself round up to the next
  ///    representable double. Confirmed on the 4.1.0 runtime:
  ///    `Math.round(0.49999999999999994) == 0`, where `floor(a + 0.5)` yields `1`.
  ///
  /// This is therefore the real JDK bit-twiddling implementation rather than an approximation
  /// of it.
  private static func javaMathRound(_ a: Double) -> Int64 {
    let longBits = Int64(bitPattern: a.bitPattern)
    let biasedExp = (longBits & 0x7FF0_0000_0000_0000) >> 52
    // (SIGNIFICAND_WIDTH - 2 + EXP_BIAS) - biasedExp == 1074 - biasedExp.
    let shift = Int64(53 - 2 + 1023) - biasedExp
    if (shift & -64) == 0 {  // i.e. 0 <= shift < 64
      var r = (longBits & 0x000F_FFFF_FFFF_FFFF) | 0x0010_0000_0000_0000
      if longBits < 0 { r = -r }
      return ((r >> shift) &+ 1) >> 1
    }
    // |a| is either already integral (and possibly out of `long` range) or below 0.5.
    return javaDoubleToLong(a)
  }

  /// Java's narrowing primitive conversion `(long) someDouble`: NaN becomes 0, out-of-range
  /// values saturate to the `long` bounds, everything else truncates toward zero. Swift's
  /// `Int64(_: Double)` traps on all three of those instead.
  private static func javaDoubleToLong(_ a: Double) -> Int64 {
    if a.isNaN { return 0 }
    // 2^63 is exactly representable as a Double; Int64.max is not.
    if a >= 9_223_372_036_854_775_808.0 { return Int64.max }
    if a <= -9_223_372_036_854_775_808.0 { return Int64.min }
    return Int64(a)
  }
}
