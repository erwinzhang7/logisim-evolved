// Pin.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.wiring.Pin),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ══ WHY THIS FILE IS DISPROPORTIONATELY LOAD-BEARING ════════════════════════════════════════
//
// A Pin is the *boundary* of a circuit. Its ports are what a parent subcircuit binds to, its
// `intendedValue` is what the parent reads and writes, and its bounds are what the subcircuit's
// default appearance lays out. Three separate subsystems reach into it:
//
//   * the simulator, through `propagate` and `driveInputPin`;
//   * the subcircuit machinery, through `getValue`/`getWidth`/`isInputPin`/`isClockPin`;
//   * the `.circ` codec, through `PinAttributes`'s three attribute lists and the appearance
//     default (see `ProbeAttributes.swift`'s header; that default is a gated, byte-visible
//     output, not an implementation detail).
//
// ── The behaviour model, in upstream's own words (Pin.java:1221-1249) ───────────────────────
//
// Version 4.0.0 simplified this, and the comment block at the foot of the Java file is the
// specification. Reproduced verbatim at the bottom of this file, because the four modes are not
// derivable from the code: `propagate` and `pull` are eight lines between them, and every
// subtlety (why an output pin ignores `behavior`; why tristate and simple differ only in the UI;
// why a pull pin converts X and not E) lives in that comment.
//
// ── Ports ───────────────────────────────────────────────────────────────────────────────────
//
// One port, at the component's own location, whose *direction is inverted*: an **output** pin
// declares a `Port.INPUT` (it reads the circuit and shows it), an **input** pin declares a
// `Port.OUTPUT` (it drives the circuit). Getting this backwards silently reverses every
// subcircuit boundary in the file, and it type-checks.
//
// ── D9 ──────────────────────────────────────────────────────────────────────────────────────
//
// Upstream's `Pin.java` is 1,269 lines, of which ~700 are Swing: two `JDialog` subclasses
// (`EditDecimal`, `EditFloat`) and the `Graphics2D` painters. The dialogs' *edit logic*, what
// text is acceptable and what `Value` it produces, is real model behaviour and is ported here as
// `DecimalEdit` / `FloatEdit`; their widgets are not. See "Input seams" below.
//
// ── Input seams (reported, not faked) ───────────────────────────────────────────────────────
//
//   1. `PinPoker` coordinates. `getRow`/`getColumn`/`getBit` take a raw `(x, y)` in the **same
//      coordinate space as `component.bounds`**; upstream reads `e.getX()`/`e.getY()` from the
//      `MouseEvent` the poke tool forwards and subtracts it directly from `bds.getX()`, so the
//      two are already in one space by construction.
//   2. `PinPokerHost`. Upstream's `handleBitPress` inspects `src instanceof Canvas` and, when the
//      poked pin lives in a *substate* (a subcircuit being viewed through its parent), pops an
//      OK/Cancel dialog and, on OK, clones the state as a new root and re-fetches the instance
//      state. That is three UI dependencies (`Canvas`, `OptionPane`, `Project`) in the middle of
//      an otherwise pure routine. It is expressed as a one-method protocol; passing `nil` is
//      exactly upstream's "the event did not come from a Canvas" path, which skips the prompt.
//   3. `DecimalEdit`/`FloatEdit`. `isValid(_:)` is the document listener's validity test (the
//      field turns yellow/red and the OK button enables) and `accept(_:)` is what the OK button
//      and the Return key do. The dialog itself is M6.
//   4. `LogisimFile.ProbeAttributes.defaultProbeAppearance`: the preference behind the
//      appearance default (`AppPreferences.NEW_INPUT_OUTPUT_SHAPES`). Already declared by the
//      `.circ` reader; `ProbeAttributes.swift` forwards to it rather than adding a second knob.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

/// `com.cburch.logisim.std.wiring.Pin`.
public final class Pin: InstanceFactoryBase {

  /// `Pin._ID`. Do not change, `.circ` files reference it.
  public static let id = "Pin"

  /// `setInstancePoker(PinPoker.class)` (`Pin.java:120`).
  ///
  /// **This registration is what made an input pin pokable, and it was the missing line.**
  /// `Pin.Poker` below has been complete for a long time, bit hit-testing, the toggle, the
  /// tristate normalisation, the typed-digit path, and nothing ever asked for it:
  /// `InstanceFactoryFeatures` answers `ComponentFeatureKey.pokable` with `makePoker()`, `Pin`
  /// did not override it, so `Component.pokeCaret` returned nil and clicking an input did
  /// nothing. Measured before the fix, on a real host with a live simulation behind it:
  /// `pin.pokeCaret(event)` → nil, with `circuitState` and `instanceState` both non-nil.
  ///
  /// A fresh instance every call, as the protocol requires: `Pin.Poker` carries `bitPressed` and
  /// `bitCaret` across the events of one gesture, so a shared one would leak a half-finished
  /// poke from one pin into the next.
  public override func makePoker() -> (any InstancePoker)? { PokerBridge() }

  // MARK: Attributes

  /// `Pin.INPUT`, `.circ` token `"input"`.
  public static let input = AttributeOption(name: "input")
  /// `Pin.OUTPUT`, `.circ` token `"output"`.
  public static let output = AttributeOption(name: "output")

  /// `Pin.ATTR_TYPE`: `.circ` token `"type"`. Default `INPUT` (`PinAttributes.type`).
  public static let attrType: Attribute<AttributeOption> = Attributes.forOption(
    "type", choices: [Pin.input, Pin.output])

  /// `Pin.SIMPLE`, `.circ` token `"simple"`.
  public static let simple = AttributeOption(name: "simple")
  /// `Pin.TRISTATE`, `.circ` token `"tristate"`.
  public static let tristate = AttributeOption(name: "tristate")
  /// `Pin.PULL_DOWN`, `.circ` token `"pulldown"`.
  public static let pullDown = AttributeOption(name: "pulldown")
  /// `Pin.PULL_UP`, `.circ` token `"pullup"`.
  public static let pullUp = AttributeOption(name: "pullup")

  /// `Pin.ATTR_BEHAVIOR`: `.circ` token `"behavior"`. Default `SIMPLE`.
  public static let attrBehavior: Attribute<AttributeOption> = Attributes.forOption(
    "behavior", choices: [Pin.simple, Pin.tristate, Pin.pullDown, Pin.pullUp])

  /// `Pin.ATTR_INITIAL`: `.circ` token `"initial"`, written in hex (`Attributes.forHexLong`).
  /// Default `0`.
  public static let attrInitial: Attribute<Int64> = Attributes.forHexLong("initial")

  /// `Pin.DIGIT_WIDTH`: the pixel advance of one non-binary digit. Shared with
  /// `Probe.getOffsetBounds`, so it is part of every pin's saved geometry.
  public static let digitWidth = 8

  /// Java's `public static final Pin FACTORY = new Pin()`.
  public static let factory = Pin()

  public init() {
    super.init(Pin.id)
    setFacingAttribute(StdAttr.facing)
    // NOT PORTED: `setKeyConfigurator(JoinedConfigurator.create(new BitWidthConfigurator(WIDTH),
    // new DirectionConfigurator(LABEL_LOC, ALT_DOWN_MASK)))`: attribute-table key handling, UI.
    // NOT PORTED: `setInstanceLogger(PinLogger.class)`;
    // both take a `Class<?>` and are instantiated reflectively. The *logic* of both is ported
    // below as `Pin.Logger` and `Pin.Poker`; the registration is an M6 decision
    // (`InstanceFactory.swift`'s header).
  }

