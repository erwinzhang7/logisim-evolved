// RamAppearance.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.memory.RamAppearance),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── What this file actually is ──────────────────────────────────────────────────────────────
//
// Despite the name, most of upstream's `RamAppearance` is not drawing at all: it is the port
// *topology* both `Ram` and `Rom` share; how many ports a given attribute combination produces,
// which port index each logical signal (address, data, OE, WE, clock, line-enable, byte-enable,
// clear) lands at, and where each one sits relative to the component's origin. `Ram.propagate`
// calls `RamAppearance.getDataOutIndex`/`getWEIndex`/`getClkIndex`/etc. on **every simulation
// step**, not just once at construction, so this is simulation-critical port logic wearing an
// "Appearance" name, and it has to be exactly right for `Ram`/`Rom`'s `propagate` (ported
// elsewhere) to read and write the correct port.
//
// That part is ported in full below: the `*PortCount`/`*PortIndex` family, `ports(_:)` (upstream
// `configurePorts`), `offsetBounds(_:)` (upstream `getBounds`), `controlHeight(_:)`,
// `classicAppearance(_:)`, and `highlightCount(_:)`.
//
// The other half, `drawRamClassic`, `drawRamEvolution`, `drawConnections`, `drawControlBlock`,
// `drawDataBlocks`, `drawBidir`, `drawAddress`, is the M6 painting, and is now ported at the
// bottom of this file. `Ram`, `Rom` and (through its own file) `DualRam` all drive it; there is
// no third renderer anywhere.
//
// ── `Graphics2D.create()` ───────────────────────────────────────────────────────────────────
//
// Four of those methods open with `painter.getGraphics().create()` and close with `dispose()`,
// then set strokes, fonts and colours freely inside, relying on the clone to discard the lot.
// `SceneBuilder` is one shared emitter by design (D6 explicitly does *not* clone a context per
// component; that is one of the costs the port removes), so `MemPaint.withGraphicsCopy` stands
// in: it saves and restores font, pen and colour around the block, which is the only observable
// difference the clone made.
//
// ── Deviations ───────────────────────────────────────────────────────────────────────────────
//
//   * **Naming.** `get`/`Nr` prefixes are dropped in favour of Swift's property-getter
//     convention (`getNrAddrPorts` → `addrPortCount`, `getAddrIndex` → `addrPortIndex`), matching
//     `InstanceFactory.offsetBounds`/`InstanceState.attributeValue` elsewhere in this module.
//     Every function's doc comment names the exact upstream method so the correspondence is
//     never in doubt.
//   * **No tool tips.** Every `Port(...).setToolTip(...)` call is dropped; `Port` carries none
//     (see `Port.swift`); nothing about port topology or propagation reads them.
//   * **Missing-attribute degradation.** Upstream calls `attrs.getValue(X)` and lets a `null`
//     NPE uncaught (which, if it happened during `propagate`, `Simulator` would still catch and
//     report: D13). This port instead degrades gracefully: an absent `AttributeOption` compares
//     unequal to everything (so a `Mem.dual`/`Mem.quad`/... check simply falls through) and an
//     absent `BitWidth` contributes a width of 0. In practice neither path is reachable,
//     `RamAttributes`/`RomAttributes` (ported alongside `Ram`/`Rom`) answer `Mem.data`/`Mem.line`
//     unconditionally regardless of which attributes are in the current `getAttributes()` list,
//     exactly as `GateAttributes.rawValue` does, but the degradation is strictly safer than a
//     force-unwrap and costs nothing.
//   * `getBounds`'s dead `xoffset` in the classic branch is preserved verbatim (see
//     `offsetBounds(_:)`'s doc comment); it is upstream's own dead code, not a porting slip.
//
// ── Assumed API from `Mem`/`RamAttributes` (owned by the Mem/Ram/Rom slice) ─────────────────
//
// This file does not exist without `Mem`'s port-topology attributes and `RamAttributes`'
// byte-enable/clear-pin attributes. Everything below is assumed to exist with these exact
// names; if the slice that ports `Mem`/`RamAttributes` lands with different names, only the
// call sites in this file need to change, not the logic:
//
//   `Mem.addr`, `Mem.data`                    : Attribute<BitWidth>   (ADDR_ATTR / DATA_ATTR)
//   `Mem.line`                                : Attribute<AttributeOption>  (LINE_ATTR)
//   `Mem.single`, `.dual`, `.quad`, `.octo`    : AttributeOption  (SINGLE/DUAL/QUAD/OCTO)
//   `Mem.enables`                             : Attribute<AttributeOption>  (ENABLES_ATTR)
//   `Mem.useByteEnables`, `.useLineEnables`   : AttributeOption  (USEBYTEENABLES/USELINEENABLES)
//   `Mem.symbolWidth`                         : Int  (SymbolWidth, = 200)
//   `RamAttributes.byteEnables`               : Attribute<AttributeOption>  (ATTR_ByteEnables)
//   `RamAttributes.busWithByteEnables`        : AttributeOption  (BUS_WITH_BYTEENABLES)
//   `RamAttributes.dataBus`                   : Attribute<AttributeOption>  (ATTR_DBUS)
//   `RamAttributes.busSeparate`               : AttributeOption  (BUS_SEP)
//   `RamAttributes.clearPin`                  : Attribute<Bool>  (CLEAR_PIN)
//   `StdAttr.appearance`, `.appearClassic`, `.trigger`, `.triggerRising`, `.triggerFalling`
//     : all already ported (`LogisimFile/StdAttr.swift`).

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

