// SplitterFactory.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.circuit.SplitterFactory),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16). See `SplitterParameters.swift`'s header for why
// this file lives under `LogisimStd/Wiring/` rather than mirroring Java's `circuit` package.
//
// ── This is one of the builtin tools the M2 migration gate needs ───────────────────────────
//
// `WiringLibrary` adds `SplitterFactory.instance` to the toolbar exactly like `Pin.FACTORY` and
// `PullResistor.FACTORY` (see `WiringLibrary.swift`). `XmlWriter` omits a `<tool name="Splitter">`
// attribute's `<a>` element precisely when the stored value equals what `defaultAttributeValue`
// below returns, so both the version-dependent `ATTR_APPEARANCE` default and the per-bit
// `bitN` default must be exact or every file naming a Splitter with an edited default mismatches
// the oracle. See `decisions.md`'s `WHY THIS FAMILY MATTERS MORE` block and
// `SplitterAttributes.swift`'s header for why the per-bit default is `which + 1`, not whatever
// `computeDistribution` actually assigned.
//
// `Splitter` does not fit the `InstanceFactory`/`Port`/`InstanceState` chassis every other
// `LogisimStd` component uses (`PATTERNS.md` §0) because it does not in Java either; it is a
// direct `AbstractComponentFactory`/`ManagedComponent` pair, not an `InstanceFactory`. This is a
// deliberate, documented exception to "follow `PATTERNS.md` literally", made because Java's own
// architecture already isolates Splitter the same way.

import Foundation
import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.circuit.SplitterFactory`.
public final class SplitterFactory: AbstractComponentFactory {

  /// `SplitterFactory.instance`. Java's constructor is `private`, so this is the only instance.
  public static let instance = SplitterFactory()

  private init() {
    super.init(requiresLabel: false, requiresGlobalClock: false)
  }

  public override var name: String { Splitter.id }

  public override func createAttributeSet() -> any AttributeSet { SplitterAttributes() }

  /// `createComponent(Location, AttributeSet)`.
  ///
  /// D13: Java would hit a `ClassCastException` on a `.circ` repair pass that retargeted a
  /// `<comp name="Splitter">` element at a foreign attribute set; here that is a thrown
  /// `ComponentError.wrongAttributeSet` rather than a trap, matching every other factory's
  /// `validateAttributeSet` convention in this module even though `AbstractComponentFactory`
  /// itself has no such hook (`InstanceFactoryBase` is not Splitter's base).
  public override func createComponent(
    location: Location, attributes: any AttributeSet
  ) throws -> any Component {
    guard let attrs = attributes as? SplitterAttributes else {
      throw ComponentError.wrongAttributeSet(factory: Splitter.id)
    }
    return Splitter(location: location, attributes: attrs)
  }

  /// `getOffsetBounds(AttributeSet)` (`SplitterFactory.java:108-119`).
  public override func offsetBounds(_ attributes: any AttributeSet) -> Bounds {
    guard let attrs = attributes as? SplitterAttributes else { return Bounds.empty }
    let fanout = Int(attrs.fanout)
    let parms = attrs.parameters()
    let xEnd0 = parms.end0X
    let yEnd0 = parms.end0Y
    var bounds = Bounds.create(0, 0, 1, 1)
    bounds = bounds.add(xEnd0, yEnd0)
    bounds = bounds.add(
      xEnd0 + (fanout - 1) * parms.endToEndDeltaX,
      yEnd0 + (fanout - 1) * parms.endToEndDeltaY)
    return bounds
  }

  /// `getDefaultAttributeValue(Attribute<?>, LogisimVersion)` (`SplitterFactory.java:67-80`).
  public override func defaultAttributeValue(
    _ attribute: AnyAttribute, version: LogisimVersion
  ) -> AttributeValue? {
    if attribute === SplitterAttributes.attrAppearance {
      // Java: `ver.compareTo(new LogisimVersion(2, 6, 4)) < 0 ? APPEAR_LEGACY : APPEAR_LEFT`.
      let appearance: SplitterAppearance =
        version.compare(to: LogisimVersion(2, 6, 4)) < 0 ? .legacy : .left
      return SplitterAttributes.attrAppearance.encode(appearance)
    }
    // `attr instanceof SplitterAttributes.BitOutAttribute -> bitOutAttr.getDefault()`, i.e.
    // `which + 1`. See `SplitterAttributes.swift`'s header for why the index is recovered from
    // the `.circ` name rather than from a `which` field: every `bitN` attribute this factory is
    // ever asked about was created with exactly that name by `SplitterAttributes`.
    if attribute.name.hasPrefix("bit"), let which = Int(attribute.name.dropFirst(3)) {
      return .integer(Int32(which + 1))
    }
    return super.defaultAttributeValue(attribute, version: version)
  }

  /// `getFeature(Object, AttributeSet)`; only the facing-attribute key is meaningful without a
  /// UI. `KeyConfigurator.class` (the attribute-table arrow-key handler) is UI surface and is not
  /// declared in `ComponentFactoryFeatureKey` at all (see `ComponentFactory.swift`'s header).
  public override func feature(
    _ key: ComponentFactoryFeatureKey, _ attributes: any AttributeSet
  ) -> Any? {
    if key == .facingAttribute { return StdAttr.facing }
    return super.feature(key, attributes)
  }

  // NOT PORTED: `drawGhost` (M6/D6/D9), draws either the legacy or the line-based ghost via
  // `SplitterPainter`; `paintIcon`, draws `SplitterIcon` (M6). See `Splitter.swift`'s header
  // for why `SplitterPainter` itself is not ported at all yet.
}
