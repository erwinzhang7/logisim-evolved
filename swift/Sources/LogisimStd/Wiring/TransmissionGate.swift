// TransmissionGate.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.wiring.TransmissionGate),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// A CMOS transmission gate: two complementary gate inputs must both be fully defined and
// disagree for the switch to have a defined state at all; when they do, `GATE0 == TRUE` means
// open (`UNKNOWN` output) and `GATE0 == FALSE` means closed (input passes through unchanged).
// Any other combination of the two gate inputs is a `computeOutput` error/floating case, exactly
// like `Transistor`'s single-gate version; see that file's header for why `ERROR` vs `UNKNOWN`
// is preserved bit-for-bit rather than collapsed.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

/// `com.cburch.logisim.std.wiring.TransmissionGate`.
public final class TransmissionGate: InstanceFactoryBase {

  /// `TransmissionGate._ID`. Do not change, `.circ` files reference it.
  public static let id = "Transmission Gate"

  /// `TransmissionGate.OUTPUT` / `.INPUT` / `.GATE0` / `.GATE1`: port indices; see
  /// `Transistor.swift`'s identical note on why these stay named constants.
  public static let outputPort = 0
  public static let inputPort = 1
  public static let gate0Port = 2
  public static let gate1Port = 3

  /// See `Transistor.factory`'s comment; Java has no `TransmissionGate.FACTORY` constant
  /// either; `WiringLibrary` builds `new AddTool(new TransmissionGate())` inline.
  public static let factory = TransmissionGate()

  public init() {
    super.init(TransmissionGate.id)
    setAttributes([
      StdAttr.facing.binding(.east),
      StdAttr.selectLocation.binding(StdAttr.selectTopRight),
      StdAttr.width.binding(.one),
    ])
    setFacingAttribute(StdAttr.facing)
  }

  /// `updatePorts(Instance)`, transcribed as a pure function of `attributes`: attribute
  /// dependent, so this overrides `ports(_:)`. Tool tips dropped, as in `Transistor`.
  ///
  /// **Note the asymmetry with `Transistor`**: here the `flip` branch swaps *which port index*
  /// (`GATE0` vs `GATE1`) gets which position, not the coordinates within one port: transcribed
  /// exactly, do not "simplify" it into the same shape as `Transistor`'s single-gate flip.
  public override func ports(_ attributes: any AttributeSet) -> [Port] {
    var dx = 0
    var dy = 0
    let facing = attributes[StdAttr.facing, default: .east]
    switch facing {
    case .north: dy = 1
    case .east: dx = -1
    case .south: dy = -1
    case .west: dx = 1
    }

    let selectLoc = attributes[StdAttr.selectLocation, default: StdAttr.selectTopRight]
    let flip = (facing == .north || facing == .west) == (selectLoc == StdAttr.selectTopRight)

    var ports = [Port](repeating: Port(0, 0, .output, StdAttr.width), count: 4)
    ports[TransmissionGate.outputPort] = Port(0, 0, .output, StdAttr.width)
    ports[TransmissionGate.inputPort] = Port(40 * dx, 40 * dy, .input, StdAttr.width)
    if flip {
      ports[TransmissionGate.gate1Port] = Port(20 * (dx - dy), 20 * (dx + dy), .input, 1)
      ports[TransmissionGate.gate0Port] = Port(20 * (dx + dy), 20 * (-dx + dy), .input, 1)
    } else {
      ports[TransmissionGate.gate0Port] = Port(20 * (dx - dy), 20 * (dx + dy), .input, 1)
      ports[TransmissionGate.gate1Port] = Port(20 * (dx + dy), 20 * (-dx + dy), .input, 1)
    }
    return ports
  }

  /// `contains(Location, AttributeSet)`; identical shape to `Transistor`'s: the hit region is a
  /// 24-pixel manhattan-distance disc centred 20 pixels behind the component along its facing,
  /// intersected with the bounds.
  public override func contains(_ point: Location, _ attributes: any AttributeSet) -> Bool {
    guard offsetBounds(attributes).contains(point, 1) else { return false }
    let facing = attributes[StdAttr.facing, default: .east]
    let center = Location.create(0, 0, hasToSnap: true).translate(facing, -20)
    return center.manhattanDistance(to: point) < 24
  }

  /// `getOffsetBounds(AttributeSet)`.
  public override func offsetBounds(_ attributes: any AttributeSet) -> Bounds {
    let facing = attributes[StdAttr.facing, default: .east]
    return Bounds.create(0, -20, 40, 40).rotate(from: .west, to: facing, xc: 0, yc: 0)
  }

  // NOT PORTED: `instanceAttributeChanged`: `FACING`/`SELECT_LOC` only trigger automatic
  // bounds/port recomputation, and `WIDTH` only calls `fireInvalidated()` (paint, M6). See
  // `InstanceFactory.swift`'s file header.

  public override func instanceFeature(
    _ key: ComponentFeatureKey, _ component: StdInstanceComponent
  ) -> Any? {
    guard key == .wireRepair else {
      return super.instanceFeature(key, component)
    }
    return ClosureWireRepair { _ in true }
  }

