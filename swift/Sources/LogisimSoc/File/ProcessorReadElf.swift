// ProcessorReadElf.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.soc.file.ProcessorReadElf),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// The "load a compiled program into memory" entry point: parse the ELF, verify it matches the
// target CPU core (architecture id, `ET_EXEC`, endianness), then replay every `PT_LOAD` segment
// as a sequence of hidden **byte**-access write transactions through the CPU's
// `SocProcessorInterface`: genuinely one bus transaction per byte, exactly as upstream, so any
// address-decode error the memory map has (a `PT_LOAD` segment that does not land on a mapped
// slave) surfaces through the ordinary transaction-error path rather than a separate "can't load"
// mechanism.
//
// D13: every failure mode here (file unreadable, bad magic, wrong architecture, wrong ELF type,
// endianness mismatch, malformed program/section headers, a `PT_LOAD` segment too large to fit
// an `Int32` byte count, a write that lands outside every mapped slave) is a `status` code the
// caller inspects via `canExecute`/`errorMessage`, matching Java's own non-exception error model
// for this loader (see `ElfHeader.swift`'s file header); nothing here needed to become a
// `throw`.
//
// ── Seam: `Component`, not `Instance` (D3) ──────────────────────────────────────────────────────
//
// Java takes an `Instance` and downcasts `instance.getFactory()` to `SocInstanceFactory`. The
// port takes the plain `any Component` this module already threads everywhere else and performs
// the same downcast (`component.factory as? any SocInstanceFactory`), which is exactly D3's
// "`Instance` is a pure forwarder" collapse in action.

import Foundation
import LogisimFile
import LogisimKernel

public enum ProcessorReadElfStatus: Sendable, Equatable {
  case ok
  case fileOpenError
  case headerError
  case architectureError(found: Int32, expected: Int32)
  case notExecutable
  case endianMismatch(fileIsLittleEndian: Bool, expectedLittleEndian: Bool)
  case programHeaderInvalid
  case sectionHeaderInvalid
  case not32Bit
  case loadableSectionTooBig
  case memoryLoadError(start: Int64, end: Int64)
  case noProcessorInterface
}

/// `com.cburch.logisim.soc.file.ProcessorReadElf`.
public struct ProcessorReadElf {
  public private(set) var status: ProcessorReadElfStatus = .ok
  private let cpu: any SocProcessorInterface
  private let architecture: Int32
  private let elfHeader: ElfHeader
  private let programHeader: ElfProgramHeader
  private let sectionHeader: ElfSectionHeader
  private let fileData: Data

  public var canExecute: Bool { status == .ok }

  /// `ProcessorReadElf(File, Instance, int, boolean)`. Returns `nil` only when the file itself
  /// could not be read (mirrors Java's `FILE_OPEN_ERROR` early return); every other failure is
  /// reported through `status`/`canExecute` on the returned instance, exactly as upstream.
  public init?(
    fileURL: URL, component: any Component, architecture: Int32, littleEndian: Bool
  ) {
    guard let cpu = (component.factory as? any SocInstanceFactory)?.processorInterface(
      component.attributeSet)
    else {
      self.cpu = ProcessorReadElf.noopProcessor
      self.architecture = architecture
      self.elfHeader = ElfHeader(data: Data())
      self.programHeader = ElfProgramHeader()
      self.sectionHeader = ElfSectionHeader()
      self.fileData = Data()
      self.status = .noProcessorInterface
      return
    }
    self.cpu = cpu
    self.architecture = architecture
    guard let data = try? Data(contentsOf: fileURL) else {
      self.elfHeader = ElfHeader(data: Data())
      self.programHeader = ElfProgramHeader()
      self.sectionHeader = ElfSectionHeader()
      self.fileData = Data()
      self.status = .fileOpenError
      return
    }
    self.fileData = data
    let header = ElfHeader(data: data)
    self.elfHeader = header
    guard header.isValid else {
      self.programHeader = ElfProgramHeader()
      self.sectionHeader = ElfSectionHeader()
      self.status = .headerError
      return
    }
    guard let machine = header.value(.machine), Int32(truncatingIfNeeded: machine) == architecture
    else {
      self.programHeader = ElfProgramHeader()
      self.sectionHeader = ElfSectionHeader()
      self.status = .architectureError(
        found: Int32(truncatingIfNeeded: header.value(.machine) ?? 0), expected: architecture)
      return
    }
    guard let type = header.value(.type), Int32(truncatingIfNeeded: type) == ElfHeader.typeExec
    else {
      self.programHeader = ElfProgramHeader()
      self.sectionHeader = ElfSectionHeader()
      self.status = .notExecutable
      return
    }
    guard header.isLittleEndian == littleEndian else {
      self.programHeader = ElfProgramHeader()
      self.sectionHeader = ElfSectionHeader()
      self.status = .endianMismatch(
        fileIsLittleEndian: header.isLittleEndian, expectedLittleEndian: littleEndian)
      return
    }
    let ph = ElfProgramHeader(data: data, header: header)
    self.programHeader = ph
    guard ph.isValid else {
      self.sectionHeader = ElfSectionHeader()
      self.status = .programHeaderInvalid
      return
    }
    let sh = ElfSectionHeader(data: data, header: header)
    self.sectionHeader = sh
    guard sh.isValid else {
      self.status = .sectionHeaderInvalid
      return
    }
    guard header.is32Bit else {
      self.status = .not32Bit
      return
    }
  }

