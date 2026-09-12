// Counter.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.memory.{Counter, CounterAttributes}),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// `CounterAttributes.java` is folded into this file as `CounterAttributes` (a second,
// module-internal type) rather than a tenth owned file; it is a small helper `Counter` alone
// pulls in, exactly the kind of dependency the task brief allows bundling.
//
// ── `StdAttr.LABEL_LOC` ─────────────────────────────────────────────────────────────────────
//
// Same gap as `Register.swift`'s header describes; `Counter` needs its own independent copy of
// the attribute (five tokens: "center"/"north"/"south"/"east"/"west"), not a shared one.
//
// ── Preferences not wired ───────────────────────────────────────────────────────────────────
//
// See `AbstractFlipFlop.swift`'s header: `AppPreferences.getDefaultAppearance()` (default
// `StdAttr.APPEAR_EVOLUTION`) is hardcoded. `Counter` reuses `Register`'s `RegisterData`, whose
// `Memory_Startup_Unknown` handling is also hardcoded there.
//
// ── Not ported ──────────────────────────────────────────────────────────────────────────────
//
//   * `CounterPoker`: reflective poker class (`InstanceFactory.swift` header).
//   * `getHDLName`, `checkForGatedClocks`, `clockPinIndex`: HDL/FPGA backlog (D11).
//   * `DynamicElementProvider`/`createDynamicElement` (`CounterShape`): appearance-editor handle
//     overlay; a different unwired seam (objectives.md's "four unwired handler seams").
//   * `instanceAttributeChanged`: upstream's branches only call `recomputeBounds`/
//     `configurePorts` (both automatic here, PATTERNS.md §0) or `computeLabelTextField`. That
//     last one is NOT equivalent to `configurePorts`'s own `setTextField` and the difference is
//     upstream's; `labelPlacement` at the bottom of the class documents it in full.
//
// ── PAINTING (M6) ───────────────────────────────────────────────────────────────────────────
//
// `drawControl`, `drawDataBlock`, `drawCounterClassic` and `paintInstance`
// (`Counter.java:156-518`) are ported at the bottom of the class. `CounterPoker.paint`, the red
// edit caret, upstream's only `CounterPoker` override, lives in `CounterPoker.swift`. See
// `MemPainter.swift` for the paint seam.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

/// `com.cburch.logisim.std.memory.Counter`.
public final class Counter: InstanceFactoryBase {
  /// `Counter._ID`. Do NOT change; it is the `.circ` factory-name token.
  public static let id = "Counter"

  static let onGoalWrap = AttributeOption(value: "wrap")
  static let onGoalStay = AttributeOption(value: "stay")
  static let onGoalContinue = AttributeOption(value: "continue")
  static let onGoalLoad = AttributeOption(value: "load")

  static let attrMax: Attribute<Int64> = Attributes.forHexLong("max")
  static let attrOnGoal: Attribute<AttributeOption> = Attributes.forOption(
    "ongoal", choices: [onGoalWrap, onGoalStay, onGoalContinue, onGoalLoad])

  // MARK: LABEL_LOC — see the file header and `Register.swift`'s.
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

  /// `Counter.DELAY`.
  private static let delay = 8
  private static let out = 0
  private static let dataIn = 1
  private static let clockPort = 2
  private static let clearPort = 3
  private static let loadPort = 4
  private static let upDownPort = 5
  private static let enablePort = 6
  private static let carryPort = 7

  public init() {
    super.init(Counter.id)
    // Java also calls `setOffsetBounds(Bounds.create(-30, -20, 30, 40))` here, but
    // `getOffsetBounds` is overridden below and always wins, making that call dead code, not
    // reproduced.
  }

  /// `setInstancePoker(CounterPoker.class)`: `RegisterPoker` plus a different caret.
  public override func makePoker() -> (any InstancePoker)? { CounterPoker() }

  public override func createAttributeSet() -> any AttributeSet {
    CounterAttributes()
  }

  public override func validateAttributeSet(_ attributes: any AttributeSet) throws {
    guard attributes is CounterAttributes else {
      throw ComponentError.wrongAttributeSet(factory: Counter.id)
    }
  }

  /// `Counter.getSymbolWidth(int)`.
  static func symbolWidth(_ nrOfBits: Int) -> Int {
    150 + ((nrOfBits - 8) / 5) * 10
  }

