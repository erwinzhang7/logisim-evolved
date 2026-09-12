// InstanceComponent.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.instance.InstanceComponent, and the
// `Instance` facade that D3 folds into it), https://github.com/logisim-evolution/logisim-evolution.
// Copyright by the Logisim-evolution developers. This translation is a derivative work and is
// therefore GPL-3.0-only. See LICENSE.md.
//
// ── Scope ───────────────────────────────────────────────────────────────────────────────────
//
// This is the inert placement record: factory + location + attribute set + connection points,
// and nothing else. Upstream's `InstanceComponent` additionally carries `InstanceStateImpl`,
// `Port`/`InstanceData` plumbing and the paint/poke surface; all of that is M3–M6 and is
// deliberately absent rather than stubbed.
//
// ── D3: the `Instance` facade is gone ───────────────────────────────────────────────────────
//
// Upstream pairs every `InstanceComponent` with an `Instance` that forwards to it, and the two
// hold each other: an unconditional strong two-cycle on *every placed component in every
// circuit*, which is the highest-multiplicity ARC leak in the app. `Instance` is a pure
// forwarder, so it collapses into this type and callers use the component directly.

import Foundation
import LogisimKernel

/// A component placed in a circuit: what it is, where it is, and how it is configured.
///
/// `final class` and deliberately not `Equatable`/`Hashable`: D4. Key it with `ComponentRef`.
public final class InstanceComponent: Component {

  private let listeners = ComponentListenerRegistry()

  /// `getFactory()` / `setFactory(ComponentFactory)`.
  ///
  /// Mutable because the `.circ` repair passes retarget a component at a replacement factory
  /// (e.g. the pre-2.7.2 wiring-library moves) without rebuilding it.
  public private(set) var factory: any ComponentFactory

  /// `getLocation()`.
  public let location: Location

  /// `getAttributeSet()`. Owned: the component is the only thing that keeps it alive.
  public let attributeSet: any AttributeSet

  /// The `lib=` token the `<comp>` element carried, preserved verbatim.
  ///
  /// Not present upstream; the writer there recomputes the index from the library list. It is
  /// kept here because D8 requires an unresolved component to be re-emitted byte-identically, and
  /// because a component's originating library is genuine provenance that the loader should not
  /// have to reconstruct. It is a *record of what was read*, never the authority for what gets
  /// written for a resolved component.
  public let sourceLibraryReference: String?

  private var endArray: [EndData]

  /// A subscription to the attribute set, held so label changes can be forwarded as
  /// `labelChanged` component events exactly as upstream's `InstanceComponent` does.
  private var attributeSubscription: AttributeSubscription?

  public init(
    factory: any ComponentFactory,
    location: Location,
    attributes: any AttributeSet,
    ends: [EndData] = [],
    sourceLibraryReference: String? = nil
  ) {
    self.factory = factory
    self.location = location
    self.attributeSet = attributes
    self.endArray = ends
    self.sourceLibraryReference = sourceLibraryReference

    // D3: the token is owned by this component and the closure captures `self` weakly, so the
    // attribute set never gains a strong edge back to the component.
    attributeSubscription = attributes.addAttributeListener(
      onValueChanged: { [weak self] event in
        guard let self else { return }
        guard let attribute = event.attribute, attribute === StdAttr.label else { return }
        self.listeners.fireLabelChanged(ComponentEvent(source: self, data: event))
      })
  }

  public func setFactory(_ factory: any ComponentFactory) {
    self.factory = factory
  }

  /// `getBounds()`: the factory's offset box translated to this component's location.
  public var bounds: Bounds {
    let offset = factory.offsetBounds(attributeSet)
    return offset.translate(location.x, location.y)
  }

  /// `getEnds()`.
  public var ends: [EndData] { endArray }

  /// `getEnd(int)`.
  ///
  /// Upstream indexes the array directly and lets an out-of-range index throw
  /// `ArrayIndexOutOfBoundsException`. That is *not* reachable from a file, the index always
  /// comes from a loop over `getEnds()` or from a port number the factory itself defined, so it
  /// stays a trap, matching D13's "genuine programmer error" carve-out.
  public func end(at index: Int) -> EndData {
    precondition(
      endArray.indices.contains(index),
      "end index \(index) out of range for \(factory.name) at \(location)")
    return endArray[index]
  }

  /// `InstanceComponent.setPorts` / `Instance.setPorts`, reduced to what the inert model needs.
  ///
  /// Fires `endChanged` with the old and new lists, which is what `Circuit` listens for in order
  /// to keep its connection map current.
  public func setEnds(_ newEnds: [EndData]) {
    let oldEnds = endArray
    endArray = newEnds
    listeners.fireEndChanged(
      ComponentEvent(source: self, oldData: oldEnds, data: newEnds))
  }

  /// `contains(Location)`: upstream tests the bounds box, then lets a component narrow it via
  /// its own `contains`. With no component implementations yet, the box is the whole test.
  public func contains(_ point: Location) -> Bool {
    bounds.contains(point)
  }

  /// `endsAt(Location)`.
  public func endsAt(_ point: Location) -> Bool {
    endArray.contains { $0.location == point }
  }

  /// `getFeature(Object)`. Features are supplied by component implementations (M4/M5); a bare
  /// placement record has none.
  public func feature(_ key: ComponentFeatureKey) -> Any? { nil }

  @discardableResult
  public func addComponentListener(_ listener: ComponentListener) -> ComponentSubscription? {
    listeners.add(listener)
  }

  /// `InstanceComponent.fireInvalidated()`.
  public func fireInvalidated() {
    listeners.fireComponentInvalidated(ComponentEvent(source: self))
  }
}

extension InstanceComponent: CustomStringConvertible {
  public var description: String {
    "InstanceComponent[\(factory.name) @ \(location)]"
  }
}
