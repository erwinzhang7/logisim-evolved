// HexDigitHdlGeneratorFactory: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// `com/cburch/logisim/std/io/HexDigitHdlGeneratorFactory.java`. Copyright by the
// Logisim-evolution developers. This translation is a derivative work and is therefore
// licensed GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// A 4-bit-to-seven-segment decode table, emitted through `WithSelectHdlGenerator`. Two things
// to be careful about:
//
//   * The 16th entry is **not** in the table. Upstream adds cases 0..14 and makes `F` the
//     `others`/`default` arm via `setDefault("1110001")`. Adding a 15th case would change the
//     emitted text.
//   * The register name `WithSelectHdlGenerator` builds is `s_<label>_reg`, taken from the raw
//     `StdAttr.LABEL` with no `CorrectLabel` scrubbing, so an unlabelled HexDigit produces
//     `s__reg`. That is upstream's behaviour; reproduced.

import LogisimKernel

/// `com.cburch.logisim.std.io.HexDigitHdlGeneratorFactory`.
public final class HexDigitHdlGeneratorFactory: InlinedHdlGeneratorFactory {
  /// `HexDigit.HEX`, the 4-bit value input.
  public static let hexPortIndex = 0
  /// `HexDigit.DP`, the decimal-point input.
  public static let decimalPointPortIndex = 1

  private let attributes: IoHdlAttributes

  public init(attributes: IoHdlAttributes = IoHdlAttributes()) {
    self.attributes = attributes
    super.init()
  }

  public override func getInlinedCode(
    netlist: any HdlNetlist, componentId: Int64, componentInfo: any HdlNetlistComponent,
    circuitName: String
  ) -> LineBuffer {
    let attrs = componentInfo.attributeSet
    let startId = componentInfo.localBubbleOutputStart
    let bubbleBusName = HdlGeneratorNames.localOutputBubbleBusName
    // **`formatHdl`, where upstream uses `format`, and the difference is deliberate.**
    //
    // Java builds this with `LineBuffer.format`, which resolves only the positional arguments,
    // so `signalName` still contains the literal text `{{<}}` and `{{>}}` when it is installed
    // as the `sigName` pair. Those braces are then resolved (or not) by whichever later
    // iteration of `LineBuffer.applyPairs` happens to visit the `<` and `>` keys *after*
    // `sigName`, which is `HashMap` iteration order. Upstream's order happens to resolve both:
    // the jar emits `logisimOutputBubbles(22 DOWNTO 16)`. The port's `Dictionary` order does
    // not; it resolved `>` and left `{{<}}`, which is how this was found.
    //
    // Rather than reproduce a HashMap ordering to get a bracket right, the brackets are
    // resolved here, before the string is ever used as a pair value. Same output, no ordering
    // dependence. Verified byte-identical against `tools/hdlbridge/io-4.1.0.oracle` for all
    // eight HexDigit cases in both languages.
    let signalName = LineBuffer.formatHdl(
      "{{1}}{{<}}{{2}}{{3}}{{4}}{{>}}", bubbleBusName, startId + 6, Hdl.vectorLoopId(), startId)
    let contents =
      LineBuffer.getHdlBuffer()
      .pair("bubbleBusName", bubbleBusName)
      .pair("sigName", signalName)
      .pair(
        "dpName",
        Hdl.getNetName(
          componentInfo, endIndex: Self.decimalPointPortIndex, floatingNetTiedToGround: true,
          netlist: netlist))

    if componentInfo.isEndConnected(Self.hexPortIndex) {
      let generator = WithSelectHdlGenerator(
        componentName: attributes.label(attrs),
        sourceSignal: Hdl.getBusName(
          componentInfo, endIndex: Self.hexPortIndex, netlist: netlist) ?? "",
        nrOfSourceBits: 4,
        destinationSignal: signalName,
        nrOfDestinationBits: 7)
      generator
        .add(0, binaryAssignValue: "0111111")
        .add(1, binaryAssignValue: "0000110")
        .add(2, binaryAssignValue: "1011011")
        .add(3, binaryAssignValue: "1001111")
        .add(4, binaryAssignValue: "1100110")
        .add(5, binaryAssignValue: "1101101")
        .add(6, binaryAssignValue: "1111101")
        .add(7, binaryAssignValue: "0000111")
        .add(8, binaryAssignValue: "1111111")
        .add(9, binaryAssignValue: "1100111")
        .add(10, binaryAssignValue: "1110111")
        .add(11, binaryAssignValue: "1111100")
        .add(12, binaryAssignValue: "0111001")
        .add(13, binaryAssignValue: "1011110")
        .add(14, binaryAssignValue: "1111001")
        .setDefault(binaryAssignValue: "1110001")
      contents.add(generator.getHdlCode())
    } else {
      contents.add(
        "{{assign}}{{sigName}}{{=}}{{1}};",
        Hdl.getZeroVector(nrOfBits: 7, floatingPinTiedToGround: true))
    }

    if attributes.hasDecimalPoint(attrs) {
      contents.add("{{assign}}{{bubbleBusName}}{{<}}{{1}}{{>}}{{=}}{{dpName}};", startId + 7)
    }
    return contents
  }
}
