// BitAdder.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.arith.BitAdder),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// Counts the number of 1 bits across `inputs` many `width`-wide buses. Both bounds and ports are
// attribute-dependent (`NUM_INPUTS` changes the port count and the box height), one bespoke
// integer-range attribute.
//
// NOT PORTED: `instanceAttributeChanged`'s `configurePorts`/`recomputeBounds` calls on WIDTH and
// NUM_INPUTS; both are automatic here: `ports(_:)` and `offsetBounds(_:)` are pure functions of
// the attribute set, recomputed and diffed by the chassis on every change (see PATTERNS.md's
// "ports are a pure function").

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

/// `com.cburch.logisim.std.arith.BitAdder`.
public final class BitAdder: InstanceFactoryBase {

  /// `BitAdder._ID`. Do not change, `.circ` files reference it.
  public static let id = "BitAdder"

  /// `BitAdder.NUM_INPUTS`, `Attributes.forIntegerRange("inputs", 1, 64)`.
  public static let numInputs: Attribute<Int32> = Attributes.forIntegerRange(
    "inputs", start: 1, end: 64)

  public init() {
    super.init(BitAdder.id, displayName: "Bit Adder")
    setAttributes([
      // Java: `BitWidth.create(8)`: a literal (D13's non-throwing carve-out).
      StdAttr.width.binding(BitWidth.known(8)),
      BitAdder.numInputs.binding(1),
    ])
  }

  /// `computeOutputBits(int width, int inputs)`. Bounded well below where `1 << outWidth`
  /// could matter (`width, inputs <= 64` ⇒ `maxBits <= 4096` ⇒ `outWidth <= 12`), so plain `Int`
  /// shifts need no `JavaBits` masking.
  private static func computeOutputBits(_ width: Int, _ inputs: Int) -> Int {
    let maxBits = width * inputs
    var outWidth = 1
    while (1 << outWidth) <= maxBits { outWidth += 1 }
    return outWidth
  }

  /// `configurePorts(Instance)`.
  public override func ports(_ attributes: any AttributeSet) -> [Port] {
    let inWidth = attributes.getValue(StdAttr.width) ?? .known(8)
    let inputs = Int(attributes.getValue(BitAdder.numInputs) ?? 1)
    let outWidth = BitAdder.computeOutputBits(inWidth.width, inputs)

    var y: Int
    var dy = 10
    switch inputs {
    case 1:
      y = 0
    case 2:
      y = -10
      dy = 20
    case 3:
      y = -10
    default:
      y = ((inputs - 1) / 2) * -10
    }

    var ports = [Port(0, 0, .output, BitWidth.known(outWidth))]
    for i in 0..<inputs {
      ports.append(Port(-40, y + i * dy, .input, inWidth))
    }
    return ports
  }

  /// `getOffsetBounds(AttributeSet)`.
  public override func offsetBounds(_ attributes: any AttributeSet) -> Bounds {
    let inputs = Int(attributes.getValue(BitAdder.numInputs) ?? 1)
    let h = max(40, 10 * inputs)
    let y = inputs < 4 ? 20 : (((inputs - 1) / 2) * 10 + 5)
    return Bounds.create(-40, -y, 40, h)
  }

  public override func propagate(_ state: any InstanceState) throws {
    let width = state.attributeValue(StdAttr.width, default: .one).width
    let inputs = Int(state.attributeValue(BitAdder.numInputs, default: 1))

    // Number of 1 bits across every input bus: `minCount` bits are definitely 1, `maxCount`
    // bits are not definitely 0 (i.e. TRUE or X/E).
    var minCount = 0
    var maxCount = 0
    for i in 1...inputs {
      let bits = state.portValue(i).getAll()
      for b in bits {
        if b == .trueValue { minCount += 1 }
        if b != .falseValue { maxCount += 1 }
      }
    }

    // Which output bits are uncertain: any bit that differs between the `minCount` and some
    // reachable count in `minCount+1...maxCount`.
    var unknownMask = 0
    if maxCount > minCount {
      for i in (minCount + 1)...maxCount {
        unknownMask |= (minCount ^ i)
      }
    }

    let outWidth = BitAdder.computeOutputBits(width, inputs)
    var out = [Value](repeating: .falseValue, count: outWidth)
    for i in 0..<outWidth {
      if ((unknownMask >> i) & 1) != 0 {
        out[i] = .errorValue
      } else if ((minCount >> i) & 1) != 0 {
        out[i] = .trueValue
      } else {
        out[i] = .falseValue
      }
    }

    let delay = out.count * Adder.perDelay
    state.setPort(0, try Value.create(out), delay)
  }

  public func paintInstance(_ painter: SceneBuilder, _ state: any InstanceState) {
    painter.color = ArithPaint.componentColor
    painter.drawBounds(state.component.bounds)
    ArithPaint.drawAllPorts(painter, state)

    painter.withStrokeWidth(2) {
      let loc = state.component.location
      let x = loc.x - 10
      let y = loc.y
      painter.drawLine(x - 2, y - 5, x - 2, y + 5)
      painter.drawLine(x + 2, y - 5, x + 2, y + 5)
      painter.drawLine(x - 5, y - 2, x + 5, y - 2)
      painter.drawLine(x - 5, y + 2, x + 5, y + 2)
    }
  }
}