  public override func offsetBounds(_ attributes: any AttributeSet) -> Bounds {
    let width = (attributes.getValue(StdAttr.width) ?? BitWidth.known(8)).width
    if attributes.getValue(StdAttr.appearance) == StdAttr.appearClassic {
      return Bounds.create(-30, -20, 30, 40)
    }
    return Bounds.create(0, 0, Counter.symbolWidth(width) + 40, 110 + 20 * width)
  }

  public override func ports(_ attributes: any AttributeSet) -> [Port] {
    let width = (attributes.getValue(StdAttr.width) ?? BitWidth.known(8)).width
    var ps = [Port](repeating: Port(0, 0, .input, 1), count: 8)
    if attributes.getValue(StdAttr.appearance) == StdAttr.appearClassic {
      ps[Counter.out] = Port(0, 0, .output, StdAttr.width)
      ps[Counter.dataIn] = Port(-30, 0, .input, StdAttr.width)
      ps[Counter.clockPort] = Port(-20, 20, .input, 1)
      ps[Counter.clearPort] = Port(-10, 20, .input, 1)
      ps[Counter.loadPort] = Port(-30, -10, .input, 1)
      ps[Counter.upDownPort] = Port(-20, -20, .input, 1)
      ps[Counter.enablePort] = Port(-30, 10, .input, 1)
      ps[Counter.carryPort] = Port(0, 10, .output, 1)
    } else {
      if width == 1 {
        ps[Counter.out] = Port(Counter.symbolWidth(width) + 40, 120, .output, StdAttr.width)
        ps[Counter.dataIn] = Port(0, 120, .input, StdAttr.width)
      } else {
        ps[Counter.out] = Port(Counter.symbolWidth(width) + 40, 110, .output, StdAttr.width)
        ps[Counter.dataIn] = Port(0, 110, .input, StdAttr.width)
      }
      ps[Counter.clockPort] = Port(0, 80, .input, 1)
      ps[Counter.clearPort] = Port(0, 20, .input, 1)
      ps[Counter.loadPort] = Port(0, 30, .input, 1)
      ps[Counter.upDownPort] = Port(0, 50, .input, 1)
      ps[Counter.enablePort] = Port(0, 70, .input, 1)
      ps[Counter.carryPort] = Port(40 + Counter.symbolWidth(width), 50, .output, 1)
    }
    return ps
  }

