// AppearanceAnchor.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// com/cburch/logisim/circuit/appear/AppearanceAnchor.java. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore licensed GPL-3.0-only.
// See LICENSE.md.

import LogisimKernel

/// `com.cburch.logisim.circuit.appear.AppearanceAnchor`.
///
/// The `<circ-anchor>` element: the point a subcircuit's custom appearance is placed by, plus
/// the direction its ports are considered to face.
public final class AppearanceAnchor: AppearanceElement {
  /// `AppearanceAnchor.FACING`.
  ///
  /// `Attributes.forDirection` gives the same exact, case-sensitive `east`/`north`/`west`/
  /// `south` parse Java's `DirectionAttribute` does, which is what `AppearanceSvgReader` relies
  /// on when it reads the `facing=` attribute.
  public static let facing: Attribute<Direction> = Attributes.forDirection("facing")

  /// `AppearanceAnchor.ATTRIBUTES`.
  public static let attributeList: [AnyAttribute] = [facing]

  private static let radius = 3
  private static let indicatorLength = 8

  /// `SYMBOL_COLOR = new Color(0, 128, 0)`. Not used by the codec; the appearance editor paints
  /// with it (M6/M7), and it is kept here rather than in the renderer because it is this
  /// shape's own constant.
  public static let symbolColor = ColorSpec(red: 0, green: 128, blue: 0, alpha: 255)

  /// Java initialises `factingDirection = Direction.EAST` in the constructor; note the field's
  /// spelling is upstream's typo, not reproduced. An `<circ-anchor>` with no `facing=` attribute
  /// therefore reads back as east, which is why the legacy `x`/`y`/`width`/`height` form (which
  /// never carries `facing`) converts to `facing="east"`.
  public private(set) var facingDirection: Direction = .east

  public override init(_ location: Location) {
    super.init(location)
  }

  public override var displayName: String { "Anchor" }

  public override var attributes: [AnyAttribute] { AppearanceAnchor.attributeList }

  public override func rawValue(_ attribute: AnyAttribute) -> AttributeValue? {
    attribute === AppearanceAnchor.facing ? .direction(facingDirection.attributeDirection) : nil
  }

  /// `updateValue(Attribute<?>, Object)`: sets `FACING`, and defers anything else to the base
  /// class, which does nothing.
  public override func setRawValue(_ attribute: AnyAttribute, _ value: AttributeValue?) throws {
    guard attribute === AppearanceAnchor.facing else {
      try super.setRawValue(attribute, value)
      return
    }
    guard case .direction(let direction)? = value,
      let parsed = Direction(attributeDirection: direction)
    else { return }
    facingDirection = parsed
  }

  public override var bounds: Bounds {
    let base = bounds(radius: AppearanceAnchor.radius)
    let end = location.translate(
      facingDirection, AppearanceAnchor.radius + AppearanceAnchor.indicatorLength)
    return base.add(end)
  }

  public override func contains(_ loc: Location, assumeFilled: Bool) -> Bool {
    if isInCircle(loc, AppearanceAnchor.radius) { return true }
    let center = location
    let end = center.translate(
      facingDirection, AppearanceAnchor.radius + AppearanceAnchor.indicatorLength)
    if facingDirection == .east || facingDirection == .west {
      return abs(loc.y - center.y) < 2 && (loc.x < center.x) != (loc.x < end.x)
    }
    return abs(loc.x - center.x) < 2 && (loc.y < center.y) != (loc.y < end.y)
  }

  public override func handles(_ gesture: HandleGesture?) -> [Handle] {
    let center = location
    let end = center.translate(
      facingDirection, AppearanceAnchor.radius + AppearanceAnchor.indicatorLength)
    return [Handle(self, center), Handle(self, end)]
  }

  public override func matches(_ other: CanvasObject) -> Bool {
    guard let that = other as? AppearanceAnchor else { return false }
    return super.matches(that) && facingDirection == that.facingDirection
  }

  public override func matchesHashCode() -> Int {
    super.matchesHashCode() &* 31 &+ facingDirection.hashValue
  }

  public override func cloned() -> CanvasObject {
    let copy = AppearanceAnchor(location)
    copy.facingDirection = facingDirection
    return copy
  }

  /// `toSvgElement(Document)`.
  ///
  /// The 4.1.0 form is `x`/`y`/`facing`, replacing the pre-3.x `x`/`y`/`width`/`height` box;
  /// `AppearanceSvgReader.getLocation` still reads the old one, but nothing writes it. The
  /// emitted attribute order is `SvgElement`'s, i.e. alphabetical: `facing`, `x`, `y`.
  public override func toSvgElement() -> SvgElement {
    let elt = SvgElement("circ-anchor")
    elt.setAttribute("x", "\(location.x)")
    elt.setAttribute("y", "\(location.y)")
    // `Direction.toString()` is the lowercase token (`east`), which is `description` here.
    elt.setAttribute("facing", facingDirection.description)
    return elt
  }
}
