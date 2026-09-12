// ShifterHdlGeneratorFactory: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// `com/cburch/logisim/std/arith/ShifterHdlGeneratorFactory.java`. Copyright by the
// Logisim-evolution developers. This translation is a derivative work and is therefore
// licensed GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── `Shifter.SHIFT_BITS_ATTR` does not exist in this port, and does not need to ───────────────
//
// Upstream stores the distance-port width in a `forNoSave` attribute that `Shifter.configurePorts`
// writes and only this generator reads; `LogisimStd/Arith/Shifter.swift` deliberately did not
// port it (its header says so) because the Swift chassis computes ports as a pure function of
// the attribute set and has nowhere to stash a side value.
//
// It is recomputed here from the width by the same three lines `configurePorts` uses, the
// smallest `shift` with `(1 << shift) >= width`, starting at 1, which is where the attribute's
// value comes from in the first place. Two consequences, both checked against the jar:
//
//   * The value is identical for every placed component, because `configureNewInstance` always
//     runs `configurePorts`. It differs only for a *bare* attribute set that has never been
//     attached to an instance, where upstream would still be carrying the constructor default
//     of 4; that set never reaches HDL generation. `tools/hdlbridge/ArithBridge.java` therefore
//     writes the computed value into `SHIFT_BITS_ATTR` before generating, modelling a placed
//     component rather than a bare set.
//   * `myPorts.add(..., nrOfBits: 0, ..., bitWidthAttribute: SHIFT_BITS_ATTR)` and
//     `myPorts.add(..., nrOfBits: shiftBits, ...)` are the same number: the attribute-driven
//     path in `HdlPorts.nrOfBits(for:attrs:)` reduces to `attributeValue` exactly when the
//     declared `nrOfBits` is 0, which is the case here.
//
// `shift` is at most 6 for every width `BitWidth` allows (2^6 = 64), so `1 << stage` never
// approaches a 32-bit boundary and no `wrap32` is needed (D15's wide-arithmetic concern does
// not reach this file: nothing here computes with the data, only with its width).
//
// Upstream defects preserved verbatim (standing rule 4), all in the Verilog stage-0 body:
//   * `dataA[{{shiftMode}}]` indexes the data word by the *shift-mode* constant, where every
//     other arm uses `nrOfBits-1`.
//   * `({{nrOfBits1}} == 4)` compares the width against a literal 4: evidently a stray from an
//     earlier revision, since the mode constant for "rotate right" is 4, not the width.
// Both are visible in the checked-in oracle transcript, so they are verified behaviour rather
// than a transcription slip.

