// PortIo.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.io.PortIo),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── What a "PortIO" pin actually models ──────────────────────────────────────────────────────
//
// This is the bidirectional FPGA-pin component: each physical pin is modeled as up to three
// *separate* Logisim ports tied to the same conceptual wire,
//
//   * an `enable` INPUT (one bit per pin in multi-enable mode, one shared bit in single-enable
//     mode) that says whether this component is driving the pin right now;
//   * a data INPUT that carries whatever the *external* world is putting on the physical bus,
//     this is how a poked/driven value from outside reaches this component;
//   * a data OUTPUT that this component drives back onto the bus.
//
// Fidelity point (per the task brief): the tri-state/floating behaviour lives entirely in
// `PortState.pinValue(at:direction:)`, ported verbatim from `getPinValue`. When disabled and
// never poked, `pokeState` stays `.unknownValue` and the pin genuinely floats (`.unknownValue`
// out); when disabled *and* poked, it drives the poke value (simulating an external testbench
// pin driver); when enabled, it drives `inputState` unless the poke value disagrees with it, in
// which case it reports `.errorValue`: contention between an external driver and a poke.
// Getting any one of these branches backwards makes an OUTPUT-mode pin drive when it should
// float, corrupting every bus it touches, which is exactly the failure mode the task brief
// calls out.
//
// ── What did not come across ──────────────────────────────────────────────────────────────────
//
//   (`paintInstance` IS ported; see the Paint section at the end of the factory.)
//   * `PortPoker` (below) is ported in full, including the hit-testing
//     math, because that math is not paint: it is how the pin under the cursor is identified,
//     and without it `PortState.togglePokeValue` is unreachable and an INPUT-direction PortIO
//     floats forever.
//   * `StdAttr.MAPINFO`'s payload, `ComponentMapInformationContainer` (FPGA pin-mapping data).
//     `StdAttr.mapInfo` exists as an opaque `AttributeObjectBox` (never saved, per its own file
//     header); this port binds it to `nil` rather than constructing the real FPGA container,
//     which is a `com.cburch.logisim.fpga.data` type nobody has ported yet. See the task's
//     final report for the exact shape needed once that lands.
//   * The `instanceAttributeChanged` branch that resets the simulator when `ATTR_DIR` changes
//     (`instance.getComponent().getInstanceStateImpl()… simulator.reset()`) needs `Simulator`,
//     which is M3. Marked below with a `// TODO(M3)`.
//   * `setKeyConfigurator`: UI (D9's precedent throughout this module).

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

/// `PortIo.INPUT` / `OUTPUT` / `INOUTSE` / `INOUTME`: upstream's four `AttributeOption`s for
/// `ATTR_DIR`. A native Swift enum per `Attributes.forOption<V: AttributeOptionValue>`'s
/// preferred shape for new ports (see `Attributes.swift`).
public enum PortIoDirection: String, AttributeOptionValue, CaseIterable, Sendable {
  /// `PortIo.INPUT`, `"onlyinput"`.
  case input = "onlyinput"
  /// `PortIo.OUTPUT`, `"onlyOutput"`.
  case output = "onlyOutput"
  /// `PortIo.INOUTSE`, `"IOSingleEnable"`.
  case inOutSingleEnable = "IOSingleEnable"
  /// `PortIo.INOUTME`, `"IOMultiEnable"`.
  case inOutMultiEnable = "IOMultiEnable"

  public static var attributeOptions: [PortIoDirection] { Array(allCases) }
}

/// `com.cburch.logisim.std.io.PortIo`.
public final class PortIo: InstanceFactoryBase {

  /// `PortIo._ID`.
  public static let id = "PortIO"

  /// `PortIo.MAX_IO` / `MIN_IO`.
  public static let maxIo = 64
  public static let minIo = 1
  private static let initialPortSize = 8
  private static let delay = 1

