// DualRamAppearance.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.memory.DualRamAppearance),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── Ownership note ───────────────────────────────────────────────────────────────────────────
//
// See `DualRamAttributes.swift`'s header for why this file: part of the community-contributed
// "Dual Port RAM" variant; is ported under this slice's "remaining memory/*.java" clause rather
// than the sibling Mem/Ram/Rom slice's, whose own `RamAppearance.swift` this file mirrors
// function-for-function with every count/index doubled for the second (B) port.
//
// ── What this file actually is ──────────────────────────────────────────────────────────────
//
// Exactly `RamAppearance.swift`'s split: the port *topology*, how many ports a given attribute
// combination produces, which index each logical signal lands at, and where each sits relative
// to the origin, is simulation-critical (`DualRam.propagate`, ported alongside `DualRam.swift`,
// calls these functions on every step) and is ported in full below. The other half,
// `drawRamClassic`, `drawRamEvolution`, `drawConnections`, `drawControlBlock`, `drawDataBlocks`,
// `drawBidir`, `drawAddress`, paints against `Graphics2D`/`InstancePainter` and is D6/M6, **not
// ported**; see the block at the end of this file for exactly what upstream does there.
//
// ── Deviations (all inherited from `RamAppearance.swift`'s precedent) ───────────────────────────
//
//   * **Naming.** `get`/`Nr` prefixes drop in favour of Swift's property-getter convention
//     (`getNrAddrPorts` → `addrPortCount`, `getAddrIndex` → `addrPortIndex`), and upstream's own
//     misspelling `seperatedBus` is corrected to `separatedBus` (an internal helper name, never
//     serialized). Every function's doc comment names the exact upstream method.
//   * **No tool tips.** Every `Port(...).setToolTip(...)` call is dropped; `Port` carries none.
//   * **Missing-attribute degradation.** An absent `AttributeOption` compares unequal to
//     everything and an absent `BitWidth` contributes a width of 0, rather than upstream's
//     unguarded `attrs.getValue(X)` (which an uncaught `null` would NPE on, and which `Simulator`
//     would still catch; D13). In practice this path is unreachable: `DualRamAttributes.attributes`
//     answers `Mem.data`/`Mem.line`/etc. unconditionally.
//
// ── Assumed API from `Mem`/`DualRamAttributes` ──────────────────────────────────────────────────
//
//   `Mem.addr`, `Mem.data`, `Mem.line`, `Mem.single/.dual/.quad/.octo`, `Mem.enables`,
//   `Mem.useByteEnables/.useLineEnables`, `Mem.symbolWidth`: all ported in `Mem.swift` (sibling
//   slice) and already load-bearing for `RamAppearance.swift`.
//   `DualRamAttributes.dataBus`, `.busSeparate`, `.byteEnables`, `.busWithByteEnables`,
//   `.clearPin`: ported in `DualRamAttributes.swift`, this same file.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

/// `com.cburch.logisim.std.memory.DualRamAppearance`: port topology for `DualRam`.
/// A pure-static namespace, like `RamAppearance`; nothing here is instantiated.
public enum DualRamAppearance {

  // MARK: - Port counts

  /// `getNrAddrPorts`. Always two: one address input per port.
  public static func addrPortCount(_ attrs: any AttributeSet) -> Int { 2 }

  /// `getNrDataInPorts`.
  public static func dataInPortCount(_ attrs: any AttributeSet) -> Int {
    separatedBus(attrs) ? dataOutPortCount(attrs) : 0
  }

  /// `getNrDataOutPorts`. Every line-count doubled relative to `RamAppearance`'s single-port
  /// answer: one set of data lines per side.
  public static func dataOutPortCount(_ attrs: any AttributeSet) -> Int {
    if !attrs.containsAttribute(Mem.enables) || attrs.getValue(Mem.enables) == Mem.useLineEnables {
      let line = attrs.getValue(Mem.line)
      if line == Mem.dual { return 4 }
      if line == Mem.quad { return 8 }
      if line == Mem.octo { return 16 }
    }
    return 2
  }

  /// `getNrDataPorts`.
  public static func dataPortCount(_ attrs: any AttributeSet) -> Int {
    dataInPortCount(attrs) + dataOutPortCount(attrs)
  }

  /// `getNrOEPorts`.
  public static func oePortCount(_ attrs: any AttributeSet) -> Int {
    guard attrs.containsAttribute(Mem.enables) else { return 0 }
    let separated = separatedBus(attrs)
    return (!separated || attrs.getValue(Mem.enables) == Mem.useByteEnables) ? 2 : 0
  }

  /// `getNrWEPorts`.
  public static func wePortCount(_ attrs: any AttributeSet) -> Int {
    attrs.containsAttribute(Mem.enables) ? 2 : 0
  }

  /// `getNrClkPorts`.
  public static func clkPortCount(_ attrs: any AttributeSet) -> Int {
    guard attrs.containsAttribute(Mem.enables) else { return 0 }
    let async = !synchronous(attrs)
    return (async && attrs.getValue(Mem.enables) == Mem.useByteEnables) ? 0 : 2
  }

  /// `getNrLEPorts`.
  public static func lePortCount(_ attrs: any AttributeSet) -> Int {
    guard attrs.containsAttribute(Mem.enables), attrs.getValue(Mem.enables) == Mem.useLineEnables
    else { return 0 }
    let line = attrs.getValue(Mem.line)
    if line == Mem.dual { return 4 }
    if line == Mem.quad { return 8 }
    if line == Mem.octo { return 16 }
    return 0
  }

  /// `getNrBEPorts`.
  public static func bePortCount(_ attrs: any AttributeSet) -> Int {
    guard attrs.containsAttribute(Mem.enables) else { return 0 }
    let async = !synchronous(attrs)
    guard
      attrs.getValue(Mem.enables) == Mem.useByteEnables,
      attrs.containsAttribute(DualRamAttributes.byteEnables),
      attrs.getValue(DualRamAttributes.byteEnables) == DualRamAttributes.busWithByteEnables,
      !async
    else { return 0 }
    let bits = attrs.getValue(Mem.data)?.width ?? 0
    let perPort = bits < 9 ? 0 : (bits + 7) >> 3
    return perPort * 2
  }

