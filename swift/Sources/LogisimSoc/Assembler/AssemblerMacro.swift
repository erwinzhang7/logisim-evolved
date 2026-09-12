// AssemblerMacro.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.soc.util.AssemblerMacro), GPL-3.0-only.
// See LICENSE.md. Reference tree: upstream-java-4.1.0 (D16).
public final class AssemblerMacro {
  public let name: String
  public let numberOfParameters: Int
  private var tokens: [AssemblerToken] = []
  private var localLabels: [String: Int64] = [:]
  private var parameters: [[AssemblerToken]] = []
  private var sizeDeterminationActive = false
  private var macroSize: Int64 = -1

  public init(name: String, numberOfParameters: Int) {
    self.name = name
    self.numberOfParameters = numberOfParameters
  }

  public func addToken(_ token: AssemblerToken) { tokens.append(token) }
  public func addLabel(_ label: String) { localLabels[label] = -1 }
  public func clearParameters() { parameters.removeAll() }
  public func addParameter(_ param: [AssemblerToken]) { parameters.append(param) }
  public var hasCorrectNumberOfParameters: Bool { numberOfParameters == parameters.count }

  public func checkParameters(_ errors: inout [AssemblerToken: AssemblerMessage]) -> Bool {
    var hasErrors = false
    for token in tokens where token.type == AssemblerToken.macroParameter {
      let v = token.getNumberValue()
      if v < 1 || v > numberOfParameters {
        hasErrors = true
        errors[token] = .assemblerMacroParameterNotDefined
      }
    }
    return !hasErrors
  }

  /// `getMacroTokens()`: expands `%N` macro-parameter references against the call-site
  /// arguments and deep-copies every other token (Java allocates a fresh `AssemblerToken` here
  /// so later mutation; label/define/pc replacement; does not corrupt the macro's own
  /// template for the *next* call site).
  public func getMacroTokens() -> [AssemblerToken] {
    var result: [AssemblerToken] = []
    for token in tokens {
      if token.type == AssemblerToken.macroParameter {
        let index = token.getNumberValue() - 1
        if index >= 0, index < parameters.count {
          result.append(contentsOf: parameters[index])
        }
      } else {
        result.append(AssemblerToken(type: token.type, value: token.value, offset: token.offset))
      }
    }
    return result
  }

  public func checkForMacros(_ errors: inout [AssemblerToken: AssemblerMessage], names: Set<String>)
    -> Bool
  {
    var hasErrors = false
    for token in tokens where token.type == AssemblerToken.maybeLabel {
      if token.value == name {
        errors[token] = .assemblerMacroCannotUseRecurency
        hasErrors = true
      }
      if names.contains(token.value) { token.setType(AssemblerToken.macro) }
    }
    return hasErrors
  }

  public func getMacroSize(
    _ errors: inout [AssemblerToken: AssemblerMessage],
    assembler: AssemblerInterface,
    macros: [String: AssemblerMacro],
    hierarchy: inout [AssemblerToken]
  ) -> Int64 {
    if macroSize >= 0 { return macroSize }
    if sizeDeterminationActive {
      for asm in hierarchy { errors[asm] = .assemblerMacroCallingEachotherDeadlock }
      return -1
    }
    sizeDeterminationActive = true
    var pc: Int64 = 0
    var i = 0
    while i < tokens.count {
      let asm = tokens[i]
      if asm.type == AssemblerToken.instruction {
        pc += Int64(assembler.getInstructionSize(asm.value))
        i += 1
      } else if asm.type == AssemblerToken.macro {
        hierarchy.append(asm)
        guard let macro = macros[asm.value] else { i += 1; continue }
        let msize = macro.getMacroSize(&errors, assembler: assembler, macros: macros, hierarchy: &hierarchy)
        if msize < 0 {
          // Ported literally: Java does NOT reset `sizeDeterminationActive` on this path, so a
          // macro deadlock cycle leaves every macro in the cycle permanently "active": any
          // later, unrelated call to its `getMacroSize` will itself report a fresh deadlock.
          // This looks like a bug (see docs/decisions.md: preserve upstream behaviour even
          // where it looks wrong).
          return -1
        }
        pc += msize
        i += 1
      } else if asm.type == AssemblerToken.label, localLabels[asm.value] != nil {
        localLabels[asm.value] = pc
        tokens.remove(at: i)
        // Java's Iterator.remove() does not advance; the next element shifts into this index.
      } else {
        i += 1
      }
    }
    sizeDeterminationActive = false
    macroSize = pc
    return macroSize
  }

  public func replaceLabels(
    globalLabels: [String: Int64],
    errors: inout [AssemblerToken: AssemblerMessage],
    assembler: AssemblerInterface,
    macros: [String: AssemblerMacro]
  ) -> Bool {
    var hierarchy: [AssemblerToken] = []
    let msize = getMacroSize(&errors, assembler: assembler, macros: macros, hierarchy: &hierarchy)
    if msize < 0 { return false }
    var hasErrors = false
    var pc: Int64 = 0
    var nextpc: Int64 = 0
    hierarchy.removeAll()
    var i = 0
    while i < tokens.count {
      let asm = tokens[i]
      if asm.type == AssemblerToken.instruction {
        pc = nextpc
        nextpc += Int64(assembler.getInstructionSize(asm.value))
      } else if asm.type == AssemblerToken.macro {
        pc = nextpc
        if let macro = macros[asm.value] {
          nextpc += macro.getMacroSize(&errors, assembler: assembler, macros: macros, hierarchy: &hierarchy)
        }
      }
      if asm.type == AssemblerToken.parameterLabel {
        if globalLabels[asm.value] != nil {
          i += 1
          continue
        }
        if let target = localLabels[asm.value] {
          let offset0 = target - pc
          let negative = offset0 < 0
          let offset = negative ? -offset0 : offset0
          asm.setType(AssemblerToken.hexNumber)
          asm.setValue(String(format: "0x%X", offset))
          let operatorToken = AssemblerToken(
            type: negative ? AssemblerToken.mathSubtract : AssemblerToken.mathAdd, value: nil,
            offset: asm.offset)
          let pcToken = AssemblerToken(type: AssemblerToken.programCounter, value: "pc", offset: asm.offset)
          tokens.insert(operatorToken, at: i)
          tokens.insert(pcToken, at: i)
          // Java's for-loop increments by 1 here too (not skipping the two tokens just
          // inserted ahead of `asm`); harmless, since neither token's type matches any case
          // in this loop, so they no-op on their turn. Kept literal rather than "optimized".
        } else {
          hasErrors = true
          errors[asm] = .assemblerUnknownLabel
        }
      }
      i += 1
    }
    return !hasErrors
  }
}
