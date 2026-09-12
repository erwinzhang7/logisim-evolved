// RandomGenerator.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.memory.Random, and its inner
// `Random.StateData`), https://github.com/logisim-evolution/logisim-evolution. Copyright by the
// Logisim-evolution developers. This translation is a derivative work and is therefore
// GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// The public type is named `Random`, matching Java exactly (`MemoryLibrary.swift`, landing
// concurrently from a sibling slice, already references it as `Random()`); only the *file* is
// named `RandomGenerator.swift`, per this slice's file-ownership list.
//
// ── The LCG must match bit-for-bit ──────────────────────────────────────────────────────────
//
// `StateData` reproduces `java.util.Random`'s classic 48-bit linear congruential generator
// literally: same multiplier/addend/mask constants, same `& MASK` after every step, same
// truncation to `int`. A saved simulation's random sequence is observable (test vectors, replay,
// a user comparing runs), so a "cleaner" RNG here would be a *wrong* RNG, not an improvement.
//
// ── JAVA QUIRK, preserved: seed-0 non-determinism, and the field-ordering read ─────────────────
//
// `getRandomSeed`, when the seed attribute is `0` (its default), draws a *fresh* sequence from
// the wall clock (`System.currentTimeMillis()`) every run; a `Random` component left at its
// default seed is non-deterministic in Java and is exactly as non-deterministic here. See
// `randomSeed(_:)` below for the second, subtler quirk: the constructor's very first call to
// `getRandomSeed` reads `this.initSeed` before that field has ever been assigned, i.e. Java's
// default `0`, not the value the call is about to produce.
//
// ── Not ported ──────────────────────────────────────────────────────────────────────────────
//
//   * `Random.Logger`: reflective logger class (`InstanceFactory.swift` header).
//   * `checkForGatedClocks`, `clockPinIndex`; HDL/FPGA backlog (D11).
//   * `instanceAttributeChanged`; upstream's only branch calls `recomputeBounds`/`updatePorts`,
//     both automatic here (PATTERNS.md §0).
//
// ── PAINTING (M6) ───────────────────────────────────────────────────────────────────────────
//
// `drawControl`, `drawData`, `paintInstanceClassic`, `paintInstanceEvolution` and
// `paintInstance` (`Random.java:209-329`) are ported at the bottom of the class. See
// `MemPainter.swift` for the paint seam.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

/// `com.cburch.logisim.std.memory.Random`.
public final class Random: InstanceFactoryBase {
  /// `Random._ID`. Do NOT change; it is the `.circ` factory-name token.
  public static let id = "Random"

  static let attrSeed: Attribute<Int32> = Attributes.forInteger("seed")

  private static let out = 0
  private static let ck = 1
  private static let nxt = 2
  private static let rst = 3

  public init() {
    super.init(Random.id, displayName: "Random Generator")
    setAttributes([
      StdAttr.width.binding(BitWidth.known(8)),
      Random.attrSeed.binding(0),
      StdAttr.edgeTrigger.binding(StdAttr.triggerRising),
      StdAttr.label.binding(""),
      StdAttr.labelFont.binding(StdAttr.defaultLabelFont),
      StdAttr.appearance.binding(StdAttr.appearEvolution),
    ])
    // Java also calls `setOffsetBounds(Bounds.create(0, 0, 80, 90))` here, but `getOffsetBounds`
    // is overridden below and always wins, making that call dead code, not reproduced.
  }

  public override func offsetBounds(_ attributes: any AttributeSet) -> Bounds {
    attributes.getValue(StdAttr.appearance) == StdAttr.appearClassic
      ? Bounds.create(0, 0, 40, 40)
      : Bounds.create(0, 0, 80, 90)
  }

  public override func ports(_ attributes: any AttributeSet) -> [Port] {
    var ps = [Port](repeating: Port(0, 0, .input, 1), count: 4)
    if attributes.getValue(StdAttr.appearance) == StdAttr.appearClassic {
      ps[Random.out] = Port(40, 20, .output, StdAttr.width)
      ps[Random.ck] = Port(10, 40, .input, 1)
      ps[Random.nxt] = Port(0, 30, .input, 1)
      ps[Random.rst] = Port(30, 40, .input, 1)
    } else {
      ps[Random.out] = Port(80, 80, .output, StdAttr.width)
      ps[Random.ck] = Port(0, 50, .input, 1)
      ps[Random.nxt] = Port(0, 40, .input, 1)
      ps[Random.rst] = Port(0, 30, .input, 1)
    }
    return ps
  }