/// `com.cburch.logisim.std.memory.RamAppearance`: port topology shared by `Ram` and `Rom`.
/// A pure-static namespace, like `GateFunctions`; nothing here is instantiated.
public enum RamAppearance {

  // MARK: - Port counts

  /// `getNrAddrPorts`. Always exactly one address port.
  public static func addrPortCount(_ attrs: any AttributeSet) -> Int { 1 }

  /// `getNrDataInPorts`.
  public static func dataInPortCount(_ attrs: any AttributeSet) -> Int {
    separatedBus(attrs) ? dataOutPortCount(attrs) : 0
  }

  /// `getNrDataOutPorts`.
  public static func dataOutPortCount(_ attrs: any AttributeSet) -> Int {
    let enables = attrs.getValue(Mem.enables)
    if enables == nil || enables == Mem.useLineEnables {
      let line = attrs.getValue(Mem.line)
      if line == Mem.dual { return 2 }
      if line == Mem.quad { return 4 }
      if line == Mem.octo { return 8 }
    }
    return 1
  }

  /// `getNrDataPorts`.
  public static func dataPortCount(_ attrs: any AttributeSet) -> Int {
    dataInPortCount(attrs) + dataOutPortCount(attrs)
  }

  /// `getNrOEPorts`.
  public static func oePortCount(_ attrs: any AttributeSet) -> Int {
    guard attrs.containsAttribute(Mem.enables) else { return 0 }
    let separated = separatedBus(attrs)
    return (!separated || attrs.getValue(Mem.enables) == Mem.useByteEnables) ? 1 : 0
  }

  /// `getNrWEPorts`.
  public static func wePortCount(_ attrs: any AttributeSet) -> Int {
    attrs.containsAttribute(Mem.enables) ? 1 : 0
  }

  /// `getNrClkPorts`.
  public static func clkPortCount(_ attrs: any AttributeSet) -> Int {
    guard attrs.containsAttribute(Mem.enables) else { return 0 }
    let async = !synchronous(attrs)
    return (async && attrs.getValue(Mem.enables) == Mem.useByteEnables) ? 0 : 1
  }

  /// `getNrLEPorts`.
  public static func lePortCount(_ attrs: any AttributeSet) -> Int {
    guard attrs.containsAttribute(Mem.enables) else { return 0 }
    guard attrs.getValue(Mem.enables) == Mem.useLineEnables else { return 0 }
    let line = attrs.getValue(Mem.line)
    if line == Mem.dual { return 2 }
    if line == Mem.quad { return 4 }
    if line == Mem.octo { return 8 }
    return 0
  }

  /// `getNrBEPorts`.
  public static func bePortCount(_ attrs: any AttributeSet) -> Int {
    guard attrs.containsAttribute(Mem.enables) else { return 0 }
    let async = !synchronous(attrs)
    guard
      attrs.getValue(Mem.enables) == Mem.useByteEnables,
      attrs.getValue(RamAttributes.byteEnables) == RamAttributes.busWithByteEnables,
      !async
    else { return 0 }
    let bits = attrs.getValue(Mem.data)?.width ?? 0
    return bits < 9 ? 0 : (bits + 7) >> 3
  }

