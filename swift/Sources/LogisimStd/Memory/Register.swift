// Register.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.memory.{Register, RegisterData}),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── `StdAttr.LABEL_LOC` ─────────────────────────────────────────────────────────────────────
//
// Upstream's `StdAttr.LABEL_LOC` is `Attribute<Object>` over a mixed array `{LABEL_CENTER,
// Direction.NORTH, Direction.SOUTH, Direction.EAST, Direction.WEST}`; not expressible as a
// single `Attribute<V>`. `StdAttr.swift`'s own header records exactly this gap and defers it to
// "the component tranche that needs it"; this is that tranche. Following the precedent
// `CircuitAttributes.labelLocationAttribute` already set (a distinct, file-local
// `Attribute<Direction>`, not a shared upstream constant), `Register.labelLocation` below is its
// own `Attribute<AttributeOption>` built from the same five serialized tokens
// ("center"/"north"/"south"/"east"/"west").
//
// **That deferral is now spent.** The header used to say nothing in this milestone *interprets*
// the value, because upstream reads `LABEL_LOC` only from `computeLabelTextField`. Board #78
// ports exactly that, so `labelPlacement` below now translates this attribute's serialized token
// into `StdAttr.LabelLocation` and hands it to `LabelPlacement.computed`. The two are separate
// attribute identities and the default lookup would find nothing, which is why the translation
// is explicit rather than implicit; see `labelPlacement`'s own comment.
// `Counter.swift` needs the identical attribute and declares its own independent copy, exactly
// as `CircuitAttributes` does not share its constant with `StdAttr` either.
//
// ── Preferences not wired ───────────────────────────────────────────────────────────────────
//
// See `AbstractFlipFlop.swift`'s header: `AppPreferences.Memory_Startup_Unknown` (default
// `false`) and `AppPreferences.getDefaultAppearance()` (default `StdAttr.APPEAR_EVOLUTION`) are
// hardcoded to their compiled defaults rather than read from a preferences store.
//
// ── Not ported ──────────────────────────────────────────────────────────────────────────────
//
//   * `RegisterPoker`, `RegisterLogger`: reflective poker/logger classes (`InstanceFactory.swift`
//     header: no AOT-Swift equivalent).
//   * `getHDLName`, `checkForGatedClocks`, `clockPinIndex`: HDL/FPGA backlog (D11).
//   * `DynamicElementProvider`/`createDynamicElement` (`RegisterShape`): the appearance-editor
//     handle overlay; a different unwired seam than this slice (objectives.md's "four unwired
//     handler seams").
//   * `instanceAttributeChanged`: upstream's branches only call `recomputeBounds`/`updatePorts`
//     (both automatic here, PATTERNS.md §0) or `computeLabelTextField`, whose three call sites
//     (Register.java:254, :361, :363) are all answered by the single on-demand `labelPlacement`
//     below. Nothing is left for the override to do.
//   * `Register.drawRegisterClassic(InstancePainter, int, int, int, boolean, boolean, boolean,
//     String)`; the *static* eight-argument overload at `Register.java:53-61`. Its body is
//     literally `{}`: upstream declares it, never implements it, and `RegisterShape` only ever
//     calls the `drawRegisterEvolution` sibling. Porting an empty method would be noise.
//
// ── PAINTING (M6) ───────────────────────────────────────────────────────────────────────────
//
// `drawRegisterClassic(InstancePainter)`, `drawRegisterEvolution(...)` and `paintInstance` are
// ported at the bottom of this file. See `MemPainter.swift` for the paint seam and why the entry
// point is not yet an `override`.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

/// `com.cburch.logisim.std.memory.Register`.
public final class Register: InstanceFactoryBase {
  /// `Register._ID`. Do NOT change; it is the `.circ` factory-name token.
  public static let id = "Register"

  /// `Register.ATTR_SHOW_IN_TAB`. Not `private`: `Counter`'s bespoke attribute set reuses this
  /// exact constant, matching upstream's `CounterAttributes` referencing `Register.ATTR_SHOW_IN_TAB`
  /// directly rather than declaring its own.
  static let attrShowInTab: Attribute<Bool> = Attributes.forBoolean("showInTab")

  // MARK: LABEL_LOC — see the file header.
  static let labelLocationCenter = StdAttr.labelCenter
  static let labelLocationNorth = AttributeOption(value: Direction.north.name)
  static let labelLocationSouth = AttributeOption(value: Direction.south.name)
  static let labelLocationEast = AttributeOption(value: Direction.east.name)
  static let labelLocationWest = AttributeOption(value: Direction.west.name)
  static let labelLocation: Attribute<AttributeOption> = Attributes.forOption(
    "labelloc",
    choices: [
      labelLocationCenter, labelLocationNorth, labelLocationSouth, labelLocationEast,
      labelLocationWest,
    ])