  /// `getNrClrPorts`.
  public static func clrPortCount(_ attrs: any AttributeSet) -> Int {
    (attrs.containsAttribute(DualRamAttributes.clearPin)
      && (attrs.getValue(DualRamAttributes.clearPin) ?? false))
      ? 1 : 0
  }

  /// `getNrOfPorts`.
  public static func portCount(_ attrs: any AttributeSet) -> Int {
    addrPortCount(attrs) + dataPortCount(attrs) + oePortCount(attrs) + wePortCount(attrs)
      + clkPortCount(attrs) + lePortCount(attrs) + bePortCount(attrs) + clrPortCount(attrs)
  }

  // MARK: - Port indices

  /// `getAddrIndex`.
  public static func addrPortIndex(_ portIndex: Int, _ attrs: any AttributeSet) -> Int {
    portIndex < 2 ? portIndex : -1
  }

  /// `getDataInIndex`.
  public static func dataInPortIndex(_ portIndex: Int, _ attrs: any AttributeSet) -> Int {
    guard separatedBus(attrs) else { return dataOutPortIndex(portIndex, attrs) }
    return dataOffset(portOffset: addrPortCount(attrs) + dataOutPortCount(attrs), portIndex: portIndex, attrs)
  }

  /// `getDataOutIndex`.
  public static func dataOutPortIndex(_ portIndex: Int, _ attrs: any AttributeSet) -> Int {
    dataOffset(portOffset: addrPortCount(attrs), portIndex: portIndex, attrs)
  }

  /// `getOEIndex`.
  public static func oePortIndex(_ portIndex: Int, _ attrs: any AttributeSet) -> Int {
    let offset = addrPortCount(attrs) + dataPortCount(attrs)
    let count = oePortCount(attrs)
    guard count > 0, portIndex >= 0, portIndex < count else { return -1 }
    return offset + portIndex
  }

  /// `getWEIndex`.
  public static func wePortIndex(_ portIndex: Int, _ attrs: any AttributeSet) -> Int {
    let offset = addrPortCount(attrs) + dataPortCount(attrs) + oePortCount(attrs)
    let count = wePortCount(attrs)
    guard count > 0, portIndex >= 0, portIndex < count else { return -1 }
    return offset + portIndex
  }

  /// `getClkIndex`.
  public static func clkPortIndex(_ portIndex: Int, _ attrs: any AttributeSet) -> Int {
    let offset = addrPortCount(attrs) + dataPortCount(attrs) + oePortCount(attrs) + wePortCount(attrs)
    let count = clkPortCount(attrs)
    guard count > 0, portIndex >= 0, portIndex < count else { return -1 }
    return offset + portIndex
  }

  /// `getLEIndex`.
  public static func lePortIndex(_ portIndex: Int, _ attrs: any AttributeSet) -> Int {
    let offset =
      addrPortCount(attrs) + dataPortCount(attrs) + oePortCount(attrs) + wePortCount(attrs)
      + clkPortCount(attrs)
    let count = lePortCount(attrs)
    guard count > 0, portIndex >= 0, portIndex < count else { return -1 }
    return offset + portIndex
  }

  /// `getBEIndex`.
  public static func bePortIndex(_ portIndex: Int, _ attrs: any AttributeSet) -> Int {
    let offset =
      addrPortCount(attrs) + dataPortCount(attrs) + oePortCount(attrs) + wePortCount(attrs)
      + clkPortCount(attrs) + lePortCount(attrs)
    let count = bePortCount(attrs)
    guard count > 0, portIndex >= 0, portIndex < count else { return -1 }
    return offset + portIndex
  }

  /// `getClrIndex`.
  public static func clrPortIndex(_ portIndex: Int, _ attrs: any AttributeSet) -> Int {
    let offset =
      addrPortCount(attrs) + dataPortCount(attrs) + oePortCount(attrs) + wePortCount(attrs)
      + clkPortCount(attrs) + lePortCount(attrs) + bePortCount(attrs)
    let count = clrPortCount(attrs)
    guard count > 0, portIndex >= 0, portIndex < count else { return -1 }
    return offset + portIndex
  }

  // MARK: - Port list

  /// `configurePorts(Instance)`, for a factory whose `offsetBounds` **is**
  /// `DualRamAppearance.offsetBounds`: `DualRam`, and nothing else today.
  public static func ports(_ attrs: any AttributeSet) -> [Port] {
    ports(attrs, width: offsetBounds(attrs).width)
  }

  /// `configurePorts(Instance)`.
  ///
  /// Upstream mutates `instance.setPorts(ps)` in place; here the array is built and returned,
  /// matching `RamAppearance.ports(_:width:)`'s shape.
  ///
  /// **`width` is `instance.getBounds().getWidth()` upstream**, i.e. the *factory's* offset
  /// bounds. `DualRam` does not override `offsetBounds`, so for it the two are the same: but
  /// `Rom` does, and taking the width from the appearance helper instead of the factory is
  /// exactly the defect `RamAppearance.ports(_:width:)` documents. Threading it explicitly here
  /// too keeps the coupling visible at every call site rather than true by luck in this one.
  ///
  /// **Force-unwrap note.** Same invariant `RamAppearance.ports(_:width:)` documents: every slot
  /// from `0..<portCount(attrs)` is written by exactly one of the eight loops below, because each
  /// `*PortIndex` function is a bijection onto `0..<portCount(attrs)` by construction; an
  /// internal invariant no `.circ` file can violate (D13's programmer-error carve-out).
  public static func ports(_ attrs: any AttributeSet, width: Int) -> [Port] {
    var slots = [Port?](repeating: nil, count: portCount(attrs))

    for i in 0..<addrPortCount(attrs) {
      slots[addrPortIndex(i, attrs)] = addrPort(i, attrs)
    }
    for i in 0..<dataInPortCount(attrs) {
      if let port = dataInPort(i, attrs) { slots[dataInPortIndex(i, attrs)] = port }
    }
    let xpos = width
    for i in 0..<dataOutPortCount(attrs) {
      if let port = dataOutPort(i, attrs, xpos: xpos) { slots[dataOutPortIndex(i, attrs)] = port }
    }
    for i in 0..<oePortCount(attrs) {
      if let port = oePort(i, attrs) { slots[oePortIndex(i, attrs)] = port }
    }
    for i in 0..<wePortCount(attrs) {
      if let port = wePort(i, attrs) { slots[wePortIndex(i, attrs)] = port }
    }
    for i in 0..<clkPortCount(attrs) {
      if let port = clkPort(i, attrs) { slots[clkPortIndex(i, attrs)] = port }
    }
    for i in 0..<lePortCount(attrs) {
      if let port = lePort(i, attrs) { slots[lePortIndex(i, attrs)] = port }
    }
    for i in 0..<bePortCount(attrs) {
      if let port = bePort(i, attrs) { slots[bePortIndex(i, attrs)] = port }
    }
    for i in 0..<clrPortCount(attrs) {
      if let port = clrPort(i, attrs) { slots[clrPortIndex(i, attrs)] = port }
    }

    return slots.map { $0! }
  }

