// logisim-evolved: a native Swift/macOS port of logisim-evolution.
// Derived from logisim-evolution, which is GPL-3.0-only. This port is a derivative work and is
// therefore GPL-3.0-only.
// SPDX-License-Identifier: GPL-3.0-only
//
// The selection outline hugs the component instead of enclosing it.
//
// ── Where this came from ─────────────────────────────────────────────────────────────────────
//
// Reported from real use: the blue box should "wrap around the object's actual boundaries better".
// It was `insetBy(dx: -1.5, dy: -1.5)`, EXPANDED 1.5pt on every side, and the 1pt stroke is
// centred on that edge, so the visible line sat a full 2pt clear of the component. It read as a
// container around the object rather than a selection of it.
//
// ── Why a test for three lines of geometry ───────────────────────────────────────────────────
//
// Because nothing gated it. Changing the inset reddened no test in the suite, which means the
// previous value could have been wrong from the day it was written, and was, with the suite
// green throughout. That is the same shape as every other defect found here this week: correct
// code nobody could have caught being wrong.
//
// Rasterising the canvas and measuring ink would be the heavier alternative. It is not better
// here: the question is purely "which rectangle", and a pixel test would answer it slowly and
// with a tolerance, while this answers it exactly.

import CoreGraphics
import Foundation
import Testing

@testable import LogisimUI

@Suite("Selection outline geometry")
struct SelectionOutlineTests {

  private let bounds = CGRect(x: 100, y: 50, width: 40, height: 20)

  /// **The defect.** The outline must never be larger than the component it marks.
  @Test("a component's outline is never outside its own bounds")
  func componentOutlineStaysInside() {
    let rect = CircuitSceneView.selectionOutline(for: bounds, isWire: false)
    #expect(
      bounds.contains(rect),
      """
      the outline \(rect) escapes the component's bounds \(bounds) — it will read as a box AROUND \
      the object rather than a selection OF it, which is what was reported.
      """)
  }

  /// …and it must still be *on* the boundary, not shrunk into the middle of the component. Both
  /// halves are needed: "inside" alone is satisfied by a dot at the centre.
  @Test("a component's outline sits on the boundary, not shrunk inwards")
  func componentOutlineHugsTheEdge() {
    let rect = CircuitSceneView.selectionOutline(for: bounds, isWire: false)
    #expect(
      abs(rect.minX - bounds.minX) <= 1 && abs(rect.maxX - bounds.maxX) <= 1,
      "the outline is \(rect), more than a stroke-width inside \(bounds)")
    #expect(abs(rect.minY - bounds.minY) <= 1 && abs(rect.maxY - bounds.maxY) <= 1)
  }

  /// The one case that must grow. A wire's bounds are a zero-thickness line, so an outline drawn
  /// exactly on them has no area and cannot be seen; asserted separately so a future "hug
  /// everything" simplification cannot silently make wire selection invisible.
  @Test("a wire's outline grows, because its bounds have no thickness")
  func wireOutlineGrows() {
    let wire = CGRect(x: 100, y: 50, width: 60, height: 0)
    let rect = CircuitSceneView.selectionOutline(for: wire, isWire: true)
    #expect(rect.height > 0, "a wire's selection outline has no height and cannot be seen")
    #expect(
      rect.width > wire.width,
      "the outline does not extend past the wire's ends, so a short wire is hard to see")
  }

  /// The two cases must actually differ, or the wire branch is dead and the test above is passing
  /// for the wrong reason.
  @Test("the wire and component cases are genuinely different")
  func theTwoCasesDiffer() {
    let asWire = CircuitSceneView.selectionOutline(for: bounds, isWire: true)
    let asComponent = CircuitSceneView.selectionOutline(for: bounds, isWire: false)
    #expect(
      asWire != asComponent,
      "both branches return the same rectangle, so one of them is unreachable in effect")
  }
}
