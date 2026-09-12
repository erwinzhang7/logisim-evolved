// IoPainter.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.instance.InstancePainter and the parts of
// com.cburch.logisim.comp.ComponentDrawContext an io component actually calls),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ══ WHY THIS FILE EXISTS, AND WHAT THE INTEGRATOR SHOULD DO WITH IT ═════════════════════════
//
// D6 says a component emits primitives into a `SceneBuilder` and never touches a drawing
// context. It does **not** say how a component gets handed the *other* half of what upstream's
// `InstancePainter` supplies: the component's absolute bounds, its attribute set, its
// `InstanceData`, the port values, and the `drawLabel()` / `drawPorts()` composites that need
// the `CircuitState` to colour a pin marker by its value.
//
// At the time this slice was written no such seam existed anywhere in `LogisimStd`;
// `grep -rn "InstancePainter" swift/Sources/LogisimStd` returned only `// PAINT (M6):` prose.
// So this file declares the minimum surface the io family needs, deliberately shaped as a
// **protocol with no implementation**, so that:
//
//   * every io `paintInstance` below is written against the same contract the real painter will
//     have to satisfy, and
//   * when the shared `InstancePainter` lands (in `Instance/`, alongside `InstanceState`, which
//     is exactly where upstream puts it), making it conform to `IoInstancePainter` is a
//     one-line change and this file can be deleted wholesale.
//
// It is named `IoInstancePainter`, not `InstancePainter`, on purpose: three sibling paint
// slices were in flight against the same missing seam, and two protocols with the *same* name
// and *different* members is a hard merge, whereas two with different names is a rename.
//
// The member set is `InstancePainter`'s, minus everything no io component calls (the counts
// come from `grep -ho "painter\.\w*" std/io/*.java std/io/extra/*.java | sort | uniq -c`) and
// minus everything D9 forbids (`getGraphics`, `getDestination`, `getProject`).

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

// MARK: - IoInstancePainter

/// `com.cburch.logisim.instance.InstancePainter`, restricted to what the io family calls.
public protocol IoInstancePainter: AnyObject {

  /// The emitter every drawing call goes through (D6). Replaces `getGraphics()`.
  var scene: SceneBuilder { get }

  /// `getBounds()`: **absolute**, i.e. the offset bounds already translated by the component's
  /// location. Every io painter works in absolute coordinates, exactly as the Java does.
  var bounds: Bounds { get }

  /// `getLocation()`.
  var location: Location { get }

  /// `getAttributeSet()`.
  var attributeSet: any AttributeSet { get }

  /// `getData()`. Upstream throws `UnsupportedOperationException` when there is no circuit
  /// state; here the absence is modelled as `nil`, which every caller already has to handle
  /// because `getData()` also returns `null` before the first propagation.
  var data: (any InstanceData)? { get }

  /// `setData(InstanceData)`: `Keyboard`, `Tty` and `Video` lazily install their state from
  /// inside `paintInstance`, so this is genuinely on the paint path upstream.
  func setData(_ value: (any InstanceData)?)

  /// `getPortValue(int)`.
  func portValue(_ index: Int) -> Value

  /// `getShowState()`: false in the icon/attribute-table preview and in the appearance editor,
  /// where a component draws an inert shape rather than a simulation result.
  var showState: Bool { get }

  /// `shouldDrawColor()`, false in print view.
  var shouldDrawColor: Bool { get }

  /// `isPrintView()`.
  var isPrintView: Bool { get }

  /// `getTickCount()`.
  var tickCount: Int { get }

  // MARK: Composites that need the component or the circuit state

  /// `drawBounds()`: `ComponentDrawContext.drawBounds`: a 2px `drawRect` of `bounds`, then
  /// back to width 1.
  func drawBounds()

  /// `drawLabel()`: `InstanceComponent.drawLabel`, which draws the component's `TextField`
  /// (position, alignment and font all live on the component, not on the factory).
  func drawLabel()