  /// `PortIo.ATTR_SIZE`.
  public static let attrSize: Attribute<BitWidth> = Attributes.forBitWidth(
    "number", min: Int32(minIo), max: Int32(maxIo))
  /// `PortIo.ATTR_DIR`.
  public static let attrDirection: Attribute<PortIoDirection> = Attributes.forOption("direction")

  /// `PortIo.getLabels(int)`: `"pin_1"`, `"pin_2"`, … Kept for when the FPGA map container is
  /// ported; nothing in this file consumes it yet (see the header).
  public static func labels(count: Int) -> [String] {
    (0..<count).map { "pin_\($0 + 1)" }
  }

  /// `PortIo.PortPoker`: a click on one of the drawn pin squares cycles that pin's poke plane
  /// float → 0 → 1 → float, which is the only way an *external* driver is ever simulated for
  /// this component. Without it `PortState.togglePokeValue` has no caller and every pin stays
  /// at its `.unknownValue` start.
  ///
  /// The pins are drawn as a two-row matrix starting 7 px right and 25 px down from the
  /// component's location, on a 10 px pitch, filled **column-major** (`n = 2 * i + j`, so pins
  /// 0 and 1 share the first column). Upstream un-rotates the click into the component's own
  /// EAST-facing frame first, which is why the rotation runs before the offsets rather than the
  /// matrix being recomputed per facing.
  public final class PortPoker: InstancePoker {
    public init() {}

    public func mouseReleased(_ state: any InstanceState, _ event: PokeMouseEvent) {
      let loc = state.component.location
      let facing = state.attributeValue(StdAttr.facing, default: .east)
      var cx = event.x - loc.x  // Move to component location.
      var cy = event.y - loc.y
      if facing == .north || facing == .south {  // Rotate quarter circle.
        let tmpX = cx
        cx = -cy
        cy = tmpX
      }
      if facing == .west || facing == .south {  // Rotate half circle.
        cx = -cx
        cy = -cy
      }
      cx = cx - 7 + 2  // Move to start of matrix.
      cy = cy - 25 + 2
      // Both must be `>= 0` before the divisions: Java's `/` truncates toward zero, so a
      // negative `cx` would land back on column 0 instead of missing the matrix.
      if cx < 0 || cy < 0 { return }
      let i = cx / 10
      let j = cy / 10
      if j > 1 { return }
      let n = 2 * i + j
      let data = PortIo.state(for: state)
      if n < 0 || n >= data.size { return }
      data.togglePokeValue(pinIndex: n)
      state.fireInvalidated()
    }
  }

  public init() {
    super.init(PortIo.id, displayName: "Port I/O")
    setAttributes([
      StdAttr.facing.binding(.east),
      StdAttr.label.binding(""),
      StdAttr.labelLocation.binding(.east),
      StdAttr.labelFont.binding(StdAttr.defaultLabelFont),
      StdAttr.labelColor.binding(StdAttr.defaultLabelColor),
      StdAttr.labelVisibility.binding(false),
      PortIo.attrSize.binding(BitWidth.known(PortIo.initialPortSize)),
      PortIo.attrDirection.binding(.inOutSingleEnable),
      // `StdAttr.MAPINFO`; see the file header: the real `ComponentMapInformationContainer`
      // payload is not ported, so this is left unbound (upstream's non-null default has no
      // Swift-side consumer yet).
      StdAttr.mapInfo.binding(nil),
    ])
    setFacingAttribute(StdAttr.facing)
  }

  public override func makePoker() -> (any InstancePoker)? { PortPoker() }

