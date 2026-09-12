// JtagUartState.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.soc.jtaguart.JtagUartState),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// The "UART" peripheral the task brief calls for: modelled on Altera's `altera_avalon_jtag_uart`
// register layout: a data register (offset 0) and a control register (offset 4), each packing a
// FIFO-occupancy count into the high 16 bits, exactly as real hardware does. Two independent
// FIFOs connect this to the *pin side* (a keyboard/TTY pair on the component's ports), driven by
// `handleOperations` on every rising clock edge, and to the *bus side* (register reads/writes),
// driven by `handleTransaction`.
//
// Not ported: nothing UI-shaped lives in this file upstream; it is already a clean model class.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimStd

/// `JtagUartAttributes`'s `OPT_8`…`OPT_32768` FIFO-size choices, as a native Swift enum per
/// `Attributes.swift`'s guidance for new component ports (a total, compiler-checked mapping
/// rather than the Java `AttributeOption[]` linear scan).
public enum JtagUartFifoSize: String, AttributeOptionValue, CaseIterable, Sendable {
  case size8 = "8", size16 = "16", size32 = "32", size64 = "64", size128 = "128"
  case size256 = "256", size512 = "512", size1024 = "1024", size2048 = "2048"
  case size4096 = "4096", size8192 = "8192", size16384 = "16384", size32768 = "32768"

  public var wordCount: Int { Int(rawValue) ?? -1 }
}

/// `JtagUartState.JtagUartFifoState`: the per-simulation-run FIFO state and pin-side protocol.
public final class JtagUartFifoState: InstanceData {
  private var writeFifo: [Int32] = []
  private var readFifo: [Int32] = []
  private var readIrqEnable = false
  private var writeIrqEnable = false
  private var acBit = false
  private var lastReset: Value = .unknownValue
  private var lastClock: Value = .unknownValue
  public private(set) var doReset = false
  public private(set) var endReset = false

  /// Weak, not `unowned` (D13): a `.circ` mutation sequence that tears down the owning
  /// `JtagUartState` while this per-run FIFO state is still reachable must degrade (FIFOs report
  /// zero capacity, see the accessors below) rather than trap.
  private weak var owner: JtagUartState?

  fileprivate init(owner: JtagUartState?) {
    self.owner = owner
    reset()
  }

  public func reset() {
    writeFifo.removeAll()
    readFifo.removeAll()
    readIrqEnable = false
    writeIrqEnable = false
    acBit = false
  }

  /// `setReset(Value)`.
  public func setReset(_ reset: Value) {
    doReset = lastReset == .falseValue && reset == .trueValue
    endReset = lastReset == .unknownValue || (lastReset == .trueValue && reset == .falseValue)
    lastReset = reset
  }

  /// `risingEdge(Value)`.
  public func risingEdge(_ clock: Value) -> Bool {
    let last = lastClock
    lastClock = clock
    return last == .falseValue && clock == .trueValue
  }

  /// `writeDataRegister(int)`; pin side pushes a received TTY byte; silently dropped if the
  /// FIFO is full (Java: `return` with no error, no overwrite).
  public func writeDataRegister(_ value: Int32) {
    let data = value & 0xFF
    guard writeFifo.count < (owner?.writeFifoSize.wordCount ?? 0) else { return }
    writeFifo.append(data)
  }

  /// `readDataRegister()`; bus-side read of the data register: low byte is the next keyboard
  /// byte (0 if empty, matching Java returning `0` rather than an error), bit 15 is a fixed
  /// "valid" marker set unconditionally (a Java quirk: it is set even when the FIFO was empty
  /// and the byte returned is the placeholder `0`), bits 16-31 are the remaining FIFO occupancy.
  public func readDataRegister() -> Int32 {
    if readFifo.isEmpty { return 0 }
    var result = readFifo.removeFirst() & 0xFF
    result |= 1 << 15
    result |= (Int32(readFifo.count) & 0xFFFF) << 16
    return result
  }

  /// `writeControlRegister(int)`.
  public func writeControlRegister(_ value: Int32) {
    readIrqEnable = (value & 1) != 0
    writeIrqEnable = (value & 2) != 0
    if (value & (1 << 10)) != 0 { acBit = false }
  }

  /// `readControlRegister()`.
  public func readControlRegister() -> Int32 {
    var result: Int32 = 0
    if readIrqEnable { result |= 1 }
    if writeIrqEnable { result |= 2 }
    if readIrqPending { result |= 1 << 8 }
    if writeIrqPending { result |= 1 << 9 }
    if acBit { result |= 1 << 10 }
    let avail = Int32(owner?.writeFifoSize.wordCount ?? 0) &- Int32(writeFifo.count)
    result |= (avail & 0xFFFF) << 16
    return result
  }