  // MARK: - Bounds / control block sizing

  /// `getClassicPortBoffset`: the classic appearance splits its body in half vertically (port A
  /// on top, port B below); this is that half-height, rounded to the nearest 10.
  public static func classicPortBOffset(_ attrs: any AttributeSet) -> Int {
    let totalHeight = controlHeight(attrs) + extraHeight(attrs)
    let rawOffset = totalHeight / 2
    return ((rawOffset + 5) / 10) * 10
  }

  /// `getBounds`.
  public static func offsetBounds(_ attrs: any AttributeSet) -> Bounds {
    let xoffset = separatedBus(attrs) ? 40 : 50
    let widthOffset = classicAppearance(attrs) ? 40 : xoffset
    let totalHeight = controlHeight(attrs) + extraHeight(attrs)
    return Bounds.create(0, 0, Mem.symbolWidth + widthOffset, totalHeight)
  }

  /// `classicAppearance`.
  public static func classicAppearance(_ attrs: any AttributeSet) -> Bool {
    attrs.getValue(StdAttr.appearance) == StdAttr.appearClassic
  }

  /// `getControlHeight`. Doubled relative to `RamAppearance`'s answer (`* 2` at the end): the
  /// two ports' control blocks stack, classic or not.
  public static func controlHeight(_ attrs: any AttributeSet) -> Int {
    var result = 60
    if attrs.containsAttribute(Mem.enables) && attrs.getValue(Mem.enables) == Mem.useLineEnables {
      if !classicAppearance(attrs) { result += 30 }
      result += (lePortCount(attrs) / 2) * 10
    } else if attrs.containsAttribute(StdAttr.trigger) {
      let async = !synchronous(attrs)
      result += 20
      if !async { result += 10 }
      result += (lePortCount(attrs) / 2) * 10
      result += (bePortCount(attrs) / 2) * 10
    }
    return result * 2
  }

  /// `getNrToHighlight`. Upstream keeps this `private`; public here for the same reason
  /// `RamAppearance.highlightCount(_:)` is: the M6 paint code that consumes it lives outside
  /// this file.
  public static func highlightCount(_ attrs: any AttributeSet) -> Int {
    if attrs.containsAttribute(Mem.enables) && attrs.getValue(Mem.enables) == Mem.useByteEnables {
      return 1
    }
    let line = attrs.getValue(Mem.line)
    if line == Mem.dual { return 2 }
    if line == Mem.quad { return 4 }
    if line == Mem.octo { return 8 }
    return 1
  }

  // MARK: - Private helpers

  /// `getExtraHeight`; the data-grid height each port's control block sits above, doubled by
  /// `classicPortBOffset`/`offsetBounds` the same way `controlHeight` doubles the control block.
  private static func extraHeight(_ attrs: any AttributeSet) -> Int {
    let portsLen = (lePortCount(attrs) + 1) * 10
    if classicAppearance(attrs) {
      return max(70, portsLen)
    } else {
      let dataLen = (attrs.getValue(Mem.data)?.width ?? 0) * 40
      return max(dataLen, portsLen)
    }
  }

  /// `getDataOffset`. Simpler than `RamAppearance.dataOffset(_:_:_:)`: `dataOutPortCount(_:)`
  /// already reflects the doubled (A+B) line count in line-enable mode, so a direct
  /// `portOffset + portIndex` covers every line-enable case; byte-enable mode has exactly one
  /// data port per side (`portIndex` 0 or 1).
  private static func dataOffset(portOffset: Int, portIndex: Int, _ attrs: any AttributeSet) -> Int {
    let usesLineEnables =
      !attrs.containsAttribute(Mem.enables) || attrs.getValue(Mem.enables) == Mem.useLineEnables
    if usesLineEnables && portIndex < dataOutPortCount(attrs) {
      return portOffset + portIndex
    }
    if portIndex == 0 { return portOffset }
    if portIndex == 1 { return portOffset + 1 }
    return -1
  }

  /// `getAddrPort`. Tool tip dropped (`memAddrTip`).
  private static func addrPort(_ portIndex: Int, _ attrs: any AttributeSet) -> Port {
    let totalHeight = controlHeight(attrs)
    let singleRamHeight = totalHeight / 2
    var ypos = 0
    let classic = classicAppearance(attrs)
    if !classic {
      let offsetB = singleRamHeight - 10
      ypos = (portIndex == 0) ? 20 : 20 + offsetB
    } else {
      // `nrAddrs / 2`: always 1, since `addrPortCount` is always 2.
      ypos = 10
      if portIndex >= 1 { ypos += classicPortBOffset(attrs) }
    }
    return Port(0, ypos, .input, attrs.getValue(Mem.addr) ?? BitWidth.unknown)
  }

  /// `getDataInPort`. Tool tips dropped (`dualRamInTip`/`dualRamInTip0…3`).
  private static func dataInPort(_ portIndex: Int, _ attrs: any AttributeSet) -> Port? {
    let count = dataInPortCount(attrs)
    guard count > 0, portIndex >= 0, portIndex < count else { return nil }
    let totalHeight = controlHeight(attrs)
    let split = count / 2
    let isClassic = classicAppearance(attrs)
    let bits = attrs.getValue(Mem.data) ?? BitWidth.unknown

    var ypos = isClassic ? (totalHeight / 2) : totalHeight
    if !isClassic && bits.width == 1 { ypos += 10 }
    ypos += (portIndex % split) * 10
    if portIndex >= split {
      ypos += isClassic ? classicPortBOffset(attrs) : (bits.width * 20)
    }
    return Port(0, ypos, .input, bits)
  }

