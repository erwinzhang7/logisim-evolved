/*
 * logisim-evolved: a native Swift/macOS port of logisim-evolution.
 * Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution),
 * which is GPL-3.0-only. This port is therefore also GPL-3.0-only.
 *
 * Ports: soc/rv32im/Rv32imPlicState.java (4.1.0): the minimal single-context PLIC (platform-
 * level interrupt controller) model: pending/enable/claimed bitmasks, priority threshold, and
 * the claim/complete register pair, plus its role as an MMIO-mapped bus slave.
 *
 * ── The three seams this file declared have all been closed, and the notes say how ───────────
 *
 * This slice was written before `soc/data` was available to it, so it stood in three types of
 * its own. All three now exist for real, in this same module, and standing in for a type that
 * exists is exactly the "two implementations of one semantic" defect D15a records:
 *
 *   - `Rv32imBusSlave`/`Rv32imSlaveTransaction`: a private slave protocol with **one conformer
 *     (this class) and zero callers**. Replaced by the real `SocBusSlaveInterface`/
 *     `SocBusTransaction`, which is what `SocBusFabric` actually dispatches to, so the PLIC is
 *     now reachable from a bus instead of only from a test. The register logic below is the
 *     same logic, re-expressed against Java's own transaction object, which also recovers the
 *     error *codes* (`ACCESS_TYPE_NOT_SUPPORTED_ERROR`, `READ_ONLY_ACCESS_ERROR`,
 *     `MISALIGNED_ADDRESS_ERROR`) that the string-only `errorMessage` field had flattened.
 *   - `Rv32imPlicListener`: a two-method copy of `SocBusSlaveListener`. Deleted.
 *   - `getComponent()`/`getName()`'s component-location fallback, dropped as "needs a live
 *     placed Component". It has one: `attachedBus.component`, set by
 *     `SocSimulationManager.registerComponent`. Restored, including the `"BUG: Unknown"`
 *     literal upstream returns when the back-pointer is absent.
 *
 * STILL A SEAM, deliberately:
 *   - `updateFromIrqPorts(InstanceState)` reading `Value` off ports and
 *     `RV32imAttributes.RV32IM_STATE` off an `AttributeSet`; kept as
 *     `updateFromIrqPorts(numberOfIrqs:irqLines:)`, taking plain `Int`/`[Bool]`. Only
 *     `Value.TRUE` counted as asserted in the Java (`state.getPortValue(i + 2) == Value.TRUE`);
 *     UNKNOWN/FALSE/ERROR all read as "not asserted" there, which is exactly what collapsing to
 *     `Bool` preserves. `Rv32imRiscV.propagate` does that translation, at the one call site.
 *
 * `pending`/`enable`/`claimed` are Java `long` fields (64-bit bitmasks over up to 32 IRQ
 * sources, bit index 1…32), NOT 32-bit registers; kept as `Int64` rather than the wrap32'd
 * `Int` convention the rest of this slice uses for register/CSR/instruction words, to keep
 * that distinction visible at every call site.
 */

import Foundation
import LogisimFile
import LogisimKernel

public final class Rv32imPlicState: SocBusSlaveInterface {
  private static let defaultBaseAddress = 0x0C00_0000
  private static let plicMmioSize = 0x0040_0000

  private static let regPending0 = 0x0000_1000
  private static let regPending1 = 0x0000_1004
  private static let regEnable0 = 0x0000_2000
  private static let regEnable1 = 0x0000_2004
  private static let regThreshold = 0x0020_0000
  private static let regClaimComplete = 0x0020_0004

  private var listeners: [any SocBusSlaveListener] = []

  /// Java: `private SocBusInfo attachedBus`, assigned from `upState.getAttachedBus()` by
  /// `RV32imAttributes`'s constructor and by its `SOC_BUS_SELECT` setter: so the PLIC and the
  /// CPU share one `SocBusInfo` object, which is how the PLIC learns which component it belongs
  /// to. Strong, as Java's is: `SocBusInfo`'s own edges are weak, so no cycle closes here.
  public var attachedBus: SocBusInfo?

