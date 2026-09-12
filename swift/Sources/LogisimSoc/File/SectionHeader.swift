// SectionHeader.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.soc.file.SectionHeader),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).

import Foundation

/// `com.cburch.logisim.soc.file.SectionHeader`.
public struct SectionHeaderEntry {
  public static let flagWrite: Int64 = 1
  public static let flagAlloc: Int64 = 2
  public static let flagExecInstr: Int64 = 4

  public static let typeNull: Int32 = 0
  public static let typeProgBits: Int32 = 1
  public static let typeSymTab: Int32 = 2
  public static let typeStrTab: Int32 = 3

  public let nameOffset: Int32
  public let type: Int32
  public let flags: Int64
  public let address: Int64
  public let offset: Int64
  public let size: Int64
  public let link: Int32
  public let info: Int32
  public let addrAlign: Int64
  public let entSize: Int64
  public var name: String = ""
  public var symbols: [SymbolTableEntry] = []

  public var isWritable: Bool { (flags & Self.flagWrite) != 0 }
  public var isAllocated: Bool { (flags & Self.flagAlloc) != 0 }
  public var isExecutable: Bool { (flags & Self.flagExecInstr) != 0 }

  public init(data: [UInt8], is32Bit: Bool, littleEndian: Bool, offset headerOffset: Int) {
    var idx = headerOffset
    let step = is32Bit ? 4 : 8
    nameOffset = Int32(truncatingIfNeeded: ElfHeader.readInt(data, idx, 4, littleEndian))
    idx += 4
    type = Int32(truncatingIfNeeded: ElfHeader.readInt(data, idx, 4, littleEndian))
    idx += 4
    flags = ElfHeader.readLong(data, idx, step, littleEndian)
    idx += step
    address = ElfHeader.readLong(data, idx, step, littleEndian)
    idx += step
    offset = ElfHeader.readLong(data, idx, step, littleEndian)
    idx += step
    size = ElfHeader.readLong(data, idx, step, littleEndian)
    idx += step
    link = Int32(truncatingIfNeeded: ElfHeader.readInt(data, idx, 4, littleEndian))
    idx += 4
    info = Int32(truncatingIfNeeded: ElfHeader.readInt(data, idx, 4, littleEndian))
    idx += 4
    addrAlign = ElfHeader.readLong(data, idx, step, littleEndian)
    idx += step
    entSize = ElfHeader.readLong(data, idx, step, littleEndian)
  }
}
