// ShiftRegister.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.memory.{ShiftRegister,
// ShiftRegisterData}), https://github.com/logisim-evolution/logisim-evolution. Copyright by the
// Logisim-evolution developers. This translation is a derivative work and is therefore
// GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── Port width: fixed, not attribute-linked ─────────────────────────────────────────────────
//
// Unlike `Register`/`Counter` (which build ports with `Port(dx, dy, type, StdAttr.width)`, the
// *attribute-reference* constructor), upstream's `ShiftRegister.configurePorts` reads the
// numeric width once (`widthObj.getWidth()`) and builds every `Port` with the fixed-`int`
// constructor. Transcribed literally: every `Port` below takes a `BitWidth` value captured at
// the time `ports(_:)` runs, not `StdAttr.width` itself. This is behaviourally identical to the
// attribute-reference form here, because `StdInstanceComponent` recomputes `ports(_:)` in full
// on every attribute change (PATTERNS.md §0), so a `WIDTH` edit still lands promptly regardless
// of which form is used.
//
// ── `updateData`; not ported ───────────────────────────────────────────────────────────────
//
// Upstream's `instanceAttributeChanged` calls `updateData(instance)`, which reaches through
// `instance.getComponent().getInstanceStateImpl().getCircuitState()` to resize an
// *already-running* component's `ShiftRegisterData` immediately, so painting looks right before
// the next clock edge. `InstanceStateImpl`/`CircuitState` are simulation-module types this slice
// cannot see (`InstanceState.swift`'s header: `InstanceStateImpl` is installed by the simulation
// module). It has no effect on simulation *results*: `getData(state)` below calls
// `data.setDimensions(width, length)` unconditionally on **every** `propagate` regardless of
// whether `updateData` ran, so the resize happens on the very next propagation either way; the
// only user-visible difference is a paint/display staleness window between an attribute edit and
// the next clock tick, which is a D6/M6 concern, not a correctness one.
//
// ── Not ported ──────────────────────────────────────────────────────────────────────────────
//
//   * `ShiftRegisterPoker`, `ShiftRegisterLogger`: reflective poker/logger classes
//     (`InstanceFactory.swift` header).
//   * `getHDLName` (inherited default), `checkForGatedClocks`, `clockPinIndex`; HDL/FPGA
//     backlog (D11).
//   * `instanceAttributeChanged`; upstream's only branch calls `recomputeBounds`/
//     `configurePorts` (both automatic here, PATTERNS.md §0) and `updateData` (see above).
//
// ── PAINTING (M6) ───────────────────────────────────────────────────────────────────────────
//
// `drawControl`, `drawDataBlock`, `paintInstanceClassic`, `paintInstanceEvolution` and
// `paintInstance` (`ShiftRegister.java:155-490`) are ported at the bottom of the class. See
// `MemPainter.swift` for the paint seam.
//
// One deliberate divergence, in the CLASSIC readout: upstream calls `getData(painter)`, which
// **creates and stores** a `ShiftRegisterData` if the component has none yet: i.e. it mutates
// simulation state from inside a paint pass. D6 forbids that (the painter is not an
// `InstanceState` here, and a renderer must not be able to write component data). The port
// instead builds a throwaway `ShiftRegisterData` with the same constructor arguments and reads
// from it, which draws exactly the same glyphs, a freshly constructed one is all
// `Value.createKnown(width, 0)`, without the write.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

/// `com.cburch.logisim.std.memory.ShiftRegister`.
public final class ShiftRegister: InstanceFactoryBase {
  /// `ShiftRegister._ID`. Do NOT change; it is the `.circ` factory-name token.
  public static let id = "Shift Register"

  static let attrLength: Attribute<Int32> = Attributes.forIntegerRange(
    "length", start: 1, end: 64)
  static let attrLoad: Attribute<Bool> = Attributes.forBoolean("parallel")

