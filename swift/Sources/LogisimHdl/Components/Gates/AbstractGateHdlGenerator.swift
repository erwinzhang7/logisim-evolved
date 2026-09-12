// AbstractGateHdlGenerator: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// `com/cburch/logisim/std/gates/AbstractGateHdlGenerator.java`. Copyright by the
// Logisim-evolution developers. This translation is a derivative work and is therefore licensed
// GPL-3.0-only. See LICENSE.md.
//
// The one generator behind AND/OR/NAND/NOR/XOR/XNOR/Odd Parity/Even Parity. It is parameterised
// rather than one-per-gate because upstream is: input count, bit width and the per-input
// inversion bubbles are attributes, and the only thing each gate contributes is
// `getLogicFunction` (plus, for AND and NAND, the sense of an unconnected input).
//
// Two upstream spellings preserved deliberately, both visible in generated text:
//   * `getOneHot` closes its VHDL generate block with `GenBits` while `getParity` closes an
//     identically-named block with `genBits`. Capitalisation differs; VHDL is case-insensitive
//     so both compile, and changing either would diverge from the shipped tool byte for byte.
//   * `getOneHot` starts with no leading indent and `getParity` with three spaces, so a bus XOR
//     and a bus one-hot XOR indent differently. Also upstream, also load-bearing for a diff.

import LogisimKernel

/// `com.cburch.logisim.std.gates.AbstractGateHdlGenerator`.
open class AbstractGateHdlGenerator: AbstractHdlGeneratorFactory {

  static let bitWidthGeneric = -1
  static let bitWidthString = "NrOfBits"
  static let bubblesGeneric = -2
  static let bubblesMask = "BubblesMask"

  public let bindings: GatesHdlBindings

  public init(bindings: GatesHdlBindings) {
    self.bindings = bindings
    // Java's no-argument `AbstractHdlGeneratorFactory()` infers the subdirectory by parsing
    // `getClass().toString()`, which works because its packages mirror source directories. Swift
    // modules do not, so the name is explicit: see `AbstractHdlGeneratorFactory.swift`'s header.
    super.init(subDirectory: "gates", widthAttribute: bindings.width)
    myParametersList
      .addBusOnly(Self.bitWidthString, Self.bitWidthGeneric)
      .addVector(
        Self.bubblesMask, Self.bubblesGeneric,
        kind: .gateInputBubbleMask(
          inputsAttribute: bindings.gateInputs,
          isInverted: { attrs, index in attrs.hdlInputIsNegated(index) }))
    getWiresPortsDuringHdlWriting = true
  }

  open override func getGenerationTimeWiresPorts(
    netlist: any HdlNetlist, attrs: any AttributeSet
  ) {
    guard attrs.containsAttribute(bindings.gateInputs) else { return }
    let nrOfInputs = attrs.hdlInteger(named: GatesHdlAttributeNames.gateInputs, default: 1)
    let bitWidth = attrs.hdlBitWidth(named: GatesHdlAttributeNames.width)
    var input = 1
    while input <= nrOfInputs {
      myWires.addWire("s_realInput\(input)", bitWidth == 1 ? 1 : Self.bitWidthGeneric)
      let floatingToZero = getFloatingValue(attrs.hdlInputIsNegated(input - 1))
      myPorts.add(
        .input, "input\(input)", nrOfBits: bitWidth == 1 ? 1 : Self.bitWidthGeneric,
        componentPinId: input, pullToZero: floatingToZero)
      input += 1
    }
    myPorts.add(
      .output, "result", nrOfBits: Self.bitWidthGeneric, componentPinId: 0,
      bitWidthAttribute: bindings.width)
  }

  /// `AbstractGateHdlGenerator.getFloatingValue`. AND and NAND invert the sense; see their
  /// overrides.
  open func getFloatingValue(_ isInverted: Bool) -> Bool { !isInverted }

  /// `AbstractGateHdlGenerator.getLogicFunction`. The base returns an empty buffer, as upstream:
  /// every concrete gate overrides it.
  open func getLogicFunction(nrOfInputs: Int, bitWidth: Int, isOneHot: Bool) -> LineBuffer {
    LineBuffer.getHdlBuffer()
  }

  open override func getModuleFunctionality(netlist: any HdlNetlist, attrs: any AttributeSet)
    -> LineBuffer
  {
    let contents = LineBuffer.getHdlBuffer()
    let bitWidth = attrs.hdlBitWidth(named: GatesHdlAttributeNames.width)
    let nrOfInputs =
      attrs.containsAttribute(bindings.gateInputs)
      ? attrs.hdlInteger(named: GatesHdlAttributeNames.gateInputs, default: 1) : 1

    if nrOfInputs > 1 {
      contents.empty()
      contents.addRemarkBlock("Here the bubbles are processed")
      for index in 0..<nrOfInputs {
        if Hdl.isVhdl() {
          contents.addVhdlKeywords().add(
            "s_realInput{{1}} <= input{{1}} {{when}} {{2}}{{<}}{{3}}{{>}} = '0' {{else}} {{not}}(input{{1}});",
            index + 1, Self.bubblesMask, index)
        } else {
          contents.add(
            "{{assign}} s_realInput{{1}} = ({{2}}{{<}}{{3}}{{>}} == 1'b0) ? input{{1}} : ~input{{1}};",
            index + 1, Self.bubblesMask, index)
        }
      }
    }
    contents.empty().addRemarkBlock("Here the functionality is defined")
    var oneHot = false
    // `attrs.containsAttribute(ATTR_XOR)` is answered by whether the set names it at all: the
    // gate attribute list only includes `xor` for XOR/XNOR, which is exactly the discrimination
    // upstream relies on.
    if let token = attrs.hdlOptionToken(named: GatesHdlAttributeNames.gateXor) {
      oneHot = token == GatesHdlAttributeNames.gateXorOneToken
    }
    contents.add(getLogicFunction(nrOfInputs: nrOfInputs, bitWidth: bitWidth, isOneHot: oneHot))
    return contents.empty()
  }