  public override func propagate(_ state: any InstanceState) throws {
    let dataWidth = state.attributeValue(StdAttr.width, default: BitWidth.known(8))

    let data: RegisterData
    if let existing = state.data as? RegisterData {
      data = existing
    } else {
      data = RegisterData(width: dataWidth)
      state.setData(data)
    }

    let triggerType = state.attributeValue(StdAttr.edgeTrigger)
    let maxValue = UInt64(bitPattern: state.attributeValue(Counter.attrMax, default: 0xFF))
    let triggered = data.clock.updateClock(state.portValue(Counter.clockPort), trigger: triggerType)

    let newValue: Value
    let carry: Bool

    if state.portValue(Counter.clearPort) == .trueValue {
      newValue = Value.createKnown(dataWidth, 0)
      carry = false
    } else {
      let load = state.portValue(Counter.loadPort) == .trueValue
      let enabled = state.portValue(Counter.enablePort) != .falseValue
      let upCount = state.portValue(Counter.upDownPort) != .falseValue
      let oldValue = data.value
      // `Value.toLongValue()`'s bit pattern read as unsigned magnitude is exactly what Java's
      // `Long.toUnsignedString(...)` → `BigInteger` conversion produces.
      let oldMagnitude = UInt64(bitPattern: oldValue.toLongValue())
      let loadMagnitude = UInt64(bitPattern: state.portValue(Counter.dataIn).toLongValue())

      var newMagnitude: UInt64?
      if !triggered {
        newMagnitude = oldMagnitude
      } else if load {
        var clamped = loadMagnitude
        if clamped > maxValue { clamped &= maxValue }
        newMagnitude = clamped
      } else if !oldValue.isFullyDefined() {
        newMagnitude = nil
      } else if enabled {
        let goal = upCount ? maxValue : 0
        if oldMagnitude == goal {
          let onGoal = state.attributeValue(Counter.attrOnGoal)
          if onGoal == Counter.onGoalWrap {
            newMagnitude = upCount ? 0 : maxValue
          } else if onGoal == Counter.onGoalStay {
            newMagnitude = oldMagnitude
          } else if onGoal == Counter.onGoalLoad {
            var clamped = loadMagnitude
            if clamped > maxValue { clamped &= maxValue }
            newMagnitude = clamped
          } else if onGoal == Counter.onGoalContinue {
            // BigInteger.add(ONE)/.subtract(ONE) then `.longValue()` truncates to the low 64
            // bits, which is exactly `&+`/`&-` on a `UInt64`: no clamping to `max` here, only
            // to the value's own bit width (applied later by `Value.createKnown`).
            newMagnitude = upCount ? oldMagnitude &+ 1 : oldMagnitude &- 1
          } else {
            // Java: `logger.error(...)`; no logging sink in the kernel (D9), so not reproduced.
            // `load` is always `false` on this path (we are past the `else if (load)` branch
            // above), so this reproduces Java's `load ? max : 0` as the constant `0`.
            newMagnitude = 0
          }
        } else {
          newMagnitude = upCount ? oldMagnitude &+ 1 : oldMagnitude &- 1
        }
      } else {
        newMagnitude = oldMagnitude
      }

      guard let resolvedMagnitude = newMagnitude else {
        // ── UPSTREAM BUG, PRESERVED ──────────────────────────────────────────────────────────
        // `Counter.propagate` computes `newValue` from a possibly-null `BigInteger newVal`
        // (the branch above, taken when the counter's own stored value has gone
        // not-fully-defined), but the very next line reads `newVal.compareTo(compVal)`
        // UNCONDITIONALLY; a `NullPointerException` when `newVal` is null. `Simulator.java`
        // wraps propagation in `catch (Exception)` (D13), so this throws rather than traps,
        // turning it into a circuit error the user sees, exactly as upstream's crash does.
        // Reachable when `Memory_Startup_Unknown` is enabled and the counter is clocked before
        // ever being loaded or cleared; not reachable via this port *today* because that
        // preference is hardcoded `false` (see `RegisterData.init`); preserved for when it is
        // wired up. Note Java's `data.value`/`state.setPort` calls that would otherwise follow
        // never run either, so (like Java) this component stays in the same broken state on
        // every subsequent propagation until cleared or loaded.
        throw CounterError.undefinedValueDuringPropagation
      }
      newValue = Value.createKnown(dataWidth, Int64(bitPattern: resolvedMagnitude))
      let compare = upCount ? maxValue : 0
      carry = resolvedMagnitude == compare
    }

    data.value = newValue
    state.setPort(Counter.out, newValue, Counter.delay)
    state.setPort(Counter.carryPort, carry ? .trueValue : .falseValue, Counter.delay)
  }

  // MARK: - Painting (M6)

  /// `Counter.paintInstance(InstancePainter)` (`Counter.java:501-518`).
  public func paintInstance(_ painter: any MemPainter) {
    if painter.attributeValue(StdAttr.appearance) == StdAttr.appearClassic {
      drawCounterClassic(painter)
      return
    }
    let xpos = painter.location.x
    let ypos = painter.location.y
    painter.drawLabel()

    drawControl(painter, xpos, ypos)
    let width = painter.attributeValue(StdAttr.width)?.width ?? 8
    for bit in 0..<width {
      drawDataBlock(painter, xpos, ypos + 110, bit, width)
    }
  }