  /// `ShiftRegister.symbolWidth`. Not `private`: `ShiftRegisterPoker.computeStage` reads it
  /// to hit-test the EVOLUTION stage boxes, exactly as upstream's poker does.
  static let symbolWidth = 100
  private static let in_ = 0
  private static let sh = 1
  private static let ck = 2
  private static let clr = 3
  private static let out = 4
  private static let ld = 5

  public init() {
    super.init(ShiftRegister.id)
    setAttributes([
      StdAttr.width.binding(.one),
      ShiftRegister.attrLength.binding(8),
      ShiftRegister.attrLoad.binding(true),
      StdAttr.edgeTrigger.binding(StdAttr.triggerRising),
      StdAttr.label.binding(""),
      StdAttr.labelFont.binding(StdAttr.defaultLabelFont),
      StdAttr.appearance.binding(StdAttr.appearEvolution),
    ])
  }

  /// `setInstancePoker(ShiftRegisterPoker.class)`.
  public override func makePoker() -> (any InstancePoker)? { ShiftRegisterPoker() }

  public override func offsetBounds(_ attributes: any AttributeSet) -> Bounds {
    let length = Int(attributes.getValue(ShiftRegister.attrLength) ?? 8)
    if attributes.getValue(StdAttr.appearance) == StdAttr.appearClassic {
      let parallel = attributes.getValue(ShiftRegister.attrLoad) ?? true
      return parallel
        ? Bounds.create(0, -20, 20 + 10 * length, 40)
        : Bounds.create(0, -20, 30, 40)
    }
    return Bounds.create(0, 0, ShiftRegister.symbolWidth + 20, 80 + 20 * length)
  }

  public override func ports(_ attributes: any AttributeSet) -> [Port] {
    let width = attributes.getValue(StdAttr.width) ?? .one
    let parallel = attributes.getValue(ShiftRegister.attrLoad) ?? true
    let length = Int(attributes.getValue(ShiftRegister.attrLength) ?? 8)
    let classic = attributes.getValue(StdAttr.appearance) == StdAttr.appearClassic

    var ps: [Port?]
    if classic {
      if parallel {
        ps = [Port?](repeating: nil, count: 6 + 2 * length)
        ps[ShiftRegister.ld] = Port(10, -20, .input, 1)
        for i in 0..<length {
          ps[6 + 2 * i] = Port(20 + 10 * i, -20, .input, width)
          ps[6 + 2 * i + 1] = Port(20 + 10 * i, 20, .output, width)
        }
      } else {
        ps = [Port?](repeating: nil, count: 5)
      }
      let classicOutX = parallel ? 20 + 10 * length : 30
      ps[ShiftRegister.out] = Port(classicOutX, 0, .output, width)
      ps[ShiftRegister.in_] = Port(0, 0, .input, width)
      ps[ShiftRegister.sh] = Port(0, -10, .input, 1)
      ps[ShiftRegister.ck] = Port(0, 10, .input, 1)
      ps[ShiftRegister.clr] = Port(10, 20, .input, 1)
    } else {
      if parallel {
        ps = [Port?](repeating: nil, count: 6 + 2 * length - 1)
        ps[ShiftRegister.ld] = Port(0, 30, .input, 1)
        for i in 0..<length {
          ps[6 + 2 * i] = Port(0, 90 + i * 20, .input, width)
          if i < length - 1 {
            ps[6 + 2 * i + 1] = Port(
              ShiftRegister.symbolWidth + 20, 90 + i * 20, .output, width)
          }
        }
      } else {
        ps = [Port?](repeating: nil, count: 5)
      }
      ps[ShiftRegister.out] = Port(
        ShiftRegister.symbolWidth + 20, 70 + length * 20, .output, width)
      ps[ShiftRegister.in_] = Port(0, 80, .input, width)
      ps[ShiftRegister.sh] = Port(0, 40, .input, 1)
      ps[ShiftRegister.ck] = Port(0, 50, .input, 1)
      ps[ShiftRegister.clr] = Port(0, 20, .input, 1)
    }

    // Every slot 0..<count is filled by exactly one assignment above: an internal invariant
    // of the index arithmetic (PATTERNS.md §3), not something a `.circ` file can violate.
    return ps.map { port in
      guard let port else { preconditionFailure("ShiftRegister.ports: unfilled port slot") }
      return port
    }
  }

