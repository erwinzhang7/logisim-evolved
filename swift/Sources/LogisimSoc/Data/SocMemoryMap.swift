// SocMemoryMap.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.soc.data.SocMemMapModel),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// This is the address-overlap detector behind the memory-map inspector window: given the set of
// slaves registered on a bus, compute a gapless, sorted list of address ranges (filling unmapped
// holes with synthetic "empty" entries) and flag any slave whose range overlaps another's.
//
// Not ported: `AbstractTableModel`/`JTable`/renderer conformance, `MemoryMapHeaderRenderer`,
// `SlaveInfoRenderer`, the mouse-click-to-highlight-the-component behaviour; all Swing UI
// (D6/D9). `rebuild()` below is the pure computation upstream's `rebuild()` did before firing
// `fireTableDataChanged()`; the UI layer calls it and renders `entries` itself.
//
// ── Numeric fidelity ─────────────────────────────────────────────────────────────────────────
//
// Every address here is compared as a 64-bit *unsigned* magnitude via `SocSupport
// .convUnsignedInt`, exactly as upstream's `longMask`-based `SlaveInfo.getStartAddress()` does,
// so a slave based at `0x8000_0000` (top bit set) still sorts and overlaps correctly instead of
// comparing as negative.

import Foundation
import LogisimFile
import LogisimKernel

/// `SocMemMapModel.SlaveInfo`.
public final class SocMemoryMapEntry {
  /// `nil` for a synthetic "empty" gap-filler entry (Java's `slave == null` constructor).
  public let slave: (any SocBusSlaveInterface)?
  private let emptyStart: Int64
  private let emptyEnd: Int64
  public private(set) var hasOverlap = false

  public init(slave: any SocBusSlaveInterface) {
    self.slave = slave
    self.emptyStart = 0
    self.emptyEnd = 0
  }

  /// The synthetic-gap constructor. `start`/`end` are already unsigned 64-bit magnitudes.
  public init(emptyStart start: Int64, emptyEnd end: Int64) {
    self.slave = nil
    self.emptyStart = start
    self.emptyEnd = end
  }

  /// `SlaveInfo.getStartAddress()`.
  public var startAddress: Int64 {
    guard let slave else { return emptyStart }
    return SocSupport.convUnsignedInt(slave.startAddress)
  }

  /// `SlaveInfo.getEndAddress()`.
  public var endAddress: Int64 {
    guard let slave else { return emptyEnd }
    let start = SocSupport.convUnsignedInt(slave.startAddress)
    let size = SocSupport.convUnsignedInt(slave.memorySize)
    return start + size - 1
  }

  /// `SlaveInfo.getName()`.
  public var name: String { slave?.slaveName ?? "(empty)" }

  /// `SlaveInfo.contains(long)`: also the side-effecting overlap probe upstream performs
  /// in-line (`hasOverlap |= ret`), preserved exactly: calling `contains` on an entry during
  /// `SlaveMap.add` is what actually marks it overlapping.
  @discardableResult
  public func contains(_ address: Int64) -> Bool {
    let result = address >= startAddress && address <= endAddress
    hasOverlap = hasOverlap || result
    return result
  }

  fileprivate func markOverlap() { hasOverlap = true }
}

/// `SocMemMapModel.SlaveMap` + the registration bookkeeping from `SocMemMapModel` itself, minus
/// the `AbstractTableModel`/`JTable`/mouse-listener machinery (see file header).
public final class SocMemoryMap {
  private static let addressSpaceTop = SocSupport.convUnsignedInt(Int32(-1))  // 0xFFFF_FFFF

  private var slaves: [any SocBusSlaveInterface] = []
  public private(set) var entries: [SocMemoryMapEntry] = []

  public init() {
    rebuild()
  }

  /// `registerSocBusSlave(SocBusSlaveInterface)`.
  public func registerSlave(_ slave: any SocBusSlaveInterface) {
    guard !slaves.contains(where: { $0 === slave }) else { return }
    slaves.append(slave)
    slave.registerListener(rebuildListener)
    rebuild()
  }

  /// `removeSocBusSlave(SocBusSlaveInterface)`.
  public func removeSlave(_ slave: any SocBusSlaveInterface) {
    guard let index = slaves.firstIndex(where: { $0 === slave }) else { return }
    slaves.remove(at: index)
    slave.removeListener(rebuildListener)
    rebuild()
  }

  /// `getSlaves()`.
  public var registeredSlaves: [any SocBusSlaveInterface] { slaves }

  /// `SlaveMap.add`: inserts `entry` keeping the list sorted by start address (Java scans for
  /// the first existing entry whose start is `>=` the new one's and inserts before it), marking
  /// overlaps on both sides exactly as upstream does.
  private func insert(_ entry: SocMemoryMapEntry, into list: inout [SocMemoryMapEntry]) {
    guard !list.isEmpty else {
      list.append(entry)
      return
    }
    for i in 0..<list.count {
      let existing = list[i]
      if existing.contains(entry.startAddress) {
        entry.markOverlap()
      }
      if existing.startAddress >= entry.startAddress {
        if entry.contains(existing.startAddress) {
          existing.markOverlap()
        }
        list.insert(entry, at: i)
        return
      }
    }
    list.append(entry)
  }

  /// `rebuild()`; the pure part (see file header for what was dropped).
  public func rebuild() {
    var list: [SocMemoryMapEntry] = []
    if slaves.isEmpty {
      insert(SocMemoryMapEntry(emptyStart: 0, emptyEnd: -1), into: &list)
    } else {
      for slave in slaves {
        insert(SocMemoryMapEntry(slave: slave), into: &list)
      }
      var empties: [SocMemoryMapEntry] = []
      var addr: Int64 = 0
      for entry in list {
        if addr < entry.startAddress {
          empties.append(SocMemoryMapEntry(emptyStart: addr, emptyEnd: entry.startAddress - 1))
        }
        addr = entry.endAddress + 1
      }
      if addr < Self.addressSpaceTop {
        empties.append(SocMemoryMapEntry(emptyStart: addr, emptyEnd: Self.addressSpaceTop))
      }
      for entry in empties {
        insert(entry, into: &list)
      }
    }
    entries = list
  }

  /// Bridges a slave's `labelChanged()`/`memoryMapChanged()` callbacks (both of which upstream
  /// maps to `rebuild()`) into this instance without `SocMemoryMap` itself needing to be the
  /// `SocBusSlaveListener` (keeps the listener registration symmetric with
  /// `registerSlave`/`removeSlave` identity checks above).
  private lazy var rebuildListener = RebuildListener(owner: self)

  private final class RebuildListener: SocBusSlaveListener {
    weak var owner: SocMemoryMap?
    init(owner: SocMemoryMap) { self.owner = owner }
    func labelChanged() { owner?.rebuild() }
    func memoryMapChanged() { owner?.rebuild() }
  }
}
