// AbstractCanvasObject.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// com/cburch/draw/model/AbstractCanvasObject.java. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore licensed GPL-3.0-only.
// See LICENSE.md.
//
// ── Why this subclasses Kernel's `AbstractAttributeSet` ─────────────────────────────────────
//
// Java's `AbstractCanvasObject implements AttributeSet, CanvasObject` directly: a canvas shape
// *is* its own attribute set (unlike a component, which has a separate `AttributeSet` object).
// `LogisimKernel.AbstractAttributeSet` already provides exactly the machinery Java's interface
// needs, a listener registry, `getValue`/`setValue` built on a `rawValue`/`setRawValue` pair,
// `copy()` built on `makeCopyInstance`/`copyInto`, so every shape gets it by inheriting from
// that class instead of reimplementing it, and `DrawAttr`'s attributes are ordinary
// `LogisimKernel.Attribute<V>` values (D5), not a parallel type.
//
// ── The one behavioural override: `setValue` deduplicates ───────────────────────────────────
//
// Java's `AbstractCanvasObject.setValue` is `final`, and it does its own equality check before
// calling `updateValue`/firing anything:
//
//     final var same = Objects.equals(old, value);
//     if (!same) { updateValue(attr, value); fire attributeValueChanged; }
//
// `AbstractAttributeSet.setValue` (Kernel) does not do this; it is shared by component
// attribute sets, most of which do not need it. `AttributeValue` is `Hashable`, so the override
// below reproduces Java's check at the *storage* level without requiring `V: Equatable`.
//
// ── Seam: no `paint`, no `Graphics` ──────────────────────────────────────────────────────────
//
// `setForFill`/`setForStroke` are ported as `shouldPaintFill`/`shouldPaintStroke`: pure
// booleans computed from attribute values, with the `Graphics` mutation (`g.setColor`,
// `GraphicsUtil.switchToWidth`) dropped. The renderer reads these plus `getValue(DrawAttr.*)`
// directly instead of receiving a partially-configured `Graphics`.

import LogisimKernel

/// `com.cburch.draw.model.AbstractCanvasObject`.
open class AbstractCanvasObject: AbstractAttributeSet, CanvasObject {
  private static let overlapTries = 50
  private static let generateRandomTries = 20

  public override init() {
    super.init()
  }

  // MARK: - AttributeSet (Kernel) plumbing shared by every shape

  /// Subclasses override with their `DrawAttr.*` list (Java's `getAttributes()`).
  open override var attributes: [AnyAttribute] {
    fatalError("AbstractCanvasObject subclasses must override `attributes`")
  }

  open override func rawValue(_ attribute: AnyAttribute) -> AttributeValue? {
    fatalError("AbstractCanvasObject subclasses must override `rawValue(_:)`")
  }

  /// Java's per-shape `updateValue(Attribute<?>, Object)`: an attribute this shape does not
  /// recognise is silently ignored (no exception, no-op), which is why this is not `throws`
  /// in the way `AttributeSets.FixedSet` is; canvas shapes were never built on that class.
  open override func setRawValue(_ attribute: AnyAttribute, _ value: AttributeValue?) throws {
    fatalError("AbstractCanvasObject subclasses must override `setRawValue(_:_:)`")
  }

  /// Java's `final <V> void setValue(Attribute<V> attr, V value)`: see the file header for why
  /// this overrides the Kernel default instead of inheriting it.
  public final override func setValue<V>(_ attribute: Attribute<V>, _ value: V?) throws {
    let old = rawValue(attribute)
    let new = value.map(attribute.encode)
    guard old != new else { return }
    try setRawValue(attribute, new)
    fireAttributeValueChanged(attribute, value: new, oldValue: old)
  }

  open override func makeCopyInstance() -> AbstractAttributeSet {
    guard let copy = cloned() as? AbstractAttributeSet else {
      preconditionFailure("AbstractCanvasObject.cloned() must return an AbstractCanvasObject")
    }
    return copy
  }

  /// `cloned()` already produces a complete, independent object (see below), so there is
  /// nothing left for `copyInto` to do; it exists only to satisfy the abstract contract.
  open override func copyInto(_ destination: AbstractAttributeSet) {}

  // MARK: - CanvasObject

  open var attributeSet: any AttributeSet { self }

  open func canDeleteHandle(_ loc: Location) -> Handle? { nil }
  open func canInsertHandle(_ desired: Location) -> Handle? { nil }
  open func canMoveHandle(_ handle: Handle) -> Bool { false }
  open var canRemove: Bool { true }

  /// Subclasses override to produce a fully independent copy (Java's `Object.clone()` plus a
  /// fresh listener list; ARC has no generic shallow-clone, so each concrete shape's copy
  /// constructor plays that role instead).
  open func cloned() -> CanvasObject {
    fatalError("AbstractCanvasObject subclasses must override `cloned()`")
  }

  open func contains(_ loc: Location, assumeFilled: Bool) -> Bool {
    fatalError("AbstractCanvasObject subclasses must override `contains(_:assumeFilled:)`")
  }

  open func deleteHandle(_ handle: Handle) -> Handle? {
    preconditionFailure(CanvasObjectMisuse.deleteHandleUnsupported.description)
  }

