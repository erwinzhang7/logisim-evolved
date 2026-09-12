// UpstreamIssue1262Tests: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// UPSTREAM ISSUE #1262: "better mouse zoom / panning", open since 2020.
//
// `CanvasHostNSView` implements `magnify(with:)`, `smartMagnify(with:)` and precise scrolling
// deltas, and `CanvasViewport`'s doc comment claims the anchoring property upstream loses. None
// of that had a test, so the claim rested on reading the code, which is the standard this audit
// exists to raise. This file measures the three properties instead.
//
// What upstream actually does (4.1.0 tree, D16: line numbers verified in that tree, not main):
//
//   * There is no camera. The canvas is a `JScrollPane` viewport over a `Canvas` whose
//     *preferred size* is the circuit bounds times the zoom (`Canvas.computeSize`), so zooming
//     resizes a Swing component.
//   * The anchor is then re-derived from ratios and **rounded to integer scrollbar values after
//     a layout pass that has already clamped them**: `Canvas.java:699-708`:
//         viewport.doLayout();
//         setHorizontalScrollBar((int) Math.round(newViewOffsetX));
//         setVerticalScrollBar((int) Math.round(newViewOffsetY));
//     Rounding plus clamping is why the anchor drifts across repeated zooms.
//   * Because the scroll range IS the content size, you cannot scroll past the content edge.
//   * Plain wheel/two-finger scroll is bound to integer wheel notches on a `JScrollBar`
//     (`Canvas.java:917-921`: `scrollBar.setValue(scrollValue(bar, mwe.getWheelRotation()))`),
//     so trackpad panning is steppy, with no inertia.
//   * Swing has no pinch event at all: `grep -rn magnif src/main/java/.../gui/main/` finds only
//     `SimulationTreeRenderer`'s "magnifying glass" icon comment.
//
// The port's camera is `(center, zoom)` in continuous doubles, so all three properties below are
// exact rather than approximate. The tolerances are floating-point slack, not behavioural slack.
// ═════════════════════════════════════════════════════════════════════════════════════════════

import CoreGraphics
import Foundation
import Testing

@testable import LogisimUI

@Suite("Upstream #1262 — camera zoom and pan")
struct UpstreamIssue1262Tests {

  private static let viewSize = CGSize(width: 1280, height: 820)

