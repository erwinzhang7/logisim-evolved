// AssemblerInfo.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.soc.util.AssemblerInfo), GPL-3.0-only.
// See LICENSE.md. Reference tree: upstream-java-4.1.0 (D16).
//
// Java's `AssemblerInfo.AssemblerSectionInfo` extends `SectionHeader` (from
// `com.cburch.logisim.soc.file`, an ELF-reading type this module does not own: see
// Nios2Seams.swift) purely to reuse its bookkeeping fields (name, address flags) and its
// `SymbolTable` export list. `AssemblerSectionRecord` below is a from-scratch, purpose-built
// replacement carrying exactly the same *behaviour* (byte-addressable section contents keyed
// by absolute address, instruction placement, symbol export, overlap/size tracking) without
// inheriting the real ELF section-header type, so this file has no compile-time dependency on
// whichever slice eventually ports `com.cburch.logisim.soc.file`. Bridging
// `AssemblerSectionRecord` to the real `ElfSectionHeader`/`SectionHeader`/`SymbolTable` (for
// `getSectionHeader()`'s consumers: the "view assembly" panel, ELF export) is the seam the
// integrator closes once that slice lands.
public final class AssemblerSectionRecord {
  public let name: String
  public let identifier: AssemblerToken?
  public private(set) var sectionStart: Int64
  public private(set) var sectionEnd: Int64
  public private(set) var isExecutable = false
  /// `SectionHeader`'s writable/allocated distinction collapses to "not `.rodata`" here,
  /// matching the Java constructor `SectionHeader(String name)` this mirrors.
  public let isWritable: Bool
  private var data: [Int64: UInt8] = [:]
  private var instructions: [Int64: AssemblerAsmInstruction] = [:]
  /// (name, address) pairs, the `SymbolTable` export list.
  public private(set) var symbols: [(name: String, address: Int32)] = []

  public init() {
    name = "NoName"
    identifier = nil
    isWritable = true
    sectionStart = 0
    sectionEnd = 0
  }

  public init(name: String, identifier: AssemblerToken?, start: Int64 = 0) {
    self.name = name
    self.identifier = identifier
    self.isWritable = name != ".rodata"
    sectionStart = start
    sectionEnd = start
  }

  public var hasInstructions: Bool { !instructions.isEmpty }

  public var entryPoint: Int64 {
    instructions.keys.min() ?? -1
  }

  public func setOrgInfo(_ address: Int64) {
    if sectionStart == sectionEnd {
      sectionStart = address
      sectionEnd = address
      return
    }
    sectionEnd = address
  }

  public func addZeroBytes(_ nr: Int) { sectionEnd += Int64(nr) }

  /// `addString`; decodes the limited backslash-escape set the assembler's own string-literal
  /// merge pass produces (`\b \t \n \f \r`), matching Java's `switch` exactly (anything else
  /// after a backslash is emitted as that literal character, per the Java `default -> (byte) kar`).
  public func addString(_ str: String) {
    let chars = Array(str)
    var i = 0
    while i < chars.count {
      if chars[i] == "\\" {
        i += 1
        if i < chars.count {
          let kar = chars[i]
          let val: UInt8
          switch kar {
          case "b": val = 8
          case "t": val = 9
          case "n": val = 10
          case "f": val = 12
          case "r": val = 13
          default: val = UInt8(kar.asciiValue ?? 0)
          }
          data[sectionEnd] = val
          sectionEnd += 1
        }
      } else {
        // Java writes `str.getBytes()[i]`; the platform-default-charset byte at that Java
        // `char` index. Assembly string literals are effectively ASCII in practice; non-ASCII
        // input is a known, narrow divergence (UTF-8 byte(s) vs one Java-default-charset byte).
        for byte in String(chars[i]).utf8 {
          data[sectionEnd] = byte
          sectionEnd += 1
        }
        i += 1
      }
    }
  }

  public func addByte(_ b: UInt8) {
    if b != 0 { data[sectionEnd] = b }
    sectionEnd += 1
  }

  public func addInstruction(_ instr: AssemblerAsmInstruction, errors: inout [AssemblerToken: AssemblerMessage]) {
    instr.replacePcAndDoCalc(sectionEnd, &errors)
    instructions[sectionEnd] = instr
    sectionEnd += Int64(instr.sizeInBytes)
  }

  public func replaceLabels(_ labels: [String: Int64], _ errors: inout [AssemblerToken: AssemblerMessage]) -> Bool {
    var hasError = false
    for (_, instr) in instructions {
      hasError = !instr.replaceLabels(labels, &errors) || hasError
    }
    for (label, addr) in labels where addr >= sectionStart && addr < sectionEnd {
      symbols.append((name: label, address: SocSupport.convUnsignedLong(addr)))
    }
    return !hasError
  }

