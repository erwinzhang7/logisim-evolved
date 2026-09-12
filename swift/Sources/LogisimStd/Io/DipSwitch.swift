// DipSwitch.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.io.DipSwitch),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// Poker seam: see the ASSUMED CHASSIS ADDITION note in Button.swift. `LABEL_LOC`: uses the
// sibling `Io/IoLibrary.swift` file's already-landed `LabelLocation` / `stdAttrLabelLocation`
// stand-in (see the note in Button.swift): same module, no import needed.
//
// ── Not ported ────────────────────────────────────────────────────────────────────────────────
//
//   * `getLabels`/`getInputLabel` and the `ComponentMapInformationContainer` bookkeeping in
//     `instanceAttributeChanged` (`map.setNrOfInports(...)`): FPGA board-pin mapping, the same
//     unmodelled container discussed in Button.swift's header. `StdAttr.mapInfo` is boxed with a
//     trivial placeholder instead, exactly as in Button.
//   * Port tool tips (`DIP1`, `DIP2`, ...); `Port` carries none.
//   * `setIcon`, key configurator, UI (D9).

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

/// `com.cburch.logisim.std.io.DipSwitch`.
public final class DipSwitch: InstanceFactoryBase {
  /// `DipSwitch._ID`.
  public static let id = "DipSwitch"

  /// `DipSwitch.MAX_SWITCH` / `MIN_SWITCH`. Note upstream's own comment: MIN was lowered from 2
  /// to 1 to allow a single-switch DIP.
  public static let maxSwitch = 32
  public static let minSwitch = 1

  /// `DipSwitch.ATTR_SIZE`. Reuses `BitWidth` purely as a bounded-integer carrier (1...32
  /// switches); it is never a propagation width, exactly as upstream's own choice of type.
  public static let size: Attribute<BitWidth> = Attributes.forBitWidth(
    "number", min: Int32(minSwitch), max: Int32(maxSwitch))

  /// See Button.swift's header: `ComponentMapInformationContainer` is not modelled.
  private final class MapInfoPlaceholder {}

  /// `DipSwitch.State`: Java names the field `Value` (capitalised, shadowing the `Value` type
  /// name); renamed `bits` here. `size` is the switch count this state was built for, so a
  /// resize can be detected and the state rebuilt (see `propagate`/`Poker`).
  private final class State: InstanceData {
    var bits: Int32
    let size: Int

    init(bits: Int32, size: Int) {
      self.bits = bits
      self.size = size
    }

    func isBitSet(_ bitIndex: Int) -> Bool {
      guard bitIndex < size else { return false }
      let mask = Int32(1) << Int32(bitIndex & 31)
      return (bits & mask) != 0
    }

    func toggleBit(_ bitIndex: Int) {
      guard bitIndex >= 0, bitIndex < size else { return }
      let mask = Int32(1) << Int32(bitIndex & 31)
      bits ^= mask
    }

    func cloneData() -> any InstanceData { State(bits: bits, size: size) }
  }

  /// `DipSwitch.Poker`.
  ///
  /// **Deviation (mechanism).** Upstream casts `state.getData()` straight to `State` with no
  /// null guard, so a poke before the first paint/propagate would NPE. Paint and propagate both
  /// lazily create the state, which is the invariant the rest of this file relies on, so a poke
  /// that somehow arrives first lazily creates it too instead of trapping.
  public final class Poker: InstancePoker {
    public init() {}

    public func mousePressed(_ state: any InstanceState, _ event: PokeMouseEvent) {
      let n = state.attributeValue(DipSwitch.size, default: BitWidth.known(8)).width
      let existing = state.data as? State
      let data: State
      if let existing, existing.size == n {
        data = existing
      } else {
        data = State(bits: existing?.bits ?? 0, size: n)
        state.setData(data)
      }

      let loc = state.component.location
      let facing = state.attributeValue(StdAttr.facing, default: .north)
      let bitIndex: Int
      switch facing {
      case .south: bitIndex = n + (event.x - loc.x - 5) / 10
      case .east: bitIndex = (event.y - loc.y - 5) / 10
      case .west: bitIndex = (loc.y - event.y - 5) / 10
      case .north: bitIndex = (event.x - loc.x - 5) / 10
      }
      data.toggleBit(bitIndex)
      state.fireInvalidated()
    }
  }

  public init() {
    super.init(DipSwitch.id, displayName: "DIP Switch", requiresLabel: true)
    setAttributes([
      StdAttr.facing.binding(.north),
      StdAttr.label.binding(""),
      stdAttrLabelLocation.binding(.east),
      StdAttr.labelFont.binding(StdAttr.defaultLabelFont),
      StdAttr.labelColor.binding(StdAttr.defaultLabelColor),
      StdAttr.labelVisibility.binding(true),
      DipSwitch.size.binding(BitWidth.known(8)),
      StdAttr.mapInfo.binding(AttributeObjectBox(MapInfoPlaceholder())),
    ])
    setFacingAttribute(StdAttr.facing)
  }

  public override func makePoker() -> (any InstancePoker)? { Poker() }