  public override func propagate(_ state: any InstanceState) throws {
    let data: RandomState
    if let existing = state.data as? RandomState {
      data = existing
    } else {
      data = RandomState(seed: state.attributeValue(Random.attrSeed))
      state.setData(data)
    }

    let dataWidth = state.attributeValue(StdAttr.width, default: BitWidth.known(8))
    let triggerType = state.attributeValue(StdAttr.edgeTrigger)
    let triggered = data.clock.updateClock(state.portValue(Random.ck), trigger: triggerType)

    let seed = state.attributeValue(Random.attrSeed)
    let resetSignal = state.portValue(Random.rst)
    data.propagateReset(resetSignal, seed: seed)
    if resetSignal == .trueValue {
      data.reset(seed)
    } else if triggered && state.portValue(Random.nxt) != .falseValue {
      data.step()
    }

    state.setPort(Random.out, Value.createKnown(dataWidth, Int64(data.value)), 4)
  }

  // MARK: - Painting (M6)

  /// `Random.paintInstance(InstancePainter)` (`Random.java:324-329`).
  public func paintInstance(_ painter: any MemPainter) {
    if painter.attributeValue(StdAttr.appearance) == StdAttr.appearClassic {
      paintInstanceClassic(painter)
    } else {
      paintInstanceEvolution(painter)
    }
  }

  /// `Random.paintInstanceEvolution(InstancePainter)` (`Random.java:305-317`).
  func paintInstanceEvolution(_ painter: any MemPainter) {
    let bds = painter.bounds
    let x = bds.x
    let y = bds.y
    let state = painter.data as? RandomState
    let val = state?.value ?? 0
    let width = painter.attributeValue(StdAttr.width)?.width ?? 8

    painter.drawLabel()
    drawControl(painter, x, y, width)
    drawData(painter, x, y + 70, width, val)
  }

  /// `Random.drawControl(InstancePainter, int, int, int)` (`Random.java:209-238`): the RNGn
  /// control block with its R and EN inputs and the clock row.
  ///
  /// The clock row carries the same edge convention as every other sequential part in this
  /// family: the triangle at `(xpos + 10, ypos + 50)`, then a straight stub into it for a rising
  /// edge or a 10x10 negation circle at `(xpos, ypos + 45)` for a falling one.
  private func drawControl(_ painter: any MemPainter, _ xpos: Int, _ ypos: Int, _ nrOfBits: Int) {
    let g = painter.graphics
    g.strokeWidth = 2
    g.color = MemPaint.componentColor
    g.drawLine(xpos + 10, ypos, xpos + 70, ypos)
    g.drawLine(xpos + 10, ypos, xpos + 10, ypos + 60)
    g.drawLine(xpos + 70, ypos, xpos + 70, ypos + 60)
    g.drawLine(xpos + 10, ypos + 60, xpos + 20, ypos + 60)
    g.drawLine(xpos + 60, ypos + 60, xpos + 70, ypos + 60)
    g.drawLine(xpos + 20, ypos + 60, xpos + 20, ypos + 70)
    g.drawLine(xpos + 60, ypos + 60, xpos + 60, ypos + 70)
    g.drawText(
      "RNG\(nrOfBits)", x: xpos + 40, y: ypos + 8, halign: .center, valign: .center)
    g.drawLine(xpos, ypos + 30, xpos + 10, ypos + 30)
    g.drawText("R", x: xpos + 20, y: ypos + 30, halign: .left, valign: .center)
    painter.drawPort(Random.rst)
    g.drawLine(xpos, ypos + 40, xpos + 10, ypos + 40)
    g.drawText("EN", x: xpos + 20, y: ypos + 40, halign: .left, valign: .center)
    painter.drawPort(Random.nxt)
    painter.drawClockSymbol(xpos + 10, ypos + 50)
    g.strokeWidth = 2
    if painter.attributeValue(StdAttr.edgeTrigger) == StdAttr.triggerFalling {
      g.drawOval(xpos, ypos + 45, 10, 10)
    } else {
      g.drawLine(xpos, ypos + 50, xpos + 10, ypos + 50)
    }
    painter.drawPort(Random.ck)
    g.strokeWidth = 1
  }

