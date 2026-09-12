// CircuitRenderer.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.circuit.Circuit.draw and
// com.cburch.logisim.comp.ComponentDrawContext), https://github.com/logisim-evolution/logisim-evolution.
// Copyright by the Logisim-evolution developers. This translation is a derivative work and is
// therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// WHAT THIS FILE IS, AND WHY IT EXISTS SEPARATELY
//
// Sixty-one component files implement `paintInstance`, and until this file existed **nothing
// called any of them**. `grep -rn '\.paintInstance('` found only doc comments, and neither
// `LogisimRender` nor `LogisimUI` mentioned `InstancePaintable` at all. Every one of those
// implementations was correct and unreachable.
//
// That is this project's signature failure, each half built correctly, nothing owning the
// join, and it is the same shape as `Loader.fileReader` being declared and never assigned, the
// four unwired codec handlers, the poke seam that seven files coded against and nobody wrote,
// and the two value palettes with no bridge. Four agents painted in parallel, and each was
// correctly told to report a seam rather than reach across into a shared file, so the walker
// that drives them was nobody's slice.
//
// It lives in `LogisimStd` because that is the one module that can see all three pieces at
// once: `Circuit` (from `LogisimFile`), `SceneBuilder` (from `LogisimRender`), and the
// `InstancePaintable`/`ComponentPaintable` protocols declared next door in `InstancePainter`.
// Putting it in `LogisimUI` would have worked too, but would have made a headless render
// impossible, and a headless render is exactly what the M6 pass condition needs, since it
// compares against Java's `ExportImage` with no window involved.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// WHY TWO PROTOCOLS
//
// Upstream draws through `Component.draw(ComponentDrawContext)`, and `InstanceComponent`
// forwards that to its factory's `paintInstance`. Most components are instance-backed and so
// paint via their FACTORY; `Splitter` is hand-written (the propagator owns its bit-thread
// bookkeeping directly) and draws itself. Both routes are reproduced here rather than collapsed,
// because collapsing them would mean either giving `Splitter` a factory it does not have or
// giving every factory a `draw` it does not want.
//
// A component whose factory conforms to neither draws NOTHING, deliberately. `InstancePaintable`
// is a separate protocol precisely so an unported component simply does not conform, and the
// canvas skips it instead of stamping a placeholder box over the schematic.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

/// Walks a circuit and drives each component's paint implementation into a scene.
public enum CircuitRenderer {

  /// Renders every component and wire of `circuit` into `builder`.
  ///
  /// Each component is wrapped in its own `SceneBuilder` group, tagged with the component's
  /// index in the circuit's component list. The tag is what makes hit-testing possible without
  /// re-walking the circuit: `RenderScene`'s spatial index answers "what is at this point" with
  /// a group tag, and the caller maps it back through the same ordering.
  ///
  /// Wires are drawn BEFORE components, matching upstream, so a component body covers the wire
  /// stubs that run under it rather than being striped by them.
  /// `hidden` suppresses components and wires by identity (D4), for a move preview: the tool layer
  /// draws the selection shifted by the drag delta, so the unshifted originals must stop being
  /// drawn or the drag shows both copies at once.
  ///
  /// Suppression is a `continue`, never a renumber. Group tags are the component's index in
  /// `circuit.components` and hit-testing maps a tag back through that same ordering, so packing
  /// the tags down would silently misidentify every component after the first hidden one.
  @discardableResult
  public static func render(
    _ circuit: Circuit,
    into builder: SceneBuilder,
    context: any PaintContext,
    skipping hidden: Set<ObjectIdentifier> = []
  ) -> Int {
    var painted = 0

    // Wires first: see the note above about draw order.
    //
    // KNOWN GAP, stated rather than hidden: every wire is stroked at width 1. Upstream draws a
    // multi-bit bus thicker, but the thickness comes from the width `CircuitWires` computed for
    // that net, which is simulation state; a `Wire` itself carries only its two endpoints, and
    // there is deliberately no width on it. So a correct bus stroke needs the propagator, i.e.
    // M3 wired to the canvas. Until then a bus and a single wire look alike; nothing else about
    // the geometry is affected.
    builder.beginGroup(tag: wireGroupTag, opacity: 1.0)
    builder.color = context.componentColor
    builder.strokeWidth = 1
    for wire in circuit.wires {
      if !hidden.isEmpty, hidden.contains(ObjectIdentifier(wire)) { continue }
      builder.drawLine(wire.end0.x, wire.end0.y, wire.end1.x, wire.end1.y)
    }
    builder.endGroup()

    let painter = InstancePainter(g: builder, context: context)

    for (index, component) in circuit.components.enumerated() {
      // See `skipping` on the signature: `continue`, so `index` -- and therefore the group tag
      // hit-testing resolves against -- stays put.
      if !hidden.isEmpty, hidden.contains(ObjectIdentifier(component)) { continue }

      // Tags start at 1: 0 is the implicit group a SceneBuilder opens before any explicit one,
      // and the wire layer takes `UInt64.max`, so 1...n is free for components.
      builder.beginGroup(tag: UInt64(index + 1), opacity: 1.0)
      defer { builder.endGroup() }

      painter.setComponent(component)

      // Deliberately NOT `builder.reset()` here, though it reads like the obvious way to stop
      // one component's pen and colour leaking into the next. `reset()` clears the WHOLE scene,
      // primitives, groups, transforms, palette, because it exists to recycle a builder across
      // frames, not within one. Calling it per component silently produced an empty scene: 6
      // components "painted" and 0 primitives emitted, which compiled and ran and drew nothing.
      // Components set their own colour and pen before drawing, exactly as they do upstream
      // where each gets a fresh Graphics.
      if let selfDrawing = component as? any ComponentPaintable {
        // `Splitter` and anything else hand-written: draws itself.
        selfDrawing.draw(painter)
        painted += 1
      } else if let paintable = component.factory as? any InstancePaintable {
        paintable.paintInstance(painter)
        painted += 1
      }
      // Neither: an unported component. Draw nothing rather than a placeholder; see the file
      // header for why that is deliberate.
    }

    painter.setComponent(nil)
    return painted
  }

  /// Group tag for the wire layer.
  ///
  /// `UInt64.max` rather than a small sentinel: tags are unsigned, 0 is the implicit group a
  /// `SceneBuilder` opens before any explicit one, and components take 1...n, so the top of the
  /// range is the only value that cannot collide with a component index however large a circuit
  /// gets.
  public static let wireGroupTag = UInt64.max
}