  /// `getDataOutPort`. Tool tips dropped (`memDataTip`/`memDataTip0…3`).
  private static func dataOutPort(_ portIndex: Int, _ attrs: any AttributeSet, xpos: Int) -> Port? {
    let count = dataOutPortCount(attrs)
    guard count > 0, portIndex >= 0, portIndex < count else { return nil }
    let totalHeight = controlHeight(attrs)
    let split = count / 2
    let isClassic = classicAppearance(attrs)
    let bits = attrs.getValue(Mem.data) ?? BitWidth.unknown
    let portType: PortType =
      (!separatedBus(attrs) && attrs.containsAttribute(Mem.enables)) ? .inout_ : .output

    var ypos = isClassic ? (totalHeight / 2) : totalHeight
    if !isClassic && bits.width == 1 { ypos += 10 }
    ypos += (portIndex % split) * 10
    if portIndex >= split {
      ypos += isClassic ? classicPortBOffset(attrs) : (bits.width * 20)
    }
    return Port(xpos, ypos, portType, bits)
  }

  /// `getOEPort`. Tool tip dropped (`ramOETip`).
  private static func oePort(_ portIndex: Int, _ attrs: any AttributeSet) -> Port? {
    let count = oePortCount(attrs)
    guard count > 0, portIndex >= 0, portIndex < count else { return nil }
    let totalHeight = controlHeight(attrs)
    let splitIndex = count / 2
    let isClassic = classicAppearance(attrs)

    var ypos = isClassic ? 60 : 70
    if isClassic && attrs.getValue(Mem.enables) == Mem.useLineEnables { ypos = 20 }
    if !isClassic {
      if portIndex > 0 { ypos += (totalHeight / 2) - 10 }
    } else if portIndex >= splitIndex {
      ypos = classicPortBOffset(attrs) + 60
    }
    return Port(0, ypos, .input, 1)
  }

  /// `getWEPort`. Tool tip dropped (`ramWETip`).
  private static func wePort(_ portIndex: Int, _ attrs: any AttributeSet) -> Port? {
    let count = wePortCount(attrs)
    guard count > 0, portIndex >= 0, portIndex < count else { return nil }
    let totalHeight = controlHeight(attrs)
    let splitIndex = count / 2
    let isClassic = classicAppearance(attrs)

    var ypos = isClassic ? 50 : 60
    if isClassic && attrs.getValue(Mem.enables) == Mem.useLineEnables { ypos = 30 }
    if !isClassic {
      if portIndex > 0 { ypos += (totalHeight / 2) - 10 }
    } else if portIndex >= splitIndex {
      ypos += classicPortBOffset(attrs)
    }
    return Port(0, ypos, .input, 1)
  }

  /// `getClkPort`. Tool tip dropped (`ramClkTip`).
  private static func clkPort(_ portIndex: Int, _ attrs: any AttributeSet) -> Port? {
    let count = clkPortCount(attrs)
    guard count > 0, portIndex >= 0, portIndex < count else { return nil }
    let totalHeight = controlHeight(attrs)
    let splitIndex = count / 2
    let isClassic = classicAppearance(attrs)
    let useLineEnables = attrs.getValue(Mem.enables) == Mem.useLineEnables
    let nrLEs = lePortCount(attrs)
    let nrBEs = bePortCount(attrs)

    var ypos: Int
    if !isClassic {
      ypos = 80 + (nrLEs / 2 * 10) + (nrBEs / 2 * 10)
    } else {
      ypos = useLineEnables ? 40 + (nrLEs * 5) + (nrBEs * 5) : 70
    }
    if !isClassic {
      if portIndex >= splitIndex { ypos += (totalHeight / 2) - 10 }
    } else if portIndex >= splitIndex {
      ypos += classicPortBOffset(attrs)
    }
    return Port(0, ypos, .input, 1)
  }

  /// `getLEPort`. Tool tips dropped (`ramLETip0…3`).
  private static func lePort(_ portIndex: Int, _ attrs: any AttributeSet) -> Port? {
    let count = lePortCount(attrs)
    guard count > 0, portIndex >= 0, portIndex < count else { return nil }
    let totalHeight = controlHeight(attrs)
    let splitIndex = count / 2
    let isClassic = classicAppearance(attrs)
    let useLineEnables = attrs.getValue(Mem.enables) == Mem.useLineEnables

    var ypos = (isClassic && useLineEnables) ? 40 : 80
    if splitIndex > 0 { ypos += (portIndex % splitIndex) * 10 }
    if !isClassic {
      if portIndex >= splitIndex { ypos += (totalHeight / 2) - 10 }
    } else if portIndex >= splitIndex && useLineEnables {
      ypos += classicPortBOffset(attrs)
    }
    return Port(0, ypos, .input, 1)
  }

  /// `getBEPort`. Tool tips dropped (`ramByteEnableTip0…3`).
  private static func bePort(_ portIndex: Int, _ attrs: any AttributeSet) -> Port? {
    let count = bePortCount(attrs)
    guard count > 0, portIndex >= 0, portIndex < count else { return nil }
    let isClassic = classicAppearance(attrs)
    let useByteEnables = attrs.getValue(Mem.enables) == Mem.useByteEnables
    let offsetB = controlHeight(attrs) / 2 - 10
    let splitIndex = count / 2
    let leOffset = (lePortCount(attrs) / 2) * 10
    let relativeIndex = portIndex % splitIndex

    var ypos = 80 + leOffset + (splitIndex - relativeIndex - 1) * 10
    if !isClassic {
      if portIndex >= splitIndex { ypos += offsetB }
    } else if portIndex >= splitIndex && useByteEnables {
      ypos += classicPortBOffset(attrs)
    }
    return Port(0, ypos, .input, 1)
  }

