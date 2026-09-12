// AppearanceSvgReader.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// com/cburch/logisim/circuit/appear/AppearanceSvgReader.java. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore licensed GPL-3.0-only.
// See LICENSE.md.
//
// ── What this file covers, and what it deliberately does not ────────────────────────────────
//
// Upstream's `createShape` handles four kinds of `<appear>` child:
//
//   circ-anchor / circ-origin   →  AppearanceAnchor           : here
//   circ-port                   →  AppearancePort             : here
//   visible-*                   →  a DynamicElement subclass  : NOT here
//   anything else               →  draw.shapes.SvgReader      : here, by delegation
//
// The `visible-*` families (`LedShape`, `RegisterShape`, `SocVgaShape`, …) live in
// `LogisimStd`/`LogisimSoc`, which sit *above* this module, and each one binds to a component
// somewhere in the circuit tree. They are therefore resolved by the `LogisimFile` half of this
// seam (`CircuitAppearanceReader.swift`), which is where the circuit is; this function returns
// nil for them, exactly as it does for any tag it does not recognise.
//
// ── D13 ─────────────────────────────────────────────────────────────────────────────────────
//
// Every parse below is reachable from a hand-edited `.circ`, and upstream lets the resulting
// `RuntimeException` escape to `XmlReader.loadAppearance`, which catches it and reports
// `fileAppearanceError`. So they throw here rather than trapping: including the two upstream
// raises implicitly and the caller only sees as a stack trace: `pin=""` indexes past the end of
// `split(",")`'s result (ArrayIndexOutOfBoundsException), and a `<circ-port>` with a `width`
// attribute that is not a number reaches `Double.parseDouble` in `isInputPinReference`.

import LogisimKernel

/// One `Pin` component a `<circ-port>` may bind to.
///
/// `AppearanceSvgReader.PinInfo`, reduced to the three facts `AppearancePort` keeps (see
/// `AppearanceElement`'s header) plus the used/unused flag the matching loop consumes.
///
/// A class, not a struct: `pinIsUsed` is mutated through the array during the match, which is
/// how upstream stops two `<circ-port>` elements from binding to the same pin.
public final class AppearancePinBinding {
  /// `getPinLocation()`, the component's own location.
  public let location: Location
  /// `((Pin) inst.getFactory()).isInputPin(inst)`, resolved by the caller.
  public let isInput: Bool
  /// `getPinInstance()`, as an opaque identity.
  public let reference: AnyObject?
  /// `pinIsAlreadyUsed()`.
  public private(set) var isUsed: Bool = false

  public init(location: Location, isInput: Bool, reference: AnyObject? = nil) {
    self.location = location
    self.isInput = isInput
    self.reference = reference
  }

  /// `setPinIsUsed()`.
  public func markUsed() { isUsed = true }
}

/// `com.cburch.logisim.circuit.appear.AppearanceSvgReader`, minus the dynamic elements.
public enum AppearanceSvgReader {

  /// `createShape(Element, List<PinInfo>, Circuit)` for everything but `visible-*`.
  ///
  /// Returns nil for a tag this module cannot build, an unmatched `<circ-port>`, a `visible-*`
  /// element, or an unknown tag, which is upstream's own "not found" signal.
  public static func createShape(
    _ elt: SvgElement, pins: [AppearancePinBinding]
  ) throws -> AbstractCanvasObject? {
    let name = elt.tagName

    if name == "circ-anchor" || name == "circ-origin" {
      let loc = try location(of: elt)
      let ret = AppearanceAnchor(loc)
      if elt.hasAttribute("facing") {
        // `Direction.parse` is exact and case-sensitive, and throws on anything else: a
        // `NumberFormatException` upstream, so a `throw` here (D13).
        let facing = try Direction.parse(elt.getAttribute("facing"))
        try ret.setValue(AppearanceAnchor.facing, facing)
      }
      return ret
    }

    if name == "circ-port" {
      let loc = try location(of: elt)
      let pinLoc = try pinLocation(of: elt)
      let wantsInput = try isInputPinReference(elt)
      for pin in pins {
        if pin.isUsed { continue }
        guard pin.location == pinLoc else { continue }
        guard pin.isInput == wantsInput else { continue }
        pin.markUsed()
        return AppearancePort(
          loc, pinLocation: pin.location, isInput: pin.isInput, pinReference: pin.reference)
      }
      // No unused pin at that location with that direction: upstream returns null and the
      // caller reports `fileAppearanceNotFound`. The port is dropped, and dropping it is
      // correct; it names a pin the circuit no longer has.
      return nil
    }

    if name.hasPrefix("visible-") { return nil }

    return try SvgReader.createShape(elt)
  }

