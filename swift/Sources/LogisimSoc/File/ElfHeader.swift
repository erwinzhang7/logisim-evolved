// ElfHeader.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.soc.file.ElfHeader),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// The ELF loader family (`ElfHeader`/`ElfProgramHeader`/`ElfSectionHeader`/`SectionHeader`/
// `SymbolTable`/`ProcessorReadElf`) is how a compiled RISC-V/Nios II binary gets its instructions
// and initial data written into `SocMemory` before a CPU core starts executing: the one place
// in this slice where a genuinely untrusted file format (a `.elf` the user picked from disk, not
// a `.circ`) is parsed byte-by-byte. D13 applies just as much here as to a malformed `.circ`:
// truncated files, bad magic numbers, and inconsistent header counts must produce a status the
// caller can report, never a crash, and this is in fact already how upstream is written (a
// status-code state machine, `isValid()`/`getErrorString()`), so no exception→throw conversion
// was needed; the port only had to keep every early-return path intact.
//
// ── Architectural deviation: one `Data` buffer, not five reopened `FileInputStream`s ───────────
//
// Java re-opens the same file with a fresh `FileInputStream` for every structure (header, program
// headers, section headers, section-name string table, symbol table) and `skip()`s to the right
// offset each time: five file opens minimum, more for larger symbol tables. RISC-V/Nios II test
// program images in this project's size range (kilobytes to low megabytes) make "read the whole
// file into memory once" strictly simpler and no less correct: every offset Java computes via
// `skip()` is computed here as a slice into the same `Data`, and every bounds/short-read check
// Java performs (`nrRead != expectedSize`) becomes a bounds check against `data.count`. This is
// disclosed because it is a real behavioural difference in *failure mode granularity*; Java can
// fail with "could not skip to the program header" separately from "found the offset but read
// too few bytes"; this port folds both into "the requested range does not fit in the file",
// reported through the same status enum. No successfully-loading `.elf` behaves differently.
//
// ── Endian-decode simplification ────────────────────────────────────────────────────────────────
//
// `getLongValue`/`getIntValue` upstream build the result with an obfuscated shift-register loop
// (`result >>= 8; result |= value << (n-1)*8`) rather than the direct formula. Working through it
// byte by byte (see the git history of this file for the derivation) shows it is algebraically
// exactly `Σ byte[i] << 8*i` for little-endian and the direct MSB-first accumulation for
// big-endian: i.e., ordinary multi-byte decoding, obtained by an unusual route. `readInt`/
// `readLong` below compute the same values directly; this is a simplification of *expression*,
// not of *behaviour*; every input produces the identical output, including the
// past-end-of-buffer-reads-as-zero padding both versions apply per byte.

import Foundation

/// One ELF `e_ident[]` field name, `E_TYPE`…`E_SHSTRNDX`, or a raw `e_ident` byte index.
/// Kept as an enum rather than Java's flat `int` constants so `ElfHeader.value(for:)`'s switch is
/// exhaustive and a caller cannot pass an out-of-range identifier by construction.
public enum ElfHeaderField: Sendable {
  case type, machine, version, entry, programHeaderOffset, sectionHeaderOffset, flags
  case headerSize, programHeaderEntrySize, programHeaderCount
  case sectionHeaderEntrySize, sectionHeaderCount, sectionHeaderStringIndex
}

public enum ElfHeaderStatus: Sendable, Equatable {
  case ok
  case truncated  // EI_SIZE_ERROR / E_SIZE_ERROR
  case badMagic  // EI_MAGIC_ERROR
  case badClass  // EI_CLASS_ERROR
  case badEncoding  // EI_DATA_ERROR
}

/// `com.cburch.logisim.soc.file.ElfHeader`.
public struct ElfHeader {
  public static let identSize = 16
  private static let magic: [UInt8] = [0x7F, 0x45, 0x4C, 0x46]
  private static let classOffset = 4
  private static let dataOffset = 5
  private static let class32: UInt8 = 1
  private static let class64: UInt8 = 2
  private static let dataLittleEndian: UInt8 = 1
  private static let dataBigEndian: UInt8 = 2
  private static let headerSize32 = 0x34
  private static let headerSize64 = 0x40

  public static let typeExec: Int32 = 0x02

  public static let machineOpenRisc: Int32 = 92
  public static let machineNios2: Int32 = 113
  public static let machineRiscV: Int32 = 243

  public private(set) var status: ElfHeaderStatus = .ok
  private var ident: [UInt8]
  private var fields: [ElfHeaderField: Int64] = [:]