  public override func propagate(_ state: any InstanceState) throws {
    let triggerType = state.attributeValue(StdAttr.edgeTrigger)
    let parallel = state.attributeValue(ShiftRegister.attrLoad, default: true)
    let data = shiftRegisterData(state)
    let length = data.length

    let triggered = data.clock.updateClock(state.portValue(ShiftRegister.ck), trigger: triggerType)
    if state.portValue(ShiftRegister.clr) == .trueValue {
      data.clear()
    } else if triggered {
      if parallel && state.portValue(ShiftRegister.ld) == .trueValue {
        data.clear()
        for i in stride(from: length - 1, through: 0, by: -1) {
          data.push(state.portValue(6 + 2 * i))
        }
      } else if state.portValue(ShiftRegister.sh) != .falseValue {
        data.push(state.portValue(ShiftRegister.in_))
      }
    }

    state.setPort(ShiftRegister.out, data.get(0), 4)
    if parallel {
      let classic = state.attributeValue(StdAttr.appearance) == StdAttr.appearClassic
      let nrOfBits = classic ? length : length - 1
      for i in 0..<nrOfBits {
        state.setPort(6 + 2 * i + 1, data.get(length - 1 - i), 4)
      }
    }
  }

  /// `ShiftRegister.getData(InstanceState)`.
  private func shiftRegisterData(_ state: any InstanceState) -> ShiftRegisterData {
    let width = state.attributeValue(StdAttr.width, default: .one)
    let length = Int(state.attributeValue(ShiftRegister.attrLength, default: 8))
    if let existing = state.data as? ShiftRegisterData {
      // Java calls `setDimensions` unconditionally here too, every propagation; see the file
      // header's note on why `updateData` is safe to drop.
      existing.setDimensions(width: width, length: length)
      return existing
    }
    let data = ShiftRegisterData(width: width, length: length)
    state.setData(data)
    return data
  }

  // MARK: - Painting (M6)

  /// `ShiftRegister.paintInstance(InstancePainter)` (`ShiftRegister.java:392-399`).
  public func paintInstance(_ painter: any MemPainter) {
    if painter.attributeValue(StdAttr.appearance) == StdAttr.appearClassic {
      paintInstanceClassic(painter)
    } else {
      paintInstanceEvolution(painter)
    }
  }

  /// `ShiftRegister.paintInstanceEvolution(InstancePainter)` (`ShiftRegister.java:401-425`).
  ///
  /// Upstream's own comment on the `data == null` branch: "In the case data is null we assume
  /// that the different value are null. This allow the user to instantiate the shift register
  /// without simulation mode." That is the toolbar / pre-first-tick case, and it draws the full
  /// symbol with empty stage boxes.
  func paintInstanceEvolution(_ painter: any MemPainter) {
    painter.drawLabel()
    let xpos = painter.location.x
    let ypos = painter.location.y
    let wid = painter.attributeValue(StdAttr.width, default: .one).width
    let len = Int(painter.attributeValue(ShiftRegister.attrLength, default: 8))
    let parallel = painter.attributeValue(ShiftRegister.attrLoad, default: true)
    let negEdge = painter.attributeValue(StdAttr.edgeTrigger) == StdAttr.triggerFalling
    drawControl(
      painter, xpos, ypos, nrOfStages: len, nrOfBits: wid, hasLoad: parallel,
      activeLowClock: negEdge)
    let data = painter.data as? ShiftRegisterData

    if let data {
      for stage in 0..<len {
        drawDataBlock(
          painter, xpos, ypos, nrOfStages: len, nrOfBits: wid, currentStage: stage,
          dataValue: data.get(len - stage - 1), hasLoad: parallel)
      }
    } else {
      for stage in 0..<len {
        drawDataBlock(
          painter, xpos, ypos, nrOfStages: len, nrOfBits: wid, currentStage: stage,
          dataValue: nil, hasLoad: parallel)
      }
    }
  }