  /// `drawPorts()`: `ComponentDrawContext.drawPins`: a marker per end, coloured by the value
  /// on that end when `showState`, black otherwise.
  func drawPorts()

  /// `drawPort(int)`; `ComponentDrawContext.drawPin`. Note this one uses the *component
  /// colour preference* for the not-showing-state case, where `drawPins` uses plain black.
  /// The asymmetry is upstream's; it is reproduced, not fixed.
  func drawPort(_ index: Int)

  /// `drawPort(int, String, Direction)`.
  func drawPort(_ index: Int, _ label: String, _ direction: Direction)

  /// `drawClock(int, Direction)`: `ComponentDrawContext.drawClock`'s 2px chevron at an end.
  func drawClock(_ index: Int, _ direction: Direction)

  /// `drawRoundBounds(Bounds, Color)`.
  func drawRoundBounds(_ bounds: Bounds, _ color: SceneColor?)

  // MARK: Preferences the painters read

  /// `new Color(AppPreferences.COMPONENT_COLOR.get())`. A preference, so it is supplied by the
  /// UI rather than baked in; the default matches `DEFAULT_COMPONENT_COLOR = 0x00000000`, which
  /// `new Color(int)` renders as **opaque** black because it ignores the alpha byte.
  var componentColor: SceneColor { get }

  /// `new Color(AppPreferences.COMPONENT_SECONDARY_COLOR.get())`:
  /// `DEFAULT_COMPONENT_SECONDARY_COLOR = 0x99999999`, again opaque, so `#999999`.
  var componentSecondaryColor: SceneColor { get }
}

extension IoInstancePainter {

  public var componentColor: SceneColor { .rgb(0x00_0000) }
  public var componentSecondaryColor: SceneColor { .rgb(0x99_9999) }

  /// `getAttributeValue(Attribute<E>)`.
  public func attributeValue<V>(_ attribute: Attribute<V>) -> V? {
    attributeSet.getValue(attribute)
  }

  /// `getAttributeValue` for attributes the factory's template guarantees. Java would NPE or
  /// silently unbox `null`; the explicit fallback keeps that decision at the call site.
  public func attributeValue<V>(_ attribute: Attribute<V>, default fallback: @autoclosure () -> V)
    -> V
  {
    attributeSet.getValue(attribute) ?? fallback()
  }

  /// `getData()` narrowed to the one-field holder most io components use.
  public var singletonData: InstanceDataSingleton? { data as? InstanceDataSingleton }

  /// `GraphicsUtil.switchToWidth(g, w)`, bracketed.
  public func withWidth(_ width: Int, _ body: () -> Void) {
    scene.withStrokeWidth(width, body)
  }
}

// MARK: - IoPaintable

/// What a factory implements so the eventual chassis can dispatch `paintInstance` /
/// `paintGhost` without a giant `switch`. Upstream these are two overridable methods on
/// `InstanceFactory`; here they are a separate protocol purely so this slice did not have to
/// edit `InstanceFactory.swift`, which it did not own.
///
/// **It refines `InstancePaintable`, and that refinement is the whole join.** `CircuitRenderer`
/// dispatches on `component.factory as? any InstancePaintable`; conforming to `IoPaintable`
/// alone made every io factory miss that cast, so all twenty drew nothing. The extension below
/// supplies both `InstancePaintable` witnesses by forwarding, so an io component still writes
/// one `paintInstance(any IoInstancePainter)` and the renderer still sees one protocol.
public protocol IoPaintable: InstancePaintable {
  /// `paintInstance(InstancePainter)`.
  func paintInstance(_ painter: any IoInstancePainter)
  /// `paintGhost(InstancePainter)`. The default is upstream's: a factory that does not override
  /// it draws nothing (the canvas draws the offset-bounds rectangle itself).
  func paintGhost(_ painter: any IoInstancePainter)
}

extension IoPaintable {
  public func paintGhost(_ painter: any IoInstancePainter) {}

