// Slider.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.io.extra.Slider),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// A one-bit-to-N-bit output whose value is set by dragging an on-screen slider (the poke tool),
// not by any input port; this factory has no INPUT ports at all.
//
// ── What did not come across ─────────────────────────────────────────────────────────────────
//
//   * `RadixOption`; see `RadixOptionShim.swift`. The paint slice added `toString(Value)` and
//     `getIndexChar()` to that shim because `paintInstance` needs them; the rest of the real
//     type (`getMaxLength`, the display names, the poke-tool editor) is still missing.
//
// `paintInstance` IS ported; see the Paint section at the end of the factory. Note the poker
// hit-tests the knob against *different* geometry than the painter draws: the drawn rectangle is
// `(posX + sliderPosition + 5, posY + height - 15, 10, 10)` while `Poker.mousePressed` uses
// `(…, posY + height - 16, 12, 12)`, a deliberately larger grab area, so the knob can be caught
// just outside its own outline. The two must stay separate; if either is ever derived from the
// other the off-by-one has to survive.
//   * `ATTR_DIR`'s display name resolves through a second `LocaleManager("resources/logisim",
//     "circuit")` bundle upstream (i.e. borrows `circuit`'s "wire direction" string rather than
//     `io`'s own strings): purely a UI/localisation artifact, D9's precedent throughout.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

/// `Slider.RIGHT_TO_LEFT` / `LEFT_TO_RIGHT`: `ATTR_DIR`'s two options.
public enum SliderDirection: String, AttributeOptionValue, CaseIterable, Sendable {
  case rightToLeft = "right_to_left"
  case leftToRight = "left_to_right"
  public static var attributeOptions: [SliderDirection] { Array(allCases) }
}

/// `com.cburch.logisim.std.io.extra.Slider`.
public final class Slider: InstanceFactoryBase {

  public static let id = "Slider"

  private static let maximumBits = 8
  private static let maximumPosition = (1 << maximumBits) - 1

  public static let attrWidth: Attribute<BitWidth> = Attributes.forBitWidth(
    "width", min: 1, max: Int32(maximumBits))
  public static let attrDirection: Attribute<SliderDirection> = Attributes.forOption("Direction")

  /// `Slider.Poker`: the drag handler, and the **only** thing that can ever move this
  /// component's output: `Slider` has no input port, so without it `propagate` is frozen at the
  /// initial position forever.
  ///
  /// `dragging` is genuine per-placement transient state (Java's `private boolean dragging`),
  /// which is why `makePoker()` must return a fresh instance per placed component and the
  /// caller must keep it alive between the press and the drags; a poker recreated per event
  /// would lose the drag and the knob would never move.
  public final class Poker: InstancePoker {
    private var dragging = false

    public init() {}

    public func mousePressed(_ state: any InstanceState, _ event: PokeMouseEvent) {
      let data = state.data as? SliderValue
      // No state yet ⇒ the knob is parked at whichever end the direction attribute puts it.
      let sliderPosition =
        data?.position
        ?? (state.attributeValue(Slider.attrDirection) == .rightToLeft
          ? Slider.maximumPosition : 0)
      let bounds = state.component.bounds
      // `new Rectangle(bounds.getX() + sliderPosition + 5, bounds.getY() + bounds.getHeight() -
      // 16, 12, 12).contains(e.getX(), e.getY())`, spelled out without an AWT `Rectangle`:
      // AWT's `contains` is half-open on both axes (`x >= rx && x < rx + w`).
      let rx = bounds.x + sliderPosition + 5
      let ry = bounds.y + bounds.height - 16
      dragging = event.x >= rx && event.x < rx + 12 && event.y >= ry && event.y < ry + 12
    }

