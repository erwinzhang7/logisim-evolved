// SynthesizedClockHdlGeneratorFactory: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// `com/cburch/logisim/fpga/hdlgenerator/SynthesizedClockHdlGeneratorFactory.java`. Copyright by
// the Logisim-evolution developers. This translation is a derivative work and is therefore
// licensed GPL-3.0-only. See LICENSE.md.
//
// The base class for generating a synthesized clock that hooks into the clock chain right
// after the hardware clock: by default a plain loopback. A vendor's PLL/clock-tile generator
// (upstream: `XilinxSeries7SynthesizedClockHdlGeneratorFactory`) overrides `getModuleFunctionality`
// to accelerate the clock instead; that vendor integration is out of scope here (D11); Xilinx
// Vivado has never shipped a macOS build.
//
// `open` throughout: this is exactly the extension point a future vendor-clock generator hooks
// into, mirroring Java's `extends`-and-`@Override` shape.

import LogisimKernel

open class SynthesizedClockHdlGeneratorFactory: AbstractHdlGeneratorFactory {
  public static let fpgaClock = "fpgaGlobalClock"
  public static let synthesizedClock = "s_synthesizedClock"
  public static let hdlIdentifier = "synthesizedClockGenerator"
  public static let hdlDirectory = "base"

  public init(widthAttribute: Attribute<BitWidth>) {
    super.init(subDirectory: Self.hdlDirectory, widthAttribute: widthAttribute)
    myPorts
      .add(.input, "FPGAClock", nrOfBits: 1, fixedMap: Self.fpgaClock)
      .add(.output, "SynthesizedClock", nrOfBits: 1, fixedMap: Self.synthesizedClock)
  }

  open override func getPortMap(netlist: any HdlNetlist, componentInfo: (any HdlNetlistComponent)?)
    -> [String: String]
  {
    var result: [String: String] = [:]
    for port in myPorts.keySet() { result[port] = myPorts.getFixedMap(port) }
    return result
  }

  open override func getModuleFunctionality(netlist: any HdlNetlist, attrs: any AttributeSet)
    -> LineBuffer
  {
    LineBuffer.getHdlBuffer()
      .add("")
      .addRemarkBlock("Here the update logic is defined. Loop back the global clock.")
      .add(
        """
        {{assign}} SynthesizedClock {{=}} FPGAClock;

        """)
  }
}