  /// `Counter.drawControl(InstancePainter, int, int)` (`Counter.java:156-283`): the IEC control
  /// block: the notched outline, the two clock triangles, the R/M1/M2/M3/M4/G5 dependency
  /// labels, the carry outputs, and the live count readout.
  private func drawControl(_ painter: any MemPainter, _ xpos: Int, _ ypos: Int) {
    let g = painter.graphics
    g.strokeWidth = 2
    let width = painter.attributeValue(StdAttr.width)?.width ?? 8
    let symbolWidth = Counter.symbolWidth(width)

    let topX = [
      xpos + 30, xpos + 30, xpos + 20, xpos + 20,
      xpos + 20 + symbolWidth, xpos + 20 + symbolWidth,
      xpos + 10 + symbolWidth, xpos + 10 + symbolWidth,
    ]
    let topY = [
      ypos + 110, ypos + 100, ypos + 100, ypos,
      ypos, ypos + 100, ypos + 100, ypos + 110,
    ]
    g.color = MemPaint.componentColor
    g.drawPolyline(topX, topY)

    // Upstream's own comment: "These are up here because they reset the width to 1 when done."
    painter.drawClockSymbol(xpos + 20, ypos + 80)
    painter.drawClockSymbol(xpos + 20, ypos + 90)

    let maxValue = painter.attributeValue(Counter.attrMax, default: 0)
    var isCTRm = maxValue == (painter.attributeValue(StdAttr.width)?.mask ?? BitWidth.known(8).mask)
    isCTRm = isCTRm || painter.attributeValue(Counter.attrOnGoal) == Counter.onGoalContinue
    let label = isCTRm ? "CTR\(width)" : "CTR DIV0x" + MemPaint.longHexString(maxValue)
    g.drawCenteredText(label, x: xpos + (symbolWidth / 2) + 20, y: ypos + 5)
    g.strokeWidth = MemPaint.controlWidth

    // Reset
    g.drawLine(xpos, ypos + 20, xpos + 20, ypos + 20)
    g.drawText("R", x: xpos + 30, y: ypos + 20, halign: .left, valign: .center)
    painter.drawPort(Counter.clearPort)

    // Load
    g.drawLine(xpos, ypos + 30, xpos + 20, ypos + 30)
    g.drawLine(xpos + 5, ypos + 40, xpos + 12, ypos + 40)
    g.drawLine(xpos + 5, ypos + 30, xpos + 5, ypos + 40)
    g.drawOval(xpos + 12, ypos + 36, 8, 8)
    g.fillOval(xpos + 2, ypos + 27, 6, 6)
    painter.drawPort(Counter.loadPort)
    g.drawText("M2 [count]", x: xpos + 30, y: ypos + 40, halign: .left, valign: .center)
    g.drawText("M1 [load]", x: xpos + 30, y: ypos + 30, halign: .left, valign: .center)

    // Up/down
    g.drawLine(xpos, ypos + 50, xpos + 20, ypos + 50)
    g.drawLine(xpos + 5, ypos + 60, xpos + 12, ypos + 60)
    g.drawLine(xpos + 5, ypos + 50, xpos + 5, ypos + 60)
    g.drawOval(xpos + 12, ypos + 56, 8, 8)
    g.fillOval(xpos + 2, ypos + 47, 6, 6)
    g.drawText("M3 [up]", x: xpos + 30, y: ypos + 50, halign: .left, valign: .center)
    g.drawText("M4 [down]", x: xpos + 30, y: ypos + 60, halign: .left, valign: .center)
    painter.drawPort(Counter.upDownPort)

    // Enable
    g.drawLine(xpos, ypos + 70, xpos + 20, ypos + 70)
    g.drawText("G5", x: xpos + 30, y: ypos + 70, halign: .left, valign: .center)
    painter.drawPort(Counter.enablePort)

    // Clock. `StdAttr.EDGE_TRIGGER`, not `StdAttr.TRIGGER`: a counter has no level-triggered
    // mode, so only FALLING negates.
    let inverted = painter.attributeValue(StdAttr.edgeTrigger) == StdAttr.triggerFalling
    let xend = inverted ? xpos + 12 : xpos + 20
    g.drawLine(xpos, ypos + 80, xend, ypos + 80)
    g.drawLine(xpos + 5, ypos + 90, xend, ypos + 90)
    g.drawLine(xpos + 5, ypos + 80, xpos + 5, ypos + 90)
    g.fillOval(xpos + 2, ypos + 77, 6, 6)
    if inverted {
      g.drawOval(xend, ypos + 76, 8, 8)
      g.drawOval(xend, ypos + 86, 8, 8)
    }
    g.drawText("2,3,5+/C6", x: xpos + 30, y: ypos + 80, halign: .left, valign: .center)
    g.drawText("2,4,5-", x: xpos + 30, y: ypos + 90, halign: .left, valign: .center)
    painter.drawPort(Counter.clockPort)

    // Carry
    g.drawLine(xpos + 20 + symbolWidth, ypos + 50, xpos + 40 + symbolWidth, ypos + 50)
    g.drawLine(xpos + 20 + symbolWidth, ypos + 60, xpos + 35 + symbolWidth, ypos + 60)
    g.drawLine(xpos + 35 + symbolWidth, ypos + 50, xpos + 35 + symbolWidth, ypos + 60)
    g.fillOval(xpos + 32 + symbolWidth, ypos + 47, 6, 6)
    let maxLabel = "3CT=0x" + MemPaint.longHexString(maxValue).uppercased()
    g.drawText(maxLabel, x: xpos + 17 + symbolWidth, y: ypos + 50, halign: .right, valign: .center)
    g.drawText("4CT=0", x: xpos + 17 + symbolWidth, y: ypos + 60, halign: .right, valign: .center)
    painter.drawPort(Counter.carryPort)

    // Live count. Absent state, the toolbar, or before the first tick, draws nothing here,
    // exactly as upstream's `painter.getShowState() && (state != null)` guard does.
    if painter.showState, let state = painter.data as? RegisterData {
      let len = (width + 3) / 4
      let xcenter = Counter.symbolWidth(width) - 25
      let val = state.value
      if val.isFullyDefined() {
        g.color = MemPaint.lightGray
      } else if val.isErrorValue() {
        g.color = MemPaint.red
      } else {
        g.color = MemPaint.blue
      }
      g.fillRect(xpos + xcenter - len * 4, ypos + 22, len * 8, 16)
      var value = ""
      if val.isFullyDefined() {
        g.color = MemPaint.darkGray
        value = MemPaint.hexString(bits: width, value: val.toLongValue()).uppercased()
      } else {
        g.color = MemPaint.yellow
        // Upstream sizes the placeholder run by the *hex* rendering's length and then fills it
        // with one repeated character. Transcribed rather than simplified to `len`, because
        // `toHexString` is what it actually calls.
        let digits = MemPaint.hexString(bits: width, value: val.toLongValue()).count
        value = String(repeating: val.isUnknown() ? "?" : "!", count: digits)
      }
      g.drawText(
        value, x: xpos + xcenter - len * 4 + 1, y: ypos + 30, halign: .left, valign: .center)
      g.color = MemPaint.componentColor
    }
  }