  /// `factory instanceof Pin`: the port's stand-in, see `ComponentFactory.swift`.
  public override var isPin: Bool { true }

  // MARK: Attribute set

  public override func createAttributeSet() -> any AttributeSet {
    // Note what this does *not* do: unlike `Probe.createAttributeSet()`, it never writes
    // `PROBEAPPEARANCE`. So a fresh Pin attribute set holds `classic` while
    // `defaultAttributeValue` answers `NewPins`, which is what makes `<a name="appearance"
    // val="classic"/>`, and therefore the whole `<tool name="Pin">` block, appear in saved
    // files. See `ProbeAttributes.swift`'s header.
    PinAttributes()
  }

  public override func validateAttributeSet(_ attributes: any AttributeSet) throws {
    guard attributes is PinAttributes else {
      throw ComponentError.wrongAttributeSet(factory: Pin.id)
    }
  }

  /// `getDefaultAttributeValue(Attribute<?>, LogisimVersion)`.
  public override func defaultAttributeValue(
    _ attribute: AnyAttribute, version: LogisimVersion
  ) -> AttributeValue? {
    if attribute === ProbeAttributes.probeAppearance {
      return ProbeAttributes.probeAppearance.encode(ProbeAttributes.defaultProbeAppearance)
    }
    return super.defaultAttributeValue(attribute, version: version)
  }

  // MARK: Geometry and ports

  /// `getOffsetBounds(AttributeSet)`: delegated wholesale to `Probe`, with `isPin: true`, which
  /// is what turns on the width/height swap for a north- or south-facing pin in the new layout.
  public override func offsetBounds(_ attributes: any AttributeSet) -> Bounds {
    let facing = attributes[StdAttr.facing, default: .east]
    let width = attributes[StdAttr.width, default: .one]
    let newLayout =
      attributes.getValue(ProbeAttributes.probeAppearance)
      == ProbeAttributes.appearEvolutionNew
    return Probe.getOffsetBounds(
      facing, width, attributes.getValue(RadixOption.attribute), newLayout, true)
  }

  /// `configurePorts(Instance)`, as a pure function of the attributes (`PATTERNS.md` §0).
  ///
  /// **The direction is inverted on purpose.** An output pin *reads* the circuit, so it declares
  /// `Port.INPUT`; an input pin *drives* the circuit, so it declares `Port.OUTPUT`.
  ///
  /// Tool tips (`pinOutputToolTip` / `pinInputToolTip`) are dropped; `Port` carries none (D5/D9).
  public override func ports(_ attributes: any AttributeSet) -> [Port] {
    let isOutput = attributes.getValue(Pin.attrType) == Pin.output
    let endType: PortType = isOutput ? .input : .output
    return [Port(0, 0, endType, StdAttr.width)]
  }

  // MARK: Queries used by the subcircuit machinery

  /// `getValue(InstanceState)`: what the parent circuit sees on this pin.
  public static func getValue(_ state: any InstanceState) -> Value {
    Pin.getState(state).intendedValue
  }

  /// `getWidth(Instance)`.
  public static func getWidth(_ attributes: any AttributeSet) -> BitWidth {
    (attributes as? PinAttributes)?.width ?? .one
  }

  /// `isInputPin(Instance)`.
  public static func isInputPin(_ attributes: any AttributeSet) -> Bool {
    (attributes as? PinAttributes)?.type == Pin.input
  }

  /// `isClockPin(Instance)`: label-sniffing, see `PinAttributes.isClock`.
  public static func isClockPin(_ attributes: any AttributeSet) -> Bool {
    (attributes as? PinAttributes)?.isClock ?? false
  }

  /// `hasThreeStateDrivers(AttributeSet)`.
  ///
  /// Upstream's comment: "For purposes of HDL, Pin never generates floating values, regardless of
  /// attributes." Identical to the inherited default; kept because the claim is non-obvious given
  /// that a tristate pin plainly can hold `UNKNOWN`.
  public override func hasThreeStateDrivers(_ attributes: any AttributeSet) -> Bool {
    false
  }

  /// `requiresNonZeroLabel()`; a pin without a label cannot be bound by a parent subcircuit,
  /// so the label validator treats an empty one as an error.
  public override var requiresNonZeroLabel: Bool { true }

  // MARK: Propagation

  /// `propagate(InstanceState)`.
  ///
  /// Note the asymmetry, which is the whole of the input/output distinction at simulation time:
  ///
  ///   * an **output** pin only observes: it copies the port value into both `foundValue` (the
  ///     colour) and `intendedValue` (the display, and what the parent reads);
  ///   * an **input** pin observes into `foundValue` but *drives* `intendedValue` back out,
  ///     pulled, and only when it differs from what is already there. That inequality guard is
  ///     what stops an input pin from re-driving the net every tick.
  public override func propagate(_ state: any InstanceState) throws {
    guard let attrs = state.attributeSet as? PinAttributes else {
      throw ComponentError.wrongAttributeSet(factory: Pin.id)
    }

    let q = Pin.getState(state)
    let found = state.portValue(0)
    if attrs.type == Pin.output {
      q.foundValue = found  // for color
      q.intendedValue = found  // for display
    } else {
      q.foundValue = found  // for color
      let drive = try Pin.pull(attrs, q.intendedValue)
      if drive != found {
        state.setPort(0, drive, 1)
      }
    }
  }

  /// `driveInputPin(InstanceState, Value)`: how a *parent* circuit pushes a value down into a
  /// subcircuit's input pin.
  ///
  /// Upstream's own comment, kept: "don't pull here -- instead, pull when displaying and
  /// propagating". So a pull-up pin handed `UNKNOWN` by its parent stores `UNKNOWN`, and only
  /// `pull` (called from `propagate`) turns it into `TRUE`.
  public static func driveInputPin(_ state: any InstanceState, _ value: Value) {
    let myState = getState(state)
    myState.intendedValue = value
  }

  /// `pull(PinAttributes, Value)`.
  ///
  /// `Value.NIL` (width 0, "nothing connected") becomes a full-width `UNKNOWN`; note this uses
  /// `attrs.width`, the *attribute* width, not the incoming value's. `pullEachBitTowards` moves
  /// only `UNKNOWN` bits; `ERROR` bits survive a pull-up or pull-down untouched, which is what
  /// upstream's behaviour comment means by "Parent circuit can send 0, 1, or E".
  static func pull(_ attrs: PinAttributes, _ value: Value) throws -> Value {
    if value == .nilValue {
      return Value.createUnknown(attrs.width)
    } else if attrs.behavior == Pin.pullUp {
      return try value.pullEachBitTowards(.trueValue)
    } else if attrs.behavior == Pin.pullDown {
      return try value.pullEachBitTowards(.falseValue)
    } else {
      return value
    }
  }

  // MARK: Per-state data

  /// `Pin.PinState`.
  final class PinState: InstanceData {
    /// The value received from the wire attached to this pin. Drives the *colour* only.
    var foundValue: Value = .nilValue
    /// What is displayed, and what a parent subcircuit reads. For an output pin this is the
    /// received value; for an input pin it is whatever the UI or the parent last set.
    var intendedValue: Value = .nilValue

    init() {}

    func cloneData() -> any InstanceData {
      let copy = PinState()
      copy.foundValue = foundValue
      copy.intendedValue = intendedValue
      return copy
    }
  }