  public override func ports(_ attributes: any AttributeSet) -> [Port] {
    let facing = attributes.getValue(StdAttr.facing) ?? .east
    let direction = attributes.getValue(PortIo.attrDirection) ?? .inOutSingleEnable
    let size = (attributes.getValue(PortIo.attrSize) ?? BitWidth.known(PortIo.initialPortSize)).width

    var x = 0, y = 0
    var dx = 0, dy = 0
    switch facing {
    case .north: dy = -10
    case .south: dy = 10
    case .west: dx = -10
    case .east: dx = 10
    }
    if direction == .input || direction == .output {
      x += dx
      y += dy
    }

    var ports: [Port] = []

    if direction == .inOutSingleEnable {
      ports.append(Port(x - dy, y + dx, .input, 1))
      x += dx
      y += dy
    }

    // First pass: enable pins (multi-enable only) + data-input pins, `MAXWIDTH`-wide chunks.
    var n = size
    while n > 0 {
      let e = min(n, BitWidth.maxWidth)
      if direction == .inOutMultiEnable {
        ports.append(Port(x - dy, y + dx, .input, e))
        x += dx
        y += dy
      }
      if direction == .input || direction == .inOutSingleEnable || direction == .inOutMultiEnable {
        ports.append(Port(x, y, .input, e))
        x += dx
        y += dy
      }
      n -= e
    }

    // Second pass: data-output pins.
    n = size
    while n > 0 {
      let e = min(n, BitWidth.maxWidth)
      if direction == .output || direction == .inOutSingleEnable || direction == .inOutMultiEnable {
        ports.append(Port(x, y, .output, e))
        x += dx
        y += dy
      }
      n -= e
    }

    return ports
  }

  public override func offsetBounds(_ attributes: any AttributeSet) -> Bounds {
    let facing = attributes.getValue(StdAttr.facing) ?? .east
    var n = (attributes.getValue(PortIo.attrSize) ?? BitWidth.known(PortIo.initialPortSize)).width
    if n < 8 { n = 8 }
    return Bounds.create(0, 0, 10 + (n + 1) / 2 * 10, 50)
      .rotate(from: .east, to: facing, xc: 0, yc: 0)
  }

  public override func instanceAttributeChanged(
    _ component: StdInstanceComponent, _ attribute: AnyAttribute
  ) {
    // TODO(M3): upstream resets the simulator on an `ATTR_DIR` change
    // (`instance.getComponent().getInstanceStateImpl()...simulator.reset()`), because switching
    // a pin's direction mid-simulation can strand stale bus contention. Needs `Simulator`.
  }

  // MARK: Propagation — see the file header for the tri-state contract this must preserve

  private static func state(for instanceState: any InstanceState) -> PortState {
    let size = (instanceState.attributeValue(PortIo.attrSize) ?? BitWidth.known(PortIo.initialPortSize)).width
    if let existing = instanceState.data as? PortState {
      existing.resize(to: size)
      return existing
    }
    let fresh = PortState(size: size)
    instanceState.setData(fresh)
    return fresh
  }

  public override func propagate(_ state: any InstanceState) throws {
    let direction = state.attributeValue(PortIo.attrDirection, default: .inOutSingleEnable)
    let pinCount = (state.attributeValue(PortIo.attrSize) ?? BitWidth.known(PortIo.initialPortSize)).width
    let data = PortIo.state(for: state)

    var portIndex = 0

    // First: absorb whatever the outside world is driving, into `inputState`/`enableState`.
    if direction == .inOutSingleEnable || direction == .inOutMultiEnable || direction == .output {
      var enableValue = state.portValue(portIndex)
      if direction == .inOutSingleEnable || direction == .inOutMultiEnable { portIndex += 1 }
      var inputValue = state.portValue(portIndex)
      var pinIndexCorrection = -BitWidth.maxWidth
      for pinIndex in 0..<pinCount {
        if pinIndex % BitWidth.maxWidth == 0 {
          if direction == .inOutMultiEnable && pinIndex > 0 {
            enableValue = state.portValue(portIndex)
            portIndex += 1
          }
          inputValue = state.portValue(portIndex)
          portIndex += 1
          pinIndexCorrection += BitWidth.maxWidth
        }
        if direction != .output {
          let enableIndex = direction == .inOutSingleEnable ? 0 : pinIndex - pinIndexCorrection
          data.setEnableValue(enableValue.get(enableIndex), at: pinIndex)
        }
        data.setInputValue(inputValue.get(pinIndex - pinIndexCorrection), at: pinIndex)
      }
    }

    // Then: drive the outputs.
    if direction != .output {
      var remaining = pinCount
      var chunkSize = min(remaining, BitWidth.maxWidth)
      remaining -= chunkSize
      var outputChunk = [Value](repeating: .falseValue, count: chunkSize)
      var pinIndexCorrection = 0
      for pinIndex in 0..<pinCount {
        if pinIndex > 0 && pinIndex % BitWidth.maxWidth == 0 {
          state.setPort(portIndex, try Value.create(outputChunk), PortIo.delay)
          portIndex += 1
          chunkSize = min(remaining, BitWidth.maxWidth)
          remaining -= chunkSize
          outputChunk = [Value](repeating: .falseValue, count: chunkSize)
          pinIndexCorrection += BitWidth.maxWidth
        }
        outputChunk[pinIndex - pinIndexCorrection] = data.pinValue(at: pinIndex, direction: direction)
      }
      state.setPort(portIndex, try Value.create(outputChunk), PortIo.delay)
    }
  }