  /// `Counter.drawDataBlock(InstancePainter, int, int, int, int)` (`Counter.java:285-412`): one
  /// 20-high stage box per bit, with its bus ladder and stored bit.
  private func drawDataBlock(
    _ painter: any MemPainter, _ xpos: Int, _ ypos: Int, _ bitNr: Int, _ nrOfBits: Int
  ) {
    let realYpos = ypos + bitNr * 20
    let first = bitNr == 0
    let last = bitNr == (nrOfBits - 1)
    let g = painter.graphics
    let symbolWidth = Counter.symbolWidth(nrOfBits)

    let font = g.font
    g.font = MemPaint.derive(font, size: 7)
    g.strokeWidth = 2
    g.drawRect(xpos + 20, realYpos, symbolWidth, 20)

    if nrOfBits > 1 {
      g.drawPolyline(
        [xpos + 5, xpos + 10, xpos + 20], [realYpos + 5, realYpos + 10, realYpos + 10])
      g.drawPolyline(
        [xpos + 20 + symbolWidth, xpos + 30 + symbolWidth, xpos + 35 + symbolWidth],
        [realYpos + 10, realYpos + 10, realYpos + 5])
    } else {
      g.drawLine(xpos, realYpos + 10, xpos + 20, realYpos + 10)
      g.drawLine(xpos + 20 + symbolWidth, realYpos + 10, xpos + 40 + symbolWidth, realYpos + 10)
    }

    g.color = MemPaint.componentColor
    if nrOfBits > 1 {
      g.drawText(
        String(bitNr), x: xpos + 30 + symbolWidth, y: realYpos + 8, halign: .right,
        valign: .baseline)
      g.drawText(String(bitNr), x: xpos + 10, y: realYpos + 8, halign: .left, valign: .baseline)
    }
    // The 7pt font covers only the bit-index captions; "1,6D" and the readout below are drawn
    // at the inherited size, because upstream restores the font here and not at the end.
    g.font = font
    g.drawText("1,6D", x: xpos + 21, y: realYpos + 10, halign: .left, valign: .center)

    g.strokeWidth = (nrOfBits == 1) ? MemPaint.dataSingleWidth : MemPaint.dataMultiWidth
    g.color = MemPaint.multiColor
    if first {
      painter.drawPort(Counter.dataIn)
      painter.drawPort(Counter.out)
      if nrOfBits > 1 {
        g.drawPolyline([xpos, xpos + 5, xpos + 5], [realYpos, realYpos + 5, realYpos + 20])
        g.drawPolyline(
          [xpos + 35 + symbolWidth, xpos + 35 + symbolWidth, xpos + 40 + symbolWidth],
          [realYpos + 20, realYpos + 5, realYpos])
      }
    } else if last {
      g.drawLine(xpos + 5, realYpos, xpos + 5, realYpos + 5)
      g.drawLine(xpos + 35 + symbolWidth, realYpos, xpos + 35 + symbolWidth, realYpos + 5)
    } else {
      g.drawLine(xpos + 5, realYpos, xpos + 5, realYpos + 20)
      g.drawLine(xpos + 35 + symbolWidth, realYpos, xpos + 35 + symbolWidth, realYpos + 20)
    }
    g.strokeWidth = 1

    if painter.showState, let state = painter.data as? RegisterData {
      let val = state.value
      let width = painter.attributeValue(StdAttr.width)?.width ?? 8
      let xcenter = (Counter.symbolWidth(width) / 2) + 10
      var value = ""
      if val.isFullyDefined() {
        g.color = MemPaint.lightGray
        // `((1L << bitNr) & val.toLongValue()) != 0`. `javaLongBit` reproduces Java's
        // shift-distance masking, which is what keeps bit 64 of a 64-bit counter behaving as
        // Java's does rather than trapping.
        value = (javaLongBit(bitNr) & val.toLongValue()) != 0 ? "1" : "0"
      } else if val.isUnknown() {
        g.color = MemPaint.blue
        value = "?"
      } else {
        g.color = MemPaint.red
        value = "!"
      }
      g.fillRect(xpos + xcenter + 16, realYpos + 4, 8, 16)
      g.color = val.isFullyDefined() ? MemPaint.darkGray : MemPaint.yellow
      g.drawText(value, x: xpos + xcenter + 20, y: realYpos + 10, halign: .center, valign: .center)
      g.color = MemPaint.componentColor
    }
  }