  /// `getOffsetBounds(AttributeSet)`.
  public override func offsetBounds(_ attributes: any AttributeSet) -> Bounds {
    let facing = attributes[StdAttr.facing, default: .north]
    let n = attributes[DipSwitch.size, default: BitWidth.known(8)].width
    return Bounds.create(0, 0, (n + 1) * 10, 40).rotate(from: .north, to: facing, xc: 0, yc: 0)
  }

  /// `updatePorts(Instance)`, folded into `ports(_:)`: see `PATTERNS.md`. One output port per
  /// switch, spaced 10 apart along the facing direction.
  public override func ports(_ attributes: any AttributeSet) -> [Port] {
    let facing = attributes[StdAttr.facing, default: .north]
    let n = attributes[DipSwitch.size, default: BitWidth.known(8)].width
    var cx = 0, cy = 0, dx = 0, dy = 0
    switch facing {
    case .west: dy = -10
    case .east: dy = 10
    case .south: cx = -10 * (n + 1); dx = 10
    case .north: dx = 10
    }
    return (0..<n).map { i in
      Port(cx + (i + 1) * dx, cy + (i + 1) * dy, .output, 1)
    }
  }

  /// `propagate(InstanceState)`.
  public override func propagate(_ state: any InstanceState) throws {
    let n = state.attributeValue(DipSwitch.size, default: BitWidth.known(8)).width
    let existing = state.data as? State
    let data: State
    if let existing, existing.size == n {
      data = existing
    } else {
      data = State(bits: existing?.bits ?? 0, size: n)
      state.setData(data)
    }
    for i in 0..<data.size {
      state.setPort(i, data.isBitSet(i) ? .trueValue : .falseValue, 1)
    }
  }

  // MARK: - Paint (D6)

  /// `paintInstance(InstancePainter)`; `DipSwitch.java:226-287`.
  ///
  /// This is the one io painter that genuinely needs a **rotation**, not just a translation: the
  /// body is drawn once in NORTH-facing local coordinates and the whole thing is spun by
  /// `-facing.getRight().toRadians()` for EAST/WEST. SOUTH is handled by a translation instead
  /// (`x -= 10*(n+1); y -= 40`) rather than by a 180° rotation, which is why a SOUTH-facing DIP
  /// switch's digits read upright while an EAST-facing one's are sideways. That asymmetry is
  /// upstream's appearance, not a port artefact.
  ///
  /// Note also that everything inside is emitted at the component *location*, not at its
  /// bounds: `g.translate(x, y)` first, then all geometry is local.
  public func paintInstance(_ painter: any IoInstancePainter) {
    let segmentWidth = 10

    let n = painter.attributeValue(DipSwitch.size, default: BitWidth.known(8)).width
    let existing = painter.data as? State
    let state: State
    if let existing, existing.size == n {
      state = existing
    } else {
      // Upstream creates the state from inside `paintInstance`; a DIP switch that has never
      // propagated still paints, and still remembers its bits across a resize.
      state = State(bits: existing?.bits ?? 0, size: n)
      painter.setData(state)
    }

    let facing = painter.attributeValue(StdAttr.facing, default: .north)
    let loc = painter.location
    var x = loc.x
    var y = loc.y
    if facing == .south {
      x -= segmentWidth * (n + 1)
      y -= 40
    }

    let g = painter.scene
    g.pushTranslate(x, y)
    var rotate = 0.0
    if facing != .north && facing != .south {
      rotate = -facing.getRight().toRadians()
      g.pushRotate(rotate)
    }

    // Switch body.
    g.color = .darkGray
    g.fillRect(1, 1, (n + 1) * segmentWidth - 2, 40 - 2)

    // Per-switch tab wells and their 1-based index captions.
    //
    // `DrawAttr.DEFAULT_FONT` is `SansSerif PLAIN 12`, *not* the component's label font; the
    // digits are chrome, not a label. Above nine switches the size drops to 60%, and `deriveFont`
    // takes a float, so this is 7.2pt and not 7.
    let baseFont = SceneFont(family: .sansSerif, size: 12)
    g.font = n > 9 ? baseFont.withSize(12 * 0.6) : baseFont
    for i in 0..<n {
      g.color = state.isBitSet(i) ? .palette(.trueValue) : .white
      g.fillRect(7 + i * segmentWidth, 16, 6, 20)

      g.color = .white
      g.drawCenteredText(String(i + 1), x: 9 + i * segmentWidth, y: 8)
    }

    // The sliding tabs themselves: up (y = 17) when set, down (y = 26) when clear.
    for i in 0..<n {
      g.color = state.isBitSet(i) ? .darkGray : .gray
      let ypos = state.isBitSet(i) ? 17 : 26
      g.fillRect(8 + i * segmentWidth, ypos, 4, 9)
    }

    if rotate != 0.0 { g.popTransform() }
    g.popTransform()

    painter.drawLabel()
    painter.drawPorts()
  }
}

extension DipSwitch: IoPaintable {}

// MARK: - Label (board #78)

extension DipSwitch: InstanceLabelProvider {

  /// `Instance.computeLabelTextField(Instance.AVOID_LEFT)`: `DipSwitch.java:166`, re-run at
  /// `:209`/`:213`/`:223`.
  public func labelPlacement(_ painter: InstancePainter) -> LabelPlacement? {
    LabelPlacement.computed(painter, avoid: .left)
  }
}
