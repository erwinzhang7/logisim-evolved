// SocMemoryState.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.soc.memory.SocMemoryState),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// The RAM/ROM peripheral's actual storage and byte/half-word/word access logic. This is one of
// the highest numeric-fidelity-risk files in the whole slice: every read/write goes through
// hand-rolled byte-lane extraction with no bounds/sign-extension help from a `Value`, so a wrong
// shift or mask here is invisible until a program reads back garbage.
//
// ── Storage model, ported as-is ─────────────────────────────────────────────────────────────────
//
// Upstream does not allocate a flat byte array. It keeps a list of contiguous word-aligned runs
// (`SocMemoryInfoBlock`, backed by a `LinkedList<Int32>`) and grows/merges runs lazily as writes
// land adjacent to an existing one. A never-written word reads back `Random.nextInt()`: genuine
// uninitialised memory, not zero. This is preserved exactly (same run-splitting/merging rules,
// same "reads whatever, unspecified" contract) because RISC-V/Nios II programs that assume
// zeroed BSS without an explicit clear loop would behave identically wrong against the Java
// oracle, and a silent switch to zero-fill would make this port's output diverge from Java's on
// exactly the kind of buggy-but-real test program the differential harness exists to catch.
// Divergence accepted: the *specific* uninitialised bit pattern is `Int32.random`, not whatever
// `java.util.Random.nextInt()` would have produced for the same seed; no `.circ` file or test
// vector can depend on the literal value of uninitialised memory without also being
// non-reproducible against upstream itself (upstream never seeds this `Random` either).
//
// ── D13 ───────────────────────────────────────────────────────────────────────────────────────
//
// `writeWord`'s `adders.size() > 2` branch is upstream's own "this should never happen" guard
// (`System.out.println("BUG! ...")`); a malformed sequence of writes cannot actually reach three
// simultaneous adjacent runs given how runs are merged, so this stays a `Swift.print` + early
// return exactly like the Java, not a `throw`; it is asserting an internal invariant the
// component itself maintains, not something a `.circ` file's *content* can trigger.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimStd

/// `SocMemoryState.SocMemoryInfo.SocMemoryInfoBlock`: one contiguous, word-aligned run.
private final class SocMemoryInfoBlock {
  private var contents: [Int32] = []
  private(set) var startAddress: Int32

  init(address: Int32, data: Int32) {
    startAddress = (address >> 2) << 2
    contents.append(data)
  }

  private var endAddress: Int32 {
    startAddress &+ Int32(contents.count) &* 4
  }

  func canAddBefore(_ address: Int32) -> Bool {
    let previous = startAddress &- 4
    return address >= previous && address < startAddress
  }

  func canAddAfter(_ address: Int32) -> Bool {
    address >= endAddress && address < endAddress &+ 4
  }

  func contains(_ address: Int32) -> Bool {
    address >= startAddress && address < endAddress
  }

  func canAdd(_ address: Int32) -> Bool { canAddBefore(address) || canAddAfter(address) }

  @discardableResult
  func addInfo(_ address: Int32, _ data: Int32) -> Bool {
    if canAddBefore(address) {
      contents.insert(data, at: 0)
      startAddress = startAddress &- 4
      return true
    }
    if canAddAfter(address) {
      contents.append(data)
      return true
    }
    if contains(address) {
      let index = Int((address &- startAddress) >> 2)
      contents[index] = data
      return true
    }
    return false
  }

  func value(at address: Int32) -> Int32 {
    let index = Int((address &- startAddress) >> 2)
    guard index >= 0, index < contents.count else { return Int32.random(in: Int32.min...Int32.max) }
    return contents[index]
  }
}

/// `SocMemoryState.SocMemoryInfo`: the per-simulation-run `InstanceData`.
public final class SocMemoryInfo: InstanceData {
  private var blocks: [SocMemoryInfoBlock] = []

  public init() {}

  /// `getWord(int)`.
  public func word(at address: Int32) -> Int32 {
    for block in blocks where block.contains(address) {
      return block.value(at: address)
    }
    return Int32.random(in: Int32.min...Int32.max)
  }