  public func replaceDefines(_ defines: [String: Int], _ errors: inout [AssemblerToken: AssemblerMessage]) -> Bool {
    var errorsFound = false
    for (_, instr) in instructions {
      errorsFound = !instr.replaceDefines(defines, &errors) || errorsFound
    }
    return !errorsFound
  }

  public func replaceInstructions(_ assembler: AssemblerInterface) -> [AssemblerToken: AssemblerMessage] {
    var errors: [AssemblerToken: AssemblerMessage] = [:]
    for (addr, asm) in instructions {
      asm.setProgramCounter(addr)
      if !assembler.assemble(asm) {
        for (k, v) in asm.getErrors() { errors[k] = v }
      } else if let bytes = asm.getBytes() {
        for i in 0..<asm.sizeInBytes where i < bytes.count {
          data[addr + Int64(i)] = bytes[i]
        }
      }
    }
    return errors
  }

  /// `download(SocProcessorInterface, CircuitState)`; writes every byte of this section to the
  /// bus, one `WRITE_TRANSACTION`/`BYTE_ACCESS` at a time (matching upstream's per-byte loop
  /// exactly, including that it keeps going and returns success up to the first failing byte,
  /// then stops).
  public func download(
    _ cpu: any SocProcessorInterface, circuitState: (any SocCircuitStateToken)?
  ) -> Bool {
    var i = sectionStart
    while i < sectionEnd {
      let byte = data[i] ?? 0
      let trans = SocBusTransaction(
        kind: .write, address: SocSupport.convUnsignedLong(i), writeData: Int32(byte),
        accessType: .byte, initiator: "Assembler")
      cpu.insertTransaction(trans, hidden: true, circuitState: circuitState)
      if hasInstructions { isExecutable = true }
      if trans.hasError { return false }
      i += 1
    }
    return true
  }
}

public final class AssemblerInfo {
  private var sections: [AssemblerSectionRecord] = []
  private var errors: [AssemblerToken: AssemblerMessage] = [:]
  private var currentSection = -1
  private let assembler: AssemblerInterface

  public init(assembler: AssemblerInterface) {
    self.assembler = assembler
  }

  public func getErrors() -> [AssemblerToken: AssemblerMessage] { errors }
  public func getSections() -> [AssemblerSectionRecord] { sections }

  public func assemble(
    tokens: [AssemblerToken], labels: inout [String: Int64], macros: [String: AssemblerMacro]
  ) {
    errors.removeAll()
    sections.removeAll()
    var defines: [String: Int] = [:]
    currentSection = -1
    var i = 0
    while i < tokens.count {
      let asm = tokens[i]
      switch asm.type {
      case AssemblerToken.asmInstruction:
        i += handleAsmInstructions(tokens, index: i, current: asm, defines: &defines)
      case AssemblerToken.label:
        handleLabels(&labels, asm)
      case AssemblerToken.instruction:
        i += handleInstruction(tokens, index: i, current: asm)
      case AssemblerToken.macro:
        i += handleMacros(tokens, index: i, current: asm, macros: macros)
      default:
        errors[asm] = .assemblerUnknownIdentifier
      }
      i += 1
    }
    if !errors.isEmpty { return }
    // Second pass: every label should have been resolved to a non-negative address by now
    // (Java treats a lingering -1 as an internal bug and shows a dialog; we simply stop, since
    // there is no UI here to show it in, see D9/D17).
    for value in labels.values where value < 0 { return }
    var errorsFound = false
    for section in sections { errorsFound = !section.replaceLabels(labels, &errors) || errorsFound }
    if errorsFound { return }
    errorsFound = false
    for section in sections { errorsFound = !section.replaceDefines(defines, &errors) || errorsFound }
    if errorsFound { return }
    // Third pass: overlap check.
    for i in 0..<sections.count {
      let section = sections[i]
      for j in (i + 1)..<sections.count {
        let check = sections[j]
        if (section.sectionStart > check.sectionStart && section.sectionStart < check.sectionEnd)
          || (section.sectionEnd > check.sectionStart && section.sectionEnd < check.sectionEnd)
        {
          errorsFound = true
          // Ported literally: Java's second branch also keys on `section.getIdentifier()`
          // (not `check.getIdentifier()`): almost certainly a copy-paste bug, preserved per
          // docs/decisions.md. The one place this file diverges: if `section.identifier` is
          // nil while `check.identifier` is not, Java's `HashMap.put(null, …)` records a
          // null-keyed error entry that a non-optional `[AssemblerToken: AssemblerMessage]`
          // cannot represent, so that entry is silently dropped here instead.
          if let id = section.identifier { errors[id] = .assemblerOverlappingSections }
          if check.identifier != nil, let id = section.identifier {
            errors[id] = .assemblerOverlappingSections
          }
        }
      }
    }
    if errorsFound { return }
    // Last pass: transform instructions to bytes.
    for section in sections {
      for (k, v) in section.replaceInstructions(assembler) { errors[k] = v }
    }
  }

