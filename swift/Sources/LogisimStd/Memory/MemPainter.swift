// MemPainter.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.instance.InstancePainter,
// com.cburch.logisim.comp.ComponentDrawContext, com.cburch.logisim.util.{GraphicsUtil,
// StringUtil}), https://github.com/logisim-evolution/logisim-evolution. Copyright by the
// Logisim-evolution developers. This translation is a derivative work and is therefore
// GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ══ WHY THIS FILE EXISTS, AND WHAT IT NOW JOINS ═════════════════════════════════════════════
//
// D6 says a component paints by emitting primitives into a `RenderScene` through `SceneBuilder`.
// It does not supply the other half: upstream's `InstancePainter`, the object that pairs the
// emitter with "which component, in which circuit state, is being drawn right now" and carries
// the `drawBounds`/`drawPort`/`drawClock`/`drawLabel` conveniences every `paintInstance` port
// call. When this slice was written `Instance/` was owned by a different slice, so it could not
// declare that type; it declared `MemPainter` instead: a narrow, memory-family-scoped protocol
// naming exactly the members this family's paint code reads, each spelled the same as the
// `InstancePainter` method it stands for (`getBounds()` → `bounds`, `getShowState()` →
// `showState`, `drawPort(int, String, Direction)` → `drawPort(_:_:_:)`, …).
//
// ── SEAM #10, and how it was closed ─────────────────────────────────────────────────────────
//
// That protocol then sat with **no conformer at all** while every memory factory drew against
// it, and no memory factory conformed to `InstancePaintable`, which is what
// `CircuitRenderer.render` actually casts to (`component.factory as? any InstancePaintable`,
// `CircuitRenderer.swift:108`). Both halves were legal Swift, an unconformed protocol is not a
// diagnostic, so the build was clean, every test passed, and all eleven memory components drew
// nothing. Measured, not inferred: a circuit of all eleven rendered 0 painted and 0 primitives.
//
// Both halves are below, under `MemPaintable` and `extension InstancePainter: MemPainter`, with
// the reasoning for each at its own declaration. `MemPaintSeamTests` is the gate; it renders
// through the real `CircuitRenderer` and asserts primitive counts, because "it compiles" and
// "the call returned" both look like success for this defect class.
//
// The paint entry points in this directory are plain methods rather than `override`s: there is
// no `InstanceFactoryBase.paintInstance` to override, and `MemPaintable` deliberately routes
// them instead, so a factory that forgets to write one fails to compile.
//
// ── What else lives here ────────────────────────────────────────────────────────────────────
//
//   * `MemPaint`: the family's shared drawing constants and helpers: the `AppPreferences`
//     component colours, the `java.awt.Color` constants upstream names directly, and ports of
//     `StringUtil.toHexString(int, long)` and `Graphics.getFontMetrics().stringWidth(String)`.
//   * `MemPaintStrings`: the five `S.get(...)` strings the memory family's classic appearances
//     draw. D5's precedent (localisation lives above the model, `Attribute` keeps its raw name)
//     applies: these are the English `std.properties` values, hardcoded, so the drawing is
//     complete and the localisation seam is a later, separable change.
//
// ── D9 ──────────────────────────────────────────────────────────────────────────────────────
//
// No AppKit/SwiftUI/CoreGraphics. `SceneColor` is `LogisimRender`'s palette-facing colour value
// (an interned index, not a platform colour), which Package.swift explicitly makes LogisimStd
// depend on for exactly this purpose. Simulation-value colours go through
// `Value.paletteIndex`/`ValuePalette`, never a literal RGB.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

// MARK: - The paint context

/// `com.cburch.logisim.instance.InstancePainter`, narrowed to what the memory family draws with.
/// See this file's header: a seam, not a chassis.
public protocol MemPainter: AnyObject {

  /// `getGraphics()`.
  var graphics: SceneBuilder { get }

  /// `getAttributeSet()`.
  var attributeSet: any AttributeSet { get }

