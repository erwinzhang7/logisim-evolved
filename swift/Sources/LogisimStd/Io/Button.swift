// Button.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.io.Button),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── ASSUMED CHASSIS ADDITION #1: poke input, not yet in Instance/ ──────────────────────────
//
// `InstanceFactory.swift`'s header lists `setInstancePoker`/`getInstancePoker` under "Not
// ported ... when pokers land they will be closures or protocol witnesses, decided at M6". This
// file (and every other file in this slice except Buzzer) is poke-driven, its whole reason to
// exist is user interaction, not propagation, so the model-level poke logic is written now,
// against the seam this port will need, rather than waiting on M6's tool-dispatch design. Per
// the workflow's file-ownership rule, this is reported rather than added to `Instance/`:
//
//   public struct PokeMouseEvent {          // AppKit-free stand-in for `java.awt.event.MouseEvent`
//     public let x: Int
//     public let y: Int
//   }
//   public struct PokeKeyEvent {            // AppKit-free stand-in for `java.awt.event.KeyEvent`
//     public var keyCode: Int32?            // `getKeyCode()`: an AWT `VK_*` constant
//     public var keyChar: UInt16?           // `getKeyChar()`; `nil` == `CHAR_UNDEFINED`
//     public var consumed: Bool = false     // `consume()`
//   }
//   public protocol InstancePoker: AnyObject {
//     func mousePressed(_ state: any InstanceState, _ event: PokeMouseEvent)
//     func mouseReleased(_ state: any InstanceState, _ event: PokeMouseEvent)
//     func mouseDragged(_ state: any InstanceState, _ event: PokeMouseEvent)
//     func keyPressed(_ state: any InstanceState, _ event: inout PokeKeyEvent)
//     func keyTyped(_ state: any InstanceState, _ event: inout PokeKeyEvent)
//   }
//   extension InstancePoker { /* all five default to no-ops, as Java's abstract class does */ }
//
// Threaded through `InstanceFactory` the same way `instanceAttributeChanged` already is: a
// protocol requirement with a `nil`-returning extension default, plus a matching
// `open func makePoker() -> (any InstancePoker)? { nil }` on `InstanceFactoryBase` so a subclass
// can `override` it:
//
//   extension InstanceFactory { func makePoker() -> (any InstancePoker)? { nil } }
//
// `makePoker()` is expected to be called once per placed `StdInstanceComponent` and the result
// cached there, mirroring Java's per-`InstanceComponent` reflective `Poker` allocation; a
// poker can hold transient per-placement state (`Slider.Poker.dragging` is the concrete case in
// this slice). The eventual M6 UI layer translates a real `NSEvent` into `PokeMouseEvent`/
// `PokeKeyEvent` at the boundary; coordinates are in the same canvas integer space Java's
// `MouseEvent.getX()/getY()` reports.
//
// Every `Poker` type in this slice is written against this seam and will not compile standalone
// until it lands. See the task's final report for the precise ask.
//
// ── `StdAttr.LABEL_LOC`: ASSUMED, and three sibling slices already agree on the shape ───────
//
// `StdAttr.swift`'s header explicitly defers `LABEL_LOC` ("nothing in this milestone needs
// it"), and Button/Switch/DipSwitch are exactly the tranche that does. This file references it
// as `StdAttr.labelLocation` / `StdAttr.LabelLocation`, as if already added to the real
// `LogisimFile/StdAttr.swift`: the same choice `SevenSegment.swift`, `HexDigit.swift`,
// `Led.swift`, `RgbLed.swift` and `DotMatrix.swift` (five sibling files, already landed in this
// tree under this same `Io/` directory, presumably a different slice) independently made for
// the identical gap:
//
//   extension StdAttr {
//     public enum LabelLocation: AttributeOptionValue, CaseIterable {
//       case center, north, south, east, west   // tokens: "center"/"north"/"south"/"east"/"west"
//     }
//     public static let labelLocation: Attribute<LabelLocation> = Attributes.forOption("labelloc")
//   }
//
// **Found inconsistency worth flagging in the final report.** A sixth sibling file,
// `Io/IoLibrary.swift`, independently solved the same gap a *third* way: a top-level
// (non-`StdAttr`-nested) `LabelLocation` enum and a top-level `stdAttrLabelLocation` constant,
// with its own header calling that a stand-in for the real `StdAttr.labelLocation` too. Five
// files assume the `StdAttr`-nested shape used here; one assumes a top-level one. Both cannot
// simultaneously compile as the *real* addition; whoever lands `StdAttr.labelLocation` should
// add it exactly as the five-file majority (and this file) expect, then either delete or
// re-point `IoLibrary.swift`'s local stand-in at it.
//
// ── ASSUMED: `LogisimStd/Io/IoLibrary.swift` (a sibling file, not owned by this slice) ──────
//
// `IoLibrary.ATTR_COLOR` is referenced as `IoLibrary.attrColor: Attribute<ColorSpec>` (Java:
// `Attributes.forColor("color", ...)`, no default binding of its own: each component supplies
// its own default value, matching upstream). Expected to be produced by whichever slice ports
// `io.IoLibrary` itself (the aggregating `Library`); this file only consumes it.
//
// ── `StdAttr.MAPINFO`, FPGA board-pin mapping, not modelled ─────────────────────────────────
//
// `StdAttr.mapInfo: Attribute<AttributeObjectBox>` exists and round-trips as an opaque live
// object that is never saved (`Attributes.forMap()`, see StdAttr.swift). Java's actual payload,
// `ComponentMapInformationContainer(1, 0, 0)`, carries per-pin board-mapping data consumed only
// by the FPGA board editor (D11-adjacent, far downstream of this milestone). Rather than port
// that container now, this file boxes a trivial placeholder object so the attribute has *some*
// live value, matching upstream's invariant that the attribute is always present. Revisit when
// the FPGA board-editor surface is ported.
//
// ── Not ported ────────────────────────────────────────────────────────────────────────────────
//
//   * `Logger` (`InstanceLogger`): the Log/Chronogram window, parity backlog.
//   * HDL generator (`AbstractSimpleIoHdlGeneratorFactory`); D11/HDL backlog. Upstream passes it
//     to the four-argument `InstanceFactory` constructor purely to register HDL support; only the
//     trailing `requiresLabel: true` has model-level effect, which is what `super.init` keeps.
//   * `setIcon`, key configurator: UI (D9), covered by `InstanceFactory.swift`'s own header.
//
// (`computeLabelTextField` was listed here as "text layout, M6" and is no longer unported: it is
// the `InstanceLabelProvider` conformance at the end of this file, board #78.)

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

