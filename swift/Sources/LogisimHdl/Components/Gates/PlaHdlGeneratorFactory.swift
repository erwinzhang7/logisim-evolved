// PlaHdlGeneratorFactory: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// `com/cburch/logisim/std/gates/PlaHdlGeneratorFactory.java`. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore licensed GPL-3.0-only.
// See LICENSE.md.
//
// A programmable logic array: the component carries a truth table (`Pla.ATTR_TABLE`, a
// `PlaTable`) and this emits it as a VHDL `std_match` cascade or a Verilog `casez`.
//
// `PlaTable` lives in `LogisimStd`, which this module cannot name, so the table arrives as a
// plain `[PlaHdlRow]` through an injected reader. That is the same seam every other generator
// here uses for attributes, applied to a structured value instead of a scalar.
//
// Note the two bit renderings differ in more than syntax: VHDL *reverses* the bit order
// (`s.insert(0, …)` prepends each character) and writes a don't-care as `-`, while Verilog keeps
// source order and writes `?`. Getting either backwards produces valid HDL that computes a
// different function, which is exactly the kind of thing a transcription loses silently.

import LogisimKernel

/// One row of `PlaTable`, as this generator needs it: `PlaTable.Row.inBits` / `outBits`, whose
/// characters are `'0'`, `'1'` or anything else meaning "don't care".
public struct PlaHdlRow {
  public let inBits: [Character]
  public let outBits: [Character]

  public init(inBits: [Character], outBits: [Character]) {
    self.inBits = inBits
    self.outBits = outBits
  }
}

/// `com.cburch.logisim.std.gates.PlaHdlGeneratorFactory`.
public final class PlaHdlGeneratorFactory: AbstractHdlGeneratorFactory {

  private let rows: (any AttributeSet) -> [PlaHdlRow]
  private let outputSize: (any AttributeSet) -> Int

  /// - Parameters:
  ///   - inWidth: `Pla.ATTR_IN_WIDTH`, needed by identity for the input port's width.
  ///   - outWidth: `Pla.ATTR_OUT_WIDTH`, likewise for the output port.
  ///   - rows: reads `Pla.ATTR_TABLE`'s `rows()`.
  ///   - outputSize: `PlaTable.outSize()`, used only by the Verilog `default:` arm.
  public init(
    width: Attribute<BitWidth>,
    inWidth: AnyAttribute,
    outWidth: AnyAttribute,
    inPort: Int,
    outPort: Int,
    rows: @escaping (any AttributeSet) -> [PlaHdlRow],
    outputSize: @escaping (any AttributeSet) -> Int
  ) {
    self.rows = rows
    self.outputSize = outputSize
    super.init(subDirectory: "gates", widthAttribute: width)
    myPorts
      .add(.input, "index", nrOfBits: 0, componentPinId: inPort, bitWidthAttribute: inWidth)
      .add(.output, "result", nrOfBits: 0, componentPinId: outPort, bitWidthAttribute: outWidth)
  }

  /// `PlaHdlGeneratorFactory.vhdlBits`: reversed bit order, `-` for a don't-care, single quotes
  /// for a one-bit vector.
  static func vhdlBits(_ bits: [Character]) -> String {
    var text = ""
    for character in bits {
      text = String(character == "0" || character == "1" ? character : "-") + text
    }
    return bits.count == 1 ? "'\(text)'" : "\"\(text)\""
  }

  /// `PlaHdlGeneratorFactory.verilogBits`: source bit order, `?` for a don't-care, sized literal.
  static func verilogBits(_ bits: [Character]) -> String {
    var text = "\(bits.count)'b"
    for character in bits {
      text.append(character == "0" || character == "1" ? character : "?")
    }
    return text
  }

  /// `PlaHdlGeneratorFactory.zeros`.
  static func zeros(_ size: Int) -> String {
    let text = String(repeating: "0", count: max(0, size))
    return size == 1 ? "'\(text)'" : "\"\(text)\""
  }

  public override func getModuleFunctionality(netlist: any HdlNetlist, attrs: any AttributeSet)
    -> LineBuffer
  {
    let contents = LineBuffer.getHdlBuffer().addVhdlKeywords().empty()
    let table = rows(attrs)
    let outSize = outputSize(attrs)

    if Hdl.isVhdl() {
      var leader = "result <= "
      if table.isEmpty {
        contents.add("{{1}}{{2}};", leader, Self.zeros(outSize))
      } else {
        for row in table {
          contents.add(
            "{{1}}{{2}} {{when}} std_match(Index, {{3}}) {{else}}",
            leader, Self.vhdlBits(row.outBits), Self.vhdlBits(row.inBits))
          leader = String(repeating: " ", count: leader.count)
        }
        contents.add("{{1}}{{2}};", leader, Self.zeros(outSize))
      }
    } else {
      contents.add("casez (index)")
      for row in table {
        contents.add(
          "  {{1}}: result = {{2}};", Self.verilogBits(row.inBits), Self.verilogBits(row.outBits))
      }
      contents.add("  default: result = {{1}}'0;", outSize)
      contents.add("endcase")
    }
    return contents.empty()
  }

  public override func isHdlSupportedTarget(attrs: any AttributeSet) -> Bool { true }
}