  /// `getFactory()`. `RamAppearance`'s size caption branches on `inst.getFactory() instanceof Ram`.
  var factory: (any InstanceFactory)? { get }

  /// `getData()`. Upstream throws when there is no circuit state and returns `null` when the
  /// component has no data yet; both collapse to `nil` here, and every memory painter already
  /// has an explicit `state == null` branch for the second case (a component drawn in the
  /// toolbar, or before the first tick).
  var data: (any InstanceData)? { get }

  /// `getBounds()`.
  var bounds: Bounds { get }

  /// `getLocation()`.
  var location: Location { get }

  /// `getInstance().getPortLocation(int)`, where port `index` sits, in circuit coordinates.
  ///
  /// **Optional, and that is the D13 answer, not a convenience.** Upstream is
  /// `comp.getEnd(index).getLocation()` (`Instance.java:82`) on a painter whose `comp` may be
  /// null: an out-of-range index raises `IndexOutOfBoundsException` and a ghost painter raises
  /// `NullPointerException`. Both are catchable `RuntimeException`s, so D13 forbids a Swift trap
  /// , and a `throws` here is no good either, because `InstancePaintable.paintInstance` cannot
  /// throw and the forwarding shim would have to swallow the error, which is exactly what D13
  /// exists to prevent. `nil` is the third option and the one the rest of this module already
  /// uses: the concrete `InstancePainter.portLocation` was written to return `Location?` and its
  /// own `drawClock`/`drawPort` guard-and-return on it.
  ///
  /// Every call site in this family is `guard let loc = … else { return }`, i.e. it abandons the
  /// rest of *that component's* drawing rather than skipping one stub. That is what Java's
  /// exception does, it unwinds out of `paintInstance` to the EDT, and it matters here because
  /// `RamAppearance.drawControlBlock` numbers its dependency labels with a running `cidx`, so a
  /// `continue` would renumber every later label instead of stopping.
  ///
  /// In practice it is never `nil` on the live path: no memory factory overrides `paintGhost`
  /// upstream (`grep -l paintGhost std/memory/*.java` in 4.1.0 is empty), so the memory painters
  /// only ever run with a placed component, and every index they pass is computed by this
  /// module's own port-index functions from the same attribute set the ports were built from.
  func portLocation(_ index: Int) -> Location?

  /// `getShowState()`: false in the toolbar, in a print/export view, and whenever the canvas is
  /// drawing a component that is not part of a running circuit.
  var showState: Bool { get }

  /// `isPrintView()`.
  var isPrintView: Bool { get }

  // ── Pen-width contract ────────────────────────────────────────────────────────────────────
  //
  // `drawBounds`, `drawClock` and `drawClockSymbol` are `switchToWidth(g, 2); …;
  // switchToWidth(g, 1);` in `ComponentDrawContext`: they leave the pen at **width 1**, and
  // upstream painters rely on it: `RamAppearance.drawConnections` draws its line-enable and
  // byte-enable stubs after the clock loop with no `setStroke` of its own, so they come out
  // thinner than the OE/WE stubs above them.
  //
  // Note `SceneBuilder`'s same-named helpers use `withStrokeWidth`, which **restores** the
  // previous width instead of forcing 1. An implementation of this protocol that forwards
  // straight to them therefore breaks the contract. The two sites in this family where that is
  // observable restate the reset themselves, so both behaviours draw the same thing, but a
  // conforming painter should still leave the pen at 1.
  //
  // The one conformer, `InstancePainter`, does: all three of its methods end with an explicit
  // `g.strokeWidth = 1` rather than relying on the builder's restore. That was checked when the
  // seam was closed and is asserted at runtime by `MemPaintSeamTests.penWidthContract`, so a
  // later edit to `InstancePainter` that "simplified" the reset away would fail a test instead
  // of quietly thinning two stubs in `RamAppearance`.

  /// `drawBounds()`. Leaves the pen at width 1: see the contract note above.
  func drawBounds()

  /// `drawLabel()`.
  func drawLabel()

  /// `drawPort(int)`.
  func drawPort(_ index: Int)

