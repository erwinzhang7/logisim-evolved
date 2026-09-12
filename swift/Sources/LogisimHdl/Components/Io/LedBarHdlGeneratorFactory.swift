// LedBarHdlGeneratorFactory: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// `com/cburch/logisim/std/io/LedBarHdlGeneratorFactory.java`. Copyright by the
// Logisim-evolution developers. This translation is a derivative work and is therefore
// licensed GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// Two upstream details worth naming, both confirmed against the jar:
//
//   * The number of segments comes from `LedBar.ATTR_MATRIX_COLS`, but the *source* signal is
//     read from end 0 as a bus entry when the bar has a single input wire, and from end `pin`
//     when the inputs are separated. In the single-wire case a 1-column bar therefore asks
//     `getBusEntryName` for bit 0 of a **1-bit** end, and `Hdl.getBusEntryName` returns `""`
//     for `nrOfBits <= 1`: so `LedBar/oneWire=true/cols=1` emits
//     `logisimOutputBubbles(5) <= ;`, which is not valid VHDL. That is 4.1.0's output and the
//     port reproduces it (standing rule 4).
//
//   * `isHdlSupportedTarget` reads `DotMatrixBase.ATTR_PERSIST`, not a `LedBar` attribute, and
//     `AbstractComponentFactory.getHDLGenerator` returns **null** when it is false. So a LedBar
//     with persistence set has no generator at all, not merely an unsupported one, which is
//     what `HdlGeneratorLookup.Registration.generator` must return.

import LogisimKernel

/// `com.cburch.logisim.std.io.LedBarHdlGeneratorFactory`.
public final class LedBarHdlGeneratorFactory: InlinedHdlGeneratorFactory {
  private let attributes: IoHdlAttributes

  public init(attributes: IoHdlAttributes = IoHdlAttributes()) {
    self.attributes = attributes
    super.init()
  }

  public override func getInlinedCode(
    netlist: any HdlNetlist, componentId: Int64, componentInfo: any HdlNetlistComponent,
    circuitName: String
  ) -> LineBuffer {
    let contents = LineBuffer.getHdlBuffer()
    let attrs = componentInfo.attributeSet
    let isSingleBus = attributes.isLedBarSingleBus(attrs)
    let nrOfSegments = attributes.ledBarColumns(attrs)
    var wires: [String: String] = [:]
    for pin in 0..<max(0, nrOfSegments) {
      // NB: `LineBuffer.format`, not `formatHdl`; upstream uses the non-HDL form here, so
      // `{{<}}`/`{{>}}` resolve through the buffer's own default pairs rather than the HDL ones.
      // `LineBuffer.format` has no pairs at all, so the braces survive verbatim in Java too.
      let destPin = LineBuffer.format(
        "{{1}}{{<}}{{2}}{{>}}", HdlGeneratorNames.localOutputBubbleBusName,
        componentInfo.localBubbleOutputStart + pin)
      let sourcePin =
        isSingleBus
        ? Hdl.getBusEntryName(
          componentInfo, endIndex: 0, floatingNetTiedToGround: true, bitIndex: pin,
          netlist: netlist)
        : Hdl.getNetName(
          componentInfo, endIndex: pin, floatingNetTiedToGround: true, netlist: netlist)
      wires[destPin] = sourcePin
    }
    Hdl.addAllWiresSorted(contents, wires: &wires)
    return contents
  }

  /// `LedBarHdlGeneratorFactory.isHdlSupportedTarget`: `attrs.getValue(DotMatrixBase.ATTR_PERSIST) == 0`.
  public override func isHdlSupportedTarget(attrs: any AttributeSet) -> Bool {
    attributes.persistTicks(attrs) == 0
  }
}
