// AbstractConstantHdlGeneratorFactory: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// `com/cburch/logisim/std/wiring/AbstractConstantHdlGeneratorFactory.java`, plus the two
// `getConstant` overrides nested in `Constant.java` and `Power.java`. Copyright by the
// Logisim-evolution developers. This translation is a derivative work and is therefore licensed
// GPL-3.0-only. See LICENSE.md.
//
// Drives a net with a fixed value, inline. Four components share it: `Ground` uses the base
// class unchanged (constant 0), `Power` returns an all-ones value of the component's width,
// `Constant` returns its `value` attribute, and `NoConnect` uses a bare
// `InlinedHdlGeneratorFactory` and emits nothing at all.
//
// The constant is supplied as a closure rather than by subclassing, because the two overrides
// upstream are one line each and both read attributes this module resolves by name anyway.

import LogisimKernel

/// `com.cburch.logisim.std.wiring.AbstractConstantHdlGeneratorFactory`.
public final class AbstractConstantHdlGeneratorFactory: InlinedHdlGeneratorFactory {

  /// `AbstractConstantHdlGeneratorFactory.getConstant(AttributeSet)`. The base returns 0, which
  /// is exactly what `Ground` wants.
  public static let zero: (any AttributeSet) -> Int64 = { _ in 0 }

  /// `Constant.ConstantHdlGeneratorFactory.getConstant`: `attrs.getValue(Constant.ATTR_VALUE)`.
  public static let constantAttributeValue: (any AttributeSet) -> Int64 = { attrs in
    guard let attribute = attrs.attribute(named: GatesHdlAttributeNames.constantValue) else {
      return 0
    }
    switch attrs.rawValue(attribute) {
    case .long(let value): return value
    case .integer(let value): return Int64(value)
    default: return 0
    }
  }

  /// `Power.PowerHdlGeneratorFactory.getConstant`: all ones, `width` bits wide.
  ///
  /// Upstream builds it by shifting a `long` left one bit at a time, `width` times. At width 64
  /// that yields `-1`; Swift would trap on the signed overflow of the last `|`, so the loop is
  /// written on the unsigned bit pattern and reinterpreted, which is what the Java arithmetic
  /// actually computes.
  public static let allOnes: (any AttributeSet) -> Int64 = { attrs in
    let width = attrs.hdlBitWidth(named: GatesHdlAttributeNames.width)
    var value: UInt64 = 0
    var bit = 0
    while bit < width {
      value <<= 1
      value |= 1
      bit += 1
    }
    return Int64(bitPattern: value)
  }

  private let constant: (any AttributeSet) -> Int64

  public init(constant: @escaping (any AttributeSet) -> Int64) {
    self.constant = constant
    super.init()
  }

  public override func getInlinedCode(
    netlist: any HdlNetlist, componentId: Int64, componentInfo: any HdlNetlistComponent,
    circuitName: String
  ) -> LineBuffer {
    let contents = LineBuffer.getHdlBuffer()
    guard componentInfo.nrOfEnds > 0 else { return contents }
    // Upstream reads `componentInfo.getComponent().getEnd(0).getWidth().getWidth()`; the
    // netlist's own `ConnectionEnd` for that pin carries the same width (it is built from it),
    // and it is the only one this module's netlist protocol exposes.
    let nrOfBits = componentInfo.end(at: 0).nrOfBits
    guard componentInfo.isEndConnected(0) else { return contents }
    let constantValue = constant(componentInfo.attributeSet)

    if nrOfBits == 1 {
      contents
        .add(
          "{{assign}} {{1}} {{=}} {{2}};",
          Hdl.getNetName(
            componentInfo, endIndex: 0, floatingNetTiedToGround: true, netlist: netlist),
          Hdl.getConstantVector(constantValue, nrOfBits: 1))
        .add("")
      return contents
    }

    if netlist.isContinuesBus(componentInfo, endIndex: 0) {
      contents.add(
        "{{assign}} {{1}} {{=}} {{2}};",
        Hdl.getBusNameContinues(componentInfo, endIndex: 0, netlist: netlist) ?? "",
        Hdl.getConstantVector(constantValue, nrOfBits: nrOfBits))
      contents.add("")
      return contents
    }

    // Not a contiguous bus, so every bit is assigned individually.
    var mask: Int64 = 1
    for bit in 0..<nrOfBits {
      let bitValue = (mask & constantValue) != 0 ? Hdl.oneBit() : Hdl.zeroBit()
      // Java shifts a `long` and simply runs off the end past bit 63, leaving `mask == 0` and
      // every further bit reading zero. `&<<` reproduces that without trapping.
      mask = mask &<< 1
      contents.add(
        "{{assign}} {{1}} {{=}} {{2}};",
        Hdl.getBusEntryName(
          componentInfo, endIndex: 0, floatingNetTiedToGround: true, bitIndex: bit,
          netlist: netlist),
        bitValue)
    }
    contents.add("")
    return contents
  }
}