  /// `ShiftRegister.drawControl(...)` (`ShiftRegister.java:155-215`); the SRGn control block.
  ///
  /// The clock row is the edge-trigger convention: the triangle at `(xpos + 10, ypos + 50)`,
  /// then either a straight stub into it (rising edge) or a 10x10 negation circle at
  /// `(xpos, ypos + 45)` (falling edge). The `"1→/C3"` dependency label beside it is upstream's
  /// literal `"1→/C3"`.
  private func drawControl(
    _ painter: any MemPainter, _ xpos: Int, _ ypos: Int, nrOfStages: Int, nrOfBits: Int,
    hasLoad: Bool, activeLowClock: Bool
  ) {
    let g = painter.graphics
    g.strokeWidth = 2
    let blockWidth = ShiftRegister.symbolWidth
    g.color = MemPaint.componentColor
    g.drawLine(xpos + 10, ypos, xpos + blockWidth + 10, ypos)
    g.drawLine(xpos + 10, ypos, xpos + 10, ypos + 60)
    g.drawLine(xpos + blockWidth + 10, ypos, xpos + blockWidth + 10, ypos + 60)
    g.drawLine(xpos + 10, ypos + 60, xpos + 20, ypos + 60)
    g.drawLine(xpos + blockWidth, ypos + 60, xpos + blockWidth + 10, ypos + 60)
    g.drawLine(xpos + 20, ypos + 60, xpos + 20, ypos + 70)
    g.drawLine(xpos + blockWidth, ypos + 60, xpos + blockWidth, ypos + 70)
    if nrOfBits > 1 {
      g.drawLine(xpos + blockWidth + 10, ypos + 5, xpos + blockWidth + 15, ypos + 5)
      g.drawLine(xpos + blockWidth + 15, ypos + 5, xpos + blockWidth + 15, ypos + 65)
      g.drawLine(xpos + blockWidth + 5, ypos + 65, xpos + blockWidth + 15, ypos + 65)
      g.drawLine(xpos + blockWidth + 5, ypos + 65, xpos + blockWidth + 5, ypos + 70)
      if nrOfBits > 2 {
        g.drawLine(xpos + blockWidth + 15, ypos + 10, xpos + blockWidth + 20, ypos + 10)
        g.drawLine(xpos + blockWidth + 20, ypos + 10, xpos + blockWidth + 20, ypos + 70)
        g.drawLine(xpos + blockWidth + 10, ypos + 70, xpos + blockWidth + 20, ypos + 70)
      }
    }
    g.drawCenteredText(
      "SRG\(nrOfStages)", x: xpos + (ShiftRegister.symbolWidth / 2) + 10, y: ypos + 5)

    // Clock
    painter.drawClockSymbol(xpos + 10, ypos + 50)
    g.strokeWidth = 2
    if activeLowClock {
      g.drawOval(xpos, ypos + 45, 10, 10)
    } else {
      g.drawLine(xpos, ypos + 50, xpos + 10, ypos + 50)
    }
    painter.drawPort(ShiftRegister.ck)
    g.drawText("1\u{2192}/C3", x: xpos + 20, y: ypos + 50, halign: .left, valign: .center)

    // Shift
    g.drawLine(xpos, ypos + 40, xpos + 10, ypos + 40)
    g.drawText("M1 [shift]", x: xpos + 20, y: ypos + 40, halign: .left, valign: .center)
    painter.drawPort(ShiftRegister.sh)

    // Load
    if hasLoad {
      g.drawLine(xpos, ypos + 30, xpos + 10, ypos + 30)
      g.drawText("M2 [load]", x: xpos + 20, y: ypos + 30, halign: .left, valign: .center)
      painter.drawPort(ShiftRegister.ld)
    }

    // Reset
    g.drawLine(xpos, ypos + 20, xpos + 10, ypos + 20)
    g.drawText("R", x: xpos + 20, y: ypos + 20, halign: .left, valign: .center)
    painter.drawPort(ShiftRegister.clr)
    g.strokeWidth = 1
  }