  /// `Register.DELAY`.
  private static let delay = 8
  private static let out = 0
  private static let dataIn = 1
  private static let clockPort = 2
  private static let clearPort = 3
  private static let enablePort = 4

  public init() {
    super.init(Register.id)
    setAttributes([
      StdAttr.width.binding(BitWidth.known(8)),
      StdAttr.trigger.binding(StdAttr.triggerRising),
      StdAttr.label.binding(""),
      Register.labelLocation.binding(Register.labelLocationNorth),
      StdAttr.labelFont.binding(StdAttr.defaultLabelFont),
      Register.attrShowInTab.binding(false),
      StdAttr.appearance.binding(StdAttr.appearEvolution),
    ])
  }

  /// `setInstancePoker(RegisterPoker.class)`.
  public override func makePoker() -> (any InstancePoker)? { RegisterPoker() }

  public override func offsetBounds(_ attributes: any AttributeSet) -> Bounds {
    attributes.getValue(StdAttr.appearance) == StdAttr.appearClassic
      ? Bounds.create(-30, -20, 30, 40)
      : Bounds.create(0, 0, 60, 90)
  }

  public override func ports(_ attributes: any AttributeSet) -> [Port] {
    var ps = [Port](repeating: Port(0, 0, .input, 1), count: 5)
    if attributes.getValue(StdAttr.appearance) == StdAttr.appearClassic {
      ps[Register.out] = Port(0, 0, .output, StdAttr.width)
      ps[Register.dataIn] = Port(-30, 0, .input, StdAttr.width)
      ps[Register.clockPort] = Port(-20, 20, .input, 1)
      ps[Register.clearPort] = Port(-10, 20, .input, 1)
      ps[Register.enablePort] = Port(-30, 10, .input, 1)
    } else {
      ps[Register.out] = Port(60, 30, .output, StdAttr.width)
      ps[Register.dataIn] = Port(0, 30, .input, StdAttr.width)
      ps[Register.clockPort] = Port(0, 70, .input, 1)
      ps[Register.clearPort] = Port(30, 90, .input, 1)
      ps[Register.enablePort] = Port(0, 50, .input, 1)
    }
    return ps
  }

  public override func propagate(_ state: any InstanceState) throws {
    let dataWidth = state.attributeValue(StdAttr.width, default: BitWidth.known(8))
    let triggerType = state.attributeValue(StdAttr.trigger)

    let data: RegisterData
    if let existing = state.data as? RegisterData {
      data = existing
    } else {
      data = RegisterData(width: dataWidth)
      state.setData(data)
    }

    let triggered = data.clock.updateClock(state.portValue(Register.clockPort), trigger: triggerType)

    if state.portValue(Register.clearPort) == .trueValue {
      data.value = Value.createKnown(dataWidth, 0)
    } else if triggered && state.portValue(Register.enablePort) != .falseValue {
      data.value = state.portValue(Register.dataIn)
    }

    state.setPort(Register.out, data.value, Register.delay)
  }

  // MARK: - Painting (M6)

  /// `Register.paintInstance(InstancePainter)` (`Register.java:283-315`).
  public func paintInstance(_ painter: any MemPainter) {
    if painter.attributeValue(StdAttr.appearance) == StdAttr.appearClassic {
      drawRegisterClassic(painter)
      return
    }
    let state = painter.data as? RegisterData
    let width = painter.attributeValue(StdAttr.width)?.width ?? 8
    let loc = painter.location

    let trigger = painter.attributeValue(StdAttr.trigger)
    let isLatch = trigger == StdAttr.triggerHigh || trigger == StdAttr.triggerLow
    let negActive = trigger == StdAttr.triggerFalling || trigger == StdAttr.triggerLow

    Register.drawRegisterEvolution(
      painter, x: loc.x, y: loc.y, nrOfBits: width, isLatch: isLatch, negActive: negActive,
      hasWE: true, value: state?.value)
    painter.drawLabel()

    painter.drawPort(Register.dataIn)
    painter.drawPort(Register.out)
    painter.drawPort(Register.clearPort)
    painter.drawPort(Register.enablePort)
    painter.drawPort(Register.clockPort)
  }