  public var isValid: Bool { status == .ok }
  public var is32Bit: Bool { ident[Self.classOffset] == Self.class32 }
  public var isLittleEndian: Bool { ident[Self.dataOffset] == Self.dataLittleEndian }

  /// Parses the ELF header out of `data` starting at offset 0. Mirrors the constructor's early
  /// returns exactly (magic check, then class check, then encoding check, then the rest of the
  /// header), each leaving `status` set and no further fields populated: matching Java's
  /// early-`return` chain in the constructor.
  public init(data: Data) {
    ident = Array(data.prefix(Self.identSize))
    guard ident.count == Self.identSize else {
      status = .truncated
      return
    }
    guard Array(ident.prefix(4)) == Self.magic else {
      status = .badMagic
      return
    }
    guard ident[Self.classOffset] == Self.class32 || ident[Self.classOffset] == Self.class64 else {
      status = .badClass
      return
    }
    guard ident[Self.dataOffset] == Self.dataLittleEndian
      || ident[Self.dataOffset] == Self.dataBigEndian
    else {
      status = .badEncoding
      return
    }
    let headerSize = is32Bit ? Self.headerSize32 : Self.headerSize64
    let bytes = [UInt8](data)
    guard bytes.count >= headerSize else {
      status = .truncated
      return
    }
    var index = Self.identSize
    let fieldSize = is32Bit ? 4 : 8
    let le = isLittleEndian
    func u16() -> Int64 { defer { index += 2 }; return ElfHeader.readInt(bytes, index, 2, le) }
    func u32() -> Int64 { defer { index += 4 }; return ElfHeader.readInt(bytes, index, 4, le) }
    func addr() -> Int64 {
      defer { index += fieldSize }
      return ElfHeader.readLong(bytes, index, fieldSize, le)
    }
    fields[.type] = u16()
    fields[.machine] = u16()
    fields[.version] = u32()
    fields[.entry] = addr()
    fields[.programHeaderOffset] = addr()
    fields[.sectionHeaderOffset] = addr()
    fields[.flags] = u32()
    fields[.headerSize] = u16()
    fields[.programHeaderEntrySize] = u16()
    fields[.programHeaderCount] = u16()
    fields[.sectionHeaderEntrySize] = u16()
    fields[.sectionHeaderCount] = u16()
    fields[.sectionHeaderStringIndex] = u16()
  }

  /// `getValue(int)`. `nil` when the header failed to parse, matching Java returning `null`.
  public func value(_ field: ElfHeaderField) -> Int64? {
    guard isValid else { return nil }
    return fields[field]
  }

  public func architectureName(_ machine: Int32) -> String {
    switch machine {
    case Self.machineOpenRisc: return "Open Risc"
    case Self.machineNios2: return "Nios II"
    case Self.machineRiscV: return "Risc V"
    default: return "unknown architecture"
    }
  }

  public var errorDescription: String {
    switch status {
    case .ok: return "no errors"
    case .truncated: return "the ELF file is truncated"
    case .badMagic: return "not an ELF file (bad magic number)"
    case .badClass: return "unsupported ELF class"
    case .badEncoding: return "unsupported ELF byte order"
    }
  }

  // MARK: - Byte-order decoding (see file header for the derivation)

  /// `getLongValue(byte[], int, int, boolean)`, direct form.
  static func readLong(_ buffer: [UInt8], _ start: Int, _ count: Int, _ littleEndian: Bool) -> Int64
  {
    var result: Int64 = 0
    if littleEndian {
      for i in stride(from: count - 1, through: 0, by: -1) {
        let idx = start + i
        let byte: Int64 = idx < buffer.count ? Int64(buffer[idx]) : 0
        result = (result << 8) | byte
      }
    } else {
      for i in 0..<count {
        let idx = start + i
        let byte: Int64 = idx < buffer.count ? Int64(buffer[idx]) : 0
        result = (result << 8) | byte
      }
    }
    return result
  }

  /// `getIntValue(byte[], int, int, boolean)`, direct form, truncated to 32 bits.
  static func readInt(_ buffer: [UInt8], _ start: Int, _ count: Int, _ littleEndian: Bool) -> Int64
  {
    Int64(Int32(truncatingIfNeeded: readLong(buffer, start, count, littleEndian)))
  }

  /// `returnCorrectValue(Long, boolean)`; narrow to the low 32 bits when the file is 32-bit,
  /// otherwise pass the 64-bit value through unchanged.
  public static func narrow(_ value: Int64, is32Bit: Bool) -> Int64 {
    is32Bit ? Int64(Int32(truncatingIfNeeded: value)) : value
  }
}