  /// `ShiftRegister.drawDataBlock(...)` (`ShiftRegister.java:217-350`): one stage box, its bus
  /// ladder, and (when there is state to show) its stored value.
  private func drawDataBlock(
    _ painter: any MemPainter, _ xpos: Int, _ ypos: Int, nrOfStages: Int, nrOfBits: Int,
    currentStage: Int, dataValue: Value?, hasLoad: Bool
  ) {
    var realYpos = ypos + 70 + currentStage * 20
    if currentStage > 0 { realYpos += 10 }
    let realXpos = xpos + 10
    let dataWidth = (nrOfBits == 1) ? 2 : 5
    let lineFix = (nrOfBits == 1) ? 1 : 2
    let componentColor = MemPaint.componentColor
    let inOutConnectionColor = (nrOfBits == 1) ? componentColor : MemPaint.multiColor
    let height = (currentStage == 0) ? 30 : 20
    let lastBlock = currentStage == (nrOfStages - 1)
    let blockWidth = ShiftRegister.symbolWidth
    let g = painter.graphics

    g.strokeWidth = 2
    g.drawRect(realXpos, realYpos, blockWidth, height)
    if nrOfBits > 1 {
      g.drawLine(realXpos + blockWidth, realYpos + 5, realXpos + blockWidth + 5, realYpos + 5)
      g.drawLine(
        realXpos + blockWidth + 5, realYpos + 5, realXpos + blockWidth + 5, realYpos + height + 5)
      if lastBlock {
        g.drawLine(
          realXpos + 5, realYpos + height + 5, realXpos + blockWidth + 5, realYpos + height + 5)
        g.drawLine(realXpos + 5, realYpos + height, realXpos + 5, realYpos + height + 5)
      }
      if nrOfBits > 2 {
        g.drawLine(
          realXpos + blockWidth + 5, realYpos + 10, realXpos + blockWidth + 10, realYpos + 10)
        g.drawLine(
          realXpos + blockWidth + 10, realYpos + 10, realXpos + blockWidth + 10,
          realYpos + height + 10)
        if lastBlock {
          g.drawLine(
            realXpos + 10, realYpos + height + 10, realXpos + blockWidth + 10,
            realYpos + height + 10)
          g.drawLine(realXpos + 10, realYpos + height + 5, realXpos + 10, realYpos + height + 10)
        }
      }
    }

    // Inputs
    if currentStage == 0 || hasLoad {
      g.strokeWidth = dataWidth
      g.color = inOutConnectionColor
      g.drawLine(realXpos - 10, realYpos + 10, realXpos - lineFix, realYpos + 10)
      g.color = componentColor
      if currentStage == 0 {
        painter.drawPort(ShiftRegister.in_)
        g.drawText("1,3D", x: realXpos + 1, y: realYpos + 10, halign: .left, valign: .center)
        if hasLoad {
          g.color = inOutConnectionColor
          g.drawLine(realXpos - 10, realYpos + 20, realXpos - lineFix, realYpos + 20)
          g.color = componentColor
          g.drawText("2,3D", x: realXpos + 1, y: realYpos + 20, halign: .left, valign: .center)
        }
      } else {
        g.drawText("2,3D", x: realXpos + 1, y: realYpos + 10, halign: .left, valign: .center)
      }

      if hasLoad { painter.drawPort(6 + 2 * currentStage) }
      g.strokeWidth = 1
    }
    g.strokeWidth = 1

    // Outputs
    g.strokeWidth = dataWidth
    g.color = inOutConnectionColor
    if hasLoad || lastBlock {
      if currentStage == 0 {
        g.drawLine(
          realXpos + blockWidth + lineFix, realYpos + 20, realXpos + blockWidth + 10, realYpos + 20)
      } else {
        g.drawLine(
          realXpos + blockWidth + lineFix, realYpos + 10, realXpos + blockWidth + 10, realYpos + 10)
      }
    }
    if lastBlock {
      painter.drawPort(ShiftRegister.out)
    } else if hasLoad {
      painter.drawPort(6 + 2 * currentStage + 1)
    }
    g.strokeWidth = 1

    // Stage value
    g.color = componentColor
    if painter.showState, let dataValue {
      if dataValue.isFullyDefined() {
        g.color = MemPaint.lightGray
      } else if dataValue.isErrorValue() {
        g.color = MemPaint.red
      } else {
        g.color = MemPaint.blue
      }
      let yoff = (currentStage == 0) ? 10 : 0
      let len = (nrOfBits + 3) / 4
      let boxXpos = ((blockWidth - 30) / 2 + 30) - (len * 4)
      g.fillRect(realXpos + boxXpos, realYpos + yoff + 2, 2 + len * 8, 16)
      let value: String
      if dataValue.isFullyDefined() {
        g.color = MemPaint.darkGray
        value = MemPaint.hexString(bits: nrOfBits, value: dataValue.toLongValue())
      } else {
        g.color = MemPaint.yellow
        value = dataValue.isUnknown() ? "?" : "!"
      }
      g.drawText(
        value, x: realXpos + boxXpos + 1, y: realYpos + yoff + 10, halign: .left, valign: .center)
      g.color = componentColor
    }
  }