  /// `getNrClrPorts`.
  public static func clrPortCount(_ attrs: any AttributeSet) -> Int {
    (attrs.containsAttribute(RamAttributes.clearPin) && (attrs.getValue(RamAttributes.clearPin) ?? false))
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
    portIndex == 0 ? 0 : -1
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
    guard clkPortCount(attrs) > 0, portIndex == 0 else { return -1 }
    return offset
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
  /// `RamAppearance.offsetBounds`: `Ram` and `DualRam`, and nothing else.
  ///
  /// `Rom` overrides `offsetBounds` and must call the two-argument form below. Routing every
  /// caller through that form is deliberate: the coupling between "which bounds the ports are
  /// placed against" and "which bounds the factory reports" is upstream's, and it should be
  /// visible at the call site rather than re-derived here.
  public static func ports(_ attrs: any AttributeSet) -> [Port] {
    ports(attrs, width: offsetBounds(attrs).width)
  }

  /// `configurePorts(Instance)`.
  ///
  /// Upstream mutates `instance.setPorts(ps)` in place; here the array is built and returned,
  /// matching `InstanceFactory.ports(_:)`'s shape.
  ///
  /// **`width` is `instance.getBounds().getWidth()` upstream** (`RamAppearance.java:183`); that
  /// is the **factory's** offset bounds, which is NOT always `RamAppearance.offsetBounds(attrs)`.
  /// `Rom.getOffsetBounds` (`Rom.java:166-173`) overrides it and returns `SymbolWidth + 40` in
  /// both appearance branches, never consulting `xoffset`. `RamAppearance.getBounds`
  /// (`:199-208`) uses `xoffset = seperatedBus(attrs) ? 40 : 50`, and `seperatedBus` reads
  /// `RamAttributes.ATTR_DBUS`, which `RomAttributes.getValue` returns `null` for
  /// (`RomAttributes.java:106-134`). So for a ROM the shared function yields 250 where the
  /// factory reports 240, and taking the width from the wrong one puts the data output 10 units
  /// to the right of the wire the file connects to. Nothing is then attached to the ROM, it
  /// drives no net, and every reader downstream sees `U`.
  ///
  /// Only the *evolution* appearance diverges: the classic branch of `getBounds` hardcodes
  /// `+ 40` and ignores `xoffset`, so it agrees with `Rom`'s override. That is exactly the split
  /// the corpus shows: 0 of 12 classic ROM oracles mismatched, 13 of 21 evolution ones did.
  ///
  /// Pinned against literal 4.1.0 jar output by `RomPortGeometryTests`, via
  /// `tools/valuebridge/RomBridge.java`.
  ///
  /// **Force-unwrap note.** Every slot from `0..<portCount(attrs)` is written by exactly one of
  /// the eight loops below, because each `*PortIndex` function is a bijection onto
  /// `0..<portCount(attrs)` by construction (this is upstream's own invariant, not something
  /// this port adds). A `nil` surviving to the final `map` would mean the index/count functions
  /// above disagree with each other; an internal invariant no `.circ` file can violate, since
  /// it depends only on the attribute set's own internally-consistent fields (D13's "genuine
  /// programmer error" carve-out).
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

  /// `getBounds`.
  ///
  /// **Upstream bug, preserved.** `xoffset` (40 when the data bus is separated, else 50) is
  /// computed unconditionally but only ever *used* in the non-classic branch; the classic branch
  /// hardcodes `+ 40` regardless of `separatedBus`. So a classic-appearance RAM with a separated
  /// bus is one unit narrower than the `xoffset` computation implies. Not "fixed" here;
  /// changing it would resize every classic-appearance RAM/ROM already saved with this shape.
  public static func offsetBounds(_ attrs: any AttributeSet) -> Bounds {
    let xoffset = separatedBus(attrs) ? 40 : 50
    if classicAppearance(attrs) {
      let len = max(64, (lePortCount(attrs) + 1) * 10)
      return Bounds.create(0, 0, Mem.symbolWidth + 40, controlHeight(attrs) + len)
    } else {
      let len = max((attrs.getValue(Mem.data)?.width ?? 0) * 20, (lePortCount(attrs) + 1) * 10)
      return Bounds.create(0, 0, Mem.symbolWidth + xoffset, controlHeight(attrs) + len)
    }
  }

  /// `classicAppearance`.
  public static func classicAppearance(_ attrs: any AttributeSet) -> Bool {
    attrs.getValue(StdAttr.appearance) == StdAttr.appearClassic
  }

  /// `getControlHeight`.
  public static func controlHeight(_ attrs: any AttributeSet) -> Int {
    var result = 60
    if attrs.containsAttribute(Mem.enables) && attrs.getValue(Mem.enables) == Mem.useLineEnables {
      if !classicAppearance(attrs) { result += 30 }
      result += lePortCount(attrs) * 10
    } else if attrs.containsAttribute(StdAttr.trigger) {
      let async = !synchronous(attrs)
      result += 20
      if !async { result += 10 }
      result += bePortCount(attrs) * 10
    }
    return result
  }

  /// `getNrToHighlight`. Upstream keeps this `private`; it stays `public` here because the M6
  /// paint code that consumes it (`drawRamClassic`/`drawRamEvolution` → `MemState.paint`) lives
  /// outside this file.
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

  /// `getDataOffset`.
  private static func dataOffset(portOffset: Int, portIndex: Int, _ attrs: any AttributeSet) -> Int {
    let usesLineEnables =
      !attrs.containsAttribute(Mem.enables) || attrs.getValue(Mem.enables) == Mem.useLineEnables
    let line = attrs.getValue(Mem.line)
    switch portIndex {
    case 0:
      return portOffset
    case 1:
      return (usesLineEnables && line != Mem.single) ? portOffset + 1 : -1
    case 2, 3:
      return (usesLineEnables && (line == Mem.quad || line == Mem.octo)) ? portOffset + portIndex : -1
    case 4, 5, 6, 7:
      return (usesLineEnables && line == Mem.octo) ? portOffset + portIndex : -1
    default:
      return -1
    }
  }

  /// `getAddrPort`. Tool tip dropped (`memAddrTip`).
  private static func addrPort(_ portIndex: Int, _ attrs: any AttributeSet) -> Port {
    Port(0, 10, .input, attrs.getValue(Mem.addr) ?? BitWidth.unknown)
  }

  /// `getDataInPort`. Tool tips dropped (`ramInTip`/`ramInTip0…3`).
  private static func dataInPort(_ portIndex: Int, _ attrs: any AttributeSet) -> Port? {
    let count = dataInPortCount(attrs)
    guard count > 0, portIndex >= 0, portIndex < count else { return nil }
    var ypos = controlHeight(attrs)
    let bits = attrs.getValue(Mem.data) ?? BitWidth.unknown
    if !classicAppearance(attrs) && bits.width == 1 { ypos += 10 }
    ypos += portIndex * 10
    return Port(0, ypos, .input, bits)
  }

  /// `getDataOutPort`. Tool tips dropped (`memDataTip`/`memDataTip0…3`).
  private static func dataOutPort(_ portIndex: Int, _ attrs: any AttributeSet, xpos: Int) -> Port? {
    let count = dataOutPortCount(attrs)
    guard count > 0, portIndex >= 0, portIndex < count else { return nil }
    var ypos = controlHeight(attrs)
    let portType: PortType =
      (!separatedBus(attrs) && attrs.containsAttribute(Mem.enables)) ? .inout_ : .output
    let bits = attrs.getValue(Mem.data) ?? BitWidth.unknown
    if !classicAppearance(attrs) && bits.width == 1 { ypos += 10 }
    ypos += portIndex * 10
    return Port(xpos, ypos, portType, bits)
  }

  /// `getOEPort`. Tool tip dropped (`ramOETip`).
  private static func oePort(_ portIndex: Int, _ attrs: any AttributeSet) -> Port? {
    let count = oePortCount(attrs)
    guard count > 0, portIndex >= 0, portIndex < count else { return nil }
    let ypos = (attrs.getValue(Mem.enables) == Mem.useLineEnables && classicAppearance(attrs)) ? 20 : 60
    return Port(0, ypos, .input, 1)
  }

  /// `getWEPort`. Tool tip dropped (`ramWETip`).
  private static func wePort(_ portIndex: Int, _ attrs: any AttributeSet) -> Port? {
    let count = wePortCount(attrs)
    guard count > 0, portIndex >= 0, portIndex < count else { return nil }
    let ypos = (attrs.getValue(Mem.enables) == Mem.useLineEnables && classicAppearance(attrs)) ? 30 : 50
    return Port(0, ypos, .input, 1)
  }

  /// `getClkPort`. Tool tip dropped (`ramClkTip`).
  private static func clkPort(_ portIndex: Int, _ attrs: any AttributeSet) -> Port? {
    let count = clkPortCount(attrs)
    guard count > 0, portIndex >= 0, portIndex < count else { return nil }
    var ypos = (attrs.getValue(Mem.enables) == Mem.useLineEnables && classicAppearance(attrs)) ? 40 : 70
    ypos += lePortCount(attrs) * 10
    ypos += bePortCount(attrs) * 10
    return Port(0, ypos, .input, 1)
  }

  /// `getLEPort`. Tool tips dropped (`ramLETip0…3`).
  private static func lePort(_ portIndex: Int, _ attrs: any AttributeSet) -> Port? {
    let count = lePortCount(attrs)
    guard count > 0, portIndex >= 0, portIndex < count else { return nil }
    var ypos = (attrs.getValue(Mem.enables) == Mem.useLineEnables && classicAppearance(attrs)) ? 40 : 70
    ypos += portIndex * 10
    return Port(0, ypos, .input, 1)
  }

  /// `getBEPort`. Tool tips dropped (`ramByteEnableTip0…3`).
  private static func bePort(_ portIndex: Int, _ attrs: any AttributeSet) -> Port? {
    let count = bePortCount(attrs)
    guard count > 0, portIndex >= 0, portIndex < count else { return nil }
    let ypos = 70 + (count - portIndex - 1) * 10
    return Port(0, ypos, .input, 1)
  }

  /// `getClrPort`. Tool tip dropped (`ramClrPin`).
  private static func clrPort(_ portIndex: Int, _ attrs: any AttributeSet) -> Port? {
    guard clrPortCount(attrs) > 0, portIndex == 0 else { return nil }
    return Port(40, 0, .input, 1)
  }

  /// `seperatedBus` (upstream's spelling; corrected here since this is an internal helper name,
  /// never serialized).
  private static func separatedBus(_ attrs: any AttributeSet) -> Bool {
    attrs.getValue(RamAttributes.dataBus) == RamAttributes.busSeparate
  }

  /// `synchronous`.
  private static func synchronous(_ attrs: any AttributeSet) -> Bool {
    guard attrs.containsAttribute(StdAttr.trigger) else { return false }
    let trigger = attrs.getValue(StdAttr.trigger)
    return trigger == StdAttr.triggerRising || trigger == StdAttr.triggerFalling
  }

  // MARK: - Painting (M6)

  /// `RamAppearance.drawRamClassic(InstancePainter)` (`RamAppearance.java:216-255`).
  public static func drawRamClassic(_ painter: any MemPainter) {
    let attrs = painter.attributeSet
    let g = painter.graphics
    let bds = painter.bounds
    g.color = MemPaint.componentColor

    drawComponentLabel(painter)
    painter.drawBounds()
    drawConnections(painter)
    drawSizeCaption(painter)

    if painter.showState, let state = painter.data as? MemState {
      state.paint(
        g, leftX: bds.x, topY: bds.y, offsetX: 30, offsetY: 15,
        displayWidth: bds.width - 60, displayHeight: bds.height - 20,
        nrItemsToHighlight: highlightCount(attrs))
    }
  }

  /// `RamAppearance.drawRamEvolution(InstancePainter)` (`RamAppearance.java:257-296`).
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

    if painter.showState, let state = painter.data as? MemState {
      state.paint(
        g, leftX: bds.x, topY: bds.y, offsetX: 50, offsetY: controlHeight(attrs) + 5,
        displayWidth: bds.width - 100,
        displayHeight: bds.height - 10 - controlHeight(attrs),
        nrItemsToHighlight: highlightCount(attrs))
    }
  }

