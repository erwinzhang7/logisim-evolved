// VideoContainsToleranceTests.swift: part of logisim-evolved.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// std.io.Video's HIT-TEST TOLERANCE: the second half of board #91, and a VERIFIED NEGATIVE.
//
// #91 fixed `Splitter.contains`, which used `bounds.contains(point)` (allowed error 0) where
// 4.1.0 resolves the `super.contains` call to `AbstractComponent.java:19-23`'s
// `bds.contains(pt, 1)`. 4.1.0 has exactly three implementors of the two-argument `contains`:
// `Wire.java:129-131`, `AbstractComponent.java:26-30`, and `InstanceComponent`. The board asked
// whether `std.io.Video`, the *other* `ManagedComponent` that reaches `AbstractComponent`,
// diverges the same way.
//
// **It does not, and this file is the standing proof.** Both routes end at
// `Bounds.contains(pt, 1)`; the port simply arrives there down a different inheritance chain.
//
// ── Settled against the shipping jar's bytecode, not a source tree (D16) ────────────────────
//
//     $ javap -cp /Applications/Logisim-evolution.app/Contents/app/\
//                 logisim-evolution-4.1.0-all.jar com.cburch.logisim.std.io.Video
//     class com.cburch.logisim.std.io.Video extends com.cburch.logisim.comp.ManagedComponent
//           implements com.cburch.logisim.tools.ToolTipMaker,
//                      com.cburch.logisim.data.AttributeListener {
//       ...no `contains` in the method table...
//
//     $ javap ... com.cburch.logisim.comp.ManagedComponent
//     public abstract class ...ManagedComponent extends ...AbstractComponent {
//       ...no `contains` in the method table...
//
//     $ javap ... com.cburch.logisim.comp.AbstractComponent
//     public abstract class ...AbstractComponent implements ...Component {
//       public boolean contains(com.cburch.logisim.data.Location);
//       public boolean contains(com.cburch.logisim.data.Location, java.awt.Graphics);
//
//     $ javap -c ... com.cburch.logisim.comp.AbstractComponent      # both bodies
//       11: aload_2 / 12: aload_1 / 13: iconst_1                    <-- the literal 1
//       14: invokevirtual  Bounds.contains:(Lcom/cburch/logisim/data/Location;I)Z
//
// So in 4.1.0, `Video.contains(pt)` is `getBounds().contains(pt, 1)`.
//
// ── Why the port is already right, despite not being a `ManagedComponent` at all ────────────
//
// `RgbVideo.swift`'s header states the deliberate divergence: upstream's `Video` predates the
// `Instance`/`InstanceFactory` split and hand-rolls a `ManagedComponent`, but every port width
// it computes is a pure function of the attribute set, so the port lands it on the ordinary
// `InstanceFactory` chassis as `Video: InstanceFactoryBase`. That means the hit test resolves:
//
//     StdInstanceComponent.contains(point)            (StdInstanceComponent.swift:161-166)
//       -> factory.contains(point - location, attrs)
//       -> InstanceFactoryBase.contains                (InstanceFactory.swift:305-307)
//       -> offsetBounds(attrs).contains(point, 1)      <-- the same allowed error of 1
//
// which mirrors 4.1.0's OTHER implementor of the two-argument predicate,
// `InstanceFactory.java:125-131` (`bds.contains(loc, 1)`), reached through
// `InstanceComponent.java:216-220`. `Video` declares no `contains` override in either tree, so
// both trees land on an allowed error of 1: upstream via `AbstractComponent`, the port via
// `InstanceFactoryBase`. Translating by `-location` before the test versus translating the box
// by `+location` before the test is the same predicate; the ring probed below is derived from
// the component's ABSOLUTE `bounds`, so it would catch either half getting the translation wrong.
//
// ── What this file therefore is ─────────────────────────────────────────────────────────────
//
// A regression gate on a property that is currently correct and that nothing else can see: hit
// tolerance is not serialised, so no canonical, migration or edit-parity gate can reach it. If
// somebody later gives `Video` a `contains` override, or "fixes" `InstanceFactoryBase`'s
// tolerance to 0, a click on the boundary pixel of a 270x270 video panel stops selecting it,
// and only this file says so.
//
// ── Bounds.contains's asymmetry (as #91's file also records) ────────────────────────────────
//
//     px >= x - e && px < x + wid + e && py >= y - e && py < y + ht + e
//
// so at `e == 1` the admitted x range is `[x - 1, x + wid]`; the ring is the four lines
// `x - 1`, `x + wid`, `y - 1`, `y + ht`, and `x - 2` / `x + wid + 1` must stay OUT. Probing both
// directions is what stops "widen it until the test passes" from also passing.

import Foundation
import LogisimFile
import LogisimKernel
import Testing

@testable import LogisimStd

@Suite("std.io.Video.contains — hit-test tolerance (the allowed error of 1 is present)")
struct VideoContainsToleranceTests {

  /// Away from the origin, and off the 10-unit grid in one axis, so that a sign error in a probe
  /// offset cannot land on a coincidentally-valid pixel.
  private static let origin = Location.create(300, 400, hasToSnap: false)