  /// `Pin.getState(InstanceState)`: fetch-or-create, plus the two width-repair steps.
  ///
  /// The initial value differs by behaviour: a tristate pin starts `UNKNOWN`, everything else
  /// starts at `ATTR_INITIAL` (which is `0` unless the file says otherwise). Note the tristate
  /// branch is chosen even for an *output* pin whose behaviour attribute is not in its attribute
  /// list; the field still holds whatever it was last set to, and `getValue` still reads it.
  ///
  /// The two repairs are asymmetric on purpose: `intendedValue` widens with
  /// `attrs.defaultBitValue()` (0, or 1 under pull-up), `foundValue` widens with `UNKNOWN`.
  static func getState(_ state: any InstanceState) -> PinState {
    // A non-`PinAttributes` set cannot reach here through `createComponent`
    // (`validateAttributeSet` rejects it), so the fallback is a defined-value degradation
    // rather than a throw; this is called from non-throwing paths (`getValue`, the poker).
    let attrs = (state.attributeSet as? PinAttributes) ?? PinAttributes()
    let width = attrs.width
    var ret = state.data as? PinState
    if ret == nil {
      let initialValue = attrs.initialValue
      let newValue =
        attrs.behavior == Pin.tristate
        ? Value.createUnknown(width)
        : Value.createKnown(width.width, initialValue)
      let fresh = PinState()
      fresh.foundValue = newValue
      fresh.intendedValue = newValue
      state.setData(fresh)
      ret = fresh
    }
    let result = ret!
    if result.intendedValue.getWidth() != width.width {
      result.intendedValue = result.intendedValue.extendWidth(
        width.width, attrs.defaultBitValue)
    }
    if result.foundValue.getWidth() != width.width {
      result.foundValue = result.foundValue.extendWidth(width.width, .unknownValue)
    }
    return result
  }

  // MARK: Label placement

  /// `Pin.pinLabelLoc(Direction)`; the label sits on the side the pin points *away* from.
  ///
  /// Pure geometry, so it is ported even though its only callers (`configureNewInstance` and
  /// `instanceAttributeChanged`) are label-layout, which is M6.
  ///
  /// Note the fall-through: `NORTH` maps to `SOUTH` and *everything else* (i.e. `SOUTH`) maps to
  /// `NORTH`. The Swift `switch` is exhaustive over the four cases, so the `else` disappears.
  public static func pinLabelLoc(_ pinDir: Direction) -> Direction {
    switch pinDir {
    case .east: return .west
    case .west: return .east
    case .north: return .south
    case .south: return .north
    }
  }

  // MARK: Logger

  /// `Pin.PinLogger`: the value-log window's view of a pin. See `Probe.Logger` for why this is
  /// an enum of functions rather than a class.
  public enum Logger {
    /// `getLogName(InstanceState, Object)`.
    ///
    /// Falls back to a type word plus the component's location when the pin has no label.
    /// Upstream localises the type word (`S.get("pinInputName")` / `S.get("pinOutputName")`);
    /// D5's precedent keeps the model unlocalised, so the English resource values are used
    /// directly and the localisation belongs to whatever M6 owns the log window.
    public static func logName(_ state: any InstanceState) -> String {
      guard let attrs = state.attributeSet as? PinAttributes else { return "" }
      let ret = attrs.label
      if ret.isEmpty {
        let type = attrs.type == Pin.input ? "Input" : "Output"
        return type + String(describing: state.component.location)
      }
      return ret
    }

    /// `getBitWidth(InstanceState, Object)`: `StdAttr.WIDTH`, unlike `Probe`'s.
    public static func bitWidth(_ state: any InstanceState) -> BitWidth {
      state.attributeValue(StdAttr.width, default: .one)
    }

    /// `getLogValue(InstanceState, Object)`: the *intended* value, i.e. what is displayed, not
    /// what the wire carries.
    public static func logValue(_ state: any InstanceState) -> Value {
      Pin.getState(state).intendedValue
    }

    /// `isInput(InstanceState, Object)`.
    public static func isInput(_ state: any InstanceState) -> Bool {
      (state.attributeSet as? PinAttributes)?.type == Pin.input
    }
  }

  // ══ Upstream's behaviour specification, verbatim (Pin.java:1221-1249) ══════════════════════
  //
  // Version 4.0.0: Simplified new behavior:
  //   Output pin [behavior option hidden, has no effect]
  //      Depending on value of connected bus, UI displays 0, 1, E, or X, and
  //      subcircuit passes whatever is displayed up to parent. Color matches
  //      both the connected bus and the value passed up to parent. This is the
  //      simplest option, and it is the only option for output pins.
  //   Input pin in simple mode: [Behavior=simple]
  //      User can choose 0 or 1. Parent circuit can send 0, 1, E, or X. UI
  //      displays whatever user chose (or parent sent). Sends whatever is
  //      displayed to connected bus. Color matches whatever appears on
  //      connected bus (which may be different from what is displayed). Note:
  //      This mode never generates floating values, it only passes them along
  //      from a parent circuit.
  //   Input pin in tristate mode: [Behavior=tristate]
  //      Same circuit behavior as simple, but different UI behavior.
  //      User can choose 0, 1, or X. Parent circuit can send 0, 1, E, or X. UI
  //      displays whatever user chose (or parent sent). Sends whatever is
  //      displayed to connected bus. Color matches whatever appears on
  //      connected bus (which may be different from what is displayed). Note:
  //      This mode can generate X values from the UI, but for purposes of
  //      HDL-generation, this mode never generates floating values, it only
  //      passes them along from a parent circuit.
  //   Input pin with pull-up (or pull-down): [Behavior=pullup/pulldown]
  //      Same UI behavior as simple, but different circuit behavior.
  //      User can choose 0 or 1. Parent circuit can send 0, 1, or E, but if it
  //      tries to send X it gets converted to and displayed as 1 (or 0). Sends
  //      whatever is displayed to connected bus. Color matches whatever appears
  //      on connected bus. [or we could show blue in case of pull, or half
  //      blue]

  // NOT PORTED: `isHDLSupportedComponent(AttributeSet)`; HDL generation is stripped.
  // NOT PORTED: `configureNewInstance`; its three statements are `addAttributeListener`
  //             (chassis), `((PrefMonitorBooleanConvert) NEW_INPUT_OUTPUT_SHAPES)
  //             .addConvertListener(attrs)` (the preference subscription; see
  //             `ProbeAttributes.applyAppearancePreference` and the report's seam list), and
  //             `computeLabelTextField(AVOID_LEFT, pinLabelLoc(facing))` (M6 label layout).
  // NOT PORTED: `instanceAttributeChanged`; ATTR_TYPE re-ran `configurePorts`, which the
  //             chassis now recomputes-and-diffs; WIDTH/FACING/RADIX/PROBEAPPEARANCE re-ran
  //             `recomputeBounds` (automatic) plus label layout (M6); ATTR_BEHAVIOR called
  //             `fireInvalidated`, a repaint request (M6). Nothing is left. See `PATTERNS.md` §0.

  // NOT PORTED: `paintIcon`; the toolbar icon (see `Gates/AbstractGate.swift`'s header).
  // PAINT (M7): `PinPoker.paint` draws the edit caret: a red rectangle (new appearance) or a
  //             6px underline (classic) under the digit at `bitCaret`. It belongs with the
  //             poker, which is the editing-tool slice, not with the component's own drawing.
  //             See Pin.java:607-660.

  // MARK: Painting (Pin.java:835-1197)

  /// `Pin.DEFAULT_FONT`: `new Font("monospaced", Font.PLAIN, 12)`. Shared with `Probe`.
  public static let defaultFont = SceneFont(family: .monospaced, size: 12)