  /// `writeWord(int, int)`.
  public func writeWord(_ address: Int32, _ data: Int32) {
    var adders: [SocMemoryInfoBlock] = []
    for block in blocks {
      if block.contains(address) {
        block.addInfo(address, data)
        return
      }
      if block.canAdd(address) {
        adders.append(block)
      }
    }
    if adders.isEmpty {
      blocks.append(SocMemoryInfoBlock(address: address, data: data))
      return
    }
    if adders.count == 1 {
      adders[0].addInfo(address, data)
      return
    }
    if adders.count > 2 {
      print("BUG! Memory management does not function correctly for the SocMemory component!")
      return
    }
    let addBefore = adders[0].canAddBefore(address) ? adders[0]
      : (adders[1].canAddBefore(address) ? adders[1] : nil)
    let addAfter = adders[0].canAddAfter(address) ? adders[0]
      : (adders[1].canAddAfter(address) ? adders[1] : nil)
    guard let addBefore, let addAfter else {
      print("BUG! Memory management does not function correctly for the SocMemory component!")
      return
    }
    addAfter.addInfo(address, data)
    // Merge every word from `addBefore` into `addAfter`, matching the Java loop bound
    // `i < addBefore.getEndAddress()` exactly (`addBefore` is not mutated inside this loop, so
    // the bound need not be recomputed per iteration).
    let mergeEnd = addBefore.startAddress &+ Int32(4 * addBefore.wordCount)
    var i = addBefore.startAddress
    while i < mergeEnd {
      addAfter.addInfo(i, addBefore.value(at: i))
      i = i &+ 4
    }
    blocks.removeAll { $0 === addBefore }
  }

  /// `InstanceData.clone()`. Java's `SocMemoryInfo.clone()` is `Object.clone()`: a shallow
  /// field copy, so the cloned instance shares the *same* `ArrayList<SocMemoryInfoBlock>`
  /// reference as the original (each block is mutable, so writes through either clone are
  /// visible in both). Preserved: a forked `CircuitState`'s memory contents are the same
  /// upstream, by construction, and diverging that here would make Swift's `CircuitState.fork`
  /// behaviour differ from Java's for every SoC test bench that forks state.
  public func cloneData() -> any InstanceData {
    let copy = SocMemoryInfo()
    copy.blocks = blocks
    return copy
  }
}

extension SocMemoryInfoBlock {
  fileprivate var wordCount: Int { contents.count }
}

/// `com.cburch.logisim.soc.memory.SocMemoryState`.
public final class SocMemoryState: SocBusSlaveInterface {
  private var startAddressValue: Int32 = 0
  private var sizeInBytesValue: Int32 = 1024
  private let attachedBus = SocBusInfo("")
  private var labelValue = ""
  private var listeners: [any SocBusSlaveListener] = []

  public init() {}

  public var startAddress: Int32 { startAddressValue }
  public var memorySize: Int32 { sizeInBytesValue }

  /// `setStartAddress(int)`.
  @discardableResult
  public func setStartAddress(_ address: Int32) -> Bool {
    let addr = (address >> 2) << 2
    guard addr != startAddressValue else { return false }
    startAddressValue = addr
    fireMemoryMapChanged()
    return true
  }

  /// `setSize(BitWidth)`.
  @discardableResult
  public func setSize(_ width: BitWidth) -> Bool {
    let size = Int32(1 << width.width)
    guard size != sizeInBytesValue else { return false }
    sizeInBytesValue = size
    fireMemoryMapChanged()
    return true
  }

  public var socBusInfo: SocBusInfo { attachedBus }

  /// `setSocBusInfo(SocBusInfo)`.
  @discardableResult
  public func setSocBusInfo(_ info: SocBusInfo) -> Bool {
    guard attachedBus.busId != info.busId else { return false }
    attachedBus.busId = info.busId
    return true
  }

  public var label: String { labelValue }

  /// `setLabel(String)`.
  @discardableResult
  public func setLabel(_ value: String) -> Bool {
    guard labelValue != value else { return false }
    labelValue = value
    fireNameChanged()
    return true
  }

  public var slaveName: String {
    guard attachedBus.component != nil else { return "BUG: Unknown" }
    if !labelValue.isEmpty { return labelValue }
    guard let comp = attachedBus.component else { return "BUG: Unknown" }
    let loc = comp.location
    return "\(comp.factory.name)@\(loc.x),\(loc.y)"
  }

  public var component: (any Component)? { attachedBus.component }