  /// `getClrPort`. Tool tip dropped (`ramClrPin`).
  private static func clrPort(_ portIndex: Int, _ attrs: any AttributeSet) -> Port? {
    guard clrPortCount(attrs) > 0, portIndex == 0 else { return nil }
    return Port(40, 0, .input, 1)
  }

  /// `seperatedBus` (upstream's misspelling corrected here: an internal helper name, never
  /// serialized).
  private static func separatedBus(_ attrs: any AttributeSet) -> Bool {
    let bus = attrs.getValue(DualRamAttributes.dataBus)
    return bus == nil || bus == DualRamAttributes.busSeparate
  }

  /// `synchronous`.
  private static func synchronous(_ attrs: any AttributeSet) -> Bool {
    guard attrs.containsAttribute(StdAttr.trigger) else { return false }
    let trigger = attrs.getValue(StdAttr.trigger)
    return trigger == StdAttr.triggerRising || trigger == StdAttr.triggerFalling
  }

  // MARK: - Painting (M6)

  /// `DualRamAppearance.drawRamClassic(InstancePainter)` (`DualRamAppearance.java:255-324`).
  ///
  /// The contents window is split in half: port A's grid on top, port B's below it, each shown
  /// at its own port's current address. Note upstream drives *both* through `stateA.getCurrent`
  /// , `getCurrent(1)` is `stateB`'s address held on the port-A object, and only `setCurrent`/
  /// `scrollToShow` are called on the respective halves.
  public static func drawRamClassic(_ painter: any MemPainter) {
    let attrs = painter.attributeSet
    let g = painter.graphics
    let bds = painter.bounds
    g.color = MemPaint.componentColor

    drawComponentLabel(painter)
    painter.drawBounds()
    drawConnections(painter)
    drawSizeCaption(painter)

    guard painter.showState, let stateA = painter.data as? DualRamState else { return }
    let stateB = stateA.portBState()
    let highlight = highlightCount(attrs)
    let totalHeight = bds.height - 20
    let halfHeight = totalHeight / 2

    let addrA = stateA.current(portIndex: 0)
    stateA.setCurrent(addrA)
    stateA.scrollToShow(addrA)
    stateA.paint(
      g, leftX: bds.x, topY: bds.y, offsetX: 30, offsetY: 15,
      displayWidth: bds.width - 60, displayHeight: halfHeight, nrItemsToHighlight: highlight)

    let addrB = stateA.current(portIndex: 1)
    stateB.setCurrent(addrB)
    stateB.scrollToShow(addrB)
    stateB.paint(
      g, leftX: bds.x, topY: bds.y, offsetX: 30, offsetY: 15 + halfHeight,
      displayWidth: bds.width - 60, displayHeight: halfHeight, nrItemsToHighlight: highlight)
  }

  /// `DualRamAppearance.drawRamEvolution(InstancePainter)` (`DualRamAppearance.java:326-413`).
  ///
  /// The trailing `stateA.setCurrent(addrA); stateA.scrollToShow(addrA);` is upstream's; it
  /// restores port A's scroll after port B's half has been laid out, and dropping it would let
  /// the two halves fight over one scroll position.
  public static func drawRamEvolution(_ painter: any MemPainter) {
    let attrs = painter.attributeSet
    let g = painter.graphics
    let bds = painter.bounds
    g.color = MemPaint.componentColor

    drawComponentLabel(painter)
    drawControlBlock(painter)
    drawDataBlocks(painter)
    drawConnections(painter)
    drawSizeCaption(painter)

    guard painter.showState, let stateA = painter.data as? DualRamState else { return }
    let stateB = stateA.portBState()
    let highlight = highlightCount(attrs)
    let totalAvailHeight = bds.height - 10 - controlHeight(attrs)
    let boxHeight = (totalAvailHeight / 2) - 5

    let addrA = stateA.current(portIndex: 0)
    stateA.setCurrent(addrA)
    stateA.scrollToShow(addrA)
    stateA.paint(
      g, leftX: bds.x, topY: bds.y, offsetX: 50, offsetY: controlHeight(attrs) + 5,
      displayWidth: bds.width - 100, displayHeight: boxHeight, nrItemsToHighlight: highlight)

    let addrB = stateA.current(portIndex: 1)
    stateB.setCurrent(addrB)
    stateB.scrollToShow(addrB)
    stateB.paint(
      g, leftX: bds.x, topY: bds.y, offsetX: 50,
      offsetY: controlHeight(attrs) + 5 + boxHeight + 10,
      displayWidth: bds.width - 100, displayHeight: boxHeight, nrItemsToHighlight: highlight)

    stateA.setCurrent(addrA)
    stateA.scrollToShow(addrA)
  }

  /// The label preamble both appearances open with: identical to `RamAppearance`'s, duplicated
  /// there too.
  private static func drawComponentLabel(_ painter: any MemPainter) {
    let g = painter.graphics
    let bds = painter.bounds
    guard let label = painter.attributeValue(StdAttr.label),
      painter.attributeValue(StdAttr.labelVisibility, default: true)
    else { return }
    let font = g.font
    let labelFont = MemPaint.sceneFont(
      painter.attributeValue(StdAttr.labelFont, default: StdAttr.defaultLabelFont))
    g.font = labelFont
    g.drawCenteredText(label, x: bds.x + bds.width / 2, y: bds.y - Int(labelFont.size))
    g.font = font
  }

  /// The size caption. Unlike `RamAppearance`'s, the type prefix is unconditional; a dual-port
  /// memory is never a ROM.
  private static func drawSizeCaption(_ painter: any MemPainter) {
    let g = painter.graphics
    let bds = painter.bounds
    let addrBits = painter.attributeValue(Mem.addr)?.width ?? 0
    let dataBits = painter.attributeValue(Mem.data)?.width ?? 0
    g.drawCenteredText(
      "Dual Port RAM " + Mem.sizeLabel(addressBits: addrBits) + " x \(dataBits)",
      x: bds.x + (Mem.symbolWidth / 2) + 20, y: bds.y + 6)
  }

