// AbstractFlipFlop.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.memory.AbstractFlipFlop),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── The family base ─────────────────────────────────────────────────────────────────────────
//
// Upstream's `AbstractFlipFlop` carries the clock-edge/set-reset logic every flip-flop shares;
// `DFlipFlop`/`TFlipFlop`/`JKFlipFlop`/`SRFlipFlop` each contribute only `computeValue` (the
// next-state function) and `getInputName`. That split is kept exactly: this file owns `ports`,
// `offsetBounds` and `propagate`; the four concrete files each override two small methods.
//
// `Register`, `ShiftRegister` and `RandomGenerator` (this same slice) embed the `ClockState`
// struct already ported in `Memory/ClockState.swift` (a different, concurrently-landing slice);
// this file does not redefine it, it just uses it.
//
// ── Preferences not wired ───────────────────────────────────────────────────────────────────
//
// Upstream reads `AppPreferences.Memory_Startup_Unknown` (default **false**, per
// `AppPreferences.java`'s `PrefMonitorBoolean("MemStartUnknown", false)`) to decide whether a
// flip-flop/register/shift-register/random-generator starts at `Value.UNKNOWN` or its "zero"
// value, and `AppPreferences.getDefaultAppearance()` (default `StdAttr.APPEAR_EVOLUTION`, per
// `PrefMonitorStringOpts("defaultAppearance", …, StdAttr.APPEAR_EVOLUTION.toString())`) to pick
// the initial `StdAttr.APPEARANCE`. D9 forbids this module from reaching into a preferences
// store, and no such store exists yet in the port, so every constructor below hardcodes Java's
// *compiled* default (`false` / `StdAttr.appearEvolution`) instead; the same approach
// `Value.swift`'s `DisplayCharacters.default` already takes for the display-character prefs.
// Whoever wires a real preferences layer into `LogisimStd` should thread it through here rather
// than deleting the hardcoded defaults outright.
//
// ── Not ported ──────────────────────────────────────────────────────────────────────────────
//
//   * `Logger` (inner class): the Log/Chronogram value source; UI, parity backlog. `Poker` *is*
//     ported (below): it is what makes all four of D/T/JK/SR pokable, and both of upstream's
//     constructors call `setInstancePoker(Poker.class)`, so it belongs to every subclass.
//   * `getHDLName`, `checkForGatedClocks`, `clockPinIndex`; HDL/FPGA backlog (D11); their inner
//     HDL generator classes are stripped per this port's brief.
//   * `instanceAttributeChanged`; upstream's only branch (`APPEARANCE` changed) recomputes
//     bounds and ports, both of which `StdInstanceComponent` now does automatically for any
//     attribute change (`PATTERNS.md` §0). Nothing else happens there, so it is not overridden.
//   * (nothing further.)
//
// ── PAINTING (M6) ───────────────────────────────────────────────────────────────────────────
//
// `paintInstance`, `paintInstanceClassic` and `paintInstanceEvolution` are ported at the bottom
// of the class (`AbstractFlipFlop.java:270-380`). See `MemPainter.swift` for the paint seam.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

/// `com.cburch.logisim.std.memory.AbstractFlipFlop`.
open class AbstractFlipFlop: InstanceFactoryBase {

  /// `AbstractFlipFlop.STD_PORTS`: clock, Q, notQ, clear, preset.
  private static let stdPortCount = 5

  /// `MemoryLibrary.DELAY`. Upstream's flip-flops are the one part of this slice that use the
  /// library-wide delay rather than declaring their own (`Register`/`Counter` each declare a
  /// private `DELAY = 8`; `ShiftRegister`/`Random` use bare literals).
  private static let propagationDelay = 5

  private let numInputs: Int
  private let triggerAttribute: Attribute<AttributeOption>