  // MARK: - Paint (D6)

  /// The paint-path twin of `state(for:)`.
  private static func state(painting painter: any IoInstancePainter) -> PortState {
    let size =
      (painter.attributeValue(PortIo.attrSize) ?? BitWidth.known(PortIo.initialPortSize)).width
    if let existing = painter.data as? PortState {
      existing.resize(to: size)
      return existing
    }
    let fresh = PortState(size: size)
    painter.setData(fresh)
    return fresh
  }

  /// `paintInstance(InstancePainter)`: `PortIo.java:385-473`.
  ///
  /// A connector body (a DARK_GRAY trapezoid), a two-row grid of pin squares coloured by the
  /// value on each pin, and then a run of direction arrows: one triple per 32-bit bus, in a
  /// fixed order: enable stub, then every output arrow, then every input arrow.
  ///
  /// Three things to be careful with:
  ///
  ///   * the body polygon array has **seven** points but is *filled* with six and *stroked*
  ///     with seven. The seventh repeats the first, closing the outline; `fillPolygon` closes
  ///     implicitly, so including it in the fill would be a degenerate edge. Passing all seven
  ///     to both, the natural simplification, changes the stroke not at all and the fill not
  ///     at all, but it is transcribed as-is because the two call sites genuinely differ.
  ///   * `INOUTSE` (single enable) draws a full 6-unit enable stub for bus 0 and a 2-unit stub
  ///     for every later bus, at a *negative* offset from `px`. `INOUTME` draws the full stub
  ///     every time. That is what visually distinguishes the two modes.
  ///   * everything is drawn at the component's location under a rotation, so all the
  ///     coordinates below are local; `w`/`h` come from the bounds rotated back to EAST.
  public func paintInstance(_ painter: any IoInstancePainter) {
    let facing = painter.attributeValue(StdAttr.facing, default: .east)

    let bds = painter.bounds.rotate(from: .east, to: facing, xc: 0, yc: 0)
    let w = bds.width
    let h = bds.height
    let loc = painter.location
    let g = painter.scene

    g.pushTranslate(loc.x, loc.y)
    var rotate = 0.0
    if facing != .east {
      rotate = -facing.toRadians()
      g.pushRotate(rotate)
    }

    g.strokeWidth = 2
    g.color = .darkGray
    let bx = [1, 1, 5, w - 6, w - 2, w - 2, 1]
    let by = [20, h - 8, h - 4, h - 4, h - 8, 20, 20]
    g.fillPolygon(Array(bx.prefix(6)), Array(by.prefix(6)))
    g.color = painter.componentColor
    g.strokeWidth = 1
    g.drawPolyline(bx, by)

    let size = painter.attributeValue(PortIo.attrSize, default: BitWidth.known(PortIo.initialPortSize)).width
    let nBus = (size - 1) / BitWidth.maxWidth + 1
    let dir = painter.attributeValue(PortIo.attrDirection, default: .inOutSingleEnable)

    if !painter.showState {
      g.color = .lightGray
      for i in 0..<size {
        g.fillRect(7 + (i / 2) * 10, 25 + (i % 2) * 10, 6, 6)
      }
    } else {
      let data = PortIo.state(painting: painter)
      for i in 0..<size {
        // `getPinColor`: an UNKNOWN pin is LIGHT_GRAY: a literal colour, *not* the value
        // palette's unknown entry, so a floating pin here reads pale grey rather than the
        // blue every other unknown in the app is drawn in.
        let value = data.pinValue(at: i, direction: dir)
        g.color = value == .unknownValue ? .lightGray : .palette(value.paletteIndex)
        g.fillRect(7 + (i / 2) * 10, 25 + (i % 2) * 10, 6, 6)
      }
    }

    g.color = painter.componentColor
    var px = (dir == .inOutSingleEnable || dir == .inOutMultiEnable) ? 0 : 10
    let py = 0
    for p in 0..<nBus {
      if dir == .inOutSingleEnable {
        g.strokeWidth = 3
        if p == 0 {
          g.drawLine(px, py + 10, px + 6, py + 10)
          px += 10
        } else {
          g.drawLine(px - 6, py + 10, px - 4, py + 10)
        }
      }
      if dir == .inOutMultiEnable {
        g.strokeWidth = 3
        g.drawLine(px, py + 10, px + 6, py + 10)
        px += 10
      }
      if dir == .output || dir == .inOutSingleEnable || dir == .inOutMultiEnable {
        g.strokeWidth = 3
        g.drawLine(px, py, px, py + 4)
        g.drawLine(px, py + 15, px, py + 20)
        g.strokeWidth = 2
        g.drawPolyline(
          [px, px - 4, px + 4, px],
          [py + 15, py + 5, py + 5, py + 15])
        px += 10
      }
    }

    for _ in 0..<nBus {
      if dir == .input || dir == .inOutSingleEnable || dir == .inOutMultiEnable {
        g.strokeWidth = 3
        g.drawLine(px, py, px, py + 5)
        g.drawLine(px, py + 16, px, py + 20)
        g.strokeWidth = 2
        g.drawPolyline(
          [px, px - 4, px + 4, px],
          [py + 6, py + 16, py + 16, py + 6])
        px += 10
      }
    }

    g.strokeWidth = 1
    if rotate != 0.0 { g.popTransform() }
    g.popTransform()

    painter.drawPorts()
    g.color = .attribute(
      painter.attributeValue(StdAttr.labelColor, default: StdAttr.defaultLabelColor))
    painter.drawLabel()
  }
}