  /// `Random.drawData(InstancePainter, int, int, int, int)` (`Random.java:240-251`).
  ///
  /// Note the box is drawn unconditionally and only the hex readout is gated on `getShowState()`
  /// ; a random generator in the toolbar still shows its output box, just empty.
  private func drawData(
    _ painter: any MemPainter, _ xpos: Int, _ ypos: Int, _ nrOfBits: Int, _ value: Int32
  ) {
    let g = painter.graphics
    g.strokeWidth = 2
    g.drawRect(xpos, ypos, 80, 20)
    if painter.showState {
      let str = MemPaint.hexString(bits: nrOfBits, value: Int64(value))
      g.drawCenteredText(str, x: xpos + 40, y: ypos + 10)
    }
    painter.drawPort(Random.out)
    g.strokeWidth = 1
  }

  /// `Random.paintInstanceClassic(InstancePainter)` (`Random.java:253-303`).
  func paintInstanceClassic(_ painter: any MemPainter) {
    let g = painter.graphics
    let bds = painter.bounds
    let state = painter.data as? RandomState
    let width = painter.attributeValue(StdAttr.width)?.width ?? 8

    var a: String
    var b: String? = nil
    if painter.showState {
      let val = Int64(state?.value ?? 0)
      let str = MemPaint.hexString(bits: width, value: val)
      if str.count <= 4 {
        a = str
      } else {
        let split = str.index(str.endIndex, offsetBy: -4)
        a = String(str[str.startIndex..<split])
        b = String(str[split...])
      }
    } else {
      a = MemPaintStrings.randomLabel
      b = MemPaintStrings.randomWidthLabel(width)
    }

    g.color = MemPaint.componentColor
    painter.drawBounds()
    g.color = MemPaint.color(
      of: painter.attributeValue(StdAttr.labelColor, default: StdAttr.defaultLabelColor))
    painter.drawLabel()

    if b == nil {
      painter.drawPort(Random.out, "Q", .west)
    } else {
      painter.drawPort(Random.out)
    }
    g.color = MemPaint.componentSecondaryColor
    painter.drawPort(Random.rst, "0", .south)
    painter.drawPort(Random.nxt, MemPaintStrings.memEnableLabel, .east)
    g.color = MemPaint.componentColor
    painter.drawClock(Random.ck, .north)

    if let b {
      g.drawText(a, x: bds.x + 20, y: bds.y + 3, halign: .center, valign: .top)
      g.drawText(b, x: bds.x + 20, y: bds.y + 15, halign: .center, valign: .top)
    } else {
      g.drawText(a, x: bds.x + 20, y: bds.y + 4, halign: .center, valign: .top)
    }
  }

  // MARK: - Label placement

  /// `instance.setTextField(StdAttr.LABEL, StdAttr.LABEL_FONT, bds.getX() + bds.getWidth() / 2,
  /// bds.getY() - 3, GraphicsUtil.H_CENTER, GraphicsUtil.V_BASELINE)`: Random.java:172.
  ///
  /// Installed only from `configureNewInstance`; `instanceAttributeChanged` (Random.java:202-207)
  /// recomputes the bounds and the ports on an `APPEARANCE` change but does *not* reinstall the
  /// field, so upstream leaves the label pinned to the old top edge when a random generator is
  /// switched between the classic 40x40 body and the 80x90 one. This is a pure function of the
  /// current bounds, so it follows the body instead. Divergence recorded, in the port's favour.
  public func labelPlacement(_ painter: InstancePainter) -> LabelPlacement? {
    let bds = painter.bounds
    return LabelPlacement(
      x: bds.x + bds.width / 2, y: bds.y - 3, halign: .center, valign: .baseline)
  }
}

extension Random: InstanceLabelProvider {}