  /// `Counter.drawCounterClassic(InstancePainter)` (`Counter.java:441-499`).
  func drawCounterClassic(_ painter: any MemPainter) {
    let g = painter.graphics
    let bds = painter.bounds
    let state = painter.data as? RegisterData
    let width = painter.attributeValue(StdAttr.width)?.width ?? 8

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
      a = MemPaintStrings.counterLabel
      b = MemPaintStrings.registerWidthLabel(width)
    }

    g.color = MemPaint.componentColor
    painter.drawBounds()
    painter.drawLabel()

    if b == nil {
      painter.drawPort(Counter.dataIn, "D", .east)
      painter.drawPort(Counter.out, "Q", .west)
    } else {
      painter.drawPort(Counter.dataIn)
      painter.drawPort(Counter.out)
    }
    g.color = MemPaint.componentSecondaryColor
    painter.drawPort(Counter.loadPort)
    painter.drawPort(Counter.upDownPort)
    painter.drawPort(Counter.carryPort)
    painter.drawPort(Counter.clearPort, "0", .south)
    painter.drawPort(Counter.enablePort, MemPaintStrings.counterEnableLabel, .east)
    g.color = MemPaint.componentColor
    painter.drawClock(Counter.clockPort, .north)

    if let b {
      g.drawText(a, x: bds.x + 15, y: bds.y + 3, halign: .center, valign: .top)
      g.drawText(b, x: bds.x + 15, y: bds.y + 15, halign: .center, valign: .top)
    } else {
      g.drawText(a, x: bds.x + 15, y: bds.y + 4, halign: .center, valign: .top)
    }
  }

  // MARK: - Label placement

  /// `instance.setTextField(StdAttr.LABEL, StdAttr.LABEL_FONT, bds.getX() + bds.getWidth() / 2,
  /// bds.getY() - 3, GraphicsUtil.H_CENTER, GraphicsUtil.V_BASELINE)`: Counter.java:142, inside
  /// `configurePorts`, which `configureNewInstance` calls.
  ///
  /// **Known divergence from 4.1.0, and it is upstream that is inconsistent, not this.** Counter
  /// is the one memory factory that installs its label field *twice*, through both upstream
  /// entry points, and the two disagree:
  ///
  ///   * `configurePorts` → `setTextField(cx, bds.y - 3, H_CENTER, V_BASELINE)` (Counter.java:142)
  ///   * `instanceAttributeChanged` → `computeLabelTextField(AVOID_SIDES)` (Counter.java:436, :438)
  ///     which, for the default `LABEL_LOC == NORTH` and no `StdAttr.FACING`, resolves to
  ///     `(cx, bds.y - 2, H_CENTER, V_BOTTOM)`: one pixel lower and a different baseline rule.
  ///
  /// So in 4.1.0 a freshly placed counter's label sits at `-3`/`V_BASELINE`, and the *first*
  /// change to `WIDTH`, `APPEARANCE` or `LABEL_LOC` silently moves it to `-2`/`V_BOTTOM`, where
  /// it stays. That is path-dependent state, which this port's model deliberately cannot
  /// express: `labelPlacement` is a pure function of the attributes and the location, precisely
  /// so drawing and editing cannot drift. The fresh-placement value is transcribed here because
  /// it is the one a counter has until the user touches an attribute, and it is what the
  /// edit-parity gate exercises.
  ///
  /// **DECIDED 2026-09-06 (integrator, board #78); this is settled, not open.** It falls under
  /// D18's *fix* clause on both counts, so unifying is correct rather than merely convenient:
  ///
  ///   * **Unobservable in any gate.** A label's placement is *derived*, never serialised: no
  ///     `.circ` byte anywhere encodes it: so `canonical`, `migration` and the edit-parity gate
  ///     are all blind to the difference. There is no jar oracle for drawing (the same reason
  ///     `CircuitAnalysis.swift`'s header gives), so no measurement can prefer one over the other.
  ///   * **Upstream's version is path-dependent**, which D18 treats the same way it treats
  ///     `Location.create`'s allocation-order `hasToSnap` (D14): two identical counters draw their
  ///     labels one pixel apart depending on whether anyone ever touched `WIDTH`. There is no
  ///     behaviour to be faithful *to*, because upstream has two and picks by edit history.
  ///
  /// The residual divergence is one pixel and a baseline rule, on a counter whose width has been
  /// changed. Revisit only if a raster comparison against the jar is ever built; that is the one
  /// instrument that could see this, and until it exists the choice cannot be measured, only
  /// argued.
  public func labelPlacement(_ painter: InstancePainter) -> LabelPlacement? {
    let bds = painter.bounds
    return LabelPlacement(
      x: bds.x + bds.width / 2, y: bds.y - 3, halign: .center, valign: .baseline)
  }
}