  /// `InstancePaintable.paintInstance` → the io overload.
  ///
  /// The two overloads are told apart by the argument's *static* type: `InstancePainter` is a
  /// concrete class and `any IoInstancePainter` is an existential, and neither converts to the
  /// other, so the explicit `as` below can only resolve to the protocol requirement. That is
  /// what makes this a forward rather than infinite recursion, and there is no default for
  /// the io overload, so a conformer that forgot to write one fails to compile.
  public func paintInstance(_ painter: InstancePainter) {
    paintInstance(painter as any IoInstancePainter)
  }

  /// `InstancePaintable.paintGhost` → the io overload.
  ///
  /// More specialized than `InstancePaintable`'s own empty default, so it wins the witness for
  /// any `IoPaintable`; a factory with no io ghost still ends up at the empty default above,
  /// which is upstream's behaviour (`InstanceFactory.paintGhost` draws nothing).
  public func paintGhost(_ painter: InstancePainter) {
    paintGhost(painter as any IoInstancePainter)
  }
}

// MARK: - The painter half of the join

/// `InstancePainter` **is** the painter the io family was written against.
///
/// This is the other half of seam #9, and it is a retroactive conformance rather than a change
/// to `InstancePainter` itself for two reasons: `InstancePainter` is a shared file three other
/// slices also land in, and every requirement below except `scene` was already satisfied
/// member-for-member. The io protocol was drafted against upstream's `InstancePainter` surface
/// and the concrete one was ported from the same class, so the two lined up without either
/// having to move, which is what the file header of `IoPainter.swift` predicted ("a one-line
/// change") and is the reason no adapter object is needed.
///
/// Requirements and where each is met:
///
/// | `IoInstancePainter` | `InstancePainter` |
/// |---|---|
/// | `scene` | `g`, renamed below, the only member that was missing |
/// | `bounds` `location` `attributeSet` `data` `setData` `portValue` | already present |
/// | `showState` `shouldDrawColor` `isPrintView` `tickCount` | already present |
/// | `drawBounds` `drawLabel` `drawPorts` `drawPort` ×2 `drawClock` `drawRoundBounds` | already present |
/// | `componentColor` | already present, and reads `PaintContext.componentColor` |
/// | `componentSecondaryColor` | the protocol extension's `#999999`, see below |
///
/// `componentSecondaryColor` is deliberately left on the protocol default instead of being
/// added to `PaintContext`. `PaintContext` is implemented outside this module (`LogisimUI`'s
/// canvas context), so adding a requirement to it would break a file this slice does not own,
/// for a preference the UI does not yet expose. It is a **NOT-PORTED** point, narrowly: the
/// value is upstream's factory default `DEFAULT_COMPONENT_SECONDARY_COLOR = 0x99999999`, and it
/// stops tracking the user's preference the moment `AppPreferences` grows one. Whoever wires
/// that preference should add it to `PaintContext` and drop this note.
extension InstancePainter: IoInstancePainter {

  /// The D6 emitter. `InstancePainter` calls it `g` so that ported call sites read like the
  /// Java they came from; the io protocol calls it `scene` because it was written after that
  /// convention was dropped. Same object: identity, not a copy, which matters because the
  /// renderer rasterises the builder it walked with and geometry emitted into any other one
  /// would silently vanish.
  public var scene: SceneBuilder { g }
}

// MARK: - Colour and font bridging

extension SceneColor {
  /// A user-chosen attribute colour (`Attributes.forColor`, e.g. an LED's on/off colour) as a
  /// scene colour.
  ///
  /// These are **not** `ValuePalette` entries and must not be: D9 forbids the kernel from
  /// knowing about colours *for simulation values*, whose colours are a render-time theme. An
  /// LED's on-colour is the opposite kind of thing, it is data the user typed into the
  /// attribute table and that round-trips through the `.circ` verbatim, so it is carried as a
  /// literal `RGBA` and interned by the builder.
  public static func attribute(_ spec: ColorSpec) -> SceneColor {
    .rgba(RGBA(r: spec.red, g: spec.green, b: spec.blue, a: spec.alpha))
  }

