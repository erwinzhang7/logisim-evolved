// MemoryRomHdlGeneratorFactory: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// `com/cburch/logisim/std/memory/RomHdlGeneratorFactory.java`. Copyright by the
// Logisim-evolution developers. This translation is a derivative work and is therefore licensed
// GPL-3.0-only. See LICENSE.md.
//
// A ROM never becomes its own entity: it is spliced into the parent's architecture as one
// `with … select` (VHDL) / `case` (Verilog) lookup table, built by `WithSelectHdlGenerator`.
// Only the *non-zero* words are enumerated; zero is the table's default.
//
// ── The one dependency this module cannot satisfy on its own ────────────────────────────────
//
// The table's values come from `Rom.CONTENTS_ATTR`, whose value is a `MemContents`: a class in
// `LogisimStd`, which `LogisimHdl` cannot import (see `HdlGeneratorLookup.swift`). So reading a
// word is injected as a closure rather than imported, the same technique
// `AbstractHdlGeneratorFactory` uses for `StdAttr`. Whoever registers this generator supplies
// it; `MemoryHdlGenerators.registrations(romContents:)` is the parameter.
//
// **Left unsupplied, every word reads as zero and the emitted table is empty.** That is wrong,
// not merely degraded, so the reader is not optional in practice; it is optional only so this
// file can exist before the registration site does. A missing reader is reported through
// `Reporter` at generation time rather than silently producing an all-zero ROM.

import LogisimFile
import LogisimKernel

/// Reads one word out of a memory-contents attribute value: `(attributes, address) -> word`,
/// i.e. `attrs.getValue(Rom.CONTENTS_ATTR).get(address)`.
public typealias MemoryHdlContentsReader = (any AttributeSet, Int64) -> Int64

/// `com.cburch.logisim.std.memory.RomHdlGeneratorFactory`.
public final class MemoryRomHdlGeneratorFactory: InlinedHdlGeneratorFactory {

  private let contents: MemoryHdlContentsReader?

  public init(contents: MemoryHdlContentsReader?) {
    self.contents = contents
    super.init()
  }

  public override func getInlinedCode(
    netlist: any HdlNetlist, componentId: Int64, componentInfo: any HdlNetlistComponent,
    circuitName: String
  ) -> LineBuffer {
    let attrs = componentInfo.attributeSet
    let addressWidth = MemoryHdl.widthValue(
      attrs, named: MemoryHdl.AttributeName.memAddress, default: 0)
    let dataWidth = MemoryHdl.widthValue(attrs, named: MemoryHdl.AttributeName.memData, default: 0)
    if contents == nil {
      Reporter.shared.addFatalError(
        "INTERNAL ERROR: no ROM contents reader was registered; the generated lookup table for '"
          + componentInfo.displayName + "' would be empty!")
    }
    let generator = WithSelectHdlGenerator(
      componentName: attrs.getValue(StdAttr.label) ?? "",
      sourceSignal: Hdl.getBusName(
        componentInfo, endIndex: MemoryRamPortIndices.addrIndex(0, attrs), netlist: netlist) ?? "",
      nrOfSourceBits: addressWidth,
      destinationSignal: Hdl.getBusName(
        componentInfo, endIndex: MemoryRamPortIndices.dataOutIndex(0, attrs), netlist: netlist)
        ?? "",
      nrOfDestinationBits: dataWidth
    ).setDefault(0)
    // `1L << addressWidth` in Java; the attribute caps address width at 24 (`Mem.ADDR_ATTR`),
    // so this cannot overflow, but the loop is written over Int64 to match the Java literally.
    var address: Int64 = 0
    let entries: Int64 = addressWidth >= 63 ? Int64.max : (1 << Int64(addressWidth))
    while address < entries {
      let value = contents?(attrs, address) ?? 0
      if value != 0 { generator.add(address, value) }
      address += 1
    }
    return LineBuffer.getBuffer().add(generator.getHdlCode())
  }

  /// `RomHdlGeneratorFactory.isHdlSupportedTarget(AttributeSet)`: only a single-line ROM is
  /// synthesizable. An absent `Mem.LINE_ATTR` answers `false`, matching Java's explicit
  /// `== null` check.
  public override func isHdlSupportedTarget(attrs: any AttributeSet) -> Bool {
    guard let line = MemoryHdl.optionValue(attrs, named: MemoryHdl.AttributeName.memLine) else {
      return false
    }
    return line == MemoryHdl.Option.memSingle
  }
}