  /// `Instance.computeLabelTextField(AVOID_LEFT, pinLabelLoc(facing))`; Pin.java:750-751.
  ///
  /// The second argument is the interesting one: a pin overrides the `LABEL_LOC` attribute with
  /// `pinLabelLoc(facing)`, so its label always sits on the side the pin points away from,
  /// whatever the attribute says.
  public func labelPlacement(_ painter: InstancePainter) -> LabelPlacement? {
    let facing = painter.attributeValue(StdAttr.facing, default: .east)
    let loc: StdAttr.LabelLocation
    switch Pin.pinLabelLoc(facing) {
    case .north: loc = .north
    case .south: loc = .south
    case .east: loc = .east
    case .west: loc = .west
    }
    return LabelPlacement.computed(painter, avoid: .left, labelLoc: loc)
  }

  /// `drawNewStyleValue(InstancePainter, int width, int height, boolean isOutput, boolean isGhost)`.
  ///
  /// Drawn in a frame whose origin is the pin's *connection point*, which is why every x below
  /// is negative. A west-facing pin is drawn by rotating π and translating back along the body,
  /// so the digits stay upright.
  ///
  /// The per-bit coloured oval is drawn only for a **binary input** pin: an output pin shows
  /// plain glyphs, and a non-binary radix has no per-bit colour to show.
  private func drawNewStyleValue(
    _ painter: InstancePainter, _ width: Int, _ height: Int, _ isOutput: Bool, _ isGhost: Bool
  ) {
    // Note: we are here in a translated environment; the point (0,0) is the pin location.
    if isGhost { return }
    let value = Pin.getStateForPaint(painter).intendedValue
    let g = painter.g
    let savedFont = g.font
    g.font = Pin.defaultFont
    defer { g.font = savedFont }

    let radix = painter.attributeValue(RadixOption.attribute, default: .radix2)
    let dir = painter.attributeSet.getValue(StdAttr.facing) ?? .east
    let westTranslate = isOutput ? width : width + 10
    let baseColor = painter.componentColor
    let rotatedWest = dir == .west
    if rotatedWest {
      g.pushRotate(-Double.pi)
      g.pushTranslate(westTranslate, 0)
    }
    defer {
      if rotatedWest {
        g.popTransform()
        g.popTransform()
      }
    }

    if !painter.showState {
      g.color = baseColor
      let w = (painter.attributeSet as? PinAttributes)?.width.width ?? 1
      g.drawCenteredText("x\(w)", x: -15 - (width - 15) / 2, y: 0)
      return
    }

    let labelYPos = height / 2 - 2
    let labelValueXOffset = isOutput ? -15 : -20
    g.color = .rgba(.blue)
    g.pushScale(0.7, 0.7)
    g.drawString(
      radix.indexChar,
      x: Int(Double(labelValueXOffset) / 0.7),
      y: Int(Double(labelYPos) / 0.7))
    g.popTransform()
    g.color = baseColor
    if radix == .radix2 {
      let wid = value.width
      if wid == 0 {
        g.strokeWidth = 2
        let x = -15 - (width - 15) / 2
        g.drawLine(x - 4, 0, x + 4, 0)
        return
      }
      let x0 = isOutput ? -20 : -25
      var cx = x0
      var cy = height / 2 - 12
      var cur = 0
      for k in 0..<wid {
        if !isOutput {
          g.color = painter.color(of: value.get(k))
          g.fillOval(cx - 4, cy - 5, 9, 14)
          g.color = .white
        }
        g.drawCenteredText(value.get(k).toDisplayString(), x: cx, y: cy)
        if !isOutput { g.color = baseColor }
        cur += 1
        if cur == 8 {
          cur = 0
          cx = x0
          cy -= 20
        } else {
          cx -= 10
        }
      }
    } else {
      let text = radix.toString(value)
      var cx = isOutput ? -15 : -20
      for ch in text.reversed() {
        g.drawText(String(ch), x: cx, y: -2, halign: .right, valign: .center)
        cx -= Pin.digitWidth
      }
    }
  }

  /// The `xpos`/`ypos`/`rwidth`/`rheight`/`rotation` block that `drawInputShape` and
  /// `drawOutputShape` share character for character. Lifted out because having it twice is how
  /// the two drift apart.
  private static func newShapeFrame(
    _ dir: Direction, _ x: Int, _ y: Int, _ width: Int, _ height: Int
  ) -> (xpos: Int, ypos: Int, rwidth: Int, rheight: Int, rotation: Double) {
    switch dir {
    case .north:
      return (x + width / 2, y, height, width, -Double.pi / 2)
    case .south:
      return (x + width / 2, y + height, height, width, Double.pi / 2)
    case .west:
      return (x, y + height / 2, width, height, Double.pi)
    case .east:
      return (x + width, y + height / 2, width, height, 0)
    }
  }

  /// `drawInputShape(InstancePainter, int x, int y, int width, int height, Color, boolean isGhost)`.
  ///
  /// Classic: a plain rectangle with the value inside it. New: a five-point arrow pointing *in*
  /// toward the circuit, with a stub of wire at its tip drawn in the found value's colour (or
  /// `Value.multiColor` at bus width, which is why the bus branch ignores `lineColor`).
  private func drawInputShape(
    _ painter: InstancePainter, _ x: Int, _ y: Int, _ width: Int, _ height: Int,
    _ lineColor: SceneColor, _ isGhost: Bool
  ) {
    guard let attrs = painter.attributeSet as? PinAttributes else { return }
    let newShape =
      attrs.getValue(ProbeAttributes.probeAppearance) == ProbeAttributes.appearEvolutionNew
    let isBus = (attrs.getValue(StdAttr.width)?.width ?? 1) > 1
    let dir = attrs.getValue(StdAttr.facing) ?? .east
    let g = painter.g
    if !newShape {
      g.drawRect(x + 1, y + 1, width - 1, height - 1)
      if !isGhost {
        if !painter.showState {
          g.color = painter.componentColor
          g.drawCenteredText("x\(attrs.width.width)", x: x + width / 2, y: y + height / 2)
        } else {
          Probe.paintValue(painter, Pin.getStateForPaint(painter).intendedValue, colored: !isBus)
        }
      }
      return
    }

    let frame = Pin.newShapeFrame(dir, x, y, width, height)
    g.pushTranslate(frame.xpos, frame.ypos)
    g.pushRotate(frame.rotation)
    let col = g.color
    if isBus {
      g.color = .palette(.multi)
      g.strokeWidth = WiringPaint.busWidth
      g.drawLine(WiringPaint.busWidth / 2 - 5, 0, 0, 0)
      g.strokeWidth = 2
    } else {
      if painter.showState { g.color = lineColor }
      g.strokeWidth = WiringPaint.wireWidth
      g.drawLine(-5, 0, 0, 0)
      g.strokeWidth = 2
    }
    g.color = col
    let yBottom = frame.rheight / 2
    let yTop = -yBottom
    g.drawPolygon(
      [-frame.rwidth, -15, -5, -15, -frame.rwidth],
      [yTop, yTop, 0, yBottom, yBottom])
    drawNewStyleValue(painter, frame.rwidth, frame.rheight, false, isGhost)
    g.popTransform()
    g.popTransform()
  }