  private func makeVideo() throws -> any Component {
    let attributes = Video.factory.createAttributeSet()
    return try Video.factory.createComponent(location: Self.origin, attributes: attributes)
  }

  // ── 0. Geometry, pinned once so a drift reports as a drift ─────────────────────────────────

  /// `Factory.getOffsetBounds`: `bw = max(s*w + 14, 100)`, `bh = max(s*h + 14, 20)`,
  /// `Bounds.create(-30, -bh, bw, bh)`. `VideoAttributes`' defaults are scale 2, 128x128, so
  /// `bw == bh == 2*128 + 14 == 270` and the offset box is `(-30, -270, 270, 270)`. Translated
  /// to (300, 400) that is `(270, 130, 270, 270)`.
  ///
  /// Not the point of the file, but if the box ever moves the failure should say "the box moved"
  /// rather than surface as an inexplicable tolerance failure three tests down.
  @Test("The default video panel's box is (270, 130, 270, 270) — geometry drift guard")
  func defaultVideoBounds() throws {
    let b = try makeVideo().bounds
    #expect(b.x == 270)
    #expect(b.y == 130)
    #expect(b.width == 270)
    #expect(b.height == 270)
  }

  // ── 1. The ring: exactly the boundary pixel, which 4.1.0 accepts ───────────────────────────

  @Test("A click exactly on each boundary line selects, as 4.1.0's AbstractComponent does")
  func boundaryRingHits() throws {
    let video = try makeVideo()
    let b = video.bounds
    let midX = b.x + b.width / 2
    let midY = b.y + b.height / 2

    let ring = [
      Location.create(b.x - 1, midY, hasToSnap: false),  // left column
      Location.create(b.x + b.width, midY, hasToSnap: false),  // right column
      Location.create(midX, b.y - 1, hasToSnap: false),  // top row
      Location.create(midX, b.y + b.height, hasToSnap: false),  // bottom row
    ]

    for point in ring {
      // The premise: outside the zero-tolerance box, inside the 1-tolerance box. If this ever
      // fails the probe point is wrong, not the component.
      #expect(b.contains(point, 0) == false, "premise: \(point) should be outside e=0")
      #expect(b.contains(point, 1) == true, "premise: \(point) should be inside e=1")

      #expect(video.contains(point) == true, "4.1.0 selects on the boundary pixel at \(point)")
    }
  }

  // ── 2. One pixel further out still misses; the tolerance is exactly 1 ─────────────────────

  @Test("One pixel beyond the ring still misses — the error allowed is exactly 1, not 'generous'")
  func twoPixelsOutMisses() throws {
    let video = try makeVideo()
    let b = video.bounds
    let midX = b.x + b.width / 2
    let midY = b.y + b.height / 2

    let outside = [
      Location.create(b.x - 2, midY, hasToSnap: false),
      Location.create(b.x + b.width + 1, midY, hasToSnap: false),
      Location.create(midX, b.y - 2, hasToSnap: false),
      Location.create(midX, b.y + b.height + 1, hasToSnap: false),
    ]

    for point in outside {
      #expect(b.contains(point, 1) == false, "premise: \(point) should be outside e=1")
      #expect(video.contains(point) == false, "\(point) is two pixels out and must miss")
    }
  }

  // ── 3. The interior, so a `contains` that answers `false` for everything cannot pass ───────

  /// A guard with two directions gets probed in both (#94's lesson): a `contains` hard-wired to
  /// `false` would satisfy §2 alone, and a `contains` hard-wired to `true` would satisfy §1
  /// alone. Only all three sections together pin the predicate.
  @Test("The panel's own interior still hits — the predicate is not stuck at false")
  func interiorHits() throws {
    let video = try makeVideo()
    let b = video.bounds
    let inside = Location.create(b.x + b.width / 2, b.y + b.height / 2, hasToSnap: false)
    #expect(b.contains(inside, 0) == true)
    #expect(video.contains(inside) == true)
  }

  // ── 4. The factory-relative half, asserted directly ────────────────────────────────────────

  /// `StdInstanceComponent.contains` translates by `-location` and defers to the factory, so the
  /// tolerance actually lives in `InstanceFactoryBase.contains`. Asserting it here as well means
  /// a failure distinguishes "the factory's tolerance changed" from "the translation broke".
  @Test("Video adds no contains override — the tolerance comes from InstanceFactoryBase")
  func factoryPredicateCarriesTheTolerance() {
    let attributes = Video.factory.createAttributeSet()
    let offset = Video.factory.offsetBounds(attributes)

    // Offset box is (-30, -270, 270, 270): the right boundary column is x == -30 + 270 == 240.
    let onBoundary = Location.create(offset.x + offset.width, 0, hasToSnap: false)
    #expect(offset.contains(onBoundary, 0) == false)
    #expect(Video.factory.contains(onBoundary, attributes) == true)

    let twoOut = Location.create(offset.x + offset.width + 1, 0, hasToSnap: false)
    #expect(Video.factory.contains(twoOut, attributes) == false)
  }
}