  /// `DualRamAppearance.drawConnections(...)` (`DualRamAppearance.java:731-981`).
  ///
  /// `RamAppearance`'s routine with one structural change per data loop: the "first port" branch
  /// that draws the full bus fan-out fires at `i == 0` **and** at the split index (half the port
  /// count), because a dual-port RAM has two independent buses stacked vertically. Everything
  /// else, the 4-wide stroke, the 7pt derive inside that branch and never undone, the
  /// `Graphics2D` clone around the lot, matches.
  private static func drawConnections(_ painter: any MemPainter) {
    let attrs = painter.attributeSet
    let classic = classicAppearance(attrs)
    let g = painter.graphics

    MemPaint.withGraphicsCopy(g) {
      let font = g.font
      g.strokeWidth = 4
      let nrOfBits = attrs.getValue(Mem.data)?.width ?? 0
      let nrOfDataPorts = max(dataInPortCount(attrs), dataOutPortCount(attrs))

      // Data inputs
      let nrDataIn = dataInPortCount(attrs)
      let inputSplit = nrDataIn / 2
      for i in 0..<nrDataIn {
        let label = !classic ? "" : (nrDataIn == 1 ? "D" : "D\(i)")
        let idx = dataInPortIndex(i, attrs)
        if !classic {
          guard let loc = painter.portLocation(idx) else { return }
          let x = loc.x
          let y = loc.y
          if nrOfBits == 1 {
            g.strokeWidth = 2
            if nrOfDataPorts > 1 {
              g.drawPolyline(
                [x, x + 4 + i * 4, x + 4 + i * 4, x + 20],
                [y, y, y - (i + 1) * 6, y - (i + 1) * 6])
            } else {
              g.drawLine(x, y, x + 20, y)
            }
            g.strokeWidth = 4
          } else if i != 0 && i != inputSplit {
            if i == 3 && nrOfBits == 2 {
              g.drawLine(x, y, x + 4, y - 4)
            } else {
              g.drawLine(x, y, x + 4, y + 4)
            }
          } else {
            var ypos = [y + 5, y + 10, y + 10]
            let xpos = [x + 5, x + 10, x + 20]
            g.strokeWidth = 2
            g.font = MemPaint.derive(font, size: 7)
            g.color = MemPaint.componentColor
            for j in 0..<nrOfBits {
              g.drawPolyline(xpos, ypos)
              g.drawText(
                String(j), x: xpos[2] - 3, y: ypos[2] - 3, halign: .right, valign: .baseline)
              ypos[0] += 20
              ypos[1] += 20
              ypos[2] += 20
            }
            g.color = MemPaint.multiColor
            g.strokeWidth = 4
            g.drawPolyline([x, x + 5, x + 5], [y, y + 5, y + 5 + (nrOfBits - 1) * 20])
          }
        }
        painter.drawPort(idx, label, .east)
      }

      // Data outputs (and in/outs)
      let nrDataOut = dataOutPortCount(attrs)
      let outputSplit = nrDataOut / 2
      for i in 0..<nrDataOut {
        let label = !classic ? "" : (nrDataOut == 1 ? "D" : "D\(i)")
        let idx = dataOutPortIndex(i, attrs)
        if !classic {
          let separate =
            separatedBus(attrs) || !attrs.containsAttribute(DualRamAttributes.dataBus)
          guard let loc = painter.portLocation(idx) else { return }
          let x = loc.x
          let y = loc.y
          if nrOfBits == 1 {
            g.strokeWidth = 2
            if nrOfDataPorts > 1 {
              g.drawPolyline(
                [x, x - (i + 1) * 4, x - (i + 1) * 4, x - 20],
                [y, y, y - (i + 1) * 6, y - (i + 1) * 6])
            } else {
              g.drawLine(x, y, x - 20, y)
            }
            if !separate && i == 0 { drawBidir(g, x - 20, y) }
            g.strokeWidth = 4
          } else if i != 0 && i != outputSplit {
            // Upstream's dual-port copy draws this stub from the port outwards
            // (`loc -> loc - 4`), where `RamAppearance`'s draws it inwards. Same segment, drawn
            // in the opposite direction; kept as written.
            if i == 3 && nrOfBits == 2 {
              g.drawLine(x, y, x - 4, y - 4)
            } else {
              g.drawLine(x, y, x - 4, y + 4)
            }
          } else {
            var ypos = [y + 5, y + 10, y + 10]
            let xpos = [x - 5, x - 10, x - 20]
            g.strokeWidth = 2
            g.font = MemPaint.derive(font, size: 7)
            g.color = MemPaint.componentColor
            for j in 0..<nrOfBits {
              g.drawPolyline(xpos, ypos)
              g.drawText(
                String(j), x: xpos[2] + 3, y: ypos[2] - 3, halign: .left, valign: .baseline)
              if !separate { drawBidir(g, xpos[2], ypos[2]) }
              ypos[0] += 20
              ypos[1] += 20
              ypos[2] += 20
            }
            g.strokeWidth = 4
            g.color = MemPaint.multiColor
            g.drawPolyline([x, x - 5, x - 5], [y, y + 5, y + 5 + (nrOfBits - 1) * 20])
          }
        }
        painter.drawPort(idx, label, .west)
      }

      // Address: two of them here, one per port.
      let nrAddr = addrPortCount(attrs)
      for i in 0..<nrAddr {
        let label = !classic ? "" : (nrAddr == 1 ? "A" : "A\(i)")
        let idx = addrPortIndex(i, attrs)
        if !classic {
          guard let loc = painter.portLocation(idx) else { return }
          let x = loc.x
          let y = loc.y
          let xpos = [x + 5, x + 10, x + 20]
          var ypos = [y + 5, y + 10, y + 10]
          g.strokeWidth = 2
          g.color = MemPaint.componentColor
          g.drawPolyline(xpos, ypos)
          for j in 0..<3 {
            ypos[j] += 20
            if (attrs.getValue(Mem.addr)?.width ?? 0) > 2 {
              g.drawLine(x + 15, y + 13 + j * 6, x + 15, y + 15 + j * 6)
            }
          }
          g.drawPolyline(xpos, ypos)
          g.color = MemPaint.multiColor
          g.strokeWidth = 4
          g.drawPolyline([x, x + 5, x + 5], [y, y + 5, y + 25])
        }
        painter.drawPort(idx, label, .east)
      }

      // Control block connections
      g.color = MemPaint.componentColor
      g.strokeWidth = 2

      let nrOE = oePortCount(attrs)
      for i in 0..<nrOE {
        let label = !classic ? "" : (nrOE == 1 ? "OE" : "OE\(i)")
        let idx = oePortIndex(i, attrs)
        if !classic {
          guard let loc = painter.portLocation(idx) else { return }
          g.drawLine(loc.x, loc.y, loc.x + 20, loc.y)
        }
        painter.drawPort(idx, label, .east)
      }

      let nrWE = wePortCount(attrs)
      for i in 0..<nrWE {
        let label = !classic ? "" : (nrWE == 1 ? "WE" : "WE\(i)")
        let idx = wePortIndex(i, attrs)
        if !classic {
          guard let loc = painter.portLocation(idx) else { return }
          g.drawLine(loc.x, loc.y, loc.x + 20, loc.y)
        }
        painter.drawPort(idx, label, .east)
      }

      let nrClk = clkPortCount(attrs)
      for i in 0..<nrClk {
        let idx = clkPortIndex(i, attrs)
        if !classic {
          guard let loc = painter.portLocation(idx) else { return }
          var xend = 20
          let trigger = attrs.getValue(StdAttr.trigger)
          if trigger == StdAttr.triggerFalling || trigger == StdAttr.triggerLow {
            xend -= 8
            g.drawOval(loc.x + 12, loc.y - 4, 8, 8)
          }
          g.drawLine(loc.x, loc.y, loc.x + xend, loc.y)
          if synchronous(attrs) { painter.drawClockSymbol(loc.x + 20, loc.y) }
          painter.drawPort(idx)
        } else if synchronous(attrs) {
          painter.drawClock(idx, .east)
        } else {
          painter.drawPort(idx, nrClk == 1 ? "E" : "E\(i)", .east)
        }
      }
      // See `RamAppearance.drawConnections`: `drawClock`/`drawClockSymbol` end at width 1, so
      // the LE and BE stubs below are thinner than the OE/WE stubs above.
      if nrClk > 0 { g.strokeWidth = 1 }

      let nrLE = lePortCount(attrs)
      for i in 0..<nrLE {
        let label = !classic ? "" : (nrLE == 1 ? "LE" : "LE\(i)")
        let idx = lePortIndex(i, attrs)
        if !classic {
          guard let loc = painter.portLocation(idx) else { return }
          g.drawLine(loc.x, loc.y, loc.x + 20, loc.y)
        }
        painter.drawPort(idx, label, .east)
      }

      let nrBE = bePortCount(attrs)
      for i in 0..<nrBE {
        let label = !classic ? "" : (nrBE == 1 ? "BE" : "BE\(i)")
        let idx = bePortIndex(i, attrs)
        if !classic {
          guard let loc = painter.portLocation(idx) else { return }
          g.drawLine(loc.x, loc.y, loc.x + 20, loc.y)
        }
        painter.drawPort(idx, label, .east)
      }

      for i in 0..<clrPortCount(attrs) {
        painter.drawPort(clrPortIndex(i, attrs))
      }
    }
  }