    public func mouseDragged(_ state: any InstanceState, _ event: PokeMouseEvent) {
      guard dragging else { return }
      let data: SliderValue
      if let existing = state.data as? SliderValue {
        data = existing
      } else {
        // Upstream seeds a freshly created `SliderValue` from the attributes here, and only
        // here; `propagate` does the same two calls every tick, so a slider poked before its
        // first propagation still starts in the right direction and bit width.
        data = SliderValue()
        data.setDirection(rightToLeft: state.attributeValue(Slider.attrDirection) == .rightToLeft)
        data.setCurrentBitWidth(
          state.attributeValue(Slider.attrWidth, default: BitWidth.known(Slider.maximumBits)).width)
        state.setData(data)
      }
      // The knob's own 5-pixel offset plus the body's 5-pixel margin: `setSliderPosition` clamps.
      data.setSliderPosition(event.x - state.component.bounds.x - 10)
      state.fireInvalidated()
    }

    public func mouseReleased(_ state: any InstanceState, _ event: PokeMouseEvent) {
      dragging = false
    }
  }

  public init() {
    super.init(Slider.id)
    setAttributes([
      StdAttr.facing.binding(.east),
      Slider.attrWidth.binding(BitWidth.known(Slider.maximumBits)),
      radixOptionAttribute.binding(.radix2),
      IoLibrary.attrColor.binding(ColorSpec(red: 255, green: 255, blue: 255)),
      StdAttr.label.binding(""),
      StdAttr.labelFont.binding(StdAttr.defaultLabelFont),
      StdAttr.labelVisibility.binding(true),
      Slider.attrDirection.binding(.leftToRight),
    ])
    setFacingAttribute(StdAttr.facing)
    setPorts([Port(0, 0, .output, 1)])
  }

  public override func makePoker() -> (any InstancePoker)? { Poker() }

  public override func ports(_ attributes: any AttributeSet) -> [Port] {
    let width = attributes.getValue(Slider.attrWidth) ?? BitWidth.known(Slider.maximumBits)
    return [Port(0, 0, .output, width)]
  }

  public override func offsetBounds(_ attributes: any AttributeSet) -> Bounds {
    let facing = attributes.getValue(StdAttr.facing) ?? .east
    let width = Slider.maximumPosition + 20
    let height = 30
    switch facing {
    case .east: return Bounds.create(-width, -height / 2, width, height)
    case .west: return Bounds.create(0, -height / 2, width, height)
    case .north: return Bounds.create(-width / 2, 0, width, height)
    case .south: return Bounds.create(-width / 2, -height, width, height)
    }
  }

  public override func propagate(_ state: any InstanceState) throws {
    let bitWidth = state.attributeValue(Slider.attrWidth, default: BitWidth.known(Slider.maximumBits))
    var sliderValue = 0
    if let data = state.data as? SliderValue {
      data.setDirection(rightToLeft: state.attributeValue(Slider.attrDirection, default: .leftToRight) == .rightToLeft)
      data.setCurrentBitWidth(bitWidth.width)
      sliderValue = data.currentValue
    }
    state.setPort(0, Value.createKnown(bitWidth, Int64(sliderValue)), 1)
  }

  // MARK: - Paint (D6)

  /// `paintInstance(InstancePainter)`: `Slider.java:218-253`.
  ///
  /// A rounded body in the user's colour, a track line, a DARK_GRAY knob, and the live output
  /// value centred at the top in bold 10pt with its radix letter.
  ///
  /// The knob's drawn rectangle is `(x + position + 5, y + height - 15, 10, 10)`, while
  /// `Poker.mousePressed` hit-tests `(x + position + 5, y + height - 16, 12, 12)`: a
  /// deliberately larger grab area, one pixel up and two wider. The two must not be unified;
  /// see this file's header.
  public func paintInstance(_ painter: any IoInstancePainter) {
    let g = painter.scene
    let bounds = painter.bounds
    let posX = bounds.x
    let posY = bounds.y
    let sliderPosition =
      (painter.data as? SliderValue)?.position
      ?? (painter.attributeValue(Slider.attrDirection, default: .leftToRight) == .rightToLeft
        ? Slider.maximumPosition : 0)

    // `drawRoundBounds(Color)`: fill only when the colour is non-white, then always outline.
    let bodyColor = painter.attributeValue(IoLibrary.attrColor, default: Slider.defaultColor)
    painter.drawRoundBounds(bounds, .attribute(bodyColor))

    g.strokeWidth = 2
    g.color = painter.componentColor
    g.drawLine(
      posX + 10, posY + bounds.height - 10,
      posX + bounds.width - 10, posY + bounds.height - 10)
    g.color = .darkGray
    g.fillRoundRect(posX + sliderPosition + 5, posY + bounds.height - 15, 10, 10, 4, 4)
    g.color = painter.componentColor
    g.drawRoundRect(posX + sliderPosition + 5, posY + bounds.height - 15, 10, 10, 4, 4)
    painter.drawPorts()
    painter.drawLabel()

    // `new Font(Font.SANS_SERIF, Font.BOLD, 10)`: a fresh font, not a derivation of the
    // ambient one, so it is 10pt bold regardless of what the canvas had installed.
    g.font = SceneFont(family: .sansSerif, size: 10, bold: true)
    let radix = painter.attributeValue(radixOptionAttribute, default: .radix2)
    g.drawCenteredValue(
      radix.string(for: painter.portValue(0)),
      radixIndexChar: radix.indexChar,
      x: posX + bounds.width / 2,
      y: posY + 6)
  }