/// `Random.StateData`: the linear congruential generator itself. See the file header: the
/// constants and shifts here must match Java bit-for-bit.
///
/// **Deviation (mechanism).** Java: `extends ClockState implements InstanceData`; composition
/// (`clock: ClockState`) replaces inheritance, matching `ClockState.swift`'s own header note.
private final class RandomState: InstanceData {
  private static let multiplier: Int64 = 0x5_DEEC_E66D
  private static let addend: Int64 = 0xB
  private static let mask: Int64 = (1 << 48) - 1

  var clock = ClockState()
  private(set) var value: Int32 = 0
  private var initSeed: Int64 = 0
  private var curSeed: Int64 = 0
  private var resetValue: Int64 = 0
  private var oldReset: Value = .unknownValue

  init(seed: Int32?) {
    // JAVA QUIRK, preserved (see the file header). `StateData(Object seed)` computes
    // `resetValue = this.initSeed = this.curSeed = getRandomSeed(seed)`, and `getRandomSeed`
    // reads `this.initSeed`, which, at THIS point in Java's field-initialisation order, is
    // still its default value `0`, not whatever this call is about to produce. Swift requires
    // every stored property to have a value before `self` can be used for anything at all
    // (including calling an instance method), so the fields above are given the same Java
    // defaults first; only then is the (now legal) call to `randomSeed` made, and it reads
    // `initSeed == 0`, exactly reproducing Java's ordering.
    let random = randomSeed(seed)
    resetValue = random
    initSeed = random
    curSeed = random
    value = Int32(truncatingIfNeeded: random)
    oldReset = .unknownValue
  }

  /// Clone support; bypasses the seed-drawing constructor entirely (cloning must never draw a
  /// fresh wall-clock seed).
  private init(cloneOf other: RandomState) {
    clock = other.clock
    value = other.value
    initSeed = other.initSeed
    curSeed = other.curSeed
    resetValue = other.resetValue
    oldReset = other.oldReset
  }

  /// `StateData.getRandomSeed(Object)`.
  private func randomSeed(_ seed: Int32?) -> Int64 {
    // Java: `seed instanceof Integer ? (Integer) seed : 0`; the attribute is always an `Int32`
    // (or absent) in this port, never some other boxed type, so the `instanceof` check has
    // nothing left to do; kept as an `Optional` purely to mirror "attribute may be absent".
    var retValue = Int64(seed ?? 0)
    if retValue == 0 {
      // Non-deterministic by construction, in Java and here alike, see the file header.
      retValue = (javaCurrentTimeMillis() ^ RandomState.multiplier) & RandomState.mask
      if retValue == initSeed {
        retValue = (retValue &+ RandomState.multiplier) & RandomState.mask
      }
    }
    return retValue
  }

  /// `StateData.propagateReset(Value, Object)`.
  func propagateReset(_ reset: Value, seed: Int32?) {
    if oldReset == .falseValue && reset == .trueValue {
      resetValue = randomSeed(seed)
    }
    oldReset = reset
  }

  /// `StateData.reset(Object)`. The parameter is unused, matching Java's own dead argument.
  func reset(_ seed: Int32?) {
    initSeed = resetValue
    curSeed = resetValue
    value = Int32(truncatingIfNeeded: resetValue)
  }

  /// `StateData.step()`.
  func step() {
    // `&*`/`&+` because Java's `long` multiply/add wrap silently on overflow; the low 48 bits
    // surviving the `& MASK` below are identical either way (masking distributes over mod-2^64
    // wraparound because 2^48 divides 2^64, so the composition is exact regardless of how the
    // intermediate 64-bit value wrapped).
    let v = (curSeed &* RandomState.multiplier &+ RandomState.addend) & RandomState.mask
    curSeed = v
    // `v` is always in `0...2^48-1` after masking, so a plain (logical or arithmetic; they
    // agree for a non-negative operand) right shift matches Java's `>>` here.
    value = Int32(truncatingIfNeeded: v >> 12)
  }

  func cloneData() -> any InstanceData {
    RandomState(cloneOf: self)
  }
}

/// `System.currentTimeMillis()`.
private func javaCurrentTimeMillis() -> Int64 {
  Int64(Date().timeIntervalSince1970 * 1000)
}
