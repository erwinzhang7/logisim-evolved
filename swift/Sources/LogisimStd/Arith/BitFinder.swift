// BitFinder.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.arith.BitFinder),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// Scans an input bus for the first/last 0 or 1 bit. Fixed bounds, computed ports (the index
// output's width tracks the data width), one bespoke `AttributeOption` pick-one attribute
// (`TYPE`).
//
// NOT PORTED: `instanceAttributeChanged`'s `configurePorts` call on WIDTH; automatic here
// (`ports(_:)` is a pure function of the attribute set); its `fireInvalidated()` on TYPE is a
// repaint request, M6.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

/// `com.cburch.logisim.std.arith.BitFinder`.
public final class BitFinder: InstanceFactoryBase {

  /// `BitFinder._ID`. Do not change, `.circ` files reference it.
  public static let id = "BitFinder"

  /// `BitFinder.LOW_ONE`: `new AttributeOption("low1", …)`. Only `name` matters here (D5).
  public static let lowOne = AttributeOption(name: "low1")
  /// `BitFinder.HIGH_ONE`.
  public static let highOne = AttributeOption(name: "high1")
  /// `BitFinder.LOW_ZERO`.
  public static let lowZero = AttributeOption(name: "low0")
  /// `BitFinder.HIGH_ZERO`.
  public static let highZero = AttributeOption(name: "high0")
  /// `BitFinder.TYPE`.
  public static let type: Attribute<AttributeOption> = Attributes.forOption(
    "type", choices: [lowOne, highOne, lowZero, highZero])

  // Port indices, kept named per the arith-family convention.
  public static let present = 0
  public static let index = 1
  public static let inPort = 2

  public init() {
    super.init(BitFinder.id, displayName: "Bit Finder")
    // Java: `BitWidth.create(8)`: a literal (D13's non-throwing carve-out).
    setAttributes([
      StdAttr.width.binding(BitWidth.known(8)),
      BitFinder.type.binding(BitFinder.lowOne),
    ])
    setOffsetBounds(Bounds.create(-40, -20, 40, 40))
  }

  /// `computeOutputBits(int maxBits)`. `maxBits` is `width - 1 <= 63` here, so `outWidth <= 6`;
  /// well below where `1 << outWidth` could need `JavaBits` masking.
  private static func computeOutputBits(_ maxBits: Int) -> Int {
    var outWidth = 1
    while (1 << outWidth) <= maxBits { outWidth += 1 }
    return outWidth
  }

  /// `configurePorts(Instance)`.
  public override func ports(_ attributes: any AttributeSet) -> [Port] {
    let inWidth = attributes.getValue(StdAttr.width) ?? .known(8)
    let outWidth = BitFinder.computeOutputBits(inWidth.width - 1)

    return [
      Port(-20, 20, .output, BitWidth.one),  // PRESENT
      Port(0, 0, .output, BitWidth.known(outWidth)),  // INDEX
      Port(-40, 0, .input, inWidth),  // IN
    ]
  }

  public override func propagate(_ state: any InstanceState) throws {
    let width = state.attributeValue(StdAttr.width, default: .one).width
    let outWidth = BitFinder.computeOutputBits(width - 1)
    let kind = state.attributeValue(BitFinder.type, default: BitFinder.lowOne)

    let bits = state.portValue(BitFinder.inPort).getAll()
    let want: Value
    var i: Int
    switch kind {
    case BitFinder.highZero:
      want = .falseValue
      i = bits.count - 1
      while i >= 0 && bits[i] == .trueValue { i -= 1 }
    case BitFinder.lowZero:
      want = .falseValue
      i = 0
      while i < bits.count && bits[i] == .trueValue { i += 1 }
    case BitFinder.highOne:
      want = .trueValue
      i = bits.count - 1
      while i >= 0 && bits[i] == .falseValue { i -= 1 }
    default:  // lowOne
      want = .trueValue
      i = 0
      while i < bits.count && bits[i] == .falseValue { i += 1 }
    }

    let presentValue: Value
    let indexValue: Value
    if i < 0 || i >= bits.count {
      presentValue = .falseValue
      indexValue = Value.createKnown(outWidth, 0)
    } else if bits[i] == want {
      presentValue = .trueValue
      indexValue = Value.createKnown(outWidth, Int64(i))
    } else {
      presentValue = .errorValue
      indexValue = Value.createError(.known(outWidth))
    }

    let delay = outWidth * Adder.perDelay
    state.setPort(BitFinder.present, presentValue, delay)
    state.setPort(BitFinder.index, indexValue, delay)
  }

  /// `S.get("bitFinderFindLabel"/"bitFinderHighLabel"/"bitFinderLowLabel")`; localisation
  /// (D5's precedent); the English resource strings ("find"/"high"/"low") are used directly.
  public func paintInstance(_ painter: SceneBuilder, _ state: any InstanceState) {
    painter.color = ArithPaint.componentColor
    painter.drawBounds(state.component.bounds)
    ArithPaint.drawAllPorts(painter, state)

    let top = "find"
    let mid: String
    let bot: String
    switch state.attributeValue(BitFinder.type, default: BitFinder.lowOne) {
    case BitFinder.highZero:
      mid = "high"
      bot = "0"
    case BitFinder.lowZero:
      mid = "low"
      bot = "0"
    case BitFinder.highOne:
      mid = "high"
      bot = "1"
    default:  // lowOne
      mid = "low"
      bot = "1"
    }

    let bds = state.component.bounds
    let x = bds.x + bds.width / 2
    let y0 = bds.y
    painter.drawCenteredText(top, x: x, y: y0 + 8)
    painter.drawCenteredText(mid, x: x, y: y0 + 20)
    painter.drawCenteredText(bot, x: x, y: y0 + 32)
  }
}
