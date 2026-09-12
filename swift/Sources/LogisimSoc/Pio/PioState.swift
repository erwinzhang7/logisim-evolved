// PioState.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.soc.pio.PioState),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// A configurable-width parallel I/O peripheral (Nios II PIO-core equivalent): up to a
// `StdAttr.WIDTH`-wide input/output/bidirectional/in-out port, an edge/level capture register,
// per-bit interrupt masking, and bit-set/bit-clear MMIO shortcuts for the output register.
//
// ── Numeric fidelity: variable-width bit shifts ─────────────────────────────────────────────────
//
// Every `1 << i`/`(x >> i) & 1` here shifts by a loop-bounded `i` that can legally reach 31 (the
// component's pin count is `StdAttr.WIDTH`, whose declared range in this port goes up to 64:
// see `Attributes.forBitWidth`'s default bounds). Java masks any `int` shift distance to 5 bits
// (`i & 31`); Swift's plain `<<`/`>>` on a fixed-width integer is a *smart* shift that yields 0
// (or a fully sign-extended value, for `>>`) once the count reaches the type's bit width instead
// of wrapping; silently wrong for `i >= 32` where Java would wrap around and keep shifting
// within the low 32 bits. Every shift by a non-literal count below uses `&<<`/`&>>`, Swift's
// *masking* shift, which reduces the count modulo the bit width exactly as Java's JVM bytecode
// `ishl`/`ishr`/`iushr` do; this is the direct, no-helper-needed equivalent of
// `LogisimStd/Instance/JavaBits.swift`'s masking helpers, applicable here because the operand is
// already a native `Int32` rather than a `Int`-typed stand-in for a Java `long`.
//
// Not ported: nothing UI-shaped lives in this file upstream; it is already a clean model class.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimStd

/// `PioAttributes.PORT_BIDIR`/`PORT_INPUT`/`PORT_OUTPUT`/`PORT_INOUT`.
public enum PioDirection: String, AttributeOptionValue, CaseIterable, Sendable {
  case bidir = "bidir"
  case input = "inputonly"
  case output = "outputonly"
  case inout_ = "inout"
}

/// `PioAttributes.CAPT_RISING`/`CAPT_FALLING`/`CAPT_ANY`.
public enum PioCaptureEdge: String, AttributeOptionValue, CaseIterable, Sendable {
  case rising, falling, any
}

/// `PioAttributes.IRQ_LEVEL`/`IRQ_EDGE`.
public enum PioIrqType: String, AttributeOptionValue, CaseIterable, Sendable {
  case level, edge
}

/// `PioState.PioRegState`: the per-simulation-run register file.
public final class PioRegState: InstanceData {
  public var outputRegister: Int32 = 0
  public var captureRegister: Int32 = 0
  public var directionRegister: Int32 = 0
  public var interruptMask: Int32 = 0
  public var oldIrq = false
  public var oldIrqValid = false
  private var oldInputs: Int32 = 0
  private var oldInputsValid = false

  /// Weak, not `unowned` (D13): see the identical note on `JtagUartFifoState.owner`.
  private weak var owner: PioState?

  fileprivate init(owner: PioState?) {
    self.owner = owner
    reset()
  }

  /// `updateCaptureRegister(int)`.
  public func updateCaptureRegister(_ newInputs: Int32) {
    guard let owner else { return }
    if oldInputsValid && newInputs == oldInputs { return }
    if oldInputsValid && owner.inputIsCapturedSynchronously {
      for i in 0..<owner.nrOfIOs.width {
        let oldBit = (oldInputs &>> Int32(i)) & 1
        let newBit = (newInputs &>> Int32(i)) & 1
        switch owner.inputCaptureEdge {
        case .any:
          if oldBit != newBit { captureRegister |= (1 as Int32) &<< Int32(i) }
        case .rising:
          if oldBit == 0 && newBit == 1 { captureRegister |= (1 as Int32) &<< Int32(i) }
        case .falling:
          if oldBit == 1 && newBit == 0 { captureRegister |= (1 as Int32) &<< Int32(i) }
        }
      }
    }
    oldInputsValid = true
    oldInputs = newInputs
  }