  public func registerListener(_ listener: any SocBusSlaveListener) {
    guard !listeners.contains(where: { $0 === listener }) else { return }
    listeners.append(listener)
  }
  public func removeListener(_ listener: any SocBusSlaveListener) {
    listeners.removeAll { $0 === listener }
  }

  /// `getNewState()`.
  public func newState() -> SocMemoryInfo { SocMemoryInfo() }

  /// `canHandleTransaction(SocBusTransaction)`.
  public func canHandleTransaction(_ transaction: SocBusTransaction) -> Bool {
    let addr = SocSupport.convUnsignedInt(transaction.address)
    let start = SocSupport.convUnsignedInt(startAddressValue)
    let end = start + Int64(sizeInBytesValue)
    return addr >= start && addr < end
  }

  /// `handleTransaction(SocBusTransaction)`.
  public func handleTransaction(_ transaction: SocBusTransaction) {
    guard canHandleTransaction(transaction) else { return }
    if transaction.isReadTransaction {
      transaction.setReadData(
        performRead(address: transaction.address, type: transaction.accessType))
    }
    if transaction.isWriteTransaction {
      performWrite(
        address: transaction.address, data: transaction.writeData, type: transaction.accessType)
    }
    transaction.setTransactionResponder(attachedBus.component)
  }

  private func regPropagateState() -> SocMemoryInfo? {
    guard let manager = attachedBus.simulationManager, let comp = attachedBus.component else {
      return nil
    }
    return manager.data(for: comp) as? SocMemoryInfo
  }

  /// `performReadAction(int, int)`. All shift amounts here are compile-time literals (16, 8,
  /// 24), so Java's masked-shift vs. Swift's smart-shift divergence (see the module report)
  /// cannot bite: every shift is already `< 32`.
  private func performRead(address: Int32, type: SocAccessType) -> Int32 {
    let data = regPropagateState()
    let value = data?.word(at: (address >> 2) << 2) ?? Int32.random(in: Int32.min...Int32.max)
    switch type {
    case .word:
      return value
    case .halfWord:
      let bit1 = (address >> 1) & 1
      return bit1 == 1 ? (value >> 16) & 0xFFFF : value & 0xFFFF
    case .byte:
      switch address & 3 {
      case 0: return value & 0xFF
      case 1: return (value >> 8) & 0xFF
      case 2: return (value >> 16) & 0xFF
      default: return (value >> 24) & 0xFF
      }
    }
  }

  /// `performWriteAction(int, int, int)`; byte/half-word writes are read-modify-write against
  /// the current word, using the *old* word's untouched byte lanes. Ported field-for-field,
  /// including the byte-lane recombination that reads as odd at a glance (e.g. the byte-0 case
  /// combines `byte3|byte2|byte1` from the OLD word with the NEW byte 0); this is exactly what
  /// `SocMemoryState.java:310-321` does and is not a transcription error.
  private func performWrite(address: Int32, data: Int32, type: SocAccessType) {
    var writeData = data
    if type != .word {
      var oldData = performRead(address: address, type: .word)
      if type == .halfWord {
        let bit1 = (address >> 1) & 1
        var maskedData = data & 0xFFFF
        if bit1 == 1 {
          oldData &= 0xFFFF
          maskedData <<= 16
        } else {
          oldData = ((oldData >> 16) & 0xFFFF) << 16
        }
        writeData = oldData | maskedData
      } else {
        let byte0 = oldData & 0xFF
        let byte1 = ((oldData >> 8) & 0xFF) << 8
        let byte2 = ((oldData >> 16) & 0xFF) << 16
        let byte3 = ((oldData >> 24) & 0xFF) << 24
        let maskedData = data & 0xFF
        switch address & 3 {
        case 0: writeData = byte3 | byte2 | byte1 | maskedData
        case 1: writeData = byte3 | byte2 | byte0 | (maskedData << 8)
        case 2: writeData = byte3 | byte1 | byte0 | (maskedData << 16)
        default: writeData = byte2 | byte1 | byte0 | (maskedData << 24)
        }
      }
    }
    regPropagateState()?.writeWord(address, writeData)
  }

  private func fireNameChanged() {
    for listener in listeners { listener.labelChanged() }
  }
  private func fireMemoryMapChanged() {
    for listener in listeners { listener.memoryMapChanged() }
  }
}