  /// `drawPort(int, String, Direction)`.
  func drawPort(_ index: Int, _ label: String, _ direction: Direction)

  /// `drawPorts()`.
  func drawPorts()

  /// `drawClock(int, Direction)`. Leaves the pen at width 1: see the contract note above.
  func drawClock(_ index: Int, _ direction: Direction)

  /// `drawClockSymbol(int, int)`. Leaves the pen at width 1: see the contract note above.
  func drawClockSymbol(_ x: Int, _ y: Int)
}

extension MemPainter {
  /// `getAttributeValue(Attribute<E>)`.
  public func attributeValue<V>(_ attribute: Attribute<V>) -> V? {
    attributeSet.getValue(attribute)
  }

  /// `getAttributeValue` with the caller-stated fallback for an attribute its own factory
  /// guarantees. Upstream would NPE or silently unbox `null`; several memory painters already
  /// write `widthVal == null ? 8 : widthVal.getWidth()` themselves, which is this.
  public func attributeValue<V>(_ attribute: Attribute<V>, default fallback: @autoclosure () -> V)
    -> V
  {
    attributeSet.getValue(attribute) ?? fallback()
  }
}

// MARK: - MemPaintable — the factory half of the join

/// What a memory factory implements so `CircuitRenderer` can draw it.
///
/// **The `: InstancePaintable` refinement is the whole join, not decoration.**
/// `CircuitRenderer.render` dispatches on `component.factory as? any InstancePaintable`
/// (`CircuitRenderer.swift:108`). A factory that conformed only to a family-scoped protocol
/// would miss that cast and draw nothing, with no diagnostic, which is exactly the mistake the
/// io slice made and caught before landing (see `IoPaintable`'s doc comment). Refining it means
/// a memory factory still writes one `paintInstance(_ painter: any MemPainter)` and the renderer
/// still sees exactly one protocol.
///
/// There is deliberately **no** `paintGhost` here. No memory factory overrides `paintGhost`
/// upstream, `grep -l paintGhost src/main/java/com/cburch/logisim/std/memory/*.java` on the
/// 4.1.0 tree returns nothing, so the inherited `InstancePaintable.paintGhost` no-op is the
/// faithful behaviour, and the canvas falls back to `AbstractComponentFactory.drawGhost`'s plain
/// offset-bounds rectangle. Forwarding the ghost to `paintInstance` would be *worse* than
/// nothing: a ghost painter has no component, so `data`, `portValue` and every `portLocation`
/// are absent, and the memory bodies would draw a live-state shape for a component with no
/// state.
public protocol MemPaintable: InstancePaintable {
  /// `paintInstance(InstancePainter)`, against this family's narrowed painter surface.
  func paintInstance(_ painter: any MemPainter)
}

extension MemPaintable {

  /// `InstancePaintable.paintInstance` → the memory overload.
  ///
  /// The two overloads are told apart by the argument's *static* type: `InstancePainter` is a
  /// concrete class and `any MemPainter` is an existential, and neither converts implicitly to
  /// the other, so the explicit `as` below can only resolve to the protocol requirement. That
  /// is what makes this a forward rather than infinite recursion, and because there is no
  /// default for the memory overload, a conformer that forgot to write one fails to compile
  /// instead of silently drawing nothing.
  public func paintInstance(_ painter: InstancePainter) {
    paintInstance(painter as any MemPainter)
  }
}

// MARK: - The painter half of the join