  /// `drawOutputShape(InstancePainter, int x, int y, int width, int height, Color, boolean isGhost)`.
  ///
  /// Classic: an oval at width 1, a 6-diameter round rect for a bus. New: the mirrored arrow,
  /// pointing *out* of the circuit; note `yTop`/`yBottom` are swapped relative to the input
  /// shape, which is the whole of the mirroring.
  private func drawOutputShape(
    _ painter: InstancePainter, _ x: Int, _ y: Int, _ width: Int, _ height: Int,
    _ lineColor: SceneColor, _ isGhost: Bool
  ) {
    guard let attrs = painter.attributeSet as? PinAttributes else { return }
    let newShape =
      attrs.getValue(ProbeAttributes.probeAppearance) == ProbeAttributes.appearEvolutionNew
    let isBus = (attrs.getValue(StdAttr.width)?.width ?? 1) > 1
    let dir = attrs.getValue(StdAttr.facing) ?? .east
    let g = painter.g
    if !newShape {
      if !isBus {
        g.drawOval(x + 1, y + 1, width - 1, height - 1)
      } else {
        g.drawRoundRect(x + 1, y + 1, width - 1, height - 1, 6, 6)
      }
      if !isGhost {
        if !painter.showState {
          g.color = painter.componentColor
          g.drawCenteredText("x\(attrs.width.width)", x: x + width / 2, y: y + height / 2)
        } else {
          Probe.paintValue(painter, Pin.getStateForPaint(painter).intendedValue, colored: !isBus)
        }
      }
      return
    }

    let frame = Pin.newShapeFrame(dir, x, y, width, height)
    g.pushTranslate(frame.xpos, frame.ypos)
    g.pushRotate(frame.rotation)
    let col = g.color
    if isBus {
      g.color = .palette(.multi)
      g.strokeWidth = WiringPaint.busWidth
      g.drawLine(-3, 0, -WiringPaint.busWidth / 2, 0)
      g.strokeWidth = 2
    } else {
      if painter.showState { g.color = lineColor }
      g.strokeWidth = WiringPaint.wireWidth
      g.drawLine(-3, 0, 0, 0)
      g.strokeWidth = 2
    }
    g.color = col
    let yTop = frame.rheight / 2
    let yBottom = -yTop
    g.drawPolygon(
      [-5, 10 - frame.rwidth, -frame.rwidth, 10 - frame.rwidth, -5],
      [yTop, yTop, 0, yBottom, yBottom])
    drawNewStyleValue(painter, frame.rwidth, frame.rheight, true, isGhost)
    g.popTransform()
    g.popTransform()
  }

  /// `paintGhost(InstancePainter)`: the same two shapes in grey, with `isGhost: true`, which
  /// suppresses the value entirely.
  public func paintGhost(_ painter: InstancePainter) {
    guard let attrs = painter.attributeSet as? PinAttributes else { return }
    let loc = painter.location
    let bds = painter.offsetBounds
    let x = loc.x
    let y = loc.y
    painter.g.strokeWidth = 2
    if attrs.isOutput {
      drawOutputShape(
        painter, x + bds.x, y + bds.y, bds.width, bds.height, .rgba(.gray), true)
    } else {
      drawInputShape(
        painter, x + bds.x, y + bds.y, bds.width, bds.height, .rgba(.gray), true)
    }
  }

  /// `paintInstance(InstancePainter)`.
  ///
  /// The `+ 1 / - 1` inset here is upstream's and compounds with the one inside the classic
  /// shape drawers, which inset again, so a classic pin's rectangle really is drawn at
  /// `(x + 2, y + 2, w - 2, h - 2)`. Transcribed rather than simplified, because "simplifying"
  /// it changes the new-appearance arrow, which does *not* inset a second time.
  public func paintInstance(_ painter: InstancePainter) {
    guard let attrs = painter.attributeSet as? PinAttributes else { return }
    let g = painter.g
    let bds = painter.bounds  // intentionally without the label
    let isOutput = attrs.type == Pin.output
    let state = Pin.getStateForPaint(painter)
    let found = state.foundValue
    let x = bds.x
    let y = bds.y
    g.strokeWidth = 2
    g.color = painter.componentColor
    if isOutput {
      drawOutputShape(
        painter, x + 1, y + 1, bds.width - 1, bds.height - 1, painter.color(of: found), false)
    } else {
      drawInputShape(
        painter, x + 1, y + 1, bds.width - 1, bds.height - 1, painter.color(of: found), false)
    }
    painter.drawLabel()
    painter.drawPorts()
  }

  /// `Pin.getState(InstanceState)` reached through a painter: see `Probe.getValueForPaint`.
  ///
  /// Unlike `Probe`'s, this one *creates and repairs* the state if it is missing, exactly as
  /// `getState` does, because a pin's paint runs before its first propagation on a freshly
  /// placed component.
  static func getStateForPaint(_ painter: InstancePainter) -> PinState {
    let attrs = (painter.attributeSet as? PinAttributes) ?? PinAttributes()
    let width = attrs.width
    var ret = painter.data as? PinState
    if ret == nil {
      let initialValue = attrs.initialValue
      let newValue =
        attrs.behavior == Pin.tristate
        ? Value.createUnknown(width)
        : Value.createKnown(width.width, initialValue)
      let fresh = PinState()
      fresh.foundValue = newValue
      fresh.intendedValue = newValue
      painter.setData(fresh)
      ret = fresh
    }
    let result = ret!
    if result.intendedValue.getWidth() != width.width {
      result.intendedValue = result.intendedValue.extendWidth(
        width.width, attrs.defaultBitValue)
    }
    if result.foundValue.getWidth() != width.width {
      result.foundValue = result.foundValue.extendWidth(width.width, .unknownValue)
    }
    return result
  }
}

extension Pin: InstancePaintable {}
extension Pin: InstanceLabelProvider {}

// MARK: - Poke: the input seam

/// The three things `PinPoker.handleBitPress` needs from the editing session, and cannot get
/// from `InstanceState` (D9).
///
/// Upstream inlines all three: `src instanceof Canvas canvas && !state.isCircuitRoot()` →
/// `OptionPane.showConfirmDialog(frame, S.get("pinFrozenQuestion"), …, OK_CANCEL_OPTION,
/// WARNING_MESSAGE)` → on OK, `circState.cloneAsNewRootState()`,
/// `canvas.getProject().setCircuitState(circState)`, `circState.getInstanceState(instance)`.
///
/// The scenario: the user is looking *into* a subcircuit from its parent and pokes one of its
/// input pins. That pin's value is dictated by the parent, so the poke would be immediately
/// overwritten: "frozen". Answering OK detaches the subcircuit's state into an independent root
/// state, at which point the poke sticks.
public protocol PinPokerHost: AnyObject {
  /// Prompt, and on acceptance detach `state`'s circuit into a new root state and return the
  /// instance state for the *same* component within it. Return `nil` for Cancel.
  ///
  /// Only ever called when `state.isCircuitRoot == false`.
  func detachFromParentState(_ state: any InstanceState) -> (any InstanceState)?
}

extension Pin {

  /// `Pin.PinPoker`'s **event half**; the adapter that makes the model half below reachable.
  ///
  /// Upstream's `PinPoker` is one class extending `InstancePoker`. This port split it: the
  /// arithmetic went into `Pin.Poker` so it could be tested without a canvas, and this is the
  /// thin `InstancePoker` conformance that `InstanceFactoryFeatures` can hand to `PokeTool`.
  /// Splitting it is what let the second half go missing; see `Pin.makePoker`.
  ///
  /// Coordinates are **world** coordinates, which is what `PokeMouseEvent` carries and what
  /// `Pin.Poker.getBit` expects: it subtracts `state.component.bounds` itself, exactly as
  /// upstream's `getBit` subtracts `bds` from `e.getX()`.
  public final class PokerBridge: InstancePoker {

    private let poker = Pin.Poker()

    public init() {}