  /// `AbstractFlipFlop.Poker`. Shared by all four concrete flip-flops (upstream registers it in
  /// both constructors), and the only way to set a flip-flop's state by hand: without it, a
  /// D/T/JK/SR flip-flop can only ever be driven through its clock.
  ///
  /// Three ways in, all upstream's: click the state dot to invert it, type `0`/`1`, or press the
  /// down/up arrows to force low/high.
  public final class Poker: InstancePoker {
    /// Java initialises this to `true`, not `false`: so a poker that receives a
    /// `mouseReleased` it never saw the press for still toggles, provided the release is inside
    /// the dot. Preserved.
    private var isPressed = true

    public init() {}

    /// The hit target is a radius-8 circle around the state dot, at a different offset from the
    /// component's location in each of the two appearances.
    ///
    /// `wrap32` is not decoration here: Java computes `dx * dx + dy * dy` in `int`. A press
    /// inside the dot followed by a release tens of thousands of grid units away (the poke tool
    /// forwards the release to the component that took the press) overflows that product to a
    /// negative `int`, which passes `d2 < 8 * 8` and toggles the flip-flop from far off screen.
    /// Swift's 64-bit `Int` would not overflow and would quietly not toggle.
    private func isInside(_ state: any InstanceState, _ event: PokeMouseEvent) -> Bool {
      let loc = state.component.location
      let dx: Int
      let dy: Int
      if state.attributeValue(StdAttr.appearance) == StdAttr.appearClassic {
        dx = wrap32(event.x - (loc.x - 20))
        dy = wrap32(event.y - (loc.y + 10))
      } else {
        dx = wrap32(event.x - (loc.x + 20))
        dy = wrap32(event.y - (loc.y + 30))
      }
      let d2 = wrap32(wrap32(dx &* dx) &+ wrap32(dy &* dy))
      return d2 < 8 * 8
    }

    public func mousePressed(_ state: any InstanceState, _ event: PokeMouseEvent) {
      isPressed = isInside(state, event)
    }

    public func mouseReleased(_ state: any InstanceState, _ event: PokeMouseEvent) {
      if isPressed && isInside(state, event) {
        // No state yet means the component has never propagated; upstream declines to create
        // one here (unlike `RegisterPoker`), so the click is simply lost.
        if let myState = state.data as? FlipFlopState {
          myState.curValue = myState.curValue.not()
          state.fireInvalidated()
        }
      }
      isPressed = false
    }

    public func keyTyped(_ state: any InstanceState, _ event: inout PokeKeyEvent) {
      guard let val = javaHexDigit(event.keyChar) else { return }
      guard let myState = state.data as? FlipFlopState else { return }
      // Only `0` and `1` do anything; `2`…`f` are read as digits and then ignored.
      if val == 0 && myState.curValue != .falseValue {
        myState.curValue = .falseValue
        state.fireInvalidated()
      } else if val == 1 && myState.curValue != .trueValue {
        myState.curValue = .trueValue
        state.fireInvalidated()
      }
    }

    public func keyPressed(_ state: any InstanceState, _ event: inout PokeKeyEvent) {
      guard let myState = state.data as? FlipFlopState else { return }
      if event.keyCode == MemoryAwtKeyCode.down && myState.curValue != .falseValue {
        myState.curValue = .falseValue
        state.fireInvalidated()
      } else if event.keyCode == MemoryAwtKeyCode.up && myState.curValue != .trueValue {
        myState.curValue = .trueValue
        state.fireInvalidated()
      }
    }
  }

  /// `AbstractFlipFlop(String, Icon/String, StringGetter, int, boolean, HdlGeneratorFactory)`.
  /// Both Java overloads (icon-name vs. `Icon` object) collapse into one initialiser; icons are
  /// drawing (D6/D9) and neither is ported.
  public init(_ name: String, numInputs: Int, allowLevelTriggers: Bool) {
    self.numInputs = numInputs
    self.triggerAttribute = allowLevelTriggers ? StdAttr.trigger : StdAttr.edgeTrigger
    super.init(name)
    setAttributes([
      triggerAttribute.binding(StdAttr.triggerRising),
      StdAttr.label.binding(""),
      StdAttr.labelFont.binding(StdAttr.defaultLabelFont),
      StdAttr.appearance.binding(StdAttr.appearEvolution),
    ])
  }