import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.std.arith.ShifterHdlGeneratorFactory`.
public final class ShifterHdlGeneratorFactory: AbstractHdlGeneratorFactory {
  private static let shiftModeString = "shifterMode"
  private static let shiftModeId = -1

  /// `Shifter.ATTR_SHIFT`, injected: see `ArithHdlSupport.swift`'s header.
  public init(shiftAttribute: AnyAttribute) {
    super.init(subDirectory: ArithHdlSubdirectory.name, widthAttribute: StdAttr.width)
    myParametersList.add(
      Self.shiftModeString, Self.shiftModeId,
      kind: .attributeOption(shiftAttribute, ArithHdlOptions.shiftModeMap))
    getWiresPortsDuringHdlWriting = true
  }

  /// `Shifter.configurePorts`'s `while ((1 << shift) < data) shift++`, starting at `shift = 1`.
  static func shiftBits(forWidth width: Int) -> Int {
    var shift = 1
    while (1 << shift) < width { shift += 1 }
    return shift
  }

  public override func getGenerationTimeWiresPorts(
    netlist: any HdlNetlist, attrs: any AttributeSet
  ) {
    let nrOfBits = attrs.arithHdlWidth
    let nrOfShiftBits = Self.shiftBits(forWidth: nrOfBits)
    myPorts
      .add(.input, "dataA", nrOfBits: 0, componentPinId: ArithPortIds.Shifter.in0, bitWidthAttribute: StdAttr.width)
      .add(.input, "shiftAmount", nrOfBits: nrOfShiftBits, componentPinId: ArithPortIds.Shifter.in1)
      .add(.output, "result", nrOfBits: 0, componentPinId: ArithPortIds.Shifter.out, bitWidthAttribute: StdAttr.width)
    for stage in 0..<nrOfShiftBits {
      myWires
        .addWire("s_stage\(stage)Result", nrOfBits)
        .addWire("s_stage\(stage)ShiftIn", 1 << stage)
    }
  }

  public override func getModuleFunctionality(netlist: any HdlNetlist, attrs: any AttributeSet)
    -> LineBuffer
  {
    let contents = LineBuffer.getBuffer().pair("shiftMode", Self.shiftModeString)
    let nrOfBits = attrs.arithHdlWidth
    let nrOfShiftBits = Self.shiftBits(forWidth: nrOfBits)
    contents.addRemarkBlock(
      """
      ShifterMode represents when:
      0 : Logical Shift Left
      1 : Rotate Left
      2 : Logical Shift Right
      3 : Arithmetic Shift Right
      4 : Rotate Right
      """ + "\n")
    if Hdl.isVhdl() {
      if nrOfBits == 1 {
        contents.addVhdlKeywords().add(
          """
          result <= dataA {{when}} {{shiftMode}} = 1 {{or}}
                               {{shiftMode}} = 3 {{or}}
                               {{shiftMode}} = 4 {{else}} dataA {{and}} {{not}}(shiftAmount);
          """ + "\n")
      } else {
        for stage in 0..<nrOfShiftBits {
          contents.add(stageFunctionalityVhdl(stageNumber: stage, nrOfBits: nrOfBits))
        }
        contents
          .empty()
          .addRemarkBlock("The result is assigned here")
          .add("result <= s_stage{{1}}Result;", nrOfShiftBits - 1)
      }
    } else {
      if nrOfBits == 1 {
        contents.add(
          """
          assign result = ( ({{shiftMode}} == 1) ||
                            ({{shiftMode}} == 3) ||
                            ({{shiftMode}} == 4) ) ? dataA : dataA&(~shiftAmount);
          """ + "\n")
      } else {
        for stage in 0..<nrOfShiftBits {
          contents.add(stageFunctionalityVerilog(stageNumber: stage, nrOfBits: nrOfBits))
        }
        contents
          .empty()
          .addRemarkBlock("The result is assigned here")
          .add("assign result = s_stage{{1}}Result;", nrOfShiftBits - 1)
      }
    }
    return contents.empty()
  }

  /// `ShifterHdlGeneratorFactory.getStageFunctionalityVerilog`.
  private func stageFunctionalityVerilog(stageNumber: Int, nrOfBits: Int) -> LineBuffer {
    let contents = LineBuffer.getBuffer()
      .pair("shiftMode", Self.shiftModeString)
      .pair("stageNumber", stageNumber)
      .pair("nrOfBits1", nrOfBits - 1)
      .pair("nrOfBits2", nrOfBits - 2)
    let nrOfBitsToShift = 1 << stageNumber
    contents.empty().addRemarkBlock(
      "Stage \(stageNumber) of the binary shift tree is defined here")
    if stageNumber == 0 {
      contents.add(
        """
        assign s_stage0ShiftIn = (({{shiftMode}} == 1) || ({{shiftMode}} == 3))
             ? dataA[{{shiftMode}}] : ({{nrOfBits1}} == 4) ? dataA[0] : 0;

        assign s_stage0Result  = (shiftAmount == 0)
             ? dataA
             : (({{shiftMode}} == 0) || ({{shiftMode}} == 1))
                ? {dataA[{{nrOfBits2}}:0],s_stage0ShiftIn}
                : {s_stage0ShiftIn,dataA[{{nrOfBits1}}:1]};

        """ + "\n")
    } else {
      contents
        .pair("stageNumber1", stageNumber - 1)
        .pair("nrOfBitsToShift", nrOfBitsToShift)
        .pair("nrOfBitsToShift1", nrOfBitsToShift - 1)
        .pair("bitsShiftDiff", nrOfBits - nrOfBitsToShift)
        .pair("bitsShiftDiff1", nrOfBits - nrOfBitsToShift - 1)
        .add(
          """
          assign s_stage{{stageNumber}}ShiftIn = ({{shiftMode}} == 1) ?
                                     s_stage{{stageNumber1}}Result[{{nrOfBits1}}:{{bitsShiftDiff}}] :
                                     ({{shiftMode}} == 3) ?
                                     { {{nrOfBitsToShift}}{s_stage{{stageNumber1}}Result[{{nrOfBits1}}]} } :
                                     ({{shiftMode}} == 4) ?
                                     s_stage{{stageNumber1}}Result[{{nrOfBitsToShift1}}:0] : 0;

          assign s_stage{{stageNumber}}Result  = (shiftAmount[{{stageNumber}}]==0) ?
                                     s_stage{{stageNumber1}}Result :
                                     (({{shiftMode}} == 0)||({{shiftMode}} == 1)) ?
                                     {s_stage{{stageNumber1}}Result[{{bitsShiftDiff1}}:0],s_stage{{stageNumber}}ShiftIn} :
                                     {s_stage{{stageNumber}}ShiftIn,s_stage{{stageNumber1}}Result[{{nrOfBits1}}:{{nrOfBitsToShift}}]};

          """ + "\n")
    }
    return contents
  }

  /// `ShifterHdlGeneratorFactory.getStageFunctionalityVhdl`.
  private func stageFunctionalityVhdl(stageNumber: Int, nrOfBits: Int) -> LineBuffer {
    let nrOfBitsToShift = 1 << stageNumber
    let contents = LineBuffer.getBuffer()
      .addVhdlKeywords()
      .pair("shiftMode", Self.shiftModeString)
      .pair("stageNumber", stageNumber)
      .pair("stageNumber1", stageNumber - 1)
      .pair("nrOfBits1", nrOfBits - 1)
      .pair("nrOfBits2", nrOfBits - 2)
      .pair("bitsShiftDiff", nrOfBits - nrOfBitsToShift)
      .pair("bitsShiftDiff1", nrOfBits - nrOfBitsToShift - 1)
      .pair("nrOfBitsToShift", nrOfBitsToShift)
      .pair("nrOfBitsToShift1", nrOfBitsToShift - 1)
      .empty()
      .addRemarkBlock("Stage \(stageNumber) of the binary shift tree is defined here")
    if stageNumber == 0 {
      contents
        .add(
          """
          s_stage0ShiftIn <= dataA({{nrOfBits1}}) {{when}} {{shiftMode}} = 1 {{or}} {{shiftMode}} = 3 {{else}}
                             dataA(0) {{when}} {{shiftMode}} = 4 {{else}} '0';

          s_stage0Result  <= dataA
          """ + "\n")
        .add(
          nrOfBits == 2
            ? "                      {{when}} shiftAmount = '0' {{else}}"
            : "                      {{when}} shiftAmount(0) = '0' {{else}}")
        .add(
          """
                             dataA({{nrOfBits2}} {{downto}} 0)&s_stage0ShiftIn
                                {{when}} {{shiftMode}} = 0 {{or}} {{shiftMode}} = 1 {{else}}
                             s_stage0ShiftIn&dataA( {{nrOfBits1}} {{downto}} 1 );
          """ + "\n")
    } else {
      contents.add(
        """
        s_stage{{stageNumber}}ShiftIn <= s_stage{{stageNumber1}}Result( {{nrOfBits1}} {{downto}} {{bitsShiftDiff}} ) {{when}} {{shiftMode}} = 1 {{else}}
                           ({{others}} => s_stage{{stageNumber1}}Result({{stageNumber1}})) {{when}} {{shiftMode}} = 3 {{else}}
                           s_stage{{stageNumber1}}Result( {{nrOfBitsToShift1}} {{downto}} 0 ) {{when}} {{shiftMode}} = 4 {{else}}
                           ({{others}} => '0');

        s_stage{{stageNumber}}Result  <= s_stage{{stageNumber1}}Result
                              {{when}} shiftAmount({{stageNumber}}) = '0' {{else}}
                           s_stage{{stageNumber1}}Result( {{bitsShiftDiff1}} {{downto}} 0 )&s_stage{{stageNumber}}ShiftIn
                              {{when}} {{shiftMode}} = 0 {{or}} {{shiftMode}} = 1 {{else}}
                           s_stage{{stageNumber}}ShiftIn&s_stage{{stageNumber1}}Result( {{nrOfBits1}} {{downto}} {{nrOfBitsToShift}} );
        """ + "\n")
    }
    return contents
  }
}
