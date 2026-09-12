// LogisimUI: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// ============================================================================
// THE JOIN.
//
// `LogisimStd/Instance/CircuitRenderer` walks a circuit and drives 61 `paintInstance`
// implementations into a `SceneBuilder`. `LogisimRender/Backend/CoreGraphicsSceneRenderer`
// paints a `RenderScene` into a `CGContext`. `LogisimUI/Canvas/CanvasHostNSView` owns the
// camera and the input. Until this file existed, `grep -rn CircuitRenderer Sources/LogisimUI`
// returned nothing: three finished halves and no join, which is this project's signature
// failure mode (see the header of `CircuitRenderer.swift` for the previous four instances).
//
// This file is the *pure* half of the join: no AppKit, no view, no drawing. It turns a
// `Circuit` into everything the canvas needs to draw and to answer "what is under the
// pointer", and it is deliberately callable headlessly so the verification test can render a
// corpus file offscreen with no window in existence.
//
// ── The tag contract ────────────────────────────────────────────────────────────────────────
//
// `CircuitRenderer` tags each component's scene group with its index in `Circuit.components`
// **plus one**, and the whole wire layer with `UInt64.max`. Nothing else defines that mapping,
// so this file must enumerate `Circuit.components` in exactly the same way and must not
// re-derive the order from `nonWires` + `wires` by hand; `Circuit.components` is the single
// definition of it (components first, then wires, matching upstream's
// `CollectionUtil.createUnmodifiableSetUnion`). A hit therefore costs one index, never a
// second walk of the circuit.
// ============================================================================

import CoreGraphics
import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender
import LogisimRenderBackend
import LogisimStd

// MARK: - Unresolved placeholder geometry

/// D8: a component whose library did not resolve is kept, round-trips byte-for-byte, and must
/// be **visible and selectable** rather than silently gone.
///
/// `UnresolvedComponent.bounds` is deliberately `Bounds.empty`; inventing geometry down there
/// would leak a placeholder into `Circuit.bounds` and change what a saved viewport looks like.
/// So the box is invented *here*, in the view layer, where it affects only pixels. It is drawn
/// by `CircuitSceneView` as an overlay rather than emitted into the scene, because the scene is
/// what a headless export renders and an export must not contain UI chrome.
enum UnresolvedPlaceholder {
  /// World units. Two grid cells square, centred on the component's anchor location, which is
  /// the only real coordinate an unresolved component has.
  static let extent: CGFloat = 40

  static func rect(at location: Location) -> CGRect {
    CGRect(
      x: CGFloat(location.x) - extent / 2,
      y: CGFloat(location.y) - extent / 2,
      width: extent,
      height: extent)
  }
}

// MARK: - Wire segments

/// One drawable wire, kept out of the scene's hit path on purpose.
///
/// The whole wire layer shares a single group (`CircuitRenderer.wireGroupTag`), so its group
/// bounds are the union of every wire in the circuit; useless as a hit target. Wires are
/// therefore hit-tested against their own segments, which is also the only way to honour a
/// tolerance on a zero-area shape.
struct CircuitWireSegment {
  var a: CGPoint
  var b: CGPoint
  /// Index into `CircuitSceneBuild.targets`.
  var targetIndex: Int

  /// Squared distance from `point` to the segment. Squared to keep it in integers-as-doubles
  /// and out of `sqrt` on every wire of every hit test.
  func squaredDistance(to point: CGPoint) -> CGFloat {
    let dx = b.x - a.x
    let dy = b.y - a.y
    let lengthSquared = dx * dx + dy * dy
    guard lengthSquared > 0 else {
      let px = point.x - a.x
      let py = point.y - a.y
      return px * px + py * py
    }
    var t = ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared
    t = min(max(t, 0), 1)
    let cx = a.x + t * dx
    let cy = a.y + t * dy
    let ex = point.x - cx
    let ey = point.y - cy
    return ex * ex + ey * ey
  }
}

// MARK: - CircuitSceneBuild

