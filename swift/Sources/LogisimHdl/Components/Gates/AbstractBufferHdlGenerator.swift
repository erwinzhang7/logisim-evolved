// AbstractBufferHdlGenerator: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// `com/cburch/logisim/std/gates/AbstractBufferHdlGenerator.java`. Copyright by the
// Logisim-evolution developers. This translation is a derivative work and is therefore licensed
// GPL-3.0-only. See LICENSE.md.
//
// Buffer and NOT Gate. Both are inline-only: they never become an entity, they splice a single
// assignment into the parent architecture. The only difference between them is the `NOT`, which
// upstream passes to the constructor: so `Buffer` and `NOT Gate` register two instances of this
// one class rather than two classes.

import LogisimKernel

/// `com.cburch.logisim.std.gates.AbstractBufferHdlGenerator`.
public final class AbstractBufferHdlGenerator: InlinedHdlGeneratorFactory {

  private let isInverter: Bool

  public init(isInverter: Bool) {
    self.isInverter = isInverter
    super.init()
  }

  public override func getInlinedCode(
    netlist: any HdlNetlist, componentId: Int64, componentInfo: any HdlNetlistComponent,
    circuitName: String
  ) -> LineBuffer {
    let attrs = componentInfo.attributeSet
    let nrOfBits = attrs.hdlBitWidth(named: GatesHdlAttributeNames.width)
    let dest =
      nrOfBits == 1
      ? Hdl.getNetName(componentInfo, endIndex: 0, floatingNetTiedToGround: false, netlist: netlist)
      : (Hdl.getBusName(componentInfo, endIndex: 0, netlist: netlist) ?? "")
    let source =
      nrOfBits == 1
      ? Hdl.getNetName(componentInfo, endIndex: 1, floatingNetTiedToGround: false, netlist: netlist)
      : (Hdl.getBusName(componentInfo, endIndex: 1, netlist: netlist) ?? "")
    // Upstream returns a buffer holding one empty line, not an empty buffer, when the output
    // is unconnected. That blank line reaches the generated file, so it is reproduced exactly.
    guard componentInfo.isEndConnected(0) else {
      return LineBuffer.getBuffer().add("")
    }
    return LineBuffer.getHdlBuffer().add(
      "{{assign}}{{1}}{{=}}{{2}}{{3}};", dest, isInverter ? Hdl.notOperator() : "", source)
  }

  /// See `AbstractGateHdlGenerator.isHdlSupportedTarget`; a `0Z`/`Z1` buffer has no HDL form,
  /// and upstream's `getHDLGenerator` therefore answers `null` for one.
  public override func isHdlSupportedTarget(attrs: any AttributeSet) -> Bool {
    guard let token = attrs.hdlOptionToken(named: GatesHdlAttributeNames.gateOutput) else {
      return true
    }
    return token == GatesHdlAttributeNames.gateOutput01Token
  }
}