  public func download(
    _ cpu: any SocProcessorInterface, circuitState: (any SocCircuitStateToken)?
  ) -> Bool {
    for section in sections where !section.download(cpu, circuitState: circuitState) {
      return false
    }
    return true
  }

  public var entryPoint: Int64 {
    var entry: Int64 = -1
    for section in sections where section.hasInstructions {
      let sentry = section.entryPoint
      if entry < 0 || sentry < entry { entry = sentry }
    }
    return entry
  }

  private func handleMacros(
    _ tokens: [AssemblerToken], index: Int, current: AssemblerToken,
    macros: [String: AssemblerMacro]
  ) -> Int {
    guard let macro = macros[current.value] else { return 0 }
    macro.clearParameters()
    let accepted = assembler.acceptedParameterTypes
    var skip = 0
    if index + 1 < tokens.count {
      var params: [AssemblerToken] = []
      var next: AssemblerToken
      repeat {
        next = tokens[index + skip + 1]
        if accepted.contains(next.type) {
          skip += 1
          if next.type == AssemblerToken.seperator {
            if params.isEmpty {
              errors[next] = .assemblerExpectedParameter
              return tokens.count
            }
            macro.addParameter(params)
            params = []
          } else {
            params.append(next)
          }
        }
      } while index + skip + 1 < tokens.count && accepted.contains(next.type)
      if !params.isEmpty { macro.addParameter(params) }
    }
    if !macro.hasCorrectNumberOfParameters {
      errors[current] = .assemblerMacroIncorrectNumberOfParameters
      return tokens.count
    }
    let macroTokens = macro.getMacroTokens()
    var i = 0
    while i < macroTokens.count {
      let asm = macroTokens[i]
      switch asm.type {
      case AssemblerToken.instruction:
        i += handleInstruction(macroTokens, index: i, current: asm)
      case AssemblerToken.macro:
        i += handleMacros(macroTokens, index: i, current: asm, macros: macros)
      default:
        errors[asm] = .assemblerUnknownIdentifier
      }
      i += 1
    }
    return skip
  }

  private func handleInstruction(_ tokens: [AssemblerToken], index: Int, current: AssemblerToken) -> Int {
    let instruction = AssemblerAsmInstruction(
      instruction: current, size: assembler.getInstructionSize(current.value))
    let accepted = assembler.acceptedParameterTypes
    var skip = 0
    if index + 1 < tokens.count {
      var params: [AssemblerToken] = []
      var next: AssemblerToken
      repeat {
        next = tokens[index + skip + 1]
        if accepted.contains(next.type) {
          skip += 1
          if next.type == AssemblerToken.seperator {
            if params.isEmpty {
              errors[next] = .assemblerExpectedParameter
              return tokens.count
            }
            instruction.addParameter(params)
            params = []
          } else {
            params.append(next)
          }
        }
      } while index + skip + 1 < tokens.count && accepted.contains(next.type)
      if !params.isEmpty { instruction.addParameter(params) }
    }
    checkIfActiveSection()
    sections[currentSection].addInstruction(instruction, errors: &errors)
    return skip
  }

  private func handleLabels(_ labels: inout [String: Int64], _ current: AssemblerToken) {
    guard let existing = labels[current.value] else {
      errors[current] = .assemblerUnknownLabel
      return
    }
    if existing >= 0 {
      errors[current] = .assemblerDuplicatedLabelNotSupported
      return
    }
    checkIfActiveSection()
    labels[current.value] = sections[currentSection].sectionEnd
  }