  /// Java: the `startAddress` field. Named apart from the `SocBusSlaveInterface.startAddress`
  /// requirement below because Java's `getStartAddress()` returns `Integer` while the field is
  /// an `int`; the port's protocol uses `Int32`, and collapsing the two would silently change
  /// the type `setPlicBaseAddress` and `RV32imAttributes` work in.
  public private(set) var baseAddress: Int = Rv32imPlicState.defaultBaseAddress
  public private(set) var label: String = ""

  private var nrOfSources = 0
  private var pending: Int64 = 0
  private var enable: Int64 = 0
  private var claimed: Int64 = 0
  private var threshold: Int = 0

  public init() {}

  // MARK: Listeners

  public func registerListener(_ listener: any SocBusSlaveListener) {
    if !listeners.contains(where: { $0 === listener }) { listeners.append(listener) }
  }

  public func removeListener(_ listener: any SocBusSlaveListener) {
    listeners.removeAll { $0 === listener }
  }

  private func fireLabelChanged() { for l in listeners { l.labelChanged() } }
  private func fireMemoryMapChanged() { for l in listeners { l.memoryMapChanged() } }

  // MARK: Configuration

  @discardableResult
  public func setPlicBaseAddress(_ address: Int) -> Bool {
    let aligned = (address >> 2) << 2
    if baseAddress == aligned { return false }
    baseAddress = aligned
    fireMemoryMapChanged()
    return true
  }

  @discardableResult
  public func setLabel(_ value: String) -> Bool {
    if label == value { return false }
    label = value
    fireLabelChanged()
    return true
  }

  // MARK: IRQ sampling (Java: updateFromIrqPorts(InstanceState))

  /// `numberOfIrqs` mirrors Java's live re-read of `RV32imAttributes.RV32IM_STATE.getNrOfIrqs()`
  /// on every call (clamped 0...32, exactly as Java's `Math.max(0, Math.min(32, ...))`) rather
  /// than a value cached at construction, since the Java also re-samples it every call.
  /// `irqLines[i]` corresponds to Java's `state.getPortValue(i + 2) == Value.TRUE` for source
  /// `i + 1`; index 0 of `irqLines` is IRQ source 1, matching the Java's `src = i + 1`.
  public func updateFromIrqPorts(numberOfIrqs: Int, irqLines: [Bool]) {
    nrOfSources = max(0, min(32, numberOfIrqs))

    var level: Int64 = 0
    for i in 0..<nrOfSources where i < irqLines.count && irqLines[i] {
      let src = i + 1
      level |= Int64(1) << src
    }

    let claimedMask = claimed & sourceMask
    let levelUnclaimed = level & ~claimedMask

    // For level-triggered sources, pending stays asserted while the source is high, except
    // when it is already claimed.
    pending &= (levelUnclaimed | claimedMask)
    pending |= levelUnclaimed

    // Always drop any pending bit that is currently claimed.
    pending &= ~claimedMask
  }

  public var isMachineExternalInterruptPending: Bool {
    if threshold != 0 { return false }
    return ((pending & enable) & sourceMask) != 0
  }

  private var sourceMask: Int64 {
    // `1...nrOfSources` would be an invalid (crashing) range if `nrOfSources == 0`; Java's
    // equivalent `for (int src = 1; src <= nrOfSources; src++)` simply does not execute its
    // body in that case, which `stride` reproduces without needing a range at all.
    var mask: Int64 = 0
    for src in stride(from: 1, through: nrOfSources, by: 1) {
      mask |= Int64(1) << src
    }
    return mask
  }

  private func selectClaimId() -> Int {
    if threshold != 0 { return 0 }
    let candidates = (pending & enable) & sourceMask
    if candidates == 0 { return 0 }
    for src in stride(from: 1, through: nrOfSources, by: 1) {
      if (candidates & (Int64(1) << src)) != 0 { return src }
    }
    return 0
  }

  // MARK: Register word packing (Java: readWord/writeWord — pack/unpack a 32-bit half of a
  // 64-bit bitmask register)

  private func readWord(_ value: Int64, upper: Bool) -> Int {
    let shifted = upper ? (value >> 32) : value
    return Int(shifted & 0xFFFF_FFFF)
  }