extension Counter: InstanceLabelProvider {}

/// D13: mirrors the `NullPointerException` documented at the `propagate` call site above.
enum CounterError: Error, CustomStringConvertible, Sendable {
  case undefinedValueDuringPropagation

  var description: String {
    "Counter: cannot compute carry from an undefined stored value"
  }
}

/// `com.cburch.logisim.std.memory.CounterAttributes`.
///
/// **Deviation (mechanism).** Upstream delegates to an inner `AttributeSets.fixedSet` `base` and
/// intercepts `setValue`/`attributesMayAlsoBeChanged` for the width↔max cross-attribute
/// relationship. This port stores each attribute as an explicit field instead (`GateAttributes`'
/// shape, `PATTERNS.md` §5), which is equivalent because nothing outside this class ever reads
/// `base` directly.
private final class CounterAttributes: AbstractAttributeSet {
  private static let attributeList: [AnyAttribute] = [
    StdAttr.width, Counter.attrMax, Counter.attrOnGoal, StdAttr.edgeTrigger,
    StdAttr.label, StdAttr.labelFont, Counter.labelLocation, Register.attrShowInTab,
    StdAttr.appearance,
  ]

  var width: BitWidth = BitWidth.known(8)
  var maxValue: Int64 = 0xFF
  var onGoal: AttributeOption = Counter.onGoalWrap
  var triggerType: AttributeOption = StdAttr.triggerRising
  var label: String = ""
  var labelFont: FontSpec = StdAttr.defaultLabelFont
  var labelLocation: AttributeOption = Counter.labelLocationNorth
  var showInTab: Bool = false
  // `AppPreferences.getDefaultAppearance()`'s compiled default; see `AbstractFlipFlop.swift`.
  var appearance: AttributeOption = StdAttr.appearEvolution

  override var attributes: [AnyAttribute] { Self.attributeList }

  override func rawValue(_ attribute: AnyAttribute) -> AttributeValue? {
    if attribute === StdAttr.width { return StdAttr.width.encode(width) }
    if attribute === Counter.attrMax { return Counter.attrMax.encode(maxValue) }
    if attribute === Counter.attrOnGoal { return .option(onGoal) }
    if attribute === StdAttr.edgeTrigger { return .option(triggerType) }
    if attribute === StdAttr.label { return StdAttr.label.encode(label) }
    if attribute === StdAttr.labelFont { return StdAttr.labelFont.encode(labelFont) }
    if attribute === Counter.labelLocation { return .option(labelLocation) }
    if attribute === Register.attrShowInTab { return Register.attrShowInTab.encode(showInTab) }
    if attribute === StdAttr.appearance { return .option(appearance) }
    return nil
  }