  /// The property upstream loses to `Math.round` + `doLayout()` clamping: the world point under
  /// the cursor must stay under the cursor. Checked across a long chain of zooms, because drift
  /// is cumulative; a single step can look fine while fifty steps walk the schematic away.
  @Test("zoom keeps the anchor under the same view pixel, over 60 chained steps")
  func zoomAnchorDoesNotDrift() {
    var viewport = CanvasViewport(
      zoom: 1, center: CGPoint(x: 300, y: 200), viewSize: Self.viewSize)
    let anchorView = CGPoint(x: 940, y: 210)
    let anchorWorld = viewport.viewToWorld(anchorView)

    // Alternating in and out, ending away from 1.0, so clamping is exercised at both ends.
    for step in 0..<60 {
      let factor = step.isMultiple(of: 3) ? 1.35 : 0.82
      viewport.zoom(to: viewport.zoom * factor, anchoringWorldPoint: anchorWorld)
      let back = viewport.worldToView(anchorWorld)
      #expect(
        abs(back.x - anchorView.x) < 1e-6 && abs(back.y - anchorView.y) < 1e-6,
        "anchor drifted at step \(step): \(back) vs \(anchorView) at zoom \(viewport.zoom)")
    }
  }

  /// Anchoring by view point is the form the pinch handler actually calls.
  @Test("zoom anchored on a view point is equivalent to anchoring on its world point")
  func viewPointAnchoringAgrees() {
    let start = CanvasViewport(zoom: 0.7, center: CGPoint(x: -40, y: 90), viewSize: Self.viewSize)
    let pinch = CGPoint(x: 220, y: 640)

    var byView = start
    byView.zoom(to: 2.4, anchoringViewPoint: pinch)
    var byWorld = start
    byWorld.zoom(to: 2.4, anchoringWorldPoint: start.viewToWorld(pinch))

    #expect(byView == byWorld)
    let held = byView.worldToView(start.viewToWorld(pinch))
    #expect(abs(held.x - pinch.x) < 1e-6 && abs(held.y - pinch.y) < 1e-6)
  }

  /// A trackpad delta is in view points. Upstream quantises it to wheel notches on a scrollbar;
  /// here it must move the image by exactly that many points at ANY zoom, which is what makes
  /// the gesture feel 1:1 when zoomed in.
  @Test("pan moves the image 1:1 in view points at every zoom")
  func panIsOneToOneInViewPoints() {
    for zoom in [0.05, 0.25, 1.0, 3.5, 10.0] {
      var viewport = CanvasViewport(
        zoom: zoom, center: CGPoint(x: 12, y: -8), viewSize: Self.viewSize)
      let probe = CGPoint(x: 55, y: 61)
      let before = viewport.worldToView(probe)
      let delta = CGSize(width: -37.5, height: 21.25)
      viewport.pan(byViewDelta: delta)
      let after = viewport.worldToView(probe)
      #expect(
        abs((after.x - before.x) - delta.width) < 1e-9,
        "x pan was not 1:1 at zoom \(zoom): moved \(after.x - before.x), asked \(delta.width)")
      #expect(
        abs((after.y - before.y) - delta.height) < 1e-9,
        "y pan was not 1:1 at zoom \(zoom): moved \(after.y - before.y), asked \(delta.height)")
    }
  }

  /// Upstream's scroll range *is* the content size, so you cannot scroll past the leftmost
  /// component in order to place something to the left of it; one of the concrete complaints on
  /// the issue. The camera here is unbounded, and that is a behaviour worth pinning: a future
  /// "clamp the camera to content" change would silently reintroduce the upstream defect.
  @Test("the camera is unbounded — you can pan far outside the content")
  func cameraIsUnbounded() {
    var viewport = CanvasViewport(zoom: 1, center: .zero, viewSize: Self.viewSize)
    let content = CGRect(x: 0, y: 0, width: 200, height: 200)
    for _ in 0..<50 { viewport.pan(byViewDelta: CGSize(width: 400, height: 0)) }
    #expect(viewport.center.x < -1000, "camera clamped at \(viewport.center.x)")
    #expect(!viewport.visibleWorldRect.intersects(content))
    // And it comes back, no accumulated clamping error.
    for _ in 0..<50 { viewport.pan(byViewDelta: CGSize(width: -400, height: 0)) }
    #expect(abs(viewport.center.x) < 1e-9)
  }

  /// Zoom is clamped to a declared range rather than to the scrollbar geometry, and the anchor
  /// invariant must survive the clamp: the case where a fast pinch overshoots the limit.
  @Test("zoom clamps to the declared range and still holds the anchor")
  func clampedZoomStillAnchors() {
    var viewport = CanvasViewport(zoom: 1, center: .zero, viewSize: Self.viewSize)
    let anchorView = CGPoint(x: 100, y: 700)
    let anchorWorld = viewport.viewToWorld(anchorView)

    viewport.zoom(to: 1_000, anchoringWorldPoint: anchorWorld)
    #expect(viewport.zoom == CanvasViewport.maximumZoom)
    var back = viewport.worldToView(anchorWorld)
    #expect(abs(back.x - anchorView.x) < 1e-6 && abs(back.y - anchorView.y) < 1e-6)

    viewport.zoom(to: 0.000_1, anchoringWorldPoint: anchorWorld)
    #expect(viewport.zoom == CanvasViewport.minimumZoom)
    back = viewport.worldToView(anchorWorld)
    #expect(abs(back.x - anchorView.x) < 1e-6 && abs(back.y - anchorView.y) < 1e-6)
  }

  /// Culling depends on this, so it is worth stating: the visible rect must be the exact
  /// preimage of the view bounds. Upstream has no equivalent and paints every component.
  @Test("visibleWorldRect is the exact preimage of the view bounds")
  func visibleRectIsExact() {
    let viewport = CanvasViewport(
      zoom: 2.5, center: CGPoint(x: 130, y: -70), viewSize: Self.viewSize)
    let rect = viewport.visibleWorldRect
    let topLeft = viewport.viewToWorld(.zero)
    let bottomRight = viewport.viewToWorld(
      CGPoint(x: Self.viewSize.width, y: Self.viewSize.height))
    #expect(abs(rect.minX - topLeft.x) < 1e-9)
    #expect(abs(rect.minY - topLeft.y) < 1e-9)
    #expect(abs(rect.maxX - bottomRight.x) < 1e-9)
    #expect(abs(rect.maxY - bottomRight.y) < 1e-9)
  }
}
