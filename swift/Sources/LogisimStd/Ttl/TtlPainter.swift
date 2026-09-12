// TtlPainter.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.instance.InstancePainter and the parts of
// com.cburch.logisim.comp.ComponentDrawContext the TTL family actually calls),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ══ SEAM #11-shaped, and the third of its exact kind ════════════════════════════════════════
//
// `AbstractTtlGate` had two paint entry points and they carried *bespoke* signatures that no
// protocol named:
//
//     paintInstance(_ painter: SceneBuilder, _ state: any InstanceState)
//     paintGhost(_ painter: SceneBuilder, attributes: any AttributeSet, bounds: Bounds)
//
// `CircuitRenderer.render` dispatches on `component.factory as? any InstancePaintable`
// (`CircuitRenderer.swift:121`) and `ToolOverlayScene` on the same cast
// (`ToolOverlayScene.swift:290,313`). `AbstractTtlGate` conformed to NEITHER `InstancePaintable`
// nor `ComponentPaintable`, so both casts failed and all 61 74xx chips rendered as nothing,
// while 47 `paintInternal` implementations, `Drawgates`' eight symbol routines and a measured
// 61/61 correct label placement sat behind the failed cast, complete and unreachable.
//
// This is seam #9 (`IoInstancePainter` with no conformer) and seam #10 (`MemPainter` with no
// conformer) a third time, with one difference that made it *quieter*: the io and memory
// families at least declared a protocol, so `deadseam.py`-style "declared and never conformed"
// searches could see them. TTL declared nothing at all; its paint entry points were plain
// methods on a class, which is indistinguishable from dead private code to every tool in
// `tools/`. Nothing was unconformed; the conformance simply did not exist.
//
// ── WHY THE SIGNATURES KEEP THEIR (emitter, state) SHAPE ────────────────────────────────────
//
// Every paint method in this directory is `(_ painter: SceneBuilder, _ state: …, …)`: the D6
// emitter and, separately, the thing that answers "which component, drawn how". Upstream fuses
// both into `InstancePainter` and writes `painter.getGraphics()` at the top of each method; the
// port split them when `Instance/` was owned by another slice. The split is kept, 47
// `paintInternal` bodies and 26 `paintBase` call sites are written against it, and only the
// *second* parameter's type changes, from `any InstanceState` to `any TtlPainter`.
//
// That is not cosmetic. `InstancePainter` deliberately does **not** conform to `InstanceState`
// (see `InstancePainter.swift:332-334`: `InstanceState.component` is non-optional and a ghost
// genuinely has none), so the old signature could never have been fed by the renderer, whatever
// conformance was bolted on. The type had to change for the seam to close at all.
//
// It also makes the type system state something true that the old signature did not: paint gets
// a *read-only* view. `InstanceState` offers `setPort`, `setData` and `fireInvalidated`; nothing
// in this family calls them from a paint path (measured: the only member any `paintInternal`
// reads is `state.data`, 7 sites), and upstream's `InstancePainter` throws
// `UnsupportedOperationException` from all three. Narrowing the parameter removes the ability to
// call them rather than relying on nobody trying.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

// MARK: - TtlPainter

/// `com.cburch.logisim.instance.InstancePainter`, restricted to what the TTL family draws with.
///
/// Deliberately tiny. The member set is the measured one: `getBounds()` and
/// `getAttributeValue(FACING)`/`(DRAW_INTERNAL_STRUCTURE)` in `paintBase`/`paintInstance`,
/// `getData()` in the seven stateful chips' `paintInternal`, and the two composites
/// `AbstractTtlGate.paintInstance` opens with upstream (`AbstractTtlGate.java:287-290`:
/// `painter.drawPorts(); … painter.drawLabel();`).
///
/// There is no emitter member: this family already receives the `SceneBuilder` as its first
/// parameter, which is why the signature change below is one token per method.
public protocol TtlPainter: AnyObject {

  /// `getAttributeSet()`.
  var attributeSet: any AttributeSet { get }

  /// `getBounds()`: **absolute** for a placed component (the offset bounds already translated
  /// by the location), and the *unlocated* offset bounds for a ghost, exactly as Java's
  /// `InstancePainter.getBounds()` answers in each case. The ghost caller translates the emitter
  /// instead (`ToolOverlayScene.paint`'s `pushTranslate`), so both arms of `paintBase` read the
  /// same field and neither needs to know which one it is in.
  var bounds: Bounds { get }

  /// `getData()`. `nil` before the first propagation and in a ghost; every one of the seven
  /// call sites in this family is already an `as?` cast that handles it.
  var data: (any InstanceData)? { get }