  private func handleAsmInstructions(
    _ tokens: [AssemblerToken], index: Int, current: AssemblerToken, defines: inout [String: Int]
  ) -> Int {
    let value = current.value
    if value == ".section" {
      guard index + 1 < tokens.count else {
        errors[current] = .assemblerExpectingSectionName
        return 0
      }
      let next = tokens[index + 1]
      guard next.type == AssemblerToken.maybeLabel || next.type == AssemblerToken.labelIdentifier
        || next.type == AssemblerToken.asmInstruction
      else {
        errors[current] = .assemblerExpectingSectionName
        return 0
      }
      guard addSection(next.value, identifier: next) else {
        errors[next] = .assemblerDuplicatedSectionError
        return tokens.count
      }
      return 1
    }
    if value == ".text" || value == ".data" || value == ".rodata" || value == ".bss" {
      guard addSection(value, identifier: current) else {
        errors[current] = .assemblerDuplicatedSectionError
        return tokens.count
      }
      return 0
    }
    if value == ".org" {
      guard index + 1 < tokens.count else {
        errors[current] = .assemblerExpectingNumber
        return 0
      }
      let next = tokens[index + 1]
      guard next.isNumber else {
        errors[current] = .assemblerExpectingNumber
        return 0
      }
      let addr = SocSupport.convUnsignedInt(next.getNumberValue())
      checkIfActiveSection()
      sections[currentSection].setOrgInfo(addr)
      return 1
    }
    if value == ".zero" {
      guard index + 1 < tokens.count else {
        errors[current] = .assemblerExpectingNumber
        return 0
      }
      let next = tokens[index + 1]
      guard next.isNumber else {
        errors[current] = .assemblerExpectingNumber
        return 0
      }
      let n = next.getNumberValue()
      if n < 0 {
        errors[next] = .assemblerExpectingPositiveNumber
        return 1
      }
      if n > 0 {
        checkIfActiveSection()
        sections[currentSection].addZeroBytes(n)
      }
      return 1
    }
    if AssemblerDirectives.strings.contains(value) {
      guard index + 1 < tokens.count else {
        errors[current] = .assemblerExpectingString
        return 0
      }
      let next = tokens[index + 1]
      guard next.type == AssemblerToken.string else {
        errors[current] = .assemblerExpectingString
        return 0
      }
      checkIfActiveSection()
      sections[currentSection].addString(next.value)
      if value != ".ascii" { sections[currentSection].addByte(0) }
      return 1
    }
    if AssemblerDirectives.bytes.contains(value) || AssemblerDirectives.shorts.contains(value)
      || AssemblerDirectives.ints.contains(value) || AssemblerDirectives.longs.contains(value)
    {
      guard index + 1 < tokens.count else {
        errors[current] = .assemblerExpectingNumber
        return 0
      }
      let maxRange =
        AssemblerDirectives.bytes.contains(value) ? 8
        : AssemblerDirectives.shorts.contains(value) ? 16
        : AssemblerDirectives.ints.contains(value) ? 32 : -1
      var skip = 0
      var next: AssemblerToken
      repeat {
        skip += 1
        next = tokens[index + skip]
        guard next.isNumber else {
          errors[next] = .assemblerExpectingNumber
          return skip
        }
        let value64 = next.getLongValue()
        if maxRange > 0 && value64 >= (Int64(1) << maxRange) {
          errors[next] = .assemblerValueOutOfRange
          return skip
        }
        checkIfActiveSection()
        let nrOfBytes = maxRange < 0 ? 8 : maxRange >> 3
        var v = value64
        for _ in 0..<nrOfBytes {
          sections[currentSection].addByte(UInt8(truncatingIfNeeded: v))
          v >>= 8
        }
        if index + skip + 1 < tokens.count {
          let peek = tokens[index + skip + 1]
          if peek.type == AssemblerToken.seperator { skip += 1 }
        }
      } while index + skip < tokens.count && next.type == AssemblerToken.seperator
      return skip
    }
    if value == ".equ" {
      // Java's literal bound check here is `index + 1 > tokens.size()`, which is off by one
      // (it lets `index + 1 == tokens.size()` through to an out-of-bounds `tokens.get`). D13:
      // a malformed-input crash becomes a reported error instead, not a trap.
      guard index + 1 < tokens.count else {
        errors[current] = .assemblerExpectedLabel
        return 0
      }
      let labelToken = tokens[index + 1]
      let type = labelToken.type
      guard type == AssemblerToken.maybeLabel || type == AssemblerToken.parameterLabel else {
        errors[labelToken] = .assemblerExpectedLabel
        return 1
      }
      guard index + 2 < tokens.count else {
        errors[current] = .assemblerExpectedLabelAndNumber
        return 1
      }
      guard tokens[index + 2].isNumber else {
        errors[tokens[index + 2]] = .assemblerExpectedImmediateValue
        return 2
      }
      let label = labelToken.value
      let numberValue = tokens[index + 2].getNumberValue()
      if type == AssemblerToken.parameterLabel {
        errors[labelToken] = .assemblerDuplicatedName
        return 2
      }
      defines[label] = numberValue
      return 2
    }
    errors[current] = .assemblerUnsupportedAssemblerInstruction
    return 0
  }

  private func checkIfActiveSection() {
    if currentSection < 0 {
      sections.append(AssemblerSectionRecord())
      currentSection = 0
    }
  }

  private func addSection(_ name: String, identifier: AssemblerToken) -> Bool {
    for section in sections where section.name == name { return false }
    if currentSection < 0 {
      sections.append(AssemblerSectionRecord(name: name, identifier: identifier))
      currentSection = 0
    } else {
      let start = sections[currentSection].sectionEnd
      sections.append(AssemblerSectionRecord(name: name, identifier: identifier, start: start))
      currentSection = sections.count - 1
    }
    return true
  }
}