    /// `init(InstanceState, MouseEvent)`: upstream's returns unconditionally, and so does this.
    /// An *output* pin is refused inside `handleBitPress` rather than here, which is where
    /// upstream refuses it too: clicking one still opens a caret and still shows the value.
    public func beginPoke(_ state: any InstanceState, _ event: PokeMouseEvent) -> Bool { true }

    public func mousePressed(_ state: any InstanceState, _ event: PokeMouseEvent) {
      poker.mousePressed(state, event.x, event.y)
    }

    public func mouseReleased(_ state: any InstanceState, _ event: PokeMouseEvent) {
      // D13: `mouseReleased` throws where upstream's `Value.create` can throw, and a poke that
      // cannot be represented is bad input rather than a broken program; the poke simply does
      // not take, which is also what upstream shows the user.
      //
      // **The returned `PendingEdit` is deliberately dropped, and that is a stated gap.** A pin
      // in decimal or float radix opens a modal edit dialog upstream; that dialog is M6 and is
      // not built, so those two radices are not pokable yet. Binary, octal and hex, the
      // default and everything a first-year course uses, go through the toggle path and work.
      _ = try? poker.mouseReleased(state, event.x, event.y)
    }

    /// `keyTyped(InstanceState, KeyEvent)`; typing a digit into a selected pin.
    ///
    /// `keyChar` is Java's UTF-16 `char`, and `nil` is `KeyEvent.CHAR_UNDEFINED`. A scalar that
    /// is not a whole Unicode scalar (a lone surrogate) is dropped rather than forced, which is
    /// the same answer `handleBitPress` gives a character it cannot classify.
    public func keyTyped(_ state: any InstanceState, _ event: inout PokeKeyEvent) {
      guard let keyChar = event.keyChar, let scalar = Unicode.Scalar(keyChar) else { return }
      try? poker.keyTyped(state, Character(scalar))
    }
  }

  /// `Pin.PinPoker`; the model half. See `Pin.swift`'s "Input seams" header for what is not
  /// here and why.
  ///
  /// Stateful across events (`bitPressed` survives from press to release; `bitCaret` survives
  /// across keystrokes), so it is a class with the same two `int` fields upstream has, both
  /// initialised to −1.
  public final class Poker {

    /// Which bit the mouse went down on, or −1.
    public private(set) var bitPressed = -1
    /// Where the typing caret sits, or −1 for "not yet placed".
    public private(set) var bitCaret = -1

    public init() {}

    // MARK: Hit testing

    /// `getRow(InstanceState, MouseEvent)`, which 20px row of a multi-row binary display the
    /// point falls in. `x`/`y` are in `component.bounds` coordinates.
    ///
    /// Note the three branches measure from different corners, and that the SOUTH branch (the
    /// `else`) is the only one that measures *forwards* from the origin.
    func getRow(_ state: any InstanceState, _ x: Int, _ y: Int) -> Int {
      let dir = state.attributeValue(StdAttr.facing, default: .east)
      let bds = state.component.bounds
      if dir == .east || dir == .west {
        return (bds.y + bds.height - y) / 20
      } else if dir == .north {
        return (bds.x + bds.width - x) / 20
      } else {
        return (x - bds.x) / 20
      }
    }

    /// `getColumn(InstanceState, MouseEvent, boolean isBinair)`, which digit column.
    ///
    /// `isBinair` is upstream's spelling. The 20-vs-10 offset for EAST/WEST is the arrow head
    /// plus, for an input pin, the extra 10px the new layout adds.
    func getColumn(_ state: any InstanceState, _ x: Int, _ y: Int, _ isBinair: Bool) -> Int {
      let distance = isBinair ? 10 : Pin.digitWidth
      let dir = state.attributeValue(StdAttr.facing, default: .east)
      let bds = state.component.bounds
      if dir == .east || dir == .west {
        let offset = dir == .east ? 20 : 10
        return (bds.x + bds.width - x - offset) / distance
      } else if dir == .north {
        return (y - bds.y - 20) / distance
      } else {
        return (bds.y + bds.height - y - 20) / distance
      }
    }

    /// `getBit(InstanceState, MouseEvent)`: the bit index under the point, or −1.
    ///
    /// Returns −1 for the decimal and float radices (they are edited through a dialog, not
    /// bit-by-bit), and 0 whenever the whole value fits in one digit.
    public func getBit(_ state: any InstanceState, _ x: Int, _ y: Int) -> Int {
      let radix = state.attributeValue(RadixOption.attribute, default: .radix2)
      let width = state.attributeValue(StdAttr.width, default: .one)
      let r: Int
      if radix == .radix16 {
        r = 4
      } else if radix == .radix8 {
        r = 3
      } else if radix == .radix2 {
        r = 1
      } else {
        return -1
      }
      if width.width <= r {
        return 0
      }
      let bds = state.component.bounds
      let i: Int
      let j: Int
      if state.attributeValue(ProbeAttributes.probeAppearance)
        == ProbeAttributes.appearEvolutionNew
      {
        i = getColumn(state, x, y, r == 1)
        j = getRow(state, x, y)
      } else {
        // The classic layout is laid out from the bottom-right corner, 10px (binary) or 8px
        // (hex/octal) per column and 14px per row, with a 4px / 2px inset.
        i = (bds.x + bds.width - x - (r == 1 ? 0 : 4)) / (r == 1 ? 10 : 8)
        j = (bds.y + bds.height - y - 2) / 14
      }
      // Binary packs 8 bits per row; every other radix is one row, so `j` is ignored.
      let bit = (r == 1) ? 8 * j + i : i * r
      return (bit < 0 || bit >= width.width) ? -1 : bit
    }

    // MARK: Editing

