// BitExtenderHdlGeneratorFactory: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// `com/cburch/logisim/std/wiring/BitExtenderHdlGeneratorFactory.java`. Copyright by the
// Logisim-evolution developers. This translation is a derivative work and is therefore licensed
// GPL-3.0-only. See LICENSE.md.
//
// Widens or narrows a bus inline, filling the new high bits with zero, one, the sign bit, or a
// separate input pin.
//
// ── UPSTREAM BUG, PRESERVED ─────────────────────────────────────────────────────────────────
//
// The single-bit-output branch emits the *same assignment twice* (`BitExtenderHdlGeneratorFactory
// .java:42-46`: one `contents.add(...)` written inline, then a second identical one written
// across four lines). In VHDL that is a duplicate concurrent assignment to the same signal and in
// Verilog a duplicate `assign`; both are at best a warning and at worst a multiple-driver error
// from the synthesiser. It is reproduced verbatim under standing rule 4; removing it would make
// generated output differ from the shipped tool for every one-bit Bit Extender.

import LogisimKernel

/// `com.cburch.logisim.std.wiring.BitExtenderHdlGeneratorFactory`.
public final class BitExtenderHdlGeneratorFactory: InlinedHdlGeneratorFactory {

  public override init() {
    super.init()
  }

  public override func getInlinedCode(
    netlist: any HdlNetlist, componentId: Int64, componentInfo: any HdlNetlistComponent,
    circuitName: String
  ) -> LineBuffer {
    let contents = LineBuffer.getHdlBuffer()
    let nrOfPins = componentInfo.nrOfEnds
    var pin = 1
    while pin < nrOfPins {
      guard componentInfo.isEndConnected(pin) else {
        Reporter.shared.addError(
          "Bit Extender component has floating input connection in circuit: \(circuitName)")
        return contents
      }
      pin += 1
    }

    let outputBits = componentInfo.end(at: 0).nrOfBits
    let inputBits = componentInfo.end(at: 1).nrOfBits

    if outputBits == 1 {
      let connectedNet =
        inputBits == 1
        ? Hdl.getNetName(
          componentInfo, endIndex: 1, floatingNetTiedToGround: true, netlist: netlist)
        : Hdl.getBusEntryName(
          componentInfo, endIndex: 1, floatingNetTiedToGround: true, bitIndex: 0, netlist: netlist)
      let target = Hdl.getNetName(
        componentInfo, endIndex: 0, floatingNetTiedToGround: true, netlist: netlist)
      // Twice; see the file header. This is upstream's duplication, not a copy-paste slip here.
      contents.add("{{assign}} {{1}} {{=}} {{2}};", target, connectedNet)
      contents.add("{{assign}} {{1}} {{=}} {{2}};", target, connectedNet)
      contents.add("")
      return contents
    }

    var replacement = ""
    let type = componentInfo.attributeSet.hdlOptionToken(
      named: GatesHdlAttributeNames.bitExtenderType)
    if type == "zero" { replacement += Hdl.zeroBit() }
    if type == "one" { replacement += Hdl.oneBit() }
    if type == "sign" {
      replacement +=
        inputBits > 1
        ? Hdl.getBusEntryName(
          componentInfo, endIndex: 1, floatingNetTiedToGround: true, bitIndex: inputBits - 1,
          netlist: netlist)
        : Hdl.getNetName(
          componentInfo, endIndex: 1, floatingNetTiedToGround: true, netlist: netlist)
    }
    if type == "input" {
      replacement += Hdl.getNetName(
        componentInfo, endIndex: 2, floatingNetTiedToGround: true, netlist: netlist)
    }

    for bit in 0..<outputBits {
      if bit < inputBits {
        contents.add(
          "{{assign}} {{1}} {{=}} {{2}};",
          Hdl.getBusEntryName(
            componentInfo, endIndex: 0, floatingNetTiedToGround: true, bitIndex: bit,
            netlist: netlist),
          inputBits > 1
            ? Hdl.getBusEntryName(
              componentInfo, endIndex: 1, floatingNetTiedToGround: true, bitIndex: bit,
              netlist: netlist)
            : Hdl.getNetName(
              componentInfo, endIndex: 1, floatingNetTiedToGround: true, netlist: netlist))
      } else {
        contents.add(
          "{{assign}} {{1}} {{=}} {{2}};",
          Hdl.getBusEntryName(
            componentInfo, endIndex: 0, floatingNetTiedToGround: true, bitIndex: bit,
            netlist: netlist),
          replacement)
      }
    }
    contents.empty()
    return contents
  }
}