  public func reset() {
    outputRegister = owner?.outputResetValue ?? 0
    captureRegister = 0
    directionRegister = 0
    oldInputs = 0
    oldInputsValid = false
    interruptMask = 0
    oldIrq = false
    oldIrqValid = false
  }

  public func cloneData() -> any InstanceData {
    let copy = PioRegState(owner: owner)
    copy.outputRegister = outputRegister
    copy.captureRegister = captureRegister
    copy.directionRegister = directionRegister
    copy.interruptMask = interruptMask
    copy.oldIrq = oldIrq
    copy.oldIrqValid = oldIrqValid
    copy.oldInputs = oldInputs
    copy.oldInputsValid = oldInputsValid
    return copy
  }
}

/// `com.cburch.logisim.soc.pio.PioState`.
public final class PioState: SocBusSlaveInterface {
  private static let dataRegIndex: Int64 = 0x0
  private static let dirRegIndex: Int64 = 0x4
  private static let irqMaskIndex: Int64 = 0x8
  private static let edgeCaptIndex: Int64 = 0xC
  private static let outSetIndex: Int64 = 0x10
  private static let outClearIndex: Int64 = 0x14

  public private(set) var nrOfIOs = BitWidth.known(1)
  private var labelValue = ""
  private let attachedBus = SocBusInfo("")
  private var startAddressValue: Int32 = 0
  private var listeners: [any SocBusSlaveListener] = []
  public private(set) var portDirection: PioDirection = .input
  public private(set) var outputResetValue: Int32 = 0
  public private(set) var outputBitManipulations = false
  public private(set) var inputIsCapturedSynchronously = false
  public private(set) var inputCaptureEdge: PioCaptureEdge = .rising
  public private(set) var inputCaptureBitClearing = false
  private var inputGeneratesIrqValue = false
  public private(set) var irqTypeValue: PioIrqType = .level

  public init() {}

  public func copyInto(_ dest: PioState) {
    dest.nrOfIOs = nrOfIOs
    dest.labelValue = labelValue
    dest.attachedBus.busId = attachedBus.busId
    dest.startAddressValue = startAddressValue
    dest.portDirection = portDirection
    dest.outputResetValue = outputResetValue
    dest.outputBitManipulations = outputBitManipulations
    dest.inputIsCapturedSynchronously = inputIsCapturedSynchronously
    dest.inputCaptureEdge = inputCaptureEdge
    dest.inputCaptureBitClearing = inputCaptureBitClearing
    dest.inputGeneratesIrqValue = inputGeneratesIrqValue
    dest.irqTypeValue = irqTypeValue
  }

  public var label: String { labelValue }
  public var attachedBusInfo: SocBusInfo { attachedBus }
  public var startAddress: Int32 { startAddressValue }

  /// `inputGeneratesIrq()`: a *computed* property upstream, not a plain getter: it is forced
  /// off whenever the port is output-only, independent of the stored flag.
  public var inputGeneratesIrq: Bool { inputGeneratesIrqValue && portDirection != .output }

  /// `getIrqType()`; likewise computed: reports `IRQ_LEVEL` unless both IRQ generation and
  /// synchronous capture are active.
  public var irqType: PioIrqType {
    (inputGeneratesIrq && inputIsCapturedSynchronously) ? irqTypeValue : .level
  }