    /// `handleBitPress(InstanceState, int bit, RadixOption, Component src, char ch)`.
    ///
    /// `ch == nil` is upstream's `ch == 0`, i.e. "toggle" rather than "type this digit".
    /// Returns whether the value changed (which is what advances the caret in `keyTyped`).
    ///
    /// The normalisation step before any edit is load-bearing: whatever the parent circuit put
    /// in `intendedValue` is coerced to something the UI can represent: E and X become X under
    /// tristate, and E and X both become **1** otherwise. That is why poking a pin that is
    /// showing `E` in simple mode jumps it to 1 rather than to 0.
    @discardableResult
    public func handleBitPress(
      _ state: any InstanceState,
      bit: Int,
      radix: RadixOption,
      host: (any PinPokerHost)?,
      char ch: Character?
    ) throws -> Bool {
      var state = state
      guard let attrs = state.attributeSet as? PinAttributes, attrs.isInput else {
        return false
      }
      // `src instanceof Canvas canvas && !state.isCircuitRoot()`: a non-Canvas source skips the
      // prompt entirely and edits the frozen substate anyway. Passing `host: nil` reproduces it.
      if let host, !state.isCircuitRoot {
        guard let detached = host.detachFromParentState(state) else { return false }
        state = detached
      }
      let width = state.attributeValue(StdAttr.width, default: .one)
      let pinState = Pin.getState(state)
      var r = (radix == .radix16 ? 4 : (radix == .radix8 ? 3 : 1))
      if bit + r > width.width { r = width.width - bit }
      var val = pinState.intendedValue.getAll()
      let tristate = (attrs.behavior == Pin.tristate)
      // "if this was just converted from substate to root state, normalize val", upstream's
      // comment.
      if tristate {
        // convert E bits to x
        for b in 0..<val.count
        where val[b] != .trueValue && val[b] != .falseValue && val[b] != .unknownValue {
          val[b] = .unknownValue
        }
      } else {
        // convert E and X bits to 1
        for b in 0..<val.count where val[b] != .trueValue && val[b] != .falseValue {
          val[b] = .trueValue
        }
      }
      if ch == nil {
        // Toggle: increment the r-bit field, except that an all-ones field wraps to 0 (simple)
        // or to X (tristate), and an ill-defined field is cleared to 0.
        var ones = true
        var defined = true
        for b in bit..<(bit + r) {
          if val[b] == .falseValue {
            ones = false
          } else if val[b] != .trueValue {
            defined = false
          }
        }
        if !defined || (ones && !tristate) {
          for b in bit..<(bit + r) { val[b] = .falseValue }
        } else if ones && tristate {
          for b in bit..<(bit + r) { val[b] = .unknownValue }
        } else {
          var carry = 1
          let v: [Value] = [.falseValue, .trueValue]
          for b in bit..<(bit + r) {
            let s = (val[b] == .trueValue ? 1 : 0) + carry
            val[b] = v[s % 2]
            carry = s / 2
          }
        }
      } else if tristate && JavaText.isUnknownCharacter(ch) {
        // `ch == Character.toLowerCase(Value.UNKNOWNCHAR) || ch ==
        // Character.toUpperCase(Value.UNKNOWNCHAR)`. See `JavaText.isUnknownCharacter` for why
        // the character comes from `DisplayCharacters.default` rather than a preference.
        for b in bit..<(bit + r) { val[b] = .unknownValue }
      } else {
        let d: Int
        guard let ch, let ascii = ch.asciiValue else { return false }
        switch ascii {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): d = Int(ascii - UInt8(ascii: "0"))
        case UInt8(ascii: "a")...UInt8(ascii: "f"): d = 0xa + Int(ascii - UInt8(ascii: "a"))
        case UInt8(ascii: "A")...UInt8(ascii: "F"): d = 0xA + Int(ascii - UInt8(ascii: "A"))
        default: return false
        }
        if d >= 1 << r { return false }
        for i in 0..<r {
          val[bit + i] = ((d & (1 << i)) != 0) ? .trueValue : .falseValue
        }
      }
      pinState.intendedValue = try Value.create(val)
      state.fireInvalidated()
      return true
    }

    // MARK: Event entry points

    /// `mousePressed(InstanceState, MouseEvent)`.
    public func mousePressed(_ state: any InstanceState, _ x: Int, _ y: Int) {
      bitPressed = getBit(state, x, y)
    }

    /// `mouseReleased(InstanceState, MouseEvent)`.
    ///
    /// Returns the dialog the caller must present, if any. Upstream constructs and shows
    /// `EditDecimal` / `EditFloat` inline at `(e.getXOnScreen() - 60, e.getYOnScreen() - 40)`;
    /// positioning and presentation are M6, the edit models are `Pin.DecimalEdit` /
    /// `Pin.FloatEdit`.
    @discardableResult
    public func mouseReleased(
      _ state: any InstanceState, _ x: Int, _ y: Int, host: (any PinPokerHost)? = nil
    ) throws -> PendingEdit? {
      guard let attrs = state.attributeSet as? PinAttributes, attrs.isInput else {
        bitPressed = -1
        bitCaret = -1
        return nil
      }
      var pending: PendingEdit? = nil
      let radix = state.attributeValue(RadixOption.attribute, default: .radix2)
      if radix == .radix10Signed || radix == .radix10Unsigned {
        pending = .decimal(DecimalEdit(state))
      } else if radix == .radixFloat {
        pending = .float(FloatEdit(state))
      } else {
        let bit = getBit(state, x, y)
        if bit == bitPressed && bit >= 0 {
          bitCaret = bit
          try handleBitPress(state, bit: bit, radix: radix, host: host, char: nil)
        }
        if bitCaret < 0 {
          let width = state.attributeValue(StdAttr.width, default: .one)
          let r = (radix == .radix16 ? 4 : (radix == .radix8 ? 3 : 1))
          bitCaret = ((width.width - 1) / r) * r
        }
      }
      bitPressed = -1
      return pending
    }

    /// `keyTyped(InstanceState, KeyEvent)`: type a digit at the caret, then move the caret one
    /// digit to the right (i.e. towards the low bits), wrapping to the top.
    ///
    /// Note `RADIX_FLOAT` is **not** excluded here the way it is in `mouseReleased`, so `r`
    /// falls through to 1 and a float-radix pin can be edited bit-by-bit from the keyboard.
    /// Preserved.
    public func keyTyped(
      _ state: any InstanceState, _ ch: Character, host: (any PinPokerHost)? = nil
    ) throws {
      let radix = state.attributeValue(RadixOption.attribute, default: .radix2)
      if radix == .radix10Signed || radix == .radix10Unsigned { return }
      let r = (radix == .radix16 ? 4 : (radix == .radix8 ? 3 : 1))
      let width = state.attributeValue(StdAttr.width, default: .one)
      if bitCaret < 0 { bitCaret = ((width.width - 1) / r) * r }
      if try handleBitPress(state, bit: bitCaret, radix: radix, host: host, char: ch) {
        bitCaret -= r
        if bitCaret < 0 { bitCaret = ((width.width - 1) / r) * r }
      }
    }

    /// What `mouseReleased` decided the UI should open.
    public enum PendingEdit {
      case decimal(Pin.DecimalEdit)
      case float(Pin.FloatEdit)
    }
  }
}

// MARK: - The two value editors, model half

extension Pin {

  /// `Pin.EditDecimal` minus its `JDialog`. Constructed on mouse-release for the two decimal
  /// radices; `initialText` is what the field is pre-filled with (and pre-selected), `isValid`
  /// drives the yellow/red background and the OK button, and `accept` is OK / Return.
  public final class DecimalEdit {
    private let state: any InstanceState
    private let pinState: Pin.PinState
    /// `RadixOption` at construction time; the dialog does not observe later changes.
    public let radix: RadixOption
    /// `value.getWidth()`, captured at construction.
    public let bitWidth: Int
    /// `attrs.behavior == TRISTATE`.
    public let isTristate: Bool

    init(_ state: any InstanceState) {
      self.state = state
      self.radix = state.attributeValue(RadixOption.attribute, default: .radix2)
      self.pinState = Pin.getState(state)
      self.bitWidth = pinState.intendedValue.getWidth()
      self.isTristate = (state.attributeSet as? PinAttributes)?.behavior == Pin.tristate
    }

    /// `text.setText(value.toDecimalString(radix == RADIX_10_SIGNED))`.
    public var initialText: String {
      pinState.intendedValue.toDecimalString(signed: radix == .radix10Signed)
    }

    /// `isEditValid(String)`.
    ///
    /// Trims first, so leading/trailing whitespace is accepted here: and then `accept` parses
    /// the **untrimmed** string, so `" 5 "` reports valid and then silently does nothing. See
    /// `accept`.
    public func isValid(_ text: String?) -> Bool {
      guard let text else { return false }
      let s = JavaText.trim(text)
      if s.isEmpty { return false }
      if isTristate && JavaText.isUnknownToken(s) { return true }
      guard let n = JavaText.parseBigInteger(s) else { return false }
      if radix == .radix10Signed {
        let minValue = -(Int128(1) << (bitWidth - 1))
        let maxValue = Int128(1) << (bitWidth - 1)
        return n >= minValue && n < maxValue
      } else {
        let maxValue = Int128(1) << bitWidth
        return n >= 0 && n < maxValue
      }
    }

