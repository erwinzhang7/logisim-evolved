// DmaState.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.soc.dma.DmaState),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// The MMIO register map and clock-driven burst-copy engine for the SoC DMA peripheral: it is
// simultaneously a bus slave (control registers) and a bus master (the actual source-read /
// destination-write transactions). `executeBurst` is the numerically interesting part: it walks
// `burstSize` words per clock tick, and a `hidden` read paired with a non-hidden write is
// deliberate (see the Java doc comment, preserved below) so bus sniffers like the VGA framebuffer
// observe DMA-driven writes in real time without the read half flooding the trace log.
//
// Not ported: nothing UI-shaped lives in this file upstream; it is already a clean model class.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimStd

/// `DmaState.DmaRegState`: the per-simulation-run register file.
public final class DmaRegState: InstanceData {
  public var srcAddr: Int32 = 0
  public var dstAddr: Int32 = 0
  public var length: Int32 = 0
  public var control: Int32 = 0
  public var busy = false
  public var done = false
  public var bytesDone: Int32 = 0
  public var irqAsserted = false
  public var lastClock: Value = .unknownValue

  public init() {}

  public func reset() {
    srcAddr = 0
    dstAddr = 0
    length = 0
    control = 0
    busy = false
    done = false
    bytesDone = 0
    irqAsserted = false
  }

  public func cloneData() -> any InstanceData {
    let copy = DmaRegState()
    copy.srcAddr = srcAddr
    copy.dstAddr = dstAddr
    copy.length = length
    copy.control = control
    copy.busy = busy
    copy.done = done
    copy.bytesDone = bytesDone
    copy.irqAsserted = irqAsserted
    copy.lastClock = lastClock
    return copy
  }
}

/// `com.cburch.logisim.soc.dma.DmaState`.
public final class DmaState: SocBusSlaveInterface, SocBusMasterInterface {

  public static let srcAddrReg: Int32 = 0x00
  public static let dstAddrReg: Int32 = 0x04
  public static let lengthReg: Int32 = 0x08
  public static let controlReg: Int32 = 0x0C
  public static let statusReg: Int32 = 0x10
  public static let bytesDoneReg: Int32 = 0x14
  public static let registerRegionSize: Int32 = 0x18

  public static let ctrlStart: Int32 = 1 << 0
  public static let ctrlIrqEn: Int32 = 1 << 1
  public static let statBusy: Int32 = 1 << 0
  public static let statDone: Int32 = 1 << 1

  private var startAddressValue: Int32 = 0
  private var burstSizeValue: Int32 = 16
  private let controlBus = SocBusInfo("")
  private let sourceBus = SocBusInfo("")
  private let destBus = SocBusInfo("")
  private var labelValue = ""
  private var listeners: [any SocBusSlaveListener] = []

  public init() {}

  public var burstSize: Int32 { burstSizeValue }
  @discardableResult
  public func setBurstSize(_ size: Int32) -> Bool {
    guard size != burstSizeValue else { return false }
    burstSizeValue = size
    return true
  }

  public var controlBusInfo: SocBusInfo { controlBus }
  public var sourceBusInfo: SocBusInfo { sourceBus }
  public var destBusInfo: SocBusInfo { destBus }

  public var label: String { labelValue }
  @discardableResult
  public func setLabel(_ value: String) -> Bool {
    guard labelValue != value else { return false }
    labelValue = value
    fireNameChanged()
    return true
  }

  /// `setStartAddress(Integer)`, force word-alignment.
  @discardableResult
  public func setStartAddress(_ value: Int32) -> Bool {
    let addr = (value >> 2) << 2
    guard addr != startAddressValue else { return false }
    startAddressValue = addr
    fireMemMapChanged()
    return true
  }

  @discardableResult
  public func setControlBus(_ info: SocBusInfo) -> Bool {
    guard controlBus.busId != info.busId else { return false }
    controlBus.busId = info.busId
    return true
  }
  @discardableResult
  public func setSourceBus(_ info: SocBusInfo) -> Bool {
    guard sourceBus.busId != info.busId else { return false }
    sourceBus.busId = info.busId
    return true
  }
  @discardableResult
  public func setDestBus(_ info: SocBusInfo) -> Bool {
    guard destBus.busId != info.busId else { return false }
    destBus.busId = info.busId
    return true
  }

  public func newState() -> DmaRegState { DmaRegState() }

