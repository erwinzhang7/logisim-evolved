// WithSelectHdlGenerator: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// `com/cburch/logisim/fpga/hdlgenerator/WithSelectHdlGenerator.java`. Copyright by the
// Logisim-evolution developers. This translation is a derivative work and is therefore
// licensed GPL-3.0-only. See LICENSE.md.
//
// A small code-generation helper for "look up `sourceSignal` in a table, assign the matching
// constant to `destinationSignal`" logic: a VHDL `with ... select` / Verilog `case` inside an
// `always @(*)` block. Used by components with an internal lookup table (e.g. a priority
// encoder's output-per-input-pattern table).
public final class WithSelectHdlGenerator {
  private var cases: [Int64: Int64] = [:]
  private let regName: String
  private let sourceSignal: String
  private let nrOfSourceBits: Int
  private let destinationSignal: String
  private let nrOfDestinationBits: Int
  private var defaultValue: Int64 = 0

  public init(
    componentName: String, sourceSignal: String, nrOfSourceBits: Int, destinationSignal: String,
    nrOfDestinationBits: Int
  ) {
    regName = LineBuffer.format("s_{{1}}_reg", componentName)
    self.sourceSignal = sourceSignal
    self.nrOfSourceBits = nrOfSourceBits
    self.destinationSignal = destinationSignal
    self.nrOfDestinationBits = nrOfDestinationBits
  }

  /// `WithSelectHdlGenerator.binairyStringToInt`. A malformed binary literal is a bug in the
  /// calling generator's own source, not something a `.circ` file can produce: traps (D13),
  /// matching Java's `NumberFormatException` (which is also never caught anywhere upstream).
  private func binaryStringToInt(_ binaryValue: String) -> Int64 {
    var result: Int64 = 0
    for character in binaryValue {
      guard let digit = character.wholeNumberValue, digit == 0 || digit == 1 else {
        preconditionFailure("Invalid binary value in WithSelectHdlGenerator")
      }
      result = result * 2 + Int64(digit)
    }
    return result
  }

  @discardableResult
  public func add(_ selectValue: Int64, _ assignValue: Int64) -> WithSelectHdlGenerator {
    cases[selectValue] = assignValue
    return self
  }

  @discardableResult
  public func add(_ selectValue: Int64, binaryAssignValue: String) -> WithSelectHdlGenerator {
    cases[selectValue] = binaryStringToInt(binaryAssignValue)
    return self
  }

  @discardableResult
  public func add(binarySelectValue: String, binaryAssignValue: String) -> WithSelectHdlGenerator
  {
    cases[binaryStringToInt(binarySelectValue)] = binaryStringToInt(binaryAssignValue)
    return self
  }

  @discardableResult
  public func add(binarySelectValue: String, _ assignValue: Int64) -> WithSelectHdlGenerator {
    cases[binaryStringToInt(binarySelectValue)] = assignValue
    return self
  }

  @discardableResult
  public func setDefault(_ assignValue: Int64) -> WithSelectHdlGenerator {
    defaultValue = assignValue
    return self
  }

  @discardableResult
  public func setDefault(binaryAssignValue: String) -> WithSelectHdlGenerator {
    defaultValue = binaryStringToInt(binaryAssignValue)
    return self
  }

  public func getHdlCode() -> [String] {
    let contents =
      LineBuffer.getHdlBuffer()
      .pair("sourceName", sourceSignal)
      .pair("destName", destinationSignal)
      .pair("regName", regName)
      .pair("regBits", nrOfDestinationBits - 1)
    if Hdl.isVhdl() {
      contents.addVhdlKeywords().add("{{with}} ({{sourceName}}) {{select}} {{destName}} <=")
    } else {
      contents.add(
        """
        reg[{{regBits}}:0] {{regName}};
           always @(*)
           begin
              case ({{sourceName}})

        """)
    }
    for selectValue in cases.keys.sorted() {
      let value = cases[selectValue]!
      if Hdl.isVhdl() {
        contents.add(
          "   {{1}} {{when}} {{2}},", Hdl.getConstantVector(value, nrOfBits: nrOfDestinationBits),
          Hdl.getConstantVector(selectValue, nrOfBits: nrOfSourceBits))
      } else {
        contents.add(
          "      {{1}} : {{regName}} = {{2}};",
          Hdl.getConstantVector(selectValue, nrOfBits: nrOfSourceBits),
          Hdl.getConstantVector(value, nrOfBits: nrOfDestinationBits))
      }
    }
    if Hdl.isVhdl() {
      contents.add(
        "   {{1}} {{when}} {{others}};", Hdl.getConstantVector(defaultValue, nrOfBits: nrOfDestinationBits))
    } else {
      contents.add(
        "      default : {{regName}} = {{1}};",
        Hdl.getConstantVector(defaultValue, nrOfBits: nrOfDestinationBits))
    }
    if Hdl.isVerilog() {
      contents.add(
        // Java's text block (WithSelectHdlGenerator.java:112-117) strips the MINIMUM indentation
        // over its content lines *and* its closing delimiter, 10 columns, which leaves
        // `endcase` at 3. Swift strips only the closing delimiter's own indentation, so the
        // literal has to be written pre-stripped. Transcribing the Java's columns verbatim put
        // `endcase` at 5.
        """
           endcase
        end

        assign {{destName}} = {{regName}};

        """)
    }
    return contents.get()
  }
}
