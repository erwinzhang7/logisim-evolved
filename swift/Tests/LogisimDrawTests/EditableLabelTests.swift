// EditableLabelTests: part of logisim-evolved.
//
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// Every expectation here is the observed behaviour of `com.cburch.draw.util.EditableLabel`
// (4.1.0). Two families of regression are pinned:
//
//  1. `equals`/`hashCode` compare exactly seven fields and deliberately exclude the four
//     measured metrics. Swift's *synthesized* `Hashable` would include them, which made a
//     painted `DrawText` stop matching an identical unpainted one.
//  2. `getLeftX()`/`getBaseY()` are `float` and `getBounds()` narrows with a single `(int)`
//     cast at the end. Halving in `Int` truncates the quotient one step too early and is off by
//     one for odd widths: the common case, since `SvgReader` maps every `text-anchor` other
//     than `start`/`end` to `HALIGN_CENTER`.

import LogisimKernel
import Testing

@testable import LogisimDraw

/// Stands in for the CoreText-backed provider `LogisimRender` supplies. `EditableLabel`'s
/// metrics are zero until something calls `measure(using:)`, exactly as upstream's are zero
/// until `paint(Graphics)` runs, see `TextMetrics.swift`.
private struct FixedMetrics: TextMetricsProviding {
  let width: Int
  let ascent: Int
  let descent: Int
  func measure(text: String, font: FontSpec) -> (width: Int, ascent: Int, descent: Int) {
    (width, ascent, descent)
  }
}

private let sansSerif12 = FontSpec(family: "SansSerif", size: 12)

// MARK: - 1. Equality excludes the measured metrics

@Test func measuringALabelDoesNotChangeItsEquality() {
  let unpainted = EditableLabel(x: 10, y: 20, text: "hi", font: sansSerif12)
  var painted = EditableLabel(x: 10, y: 20, text: "hi", font: sansSerif12)
  painted.measure(using: FixedMetrics(width: 7, ascent: 9, descent: 2))

  // The measurement really did land; otherwise this test would pass vacuously.
  #expect(painted.width == 7)
  #expect(painted.ascent == 9)
  #expect(painted.descent == 2)
  #expect(unpainted.width == 0)

  // Java: equals() compares x, y, text, font, color, horzAlign, vertAlign only.
  #expect(unpainted == painted)
  #expect(painted == unpainted)
  #expect(unpainted.hashValue == painted.hashValue)
}

@Test func drawTextMatchesSurvivesBeingPainted() {
  let unpainted = DrawText(x: 10, y: 20, text: "hi")
  let painted = DrawText(x: 10, y: 20, text: "hi")
  painted.measure(using: FixedMetrics(width: 7, ascent: 9, descent: 2))

  // `Text.matches` delegates straight to label equality; `MatchingSet`-based appearance diffing
  // depends on this and on the hash agreeing with it.
  #expect(unpainted.matches(painted))
  #expect(painted.matches(unpainted))
  #expect(unpainted.matchesHashCode() == painted.matchesHashCode())
}

@Test func labelsDifferingInAnyOfJavasSevenFieldsAreUnequal() {
  let base = EditableLabel(x: 10, y: 20, text: "hi", font: sansSerif12)

  var differentX = base
  differentX.x = 11
  var differentY = base
  differentY.y = 21
  var differentText = base
  differentText.text = "ho"
  var differentFont = base
  differentFont.font = FontSpec(family: "Serif", size: 12)
  var differentColor = base
  differentColor.color = ColorSpec(red: 255, green: 0, blue: 0)
  var differentHalign = base
  differentHalign.horizontalAlignment = .center
  var differentValign = base
  differentValign.verticalAlignment = .middle

  for variant in [
    differentX, differentY, differentText, differentFont, differentColor, differentHalign,
    differentValign,
  ] {
    #expect(variant != base)
  }
  #expect(base == base)
}

// MARK: - 2. Float geometry, truncated once