  /// Both upstream constructors call `setInstancePoker(Poker.class)`, so this is inherited by
  /// `DFlipFlop`, `TFlipFlop`, `JKFlipFlop` and `SRFlipFlop` alike: none of them overrides it.
  open override func makePoker() -> (any InstancePoker)? { Poker() }

  // MARK: Ports — `updatePorts(Instance)`, transcribed as a pure function (PATTERNS.md §0)

  open override func ports(_ attributes: any AttributeSet) -> [Port] {
    let classic = attributes.getValue(StdAttr.appearance) == StdAttr.appearClassic
    var ps = [Port](repeating: Port(0, 0, .input, 1), count: numInputs + AbstractFlipFlop.stdPortCount)

    if classic {
      switch numInputs {
      case 1:
        ps[0] = Port(-40, 20, .input, 1)
        ps[1] = Port(-40, 0, .input, 1)
      case 2:
        ps[0] = Port(-40, 0, .input, 1)
        ps[1] = Port(-40, 20, .input, 1)
        ps[2] = Port(-40, 10, .input, 1)
      default:
        // `throw new RuntimeException("flip-flop input > 2")`; unreachable: `numInputs` is a
        // compile-time constant fixed by the four concrete subclasses below (1 or 2), never by
        // anything a `.circ` file supplies. D13's "genuine programmer error" carve-out.
        fatalError("\(name): flip-flop input > 2")
      }
      ps[numInputs + 1] = Port(0, 0, .output, 1)
      ps[numInputs + 2] = Port(0, 20, .output, 1)
      ps[numInputs + 3] = Port(-10, 30, .input, 1)
      ps[numInputs + 4] = Port(-30, 30, .input, 1)
    } else {
      switch numInputs {
      case 1:
        ps[0] = Port(-10, 10, .input, 1)
        ps[1] = Port(-10, 50, .input, 1)
      case 2:
        ps[0] = Port(-10, 10, .input, 1)
        ps[1] = Port(-10, 30, .input, 1)
        ps[2] = Port(-10, 50, .input, 1)
      default:
        fatalError("\(name): flip-flop input > 2")
      }
      ps[numInputs + 1] = Port(50, 10, .output, 1)
      ps[numInputs + 2] = Port(50, 50, .output, 1)
      ps[numInputs + 3] = Port(20, 60, .input, 1)
      ps[numInputs + 4] = Port(20, 0, .input, 1)
    }
    return ps
  }

  // MARK: Bounds — `getOffsetBounds(AttributeSet)`

  open override func offsetBounds(_ attributes: any AttributeSet) -> Bounds {
    attributes.getValue(StdAttr.appearance) == StdAttr.appearClassic
      ? Bounds.create(-40, -10, 40, 40)
      : Bounds.create(-10, 0, 60, 60)
  }

  // MARK: Abstract hooks — `computeValue`, `getInputName`

  /// `AbstractFlipFlop.computeValue(Value[], Value)`: `protected abstract` in Java, so the
  /// compiler makes it uncallable; no `.circ` file can reach this trap (D13).
  open func computeValue(_ inputs: [Value], _ curValue: Value) -> Value {
    fatalError("\(name): AbstractFlipFlop subclasses must override `computeValue`")
  }

  /// `AbstractFlipFlop.getInputName(int)`.
  open func getInputName(_ index: Int) -> String {
    fatalError("\(name): AbstractFlipFlop subclasses must override `getInputName`")
  }

  // MARK: Propagation