  /// `Register.drawRegisterEvolution(InstancePainter, int, int, int, boolean, boolean, boolean,
  /// Value)` (`Register.java:63-140`). `static` in Java too: `RegisterShape` (the
  /// appearance-editor dynamic element, not ported) is upstream's other caller.
  ///
  /// Note the deliberate colour leak in the middle: `g.setColor(Value.multiColor)` inside the
  /// `nrOfBits > 1` block is *not* restored before the D/Q stub lines are drawn, so a multi-bit
  /// register's stubs come out in the bus colour and a one-bit register's in the component
  /// colour. That is upstream's shape, reproduced.
  public static func drawRegisterEvolution(
    _ painter: any MemPainter, x: Int, y: Int, nrOfBits: Int, isLatch: Bool, negActive: Bool,
    hasWE: Bool, value: Value?
  ) {
    let dqWidth = (nrOfBits == 1) ? 2 : 5
    let len = (nrOfBits + 3) / 4
    let wid = 8 * len + 2
    let xoff = (60 - wid) / 2
    let g = painter.graphics

    if painter.showState, let value {
      if value.isFullyDefined() {
        g.color = MemPaint.lightGray
      } else if value.isErrorValue() {
        g.color = MemPaint.red
      } else {
        g.color = MemPaint.blue
      }
      g.fillRect(x + xoff, y + 1, wid, 16)
      g.color = value.isFullyDefined() ? MemPaint.darkGray : MemPaint.yellow
      let str =
        value.isFullyDefined()
        ? MemPaint.hexString(bits: nrOfBits, value: value.toLongValue())
        : String(repeating: "?", count: len)
      g.drawCenteredText(str, x: x + 30, y: y + 8)
    }

    g.color = MemPaint.componentColor
    g.strokeWidth = 2
    if nrOfBits > 1 {
      g.drawLine(x + 15, y + 80, x + 15, y + 85)
      g.drawLine(x + 15, y + 85, x + 55, y + 85)
      g.drawLine(x + 55, y + 25, x + 55, y + 85)
      g.drawLine(x + 50, y + 25, x + 55, y + 25)
      if nrOfBits > 2 {
        g.drawLine(x + 20, y + 85, x + 20, y + 90)
        g.drawLine(x + 20, y + 90, x + 60, y + 90)
        g.drawLine(x + 60, y + 30, x + 60, y + 90)
        g.drawLine(x + 55, y + 30, x + 60, y + 30)
      }
      g.color = MemPaint.multiColor
    }
    g.strokeWidth = dqWidth
    g.drawLine(x, y + 30, x + 8, y + 30)
    g.drawLine(x + 52, y + 30, x + 60, y + 30)
    g.color = MemPaint.componentColor
    g.strokeWidth = 2
    g.drawRect(x + 10, y + 20, 40, 60)
    g.strokeWidth = 1
    g.drawCenteredText("D", x: x + 18, y: y + 28)
    g.drawCenteredText("Q", x: x + 41, y: y + 28)
    g.strokeWidth = 2
    g.drawLine(x + 30, y + 81, x + 30, y + 90)
    g.strokeWidth = 1
    g.color = MemPaint.componentSecondaryColor
    g.drawCenteredText("R", x: x + 30, y: y + 68)
    g.color = MemPaint.componentColor
    if hasWE {
      g.drawCenteredText("WE", x: x + 22, y: y + 48)
      g.strokeWidth = 2
      g.drawLine(x, y + 50, x + 9, y + 50)
      g.strokeWidth = 1
    }
    if !isLatch {
      painter.drawClockSymbol(x + 10, y + 70)
    } else {
      g.drawCenteredText("E", x: x + 18, y: y + 68)
    }
    g.strokeWidth = 2
    if !negActive {
      g.drawLine(x, y + 70, x + 9, y + 70)
    } else {
      g.drawOval(x, y + 65, 10, 10)
    }
    g.strokeWidth = 1
  }

  /// `Register.drawRegisterClassic(InstancePainter)` (`Register.java:142-196`).
  func drawRegisterClassic(_ painter: any MemPainter) {
    let g = painter.graphics
    let bds = painter.bounds
    let state = painter.data as? RegisterData
    let widthVal = painter.attributeValue(StdAttr.width)
    let width = widthVal?.width ?? 8

    // The hex readout is split across two lines once it needs more than four digits.
    var a: String
    var b: String? = nil
    if painter.showState {
      let val = state?.value.toLongValue() ?? 0
      let str = MemPaint.hexString(bits: width, value: val)
      if str.count <= 4 {
        a = str
      } else {
        let split = str.index(str.endIndex, offsetBy: -4)
        a = String(str[str.startIndex..<split])
        b = String(str[split...])
      }
    } else {
      a = MemPaintStrings.registerLabel
      // Upstream writes `widthVal.getWidth()` here and NPEs on a missing width attribute; the
      // already-defaulted `width` is used instead (same value on every reachable path).
      b = MemPaintStrings.registerWidthLabel(width)
    }

    g.color = MemPaint.componentColor
    painter.drawBounds()
    g.color = MemPaint.color(of: painter.attributeValue(StdAttr.labelColor, default: StdAttr.defaultLabelColor))
    painter.drawLabel()

    if b == nil {
      painter.drawPort(Register.dataIn, "D", .east)
      painter.drawPort(Register.out, "Q", .west)
    } else {
      painter.drawPort(Register.dataIn)
      painter.drawPort(Register.out)
    }
    g.color = MemPaint.componentSecondaryColor
    painter.drawPort(Register.clearPort, "0", .south)
    painter.drawPort(Register.enablePort, MemPaintStrings.memEnableLabel, .east)
    g.color = MemPaint.componentColor
    painter.drawClock(Register.clockPort, .north)

    if let b {
      g.drawText(a, x: bds.x + 15, y: bds.y + 3, halign: .center, valign: .top)
      g.drawText(b, x: bds.x + 15, y: bds.y + 15, halign: .center, valign: .top)
    } else {
      g.drawText(a, x: bds.x + 15, y: bds.y + 4, halign: .center, valign: .top)
    }
  }