/// `InstancePainter` **is** the painter the memory family was written against.
///
/// This file's header promised "integration is one line"; it is two, and this is them. It is a
/// retroactive conformance in a file this slice owns rather than an edit to
/// `Instance/InstancePainter.swift`, which several slices land in concurrently; the same choice
/// the io slice made, for the same reason.
///
/// Requirements and where each is met:
///
/// | `MemPainter` | `InstancePainter` |
/// |---|---|
/// | `graphics` | `g`, renamed below; one of the two members that did not line up |
/// | `portLocation(_:)` | already present, and already `Location?`: see the second shim |
/// | `attributeSet` `factory` `data` `bounds` `location` | already present, member for member |
/// | `showState` `isPrintView` | already present |
/// | `drawBounds` `drawLabel` `drawPort` ×2 `drawPorts` `drawClock` `drawClockSymbol` | already present |
///
/// **The pen-width contract holds without a shim, and that was checked rather than assumed.**
/// This protocol's header records that upstream's `ComponentDrawContext.drawBounds`,
/// `drawClock` and `drawClockSymbol` end on `switchToWidth(g, 1)` and leave the pen at 1,
/// whereas `SceneBuilder`'s same-named helpers *restore* the previous width, so a bridge that
/// forwarded straight to the builder would break `RamAppearance.drawConnections`, whose
/// line-enable and byte-enable stubs are drawn after the clock loop with no stroke of their own.
/// `InstancePainter` does not forward straight through: all three of its methods end with an
/// explicit `g.strokeWidth = 1` (`InstancePainter.swift`, `drawBounds` / `drawClock` /
/// `drawClockSymbol`). `MemPaintSeamTests.penWidthContract` asserts it at runtime so a later
/// edit to `InstancePainter` cannot quietly drop it.
extension InstancePainter: MemPainter {

  /// The D6 emitter. `InstancePainter` calls it `g` so that ported call sites read like the Java
  /// they came from (`getGraphics()`); this family calls it `graphics`. Same object: identity,
  /// not a copy, which matters because the renderer rasterises the builder it walked with, and
  /// geometry emitted into any other one would silently vanish.
  public var graphics: SceneBuilder { g }
}

// MARK: - The eleven factories

// Conformances rather than a `: MemPaintable` on each class declaration, so that the whole seam
// , protocol, forward, painter bridge and conformer list, is readable in one place, and so a
// factory that stops satisfying it fails here rather than 400 lines into its own file.
//
// `AbstractFlipFlop` covers `DFlipFlop`, `TFlipFlop`, `JKFlipFlop` and `SRFlipFlop`: its
// `paintInstance` is `open`, so the witness is vtable-dispatched and a subclass override would
// be honoured. None of the four overrides it, exactly as upstream (`AbstractFlipFlop.java:271`
// is the only `paintInstance` among the five).
//
// `Mem` itself is **not** listed. It is upstream's abstract base (`Mem.java` declares no
// `paintInstance`) and is never placed on a canvas; `Ram`, `Rom` and `DualRam` are its three
// concrete subclasses and each carries its own.

extension AbstractFlipFlop: MemPaintable {}
extension Register: MemPaintable {}
extension Counter: MemPaintable {}
extension ShiftRegister: MemPaintable {}
extension Random: MemPaintable {}
extension Ram: MemPaintable {}
extension Rom: MemPaintable {}
extension DualRam: MemPaintable {}

// MARK: - Shared drawing constants and helpers

/// The memory family's drawing constants: upstream's `AppPreferences` component colours, the
/// `java.awt.Color` constants its painters name directly, and two `StringUtil`/`FontMetrics`
/// helpers every hex readout in this directory needs.
public enum MemPaint {

  // ── Colours ───────────────────────────────────────────────────────────────────────────────
  //
  // `AppPreferences.COMPONENT_COLOR` / `COMPONENT_SECONDARY_COLOR` are preference-backed. As
  // `Register.swift`'s and `AbstractFlipFlop.swift`'s headers already record for
  // `Memory_Startup_Unknown`/`getDefaultAppearance()`, this port hardcodes the compiled defaults
  // rather than reaching into a preferences store from the kernel-side module (D9).
  // `AppPreferences.java:577-578`: `0x00000000` and `0x99999999`. Both go through
  // `new Color(int)`, which **ignores the alpha byte**, so the secondary colour is opaque grey
  // `#999999`, not 60%-alpha grey. `RGBA(javaRGB:)` reproduces exactly that.

  /// `new Color(AppPreferences.COMPONENT_COLOR.get())`, the default component ink.
  public static let componentColor = SceneColor.rgb(0x00_0000)

