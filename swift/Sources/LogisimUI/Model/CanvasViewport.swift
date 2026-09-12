// LogisimUI: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.

import CoreGraphics
import Foundation

/// Where the camera is, in world units.
///
/// **Coordinate convention; binding for the renderer.** World space is Logisim's own:
/// origin top-left, +x right, **+y down**, one unit = one Logisim unit, the grid is every
/// 10 units. The hosting `NSView` is `isFlipped == true`, so world → view is a pure
/// scale-and-translate with *no* Y flip. `transform` below is the only definition of that
/// mapping; the render surface must use it and must not invent its own.
///
/// **Upstream issue #1262; "mouse zoom and panning".** Upstream has no camera at all: the
/// canvas is a `JScrollPane` viewport over a `Canvas` whose *preferred size* is the circuit
/// bounds times the zoom factor (`Canvas.computeSize`), and zooming means resizing that
/// component and then trying to re-derive scrollbar positions from ratios
/// (`Canvas.java:700-710`). Consequences the users report: the anchor point drifts because
/// the recomputation runs after a `doLayout()` that has already clamped the bars; you cannot
/// scroll past the content edge, so you cannot place a component to the left of the leftmost
/// existing one without first moving everything; and plain two-finger scroll is bound to
/// wheel-notch scrollbar increments (`Canvas.java:917-921`) rather than to a continuous
/// gesture, so trackpad panning is steppy and has no inertia.
///
/// This model has none of those properties. The camera is `(center, zoom)`, it is
/// unbounded, zoom anchors exactly on a supplied world point, and pan is a direct
/// translation in world units, so a trackpad delta maps 1:1 to pixels at any zoom.
public struct CanvasViewport: Sendable, Equatable {
  /// View pixels per world unit. 1.0 == 100%.
  public var zoom: Double
  /// The world point displayed at the centre of the view.
  public var center: CGPoint
  /// Size of the hosting view, in points.
  public var viewSize: CGSize

  public init(zoom: Double = 1, center: CGPoint = .zero, viewSize: CGSize = .zero) {
    self.zoom = zoom
    self.center = center
    self.viewSize = viewSize
  }

  public static let minimumZoom = 0.05
  public static let maximumZoom = 10.0

  /// World → view. Feed straight into `CGContext.concatenate`.
  public var transform: CGAffineTransform {
    CGAffineTransform(translationX: viewSize.width / 2, y: viewSize.height / 2)
      .scaledBy(x: zoom, y: zoom)
      .translatedBy(x: -center.x, y: -center.y)
  }

  public func worldToView(_ point: CGPoint) -> CGPoint {
    point.applying(transform)
  }

  public func viewToWorld(_ point: CGPoint) -> CGPoint {
    point.applying(transform.inverted())
  }

  /// The world rectangle currently on screen. This is what makes viewport culling possible
  /// (D6); upstream has no equivalent and paints every component every frame.
  public var visibleWorldRect: CGRect {
    guard zoom > 0, viewSize.width > 0, viewSize.height > 0 else { return .null }
    let w = viewSize.width / zoom
    let h = viewSize.height / zoom
    return CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h)
  }

  /// Zoom about a fixed world point: the cursor, or the pinch centroid. The invariant is
  /// that `anchor` stays under the same view pixel, which is the property upstream loses.
  public mutating func zoom(to newZoom: Double, anchoringWorldPoint anchor: CGPoint) {
    let clamped = min(max(newZoom, Self.minimumZoom), Self.maximumZoom)
    guard clamped != zoom else { return }
    // Keep the anchor's view position fixed:
    //   viewOffsetFromCentre = (anchor - center) * zoom  must be invariant.
    let offset = CGPoint(x: anchor.x - center.x, y: anchor.y - center.y)
    let scale = zoom / clamped
    center = CGPoint(
      x: anchor.x - offset.x * scale,
      y: anchor.y - offset.y * scale)
    zoom = clamped
  }

  public mutating func zoom(to newZoom: Double, anchoringViewPoint viewPoint: CGPoint) {
    zoom(to: newZoom, anchoringWorldPoint: viewToWorld(viewPoint))
  }

  /// Pan by a delta expressed in *view* points, so trackpad deltas need no conversion.
  public mutating func pan(byViewDelta delta: CGSize) {
    guard zoom > 0 else { return }
    center.x -= delta.width / zoom
    center.y -= delta.height / zoom
  }

  /// Fit `rect` (world) with a margin, clamped to the legal zoom range.
  public mutating func fit(_ rect: CGRect, padding: Double = 24) {
    guard viewSize.width > 0, viewSize.height > 0 else { return }
    let target = rect.isNull || rect.isEmpty
      ? CGRect(x: -50, y: -50, width: 100, height: 100)
      : rect
    let usableW = max(viewSize.width - padding * 2, 1)
    let usableH = max(viewSize.height - padding * 2, 1)
    let fitZoom = min(usableW / target.width, usableH / target.height)
    zoom = min(max(fitZoom, Self.minimumZoom), Self.maximumZoom)
    center = CGPoint(x: target.midX, y: target.midY)
  }

  /// Bring `rect` into view without changing zoom; used when the explorer selects a
  /// component, or when the simulator reports an error at a location.
  public mutating func reveal(_ rect: CGRect, animatedMargin: Double = 40) {
    guard zoom > 0 else { return }
    var visible = visibleWorldRect
    guard !visible.isNull else { return }
    visible = visible.insetBy(dx: animatedMargin / zoom, dy: animatedMargin / zoom)
    if visible.contains(rect) { return }
    center = CGPoint(x: rect.midX, y: rect.midY)
  }
}

/// The discrete zoom ladder used by ⌘+ / ⌘− and the zoom popup.
///
/// Reproduces `Frame.buildZoomSteps()` (`Frame.java:327-341`): 5→50 in 5s, 50→200 in 10s,
/// 200→1000 in 20s. Kept because it is a genuinely good ladder and because a user coming
/// from upstream expects "150%" to be a stop. Continuous pinch is *not* snapped to it;
/// upstream has no continuous zoom at all.
public enum CanvasZoom {
  public static let steps: [Double] = {
    var out: [Double] = []
    var z = 0.0
    for (maxZoom, step) in [(50.0, 5.0), (200.0, 10.0), (1000.0, 20.0)] {
      while z < maxZoom {
        z += step
        out.append(z / 100)
      }
    }
    return out
  }()

  public static func next(after zoom: Double) -> Double {
    steps.first { $0 > zoom * 1.001 } ?? steps.last ?? zoom
  }

  public static func previous(before zoom: Double) -> Double {
    steps.last { $0 < zoom * 0.999 } ?? steps.first ?? zoom
  }

  public static func percentLabel(_ zoom: Double) -> String {
    let percent = zoom * 100
    if percent >= 100 || percent == percent.rounded() {
      return "\(Int(percent.rounded()))%"
    }
    return String(format: "%.1f%%", percent)
  }
}