  @discardableResult
  public func setNrOfIOs(_ width: BitWidth) -> Bool {
    guard width.width != nrOfIOs.width else { return false }
    nrOfIOs = width
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
  public func setAttachedBus(_ info: SocBusInfo) -> Bool {
    guard attachedBus.busId != info.busId else { return false }
    attachedBus.busId = info.busId
    return true
  }
  @discardableResult
  public func setStartAddress(_ addr: Int32) -> Bool {
    guard startAddressValue != addr else { return false }
    startAddressValue = addr
    fireMemMapChanged()
    return true
  }
  @discardableResult
  public func setPortDirection(_ dir: PioDirection) -> Bool {
    guard portDirection != dir else { return false }
    portDirection = dir
    return true
  }
  @discardableResult
  public func setOutputResetValue(_ value: Int32) -> Bool {
    guard outputResetValue != value else { return false }
    outputResetValue = value
    return true
  }
  @discardableResult
  public func setOutputBitManipulations(_ value: Bool) -> Bool {
    guard outputBitManipulations != value else { return false }
    outputBitManipulations = value
    return true
  }
  @discardableResult
  public func setInputSynchronousCapture(_ value: Bool) -> Bool {
    guard inputIsCapturedSynchronously != value else { return false }
    inputIsCapturedSynchronously = value
    return true
  }
  @discardableResult
  public func setInputCaptureEdge(_ value: PioCaptureEdge) -> Bool {
    guard inputCaptureEdge != value else { return false }
    inputCaptureEdge = value
    return true
  }
  @discardableResult
  public func setInputCaptureBitClearing(_ value: Bool) -> Bool {
    guard inputCaptureBitClearing != value else { return false }
    inputCaptureBitClearing = value
    return true
  }
  @discardableResult
  public func setIrqGeneration(_ value: Bool) -> Bool {
    guard inputGeneratesIrqValue != value else { return false }
    inputGeneratesIrqValue = value
    return true
  }
  @discardableResult
  public func setIrqType(_ value: PioIrqType) -> Bool {
    guard irqTypeValue != value else { return false }
    irqTypeValue = value
    return true
  }

  public func newRegState() -> PioRegState { PioRegState(owner: self) }

  /// `handleOperations(InstanceState, boolean)`.
  @discardableResult
  public func handleOperations(_ state: any InstanceState, captureOnly: Bool) -> Int32 {
    let regs: PioRegState
    if let existing = state.data as? PioRegState {
      regs = existing
    } else {
      regs = newRegState()
      state.setData(regs)
    }
    if state.portValue(SocPio.resetIndex) == .trueValue { regs.reset() }
    let index = inputGeneratesIrq ? 2 : 1
    let nrOfBits = nrOfIOs.width
    let outputStart = index + (portDirection == .inout_ ? nrOfIOs.width : 0)
    var inputs: Int32 = 0
    for i in 0..<nrOfBits {
      if state.portValue(index + i) == .trueValue {
        inputs |= (1 as Int32) &<< Int32(i)
      }
    }
    if inputGeneratesIrq {
      let irqSource = irqType == .level ? inputs : regs.captureRegister
      let irqs = irqSource & regs.interruptMask
      let isIrq = irqs != 0
      if !regs.oldIrqValid || isIrq != regs.oldIrq {
        state.setPort(SocPio.irqIndex, isIrq ? .trueValue : .falseValue, 10)
      }
      regs.oldIrqValid = true
      regs.oldIrq = isIrq
    }
    if captureOnly { return inputs }
    regs.updateCaptureRegister(inputs)
    if portDirection != .input {
      for i in 0..<nrOfBits {
        let val: Value = (regs.outputRegister & ((1 as Int32) &<< Int32(i))) != 0 ? .trueValue : .falseValue
        let isOutput = portDirection != .bidir || ((regs.directionRegister &>> Int32(i)) & 1) != 0
        if isOutput {
          state.setPort(outputStart + i, val, 10)
        }
      }
    }
    return 0
  }

  private func regPropagateState() -> PioRegState? {
    guard let manager = attachedBus.simulationManager, let comp = attachedBus.component else {
      return nil
    }
    return manager.data(for: comp) as? PioRegState
  }
  private func propagateState() -> (any InstanceState)? {
    guard let manager = attachedBus.simulationManager, let comp = attachedBus.component else {
      return nil
    }
    return manager.instanceState(for: comp)
  }

  private func handleOutputWriteTransaction(_ transaction: SocBusTransaction) {
    if portDirection == .input {
      transaction.setError(.readOnlyAccess)
    } else if let regs = regPropagateState(), let state = propagateState() {
      regs.outputRegister = transaction.writeData
      _ = handleOperations(state, captureOnly: false)
    }
  }

  private func handleInputReadTransaction(_ transaction: SocBusTransaction) {
    if portDirection == .output {
      transaction.setError(.writeOnlyAccess)
    } else if let state = propagateState() {
      transaction.setReadData(handleOperations(state, captureOnly: true))
    }
  }

  private func handleDirectionRegister(_ transaction: SocBusTransaction) {
    guard portDirection == .bidir else {
      transaction.setError(.registerDoesNotExist)
      return
    }
    guard let regs = regPropagateState() else { return }
    if transaction.isReadTransaction { transaction.setReadData(regs.directionRegister) }
    if transaction.isWriteTransaction { regs.directionRegister = transaction.writeData }
  }

  private func handleIrqMaskRegister(_ transaction: SocBusTransaction) {
    guard inputGeneratesIrq else {
      transaction.setError(.registerDoesNotExist)
      return
    }
    guard let regs = regPropagateState() else { return }
    if transaction.isReadTransaction { transaction.setReadData(regs.interruptMask) }
    else { regs.interruptMask = transaction.writeData }
  }

  private func handleCaptureRegister(_ transaction: SocBusTransaction) {
    guard inputIsCapturedSynchronously else {
      transaction.setError(.registerDoesNotExist)
      return
    }
    guard let regs = regPropagateState() else { return }
    if transaction.isReadTransaction { transaction.setReadData(regs.captureRegister) }
    if transaction.isWriteTransaction {
      if inputCaptureBitClearing {
        regs.captureRegister &= ~transaction.writeData
      } else {
        regs.captureRegister = 0
      }
    }
  }

  private func handleOutputBitOperation(_ transaction: SocBusTransaction, clear: Bool) {
    guard outputBitManipulations else {
      transaction.setError(.registerDoesNotExist)
      return
    }
    if transaction.isReadTransaction {
      transaction.setError(.writeOnlyAccess)
    }
    guard let regs = regPropagateState() else { return }
    let mask = transaction.writeData
    if clear {
      regs.outputRegister &= ~mask
    } else {
      regs.outputRegister |= mask
    }
    if let state = propagateState() { _ = handleOperations(state, captureOnly: false) }
  }

  // MARK: - SocBusSlaveInterface

  public func canHandleTransaction(_ transaction: SocBusTransaction) -> Bool {
    let addr = SocSupport.convUnsignedInt(transaction.address)
    let start = SocSupport.convUnsignedInt(startAddressValue)
    return addr >= start && addr < start + 24
  }

  public func handleTransaction(_ transaction: SocBusTransaction) {
    guard canHandleTransaction(transaction) else { return }
    transaction.setTransactionResponder(attachedBus.component)
    let addr = SocSupport.convUnsignedInt(transaction.address)
    let start = SocSupport.convUnsignedInt(startAddressValue)
    let index = addr - start
    guard transaction.accessType == .word else {
      transaction.setError(.accessTypeNotSupported)
      return
    }
    switch index {
    case Self.dataRegIndex:
      if transaction.isWriteTransaction { handleOutputWriteTransaction(transaction) }
      if transaction.isReadTransaction { handleInputReadTransaction(transaction) }
    case Self.dirRegIndex: handleDirectionRegister(transaction)
    case Self.irqMaskIndex: handleIrqMaskRegister(transaction)
    case Self.edgeCaptIndex: handleCaptureRegister(transaction)
    case Self.outSetIndex: handleOutputBitOperation(transaction, clear: false)
    case Self.outClearIndex: handleOutputBitOperation(transaction, clear: true)
    default: transaction.setError(.misalignedAddress)
    }
  }

  public var memorySize: Int32 { 24 }

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

extension PioDirection: Equatable {}
extension PioCaptureEdge: Equatable {}
extension PioIrqType: Equatable {}