  public override func propagate(_ state: any InstanceState) throws {
    let data: FlipFlopState
    if let existing = state.data as? FlipFlopState {
      data = existing
    } else {
      data = FlipFlopState()
      state.setData(data)
    }

    let n = numInputs
    let triggerType = state.attributeValue(triggerAttribute)
    let triggered = data.clock.updateClock(state.portValue(n), trigger: triggerType)

    if state.portValue(n + 3) == .trueValue {
      // clear requested
      data.curValue = .falseValue
    } else if state.portValue(n + 4) == .trueValue {
      // preset requested
      data.curValue = .trueValue
    } else if triggered {
      var inputs = [Value](repeating: .falseValue, count: n)
      for i in 0..<n { inputs[i] = state.portValue(i) }
      let newVal = computeValue(inputs, data.curValue)
      // Structural `==` reproduces Java's `==` here: both operands are always one of the four
      // width-1 singletons, which Java interns and this port compares structurally instead
      // (PATTERNS.md "Equality"; see also decisions.md D15).
      if newVal == .trueValue || newVal == .falseValue {
        data.curValue = newVal
      }
    }

    state.setPort(n + 1, data.curValue, AbstractFlipFlop.propagationDelay)
    state.setPort(n + 2, data.curValue.not(), AbstractFlipFlop.propagationDelay)
  }

  // MARK: - Painting (M6)

  /// `AbstractFlipFlop.paintInstance(InstancePainter)` (`AbstractFlipFlop.java:262-268`).
  open func paintInstance(_ painter: any MemPainter) {
    if painter.attributeValue(StdAttr.appearance) == StdAttr.appearClassic {
      paintInstanceClassic(painter)
    } else {
      paintInstanceEvolution(painter)
    }
  }

  /// `AbstractFlipFlop.paintInstanceClassic(InstancePainter)` (`AbstractFlipFlop.java:270-300`).
  ///
  /// The state bubble is only drawn when there *is* state: `painter.getShowState()` is false in
  /// the toolbar and in a print view, and `getData()` is null before the first propagation, so a
  /// freshly placed flip-flop draws its body and ports and nothing else. Reproduced exactly;
  /// this is the "drawn outside a running circuit" case.
  func paintInstanceClassic(_ painter: any MemPainter) {
    let g = painter.graphics
    g.color = MemPaint.componentColor
    painter.drawBounds()
    painter.drawLabel()
    if painter.showState, let myState = painter.data as? FlipFlopState {
      let loc = painter.location
      let x = loc.x
      let y = loc.y
      g.color = MemPaint.color(of: myState.curValue)
      g.fillOval(x - 26, y + 4, 13, 13)
      g.color = MemPaint.white
      g.drawCenteredText(myState.curValue.toDisplayString(), x: x - 20, y: y + 9)
      g.color = MemPaint.componentColor
    }

    let n = numInputs
    g.color = MemPaint.componentSecondaryColor
    painter.drawPort(n + 3, "0", .south)
    painter.drawPort(n + 4, "1", .south)
    g.color = MemPaint.componentColor
    for i in 0..<n {
      painter.drawPort(i, getInputName(i), .east)
    }
    painter.drawClock(n, .east)
    painter.drawPort(n + 1, "Q", .west)
    painter.drawPort(n + 2)
  }