  /// `ShiftRegister.paintInstanceClassic(InstancePainter)` (`ShiftRegister.java:427-490`).
  func paintInstanceClassic(_ painter: any MemPainter) {
    painter.drawBounds()
    painter.drawLabel()

    let parallel = painter.attributeValue(ShiftRegister.attrLoad, default: true)
    if parallel {
      let wid = painter.attributeValue(StdAttr.width, default: .one)
      let width = wid.width
      let len = Int(painter.attributeValue(ShiftRegister.attrLength, default: 8))
      if painter.showState {
        if width <= 4 {
          // See the file header: upstream's `getData(painter)` would *store* a fresh
          // `ShiftRegisterData` here; the throwaway draws the identical glyphs without the write.
          let data =
            (painter.data as? ShiftRegisterData)
            ?? ShiftRegisterData(width: wid, length: len)
          let bds = painter.bounds
          var x = bds.x + 20
          var y = bds.y
          let label = painter.attributeValue(StdAttr.label)
          if label == nil || label == "" {
            y += bds.height / 2
          } else {
            y += 3 * bds.height / 4
          }
          let g = painter.graphics
          for i in 0..<len {
            // `data.get(len - 1 - i) != null` is vacuously true here: the port's stage array is
            // `[Value]`, never `[Value?]`, because upstream fills it in the constructor.
            g.drawCenteredText(data.get(len - 1 - i).toHexString(), x: x, y: y)
            x += 10
          }
        }
      } else {
        let bds = painter.bounds
        let x = bds.x + bds.width / 2
        let y = bds.y
        let h = bds.height
        let g = painter.graphics
        let label = painter.attributeValue(StdAttr.label)
        if label == nil || label == "" {
          g.drawCenteredText(MemPaintStrings.shiftRegisterLabel1, x: x, y: y + h / 4)
        }
        g.drawCenteredText(
          MemPaintStrings.shiftRegisterLabel2(len, width), x: x, y: y + 3 * h / 4)
      }
    }

    // `painter.getInstance().getPorts().size()`. The port list is a pure function of the
    // attributes here (PATTERNS.md §0), so asking the factory for it is the same count.
    let portCount = ports(painter.attributeSet).count
    for i in 0..<portCount where i != ShiftRegister.ck {
      painter.drawPort(i)
    }
    painter.drawClock(ShiftRegister.ck, .east)
  }

