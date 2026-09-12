// SymbolTable.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.soc.file.SymbolTable),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).

import Foundation

/// `com.cburch.logisim.soc.file.SymbolTable`.
public struct SymbolTableEntry {
  public static let bindLocal: Int32 = 0
  public static let bindGlobal: Int32 = 1
  public static let bindWeak: Int32 = 2

  public static let typeNoType: Int32 = 0
  public static let typeObject: Int32 = 1
  public static let typeFunc: Int32 = 2
  public static let typeSection: Int32 = 3
  public static let typeFile: Int32 = 4

  public static let entrySize = 16

  public let nameOffset: Int32
  public let value: Int32
  public let size: Int32
  public let info: Int32
  public let other: Int32
  public let sectionIndex: Int32
  public var name: String = ""

  public var symbolType: Int32 { info & 0xF }
  public var binding: Int32 { (info >> 4) & 0xF }

  public init(data: [UInt8], littleEndian: Bool, offset: Int) {
    var idx = offset
    nameOffset = Int32(truncatingIfNeeded: ElfHeader.readInt(data, idx, 4, littleEndian))
    idx += 4
    value = Int32(truncatingIfNeeded: ElfHeader.readInt(data, idx, 4, littleEndian))
    idx += 4
    size = Int32(truncatingIfNeeded: ElfHeader.readInt(data, idx, 4, littleEndian))
    idx += 4
    info = idx < data.count ? Int32(data[idx]) : 0
    idx += 1
    other = idx < data.count ? Int32(data[idx]) : 0
    idx += 1
    sectionIndex = Int32(truncatingIfNeeded: ElfHeader.readInt(data, idx, 2, littleEndian))
  }
}