  private func writeWord(_ oldValue: Int64, newWord: Int, upper: Bool) -> Int64 {
    let word = Int64(newWord) & 0xFFFF_FFFF
    if upper {
      return (oldValue & 0xFFFF_FFFF) | (word << 32)
    }
    return (oldValue & Int64(bitPattern: 0xFFFF_FFFF_0000_0000)) | word
  }

  // MARK: - SocBusSlaveInterface (Java: canHandleTransaction/handleTransaction and friends)

  /// `getStartAddress()`.
  public var startAddress: Int32 { Int32(truncatingIfNeeded: baseAddress) }
  /// `getMemorySize()`.
  public var memorySize: Int32 { Int32(Self.plicMmioSize) }

  /// `getComponent()`. Upstream narrows to `InstanceComponent`; D3 deleted the `Instance`
  /// facade, so the placement itself is what everything downstream wants.
  public var component: (any Component)? { attachedBus?.component }

  /// `getName()`, including upstream's literal `"BUG: Unknown"` for the no-back-pointer case,
  /// which is not decoration: it is how a peripheral that never got registered announces itself
  /// in the memory-map window, and preserving it keeps that diagnostic working.
  public var slaveName: String {
    guard let comp = attachedBus?.component else { return "BUG: Unknown" }
    if !label.isEmpty { return label }
    let loc = comp.location
    return "\(comp.factory.name)@\(loc.x),\(loc.y)"
  }

  public func canHandleTransaction(_ transaction: SocBusTransaction) -> Bool {
    let addr = SocSupport.convUnsignedInt(transaction.address)
    let start = SocSupport.convUnsignedInt(startAddress)
    let end = start + Int64(Self.plicMmioSize)
    return addr >= start && addr < end
  }

  /// `handleTransaction(SocBusTransaction)`.
  ///
  /// Note the responder is set **before** the access-type check, so a rejected access still
  /// records who rejected it; that ordering is upstream's (`Rv32imPlicState.java:179-184`) and
  /// is visible in the bus trace window.
  public func handleTransaction(_ transaction: SocBusTransaction) {
    guard canHandleTransaction(transaction) else { return }

    transaction.setTransactionResponder(attachedBus?.component)

    guard transaction.accessType == .word else {
      transaction.setError(.accessTypeNotSupported)
      return
    }

    let addr = SocSupport.convUnsignedInt(transaction.address)
    let start = SocSupport.convUnsignedInt(startAddress)
    let offset = Int(addr - start)

    switch offset {
    case Self.regPending0:
      if transaction.isWriteTransaction {
        transaction.setError(.readOnlyAccess)
        return
      }
      transaction.setReadData(Int32(truncatingIfNeeded: readWord(pending, upper: false)))
    case Self.regPending1:
      if transaction.isWriteTransaction {
        transaction.setError(.readOnlyAccess)
        return
      }
      transaction.setReadData(Int32(truncatingIfNeeded: readWord(pending, upper: true)))
    case Self.regEnable0:
      if transaction.isReadTransaction {
        transaction.setReadData(Int32(truncatingIfNeeded: readWord(enable, upper: false)))
      }
      if transaction.isWriteTransaction {
        enable = writeWord(enable, newWord: Int(transaction.writeData), upper: false)
        enable &= sourceMask
      }
    case Self.regEnable1:
      if transaction.isReadTransaction {
        transaction.setReadData(Int32(truncatingIfNeeded: readWord(enable, upper: true)))
      }
      if transaction.isWriteTransaction {
        enable = writeWord(enable, newWord: Int(transaction.writeData), upper: true)
        enable &= sourceMask
      }
    case Self.regThreshold:
      if transaction.isReadTransaction {
        transaction.setReadData(Int32(truncatingIfNeeded: threshold))
      }
      if transaction.isWriteTransaction { threshold = Int(transaction.writeData) }
    case Self.regClaimComplete:
      if transaction.isReadTransaction {
        let id = selectClaimId()
        if id != 0 {
          let bit = Int64(1) << id
          pending &= ~bit
          claimed |= bit
        }
        transaction.setReadData(Int32(truncatingIfNeeded: id))
      }
      if transaction.isWriteTransaction {
        let id = Int(transaction.writeData)
        guard id >= 1 && id <= nrOfSources else { return }
        claimed &= ~(Int64(1) << id)
      }
    default:
      transaction.setError(.misalignedAddress)
    }
  }
}
