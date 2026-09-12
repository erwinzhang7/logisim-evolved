// AppearancePort.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// com/cburch/logisim/circuit/appear/AppearancePort.java. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore licensed GPL-3.0-only.
// See LICENSE.md.

import LogisimKernel

/// `com.cburch.logisim.circuit.appear.AppearancePort`.
///
/// The `<circ-port>` element: one point on a subcircuit's custom appearance, bound to one `Pin`
/// component inside the circuit. Its own location is where the wire attaches on the *outside*;
/// `pinLocation` is where the `Pin` sits *inside*, and is the identity written to `pin="x,y"`.
///
/// See `AppearanceElement`'s header for why the bound pin is three stored facts rather than a
/// component reference.
public final class AppearancePort: AppearanceElement {
  /// `INPUT_RADIUS`: also the value `isInputAppearance` recognises in the legacy
  /// `width`/`height` form.
  public static let inputRadius = 4
  /// `OUTPUT_RADIUS`.
  public static let outputRadius = 5
  /// `MINOR_RADIUS`: the filled dot drawn at the centre of either shape.
  public static let minorRadius = 2

  /// `AppearancePort.COLOR = Color.BLUE`. Codec-irrelevant; kept with the shape for M6/M7.
  public static let color = ColorSpec(red: 0, green: 0, blue: 255, alpha: 255)

  /// `pin.getLocation()`. This is the *component's* location, not the `pin=` attribute as it was
  /// parsed: `AppearanceSvgReader` matches a parsed location against the real pins and binds the
  /// one it finds, and `toSvgElement` then writes the bound pin's own location back. The two
  /// agree by construction, matching is equality, but taking it from the binding is what
  /// upstream does and is the correct source if `Location.create`'s snapping ever moves the
  /// parsed value.
  public private(set) var pinLocation: Location

  /// `Pin.FACTORY.isInputPin(pin)`, resolved when the shape was built.
  ///
  /// Upstream's `isInput()` is `pin == null || Pin.FACTORY.isInputPin(pin)`, so an unbound port
  /// reads as an input; a port built by this port's reader is always bound, and a port built
  /// with no binding at all takes the same `true` default.
  public private(set) var isInput: Bool

  /// Identity of the bound `Pin` component, for `matches`. Held as `AnyObject` because the
  /// component types live above this module, see `AppearanceElement`'s header.
  public private(set) weak var pinReference: AnyObject?

  public init(
    _ location: Location, pinLocation: Location, isInput: Bool, pinReference: AnyObject? = nil
  ) {
    self.pinLocation = pinLocation
    self.isInput = isInput
    self.pinReference = pinReference
    super.init(location)
  }

  /// `isInputAppearance(int radius)`; the backwards-compatibility test that reads a port's
  /// direction out of the legacy `width`/`height` box when no `dir=` attribute is present.
  public static func isInputAppearance(radius: Int) -> Bool { radius == inputRadius }

  /// `setPin(Instance)`, adapted: the three facts replace the instance.
  public func setPin(location: Location, isInput: Bool, reference: AnyObject?) {
    self.pinLocation = location
    self.isInput = isInput
    self.pinReference = reference
  }

  public override var displayName: String { "Port" }

  public override var bounds: Bounds {
    bounds(radius: isInput ? AppearancePort.inputRadius : AppearancePort.outputRadius)
  }

  /// An input is a square and is hit-tested by its bounding box; an output is a circle and is
  /// hit-tested by radius.
  public override func contains(_ loc: Location, assumeFilled: Bool) -> Bool {
    isInput ? bounds.contains(loc) : isInCircle(loc, AppearancePort.outputRadius)
  }

  public override func handles(_ gesture: HandleGesture?) -> [Handle] {
    let loc = location
    let r = isInput ? AppearancePort.inputRadius : AppearancePort.outputRadius
    return [
      Handle(self, loc.translate(-r, -r)),
      Handle(self, loc.translate(r, -r)),
      Handle(self, loc.translate(r, r)),
      Handle(self, loc.translate(-r, r)),
    ]
  }

  public override func matches(_ other: CanvasObject) -> Bool {
    guard let that = other as? AppearancePort else { return false }
    return super.matches(that) && pinReference === that.pinReference
  }

  /// Java is `super.matchesHashCode() + pin.hashCode()` and would `NullPointerException` on an
  /// unbound port. D13: an unbound port contributes nothing rather than trapping.
  public override func matchesHashCode() -> Int {
    guard let pinReference else { return super.matchesHashCode() }
    return super.matchesHashCode() &+ ObjectIdentifier(pinReference).hashValue
  }

  public override func cloned() -> CanvasObject {
    AppearancePort(
      location, pinLocation: pinLocation, isInput: isInput, pinReference: pinReference)
  }

  /// `toSvgElement(Document)`: **the 4.1.0 form**, and the whole point of this file.
  ///
  /// 4.1.0 writes `x`, `y`, `dir` and `pin`. Files written by 2.x/3.x carry the older
  /// `x`/`y`/`width`/`height` box instead, where the location is the box centre and the
  /// direction is inferred from the width (8 → input, 10 → output). `AppearanceSvgReader` reads
  /// both; nothing writes the old one, so opening a legacy file and saving it converts every
  /// `<circ-port>`, which is exactly what the migration gate compares against.
  ///
  /// Emitted attribute order is `SvgElement`'s, i.e. alphabetical: `dir`, `pin`, `x`, `y`.
  public override func toSvgElement() -> SvgElement {
    let elt = SvgElement("circ-port")
    elt.setAttribute("x", "\(location.x)")
    elt.setAttribute("y", "\(location.y)")
    elt.setAttribute("dir", isInput ? "in" : "out")
    elt.setAttribute("pin", "\(pinLocation.x),\(pinLocation.y)")
    return elt
  }
}