extension PortIo: IoPaintable {}

// MARK: - Label (board #78)

extension PortIo: InstanceLabelProvider {

  /// `Instance.computeLabelTextField(Instance.AVOID_BOTTOM)`: `PortIo.java:254`, re-run at
  /// `:343`/`:345`/`:349`.
  ///
  /// `AVOID_BOTTOM` (0b0100), not `AVOID_LEFT`: it rotates to `left` on a north-facing PortIo,
  /// `bottom` on west, `top` on south and `right` on east: i.e. the opposite edge from the
  /// LED family's, so a `SOUTH` label is nudged here where a `WEST` one would be there.
  public func labelPlacement(_ painter: InstancePainter) -> LabelPlacement? {
    LabelPlacement.computed(painter, avoid: .bottom)
  }
}

/// `PortIo.PortState`; the per-instance scratch data. Each pin carries three independent
/// planes; see the file header for exactly what each means and why the tri-state logic must be
/// preserved bit-for-bit.
public final class PortState: InstanceData {
  private static let bitWidth = BitWidth.known(1)

  private(set) var size: Int
  private var inputState: [Value]
  private var pokeState: [Value]
  private var enableState: [Value]

  init(size: Int) {
    self.size = size
    self.inputState = Array(repeating: .unknownValue, count: size)
    self.pokeState = Array(repeating: .unknownValue, count: size)
    self.enableState = Array(repeating: Value.createKnown(PortState.bitWidth, 0), count: size)
  }