  // MARK: - Label placement

  /// `instance.computeLabelTextField(Instance.AVOID_SIDES)`: Register.java:254 (from
  /// `configureNewInstance`), :361 and :363 (from `instanceAttributeChanged`).
  ///
  /// Upstream needs all **three** call sites because its text field is a stored object that must
  /// be re-derived whenever `StdAttr.WIDTH`, `StdAttr.APPEARANCE` (both of which resize the body,
  /// so `bds` moves) or `StdAttr.LABEL_LOC` (which picks the edge) changes. Here the placement is
  /// computed on demand from the live attribute set by both `InstancePainter.drawLabel()` and
  /// `InstanceTextField.resolve`, so one function replaces all three call sites and the
  /// recomputation cannot be missed.
  ///
  /// The `labelLoc:` argument is passed explicitly rather than left to
  /// `LabelPlacement.computed`'s default lookup of `StdAttr.labelLocation`. Upstream's
  /// `StdAttr.LABEL_LOC` is `Attribute<Object>` over a heterogeneous array, and this port's
  /// `Register`/`Counter` tranche modelled it as a file-local `Attribute<AttributeOption>` (see
  /// the file header) rather than the `StdAttr.LabelLocation` enum `StdAttr.swift` later settled
  /// on. Those are two distinct attribute identities, so the default lookup would find nothing
  /// and silently fall through to `computeLabelTextField`'s centred defaults. Translating the
  /// serialized token here keeps the `.circ` format untouched. `Pin.labelPlacement` sets the
  /// precedent for passing the location in.
  ///
  /// For the shipped defaults, `LABEL_LOC == north`, no `StdAttr.FACING` on a register, so the
  /// avoid mask does not rotate and `AVOID_TOP` is clear, this resolves to
  /// `(bds.x + bds.width / 2, bds.y - 2, H_CENTER, V_BOTTOM)`.
  public func labelPlacement(_ painter: InstancePainter) -> LabelPlacement? {
    LabelPlacement.computed(
      painter, avoid: .sides, labelLoc: Register.labelLocation(of: painter.attributeSet))
  }

  /// The `Register.labelLocation` option -> `StdAttr.LabelLocation` translation described above.
  /// Matched on the serialized token, which is by construction the same five strings on both
  /// sides ("center"/"north"/"south"/"east"/"west").
  static func labelLocation(of attributes: any AttributeSet) -> StdAttr.LabelLocation? {
    guard let option = attributes.getValue(Register.labelLocation) else { return nil }
    return StdAttr.LabelLocation(rawValue: option.name)
  }
}

extension Register: InstanceLabelProvider {}

/// `com.cburch.logisim.std.memory.RegisterData`.
///
/// Also used directly by `Counter.propagate`, exactly as upstream's `Counter.java` casts
/// `state.getData()` to this same `RegisterData` class rather than declaring its own; kept
/// `internal` (the Swift default) rather than `private` for that reason.
///
/// **Deviation (mechanism).** Java: `extends ClockState implements InstanceData`; composition
/// (`clock: ClockState`) replaces inheritance, matching `ClockState.swift`'s own header note.
final class RegisterData: InstanceData {
  var clock = ClockState()
  var value: Value

  init(width: BitWidth) {
    // `AppPreferences.Memory_Startup_Unknown` defaults to `false`, see `AbstractFlipFlop.swift`.
    value = Value.createKnown(width, 0)
  }

  func cloneData() -> any InstanceData {
    let copy = RegisterData(width: BitWidth.known(value.width))
    copy.value = value
    copy.clock = clock
    return copy
  }
}