  /// `java.awt.Color.DARK_GRAY`, `(64, 64, 64)`, the inert colour several io components fall
  /// back to when `getShowState()` is false.
  public static let darkGray = SceneColor.rgb(0x40_4040)

  /// `java.awt.Color.GRAY`, `(128, 128, 128)`.
  public static let gray = SceneColor.rgb(0x80_8080)

  /// `java.awt.Color.LIGHT_GRAY`, `(192, 192, 192)`.
  public static let lightGray = SceneColor.rgb(0xC0_C0C0)

  /// `java.awt.Color.RED`.
  public static let red = SceneColor.rgb(0xFF_0000)

  /// `java.awt.Color.YELLOW`.
  public static let yellow = SceneColor.rgb(0xFF_FF00)

  /// `java.awt.Color.BLUE`.
  public static let blue = SceneColor.rgb(0x00_00FF)

  /// `java.awt.Color.GREEN`.
  public static let green = SceneColor.rgb(0x00_FF00)

  /// `java.awt.Color.MAGENTA`.
  public static let magenta = SceneColor.rgb(0xFF_00FF)

  /// `java.awt.Color.CYAN`.
  public static let cyan = SceneColor.rgb(0x00_FFFF)

  /// `java.awt.Color.ORANGE`, `(255, 200, 0)`, which is **not** `#FFA500`.
  public static let orange = SceneColor.rgb(0xFF_C800)

  /// `java.awt.Color.PINK`, `(255, 175, 175)`.
  public static let pink = SceneColor.rgb(0xFF_AFAF)
}

extension ColorSpec {

  /// `java.awt.Color.darker()`: every channel times `FACTOR = 0.7`, **truncated** to an int,
  /// floored at 0, and the result is opaque (`new Color(int, int, int)` drops the alpha).
  ///
  /// `Button` and `Switch` both draw their bevel with this, so the exact rounding is visible:
  /// `(int)(255 * 0.7)` is 178, not 179.
  public var darker: ColorSpec {
    func scale(_ c: UInt8) -> UInt8 { UInt8(max(Int(Double(c) * 0.7), 0)) }
    return ColorSpec(red: scale(red), green: scale(green), blue: scale(blue))
  }

  /// `java.awt.Color.brighter()`.
  ///
  /// Not the inverse of `darker()`: it divides by `FACTOR`, and it has a special case so that a
  /// pure black brightens to `(3, 3, 3)` rather than staying black. `Switch` relies on it.
  public var brighter: ColorSpec {
    var r = Int(red)
    var g = Int(green)
    var b = Int(blue)
    let i = Int(1.0 / (1.0 - 0.7))  // == 3
    if r == 0 && g == 0 && b == 0 {
      return ColorSpec(red: UInt8(i), green: UInt8(i), blue: UInt8(i), alpha: alpha)
    }
    if r > 0 && r < i { r = i }
    if g > 0 && g < i { g = i }
    if b > 0 && b < i { b = i }
    return ColorSpec(
      red: UInt8(min(Int(Double(r) / 0.7), 255)),
      green: UInt8(min(Int(Double(g) / 0.7), 255)),
      blue: UInt8(min(Int(Double(b) / 0.7), 255)),
      alpha: alpha)
  }

  /// The print-view greyscale several io components fall back to when `shouldDrawColor()` is
  /// false: `hue = (r + g + b) / 3` with Java's integer division, then `new Color(hue, hue, hue)`.
  public var printGrey: ColorSpec {
    let hue = UInt8((Int(red) + Int(green) + Int(blue)) / 3)
    return ColorSpec(red: hue, green: hue, blue: hue)
  }
}