/// `com.cburch.logisim.std.io.Button`.
public final class Button: InstanceFactoryBase {
  /// `Button._ID`. Do NOT change, referenced by `.circ` files.
  public static let id = "Button"

  /// `BUTTON_PRESS_ACTIVE` / `BUTTON_PRESS_PASSIVE`.
  public static let pressActive = AttributeOption(name: "active")
  public static let pressPassive = AttributeOption(name: "passive")

  /// `Button.ATTR_PRESS`.
  public static let press: Attribute<AttributeOption> = Attributes.forOption(
    "press", choices: [pressActive, pressPassive])

  /// See the file header: `ComponentMapInformationContainer(1, 0, 0)` is not modelled, only
  /// boxed so `StdAttr.mapInfo` has a live value.
  private final class MapInfoPlaceholder {}

  /// `Button.Poker`; see ASSUMED CHASSIS ADDITION #1 above. `mousePressed`/`mouseReleased`
  /// flip the button's held-down value; upstream never reads the event's coordinates.
  public final class Poker: InstancePoker {
    public init() {}

    public func mousePressed(_ state: any InstanceState, _ event: PokeMouseEvent) {
      setValue(
        state,
        state.attributeValue(Button.press) == Button.pressPassive ? .falseValue : .trueValue)
    }

