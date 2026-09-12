// AppearanceSceneSource.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.draw.canvas.Canvas.paintForeground and
// com.cburch.logisim.circuit.appear.CircuitAppearance.paintSubcircuit),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// THE PURE HALF OF THE APPEARANCE CANVAS
//
// Exactly the shape `CircuitSceneSource` has, and deliberately so: a free function from a model
// to a `RenderScene` plus a hit-target table, with no AppKit, no view and no global state, so
// the verification suite can render a corpus file's `<appear>` with no window in existence. That
// is what lets `AppearanceRoundTripTests` assert on **primitive counts out of `SceneBuilder`**
// rather than on "the view exists".
//
// ── What is reused, and the one thing that is not ────────────────────────────────────────────
//
// Reused unchanged: `SceneBuilder` + `CoreTextMeasurer` (D6's drawing API), `RenderScene`,
// `CanvasAppearance`, `CoreGraphicsSceneRenderer` via `AppearanceSceneRasterizer`, and
// `LogisimStd.AppearanceShapePainter`, which is the whole of the per-shape drawing and was
// written for `paintSubcircuit`. Nothing here re-implements a `paint`.
//
// NOT reused: `CircuitSceneBuild` and `CircuitSceneSource.build`. Both are typed on
// `Circuit`/`Component` end to end; `targets` is documented as "parallel to `Circuit
// .components`", the tag contract is `CircuitRenderer`'s component index, and hit results are
// `ComponentID`s. An `<appear>` has no components; its objects are `CanvasObject`s with no
// `ComponentID` and no place in `Circuit.components`. Generalising that file over both models
// would mean making its tag contract and its `CanvasHitTarget.Kind` polymorphic, which is a
// change to a file this work does not own and a much larger blast radius than 60 lines here.
// **Recommended follow-up, stated rather than done:** if a third scene source ever appears,
// factor the `SceneBuilder`-to-`RenderScene`-plus-targets shape out of both.

import CoreGraphics
import Foundation
import LogisimDraw
import LogisimFile
import LogisimKernel
import LogisimRender
import LogisimRenderBackend
import LogisimStd

// MARK: - Build product

/// Everything one walk of an appearance produces. A value type for the same reason
/// `CircuitSceneBuild` is one: the view swaps a new one in atomically and a half-built scene is
/// never observable.
struct AppearanceSceneBuild {
  var scene: RenderScene = .empty

  /// The modelled shapes, bottom to top; the same order and the same object references the
  /// model holds, so index *i* here is `drawing.objectsFromBottom[i]`.
  var shapes: [CanvasObject] = []

  /// `shapes[i].bounds`, cached because a hit test and an invalidate both want it.
  var bounds: [CGRect] = []

  /// World bounds of everything drawn, for zoom-to-fit. `.null` for an empty appearance.
  var contentBounds: CGRect = .null

  /// How many shapes actually reached a draw call. This is the number the tests assert on
  /// alongside the primitive count: `AppearanceShapePainter.paint` returns `false` for a kind it
  /// does not know, so `paintedShapeCount < shapes.count` names a real gap rather than hiding
  /// one. Ports and the anchor are deliberately not counted, see below.
  var paintedShapeCount: Int = 0

  /// `AppearanceElement` instances in the list: `circ-port` and `circ-anchor`. Held separately
  /// because they are **not drawn by the shape painter** (upstream's `paintSubcircuit` skips
  /// them) and yet they are the things the editor most needs to show, since they are what the
  /// parent circuit wires to.
  var portLocations: [CGPoint] = []
  var anchorLocation: CGPoint?

  var isEmpty: Bool { shapes.isEmpty && portLocations.isEmpty && anchorLocation == nil }
}

// MARK: - The builder

enum AppearanceSceneSource {

  /// Walks a shape list and produces the scene plus the hit-target geometry.
  ///
  /// `shapes` is `[AppearanceShape]` (i.e. `[AnyObject]`) rather than `[CanvasObject]` because
  /// that is what the reader produces and what D8's verbatim entries live in. Filtering happens
  /// here, once, and the verbatim entries contribute nothing to the scene; they are XML this
  /// port does not model, so there is nothing to draw. **That is a visible gap, not a silent
  /// one:** `unmodelledShapeCount` reports it so the pane can say "N shapes in this appearance
  /// are preserved but not drawn" instead of quietly showing an incomplete symbol.
  static func build(
    shapes: [AppearanceShape],
    appearance: CanvasAppearance
  ) -> (build: AppearanceSceneBuild, unmodelledShapeCount: Int) {
    var result = AppearanceSceneBuild()
    var unmodelled = 0

    let builder = SceneBuilder(measurer: CoreTextMeasurer())
    var box = CGRect.null

    for shape in shapes {
      guard let object = shape as? CanvasObject else {
        unmodelled += 1
        continue
      }
      if let element = object as? AppearanceElement {
        let point = CGPoint(x: CGFloat(element.location.x), y: CGFloat(element.location.y))
        if element is AppearanceAnchor {
          result.anchorLocation = point
        } else {
          result.portLocations.append(point)
        }
        // Deliberately NOT appended to `shapes`: `AppearanceElement`s are drawn by the overlay
        // (they are UI affordances, not part of the exported symbol) and `model.shape(at:)`
        // skips them for the same reason upstream's `AppearanceCanvas` keeps them pinned to the
        // top layer and out of ordinary selection.
        continue
      }

      result.shapes.append(object)
      let rect = AppearanceEditorModel.rect(object.bounds)
      result.bounds.append(rect)
      if !rect.isNull, !rect.isInfinite { box = box.union(rect) }
      if AppearanceShapePainter.paint(object, into: builder) { result.paintedShapeCount += 1 }
    }

    result.scene = builder.finish()

    // Ports and the anchor are part of what the editor has to keep on screen even when every
    // drawn shape is elsewhere; a symbol whose anchor is off-canvas is exactly the case a user
    // needs to see to fix.
    for point in result.portLocations {
      box = box.union(CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8))
    }
    if let anchor = result.anchorLocation {
      box = box.union(CGRect(x: anchor.x - 6, y: anchor.y - 6, width: 12, height: 12))
    }
    result.contentBounds = box
    return (result, unmodelled)
  }

  /// The topmost shape containing `point`, by index into `build.shapes`.
  ///
  /// Bounds-level only: the exact `contains(_:assumeFilled:)` test lives on the model, which
  /// owns the `Drawing`. This exists so the view can pick an invalidation rectangle without
  /// reaching into the model.
  static func index(at point: CGPoint, in build: AppearanceSceneBuild) -> Int? {
    for index in stride(from: build.bounds.count - 1, through: 0, by: -1)
    where build.bounds[index].contains(point) {
      return index
    }
    return nil
  }
}