  private var readIrqPending: Bool {
    guard readIrqEnable, let owner else { return false }
    let empties = owner.readFifoSize.wordCount - readFifo.count
    return Int32(empties) <= owner.readIrqThreshold
  }
  private var writeIrqPending: Bool {
    guard writeIrqEnable, let owner else { return false }
    return writeFifo.count <= Int(owner.writeIrqThreshold)
  }

  public var isIrqPending: Bool { readIrqPending || writeIrqPending }
  public var isWriteFifoEmpty: Bool { writeFifo.isEmpty }

  public func setAcBit() { acBit = true }

  /// `popWriteFifo()`: `-1` sentinel on empty, matching Java (the caller never treats `-1` as
  /// a valid byte since it only pops after checking `isWriteFifoEmpty`).
  public func popWriteFifo() -> Int32 {
    guard !writeFifo.isEmpty else { return -1 }
    return writeFifo.removeFirst()
  }

  /// `pushReadFifo(Integer)`; silently dropped if full, matching Java.
  public func pushReadFifo(_ value: Int32) {
    guard readFifo.count < (owner?.readFifoSize.wordCount ?? 0) else { return }
    readFifo.append(value)
  }

  public func cloneData() -> any InstanceData {
    let copy = JtagUartFifoState(owner: owner)
    copy.writeFifo = writeFifo
    copy.readFifo = readFifo
    copy.readIrqEnable = readIrqEnable
    copy.writeIrqEnable = writeIrqEnable
    copy.acBit = acBit
    copy.lastReset = lastReset
    copy.lastClock = lastClock
    copy.doReset = doReset
    copy.endReset = endReset
    return copy
  }
}

/// `com.cburch.logisim.soc.jtaguart.JtagUartState`.
public final class JtagUartState: SocBusSlaveInterface {
  private var labelValue = ""
  private let attachedBus = SocBusInfo("")
  private var startAddressValue: Int32 = 0
  public private(set) var writeFifoSize: JtagUartFifoSize = .size64
  public private(set) var writeIrqThreshold: Int32 = 8
  public private(set) var readFifoSize: JtagUartFifoSize = .size64
  public private(set) var readIrqThreshold: Int32 = 8
  private var listeners: [any SocBusSlaveListener] = []

  public init() {}

  public var label: String { labelValue }
  public var attachedBusInfo: SocBusInfo { attachedBus }
  public var startAddress: Int32 { startAddressValue }

  @discardableResult
  public func setLabel(_ value: String) -> Bool {
    guard labelValue != value else { return false }
    labelValue = value
    fireNameChanged()
    return true
  }
  @discardableResult
  public func setAttachedBus(_ info: SocBusInfo) -> Bool {
    guard attachedBus.busId != info.busId else { return false }
    attachedBus.busId = info.busId
    return true
  }
  @discardableResult
  public func setStartAddress(_ addr: Int32) -> Bool {
    guard addr != startAddressValue else { return false }
    startAddressValue = addr
    fireMemMapChanged()
    return true
  }
  @discardableResult
  public func setWriteFifoSize(_ size: JtagUartFifoSize) -> Bool {
    guard writeFifoSize != size else { return false }
    writeFifoSize = size
    return true
  }
  @discardableResult
  public func setWriteIrqThreshold(_ value: Int32) -> Bool {
    guard writeIrqThreshold != value else { return false }
    writeIrqThreshold = value
    return true
  }
  @discardableResult
  public func setReadFifoSize(_ size: JtagUartFifoSize) -> Bool {
    guard readFifoSize != size else { return false }
    readFifoSize = size
    return true
  }
  @discardableResult
  public func setReadIrqThreshold(_ value: Int32) -> Bool {
    guard readIrqThreshold != value else { return false }
    readIrqThreshold = value
    return true
  }

  public func copyInto(_ dest: JtagUartState) {
    dest.labelValue = labelValue
    dest.attachedBus.busId = attachedBus.busId
    dest.startAddressValue = startAddressValue
    dest.writeFifoSize = writeFifoSize
    dest.readFifoSize = readFifoSize
    dest.writeIrqThreshold = writeIrqThreshold
    dest.readIrqThreshold = readIrqThreshold
  }

