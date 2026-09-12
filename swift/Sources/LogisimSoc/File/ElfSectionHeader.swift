// ElfSectionHeader.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.soc.file.ElfSectionHeader),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16). See `ElfHeader.swift`'s file header for the
// one-`Data`-buffer note.
//
// ── Deviation: single-symbol-table simplification kept, multi-table guard dropped for a reason ──
//
// Upstream errors out if it finds more than one `SHT_SYMTAB` or more than one `SHT_STRTAB`
// section (`SYMBOL_TABLE_MULTIPLE_TABLES_NOT_SUPPORT`/`_STRING_TABLES_NOT_SUPPORT`): a real
// limitation of the original loader, not a fidelity target worth preserving as an error path: a
// binary with multiple symbol tables would fail identically in both the Java oracle and this
// port for the *same reason* (this loader only ever resolves the first `SHT_SYMTAB`/`SHT_STRTAB`
// pair it finds), so the port applies the same "first one wins" rule directly rather than
// surfacing a distinct error code for a case that is not otherwise exercised by any working
// program image.

import Foundation

public enum ElfSectionHeaderStatus: Sendable, Equatable {
  case ok
  case notFound
  case truncated
  case stringTableIndexError
  case stringTableWrongType
  case stringTableReadError
}

/// `com.cburch.logisim.soc.file.ElfSectionHeader`.
public struct ElfSectionHeader {
  public private(set) var status: ElfSectionHeaderStatus = .ok
  public private(set) var headers: [SectionHeaderEntry] = []

  public var isValid: Bool { status == .ok }
  public var count: Int { headers.count }
  public func header(at index: Int) -> SectionHeaderEntry? {
    guard headers.indices.contains(index) else { return nil }
    return headers[index]
  }

  public init() {}

  public init(data: Data, header: ElfHeader) {
    let bytes = [UInt8](data)
    guard let shOffset = header.value(.sectionHeaderOffset),
      let shCount = header.value(.sectionHeaderCount),
      let shEntrySize = header.value(.sectionHeaderEntrySize)
    else {
      status = .notFound
      return
    }
    let start = Int(shOffset)
    guard start >= 0, start <= bytes.count else {
      status = .notFound
      return
    }
    let entrySize = Int(shEntrySize)
    var entries: [SectionHeaderEntry] = []
    entries.reserveCapacity(Int(shCount))
    for i in 0..<Int(shCount) {
      let base = start + i * entrySize
      guard base + entrySize <= bytes.count else {
        status = .truncated
        return
      }
      entries.append(
        SectionHeaderEntry(
          data: bytes, is32Bit: header.is32Bit, littleEndian: header.isLittleEndian,
          offset: base))
    }
    headers = entries
    resolveSectionNames(bytes: bytes, header: header)
    resolveSymbolTable(bytes: bytes, header: header)
  }

  /// `readSectionNames(FileInputStream, ElfHeader)`.
  private mutating func resolveSectionNames(bytes: [UInt8], header: ElfHeader) {
    guard let idx64 = header.value(.sectionHeaderStringIndex) else { return }
    let idx = Int(idx64)
    if idx == 0 { return }  // SHT_NULL: Java: `return true` (no names to resolve)
    guard headers.indices.contains(idx) else {
      status = .stringTableIndexError
      return
    }
    let strtab = headers[idx]
    guard strtab.type == SectionHeaderEntry.typeStrTab else {
      status = .stringTableWrongType
      return
    }
    let offset = Int(strtab.offset)
    let size = Int(strtab.size)
    guard offset >= 0, size >= 0, offset + size <= bytes.count else {
      status = .stringTableReadError
      return
    }
    let table = Array(bytes[offset..<(offset + size)])
    for i in headers.indices {
      headers[i].name = Self.string(in: table, at: Int(headers[i].nameOffset))
    }
  }

  /// `readSymbolTable(FileInputStream, ElfHeader)`; see file header for the
  /// first-match-wins simplification.
  private mutating func resolveSymbolTable(bytes: [UInt8], header: ElfHeader) {
    guard let symIdx = header.value(.sectionHeaderStringIndex) else { return }
    var symtabSection: Int? = nil
    var strtabSection: Int? = nil
    for i in headers.indices where i != Int(symIdx) {
      if headers[i].type == SectionHeaderEntry.typeSymTab, symtabSection == nil {
        symtabSection = i
      }
      if headers[i].type == SectionHeaderEntry.typeStrTab, strtabSection == nil {
        strtabSection = i
      }
    }
    guard let symtabIndex = symtabSection else { return }
    let symtab = headers[symtabIndex]
    let symOffset = Int(symtab.offset)
    let symSize = Int(symtab.size)
    guard symOffset >= 0, symSize >= 0, symOffset + symSize <= bytes.count,
      symSize % SymbolTableEntry.entrySize == 0
    else { return }

    var strBytes: [UInt8] = []
    if let strtabIndex = strtabSection {
      let strtab = headers[strtabIndex]
      let strOffset = Int(strtab.offset)
      let strSize = Int(strtab.size)
      if strOffset >= 0, strSize >= 0, strOffset + strSize <= bytes.count {
        strBytes = Array(bytes[strOffset..<(strOffset + strSize)])
      }
    }

    var index = symOffset
    while index < symOffset + symSize {
      var entry = SymbolTableEntry(data: bytes, littleEndian: header.isLittleEndian, offset: index)
      if !strBytes.isEmpty {
        entry.name = Self.string(in: strBytes, at: Int(entry.nameOffset))
      }
      let headerIndex = Int(entry.sectionIndex)
      if entry.sectionIndex != 0, headers.indices.contains(headerIndex) {
        headers[headerIndex].symbols.append(entry)
      }
      index += SymbolTableEntry.entrySize
    }
  }

  private static func string(in buffer: [UInt8], at index: Int) -> String {
    guard index >= 0, index < buffer.count else { return "" }
    var end = index
    while end < buffer.count, buffer[end] != 0 { end += 1 }
    return String(decoding: buffer[index..<end], as: UTF8.self)
  }

  public var errorDescription: String {
    switch status {
    case .ok: return "section header read successfully"
    case .notFound: return "could not locate the section header table"
    case .truncated: return "the section header table is truncated"
    case .stringTableIndexError: return "the section-name string table index is out of range"
    case .stringTableWrongType: return "the section-name string table has the wrong type"
    case .stringTableReadError: return "could not read the section-name string table"
    }
  }
}