/// `Bounds getBounds()` with `x = 10`, an odd `width = 7` and `HALIGN_CENTER`:
/// Java's `getLeftX()` is `10 - 7 / 2.0F == 6.5F` and `(int) 6.5F == 6`. Halving in `Int` first
/// gives `10 - 3 == 7`, one pixel to the right.
@Test func centredBoundsTruncateOnceAtTheEndLikeJava() {
  var label = EditableLabel(x: 10, y: 20, text: "hi", font: sansSerif12)
  label.horizontalAlignment = .center
  label.measure(using: FixedMetrics(width: 7, ascent: 9, descent: 2))

  #expect(label.bounds == Bounds.create(6, 11, 7, 11))
}

@Test func centredBoundsAreUnchangedForEvenWidths() {
  var label = EditableLabel(x: 10, y: 20, text: "hi", font: sansSerif12)
  label.horizontalAlignment = .center
  label.measure(using: FixedMetrics(width: 8, ascent: 9, descent: 2))

  // 10 - 8 / 2.0F == 6.0F; nothing to truncate, so both arithmetics agree here.
  #expect(label.bounds == Bounds.create(6, 11, 8, 11))
}

/// `(int)` rounds toward zero, so a negative half also loses its fraction upward.
/// `-10 - 7 / 2.0F == -13.5F`, `(int) -13.5F == -13`.
@Test func centredBoundsRoundTowardZeroOnNegativeCoordinates() {
  var label = EditableLabel(x: -10, y: 20, text: "hi", font: sansSerif12)
  label.horizontalAlignment = .center
  label.measure(using: FixedMetrics(width: 7, ascent: 9, descent: 2))

  #expect(label.bounds == Bounds.create(-13, 11, 7, 11))
}

@Test func rightAlignedAndLeftAlignedBoundsAreUnaffected() {
  var left = EditableLabel(x: 10, y: 20, text: "hi", font: sansSerif12)
  left.measure(using: FixedMetrics(width: 7, ascent: 9, descent: 2))
  #expect(left.bounds == Bounds.create(10, 11, 7, 11))

  var right = EditableLabel(x: 10, y: 20, text: "hi", font: sansSerif12)
  right.horizontalAlignment = .right
  right.measure(using: FixedMetrics(width: 7, ascent: 9, descent: 2))
  #expect(right.bounds == Bounds.create(3, 11, 7, 11))
}

/// `getBaseY()`'s `MIDDLE` arm is `y + (ascent - descent) / 2.0F`, and `getBounds()` casts
/// *that* before subtracting `ascent` (`(int) getBaseY() - ascent`). With `y = -20`,
/// `ascent = 9`, `descent = 2`: `-20 + 3.5F == -16.5F`, `(int) -16.5F == -16`, `y0 == -25`.
/// Int halving gives `-20 + 3 == -17` and `y0 == -26`.
@Test func middleBaselineTruncatesTowardZeroAfterTheDivision() {
  var label = EditableLabel(x: 10, y: -20, text: "hi", font: sansSerif12)
  label.verticalAlignment = .middle
  label.measure(using: FixedMetrics(width: 7, ascent: 9, descent: 2))

  #expect(label.bounds == Bounds.create(10, -25, 7, 11))
}

@Test func middleBaselineWithADescentLargerThanTheAscent() {
  // (ascent - descent) == -7, so 20 + (-7) / 2.0F == 16.5F -> 16, y0 == 14.
  // Int halving: -7 / 2 == -3 (Swift truncates toward zero too), 20 - 3 == 17, y0 == 15.
  var label = EditableLabel(x: 10, y: 20, text: "hi", font: sansSerif12)
  label.verticalAlignment = .middle
  label.measure(using: FixedMetrics(width: 7, ascent: 2, descent: 9))

  #expect(label.bounds == Bounds.create(10, 14, 7, 11))
}