/// Everything one walk of a circuit produces. A value type, so the surface can swap a new one
/// in atomically and a half-built scene is never observable.
struct CircuitSceneBuild {
  /// The retained geometry. Rebuilt only when the circuit or the *geometry* inputs change:
  /// never for a palette change, and never per frame. See `CircuitSceneGeometryKey`.
  var scene: RenderScene = .empty

  /// Parallel to `Circuit.components`, so `targets[i]` is the component tagged `i + 1`.
  var targets: [CanvasHitTarget] = []

  /// The components themselves, same order. Held so an exact `contains(Location)` test can
  /// refine a bounds-level hit without going back to the circuit.
  var components: [any Component] = []

  var indexByID: [ComponentID: Int] = [:]

  var wireSegments: [CircuitWireSegment] = []

  /// Targets that draw nothing and need the D8 placeholder box painted over them.
  var unresolvedTargetIndices: [Int] = []

  /// World bounds of everything, for zoom-to-fit. `.null` when the circuit is empty.
  var contentBounds: CGRect = .null

  /// How many components actually painted. A component whose factory conforms to neither
  /// `InstancePaintable` nor `ComponentPaintable` paints nothing, deliberately (see
  /// `CircuitRenderer`), so this being lower than `components.count` is expected, not a bug,
  /// but it being *zero* on a non-empty circuit is the failure the verification test catches.
  var paintedComponentCount: Int = 0

  var isEmpty: Bool { targets.isEmpty }

  func target(forTag tag: UInt64) -> Int? {
    guard tag != 0, tag != CircuitRenderer.wireGroupTag else { return nil }
    let index = Int(tag) - 1
    guard index >= 0, index < targets.count else { return nil }
    return index
  }
}

// MARK: - Geometry key

/// The inputs a rebuild actually depends on.
///
/// This is what keeps `setAppearance` cheap. Of everything on `CanvasAppearance`, only the gate
/// shape and the ink colour reach `paintInstance` at all; grid, antialiasing, backing scale,
/// halo and tick markers are render-time or overlay-time decisions and must never cost a
/// rebuild. `backingScale` in particular is pushed on every `viewDidChangeBackingProperties`
/// and on every SwiftUI update pass; rebuilding on it would rebuild the scene continuously.
///
/// **Why the ink colour is here and the value colours are not.** The 12 simulation colours live
/// in the scene as reserved `PaletteIndex` values and are resolved through
/// `RenderOptions.theme` at draw time, so re-theming them is free (that is the whole point of
/// `ScenePalette`'s reserved range). The component *outline* colour is not: 61 component
/// painters write literal blacks (`MemPaint.componentColor`, `g.color = .black`, …) which the
/// builder interns as literal palette entries, and no theme swap can move an interned literal.
/// So a light/dark flip does change geometry, and is the one appearance change that rebuilds:
/// once per user-initiated theme switch, not per frame.
struct CircuitSceneGeometryKey: Equatable {
  var circuit: ObjectIdentifier?
  var revision: UInt64
  var gateShape: CanvasAppearance.GateShape
  var ink: RGBA
  var showsValueColours: Bool

  /// Part of the key because it changes what geometry is emitted, not merely how it is painted.
  /// A drag pushes a new hidden set on the frame the gesture starts and again when it ends, and
  /// each of those must rebuild exactly once; omitting it would leave the originals drawn for
  /// the whole drag, which is the bug this parameter exists to fix.
  var hidden: Set<ComponentID>

  /// Bumped by the propagation thread every time it finishes a request.
  ///
  /// Part of the key because **values are geometry here**. A scene stores each wire's colour as a
  /// resolved `PaletteIndex` and each component paints its own state, a lit LED is a different
  /// set of primitives from a dark one, so a propagation that changes nothing about the circuit's
  /// shape still changes what must be drawn. Without this the schematic froze at whatever the
  /// values were when the geometry last changed, which is indistinguishable from the simulation
  /// not running.
  ///
  /// Zero whenever nothing is simulating, so a document with no engine behind it rebuilds exactly
  /// as often as it did before.
  var simulationRevision: UInt64