  /// `new Color(AppPreferences.COMPONENT_SECONDARY_COLOR.get())`, control-pin labels.
  public static let componentSecondaryColor = SceneColor.rgb(0x99_9999)

  /// `java.awt.Color.LIGHT_GRAY`, `(192, 192, 192)`.
  public static let lightGray = SceneColor.rgb(0xC0_C0C0)
  /// `java.awt.Color.DARK_GRAY`, `(64, 64, 64)`.
  public static let darkGray = SceneColor.rgb(0x40_4040)
  /// `java.awt.Color.RED`.
  public static let red = SceneColor.rgb(0xFF_0000)
  /// `java.awt.Color.BLUE`.
  public static let blue = SceneColor.rgb(0x00_00FF)
  /// `java.awt.Color.YELLOW`.
  public static let yellow = SceneColor.rgb(0xFF_FF00)
  /// `java.awt.Color.WHITE`.
  public static let white = SceneColor.white
  /// `java.awt.Color.BLACK`.
  public static let black = SceneColor.black

  /// `Value.multiColor`: the multi-bit bus colour. A palette slot, not a literal: D9 keeps the
  /// simulation palette re-themable at render time.
  public static let multiColor = SceneColor.palette(.multi)

  /// `value.getColor()`: the flip-flop state bubble's fill.
  public static func color(of value: Value) -> SceneColor {
    .palette(value.paletteIndex)
  }

  /// `ColorSpec` (a `StdAttr.LABEL_COLOR` value) as a scene colour.
  public static func color(of spec: ColorSpec) -> SceneColor {
    .rgba(RGBA(r: spec.red, g: spec.green, b: spec.blue, a: spec.alpha))
  }

  // ── Stroke widths (`GraphicsUtil`) ────────────────────────────────────────────────────────

  /// `GraphicsUtil.CONTROL_WIDTH`.
  public static let controlWidth = 2
  /// `GraphicsUtil.NEGATED_WIDTH`.
  public static let negatedWidth = 2
  /// `GraphicsUtil.DATA_SINGLE_WIDTH`.
  public static let dataSingleWidth = 3
  /// `GraphicsUtil.DATA_MULTI_WIDTH`.
  public static let dataMultiWidth = 4

  // ── Text ──────────────────────────────────────────────────────────────────────────────────

  /// `StringUtil.toHexString(int bits, long value)`.
  ///
  /// Java masks to `bits` (for `bits < 64`), formats `%0<len>x` where `len = (bits + 3) / 4`, and
  /// then truncates from the *left* if the formatted string somehow came out longer. `%x` on a
  /// `long` is unsigned, which is why the value is reinterpreted through `UInt64` rather than
  /// printed as a signed `Int64`: at `bits == 64` a negative value must print as its unsigned
  /// 64-bit form, exactly as Java does.
  public static func hexString(bits: Int, value: Int64) -> String {
    var v = value
    if bits < 64 {
      // `1L << bits`: Java masks the shift distance by 63, and `bits` here is always `1...63`
      // on this branch, so a plain shift is faithful.
      v &= (Int64(1) << Int64(bits)) &- 1
    }
    let len = (bits + 3) / 4
    var digits = String(UInt64(bitPattern: v), radix: 16)
    if digits.count < len {
      digits = String(repeating: "0", count: len - digits.count) + digits
    } else if digits.count > len {
      digits = String(digits.suffix(len))
    }
    return digits
  }

  /// `Long.toHexString(long)`: unsigned 64-bit hex, lowercase, no leading zeros (`0` prints as
  /// `"0"`). `Counter`'s "CTR DIV0x…" and "3CT=0x…" captions use this, not the zero-padded
  /// `StringUtil.toHexString` above.
  public static func longHexString(_ value: Int64) -> String {
    String(UInt64(bitPattern: value), radix: 16)
  }

