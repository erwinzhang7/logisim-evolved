// SplitterParameters.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.circuit.SplitterParameters),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── Where the Java file actually lives ───────────────────────────────────────────────────────
//
// Upstream puts `Splitter`/`SplitterAttributes`/`SplitterFactory`/`SplitterParameters` in
// `com.cburch.logisim.circuit`, not `com.cburch.logisim.std.wiring`; Splitter is treated as a
// core netlist primitive, wired directly into `WiringLibrary` (`new
// AddTool(SplitterFactory.instance)`) rather than living beside the other wiring components. The
// task brief that scoped this slice named the `std/wiring` directory, but the actual `.java`
// sources are under `circuit/`; this port keeps all four files together under
// `LogisimStd/Wiring/` for the same reason Java keeps them together in its tool list, and because
// `WiringLibrary.swift` (also owned by this slice) needs them in the same target.
//
// ── Pure geometry, no drawing ────────────────────────────────────────────────────────────────
//
// This is pixel arithmetic that both the (unported, M6) painter and `SplitterFactory.offsetBounds`
// consume. Only the bounds-relevant half is load-bearing today; `textAngle`/`textHorzAlign`/
// `textVertAlign` are read solely by `SplitterPainter.drawLabels` (M6, not ported; see
// `Splitter.swift`'s header) but are kept verbatim so the renderer has exact data to consume
// later rather than having to re-derive it.
//
// `textHorzAlign`/`textVertAlign` reproduce `GraphicsUtil.H_LEFT`/`H_RIGHT`/`V_TOP`/`V_BASELINE`
// as raw `Int`s (`GraphicsUtil.java:25-36`: H_LEFT=-1, H_CENTER=0, H_RIGHT=1, V_TOP=-1,
// V_CENTER=0, V_BASELINE=1, V_BOTTOM=2, V_CENTER_OVERALL=3) rather than importing a shared
// alignment type; `GraphicsUtil` itself is D9/D6 UI surface this module cannot see, and no
// shared alignment enum exists yet in `LogisimRender`. M6 can map these onto its own type.
//
// All quantities here are derived from `attrs.spacing` (1...9) and `attrs.fanout` (1...64), both
// range-checked at attribute-parse time (`SplitterAttributes.attrSpacing`/`attrFanout`), so the
// arithmetic below (`gap * (fanout - 1)` maxes out at 90 * 63 = 5,670) cannot reach anywhere near
// `Int32` overflow, let alone the 64-bit range Swift's native `Int` gives it. No `wrap32` needed.

import LogisimKernel

/// `com.cburch.logisim.circuit.SplitterParameters`: the pixel geometry of one splitter,
/// derived once from its attributes and cached by `SplitterAttributes.parameters()`.
struct SplitterParameters {
  // MARK: GraphicsUtil alignment constants (see file header)

  static let hLeft = -1
  static let hCenter = 0
  static let hRight = 1
  static let vTop = -1
  static let vCenter = 0
  static let vBaseline = 1
  static let vBottom = 2
  static let vCenterOverall = 3

  /// `getEnd0X()` / `getEnd0Y()`: location of split end 0 relative to the origin.
  let end0X: Int
  let end0Y: Int

  /// `getEndToEndDeltaX()` / `getEndToEndDeltaY()`: distance from split end *i* to end *i+1*.
  let endToEndDeltaX: Int
  let endToEndDeltaY: Int

  /// `getEndToSpineDeltaX()` / `getEndToSpineDeltaY()`: distance from a split end to the spine.
  let endToSpineDeltaX: Int
  let endToSpineDeltaY: Int

  /// `getSpine0X()` / `getSpine0Y()`: distance from the origin to the far end of the spine.
  let spine0X: Int
  let spine0Y: Int

  /// `getSpine1X()` / `getSpine1Y()`: distance from the origin to the near end of the spine.
  let spine1X: Int
  let spine1Y: Int

  /// `getTextAngle()`: angle (degrees) to rotate the end-label text.
  let textAngle: Int

  /// `getTextHorzAlign()` / `getTextVertAlign()`: see the file header for the constant scheme.
  let textHorzAlign: Int
  let textVertAlign: Int

  /// `SplitterParameters(SplitterAttributes attrs)` (`SplitterParameters.java:30-82`).
  init(_ attrs: SplitterAttributes) {
    let appear = attrs.appear
    let fanout = Int(attrs.fanout)
    let facing = attrs.facing

    let justify: Int
    if appear == .center || appear == .legacy {
      justify = 0
    } else if appear == .right {
      justify = 1
    } else {
      justify = -1
    }
    let width = 20

    let gap = Int(attrs.spacing) * 10
    let offs = 6
    if facing == .north || facing == .south {
      // ^ or V
      let m = facing == .north ? 1 : -1
      end0X =
        justify == 0
        ? gap * ((fanout + 1) / 2 - 1)
        : (m * justify < 0 ? -10 : (10 + gap * (fanout - 1)))
      end0Y = -m * width
      endToEndDeltaX = -gap
      endToEndDeltaY = 0
      endToSpineDeltaX = 0
      endToSpineDeltaY = m * (width - offs)
      spine0X = m * justify * (10 + gap * (fanout - 1) - 1)
      spine0Y = -m * offs
      spine1X = m * justify * offs
      spine1Y = -m * offs
      textAngle = 90
      textHorzAlign = m > 0 ? Self.hRight : Self.hLeft
      textVertAlign = Self.vBaseline
    } else {
      // > or <
      let m = facing == .west ? -1 : 1
      end0X = m * width
      end0Y =
        justify == 0
        ? -gap * (fanout / 2)
        : (m * justify > 0 ? 10 : -(10 + gap * (fanout - 1)))
      endToEndDeltaX = 0
      endToEndDeltaY = gap
      endToSpineDeltaX = -m * (width - offs)
      endToSpineDeltaY = 0
      spine0X = m * offs
      spine0Y = m * justify * (10 + gap * (fanout - 1) - 1)
      spine1X = m * offs
      spine1Y = m * justify * offs
      textAngle = 0
      textHorzAlign = m > 0 ? Self.hLeft : Self.hRight
      textVertAlign = (m * justify < 0) ? Self.vTop : Self.vBaseline
    }
  }
}