  /// `CounterAttributes.setValue(Attribute<V>, V)`.
  override func setRawValue(_ attribute: AnyAttribute, _ newValue: AttributeValue?) throws {
    let oldRaw = rawValue(attribute)
    // Java: `if (Objects.equals(oldValue, value)) return;`: a uniform no-op guard for every
    // attribute, checked before any of the width↔max cross-attribute logic below.
    if newValue == oldRaw { return }

    if attribute === StdAttr.width {
      guard let newWidth = newValue.flatMap(StdAttr.width.decode) else { throw badValue(attribute) }
      let oldWidth = width
      let mask = newWidth.mask
      let oldMax = maxValue
      let newMax = (newWidth.width < oldWidth.width) ? (mask & oldMax) : mask
      if oldMax != newMax {
        maxValue = newMax
        fireAttributeValueChanged(
          Counter.attrMax, value: Counter.attrMax.encode(newMax),
          oldValue: Counter.attrMax.encode(oldMax))
      }
      width = newWidth
      fireAttributeValueChanged(attribute, value: newValue, oldValue: oldRaw)
      return
    }

    if attribute === Counter.attrMax {
      guard let requested = newValue.flatMap(Counter.attrMax.decode) else { throw badValue(attribute) }
      let masked = width.mask & requested
      let maskedRaw = Counter.attrMax.encode(masked)
      // Java's second guard, specific to `ATTR_MAX`: `newValue = width.getMask() & newValue; if
      // (Objects.equals(oldValue, newValue)) return;`; masking can turn a genuine change into
      // a no-op.
      if maskedRaw == oldRaw { return }
      maxValue = masked
      fireAttributeValueChanged(attribute, value: maskedRaw, oldValue: oldRaw)
      return
    }

    if attribute === Counter.attrOnGoal {
      guard case .option(let value)? = newValue else { throw badValue(attribute) }
      onGoal = value
    } else if attribute === StdAttr.edgeTrigger {
      guard case .option(let value)? = newValue else { throw badValue(attribute) }
      triggerType = value
    } else if attribute === StdAttr.label {
      guard let value = newValue.flatMap(StdAttr.label.decode) else { throw badValue(attribute) }
      label = value
    } else if attribute === StdAttr.labelFont {
      guard let value = newValue.flatMap(StdAttr.labelFont.decode) else { throw badValue(attribute) }
      labelFont = value
    } else if attribute === Counter.labelLocation {
      guard case .option(let value)? = newValue else { throw badValue(attribute) }
      labelLocation = value
    } else if attribute === Register.attrShowInTab {
      guard let value = newValue.flatMap(Register.attrShowInTab.decode) else {
        throw badValue(attribute)
      }
      showInTab = value
    } else if attribute === StdAttr.appearance {
      guard case .option(let value)? = newValue else { throw badValue(attribute) }
      appearance = value
    } else {
      throw AttributeSetError.attributeAbsent(name: attribute.name)
    }
    fireAttributeValueChanged(attribute, value: newValue, oldValue: oldRaw)
  }

  /// `CounterAttributes.attributesMayAlsoBeChanged(Attribute<V>, V)`.
  override func attributesMayAlsoBeChanged<V>(
    _ attribute: Attribute<V>, _ value: V?
  ) -> [AnyAttribute]? {
    guard attribute === StdAttr.width else { return nil }
    if value.map(attribute.encode) == rawValue(attribute) { return nil }
    return [Counter.attrMax]
  }

  private func badValue(_ attribute: AnyAttribute) -> ComponentError {
    .unsupportedAttributeValue(factory: Counter.id, attribute: attribute.name)
  }

  override func makeCopyInstance() -> AbstractAttributeSet { CounterAttributes() }

  override func copyInto(_ destination: AbstractAttributeSet) {
    guard let destination = destination as? CounterAttributes else { return }
    destination.width = width
    destination.maxValue = maxValue
    destination.onGoal = onGoal
    destination.triggerType = triggerType
    destination.label = label
    destination.labelFont = labelFont
    destination.labelLocation = labelLocation
    destination.showInTab = showInTab
    destination.appearance = appearance
  }
}
