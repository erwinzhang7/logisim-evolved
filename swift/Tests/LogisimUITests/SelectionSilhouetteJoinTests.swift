// logisim-evolved: a native Swift/macOS port of logisim-evolution.
// Derived from logisim-evolution, which is GPL-3.0-only. This port is a derivative work and is
// therefore GPL-3.0-only.
// SPDX-License-Identifier: GPL-3.0-only
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// DOES THE NEW SHAPE ACTUALLY REACH THE SCREEN?
//
// Every assertion in `SelectionSilhouetteTests` is on a pure function, which is exactly the
// property that made this change safe to make, and exactly the property that would let the whole
// thing be correct and unreachable. That is not a hypothetical failure in this codebase:
// `CircuitRenderer` was once complete, correct, and called by nothing at all (see the header on
// `CanvasWiringTests`), and this very selection outline was only gateable in the first place
// because its geometry had been pulled out of the `CGContext` call.
//
// So this suite draws the real `CircuitSceneView` into a bitmap and looks at pixels. It asks the
// one question the pure tests cannot: does the selection paint the component's SHAPE, or a BOX?
//
// A Pin's bounding box has corners its pentagon does not reach; `Pin.drawInputShape` draws a
// flat left edge that slants back to a tip on the right, so the box's two right-hand corners are
// outside the arrow. Ink there means a rectangle was painted. No ink there, plus ink elsewhere,
// means the silhouette was. Nothing anywhere means the adornment never ran.
//
// Deliberately NOT a screenshot of the app: the owner's screen is his own, and an offscreen
// `CGContext` answers the same question with no window in existence.
// ═════════════════════════════════════════════════════════════════════════════════════════════

import AppKit
import CoreGraphics
import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender
import LogisimStd
import Testing

@testable import LogisimUI

@Suite("Selection silhouette — the join to the canvas")
@MainActor
struct SelectionSilhouetteJoinTests {

  private let size = 120

  /// Draws `view` into an offscreen bitmap and returns the raw RGBA bytes.
  private func render(_ view: CircuitSceneView) -> [UInt8] {
    let bytesPerRow = size * 4
    var data = [UInt8](repeating: 0, count: bytesPerRow * size)
    data.withUnsafeMutableBytes { raw in
      guard
        let space = CGColorSpace(name: CGColorSpace.sRGB),
        let ctx = CGContext(
          data: raw.baseAddress, width: size, height: size, bitsPerComponent: 8,
          bytesPerRow: bytesPerRow, space: space,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return }
      // The view is flipped (y down); a CG bitmap is not. Flip the CTM so view coordinates land
      // where the view expects them, and undo it when reading, see `pixel`.
      ctx.translateBy(x: 0, y: CGFloat(size))
      ctx.scaleBy(x: 1, y: -1)
      let saved = NSGraphicsContext.current
      NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
      view.draw(view.bounds)
      NSGraphicsContext.current = saved
    }
    return data
  }

  /// View-space (x, y) → that pixel's bytes. `size - 1 - y` undoes the CTM flip in `render`.
  private func pixel(_ data: [UInt8], x: Int, y: Int) -> UInt32 {
    guard x >= 0, y >= 0, x < size, y < size else { return 0 }
    let i = (size - 1 - y) * size * 4 + x * 4
    return UInt32(data[i]) << 24 | UInt32(data[i + 1]) << 16 | UInt32(data[i + 2]) << 8
      | UInt32(data[i + 3])
  }