extension SceneFont {
  /// A `FontSpec` attribute (`Attributes.forFont`) as a scene font.
  ///
  /// Java's logical family names map onto `SceneFont.Family`'s three cases; anything else is
  /// carried through as `.named`, which is what `SansSerif`-vs-`Monospaced` fidelity needs
  /// (`Tty` is `Monospaced` and its whole layout is derived from the character advance).
  public static func attribute(_ spec: FontSpec) -> SceneFont {
    let family: Family
    switch spec.family {
    case "SansSerif", "Dialog": family = .sansSerif
    case "Serif": family = .serif
    case "Monospaced": family = .monospaced
    default: family = .named(spec.family)
    }
    return SceneFont(
      family: family,
      size: Double(spec.size),
      bold: spec.style.contains(.bold),
      italic: spec.style.contains(.italic))
  }
}

// MARK: - Text measurement

extension SceneBuilder {

  /// `FontMetrics.stringWidth(String)` in the current font.
  ///
  /// `SceneBuilder` deliberately exposes no raw measurer (measurement is meant to happen once,
  /// inside `drawText`), but three io components genuinely need a bare advance width before
  /// they can decide *where* to draw: `Tty` positions its cursor bar after the typed prefix of
  /// a row and centres its own description string, `PlaRom` centres a caption, and
  /// `DigitalOscilloscope` right-aligns its axis labels. Java reaches
  /// `g.getFontMetrics().stringWidth(s)` at all three sites.
  ///
  /// Derived from `textBoundsInUserSpace` rather than from a second measurer call so it cannot
  /// disagree with what the emitters compute: at `halign == .left` the box's width *is* the
  /// advance width.
  public func measuredWidth(of text: String) -> Int {
    guard !text.isEmpty else { return 0 }
    return textBoundsInUserSpace(text, x: 0, y: 0, halign: .left, valign: .baseline).width
  }

  /// `GraphicsUtil.drawCenteredValue(Graphics2D, Value, RadixOption, int, int)`:
  /// `GraphicsUtil.java:89-104`.
  ///
  /// A value centred on `(x, y)` with a small blue radix letter tucked to its lower right, drawn
  /// under a 0.7 scale. Two things about that scale are load-bearing:
  ///
  ///   * the metrics used to place the letter are the **unscaled** ones. Java scales the
  ///     `Graphics2D` but keeps measuring with the `FontMetrics` it fetched beforehand, so the
  ///     letter's position is computed in unscaled space and then divided by 0.7 to compensate.
  ///     Re-measuring after the scale would move it.
  ///   * both divisions are `(int)` casts, i.e. truncation toward zero, not rounding.
  ///
  /// Lives on the builder rather than in one component because `Slider` draws its output this
  /// way and `Probe`/`Pin` in the wiring family do the same; a second copy would be a second
  /// place for the truncation to drift.
  public func drawCenteredValue(
    _ valueString: String, radixIndexChar: String, x: Int, y: Int,
    radixColor: SceneColor = .blue
  ) {
    let metrics = fontMetrics()
    let valueWidth = measuredWidth(of: valueString)
    let valueHeight = metrics.height
    drawString(valueString, x: x - valueWidth / 2, y: y + valueHeight / 2)

    let radixHeight = radixIndexChar.isEmpty ? 0 : metrics.height
    let radixX = Double(x) + Double(valueWidth) / 2 + 1
    let radixY = Double(y) + Double(valueHeight) - Double(radixHeight) / 3
    withColor(radixColor) {
      withTransform(.scale(0.7, 0.7)) {
        drawString(
          radixIndexChar,
          x: Int(radixX / 0.7),
          y: Int(radixY / 0.7))
      }
    }
  }
}

// MARK: - Java arithmetic helpers used by the io painters

/// `Math.round(float)`: `floor(x + 0.5)`, which is **not** Swift's `.rounded()`: the two
/// disagree on exact negative halves (`Math.round(-2.5f) == -2`, `(-2.5).rounded() == -3`).
/// `DigitalOscilloscope` and `Slider` both round negative intermediates, so this matters.
@inlinable
public func javaRound(_ value: Float) -> Int {
  Int((value + 0.5).rounded(.down))
}

/// `Math.round(double)`, same rule.
@inlinable
public func javaRound(_ value: Double) -> Int {
  Int((value + 0.5).rounded(.down))
}