  init(
    circuit: Circuit?,
    revision: UInt64,
    appearance: CanvasAppearance,
    hidden: Set<ComponentID> = [],
    simulationRevision: UInt64 = 0
  ) {
    self.circuit = circuit.map(ObjectIdentifier.init)
    self.revision = revision
    self.gateShape = appearance.gateShape
    self.ink = appearance.palette[.componentStroke]
    self.showsValueColours = appearance.showsValueColours
    self.hidden = hidden
    self.simulationRevision = simulationRevision
  }
}

// MARK: - CircuitSceneSource

enum CircuitSceneSource {

  /// Walks `circuit` and produces the scene plus the hit-target table.
  ///
  /// Pure and synchronous: no AppKit, no view, no global state. That is what lets the
  /// verification test render a corpus file with no window, and what will let a future
  /// background rebuild move off the main actor without touching this code.
  /// - Parameter liveContext: the paint context to render with, or nil for the unpowered one.
  ///   Supplied by `CircuitCanvasSurface` when a simulation is running, and **only ever supplied
  ///   from inside `CanvasSimulationAccess.withModelLock`**; every painter this walks reads
  ///   `CircuitState` through it, so the whole build has to be serialised against the propagation
  ///   thread, not each individual read.
  static func build(
    circuit: Circuit?,
    appearance: CanvasAppearance,
    hidden: Set<ComponentID> = [],
    liveContext: (any PaintContext)? = nil
  ) -> CircuitSceneBuild {
    var result = CircuitSceneBuild()
    guard let circuit else { return result }

    // `Circuit.components` materialises a fresh array on every access, so it is read exactly
    // once and that array is the ordering contract for the whole build, see the file header.
    let components = circuit.components
    result.components = components

    // `ComponentID` is a projected address and cannot be turned back into an `ObjectIdentifier`,
    // so the mapping is done here, where the component array already is, rather than widening
    // `CircuitRenderer`'s parameter to a raw `UInt64` set and coupling `LogisimStd` to a shell
    // type it must not know about (D9).
    //
    // Hit targets are built for hidden components as usual. A hidden component is one being
    // dragged, whose ghost the overlay draws; hit-testing is not consulted mid-drag, and leaving
    // the target table dense keeps it index-aligned with `components`, which is the contract the
    // whole file rests on.
    var hiddenRefs: Set<ObjectIdentifier> = []
    if !hidden.isEmpty {
      for component in components where hidden.contains(identity(of: component)) {
        hiddenRefs.insert(ObjectIdentifier(component))
      }
      for wire in circuit.wires where hidden.contains(identity(of: wire)) {
        hiddenRefs.insert(ObjectIdentifier(wire))
      }
    }

    let builder = SceneBuilder(measurer: CoreTextMeasurer())
    let context = liveContext ?? paintContext(for: appearance)
    result.paintedComponentCount = CircuitRenderer.render(
      circuit, into: builder, context: context, skipping: hiddenRefs)
    result.scene = builder.finish()

    var bounds = CGRect.null
    result.targets.reserveCapacity(components.count)

    for (index, component) in components.enumerated() {
      let kind = classify(component)
      let box = worldBounds(of: component, kind: kind)
      let target = CanvasHitTarget(
        id: identity(of: component),
        kind: kind,
        displayName: displayName(of: component, kind: kind),
        bounds: box)
      result.indexByID[target.id] = index
      result.targets.append(target)
      if kind == .unresolvedPlaceholder { result.unresolvedTargetIndices.append(index) }
      if let wire = component as? Wire {
        result.wireSegments.append(
          CircuitWireSegment(
            a: CGPoint(x: CGFloat(wire.end0.x), y: CGFloat(wire.end0.y)),
            b: CGPoint(x: CGFloat(wire.end1.x), y: CGFloat(wire.end1.y)),
            targetIndex: index))
      }
      if !box.isNull, !box.isInfinite { bounds = bounds.union(box) }
    }

    result.contentBounds = bounds
    return result
  }