  /// `drawPorts()`: `ComponentDrawContext.drawPins`. First line of upstream's `paintInstance`.
  func drawPorts()

  /// `drawLabel()`: the component's `StdAttr.LABEL`, placed by
  /// `AbstractTtlGate.labelPlacement` (upstream's `computeTextField`). Second line of upstream's
  /// `paintInstance`, and the reason the family's 61/61 correct label placements were, until
  /// this file existed, never asked for.
  func drawLabel()
}

extension TtlPainter {
  /// `getAttributeValue(Attribute<E>)`.
  public func attributeValue<V>(_ attribute: Attribute<V>) -> V? {
    attributeSet.getValue(attribute)
  }

  /// `getAttributeValue` for an attribute `AbstractTtlGate.init` guarantees is in the template.
  public func attributeValue<V>(_ attribute: Attribute<V>, default fallback: @autoclosure () -> V)
    -> V
  {
    attributeSet.getValue(attribute) ?? fallback()
  }
}

// MARK: - TtlPaintable — the factory half of the join

/// What a TTL factory implements so `CircuitRenderer` and `ToolOverlayScene` can draw it.
///
/// **The `: InstancePaintable` refinement is the whole join, not decoration**: the same
/// sentence `MemPaintable` and `IoPaintable` carry, for the same reason: both walkers cast to
/// `any InstancePaintable` and nothing else. A family-scoped protocol on its own compiles,
/// type-checks, and draws nothing.
///
/// Unlike the memory family, `paintGhost` **is** a requirement here and is not left at
/// `InstancePaintable`'s no-op: `AbstractTtlGate.java:281-284` overrides it
/// (`paintBase(painter, true, true)`), so a dragged 74xx chip previews its DIP outline, its 14
/// pin stubs, its part number and its Vcc/GND legends rather than the bare offset-bounds
/// rectangle `AbstractComponentFactory.drawGhost` would stroke.
public protocol TtlPaintable: InstancePaintable {
  /// `paintInstance(InstancePainter)`, in this family's (emitter, state) shape.
  func paintInstance(_ painter: SceneBuilder, _ state: any TtlPainter)
  /// `paintGhost(InstancePainter)`, same shape.
  func paintGhost(_ painter: SceneBuilder, _ state: any TtlPainter)
}

extension TtlPaintable {

  /// `InstancePaintable.paintInstance` → the TTL overload.
  ///
  /// Told apart from the requirement by *arity*, not by a static-type subtlety, so there is no
  /// risk of the forward resolving back to itself: the protocol requirement takes two arguments
  /// and this takes one. There is deliberately no default for the two-argument form, so a
  /// factory that forgot to write one fails to compile instead of silently drawing nothing,
  /// which is exactly the failure this file exists to end.
  public func paintInstance(_ painter: InstancePainter) {
    paintInstance(painter.g, painter as any TtlPainter)
  }

  /// `InstancePaintable.paintGhost` → the TTL overload. More specialized than
  /// `InstancePaintable`'s empty default, so it wins the witness for any `TtlPaintable`.
  public func paintGhost(_ painter: InstancePainter) {
    paintGhost(painter.g, painter as any TtlPainter)
  }
}

// MARK: - The painter half of the join

/// `InstancePainter` **is** the painter this family needs, and every requirement above was
/// already a member of it:
///
/// | `TtlPainter` | `InstancePainter` |
/// |---|---|
/// | `attributeSet` `bounds` `data` | already present, member for member |
/// | `drawPorts()` `drawLabel()` | already present |
///
/// So the conformance body is empty; nothing had to move, and nothing in `Instance/` (owned by
/// another slice) was edited. `drawLabel()` in particular needs no shim: it looks the placement
/// up through `factory as? InstanceLabelProvider`, and `AbstractTtlGate` has conformed to
/// `InstanceLabelProvider` since the label slice landed (`AbstractTtlGate.swift:547`). That
/// conformance was correct and unreachable for exactly as long as this one was missing.
extension InstancePainter: TtlPainter {}

// MARK: - The 61 chips

/// One conformance covers all 61 factories.
///
/// Every 74xx factory in this module descends from `AbstractTtlGate`, and none of them overrides
/// `paintInstance` or `paintGhost`: exactly as upstream, where `AbstractTtlGate` is the only
/// class in `std/ttl/` declaring either (`grep -l 'void paintInstance' std/ttl/*.java` on the
/// 4.1.0 tree returns `AbstractTtlGate.java` alone). What the 47 chips *do* override is
/// `paintInternal`, which `paintInternalBase` calls, and which is `open` here so those overrides
/// are vtable-dispatched through this one witness.
extension AbstractTtlGate: TtlPaintable {}