  /// `AbstractFlipFlop.paintInstanceEvolution(InstancePainter)` (`AbstractFlipFlop.java:302-370`).
  ///
  /// The clock triangle is the edge-trigger convention users read at a glance, so its geometry is
  /// copied rather than approximated: `drawClockSymbol(x, y + 50)`, the three-point polyline
  /// `(x+1, y+46) (x+8, y+50) (x+1, y+54)` at pen width 2, plus the level-vs-edge distinction
  /// carried by the input stub beside it (a straight line for RISING/HIGH, a 10x10 negation
  /// circle for FALLING/LOW), and an "E" glyph instead of the triangle for the two level
  /// triggers.
  func paintInstanceEvolution(_ painter: any MemPainter) {
    let g = painter.graphics
    painter.drawLabel()
    let loc = painter.location
    let x = loc.x
    let y = loc.y

    g.color = MemPaint.componentColor
    g.strokeWidth = 2
    g.drawRect(x, y, 40, 60)

    if painter.showState, let myState = painter.data as? FlipFlopState {
      g.color = MemPaint.color(of: myState.curValue)
      g.fillOval(x + 13, y + 23, 14, 14)
      g.color = MemPaint.white
      g.drawCenteredText(myState.curValue.toDisplayString(), x: x + 20, y: y + 28)
      g.color = MemPaint.componentColor
    }

    let n = numInputs
    g.color = MemPaint.componentSecondaryColor
    painter.drawPort(n + 3, "R", .south)
    painter.drawPort(n + 4, "S", .north)
    g.color = MemPaint.componentColor

    for i in 0..<n {
      g.strokeWidth = MemPaint.dataSingleWidth
      g.drawLine(x - 10, y + 10 + i * 20, x - 1, y + 10 + i * 20)
      painter.drawPort(i)
      g.drawCenteredText(getInputName(i), x: x + 8, y: y + 8 + i * 20)
    }

    let trigger = painter.attributeValue(triggerAttribute)
    if trigger == StdAttr.triggerRising || trigger == StdAttr.triggerFalling {
      painter.drawClockSymbol(x, y + 50)
    } else {
      g.drawCenteredText("E", x: x + 8, y: y + 48)
    }

    if trigger == StdAttr.triggerRising || trigger == StdAttr.triggerHigh {
      g.strokeWidth = MemPaint.controlWidth
      g.drawLine(x - 10, y + 50, x - 1, y + 50)
    } else {
      g.strokeWidth = MemPaint.negatedWidth
      g.drawOval(x - 10, y + 45, 10, 10)
    }
    painter.drawPort(n)

    g.strokeWidth = MemPaint.dataSingleWidth
    g.drawLine(x + 41, y + 10, x + 50, y + 10)
    g.drawCenteredText("Q", x: x + 31, y: y + 8)
    painter.drawPort(n + 1)
    g.strokeWidth = MemPaint.negatedWidth
    g.drawOval(x + 40, y + 45, 10, 10)
    painter.drawPort(n + 2)

    g.strokeWidth = 1
  }

  // MARK: - Label placement

  /// `instance.setTextField(StdAttr.LABEL, StdAttr.LABEL_FONT, bds.getX() + bds.getWidth() / 2,
  /// bds.getY() - 3, GraphicsUtil.H_CENTER, GraphicsUtil.V_BASELINE)`; AbstractFlipFlop.java:233.
  ///
  /// `configureNewInstance` is in upstream's "concrete methods not intended to be overridden"
  /// block (AbstractFlipFlop.java:225-240) and none of `DFlipFlop`, `TFlipFlop`, `JKFlipFlop` or
  /// `SRFlipFlop` overrides it, so all four inherit this, as they do here.
  ///
  /// Same non-recompute divergence as `Random`: `instanceAttributeChanged`
  /// (AbstractFlipFlop.java:432-437) resizes on `APPEARANCE` without reinstalling the field.
  public func labelPlacement(_ painter: InstancePainter) -> LabelPlacement? {
    let bds = painter.bounds
    return LabelPlacement(
      x: bds.x + bds.width / 2, y: bds.y - 3, halign: .center, valign: .baseline)
  }
}

extension AbstractFlipFlop: InstanceLabelProvider {}

/// `AbstractFlipFlop.StateData`: Java: `extends ClockState implements InstanceData`.
///
/// **Deviation (mechanism).** Composition (`clock: ClockState`) replaces inheritance, matching
/// `ClockState.swift`'s own header note. Nothing outside this class observes the field's type
/// or identity, so the substitution is exact.
private final class FlipFlopState: InstanceData {
  var clock = ClockState()
  // `AppPreferences.Memory_Startup_Unknown` defaults to `false`, see this file's header.
  var curValue: Value = .falseValue

  func cloneData() -> any InstanceData {
    let copy = FlipFlopState()
    copy.clock = clock
    copy.curValue = curValue
    return copy
  }
}