  // MARK: - Label placement

  /// `instance.setTextField(StdAttr.LABEL, StdAttr.LABEL_FONT, bds.getX() + bds.getWidth() / 2,
  /// bds.getY() - 3, GraphicsUtil.H_CENTER, GraphicsUtil.V_BASELINE)`: ShiftRegister.java:146,
  /// inside `configurePorts`.
  ///
  /// This is the cleanest of the four `-3`/`V_BASELINE` cases: upstream calls `configurePorts`
  /// from both `configureNewInstance` (ShiftRegister.java:92) *and* `instanceAttributeChanged`
  /// (ShiftRegister.java:396), and never calls `computeLabelTextField`, so upstream's field is
  /// already a pure function of the current bounds; exactly what this returns.
  public func labelPlacement(_ painter: InstancePainter) -> LabelPlacement? {
    let bds = painter.bounds
    return LabelPlacement(
      x: bds.x + bds.width / 2, y: bds.y - 3, halign: .center, valign: .baseline)
  }
}

extension ShiftRegister: InstanceLabelProvider {}

/// `com.cburch.logisim.std.memory.ShiftRegisterData`.
///
/// **Deviation (mechanism).** Java: `extends ClockState implements InstanceData`; composition
/// (`clock: ClockState`) replaces inheritance, matching `ClockState.swift`'s own header note.
///
/// Serialisation ordering note (per this slice's task brief): `values[0]` is always the stage
/// about to be shifted out next (`get(0)` drives the `OUT` port); `pos` is the circular buffer's
/// write cursor, exactly as upstream's `vsPos`. Anything that persists this data must preserve
/// both `values` in array order and `pos`, not just the logical stage contents.
final class ShiftRegisterData: InstanceData {
  var clock = ClockState()
  private var width: BitWidth
  private var values: [Value]
  private var pos: Int = 0

  init(width: BitWidth, length: Int) {
    self.width = width
    // `AppPreferences.Memory_Startup_Unknown` defaults to `false`, see `AbstractFlipFlop.swift`.
    self.values = [Value](repeating: Value.createKnown(width, 0), count: length)
  }

  var length: Int { values.count }

  func clear() {
    values = [Value](repeating: Value.createKnown(width, 0), count: values.count)
    pos = 0
  }

  func get(_ index: Int) -> Value {
    var i = pos + index
    if i >= values.count { i -= values.count }
    return values[i]
  }

  func push(_ v: Value) {
    let p = pos
    values[p] = v
    pos = p >= values.count - 1 ? 0 : p + 1
  }

  func set(_ index: Int, _ val: Value) {
    var i = pos + index
    if i >= values.count { i -= values.count }
    values[i] = val
  }

  /// `ShiftRegisterData.setDimensions(BitWidth, int)`.
  func setDimensions(width newWidth: BitWidth, length newLength: Int) {
    if values.count != newLength {
      var newValues = [Value](repeating: Value.createKnown(newWidth, 0), count: newLength)
      var j = pos
      let copyCount = min(newLength, values.count)
      for i in 0..<copyCount {
        newValues[i] = values[j]
        j += 1
        if j == values.count { j = 0 }
      }
      values = newValues
      pos = 0
    }
    if width.width != newWidth.width {
      for i in values.indices where values[i].width != newWidth.width {
        values[i] = values[i].extendWidth(newWidth.width, .falseValue)
      }
      width = newWidth
    }
  }

  func cloneData() -> any InstanceData {
    let copy = ShiftRegisterData(width: width, length: values.count)
    copy.values = values
    copy.pos = pos
    copy.clock = clock
    return copy
  }
}
