// MemoryRamPortIndices: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution): the
// port-counting and port-indexing half of
// `com/cburch/logisim/std/memory/RamAppearance.java:31-197,322-348,505-514`. Copyright by the
// Logisim-evolution developers. This translation is a derivative work and is therefore licensed
// GPL-3.0-only. See LICENSE.md.
//
// ── Why this is a second copy of logic that already exists in LogisimStd ────────────────────
//
// `RamAppearance` is ported in `LogisimStd/Memory/RamAppearance.swift`, but `LogisimHdl` cannot
// import `LogisimStd` (see `HdlGeneratorLookup.swift`), and `RamHdlGeneratorFactory` calls
// `RamAppearance.getAddrIndex`/`getDataInIndex`/`getDataOutIndex`/`getWEIndex`/`getOEIndex`/
// `getClkIndex`/`getLEIndex`/`getBEIndex`/`getNrLEPorts`/`getNrBEPorts` on nearly every line of
// its port construction. There is no way to reach them from here.
//
// Only the *index arithmetic* is duplicated, no geometry, no drawing, no `Port` construction,
// and it is pure arithmetic over attribute values, so the duplicate cannot drift in behaviour
// without the oracle test noticing: the port ids it produces are dumped straight out of the
// jar's own `myPorts` by `tools/hdlbridge/MemoryBridge.java` and compared.
//
// **If `LogisimStd` ever gains a dependency on `LogisimHdl`, delete this file and call
// `RamAppearance` directly.** It exists solely because that edge does not exist yet.