  // MARK: Paint context

  /// The `PaintContext` an **unpowered** schematic paints against.
  ///
  /// `showState` is false, so every port reads `Value.NIL`, which is exactly what upstream shows
  /// with the simulator stopped, and what this canvas shows when nothing is simulating. When a
  /// simulation *is* running the surface passes a `LiveCircuitPaintContext` instead; see
  /// `build(circuit:appearance:hidden:liveContext:)`.
  /// `StaticPaintContext` is `LogisimStd`'s own stand-in for that situation, so nothing
  /// UI-shaped has to be pushed down past D9 to get it.
  static func paintContext(for appearance: CanvasAppearance) -> any PaintContext {
    StaticPaintContext(
      showState: false,
      showColor: appearance.showsValueColours,
      isPrintView: false,
      gateShape: GateShape(rawValue: appearance.gateShape.rawValue) ?? .shaped,
      pinAppearance: .dotSmall,
      componentColor: .rgba(appearance.palette[.componentStroke].sceneRGBA))
  }

  /// The 12 simulation colours, handed to the backend per frame.
  ///
  /// This is the "colour-palette swap" half of the per-frame budget: re-theming every wire and
  /// port in a 5,000-component schematic is 12 struct writes and zero geometry work, because
  /// the scene stores a reserved `PaletteIndex` rather than a colour. Upstream cannot do this
  /// at all: `Value.java` freezes the same 12 colours into `static Color` fields at class-init
  /// time, which is issue #2661.
  static func theme(for palette: CircuitPalette) -> ValueColorTheme {
    var theme = ValueColorTheme.logisim
    for slot in ValuePalette.allCases {
      theme[slot] = palette.color(for: slot).sceneRGBA
    }
    return theme
  }

  // MARK: Classification

  static func classify(_ component: any Component) -> CanvasHitTarget.Kind {
    if component is Wire { return .wire }
    if component is UnresolvedComponent { return .unresolvedPlaceholder }
    let factory = component.factory
    if factory is any SubcircuitFactory { return .subcircuit }
    if factory is UnresolvedComponentFactory { return .unresolvedPlaceholder }
    switch factory.name {
    case "Pin": return .pin
    case "Text": return .label
    default: return .component
    }
  }

  static func displayName(of component: any Component, kind: CanvasHitTarget.Kind) -> String {
    switch kind {
    case .wire: return "Wire"
    case .unresolvedPlaceholder: return "\(component.factory.name) (unresolved)"
    default: return component.factory.displayName
    }
  }

  static func worldBounds(of component: any Component, kind: CanvasHitTarget.Kind) -> CGRect {
    if kind == .unresolvedPlaceholder {
      return UnresolvedPlaceholder.rect(at: component.location)
    }
    let box = component.bounds
    return CGRect(
      x: CGFloat(box.x), y: CGFloat(box.y),
      width: CGFloat(box.width), height: CGFloat(box.height))
  }

  /// D4: component identity is reference identity, and nothing else may be used as a key. The
  /// shell needs a `Sendable`, `Codable` handle for SwiftUI selection, so the reference is
  /// projected to its address; stable for as long as the circuit holds the component, which is
  /// exactly the lifetime a canvas selection has.
  static func identity(of component: any Component) -> ComponentID {
    ComponentID(rawValue: UInt64(UInt(bitPattern: ObjectIdentifier(component))))
  }
}

// MARK: - Colour bridging

extension RGBA {
  /// `LogisimUI.RGBA` (Double channels, appearance-resolved) → `LogisimRender.RGBA` (byte
  /// channels, what the scene and the GPU want). Two distinct types with the same name, which
  /// is why every crossing is written out rather than inferred.
  var sceneRGBA: LogisimRender.RGBA {
    func byte(_ value: Double) -> UInt8 {
      UInt8(max(0, min(255, (value * 255).rounded())))
    }
    return LogisimRender.RGBA(
      r: byte(red), g: byte(green), b: byte(blue), a: byte(alpha))
  }
}