@Test func topAndBottomBaselinesAreIntegerArithmeticInJavaToo() {
  var top = EditableLabel(x: 10, y: 20, text: "hi", font: sansSerif12)
  top.verticalAlignment = .top
  top.measure(using: FixedMetrics(width: 7, ascent: 9, descent: 2))
  #expect(top.bounds == Bounds.create(10, 20, 7, 11))

  var bottom = EditableLabel(x: 10, y: 20, text: "hi", font: sansSerif12)
  bottom.verticalAlignment = .bottom
  bottom.measure(using: FixedMetrics(width: 7, ascent: 9, descent: 2))
  #expect(bottom.bounds == Bounds.create(10, 9, 7, 11))
}

/// The latent upstream behaviour `TextMetrics.swift` documents: metrics are zero until measured,
/// so an unpainted label reports a zero-sized box. Pinned so the float rework cannot quietly
/// change it.
@Test func anUnmeasuredLabelStillReportsZeroSizedBounds() {
  let label = EditableLabel(x: 10, y: 20, text: "hi", font: sansSerif12)
  #expect(label.bounds == Bounds.create(10, 20, 0, 0))
}

// MARK: - `contains` is a float comparison in Java too

/// Java's `contains` compares its two `int` arguments against the `float` results of
/// `getLeftX()`/`getBaseY()`, so the test window is a half-open interval that can sit on a half
/// pixel.
///
/// A half-pixel shift alone is invisible here: `[x0, x0 + width)` and `[x0 - 0.5, x0 - 0.5 +
/// width)` hold the same integers when `width` is an integer, which is why `HALIGN_CENTER` on
/// its own does not discriminate. What does discriminate is `VALIGN_MIDDLE` at a negative `y`,
/// where `Int` halving truncates toward zero and the float does not: `y = -20`, `ascent = 9`,
/// `descent = 2` gives `getBaseY() == -16.5F` and a window of `[-25.5, -14.5)`, i.e. rows
/// -25…-15, whereas `Int` arithmetic gives `baseY == -17` and rows -26…-16; a window off by a
/// whole row at both ends.
@Test func containsUsesFloatWindowsLikeJava() {
  var label = EditableLabel(x: 10, y: -20, text: "hi", font: sansSerif12)
  label.horizontalAlignment = .center
  label.verticalAlignment = .middle
  label.measure(using: FixedMetrics(width: 7, ascent: 9, descent: 2))

  #expect(label.contains(7, -15))  // Int arithmetic put the bottom edge at -15 and excluded it.
  #expect(!label.contains(7, -26))  // Int arithmetic put the top edge at -26 and included it.

  // The rows both arithmetics agree on, as a sanity rail.
  #expect(label.contains(7, -25))
  #expect(label.contains(7, -16))
  #expect(!label.contains(7, -14))

  // Horizontal window: [6.5, 13.5) holds 7…13.
  #expect(!label.contains(6, -20))
  #expect(label.contains(7, -20))
  #expect(label.contains(13, -20))
  #expect(!label.contains(14, -20))
}

// MARK: - The `(int)` narrowing saturates rather than trapping (D13)

/// Java's `(int)` cast of a `float` saturates at `Integer.MAX_VALUE`; Swift's `Int(_: Float)`
/// traps on anything out of range. Every coordinate reaching here came out of a `.circ`
/// `<appear>` section, so a trap would be a crash on file input.
@Test func extremeCoordinatesSaturateInsteadOfTrapping() {
  var label = EditableLabel(x: Int(Int32.max), y: 20, text: "hi", font: sansSerif12)
  label.horizontalAlignment = .center
  label.measure(using: FixedMetrics(width: 1, ascent: 9, descent: 2))

  // (float) Integer.MAX_VALUE rounds up to 2^31; minus 0.5F is still 2^31 in float, and
  // (int) 2.14748365E9F == Integer.MAX_VALUE.
  #expect(label.bounds.x == Int(Int32.max))
}