  /// `DualRamAppearance.drawControlBlock(...)` (`DualRamAppearance.java:983-1052`).
  private static func drawControlBlock(_ painter: any MemPainter) {
    let attrs = painter.attributeSet
    let g = painter.graphics

    MemPaint.withGraphicsCopy(g) {
      let x = painter.bounds.x
      let y = painter.bounds.y
      let y0 = y + controlHeight(attrs)
      let xpos = [
        x + 30, x + 30, x + 20, x + 20,
        x + Mem.symbolWidth + 20, x + Mem.symbolWidth + 20,
        x + Mem.symbolWidth + 10, x + Mem.symbolWidth + 10,
      ]
      let ypos = [y0, y0 - 10, y0 - 10, y, y, y0 - 10, y0 - 10, y0]
      g.strokeWidth = 2
      g.drawPolyline(xpos, ypos)

      for i in 0..<addrPortCount(attrs) {
        guard let loc = painter.portLocation(addrPortIndex(i, attrs)) else { return }
        drawAddress(g, loc.x, loc.y, attrs.getValue(Mem.addr)?.width ?? 0, i)
      }

      var cidx = 1
      for i in 0..<clkPortCount(attrs) {
        guard let loc = painter.portLocation(clkPortIndex(i, attrs)) else { return }
        g.drawString(synchronous(attrs) ? "C\(cidx)" : "E\(cidx)", x: loc.x + 33, y: loc.y + 5)
        cidx += 1
      }
      for i in 0..<oePortCount(attrs) {
        guard let loc = painter.portLocation(oePortIndex(i, attrs)) else { return }
        g.drawString("M\(cidx) [Output enable]", x: loc.x + 33, y: loc.y + 5)
        cidx += 1
      }
      for i in 0..<wePortCount(attrs) {
        guard let loc = painter.portLocation(wePortIndex(i, attrs)) else { return }
        g.drawString("M\(cidx) [Write enable]", x: loc.x + 33, y: loc.y + 5)
        cidx += 1
      }
      for i in 0..<lePortCount(attrs) {
        guard let loc = painter.portLocation(lePortIndex(i, attrs)) else { return }
        g.drawString("M\(cidx) [Line enable \(i)]", x: loc.x + 33, y: loc.y + 5)
        cidx += 1
      }
      for i in 0..<bePortCount(attrs) {
        guard let loc = painter.portLocation(bePortIndex(i, attrs)) else { return }
        g.drawString("M\(cidx) [Byte enable \(i)]", x: loc.x + 33, y: loc.y + 5)
        cidx += 1
      }
    }
  }