  @Test("selecting a Pin paints its pentagon on the canvas, not a box around it")
  func selectionPaintsTheSilhouette() throws {
    StdLibraries.registerAll()
    let circuit = try Circuit(name: "join")
    let attributes = Pin.factory.createAttributeSet()
    // The shipped appearance: see the note in `SelectionSilhouetteTests`' fixture.
    try attributes.setValue(
      LogisimStd.ProbeAttributes.probeAppearance,
      LogisimStd.ProbeAttributes.appearEvolutionNew)
    let component = try Pin.factory.createComponent(
      location: Location.create(0, 0, hasToSnap: false), attributes: attributes)
    try circuit.mutatorAdd(component)

    let build = CircuitSceneSource.build(circuit: circuit, appearance: CanvasAppearance())
    let target = try #require(build.targets.first)

    let view = CircuitSceneView(frame: NSRect(x: 0, y: 0, width: size, height: size))
    view.build = build
    // 1:1 zoom with the component centred, so world → view is a pure translation and the
    // arithmetic below stays readable.
    view.viewport = CanvasViewport(
      zoom: 1,
      center: CGPoint(x: target.bounds.midX, y: target.bounds.midY),
      viewSize: CGSize(width: CGFloat(size), height: CGFloat(size)))
    var appearance = CanvasAppearance()
    // The grid and antialiasing are both noise for a pixel diff, and the grid in particular
    // would change under the translucent selection fill and be counted as selection ink.
    appearance.showGrid = false
    appearance.antialiasing = false
    view.appearance_ = appearance

    let unselected = render(view)
    view.selection = [target.id]
    let selected = render(view)

    var changed: [(x: Int, y: Int)] = []
    for y in 0..<size {
      for x in 0..<size where pixel(unselected, x: x, y: y) != pixel(selected, x: x, y: y) {
        changed.append((x, y))
      }
    }

    // THE JOIN. If the silhouette never reaches `draw`, nothing changes at all.
    #expect(
      !changed.isEmpty,
      "selecting a component changed no pixels — the selection adornment is not being drawn")

    // THE SHAPE.
    let box = target.bounds.applying(view.worldToView)
    let span: CGFloat = 4
    let corners = changed.filter { p in
      let nearRight = CGFloat(p.x) >= box.maxX - span
      let nearTop = CGFloat(p.y) <= box.minY + span
      let nearBottom = CGFloat(p.y) >= box.maxY - span
      return nearRight && (nearTop || nearBottom)
    }
    #expect(
      corners.isEmpty,
      """
      \(corners.count) selection pixels landed in the Pin's bounding-box corners, e.g. \
      \(corners.prefix(4).map { "(\($0.x),\($0.y))" }). `Pin.drawInputShape`'s arrow does not \
      reach those corners, so what was painted is a BOX — the reported defect. Box \(box).
      """)
  }

  /// The wire case, drawn rather than reasoned about. A wire has no silhouette, so the rectangle
  /// path has to still be live; if the `.bounds` branch were dropped in the rewrite, selecting a
  /// wire would silently draw nothing at all.
  @Test("selecting a wire still paints something")
  func selectingAWirePaintsSomething() throws {
    StdLibraries.registerAll()
    let circuit = try Circuit(name: "join-wire")
    try circuit.mutatorAdd(
      Wire.create(
        Location.create(-30, 0, hasToSnap: false), Location.create(30, 0, hasToSnap: false)))
    let build = CircuitSceneSource.build(circuit: circuit, appearance: CanvasAppearance())
    let target = try #require(build.targets.first)
    #expect(target.kind == .wire)

    let view = CircuitSceneView(frame: NSRect(x: 0, y: 0, width: size, height: size))
    view.build = build
    view.viewport = CanvasViewport(
      zoom: 1, center: .zero,
      viewSize: CGSize(width: CGFloat(size), height: CGFloat(size)))
    var appearance = CanvasAppearance()
    appearance.showGrid = false
    appearance.antialiasing = false
    view.appearance_ = appearance

    let unselected = render(view)
    view.selection = [target.id]
    let selected = render(view)

    var changed = 0
    for y in 0..<size {
      for x in 0..<size where pixel(unselected, x: x, y: y) != pixel(selected, x: x, y: y) {
        changed += 1
      }
    }
    #expect(
      changed > 0,
      """
      selecting a wire changed no pixels. A wire has no scene group of its own, so it takes the \
      rectangle fallback; if that branch is gone, wire selection is invisible.
      """)
  }
}