    public func mouseReleased(_ state: any InstanceState, _ event: PokeMouseEvent) {
      setValue(
        state,
        state.attributeValue(Button.press) == Button.pressPassive ? .trueValue : .falseValue)
    }

    private func setValue(_ state: any InstanceState, _ value: Value) {
      if let data = state.data as? InstanceDataSingleton {
        data.value = value
      } else {
        state.setData(InstanceDataSingleton(value))
      }
      state.fireInvalidated()
    }
  }

  public init() {
    super.init(Button.id, requiresLabel: true)
    setAttributes([
      StdAttr.facing.binding(.east),
      IoLibrary.attrColor.binding(ColorSpec(red: 255, green: 255, blue: 255)),
      Button.press.binding(Button.pressActive),
      StdAttr.label.binding(""),
      StdAttr.labelLocation.binding(.west),
      StdAttr.labelFont.binding(StdAttr.defaultLabelFont),
      StdAttr.labelColor.binding(StdAttr.defaultLabelColor),
      StdAttr.labelVisibility.binding(true),
      StdAttr.mapInfo.binding(AttributeObjectBox(MapInfoPlaceholder())),
    ])
    setFacingAttribute(StdAttr.facing)
    setPorts([Port(0, 0, .output, 1)])
  }

  public override func makePoker() -> (any InstancePoker)? { Poker() }

  /// `getOffsetBounds(AttributeSet)`. Note the port does **not** move with facing; only the
  /// bounds rotate; `setPorts` above is fixed at the origin, matching upstream's own asymmetry.
  public override func offsetBounds(_ attributes: any AttributeSet) -> Bounds {
    let facing = attributes[StdAttr.facing, default: .east]
    return Bounds.create(-20, -10, 20, 20).rotate(from: .east, to: facing, xc: 0, yc: 0)
  }

  /// `instanceAttributeChanged(Instance, Attribute<?>)`.
  ///
  /// FACING and LABEL_LOC recompute automatically now (bounds/ports are pure functions of the
  /// attribute set; see `PATTERNS.md`); nothing is needed for either here.
  ///
  /// **NOT PORTED (blocked on M3).** Upstream's `ATTR_PRESS` branch reaches through
  /// `instance.getComponent().getInstanceStateImpl().getCircuitState().getInstanceState(...)` to
  /// flip the button's *currently held* value in place when the active/passive polarity is
  /// edited mid-simulation (Button.java:159-184), so an already-pressed button stays logically
  /// "pressed" under the new polarity instead of silently flipping to "released". That path
  /// requires live per-`CircuitState` component data, which does not exist before M3
  /// (`CircuitState`/`InstanceStateImpl` are referenced only in comments elsewhere in this
  /// package today). Revisit once M3 lands; until then, editing `ATTR_PRESS` while a button's
  /// value is held simply leaves the stored `Value` as-is, which reads as the opposite polarity
  /// upstream would have avoided.
  public override func instanceAttributeChanged(
    _ component: StdInstanceComponent, _ attribute: AnyAttribute
  ) {}

  /// `propagate(InstanceState)`.
  public override func propagate(_ state: any InstanceState) throws {
    let data = state.data as? InstanceDataSingleton
    let defaultValue: Value = state.attributeValue(Button.press) == Button.pressActive
      ? .falseValue : .trueValue
    let value = (data?.value as? Value) ?? defaultValue
    state.setPort(0, value, 1)
  }

  /// `Button.DEPTH`: the bevel depth, in scene units.
  static let depth = 3

  /// `Wire.WIDTH`: the pen width of an ordinary 1-bit wire, borrowed by the stub below.
  static let wireWidth = 3

  /// The attribute-template default for `IoLibrary.ATTR_COLOR`: white.
  static let defaultColor = ColorSpec(red: 255, green: 255, blue: 255)
}

// MARK: - Paint (D6)

extension Button: IoPaintable {

