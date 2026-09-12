// VgaState.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.soc.vga.VgaState),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// The "vga/display peripheral" the task brief calls out: a memory-mapped framebuffer read by
// hidden bus transactions on demand (`loadImage`) and kept live afterward by sniffing every bus
// write that lands inside the buffer range (`sniffTransaction`): plus a tiny one-word control
// register that lets running software query/select among the "soft" (software-selectable)
// display modes.
//
// ── Seam: framebuffer storage, not `BufferedImage` ──────────────────────────────────────────────
//
// D9 forbids any AppKit/CoreGraphics-adjacent type in this module, and `java.awt.image
// .BufferedImage` is exactly that. The framebuffer is instead a flat `[Int32]` of packed
// 0x00RRGGBB pixels (`BufferedImage.TYPE_INT_RGB`'s exact in-memory format, alpha byte ignored on
// both read and write: matching `setRGB`/`getRGB` on a `TYPE_INT_RGB` image), row-major,
// `lineSize` wide. `LogisimRender` turns this into an actual bitmap for display; every numeric
// operation that mattered (index arithmetic, the `SocBusTransaction` round-trip for lazy
// loading) is preserved exactly.
//
// Not ported: `paint(Graphics, CircuitState)` (`g.drawImage(...)`, the renderer draws
// `pixels` directly), `SocVgaShape` (the appearance-editor "dynamic element" for embedding a VGA
// display in a subcircuit's custom appearance, a `DynamicElement` subclass that is pure
// drawing/serialisation-of-drawing-parameters, D6/D9).

import Foundation
import LogisimFile
import LogisimKernel
import LogisimStd

/// `VgaAttributes.MODE_160_120` … `MODE_1024_768`, as an ordered, total enum. Java keeps these
/// as bare `int` indices into `VgaAttributes.MODES`; the raw value is preserved so
/// `SocSupport`/register-format compatibility (`MODE_xxx_MASK = 1 << MODE_xxx`) reads exactly
/// like upstream.
public enum VgaMode: Int32, CaseIterable, Sendable {
  case mode160x120 = 0
  case mode320x240 = 1
  case mode640x480 = 2
  case mode800x600 = 3
  case mode1024x768 = 4

  public var mask: Int32 { 1 &<< rawValue }

  public var dimensions: (width: Int, height: Int) {
    switch self {
    case .mode160x120: return (160, 120)
    case .mode320x240: return (320, 240)
    case .mode640x480: return (640, 480)
    case .mode800x600: return (800, 600)
    case .mode1024x768: return (1024, 768)
    }
  }

  /// `AttributeOption` identity for this mode, per `VgaAttributes.MODE_ARRAY`'s tokens.
  public var attributeName: String {
    switch self {
    case .mode160x120: return "160x120"
    case .mode320x240: return "320x240"
    case .mode640x480: return "640x480"
    case .mode800x600: return "800x600"
    case .mode1024x768: return "1024x768"
    }
  }
}

extension VgaMode: AttributeOptionValue {
  public var attributeOptionName: String { attributeName }
}

/// `VgaState.VgaDisplayState`: the per-simulation-run framebuffer.
public final class VgaDisplayState: InstanceData {
  private weak var owner: VgaState?
  private var modeValue: VgaMode
  private var modeSetBySoftware = false
  public private(set) var lineSize = 0
  public private(set) var nrOfLines = 0
  /// Packed `0x00RRGGBB` pixels, row-major; see file header. `internal` (not `private`) so
  /// `VgaState.sniffTransaction` can poke a single pixel without a per-write allocation.
  var pixels: [Int32] = []
  private var reload = true

  fileprivate init(owner: VgaState?) {
    self.owner = owner
    self.modeValue = owner?.displayMode ?? .mode160x120
    _ = sizeChanged(initialSize: true)
  }

  /// `getMode()`.
  public var mode: VgaMode { modeSetBySoftware ? modeValue : (owner?.displayMode ?? modeValue) }

  /// `setSoftMode(int)`.
  @discardableResult
  public func setSoftMode(_ mode: VgaMode) -> Bool {
    modeSetBySoftware = true
    guard mode != modeValue else { return false }
    modeValue = mode
    return sizeChanged(initialSize: false)
  }

  /// `getImage(CircuitState)`; loads on demand (see `loadImage`) and returns the framebuffer.
  public func image(circuitState: any SocCircuitStateToken) -> (width: Int, height: Int, pixels: [Int32]) {
    loadImage(circuitState: circuitState)
    return (lineSize, nrOfLines, pixels)
  }

  /// `sizeChanged(boolean)`.
  @discardableResult
  public func sizeChanged(initialSize: Bool) -> Bool {
    if initialSize && modeSetBySoftware { return false }
    clear()
    (lineSize, nrOfLines) = mode.dimensions
    pixels = [Int32](repeating: 0, count: lineSize * nrOfLines)
    return true
  }