import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.std.memory.RamAppearance`, restricted to the port-index arithmetic the
/// RAM HDL generator needs.
public enum MemoryRamPortIndices {

  /// `RamAppearance.seperatedBus` (upstream's spelling).
  public static func separatedBus(_ attrs: any AttributeSet) -> Bool {
    MemoryHdl.optionValue(attrs, named: MemoryHdl.AttributeName.ramDataBus)
      == MemoryHdl.Option.ramBusSeparate
  }

  /// `RamAppearance.synchronous`.
  public static func synchronous(_ attrs: any AttributeSet) -> Bool {
    guard attrs.containsAttribute(StdAttr.trigger) else { return false }
    let trigger = attrs.getValue(StdAttr.trigger)
    return trigger == StdAttr.triggerRising || trigger == StdAttr.triggerFalling
  }

  /// Whether `Mem.ENABLES_ATTR` is absent or set to `Mem.USELINEENABLES`; the guard that
  /// precedes every `Mem.LINE_ATTR` read, so `LINE_ATTR` is never consulted for a byte-enable
  /// RAM (which does not carry it).
  private static func lineEnabled(_ attrs: any AttributeSet) -> Bool {
    guard let enables = MemoryHdl.optionValue(attrs, named: MemoryHdl.AttributeName.memEnables)
    else { return true }
    return enables == MemoryHdl.Option.memUseLineEnables
  }

  private static func lineSize(_ attrs: any AttributeSet) -> AttributeOption? {
    MemoryHdl.optionValue(attrs, named: MemoryHdl.AttributeName.memLine)
  }

  /// `Mem.DUAL` / `.QUAD` / `.OCTO` as data-port counts; `Mem.SINGLE` and anything else is 1.
  private static func lineCount(_ attrs: any AttributeSet) -> Int {
    switch lineSize(attrs)?.name {
    case "dual": return 2
    case "quad": return 4
    case "octo": return 8
    default: return 1
    }
  }

  public static func nrAddrPorts(_ attrs: any AttributeSet) -> Int { 1 }

  public static func nrDataOutPorts(_ attrs: any AttributeSet) -> Int {
    lineEnabled(attrs) ? lineCount(attrs) : 1
  }

  public static func nrDataInPorts(_ attrs: any AttributeSet) -> Int {
    separatedBus(attrs) ? nrDataOutPorts(attrs) : 0
  }

  public static func nrDataPorts(_ attrs: any AttributeSet) -> Int {
    nrDataInPorts(attrs) + nrDataOutPorts(attrs)
  }

  public static func nrOePorts(_ attrs: any AttributeSet) -> Int {
    guard let enables = MemoryHdl.optionValue(attrs, named: MemoryHdl.AttributeName.memEnables)
    else { return 0 }
    if !separatedBus(attrs) || enables != MemoryHdl.Option.memUseLineEnables { return 1 }
    return 0
  }

  public static func nrWePorts(_ attrs: any AttributeSet) -> Int {
    MemoryHdl.optionValue(attrs, named: MemoryHdl.AttributeName.memEnables) == nil ? 0 : 1
  }

  public static func nrClkPorts(_ attrs: any AttributeSet) -> Int {
    guard let enables = MemoryHdl.optionValue(attrs, named: MemoryHdl.AttributeName.memEnables)
    else { return 0 }
    let async = !synchronous(attrs)
    return (async && enables != MemoryHdl.Option.memUseLineEnables) ? 0 : 1
  }

  public static func nrLePorts(_ attrs: any AttributeSet) -> Int {
    guard let enables = MemoryHdl.optionValue(attrs, named: MemoryHdl.AttributeName.memEnables)
    else { return 0 }
    guard enables == MemoryHdl.Option.memUseLineEnables else { return 0 }
    let count = lineCount(attrs)
    return count == 1 ? 0 : count
  }

  public static func nrBePorts(_ attrs: any AttributeSet) -> Int {
    guard let enables = MemoryHdl.optionValue(attrs, named: MemoryHdl.AttributeName.memEnables)
    else { return 0 }
    let async = !synchronous(attrs)
    guard enables != MemoryHdl.Option.memUseLineEnables,
      MemoryHdl.optionValue(attrs, named: MemoryHdl.AttributeName.ramByteEnables)
        == MemoryHdl.Option.ramWithByteEnables,
      !async
    else { return 0 }
    let nrBits = MemoryHdl.widthValue(attrs, named: MemoryHdl.AttributeName.memData, default: 0)
    return nrBits < 9 ? 0 : (nrBits + 7) >> 3
  }

  public static func nrClrPorts(_ attrs: any AttributeSet) -> Int {
    MemoryHdl.booleanValue(attrs, named: MemoryHdl.AttributeName.ramClearPin, default: false)
      ? 1 : 0
  }

  /// `RamAppearance.getDataOffset`.
  private static func dataOffset(portOffset: Int, portIndex: Int, _ attrs: any AttributeSet) -> Int
  {
    switch portIndex {
    case 0:
      return portOffset
    case 1:
      return (lineEnabled(attrs) && lineSize(attrs) != MemoryHdl.Option.memSingle)
        ? portOffset + 1 : -1
    case 2, 3:
      let count = lineCount(attrs)
      return (lineEnabled(attrs) && (count == 4 || count == 8)) ? portOffset + portIndex : -1
    case 4, 5, 6, 7:
      return (lineEnabled(attrs) && lineCount(attrs) == 8) ? portOffset + portIndex : -1
    default:
      return -1
    }
  }

  public static func addrIndex(_ portIndex: Int, _ attrs: any AttributeSet) -> Int {
    portIndex == 0 ? 0 : -1
  }

  public static func dataOutIndex(_ portIndex: Int, _ attrs: any AttributeSet) -> Int {
    dataOffset(portOffset: nrAddrPorts(attrs), portIndex: portIndex, attrs)
  }

  public static func dataInIndex(_ portIndex: Int, _ attrs: any AttributeSet) -> Int {
    guard separatedBus(attrs) else { return dataOutIndex(portIndex, attrs) }
    return dataOffset(
      portOffset: nrAddrPorts(attrs) + nrDataOutPorts(attrs), portIndex: portIndex, attrs)
  }

  public static func oeIndex(_ portIndex: Int, _ attrs: any AttributeSet) -> Int {
    let portOffset = nrAddrPorts(attrs) + nrDataPorts(attrs)
    let nrOes = nrOePorts(attrs)
    if nrOes == 0 || portIndex < 0 { return -1 }
    return portIndex < nrOes ? portOffset + portIndex : -1
  }

  public static func weIndex(_ portIndex: Int, _ attrs: any AttributeSet) -> Int {
    let portOffset = nrAddrPorts(attrs) + nrDataPorts(attrs) + nrOePorts(attrs)
    let nrWes = nrWePorts(attrs)
    if nrWes == 0 || portIndex < 0 { return -1 }
    return portIndex < nrWes ? portOffset + portIndex : -1
  }

  public static func clkIndex(_ portIndex: Int, _ attrs: any AttributeSet) -> Int {
    let portOffset =
      nrAddrPorts(attrs) + nrDataPorts(attrs) + nrOePorts(attrs) + nrWePorts(attrs)
    if nrClkPorts(attrs) == 0 || portIndex != 0 { return -1 }
    return portOffset
  }

  public static func leIndex(_ portIndex: Int, _ attrs: any AttributeSet) -> Int {
    let portOffset =
      nrAddrPorts(attrs) + nrDataPorts(attrs) + nrOePorts(attrs) + nrWePorts(attrs)
      + nrClkPorts(attrs)
    let nrLes = nrLePorts(attrs)
    if nrLes == 0 || portIndex < 0 { return -1 }
    return portIndex < nrLes ? portOffset + portIndex : -1
  }

  public static func beIndex(_ portIndex: Int, _ attrs: any AttributeSet) -> Int {
    let portOffset =
      nrAddrPorts(attrs) + nrDataPorts(attrs) + nrOePorts(attrs) + nrWePorts(attrs)
      + nrClkPorts(attrs) + nrLePorts(attrs)
    let nrBes = nrBePorts(attrs)
    if nrBes == 0 || portIndex < 0 { return -1 }
    return portIndex < nrBes ? portOffset + portIndex : -1
  }

  public static func clrIndex(_ portIndex: Int, _ attrs: any AttributeSet) -> Int {
    let portOffset =
      nrAddrPorts(attrs) + nrDataPorts(attrs) + nrOePorts(attrs) + nrWePorts(attrs)
      + nrClkPorts(attrs) + nrLePorts(attrs) + nrBePorts(attrs)
    let nrClrs = nrClrPorts(attrs)
    if nrClrs == 0 || portIndex < 0 { return -1 }
    return portIndex < nrClrs ? portOffset + portIndex : -1
  }
}