  /// The shared "draw label" preamble both appearances open with. Not a separate method
  /// upstream, the seven lines are duplicated verbatim in `drawRamClassic` and
  /// `drawRamEvolution`, but factoring two identical copies is not a behaviour change.
  ///
  /// Note the vertical placement: `bds.getY() - g.getFont().getSize()`, read *after*
  /// `setFont(LABEL_FONT)`, so the offset is the label font's own point size.
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

  /// The "draw the size" caption both appearances close with;
  /// `"RAM "`/`"ROM "` + `Mem.getSizeLabel(addrBits)` + `" x "` + data width.
  ///
  /// The type prefix is upstream's `inst.getFactory() instanceof Ram ? "RAM " : "ROM "`,
  /// flagged `// FIXME: hardcoded string` in the Java. `DualRamAppearance` has its own copy that
  /// says `"Dual Port RAM "` unconditionally.
  private static func drawSizeCaption(_ painter: any MemPainter) {
    let g = painter.graphics
    let bds = painter.bounds
    let type = painter.factory is Ram ? "RAM " : "ROM "
    let addrBits = painter.attributeValue(Mem.addr)?.width ?? 0
    let dataBits = painter.attributeValue(Mem.data)?.width ?? 0
    g.drawCenteredText(
      type + Mem.sizeLabel(addressBits: addrBits) + " x \(dataBits)",
      x: bds.x + (Mem.symbolWidth / 2) + 20, y: bds.y + 6)
  }