  /// `paintInstance(InstancePainter)`; `Button.java:186-259`.
  ///
  /// The whole component is a 3D bevel: a raised button is a hexagonal `fillPolygon` in
  /// `color.darker()` with the flat face `fillRect`ed on top of it, offset by `DEPTH` from the
  /// bottom-right; a pressed button is just the face, moved down-right by `DEPTH` so the bevel
  /// disappears. Three details are easy to lose:
  ///
  ///   * `depress`: the label, and *only* the label, shifts with the face, and only when the
  ///     label sits where the face would otherwise slide out from under it (`LABEL_CENTER`,
  ///     `NORTH`, `WEST`). The ports never shift.
  ///   * a pressed button facing NORTH or WEST draws a 10-unit wire-coloured stub from the
  ///     component's *location* (not its bounds). Upstream does this because the pressed face
  ///     retreats past the port on those two facings and would otherwise leave the connection
  ///     visually detached.
  ///   * `Value.trueColor` for that stub is a **value-palette** entry, not an attribute colour.
  public func paintInstance(_ painter: any IoInstancePainter) {
    let defaultButtonState: Value =
      painter.attributeValue(Button.press) == Button.pressActive ? .falseValue : .trueValue
    let bds = painter.bounds
    var x = bds.x
    var y = bds.y
    let w = bds.width
    let h = bds.height
    let baseColor = painter.componentColor

    let val: Value
    if painter.showState {
      val = (painter.singletonData?.value as? Value) ?? defaultButtonState
    } else {
      val = defaultButtonState
    }

    var color = painter.attributeValue(IoLibrary.attrColor, default: Button.defaultColor)
    if !painter.shouldDrawColor {
      color = color.printGrey
    }

    let g = painter.scene
    let depress: Int
    if val != defaultButtonState {
      x += Button.depth
      y += Button.depth
      let labelLoc = painter.attributeValue(StdAttr.labelLocation, default: .west)
      depress = (labelLoc == .center || labelLoc == .north || labelLoc == .west)
        ? Button.depth : 0

      let facing = painter.attributeValue(StdAttr.facing, default: .east)
      if facing == .north || facing == .west {
        let p = painter.location
        painter.withWidth(Button.wireWidth) {
          g.color = .palette(.trueValue)
          if facing == .north {
            g.drawLine(p.x, p.y, p.x, p.y + 10)
          } else {
            g.drawLine(p.x, p.y, p.x + 10, p.y)
          }
        }
      }

      g.color = .attribute(color)
      g.fillRect(x, y, w - Button.depth, h - Button.depth)
      g.color = baseColor
      g.drawRect(x, y, w - Button.depth, h - Button.depth)
    } else {
      depress = 0
      let xp = [x, x + w - Button.depth, x + w, x + w, x + Button.depth, x]
      let yp = [y, y, y + Button.depth, y + h, y + h, y + h - Button.depth]
      g.color = .attribute(color.darker)
      g.fillPolygon(xp, yp)
      g.color = .attribute(color)
      g.fillRect(x, y, w - Button.depth, h - Button.depth)
      g.color = baseColor
      g.drawRect(x, y, w - Button.depth, h - Button.depth)
      g.drawLine(x + w - Button.depth, y + h - Button.depth, x + w, y + h)
      g.drawPolygon(xp, yp)
    }

    g.withTranslate(depress, depress) {
      painter.drawLabel()
    }
    painter.drawPorts()
  }
}

// MARK: - Label (board #78)

extension Button: InstanceLabelProvider {

  /// `Instance.computeLabelTextField(Instance.AVOID_CENTER | Instance.AVOID_LEFT)`:
  /// `Button.java:149`, re-run at `:162`/`:164`.
  ///
  /// The `AVOID_CENTER` bit is the one that distinguishes this from the six plain-`AVOID_LEFT`
  /// io factories: it survives the rotation untouched (`avoid & 0x10`) and pulls a
  /// `LABEL_CENTER` label 3px up and left of the body centre, so it clears the button face.
  public func labelPlacement(_ painter: InstancePainter) -> LabelPlacement? {
    LabelPlacement.computed(painter, avoid: [.center, .left])
  }
}