  open var bounds: Bounds {
    fatalError("AbstractCanvasObject subclasses must override `bounds`")
  }

  open var displayName: String {
    fatalError("AbstractCanvasObject subclasses must override `displayName`")
  }

  /// Java's default: `getDisplayNameAndLabel()` returns `getDisplayName()`. No shape here
  /// overrides it.
  open var displayNameAndLabel: String { displayName }

  open func handles(_ gesture: HandleGesture?) -> [Handle] {
    fatalError("AbstractCanvasObject subclasses must override `handles(_:)`")
  }

  open func insertHandle(_ desired: Handle, after previous: Handle?) throws {
    throw CanvasObjectMisuse.insertHandleUnsupported
  }

  open func matches(_ other: CanvasObject) -> Bool {
    fatalError("AbstractCanvasObject subclasses must override `matches(_:)`")
  }

  open func matchesHashCode() -> Int {
    fatalError("AbstractCanvasObject subclasses must override `matchesHashCode()`")
  }

  open func moveHandle(_ gesture: HandleGesture) -> Handle? {
    preconditionFailure(CanvasObjectMisuse.moveHandleUnsupported.description)
  }

  /// `AbstractCanvasObject.overlaps`; a Monte-Carlo point-sampling test. Java draws from
  /// `java.util.Random`; exact PRNG-stream parity is not attempted (this feeds interactive
  /// z-order/selection heuristics in `draw/canvas`, out of scope here, never `.circ`/SVG
  /// content), so this uses `SystemRandomNumberGenerator`. The sampling algorithm, bounding-box
  /// intersection first, then up to 50 alternating trial points, is otherwise identical.
  open func overlaps(_ other: CanvasObject) -> Bool {
    let a = bounds
    let b = other.bounds
    let c = a.intersect(b)
    guard c.width != 0, c.height != 0 else { return false }

    var rng = SystemRandomNumberGenerator()
    if let that = other as? AbstractCanvasObject {
      for i in 0..<AbstractCanvasObject.overlapTries {
        if i % 2 == 0 {
          if let loc = randomPoint(in: c, using: &rng), that.contains(loc, assumeFilled: false) {
            return true
          }
        } else {
          if let loc = that.randomPoint(in: c, using: &rng), self.contains(loc, assumeFilled: false)
          {
            return true
          }
        }
      }
      return false
    } else {
      for _ in 0..<AbstractCanvasObject.overlapTries {
        if let loc = randomPoint(in: c, using: &rng), other.contains(loc, assumeFilled: false) {
          return true
        }
      }
      return false
    }
  }

  /// `AbstractCanvasObject.getRandomPoint(Bounds, Random)` default body. Several shapes
  /// (`Rectangle`, `RoundRectangle`, `Oval`, `Poly`, `Line`) override this to sample along their
  /// boundary instead when stroked; those overrides live on the concrete shapes.
  open func randomPoint(in bounds: Bounds, using rng: inout SystemRandomNumberGenerator) -> Location?
  {
    let x = bounds.x
    let y = bounds.y
    let w = bounds.width
    let h = bounds.height
    guard w > 0, h > 0 else { return nil }
    for _ in 0..<AbstractCanvasObject.generateRandomTries {
      let loc = Location.create(
        x + Int.random(in: 0..<w, using: &rng), y + Int.random(in: 0..<h, using: &rng),
        hasToSnap: false)
      if contains(loc, assumeFilled: false) { return loc }
    }
    return nil
  }

  open func translate(_ dx: Int, _ dy: Int) {
    fatalError("AbstractCanvasObject subclasses must override `translate(_:_:)`")
  }

  /// `toSvgElement(Document)`, minus the `Document` factory parameter; this module owns its
  /// own lightweight `SvgElement` (see `Svg/SvgElement.swift`) instead of `org.w3c.dom`, so
  /// there is nothing for a document factory to do.
  open func toSvgElement() -> SvgElement {
    fatalError("AbstractCanvasObject subclasses must override `toSvgElement()`")
  }

  // MARK: - Fill/stroke decisions (rendering seam)

  /// `AbstractCanvasObject.setForFill`, minus the `Graphics` mutation: whether this shape's
  /// interior should be painted at all. The renderer additionally reads
  /// `getValue(DrawAttr.fillColor)` for the colour.
  public var shouldPaintFill: Bool {
    if attributes.contains(where: { $0 === DrawAttr.paintType }) {
      if let paintType = getValue(DrawAttr.paintType), paintType == DrawAttr.paintStroke {
        return false
      }
    }
    if let color = getValue(DrawAttr.fillColor), color.alpha == 0 { return false }
    return true
  }

  /// `AbstractCanvasObject.setForStroke`, minus the `Graphics` mutation.
  public var shouldPaintStroke: Bool {
    if attributes.contains(where: { $0 === DrawAttr.paintType }) {
      if let paintType = getValue(DrawAttr.paintType), paintType == DrawAttr.paintFill {
        return false
      }
    }
    guard let width = getValue(DrawAttr.strokeWidth), width > 0 else { return false }
    if let color = getValue(DrawAttr.strokeColor), color.alpha == 0 { return false }
    return true
  }
}