  /// `DualRamAppearance.drawDataBlocks(...)` (`DualRamAppearance.java:1054-1159`).
  ///
  /// Twice `RamAppearance`'s: `nrOfBits` boxes for port A, then `nrOfBits` more for port B
  /// directly beneath, labelled `A1…`/`A2…`. The dependency-index bookkeeping walks *all* the
  /// control ports each pass but only appends the indices belonging to the pass's own port,
  /// which is why `cidx` is incremented unconditionally inside each loop.
  private static func drawDataBlocks(_ painter: any MemPainter) {
    let attrs = painter.attributeSet
    let g = painter.graphics

    MemPaint.withGraphicsCopy(g) {
      let x = painter.bounds.x + 20
      let baseY = painter.bounds.y + controlHeight(attrs)
      let width = Mem.symbolWidth
      let height = 20
      g.font = MemPaint.derive(g.font, size: 9)

      let nrOfBits = attrs.getValue(Mem.data)?.width ?? 0
      let async =
        !synchronous(attrs)
        || (attrs.containsAttribute(Mem.asyncRead) && (attrs.getValue(Mem.asyncRead) ?? false))
      let drawDin = attrs.containsAttribute(DualRamAttributes.dataBus)
      let separate = separatedBus(attrs) || !drawDin

      for p in 0..<2 {
        var y = baseY
        if p == 1 { y += nrOfBits * 20 }
        let portLabel = "A\(p + 1)"
        var doutLabel = portLabel
        var dinLabel = portLabel
        var cidx = 1

        for i in 0..<clkPortCount(attrs) {
          if i == p {
            if !async { doutLabel += ",\(cidx)" }
            dinLabel += ",\(cidx)"
          }
          cidx += 1
        }
        for i in 0..<oePortCount(attrs) {
          if i == p { doutLabel += ",\(cidx)" }
          cidx += 1
        }
        for i in 0..<wePortCount(attrs) {
          if i == p { dinLabel += ",\(cidx)" }
          cidx += 1
        }
        let totalLE = lePortCount(attrs)
        for i in 0..<totalLE {
          let belongs = (p == 0 && i < totalLE / 2) || (p == 1 && i >= totalLE / 2)
          if belongs { dinLabel += ",\(cidx)" }
          cidx += 1
        }

        let appendBE = bePortCount(attrs) > 0
        let beBaseIdx = cidx
        cidx += bePortCount(attrs)
        let dLabel = separate ? "" : "D"

        for i in 0..<nrOfBits {
          g.strokeWidth = 2
          g.drawRect(x, y, width, height)
          g.strokeWidth = 1
          g.drawText(
            doutLabel, x: x - (separate ? 3 : 10) + Mem.symbolWidth, y: y + (separate ? 10 : 5),
            halign: .right, valign: .center)
          if !separate {
            g.drawPolygon(
              [x - 8 + Mem.symbolWidth, x - 5 + Mem.symbolWidth, x - 2 + Mem.symbolWidth],
              [y + 5, y + 8, y + 5])
          }
          var beIndex = ""
          if appendBE {
            let localBE = i >> 3
            let globalBE = (p == 0) ? localBE : (bePortCount(attrs) / 2 + localBE)
            beIndex = ",\(beBaseIdx + globalBE)"
          }
          if drawDin {
            g.drawText(
              dinLabel + beIndex + dLabel,
              x: x + (separate ? 3 : Mem.symbolWidth - 3),
              y: y + (separate ? 10 : 13),
              halign: separate ? .left : .right, valign: .center)
          }
          y += 20
        }
      }
    }
  }

  /// `DualRamAppearance.drawBidir(Graphics2D, int, int)` (`DualRamAppearance.java:1161-1181`),
  /// identical to `RamAppearance`'s.
  private static func drawBidir(_ g: SceneBuilder, _ x: Int, _ y: Int) {
    g.drawPolyline([x - 10, x, x, x - 10], [y - 5, y - 5, y + 5, y + 5])
    g.drawPolyline([x - 4, x - 8, x - 4], [y + 2, y + 5, y + 8])
    g.drawPolyline([x - 6, x - 2, x - 6], [y - 8, y - 5, y - 2])
  }

  /// `DualRamAppearance.drawAddress(Graphics2D, int, int, int, int)`
  /// (`DualRamAppearance.java:1183-1208`).
  ///
  /// Two differences from `RamAppearance.drawAddress`: the label is `A1`/`A2` rather than a bare
  /// `A`, and the span rule sits at `xpos + 70` rather than `xpos + 60` to clear it.
  private static func drawAddress(
    _ g: SceneBuilder, _ xpos: Int, _ ypos: Int, _ nrAddressBits: Int, _ portIndex: Int
  ) {
    g.strokeWidth = 1
    g.drawText("0", x: xpos + 22, y: ypos + 10, halign: .left, valign: .center)
    g.drawText(
      String(nrAddressBits - 1), x: xpos + 22, y: ypos + 30, halign: .left, valign: .center)
    g.drawText(
      "A" + (portIndex == 0 ? "1" : "2"), x: xpos + 50, y: ypos + 20, halign: .left,
      valign: .center)
    g.drawLine(xpos + 40, ypos + 5, xpos + 45, ypos + 10)
    g.drawLine(xpos + 45, ypos + 10, xpos + 45, ypos + 17)
    g.drawLine(xpos + 45, ypos + 17, xpos + 48, ypos + 20)
    g.drawLine(xpos + 48, ypos + 20, xpos + 45, ypos + 23)
    g.drawLine(xpos + 45, ypos + 23, xpos + 45, ypos + 30)
    g.drawLine(xpos + 40, ypos + 35, xpos + 45, ypos + 30)
    let size = String(javaIntBitWidened(nrAddressBits) &- 1)
    let strSize = MemPaint.stringWidth(g, size)
    g.drawLine(xpos + 70, ypos + 20, xpos + 70 + strSize, ypos + 20)
    g.drawText("0", x: xpos + 70 + (strSize / 2), y: ypos + 19, halign: .center, valign: .bottom)
    g.drawText(size, x: xpos + 70 + (strSize / 2), y: ypos + 21, halign: .center, valign: .top)
  }
}

// M6 landed. `drawRamClassic`, `drawRamEvolution`, `drawConnections`, `drawControlBlock`,
// `drawDataBlocks`, `drawBidir` and `drawAddress` are above; they read back this file's own
// port-index functions for each port `DualRamAppearance` placed, and call `MemState.paint`
// twice, once on port A's inherited `MemState`, once on `DualRamState.portBState()`, for the
// two stacked hex-grid contents views.