  /// `getLocation(Element, boolean hasToSnap)`, always called with `true`.
  ///
  /// The `width`/`height` branch is the pre-3.x form, where the element carried the bounding box
  /// of the drawn marker and the location is its centre. Note the asymmetry upstream has and
  /// this keeps: the legacy branch parses **doubles** and rounds, the modern branch parses
  /// **ints** and would throw on `x="1.5"`.
  private static func location(of elt: SvgElement) throws -> Location {
    if elt.hasAttribute("width") && elt.hasAttribute("height") {
      let x = try SvgReader.parseJavaDouble(elt.getAttribute("x"))
      let y = try SvgReader.parseJavaDouble(elt.getAttribute("y"))
      let w = try SvgReader.parseJavaDouble(elt.getAttribute("width"))
      let h = try SvgReader.parseJavaDouble(elt.getAttribute("height"))
      return Location.create(
        SvgReader.javaRoundToInt(x + w / 2), SvgReader.javaRoundToInt(y + h / 2), hasToSnap: true)
    }
    let px = try SvgReader.parseJavaInt(elt.getAttribute("x"))
    let py = try SvgReader.parseJavaInt(elt.getAttribute("y"))
    return Location.create(px, py, hasToSnap: true)
  }

  /// `Location.create(parseInt(pinStr[0].trim()), parseInt(pinStr[1].trim()), true)`.
  private static func pinLocation(of elt: SvgElement) throws -> Location {
    let parts = splitOnComma(elt.getAttribute("pin"))
    guard parts.count >= 2 else {
      // `pinStr[1]` on a shorter array is an ArrayIndexOutOfBoundsException upstream: a
      // RuntimeException, caught by the caller as `fileAppearanceError`. D13 makes it a throw.
      throw SvgParseError.malformedNumber(elt.getAttribute("pin"))
    }
    let x = try SvgReader.parseJavaInt(javaTrim(parts[0]))
    let y = try SvgReader.parseJavaInt(javaTrim(parts[1]))
    return Location.create(x, y, hasToSnap: true)
  }

  /// `isInputPinReference(Element)`.
  ///
  /// `dir` is 4.1.0's spelling and wins whenever present; otherwise the direction comes from the
  /// legacy box width: 8 for an input (radius 4), 10 for an output (radius 5). Anything else
  /// reads as an output, which is what `isInputAppearance`'s `== INPUT_RADIUS` says.
  private static func isInputPinReference(_ elt: SvgElement) throws -> Bool {
    if elt.hasAttribute("dir") {
      return elt.getAttribute("dir") == "in"
    }
    let width = try SvgReader.parseJavaDouble(elt.getAttribute("width"))
    let radius = SvgReader.javaRoundToInt(width / 2.0)
    return AppearancePort.isInputAppearance(radius: radius)
  }

  /// `String.split(",")` at the default limit: interior and leading empties are kept, trailing
  /// ones are dropped, and an input with no comma comes back as one element: so `""` splits to
  /// `[""]`, a one-element array whose `[1]` is out of range.
  private static func splitOnComma(_ text: String) -> [String] {
    var parts = text.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
    while let last = parts.last, last.isEmpty { parts.removeLast() }
    return parts
  }
}
