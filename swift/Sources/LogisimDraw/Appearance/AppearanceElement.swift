// AppearanceElement.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// com/cburch/logisim/circuit/appear/AppearanceElement.java. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore licensed GPL-3.0-only.
// See LICENSE.md.
//
// ── Why `logisim.circuit.appear` lands in `LogisimDraw` and not `LogisimFile` ────────────────
//
// Upstream splits these two ways: `com.cburch.draw.*` is the generic shape model and
// `com.cburch.logisim.circuit.appear.*` is the circuit-specific part that knows about `Pin`
// instances. That split cannot be reproduced literally here, because `LogisimStd` (where `Pin`
// lives) depends on `LogisimFile`, so nothing under `LogisimFile` can name a `Pin`.
//
// The dependency is dissolved rather than inverted. `AppearancePort` needs exactly three facts
// about its pin, the pin's location, whether it is an input, and its object identity, so it
// stores those three facts instead of the component. Deciding *which* pin a `<circ-port>` binds
// to stays on the `LogisimFile` side, where the components are; everything the SVG round trip
// needs is here, where the rest of the shape model already is.
//
// The consequence to keep in mind: `isInput` is resolved once, when the shape is built. Upstream
// re-asks `Pin.FACTORY.isInputPin(pin)` on every paint and every save, so a pin whose type
// attribute is edited after load changes its appearance immediately there and does not here.
// Wiring that up belongs with the appearance editor (M6/M7), and `setPin(location:isInput:)`
// below is the hook for it; it is what `AppearancePort.setPin` is for upstream.

import LogisimKernel

/// `com.cburch.logisim.circuit.appear.AppearanceElement`.
///
/// The shared base of `AppearanceAnchor` and `AppearancePort`: a shape that is a single point,
/// carries no fill/stroke attributes, cannot be deleted, and is always drawn on top.
open class AppearanceElement: AbstractCanvasObject {
  private var locationValue: Location

  public init(_ location: Location) {
    self.locationValue = location
    super.init()
  }

  /// `getLocation()`.
  public var location: Location { locationValue }

  /// `canRemove()`; these two shapes are structural; the editor may move them but not delete
  /// them.
  open override var canRemove: Bool { false }

  /// `getAttributes()` returns `Collections.emptyList()` on the base class. `AppearanceAnchor`
  /// overrides it with its one `facing` attribute.
  open override var attributes: [AnyAttribute] { [] }

  /// Java's `<V> V getValue(Attribute<V>)` returns null unconditionally here. `AbstractAttributeSet`
  /// builds `getValue` on `rawValue`, so returning nil is the same statement.
  open override func rawValue(_ attribute: AnyAttribute) -> AttributeValue? { nil }

  /// `updateValue(Attribute<?>, Object)`; "nothing to do".
  open override func setRawValue(_ attribute: AnyAttribute, _ value: AttributeValue?) throws {}

  /// `getBounds(int radius)`.
  public func bounds(radius: Int) -> Bounds {
    Bounds.create(
      locationValue.x - radius, locationValue.y - radius, 2 * radius, 2 * radius)
  }

  /// `isInCircle(Location, int)`: note the strict `<`, so a point exactly on the circle is out.
  public func isInCircle(_ loc: Location, _ radius: Int) -> Bool {
    let dx = loc.x - locationValue.x
    let dy = loc.y - locationValue.y
    return dx * dx + dy * dy < radius * radius
  }

  /// `getRandomPoint(Bounds, Random)`. Upstream's comment: "this is only used to determine what
  /// lies on top of what but the elements will always be on top anyway".
  open override func randomPoint(
    in bounds: Bounds, using rng: inout SystemRandomNumberGenerator
  ) -> Location? {
    nil
  }

  /// `matches(CanvasObject)` on the base class compares locations only; both subclasses call up
  /// to this and then add their own test.
  open override func matches(_ other: CanvasObject) -> Bool {
    guard let that = other as? AppearanceElement else { return false }
    return locationValue == that.locationValue
  }

  open override func matchesHashCode() -> Int {
    locationValue.hashValue
  }

  open override func translate(_ dx: Int, _ dy: Int) {
    locationValue = locationValue.translate(dx, dy)
  }

  /// Subclass hook for `translate`-free relocation. Not upstream API; the editor's move
  /// machinery is M6/M7 and this keeps `locationValue` private until then.
  func setLocation(_ value: Location) {
    locationValue = value
  }
}
