// ElfProgramHeader.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.soc.file.ElfProgramHeader),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16). See `ElfHeader.swift`'s file header for the
// one-`Data`-buffer and endian-decode-simplification notes, both of which apply here too.

import Foundation

public enum ElfProgramHeaderStatus: Sendable, Equatable {
  case ok
  case notFound  // PROGRAM_HEADER_NOT_FOUND_ERROR; offset does not fit in the file
  case truncated  // PROGRAM_HEADER_READ_ERROR / _SIZE_ERROR
}

/// `com.cburch.logisim.soc.file.ElfProgramHeader.ProgramHeader`.
public struct ElfProgramEntry {
  public static let typeNull: Int32 = 0
  public static let typeLoad: Int32 = 1

  public static let flagExecute: Int32 = 1
  public static let flagWrite: Int32 = 2
  public static let flagRead: Int32 = 4

  public let type: Int32
  public let flags: Int32
  public let offset: Int64
  public let virtualAddress: Int64
  public let physicalAddress: Int64
  public let fileSize: Int64
  public let memSize: Int64
  public let align: Int64
}

/// `com.cburch.logisim.soc.file.ElfProgramHeader`.
public struct ElfProgramHeader {
  public private(set) var status: ElfProgramHeaderStatus = .ok
  public private(set) var headers: [ElfProgramEntry] = []

  public var isValid: Bool { status == .ok }
  public var count: Int { headers.count }
  public func header(at index: Int) -> ElfProgramEntry? {
    guard headers.indices.contains(index) else { return nil }
    return headers[index]
  }

  /// An empty, still-valid program header. `ProcessorReadElf`'s failing initialisers need a
  /// placeholder for `let` fields they never populate, matching `ElfSectionHeader.init()`.
  public init() {}

  public init(data: Data, header: ElfHeader) {
    let bytes = [UInt8](data)
    guard let phOffset = header.value(.programHeaderOffset),
      let phCount = header.value(.programHeaderCount),
      let phEntrySize = header.value(.programHeaderEntrySize)
    else {
      status = .notFound
      return
    }
    let start = Int(phOffset)
    guard start >= 0, start <= bytes.count else {
      status = .notFound
      return
    }
    let entrySize = Int(phEntrySize)
    let is32 = header.is32Bit
    let le = header.isLittleEndian
    var entries: [ElfProgramEntry] = []
    entries.reserveCapacity(Int(phCount))
    for i in 0..<Int(phCount) {
      let base = start + i * entrySize
      guard base + entrySize <= bytes.count else {
        status = .truncated
        return
      }
      var idx = base
      let type = Int32(truncatingIfNeeded: ElfHeader.readInt(bytes, idx, 4, le))
      idx += 4
      var flags: Int32 = 0
      let step = is32 ? 4 : 8
      if !is32 {
        flags = Int32(truncatingIfNeeded: ElfHeader.readInt(bytes, idx, 4, le))
        idx += 4
      }
      let offset = ElfHeader.readLong(bytes, idx, step, le)
      idx += step
      let vaddr = ElfHeader.readLong(bytes, idx, step, le)
      idx += step
      let paddr = ElfHeader.readLong(bytes, idx, step, le)
      idx += step
      let filesz = ElfHeader.readLong(bytes, idx, step, le)
      idx += step
      let memsz = ElfHeader.readLong(bytes, idx, step, le)
      idx += step
      if is32 {
        flags = Int32(truncatingIfNeeded: ElfHeader.readInt(bytes, idx, 4, le))
        idx += 4
      }
      let align = ElfHeader.readLong(bytes, idx, step, le)
      entries.append(
        ElfProgramEntry(
          type: type, flags: flags,
          offset: ElfHeader.narrow(offset, is32Bit: is32),
          virtualAddress: ElfHeader.narrow(vaddr, is32Bit: is32),
          physicalAddress: ElfHeader.narrow(paddr, is32Bit: is32),
          fileSize: ElfHeader.narrow(filesz, is32Bit: is32),
          memSize: ElfHeader.narrow(memsz, is32Bit: is32),
          align: ElfHeader.narrow(align, is32Bit: is32)))
    }
    headers = entries
  }

  public var errorDescription: String {
    switch status {
    case .ok: return "program header read successfully"
    case .notFound: return "could not locate the program header table"
    case .truncated: return "the program header table is truncated"
    }
  }
}