  /// `executeBurst(DmaRegState, CircuitState)`. Called on every clock rising edge from
  /// `SocDma.propagate`.
  public func executeBurst(_ regs: DmaRegState, circuitState: any SocCircuitStateToken) {
    guard regs.busy else { return }
    guard let manager = controlBus.simulationManager else { return }
    guard let srcBusId = effectiveSourceBusId, let dstBusId = effectiveDestBusId else { return }
    // D13: a malformed/mid-edit circuit can reach `executeBurst` with the control bus not yet
    // attached to a component (e.g. torn down mid-simulation); Java would NPE inside
    // `controlBus.getComponent()`. Guarding instead keeps a bad transient wiring state from
    // crashing the app.
    guard let controlComponent = controlBus.component else { return }

    let remaining = regs.length &- regs.bytesDone
    let wordsToTransfer = min(burstSizeValue, remaining / 4)
    var wordsTransferred: Int32 = 0

    var i: Int32 = 0
    while i < wordsToTransfer {
      let offset = regs.bytesDone &+ i &* 4

      let readTrans = SocBusTransaction(
        kind: .read, address: regs.srcAddr &+ offset, writeData: 0, accessType: .word,
        initiator: .component(controlComponent))
      readTrans.setAsHidden()
      manager.initializeTransaction(readTrans, busId: srcBusId, circuitState: circuitState)
      if readTrans.hasError { break }

      let writeTrans = SocBusTransaction(
        kind: .write, address: regs.dstAddr &+ offset, writeData: readTrans.readData,
        accessType: .word, initiator: .component(controlComponent))
      manager.initializeTransaction(writeTrans, busId: dstBusId, circuitState: circuitState)
      if writeTrans.hasError { break }

      wordsTransferred &+= 1
      i &+= 1
    }

    regs.bytesDone &+= wordsTransferred &* 4

    if regs.bytesDone >= regs.length {
      regs.busy = false
      regs.done = true
      if (regs.control & Self.ctrlIrqEn) != 0 {
        regs.irqAsserted = true
      }
    }
  }

  private var effectiveSourceBusId: String? {
    let id = sourceBus.busId
    return id.isEmpty ? (controlBus.busId.isEmpty ? nil : controlBus.busId) : id
  }
  private var effectiveDestBusId: String? {
    let id = destBus.busId
    return id.isEmpty ? (controlBus.busId.isEmpty ? nil : controlBus.busId) : id
  }

  // MARK: - SocBusMasterInterface

  public func initializeTransaction(
    _ transaction: SocBusTransaction, busId: String,
    circuitState: (any SocCircuitStateToken)?
  ) {
    controlBus.simulationManager?.initializeTransaction(
      transaction, busId: busId, circuitState: circuitState)
  }

  // MARK: - SocBusSlaveInterface (MMIO registers)

  public var startAddress: Int32 { startAddressValue }
  public var memorySize: Int32 { Self.registerRegionSize }

  public func canHandleTransaction(_ transaction: SocBusTransaction) -> Bool {
    let addr = SocSupport.convUnsignedInt(transaction.address)
    let start = SocSupport.convUnsignedInt(startAddressValue)
    let end = start + Int64(Self.registerRegionSize)
    return addr >= start && addr < end
  }

  public func handleTransaction(_ transaction: SocBusTransaction) {
    guard canHandleTransaction(transaction) else { return }
    transaction.setTransactionResponder(controlBus.component)
    guard transaction.accessType == .word else {
      transaction.setError(.accessTypeNotSupported)
      return
    }
    let addr = SocSupport.convUnsignedInt(transaction.address)
    let start = SocSupport.convUnsignedInt(startAddressValue)
    let regOffset = Int32(addr - start)

    guard let regs = regPropagateState() else {
      transaction.setError(.accessTypeNotSupported)
      return
    }

    switch regOffset {
    case Self.srcAddrReg:
      if transaction.isReadTransaction { transaction.setReadData(regs.srcAddr) }
      if transaction.isWriteTransaction, !regs.busy {
        regs.srcAddr = (transaction.writeData >> 2) << 2
      }
    case Self.dstAddrReg:
      if transaction.isReadTransaction { transaction.setReadData(regs.dstAddr) }
      if transaction.isWriteTransaction, !regs.busy {
        regs.dstAddr = (transaction.writeData >> 2) << 2
      }
    case Self.lengthReg:
      if transaction.isReadTransaction { transaction.setReadData(regs.length) }
      if transaction.isWriteTransaction, !regs.busy {
        regs.length = (transaction.writeData >> 2) << 2
      }
    case Self.controlReg:
      if transaction.isReadTransaction { transaction.setReadData(regs.control) }
      if transaction.isWriteTransaction {
        let val = transaction.writeData
        regs.control = val & Self.ctrlIrqEn
        if (val & Self.ctrlStart) != 0, !regs.busy, regs.length > 0 {
          regs.busy = true
          regs.done = false
          regs.bytesDone = 0
          regs.irqAsserted = false
        }
      }
    case Self.statusReg:
      if transaction.isReadTransaction {
        var status: Int32 = 0
        if regs.busy { status |= Self.statBusy }
        if regs.done { status |= Self.statDone }
        transaction.setReadData(status)
      }
      if transaction.isWriteTransaction, (transaction.writeData & Self.statDone) != 0 {
        regs.done = false
        regs.irqAsserted = false
      }
    case Self.bytesDoneReg:
      if transaction.isReadTransaction { transaction.setReadData(regs.bytesDone) }
      if transaction.isWriteTransaction { transaction.setError(.readOnlyAccess) }
    default:
      transaction.setError(.misalignedAddress)
    }
  }

  private func regPropagateState() -> DmaRegState? {
    guard let manager = controlBus.simulationManager, let comp = controlBus.component else {
      return nil
    }
    return manager.data(for: comp) as? DmaRegState
  }

  public var slaveName: String {
    guard let comp = controlBus.component else { return "BUG: Unknown" }
    if !labelValue.isEmpty { return labelValue }
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
  public var component: (any Component)? { controlBus.component }

  private func fireNameChanged() {
    for listener in listeners { listener.labelChanged() }
  }
  private func fireMemMapChanged() {
    for listener in listeners { listener.memoryMapChanged() }
  }
}