  /// `execute(CircuitState)`.
  public mutating func execute(circuitState: any SocCircuitStateToken) -> Bool {
    let bytes = [UInt8](fileData)
    for i in 0..<programHeader.count {
      guard let entry = programHeader.header(at: i), entry.type == ElfProgramEntry.typeLoad
      else { continue }
      guard entry.fileSize <= Int64(Int32.max), entry.memSize <= Int64(Int32.max) else {
        status = .loadableSectionTooBig
        return false
      }
      let fileOffset = Int(entry.offset)
      let sectionSize = Int(entry.fileSize)
      guard fileOffset >= 0, sectionSize >= 0, fileOffset + sectionSize <= bytes.count else {
        status = .loadableSectionTooBig
        return false
      }
      let segment = Array(bytes[fileOffset..<(fileOffset + sectionSize)])
      let startAddr = entry.physicalAddress
      let memSize = Int64(entry.memSize)
      var j: Int64 = 0
      while j < memSize {
        let data: Int32 = j < Int64(segment.count) ? Int32(segment[Int(j)]) : 0
        let addr = Int32(truncatingIfNeeded: ElfHeader.narrow(startAddr &+ j, is32Bit: true))
        let trans = SocBusTransaction(
          kind: .write, address: addr, writeData: data, accessType: .byte, initiator: "elf")
        cpu.insertTransaction(trans, hidden: true, circuitState: circuitState)
        if trans.hasError {
          status = .memoryLoadError(start: startAddr, end: startAddr &+ memSize &- 1)
          return false
        }
        j &+= 1
      }
    }
    let entryPoint = elfHeader.value(.entry) ?? 0
    cpu.setEntryPointAndReset(
      circuitState: circuitState, entryPoint: entryPoint, programHeader: programHeader,
      sectionHeader: sectionHeader)
    return true
  }

  public var errorMessage: String {
    switch status {
    case .ok: return "loaded successfully"
    case .fileOpenError: return "could not open the ELF file"
    case .headerError: return elfHeader.errorDescription
    case .architectureError(let found, let expected):
      return
        "wrong architecture: file is \(elfHeader.architectureName(found)), expected \(elfHeader.architectureName(expected))"
    case .notExecutable: return "the ELF file is not an executable"
    case .endianMismatch(let fileLE, let expectedLE):
      return
        "endianness mismatch: file is \(fileLE ? "little" : "big") endian, expected \(expectedLE ? "little" : "big") endian"
    case .programHeaderInvalid: return programHeader.errorDescription
    case .sectionHeaderInvalid: return sectionHeader.errorDescription
    case .not32Bit: return "64-bit ELF files are not supported yet"
    case .loadableSectionTooBig: return "a loadable section is too big to fit in memory"
    case .memoryLoadError(let start, let end):
      return String(format: "memory load error in range 0x%08X-0x%08X", start, end)
    case .noProcessorInterface: return "this component has no processor interface"
    }
  }

  /// A no-op stand-in used only when the caller passed a component with no processor interface
  /// (D13: degrade to a reported error, not a trap, on this genuinely-invalid-usage path).
  private static let noopProcessor: any SocProcessorInterface = NoopProcessorInterface()

  private final class NoopProcessorInterface: SocProcessorInterface {
    func setEntryPointAndReset(
      circuitState: (any SocCircuitStateToken)?, entryPoint: Int64,
      programHeader: ElfProgramHeader?, sectionHeader: ElfSectionHeader?
    ) {}
    func insertTransaction(
      _ transaction: SocBusTransaction, hidden: Bool, circuitState: (any SocCircuitStateToken)?
    ) { transaction.setError(.noResponse) }
    func entryPoint(_ circuitState: (any SocCircuitStateToken)?) -> Int32 { 0 }
  }
}