  /// The attribute-template default for `IoLibrary.ATTR_COLOR`.
  static let defaultColor = ColorSpec(red: 255, green: 255, blue: 255)
}

extension Slider: IoPaintable {}

// MARK: - Label (board #78)

extension Slider: InstanceLabelProvider {

  /// `Slider.computeTextField(Instance)`: `Slider.java:174-184`, an explicit `setTextField`.
  ///
  /// The only facing-branching placement in the io family, and it branches on **`WEST` alone**
  /// rather than on an axis: a west-facing slider anchors its label on the body's *top* edge
  /// with `V_BASELINE`, every other facing on the vertical centre less one pixel with
  /// `V_CENTER_OVERALL`. `x` is `bds.x - 3` and `H_RIGHT` in both arms; the label always hangs
  /// off the left side, and `- 3` is the Java's, not the `- 2` the generic WEST arm uses.
  public func labelPlacement(_ painter: InstancePainter) -> LabelPlacement? {
    let isWestOrientated = painter.attributeValue(StdAttr.facing) == .west
    let bounds = painter.bounds
    return LabelPlacement(
      x: bounds.x - 3,
      y: isWestOrientated ? bounds.y : bounds.y + bounds.height / 2 - 1,
      halign: .right,
      valign: isWestOrientated ? .baseline : .centerOverall)
  }
}

/// `Slider.SliderValue`: the poked position, driven by `Slider.Poker` and read back by
/// `propagate`.
public final class SliderValue: InstanceData {
  private static let maximumBits = 8
  private static let maximumPosition = (1 << maximumBits) - 1

  private var bitCount = SliderValue.maximumBits
  private var sliderPosition = 0
  private var rightToLeft = false

  public init() {}

  private init(bitCount: Int, sliderPosition: Int, rightToLeft: Bool) {
    self.bitCount = bitCount
    self.sliderPosition = sliderPosition
    self.rightToLeft = rightToLeft
  }

  public func cloneData() -> any InstanceData {
    SliderValue(bitCount: bitCount, sliderPosition: sliderPosition, rightToLeft: rightToLeft)
  }

  /// `SliderValue.getCurrentValue()`.
  public var currentValue: Int {
    let complete = rightToLeft ? (SliderValue.maximumPosition - sliderPosition) : sliderPosition
    return complete >> (SliderValue.maximumBits - bitCount)
  }

  public var position: Int { sliderPosition }

  /// `SliderValue.setSliderPosition(int)`.
  public func setSliderPosition(_ value: Int) {
    sliderPosition = max(0, min(value, SliderValue.maximumPosition))
  }

  /// `SliderValue.setCurrentBitWidth(int)`.
  public func setCurrentBitWidth(_ width: Int) {
    guard width >= 0, width <= SliderValue.maximumBits, width != bitCount else { return }
    bitCount = width
  }

  /// `SliderValue.setDirection(boolean)`.
  public func setDirection(rightToLeft value: Bool) {
    guard value != rightToLeft else { return }
    rightToLeft = value
    sliderPosition = SliderValue.maximumPosition - sliderPosition
  }
}