  /// `getDataSize()`.
  public var dataSize: Int { lineSize * nrOfLines }

  /// `clear()`.
  public func clear() { reload = true }

  /// `loadImage(CircuitState)`; one hidden read transaction per pixel, exactly as upstream.
  private func loadImage(circuitState: any SocCircuitStateToken) {
    guard reload, let owner else { return }
    for line in 0..<nrOfLines {
      for pixel in 0..<lineSize {
        let index = line * lineSize + pixel
        let trans = SocBusTransaction(
          kind: .read, address: owner.vgaBufferAddress &+ Int32(index) &* 4, writeData: 0,
          accessType: .word, initiator: "vgadma")
        trans.setAsHidden()
        owner.initializeTransaction(trans, busId: owner.busInfo.busId, circuitState: circuitState)
        pixels[index] = trans.hasError ? 0 : trans.readData
      }
    }
    reload = false
  }

  public func cloneData() -> any InstanceData {
    let copy = VgaDisplayState(owner: owner)
    copy.modeValue = modeValue
    copy.modeSetBySoftware = modeSetBySoftware
    copy.lineSize = lineSize
    copy.nrOfLines = nrOfLines
    copy.pixels = pixels
    copy.reload = reload
    return copy
  }
}

/// `com.cburch.logisim.soc.vga.VgaState`.
public final class VgaState: SocBusSlaveInterface, SocBusSnifferInterface, SocBusMasterInterface {
  private var startAddressValue: Int32 = 0
  public private(set) var vgaBufferAddress: Int32 = 0
  public private(set) var displayMode: VgaMode = .mode160x120
  private let attachedBus = SocBusInfo("")
  private var labelValue = ""
  public private(set) var soft160x120 = true
  public private(set) var soft320x240 = true
  public private(set) var soft640x480 = true
  public private(set) var soft800x600 = false
  public private(set) var soft1024x768 = false
  private var listeners: [any SocBusSlaveListener] = []

  public init() {}

  public var busInfo: SocBusInfo { attachedBus }
  public var startAddress: Int32 { startAddressValue }
  public var label: String { labelValue }

  /// `getInitialMode()`.
  public var initialMode: VgaMode { displayMode }

  /// `getCurrentMode()`.
  public var currentMode: VgaMode {
    (attachedBus.simulationManager.flatMap { manager in
      attachedBus.component.flatMap { manager.data(for: $0) as? VgaDisplayState }
    })?.mode ?? displayMode
  }

  @discardableResult
  public func setStartAddress(_ value: Int32) -> Bool {
    guard value != startAddressValue else { return false }
    startAddressValue = value
    fireMemMapChanged()
    return true
  }

  /// `setInitialMode(AttributeOption)`. The size-change notification (re-fitting the on-canvas
  /// bounds/label) is a paint/layout concern; the UI observes `currentMode` after this returns
  /// `true` and re-lays-out itself, rather than this model reaching back into
  /// `Instance.recomputeBounds()`/`fireInvalidated()` as Java's does.
  @discardableResult
  public func setInitialMode(_ mode: VgaMode) -> Bool {
    guard displayMode != mode else { return false }
    displayMode = mode
    return true
  }

  @discardableResult
  public func setVgaBufferStartAddress(_ value: Int32) -> Bool {
    guard value != vgaBufferAddress else { return false }
    vgaBufferAddress = value
    return true
  }
  @discardableResult
  public func setLabel(_ value: String) -> Bool {
    guard labelValue != value else { return false }
    labelValue = value
    fireNameChanged()
    return true
  }
  @discardableResult
  public func setBusInfo(_ info: SocBusInfo) -> Bool {
    guard attachedBus.busId != info.busId else { return false }
    attachedBus.busId = info.busId
    return true
  }
  @discardableResult
  public func setSoft160x120(_ v: Bool) -> Bool {
    guard soft160x120 != v else { return false }
    soft160x120 = v
    return true
  }
  @discardableResult
  public func setSoft320x240(_ v: Bool) -> Bool {
    guard soft320x240 != v else { return false }
    soft320x240 = v
    return true
  }
  @discardableResult
  public func setSoft640x480(_ v: Bool) -> Bool {
    guard soft640x480 != v else { return false }
    soft640x480 = v
    return true
  }
  @discardableResult
  public func setSoft800x600(_ v: Bool) -> Bool {
    guard soft800x600 != v else { return false }
    soft800x600 = v
    return true
  }
  @discardableResult
  public func setSoft1024x768(_ v: Bool) -> Bool {
    guard soft1024x768 != v else { return false }
    soft1024x768 = v
    return true
  }