  /// `RamAppearance.drawConnections(Instance, AttributeSet, InstancePainter)`
  /// (`RamAppearance.java:516-756`): every port stub, bus fan-out and clock marker.
  ///
  /// Two font details that look like slips and are not: the 7pt derive happens *inside* the
  /// `i == 0` branch of the data loops and is never undone within the routine, so every
  /// subsequent caption in the block is drawn at 7pt; and the whole routine runs inside a
  /// `Graphics2D` clone, so none of it escapes.
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
          } else if i != 0 {
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
            g.drawPolyline(
              [x, x + 5, x + 5], [y, y + 5, y + 5 + (nrOfBits - 1) * 20])
          }
        }
        painter.drawPort(idx, label, .east)
      }

      // Data outputs (and in/outs)
      let nrDataOut = dataOutPortCount(attrs)
      for i in 0..<nrDataOut {
        let label = !classic ? "" : (nrDataOut == 1 ? "D" : "D\(i)")
        let idx = dataOutPortIndex(i, attrs)
        if !classic {
          let separate = separatedBus(attrs) || !attrs.containsAttribute(RamAttributes.dataBus)
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
          } else if i != 0 {
            if i == 3 && nrOfBits == 2 {
              g.drawLine(x - 4, y - 4, x, y)
            } else {
              g.drawLine(x - 4, y + 4, x, y)
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
            g.drawPolyline(
              [x, x - 5, x - 5], [y, y + 5, y + 5 + (nrOfBits - 1) * 20])
          }
        }
        painter.drawPort(idx, label, .west)
      }

      // Address
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
      // Both `drawClock` and `drawClockSymbol` end with `switchToWidth(g, 1)` in
      // `ComponentDrawContext`, so once a clock port has been drawn the LE and BE stubs below
      // come out at width 1, not the 2 set before the OE loop. With no clock port the width
      // stays at 2. Restated rather than assumed: see `MemPainter`'s pen-width contract.
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

  /// `RamAppearance.drawControlBlock(Instance, AttributeSet, InstancePainter)`
  /// (`RamAppearance.java:758-828`): the notched outline over the data blocks, plus the IEC
  /// dependency captions (`C1`, `M2 [Output enable]`, …), numbered in port order.
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
        drawAddress(g, loc.x, loc.y, attrs.getValue(Mem.addr)?.width ?? 0)
      }

      var cidx = 1
      for i in 0..<clkPortCount(attrs) {
        guard let loc = painter.portLocation(clkPortIndex(i, attrs)) else { return }
        let label = synchronous(attrs) ? "C\(cidx)" : "E\(cidx)"
        cidx += 1
        g.drawString(label, x: loc.x + 33, y: loc.y + 5)
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

  /// `RamAppearance.drawDataBlocks(Instance, AttributeSet, InstancePainter)`
  /// (`RamAppearance.java:830-896`): one 20-high box per data bit, captioned with the
  /// dependency indices its output (and, on a separate-bus RAM, its input) obeys.
  private static func drawDataBlocks(_ painter: any MemPainter) {
    let attrs = painter.attributeSet
    let g = painter.graphics

    MemPaint.withGraphicsCopy(g) {
      let x = painter.bounds.x + 20
      var y = painter.bounds.y + controlHeight(attrs)
      let width = Mem.symbolWidth
      let height = 20
      g.font = MemPaint.derive(g.font, size: 9)
      let nrOfBits = attrs.getValue(Mem.data)?.width ?? 0
      var doutLabel = "A"
      var dinLabel = "A"
      var cidx = 1
      let async =
        !synchronous(attrs)
        || (attrs.containsAttribute(Mem.asyncRead) && (attrs.getValue(Mem.asyncRead) ?? false))
      let drawDin = attrs.containsAttribute(RamAttributes.dataBus)
      let separate = separatedBus(attrs) || !drawDin

      for _ in 0..<clkPortCount(attrs) {
        if !async { doutLabel += ",\(cidx)" }
        dinLabel += ",\(cidx)"
        cidx += 1
      }
      for _ in 0..<oePortCount(attrs) {
        doutLabel += ",\(cidx)"
        cidx += 1
      }
      for _ in 0..<wePortCount(attrs) {
        dinLabel += ",\(cidx)"
        cidx += 1
      }
      for _ in 0..<lePortCount(attrs) {
        dinLabel += ",\(cidx)"
        cidx += 1
      }
      let appendBE = bePortCount(attrs) > 0
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
          beIndex = ",\(cidx + (i >> 3))"
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

  /// `RamAppearance.drawBidir(Graphics2D, int, int)` (`RamAppearance.java:898-918`): the
  /// double-headed arrow marking a shared data bus.
  private static func drawBidir(_ g: SceneBuilder, _ x: Int, _ y: Int) {
    g.drawPolyline([x - 10, x, x, x - 10], [y - 5, y - 5, y + 5, y + 5])
    g.drawPolyline([x - 4, x - 8, x - 4], [y + 2, y + 5, y + 8])
    g.drawPolyline([x - 6, x - 2, x - 6], [y - 8, y - 5, y - 2])
  }

  /// `RamAppearance.drawAddress(Graphics2D, int, int, int)` (`RamAppearance.java:920-944`): the
  /// `0 … n-1` address-range bracket and the `0 … 2^n-1` span rule beside the `A` label.
  ///
  /// The span rule's length is measured, not assumed: it is `stringWidth` of the decimal
  /// `2^n - 1`, which is what centres the two numbers over it.
  private static func drawAddress(
    _ g: SceneBuilder, _ xpos: Int, _ ypos: Int, _ nrAddressBits: Int
  ) {
    g.strokeWidth = 1
    g.drawText("0", x: xpos + 22, y: ypos + 10, halign: .left, valign: .center)
    g.drawText(
      String(nrAddressBits - 1), x: xpos + 22, y: ypos + 30, halign: .left, valign: .center)
    g.drawText("A", x: xpos + 50, y: ypos + 20, halign: .left, valign: .center)
    g.drawLine(xpos + 40, ypos + 5, xpos + 45, ypos + 10)
    g.drawLine(xpos + 45, ypos + 10, xpos + 45, ypos + 17)
    g.drawLine(xpos + 45, ypos + 17, xpos + 48, ypos + 20)
    g.drawLine(xpos + 48, ypos + 20, xpos + 45, ypos + 23)
    g.drawLine(xpos + 45, ypos + 23, xpos + 45, ypos + 30)
    g.drawLine(xpos + 40, ypos + 35, xpos + 45, ypos + 30)
    // `Long.toString((1 << nrAddressBits) - 1)`: an `int` shift widened to `long`, so
    // `javaIntBitWidened` is the faithful spelling even though `Mem.ADDR_ATTR` caps the width
    // at 24 and it can never overflow in practice.
    let size = String(javaIntBitWidened(nrAddressBits) &- 1)
    let strSize = MemPaint.stringWidth(g, size)
    g.drawLine(xpos + 60, ypos + 20, xpos + 60 + strSize, ypos + 20)
    g.drawText(
      "0", x: xpos + 60 + (strSize / 2), y: ypos + 19, halign: .center, valign: .bottom)
    g.drawText(
      size, x: xpos + 60 + (strSize / 2), y: ypos + 21, halign: .center, valign: .top)
  }
}

// M6 landed. `drawRamClassic`, `drawRamEvolution`, `drawConnections`, `drawControlBlock`,
// `drawDataBlocks`, `drawBidir` and `drawAddress` are above; they read back this file's own
// port-index functions (one `painter.portLocation(idx)` per port `RamAppearance` placed) and
// call `MemState.paint` for the live hex-grid contents view, with `highlightCount(_:)`
// (upstream `getNrToHighlight`) as its highlight argument.