  /// `computeOutput(InstanceState)`.
  /// The arithmetic itself, lifted out so `paintInstance` can reach it: see
  /// `Transistor.computeOutput(width:gate:input:type:)` for why.
  static func computeOutput(
    width: BitWidth, input: Value, gate0: Value, gate1: Value
  ) throws -> Value {
    // Width-1 `Value` equality below; safe structurally at width <= 1 (`PATTERNS.md`,
    // "Equality"), noted once for this file.
    if gate0.isFullyDefined() && gate1.isFullyDefined() && gate0 != gate1 {
      return gate0 == .trueValue ? Value.createUnknown(width) : input
    } else {
      if input.isFullyDefined() {
        return Value.createError(width)
      } else {
        var bits = input.getAll()
        for i in bits.indices where bits[i] != .unknownValue {
          bits[i] = .errorValue
        }
        return try Value.create(bits)
      }
    }
  }

  /// `computeOutput(InstanceState)`, the port-reading wrapper.
  private func computeOutput(_ state: any InstanceState) throws -> Value {
    try TransmissionGate.computeOutput(
      width: state.attributeValue(StdAttr.width, default: .one),
      input: state.portValue(TransmissionGate.inputPort),
      gate0: state.portValue(TransmissionGate.gate0Port),
      gate1: state.portValue(TransmissionGate.gate1Port))
  }

  /// `TransmissionGate.propagate(InstanceState)`. `Value.create([Value])` throws (D13).
  public override func propagate(_ state: any InstanceState) throws {
    state.setPort(TransmissionGate.outputPort, try computeOutput(state), 1)
  }

  // MARK: Painting (TransmissionGate.java:103-200)

  /// `drawInstance(InstancePainter, boolean isGhost)`.
  ///
  /// Unlike every other component in this family the transform is **rotate about a point, then
  /// translate**: `g.rotate(radians, bds.x + 20, bds.y + 20)` followed by
  /// `g.translate(bds.x, bds.y)`. The body is then drawn in a 0…40 box, which is why every
  /// coordinate below is positive. Composing those two in the other order puts the gate 40
  /// units away from where the reference draws it.
  ///
  /// `gate0` and `gate1` are both read from `GATE0`; upstream's line 127 reads port `GATE0`
  /// into `gate1` as well. Preserved: it means the upper and lower gate leads always share a
  /// colour, which is visible whenever the two gate inputs disagree.
  private func drawInstance(_ painter: InstancePainter, isGhost: Bool) {
    let bds = painter.bounds
    let powerLoc = painter.attributeValue(StdAttr.selectLocation)
    let facing = painter.attributeValue(StdAttr.facing, default: .east)
    let flip =
      (facing == .north || facing == .west) == (powerLoc == StdAttr.selectTopRight)

    var degrees = Direction.west.toDegrees() - facing.toDegrees()
    if flip { degrees += 180 }
    let radians = Double((degrees + 360) % 360) * Double.pi / 180.0

    let g = painter.g
    g.pushRotate(radians, aroundX: bds.x + 20, y: bds.y + 20)
    g.pushTranslate(bds.x, bds.y)
    g.strokeWidth = WiringPaint.wireWidth

    var gate0 = g.color
    var gate1 = gate0
    var input = gate0
    var output = gate0
    var platform = gate0
    if !isGhost && painter.showState {
      gate0 = painter.color(of: painter.portValue(TransmissionGate.gate0Port))
      gate1 = painter.color(of: painter.portValue(TransmissionGate.gate0Port))
      input = painter.color(of: painter.portValue(TransmissionGate.inputPort))
      output = painter.color(of: painter.portValue(TransmissionGate.outputPort))
      platform = painter.color(of: paintOutput(painter))
    }

    g.color = flip ? input : output
    g.drawLine(0, 20, 13, 20)
    g.drawLine(13, 14, 13, 26)

    g.color = flip ? output : input
    g.drawLine(27, 20, 40, 20)
    g.drawLine(27, 14, 27, 26)

    g.color = gate0
    g.drawLine(20, 38, 20, 40)
    g.strokeWidth = 2
    g.drawOval(17, 32, 6, 6)
    g.drawLine(11, 31, 29, 31)
    g.strokeWidth = WiringPaint.wireWidth

    g.color = gate1
    g.drawLine(20, 7, 20, 0)
    g.strokeWidth = 2
    g.drawLine(11, 9, 29, 9)

    g.color = platform
    g.drawLine(9, 13, 31, 13)
    g.drawLine(9, 27, 31, 27)
    g.strokeWidth = 1
    if flip {  // arrow
      g.drawLine(19, 18, 21, 20)
      g.drawLine(19, 22, 21, 20)
    } else {
      g.drawLine(21, 18, 19, 20)
      g.drawLine(21, 22, 19, 20)
    }

    g.popTransform()
    g.popTransform()
  }

  /// See `Transistor.paintOutput` for why this exists and why the throw is unreachable.
  private func paintOutput(_ painter: InstancePainter) -> Value {
    let width = painter.attributeValue(StdAttr.width, default: .one)
    let out = try? TransmissionGate.computeOutput(
      width: width,
      input: painter.portValue(TransmissionGate.inputPort),
      gate0: painter.portValue(TransmissionGate.gate0Port),
      gate1: painter.portValue(TransmissionGate.gate1Port))
    return out ?? Value.createError(width)
  }

  public func paintGhost(_ painter: InstancePainter) {
    drawInstance(painter, isGhost: true)
  }

  public func paintInstance(_ painter: InstancePainter) {
    drawInstance(painter, isGhost: false)
  }
}

extension TransmissionGate: InstancePaintable {}