  public func copyInto(_ dest: VgaState) {
    _ = dest.setStartAddress(startAddress)
    _ = dest.setInitialMode(initialMode)
    dest.soft160x120 = soft160x120
    dest.soft320x240 = soft320x240
    dest.soft640x480 = soft640x480
    dest.soft800x600 = soft800x600
    dest.soft1024x768 = soft1024x768
    _ = dest.setVgaBufferStartAddress(vgaBufferAddress)
    _ = dest.setLabel(label)
    _ = dest.setBusInfo(busInfo)
  }

  /// `getSize(int)`. Margins per `TOP_MARGIN`/`BOTTOM_MARGIN`/`LEFT_MARGIN`/`RIGHT_MARGIN`.
  public static let topMargin = 20
  public static let bottomMargin = 20
  public static let leftMargin = 5
  public static let rightMargin = 5

  public static func size(for mode: VgaMode) -> Bounds {
    let (w, h) = mode.dimensions
    return Bounds.create(
      0, 0, leftMargin + w + rightMargin, topMargin + h + bottomMargin)
  }

  public func newState() -> VgaDisplayState { VgaDisplayState(owner: self) }

  // MARK: - SocBusMasterInterface

  public func initializeTransaction(
    _ transaction: SocBusTransaction, busId: String,
    circuitState: (any SocCircuitStateToken)?
  ) {
    attachedBus.simulationManager?.initializeTransaction(
      transaction, busId: busId, circuitState: circuitState)
  }

  // MARK: - SocBusSnifferInterface

  public func sniffTransaction(_ transaction: SocBusTransaction) {
    guard transaction.isWriteTransaction else { return }
    let start = SocSupport.convUnsignedInt(vgaBufferAddress)
    guard let manager = attachedBus.simulationManager, let comp = attachedBus.component,
      let display = manager.data(for: comp) as? VgaDisplayState
    else { return }
    let end = start + Int64(display.dataSize) * 4
    let addr = SocSupport.convUnsignedInt(transaction.address)
    guard addr >= start, addr < end else { return }
    let index = Int(SocSupport.convUnsignedLong(addr - start) >> 2)
    guard index >= 0, index < display.pixels.count else { return }
    display.pixels[index] = transaction.writeData
  }

  // MARK: - SocBusSlaveInterface

  public func canHandleTransaction(_ transaction: SocBusTransaction) -> Bool {
    let addr = SocSupport.convUnsignedInt(transaction.address)
    let start = SocSupport.convUnsignedInt(startAddressValue)
    return addr >= start && addr < start + 4
  }

  public func handleTransaction(_ transaction: SocBusTransaction) {
    guard canHandleTransaction(transaction) else { return }
    transaction.setTransactionResponder(attachedBus.component)
    guard transaction.accessType == .word else {
      transaction.setError(.accessTypeNotSupported)
      return
    }
    if transaction.isReadTransaction {
      var data: Int32 = 0
      if soft160x120 { data |= VgaMode.mode160x120.mask }
      if soft320x240 { data |= VgaMode.mode320x240.mask }
      if soft640x480 { data |= VgaMode.mode640x480.mask }
      if soft800x600 { data |= VgaMode.mode800x600.mask }
      if soft1024x768 { data |= VgaMode.mode1024x768.mask }
      transaction.setReadData(data)
    }
    if transaction.isWriteTransaction {
      var mode = displayMode
      let data = transaction.writeData
      if data == VgaMode.mode160x120.mask, soft160x120 { mode = .mode160x120 }
      if data == VgaMode.mode320x240.mask, soft320x240 { mode = .mode320x240 }
      if data == VgaMode.mode640x480.mask, soft640x480 { mode = .mode640x480 }
      if data == VgaMode.mode800x600.mask, soft800x600 { mode = .mode800x600 }
      if data == VgaMode.mode1024x768.mask, soft1024x768 { mode = .mode1024x768 }
      if let manager = attachedBus.simulationManager, let comp = attachedBus.component,
        let display = manager.data(for: comp) as? VgaDisplayState
      {
        _ = display.setSoftMode(mode)
      }
    }
  }

  public var memorySize: Int32 { 4 }

  public var slaveName: String {
    if !labelValue.isEmpty { return labelValue }
    guard let comp = attachedBus.component else { return "BUG: Unknown" }
    let loc = comp.location
    return "\(comp.factory.name)@\(loc.x),\(loc.y)"
  }

  public func registerListener(_ listener: any SocBusSlaveListener) {
    guard !listeners.contains(where: { $0 === listener }) else { return }
    listeners.append(listener)
  }
  public func removeListener(_ listener: any SocBusSlaveListener) {
    listeners.removeAll { $0 === listener }
  }
  public var component: (any Component)? { attachedBus.component }

  private func fireNameChanged() {
    for listener in listeners { listener.labelChanged() }
  }
  private func fireMemMapChanged() {
    for listener in listeners { listener.memoryMapChanged() }
  }
}

extension VgaMode: Equatable {}