  private init(size: Int, inputState: [Value], pokeState: [Value], enableState: [Value]) {
    self.size = size
    self.inputState = inputState
    self.pokeState = pokeState
    self.enableState = enableState
  }

  /// `PortState.resize(int)`.
  func resize(to newSize: Int) {
    guard newSize != size else { return }
    if newSize > size {
      inputState.append(contentsOf: repeatElement(.unknownValue, count: newSize - size))
      pokeState.append(contentsOf: repeatElement(.unknownValue, count: newSize - size))
      enableState.append(
        contentsOf: repeatElement(Value.createKnown(PortState.bitWidth, 0), count: newSize - size))
    } else {
      inputState.removeLast(size - newSize)
      pokeState.removeLast(size - newSize)
      enableState.removeLast(size - newSize)
    }
    size = newSize
  }

  /// `PortState.togglePokeValue(int)`: cycles a pin's poke plane float → 0 → 1 → float. Driven
  /// by `PortIo.PortPoker`; `propagate`'s tri-state contention check reads what it writes.
  ///
  /// **Deviation, bounds only.** Java guards `pinIndex > size`, so `pinIndex == size` falls
  /// through to `pokeState.get(size)` and throws `IndexOutOfBoundsException`. The only caller
  /// (`PortPoker`) rejects `n >= size` first, so the branch is dead upstream; the guard here is
  /// the correct `>=` rather than reproducing an unreachable throw.
  public func togglePokeValue(pinIndex: Int) {
    guard pinIndex >= 0, pinIndex < size else { return }
    let current = pokeState[pinIndex].get(0)
    if current == .unknownValue {
      pokeState[pinIndex] = Value.createKnown(PortState.bitWidth, 0)
    } else if current == .falseValue {
      pokeState[pinIndex] = Value.createKnown(PortState.bitWidth, 1)
    } else {
      pokeState[pinIndex] = .unknownValue
    }
  }

  func setInputValue(_ value: Value, at pinIndex: Int) {
    guard pinIndex >= 0, pinIndex < size else { return }
    inputState[pinIndex] = value
  }

  func setEnableValue(_ value: Value, at pinIndex: Int) {
    guard pinIndex >= 0, pinIndex < size else { return }
    enableState[pinIndex] = value
  }

  /// `PortState.getPinValue(int, AttributeOption)`; the tri-state contract. See the file
  /// header: this is the single most important method in the file to get exactly right.
  func pinValue(at pinIndex: Int, direction: PortIoDirection) -> Value {
    guard pinIndex >= 0, pinIndex < size else { return .errorValue }
    if direction == .output {
      return inputState[pinIndex]
    }
    if direction == .input {
      return pokeState[pinIndex]
    }
    let input = inputState[pinIndex]
    let poke = pokeState[pinIndex]
    let enable = enableState[pinIndex]
    let result: Value = (poke == .unknownValue || poke == input) ? input : .errorValue
    if enable == .unknownValue { return .errorValue }
    return enable == .trueValue ? result : poke
  }

  /// `PortState.getPinColor(int, AttributeOption)`. Colour, not paint: this is the value the
  /// (M6) renderer will look up, kept here so the palette mapping has a single owner. `LIGHT_GRAY`
  /// (the "no simulation running" placeholder) is not a `Value` colour, so callers needing it draw
  /// it themselves rather than through this method.
  public func pinPaletteIndex(at pinIndex: Int, direction: PortIoDirection) -> ValuePalette {
    pinValue(at: pinIndex, direction: direction).paletteIndex
  }

  public func cloneData() -> any InstanceData {
    PortState(size: size, inputState: inputState, pokeState: pokeState, enableState: enableState)
  }
}