    /// `accept()`; returns whether the pin's value was changed.
    ///
    /// ── UPSTREAM BUG, PRESERVED ──
    /// `isEditValid` trims its copy of the text; `accept` then calls `new BigInteger(s)` on the
    /// *untrimmed* string. Text with surrounding whitespace therefore validates (yellow field,
    /// OK enabled) and then throws `NumberFormatException`, which is caught and turned into a
    /// bare `return`; the dialog stays open and nothing happens. "Fixing" it by trimming would
    /// make previously-inert input commit a value.
    ///
    /// The out-of-range branch is the other thing worth reading: for an *unsigned* radix, a value
    /// at or above 2^(w−1) is re-interpreted as its two's-complement negative before being stored,
    /// which is how an unsigned display and a signed `Value` stay consistent.
    @discardableResult
    public func accept(_ text: String) -> Bool {
      guard isValid(text) else { return false }
      let newVal: Value
      if JavaText.isUnknownToken(text) {
        newVal = Value.createUnknown(BitWidth.known(bitWidth))
      } else {
        guard let n = JavaText.parseBigInteger(text) else { return false }
        let signedMax = Int128(1) << (bitWidth - 1)
        if radix == .radix10Signed || n < signedMax {
          newVal = Value.createKnown(BitWidth.known(bitWidth), Int64(truncatingIfNeeded: n))
        } else {
          let maxValue = Int128(1) << bitWidth
          let newValue = n - maxValue
          newVal = Value.createKnown(
            BitWidth.known(bitWidth), Int64(truncatingIfNeeded: newValue))
        }
      }
      pinState.intendedValue = newVal
      state.fireInvalidated()
      return true
    }
  }

  /// `Pin.EditFloat` minus its `JDialog`. Same shape as `DecimalEdit`, with `Double.parseDouble`
  /// in place of `BigInteger` and no range check at all; any finite double is accepted and then
  /// squeezed into the pin's width by `Value.createKnown(int, double)`.
  public final class FloatEdit {
    private let state: any InstanceState
    private let pinState: Pin.PinState
    public let bitWidth: Int
    public let isTristate: Bool

    init(_ state: any InstanceState) {
      self.state = state
      self.pinState = Pin.getState(state)
      self.bitWidth = pinState.intendedValue.getWidth()
      self.isTristate = (state.attributeSet as? PinAttributes)?.behavior == Pin.tristate
    }

    /// `text.setText(value.toStringFromFloatValue())`.
    public var initialText: String {
      pinState.intendedValue.toStringFromFloatValue()
    }

    /// `isEditValid(String)`. The three infinity spellings and `nan` are accepted explicitly
    /// *before* `Double.parseDouble` is tried, because Java only spells them `Infinity`/`NaN`.
    public func isValid(_ text: String?) -> Bool {
      guard let text else { return false }
      let s = JavaText.trim(text)
      if s.isEmpty { return false }
      if isTristate && JavaText.isUnknownToken(s) { return true }
      let lowered = s.lowercased()
      if lowered == "nan" || lowered == "inf" || lowered == "+inf" || lowered == "-inf" {
        return true
      }
      return (try? AttributeTextFormat.parseDouble(s)) != nil
    }

    /// `accept()`.
    ///
    /// Note this branch does **not** wrap the parse in a try/catch the way `EditDecimal` does;
    /// upstream lets a `NumberFormatException` escape here. It cannot actually be thrown, because
    /// `isEditValid` already parsed the same text… except that, exactly as in `DecimalEdit`,
    /// `isEditValid` trimmed and this does not, so `" 1.5 "` throws out of the dialog's action
    /// listener. `Double.parseDouble` itself trims, which is what saves it in practice: a real
    /// difference from `BigInteger`, and the reason the two dialogs behave differently on the
    /// same input.
    @discardableResult
    public func accept(_ text: String) -> Bool {
      guard isValid(text) else { return false }
      let newVal: Value
      if JavaText.isUnknownToken(text) {
        newVal = Value.createUnknown(BitWidth.known(bitWidth))
      } else {
        let lowered = text.lowercased()
        let val: Double
        if lowered == "inf" || lowered == "+inf" {
          val = .infinity
        } else if lowered == "-inf" {
          val = -.infinity
        } else if lowered == "nan" {
          val = .nan
        } else {
          guard let parsed = try? AttributeTextFormat.parseDouble(text) else { return false }
          val = parsed
        }
        newVal = Value.createKnownFloat(bitWidth, val)
      }
      pinState.intendedValue = newVal
      state.fireInvalidated()
      return true
    }
  }
}

// MARK: - Java text helpers used by the two editors

/// The two pieces of `java.lang` text behaviour the pin editors depend on and that
/// `AttributeTextFormat` does not already cover.
enum JavaText {

  /// `String.trim()`: strips every character `<= U+0020`, which is *not* the same set as
  /// Swift's `.whitespaces`.
  static func trim(_ text: String) -> String {
    var slice = Substring(text)
    while let first = slice.unicodeScalars.first, first.value <= 0x20 {
      slice = slice.dropFirst()
    }
    while let last = slice.unicodeScalars.last, last.value <= 0x20 {
      slice = slice.dropLast()
    }
    return String(slice)
  }

  /// The three spellings both editors accept for "unknown": the display character in either
  /// case, and the literal `"???"`.
  ///
  /// Upstream uses `Character.toString(Value.UNKNOWNCHAR)`: a preference-derived character,
  /// `'U'` out of the box (`DisplayCharacters.default`). D9 keeps preferences out of the model,
  /// so the default is used directly; a UI that lets the user change it must pass its own
  /// character down when this becomes configurable.
  static func isUnknownToken(_ text: String) -> Bool {
    let unknown = String(DisplayCharacters.default.unknownChar)
    return text == unknown.lowercased() || text == unknown.uppercased() || text == "???"
  }

  /// The single-character form of the same test, used by `PinPoker.handleBitPress`
  /// (`ch == Character.toLowerCase(Value.UNKNOWNCHAR) || ch ==
  /// Character.toUpperCase(Value.UNKNOWNCHAR)`).
  static func isUnknownCharacter(_ ch: Character?) -> Bool {
    guard let ch else { return false }
    let unknown = String(DisplayCharacters.default.unknownChar)
    return String(ch) == unknown.lowercased() || String(ch) == unknown.uppercased()
  }

  /// `new BigInteger(String)` for the range these editors care about.
  ///
  /// Returns `nil` for anything `BigInteger` would reject (empty, a lone sign, a non-digit
  /// anywhere, any radix prefix) **and** for a magnitude past `Int128`. The latter is not a
  /// fidelity gap: the widest legal input is 2^64 − 1, twenty digits, and the callers'
  /// range tests reject everything larger, so a value that does not fit `Int128` is
  /// out of range under every branch.
  static func parseBigInteger(_ text: String) -> Int128? {
    var digits = Substring(text)
    var negative = false
    if let first = digits.first, first == "+" || first == "-" {
      negative = (first == "-")
      digits = digits.dropFirst()
    }
    guard !digits.isEmpty else { return nil }
    var magnitude = Int128(0)
    for character in digits {
      guard let ascii = character.asciiValue,
        ascii >= UInt8(ascii: "0"), ascii <= UInt8(ascii: "9")
      else { return nil }
      let (scaled, overflow1) = magnitude.multipliedReportingOverflow(by: 10)
      if overflow1 { return nil }
      let (sum, overflow2) = scaled.addingReportingOverflow(
        Int128(ascii - UInt8(ascii: "0")))
      if overflow2 { return nil }
      magnitude = sum
    }
    return negative ? -magnitude : magnitude
  }
}