  public func newFifoState() -> JtagUartFifoState { JtagUartFifoState(owner: self) }

  /// `handleOperations(InstanceState)`.
  public func handleOperations(_ state: any InstanceState) {
    let curReset = state.portValue(JtagUart.resetPin)
    let curClock = state.portValue(JtagUart.clockPin)
    let instState: JtagUartFifoState
    if let existing = state.data as? JtagUartFifoState {
      instState = existing
    } else {
      instState = newFifoState()
      state.setData(instState)
    }
    instState.setReset(curReset)
    if instState.doReset {
      state.setPort(JtagUart.readEnablePin, .falseValue, 5)
      state.setPort(JtagUart.clearKeyboardPin, .trueValue, 5)
      state.setPort(JtagUart.dataOutPin, Value.createKnown(7, 0), 5)
      state.setPort(JtagUart.writePin, .falseValue, 5)
      state.setPort(JtagUart.clearTtyPin, .trueValue, 5)
      state.setPort(JtagUart.irqPin, .falseValue, 5)
      instState.reset()
    }
    if instState.endReset {
      state.setPort(JtagUart.readEnablePin, .falseValue, 5)
      state.setPort(JtagUart.clearKeyboardPin, .falseValue, 5)
      state.setPort(JtagUart.dataOutPin, Value.createKnown(7, 0), 5)
      state.setPort(JtagUart.writePin, .falseValue, 5)
      state.setPort(JtagUart.clearTtyPin, .falseValue, 5)
      state.setPort(JtagUart.irqPin, .falseValue, 5)
    }
    if curReset == .trueValue { return }
    if instState.risingEdge(curClock) {
      state.setPort(JtagUart.irqPin, instState.isIrqPending ? .trueValue : .falseValue, 5)
      if instState.isWriteFifoEmpty {
        state.setPort(JtagUart.writePin, .falseValue, 5)
      } else {
        let val = instState.popWriteFifo()
        instState.setAcBit()
        state.setPort(JtagUart.writePin, .trueValue, 5)
        state.setPort(JtagUart.dataOutPin, Value.createKnown(7, Int64(val)), 5)
      }
      if state.portValue(JtagUart.availablePin) == .trueValue
        && state.portValue(JtagUart.readEnablePin) == .falseValue
      {
        instState.setAcBit()
        instState.pushReadFifo(Int32(truncatingIfNeeded: state.portValue(JtagUart.dataInPin).toLongValue()))
        state.setPort(JtagUart.readEnablePin, .trueValue, 5)
      } else {
        state.setPort(JtagUart.readEnablePin, .falseValue, 5)
      }
    }
  }

  // MARK: - SocBusSlaveInterface

  public func canHandleTransaction(_ transaction: SocBusTransaction) -> Bool {
    let addr = SocSupport.convUnsignedInt(transaction.address)
    let start = SocSupport.convUnsignedInt(startAddressValue)
    return addr >= start && addr < start + 8
  }

  public func handleTransaction(_ transaction: SocBusTransaction) {
    guard canHandleTransaction(transaction) else { return }
    transaction.setTransactionResponder(attachedBus.component)
    let addr = SocSupport.convUnsignedInt(transaction.address)
    let start = SocSupport.convUnsignedInt(startAddressValue)
    guard transaction.accessType == .word else {
      transaction.setError(.accessTypeNotSupported)
      return
    }
    guard let manager = attachedBus.simulationManager, let comp = attachedBus.component,
      let state = manager.data(for: comp) as? JtagUartFifoState
    else {
      transaction.setError(.noResponse)
      return
    }
    let index = addr - start
    if index == 0 {
      if transaction.isReadTransaction { transaction.setReadData(state.readDataRegister()) }
      if transaction.isWriteTransaction { state.writeDataRegister(transaction.writeData) }
      return
    }
    if index == 4 {
      if transaction.isReadTransaction { transaction.setReadData(state.readControlRegister()) }
      if transaction.isWriteTransaction { state.writeControlRegister(transaction.writeData) }
      return
    }
    transaction.setError(.misalignedAddress)
  }

  public var memorySize: Int32 { 8 }

  public var slaveName: String {
    guard let comp = attachedBus.component else { return "BUG: Unknown" }
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
  public var component: (any Component)? { attachedBus.component }

  private func fireNameChanged() {
    for listener in listeners { listener.labelChanged() }
  }
  private func fireMemMapChanged() {
    for listener in listeners { listener.memoryMapChanged() }
  }
}

extension JtagUartFifoSize: Equatable {}