  /// `FontMetrics.stringWidth(String)` for the builder's current font.
  ///
  /// `textBoundsInUserSpace` measures with the same `TextMeasurer` the emitters use, and its box
  /// width *is* the advance width. User space, not scene space, is deliberate: this is a pure
  /// measurement that is never added to a translated coordinate, so the baked translation must
  /// not be applied. (A width is translation-invariant either way, the two frames differ by a
  /// constant that cancels, but measuring in the frame the callers work in keeps that from
  /// being something a reader has to prove.)
  ///
  /// **Integration note.** `SceneBuilder` gained `measuredWidth(of:)` on the integration branch
  /// after this slice was cut, which is this function with the same body. Once merged, this can
  /// collapse to `g.measuredWidth(of: text)`; the two are identical, since `measuredWidth` is
  /// `textBox(text, x: 0, y: 0, …).width` and `textBoundsInUserSpace` returns that same box.
  public static func stringWidth(_ g: SceneBuilder, _ text: String) -> Int {
    guard !text.isEmpty else { return 0 }
    return g.textBoundsInUserSpace(text, x: 0, y: 0, halign: .left, valign: .baseline).width
  }

  /// `Graphics.getFont().deriveFont(float)`: same family and style, new point size.
  public static func derive(_ font: SceneFont, size: Double) -> SceneFont {
    font.withSize(size)
  }

  /// Runs `body` with the builder's font temporarily replaced: the
  /// `final var font = g.getFont(); g.setFont(...); …; g.setFont(font);` idiom, which appears in
  /// every memory painter that draws a smaller caption.
  public static func withFont(_ g: SceneBuilder, _ font: SceneFont, _ body: () -> Void) {
    let saved = g.font
    g.font = font
    body()
    g.font = saved
  }

  /// `final var g = (Graphics2D) painter.getGraphics().create(); … ; g.dispose();`
  ///
  /// `RamAppearance`/`DualRamAppearance` lean on that clone: they set a 4-wide stroke, derive a
  /// 7pt or 9pt font and switch colour freely, and rely on `dispose()` to throw all of it away
  /// rather than restoring anything. `SceneBuilder` is a single shared emitter (D6: no
  /// per-component context clone, which is one of the things that makes it faster than the
  /// Java), so the clone's *observable* effect; graphics state does not escape the block; is
  /// reproduced by saving and restoring it here.
  public static func withGraphicsCopy(_ g: SceneBuilder, _ body: () -> Void) {
    let font = g.font
    let pen = g.pen
    let color = g.color
    body()
    g.font = font
    g.pen = pen
    g.color = color
  }

  /// `StdAttr.LABEL_FONT`'s `FontSpec` as a `SceneFont`.
  public static func sceneFont(_ spec: FontSpec) -> SceneFont {
    SceneFont(
      family: .named(spec.family),
      size: Double(spec.size),
      bold: spec.style.contains(.bold),
      italic: spec.style.contains(.italic))
  }
}

/// The `S.get(...)` strings the memory family's classic appearances draw, at their English
/// `std.properties` values. See this file's header on why they are hardcoded.
public enum MemPaintStrings {
  /// `registerLabel`.
  public static let registerLabel = "reg"
  /// `counterLabel`.
  public static let counterLabel = "ctr"
  /// `randomLabel`.
  public static let randomLabel = "random"
  /// `memEnableLabel`.
  public static let memEnableLabel = "en"
  /// `counterEnableLabel`.
  public static let counterEnableLabel = "ct"
  /// `shiftRegisterLabel1`.
  public static let shiftRegisterLabel1 = "shift reg"

  /// `registerWidthLabel`, `"(%sb)"`.
  public static func registerWidthLabel(_ width: Int) -> String { "(\(width)b)" }
  /// `randomWidthLabel`, `"Width: %d"`.
  public static func randomWidthLabel(_ width: Int) -> String { "Width: \(width)" }
  /// `shiftRegisterLabel2`, `"%sx%s"`.
  public static func shiftRegisterLabel2(_ length: Int, _ width: Int) -> String {
    "\(length)x\(width)"
  }
}