  /// `AbstractGateHdlGenerator.getOneHot`.
  public func getOneHot(inverted: Bool, nrOfInputs: Int, isBus: Bool) -> LineBuffer {
    let lines = LineBuffer.getHdlBuffer()
    var spaces = ""
    var indexString = ""
    if isBus {
      if Hdl.isVhdl() {
        lines.addVhdlKeywords().add(
          spaces + "genBits : {{for}} n {{in}} (" + Self.bitWidthString
            + "-1) {{downto}} 0 {{generate}}")
        spaces += "   "
        indexString = "(n)"
      } else {
        lines.add("genvar n;")
        lines.add("generate")
        lines.add("   for (n = 0 ; n < " + Self.bitWidthString + " ; n = n + 1)")
        lines.add("      begin: bit")
        spaces += "      "
        indexString = "[n]"
      }
    }
    var oneLine = spaces + Hdl.assignPreamble() + "result" + indexString + Hdl.assignOperator()
    if inverted { oneLine += Hdl.notOperator() + "(" }
    let spacesLen = oneLine.count
    for termLoop in 0..<nrOfInputs {
      while oneLine.count < spacesLen { oneLine += " " }
      oneLine += "("
      for index in 0..<nrOfInputs {
        if index == termLoop {
          oneLine += "s_realInput\(index + 1)" + indexString
        } else {
          oneLine += Hdl.notOperator() + "(s_realInput\(index + 1)" + indexString + ")"
        }
        if index < nrOfInputs - 1 { oneLine += Hdl.andOperator() }
      }
      oneLine += ")"
      if termLoop < nrOfInputs - 1 {
        oneLine += Hdl.orOperator()
      } else {
        if inverted { oneLine += ")" }
        oneLine += ";"
      }
      lines.add(oneLine, applyMap: false)
      oneLine = ""
    }
    if isBus {
      if Hdl.isVhdl() {
        lines.add("{{end}} {{generate}} GenBits;")
      } else {
        lines.add("      end")
        lines.add("endgenerate")
      }
    }
    return lines.empty()
  }

  /// `AbstractGateHdlGenerator.getParity`.
  public static func getParity(inverted: Bool, nrOfInputs: Int, isBus: Bool) -> LineBuffer {
    let lines = LineBuffer.getHdlBuffer()
    var spaces = "   "
    var indexString = ""
    if isBus {
      if Hdl.isVhdl() {
        lines.addVhdlKeywords().add(
          spaces + "genBits : {{for}} n {{in}} (" + bitWidthString
            + "-1) {{downto}} 0 {{generate}}")
        spaces += "   "
        indexString = "(n)"
      } else {
        lines.add("genvar n;")
        lines.add("generate")
        lines.add("   for (n = 0 ; n < " + bitWidthString + " ; n = n + 1)")
        lines.add("      begin: bit")
        spaces += "      "
        indexString = "[n]"
      }
    }
    var oneLine = spaces + Hdl.assignPreamble() + "result" + indexString + Hdl.assignOperator()
    if inverted { oneLine += Hdl.notOperator() + "(" }
    let spacesLen = oneLine.count
    for index in 0..<nrOfInputs {
      while oneLine.count < spacesLen { oneLine += " " }
      oneLine += "s_realInput\(index + 1)" + indexString
      if index < nrOfInputs - 1 {
        oneLine += Hdl.xorOperator()
      } else {
        if inverted { oneLine += ")" }
        oneLine += ";"
      }
      lines.add(oneLine, applyMap: false)
      oneLine = ""
    }
    if isBus {
      if Hdl.isVhdl() {
        lines.add("{{end}} {{generate}} genBits;")
      } else {
        lines.add("      end")
        lines.add("endgenerate")
      }
    }
    return lines.empty()
  }

  /// `AbstractGateHdlGenerator.isHdlSupportedTarget`: a gate whose output behaviour is anything
  /// other than `OUTPUT_01` (i.e. it drives a high-Z level) has no HDL form.
  ///
  /// This is more load-bearing than it looks. `AbstractComponentFactory.getHDLGenerator` returns
  /// the generator **only if `isHDLSupportedComponent(attrs)`**, which defaults to this
  /// predicate, so upstream answers `null` for a `0Z`/`Z1` gate, and such a gate is therefore
  /// absent from the netlist entirely. Verified against the jar: `AND Gate out=0Z` reports
  /// `GENERATOR null`. Any registration of these generators must apply the same gate.
  open override func isHdlSupportedTarget(attrs: any AttributeSet) -> Bool {
    guard let token = attrs.hdlOptionToken(named: GatesHdlAttributeNames.gateOutput) else {
      return true
    }
    return token == GatesHdlAttributeNames.gateOutput01Token
  }
}
