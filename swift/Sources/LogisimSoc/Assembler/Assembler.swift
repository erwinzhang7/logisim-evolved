// Assembler.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.soc.util.Assembler), GPL-3.0-only.
// See LICENSE.md. Reference tree: upstream-java-4.1.0 (D16).
//
// SEAM (D9): upstream's `Assembler` is a `RSyntaxTextArea` `AbstractParser`; it reads tokens
// back out of a live editor widget, paints error-gutter icons via `RTextScrollPane`/
// `GutterIconInfo`, pops `OptionPane` dialogs (`getEntryPoint`'s "assuming lowest address"
// warning), and listens for `LocaleManager` changes to re-render already-shown error text.
// None of that is a model concern. `AssemblerRunner` below is the same multi-pass pipeline,
// tokenize, resolve labels, fold math/strings/brackets, expand macros, hand off to
// `AssemblerInfo`, as a pure function from source text to `AssembleResult`, which is exactly
// what makes the assembler's output byte-comparable/gate-able per the port brief. Every
// `OptionPane`/`Gutter` call site below is replaced with structured `AssembleError`
// accumulation instead; the UI layer renders those as gutter icons itself.
//
// ── `gui/AssemblerPanel`: NOT PORTED, and this is the file that owes the record ─────────────
//
// A parity survey of `com/cburch/logisim/soc` found `AssemblerPanel` cited by line number in
// `SocBusInterfaces.swift:95` and declared excluded nowhere. It is the window this pipeline
// exists to serve: an `RSyntaxTextArea` editor plus Open/Save/Assemble/Run buttons, which on
// assemble calls `cpu.setEntryPointandReset(circuitState, entryPoint, null,
// assembler.getSectionHeader())` (`AssemblerPanel.java:259`). Every model step behind those
// buttons is present here and in `AssemblerInfo.download`; what is absent is the editor
// window, which is D9 by the same rule as the `AbstractParser` above.
//
// The user-visible cost is the largest single one in this module, and it is worth stating
// plainly rather than leaving implied: **there is no in-app way to write, assemble and load a
// program onto a SoC CPU.** The loading half is not lost, `ProcessorReadElf` is ported, so an
// ELF built by an external toolchain still reaches memory one bus transaction at a time, but
// authoring assembly inside the app is not reachable. This is a UI backlog item (an editor
// view over `AssemblerRunner`), not missing model content; nothing here needs porting first.

import LogisimKernel

public struct AssembleError: Equatable {
  public let offset: Int
  public let message: AssemblerMessage
}

public struct AssembleResult {
  /// Errors in first-seen order; matches upstream's "first error wins per offset" dedup
  /// (`Assembler.addError` never records two errors at the same document offset).
  public let errors: [AssembleError]
  public let sections: [AssemblerSectionRecord]
  /// `getEntryPoint()`'s success path: an explicit `_start` label, else the lowest instruction
  /// address across all sections (upstream's "assuming lowest address" fallback; the
  /// `OptionPane` warning it pops in that case is a UI concern, dropped here; callers can
  /// still tell the two cases apart via `usedFallbackEntryPoint`).
  public let entryPoint: Int64?
  public let usedFallbackEntryPoint: Bool

  public var isSuccess: Bool { errors.isEmpty }
}

public final class AssemblerRunner {
  private let assembler: AssemblerInterface
  private let wordMap: [String: Int]

  public init(assembler: AssemblerInterface, wordMap: [String: Int]) {
    self.assembler = assembler
    self.wordMap = wordMap
  }

  public func assemble(sourceLines: [String]) -> AssembleResult {
    var errors: [AssembleError] = []
    var knownOffsets = Set<Int>()
    func addError(_ offset: Int, _ message: AssemblerMessage) {
      guard !knownOffsets.contains(offset) else { return }
      knownOffsets.insert(offset)
      errors.append(AssembleError(offset: offset, message: message))
    }

    // First pass: build AssemblerTokens from the raw lexer stream (mirrors
    // `checkAndBuildTokens`'s two sub-passes: classify, then fold `label:` markers).
    var tokens = buildTokens(sourceLines: sourceLines, addError: addError)

    // Second pass: collect labels.
    var labels: [String: Int64] = [:]
    var labelTokenSeen: [String: AssemblerToken] = [:]
    for asm in tokens where asm.type == AssemblerToken.label {
      if labels[asm.value] != nil {
        addError(asm.offset, .assemblerDuplicatedLabelNotSupported)
        if let earlier = labelTokenSeen[asm.value] {
          addError(earlier.offset, .assemblerDuplicatedLabelNotSupported)
        }
      } else {
        labels[asm.value] = -1
        labelTokenSeen[asm.value] = asm
      }
    }

    // Third pass: MAYBE_LABEL -> PARAMETER_LABEL for anything that turned out to be a known
    // label.
    for asm in tokens where asm.type == AssemblerToken.maybeLabel {
      if labels[asm.value] != nil { asm.setType(AssemblerToken.parameterLabel) }
    }

    // Fourth pass: fold math (always left-to-right; see upstream's comment: `5+10*2` is
    // `(5+10)*2`, not operator-precedence-correct), merge adjacent multi-line strings, and fold
    // `( register )` / `[ register ]` into BRACKETED_REGISTER.
    tokens = foldMathStringsAndBrackets(tokens, addError: addError)

    // Fifth pass: CPU-specific token reclassification (Nios2Assembler turns "ctlN"/"cN"
    // REGISTER tokens into CONTROL_REGISTER/CUSTOM_REGISTER here).
    assembler.performUpSpecificOperationsOnTokens(tokens)

    // Sixth pass: detect and remove `.macro`/`.endm` blocks, recording each as an
    // `AssemblerMacro` and marking call sites as `.macro` tokens.
    let (afterMacros, macros, macroErrors) = extractMacros(tokens, labels: &labels, addError: addError)
    if macroErrors {
      return AssembleResult(errors: errors, sections: [], entryPoint: nil, usedFallbackEntryPoint: false)
    }
    tokens = afterMacros

    var markerErrors: [AssemblerToken: AssemblerMessage] = [:]
    for (_, macro) in macros {
      _ = macro.checkForMacros(&markerErrors, names: Set(macros.keys))
    }
    for (_, macro) in macros {
      _ = macro.replaceLabels(globalLabels: labels, errors: &markerErrors, assembler: assembler, macros: macros)
    }
    if !markerErrors.isEmpty {
      for (token, message) in markerErrors { addError(token.offset, message) }
      return AssembleResult(errors: errors, sections: [], entryPoint: nil, usedFallbackEntryPoint: false)
    }

    // The real work.
    let info = AssemblerInfo(assembler: assembler)
    info.assemble(tokens: tokens, labels: &labels, macros: macros)
    for (token, message) in info.getErrors() { addError(token.offset, message) }

    if !errors.isEmpty {
      return AssembleResult(errors: errors, sections: info.getSections(), entryPoint: nil, usedFallbackEntryPoint: false)
    }
    if let start = labels["_start"] {
      return AssembleResult(errors: errors, sections: info.getSections(), entryPoint: start, usedFallbackEntryPoint: false)
    }
    let fallback = info.entryPoint
    if fallback < 0 {
      addError(0, .assemblerNoExecutableSection)
      return AssembleResult(errors: errors, sections: info.getSections(), entryPoint: nil, usedFallbackEntryPoint: false)
    }
    return AssembleResult(errors: errors, sections: info.getSections(), entryPoint: fallback, usedFallbackEntryPoint: true)
  }

  // MARK: - Pass 1: tokenize

  private func buildTokens(
    sourceLines: [String], addError: (_ offset: Int, _ message: AssemblerMessage) -> Void
  ) -> [AssemblerToken] {
    let raw = AssemblerLexer.tokenize(
      lines: sourceLines, wordMap: wordMap, usesRoundedBrackets: assembler.usesRoundedBrackets,
      onError: addError)
    var lineTokens: [AssemblerToken] = []
    for r in raw {
      switch r.kind {
      case .literalChar(let c):
        switch c {
        case ",": lineTokens.append(AssemblerToken(type: AssemblerToken.seperator, value: nil, offset: r.offset))
        case "(", "[": lineTokens.append(AssemblerToken(type: AssemblerToken.bracketOpen, value: nil, offset: r.offset))
        case ")", "]": lineTokens.append(AssemblerToken(type: AssemblerToken.bracketClose, value: nil, offset: r.offset))
        case ":": lineTokens.append(AssemblerToken(type: AssemblerToken.labelIdentifier, value: nil, offset: r.offset))
        case "-": lineTokens.append(AssemblerToken(type: AssemblerToken.mathSubtract, value: nil, offset: r.offset))
        case "+": lineTokens.append(AssemblerToken(type: AssemblerToken.mathAdd, value: nil, offset: r.offset))
        case "*": lineTokens.append(AssemblerToken(type: AssemblerToken.mathMul, value: nil, offset: r.offset))
        case "%": lineTokens.append(AssemblerToken(type: AssemblerToken.mathRem, value: nil, offset: r.offset))
        case "/": lineTokens.append(AssemblerToken(type: AssemblerToken.mathDiv, value: nil, offset: r.offset))
        default: break
        }
      case .mathShiftLeft:
        lineTokens.append(AssemblerToken(type: AssemblerToken.mathShiftLeft, value: nil, offset: r.offset))
      case .mathShiftRight:
        lineTokens.append(AssemblerToken(type: AssemblerToken.mathShiftRight, value: nil, offset: r.offset))
      case .decNumber:
        lineTokens.append(AssemblerToken(type: AssemblerToken.decNumber, value: r.text, offset: r.offset))
      case .hexNumber:
        lineTokens.append(AssemblerToken(type: AssemblerToken.hexNumber, value: r.text, offset: r.offset))
      case .string:
        lineTokens.append(AssemblerToken(type: AssemblerToken.string, value: r.text, offset: r.offset))
      case .word(let mappedType):
        let type = (mappedType == AssemblerToken.register && r.text == "pc")
          ? AssemblerToken.programCounter : mappedType
        lineTokens.append(AssemblerToken(type: type, value: r.text, offset: r.offset))
      case .maybeLabel:
        lineTokens.append(AssemblerToken(type: AssemblerToken.maybeLabel, value: r.text, offset: r.offset))
      case .preprocessor:
        lineTokens.append(AssemblerToken(type: AssemblerToken.macroParameter, value: r.text, offset: r.offset))
      }
    }
    // Second sub-pass: `identifier :` -> LABEL (matches `checkAndBuildTokens`'s LABEL_IDENTIFIER
    // handling, run once over the whole token stream rather than per-line: offsets are
    // absolute, so cross-line behaviour is identical either way, and doing it once here avoids
    // re-deriving per-line boundaries from the flattened stream).
    var toRemove = Set<Int>()
    for i in 0..<lineTokens.count where lineTokens[i].type == AssemblerToken.labelIdentifier {
      if i == 0 {
        addError(lineTokens[i].offset, .assemblerMissingLabelBefore)
      } else {
        let before = lineTokens[i - 1]
        if before.type == AssemblerToken.maybeLabel {
          before.setType(AssemblerToken.label)
        } else {
          addError(before.offset, .assemblerExpectingLabelIdentifier)
        }
      }
      toRemove.insert(i)
    }
    if !toRemove.isEmpty {
      lineTokens = lineTokens.enumerated().filter { !toRemove.contains($0.offset) }.map(\.element)
    }
    return lineTokens
  }

  // MARK: - Pass 4: math folding / string merge / bracket fold

  private func foldMathStringsAndBrackets(
    _ tokens: [AssemblerToken], addError: (_ offset: Int, _ message: AssemblerMessage) -> Void
  ) -> [AssemblerToken] {
    var toBeRemoved = Set<ObjectIdentifier>()
    var i = 0
    while i < tokens.count {
      let asm = tokens[i]
      if AssemblerToken.mathOperators.contains(asm.type) {
        if i + 1 >= tokens.count {
          addError(asm.offset, .assemblerReguiresNumberAfterMath)
          i += 1
          continue
        }
        var before: AssemblerToken? = i == 0 ? nil : tokens[i - 1]
        let after = tokens[i + 1]
        if let b = before, !(b.isNumber || b.type == AssemblerToken.programCounter) { before = nil }
        if !(after.isNumber || after.type == AssemblerToken.programCounter) {
          addError(asm.offset, .assemblerReguiresNumberAfterMath)
          i += 1
          continue
        }
        let beforeValue = before?.getNumberValue() ?? 0
        if after.type == AssemblerToken.programCounter
          || before?.type == AssemblerToken.programCounter
        {
          i += 1
        } else {
          // Every operand here comes from `AssemblerToken.getNumberValue()`, which is Java
          // `int` (32-bit). Java evaluates `int op int` at 32 bits and wraps silently on
          // overflow: `wrap32` after each op reproduces that; using Swift's 64-bit `Int`
          // arithmetic (even the wrapping `&+`/`&-`/`&*` operators, which wrap at 64 bits) would
          // silently stop matching Java the moment an intermediate result exceeds 32 bits.
          switch asm.type {
          case AssemblerToken.mathAdd:
            after.setValue(wrap32(beforeValue &+ after.getNumberValue()))
          case AssemblerToken.mathShiftLeft:
            // Java masks the shift count to 5 bits for `int << int`.
            after.setValue(wrap32(beforeValue << (after.getNumberValue() & 31)))
          case AssemblerToken.mathShiftRight:
            // Java's `>>` on `int` is arithmetic (sign-extending); Swift's `>>` on signed `Int`
            // matches.
            after.setValue(wrap32(beforeValue >> (after.getNumberValue() & 31)))
          case AssemblerToken.mathSubtract:
            after.setValue(wrap32(beforeValue &- after.getNumberValue()))
          case AssemblerToken.mathMul:
            after.setValue(wrap32(beforeValue &* after.getNumberValue()))
          case AssemblerToken.mathDiv:
            if after.getNumberValue() == 0 {
              addError(after.offset, .assemblerDivZero)
              // Java's `case MATH_DIV -> { ...; i++; break; }` returns from the arrow-block
              // entirely on the zero-divisor path (manual i++ here, plus the for-loop's own
              // automatic i++ below), skipping the removal-marking that follows this switch.
              i += 2
              continue
            }
            // Java `int / int` truncates toward zero; Swift `Int / Int` matches (values are
            // already 32-bit-range, so no Int32.min / -1 overflow case can arise here; that
            // hazard is a *runtime* RV32/Nios2 DIV instruction concern, not this compile-time
            // constant-folding pass).
            after.setValue(wrap32(beforeValue / after.getNumberValue()))
          case AssemblerToken.mathRem:
            if after.getNumberValue() == 0 {
              addError(after.offset, .assemblerDivZero)
              i += 2
              continue
            }
            after.setValue(wrap32(beforeValue % after.getNumberValue()))
          default: break
          }
          if let b = before { toBeRemoved.insert(ObjectIdentifier(b)) }
          toBeRemoved.insert(ObjectIdentifier(asm))
          i += 1
        }
      } else if asm.type == AssemblerToken.string && i + 1 < tokens.count {
        var next = tokens[i + 1]
        while next.type == AssemblerToken.string {
          i += 1
          toBeRemoved.insert(ObjectIdentifier(next))
          asm.setValue(asm.value + next.value)
          guard i + 1 < tokens.count else { break }
          next = tokens[i + 1]
        }
      } else if asm.type == AssemblerToken.bracketOpen && i + 2 < tokens.count {
        let second = tokens[i + 1]
        let third = tokens[i + 2]
        if second.type == AssemblerToken.register && third.type == AssemblerToken.bracketClose {
          second.setType(AssemblerToken.bracketedRegister)
          toBeRemoved.insert(ObjectIdentifier(asm))
          toBeRemoved.insert(ObjectIdentifier(third))
          i += 2
        }
      }
      i += 1
    }
    return tokens.filter { !toBeRemoved.contains(ObjectIdentifier($0)) }
  }

  // MARK: - Pass 6: macro extraction

  private func extractMacros(
    _ tokens: [AssemblerToken], labels: inout [String: Int64],
    addError: (_ offset: Int, _ message: AssemblerMessage) -> Void
  ) -> (tokens: [AssemblerToken], macros: [String: AssemblerMacro], hadErrors: Bool) {
    var toBeRemoved = Set<ObjectIdentifier>()
    var macros: [String: AssemblerMacro] = [:]
    var hadErrors = false
    var i = 0
    while i < tokens.count {
      let asm = tokens[i]
      guard asm.type == AssemblerToken.asmInstruction, asm.value == ".macro" else {
        i += 1
        continue
      }
      toBeRemoved.insert(ObjectIdentifier(asm))
      guard i + 1 < tokens.count else {
        addError(asm.offset, .assemblerExpectedMacroName)
        break
      }
      let name = tokens[i + 1]
      toBeRemoved.insert(ObjectIdentifier(name))
      guard name.type == AssemblerToken.maybeLabel else {
        addError(asm.offset, .assemblerExpectedMacroName)
        break
      }
      guard i + 2 < tokens.count else {
        addError(asm.offset, .assemblerExpectedMacroNrOfParameters)
        break
      }
      let nrParameters = tokens[i + 2]
      toBeRemoved.insert(ObjectIdentifier(nrParameters))
      guard nrParameters.isNumber else {
        addError(asm.offset, .assemblerExpectedMacroNrOfParameters)
        break
      }
      let macro = AssemblerMacro(name: name.value, numberOfParameters: nrParameters.getNumberValue())
      var j = i + 3
      var endOfMacro = false
      while !endOfMacro, j < tokens.count {
        let macroAsm = tokens[j]
        if macroAsm.type == AssemblerToken.asmInstruction {
          if macroAsm.value == ".endm" {
            endOfMacro = true
          } else {
            addError(macroAsm.offset, .assemblerCannotUseInsideMacro)
            hadErrors = true
          }
        } else {
          macro.addToken(macroAsm)
          if macroAsm.type == AssemblerToken.label {
            labels.removeValue(forKey: macroAsm.value)
            macro.addLabel(macroAsm.value)
          }
        }
        toBeRemoved.insert(ObjectIdentifier(macroAsm))
        j += 1
      }
      if !endOfMacro {
        addError(asm.offset, .assemblerEndOfMacroNotFound)
        hadErrors = true
      } else {
        var markers: [AssemblerToken: AssemblerMessage] = [:]
        if macro.checkParameters(&markers) {
          macros[macro.name] = macro
        } else {
          for (token, message) in markers { addError(token.offset, message) }
          hadErrors = true
        }
      }
      i = j
    }
    if hadErrors { return (tokens, macros, true) }
    let remaining = tokens.filter { !toBeRemoved.contains(ObjectIdentifier($0)) }
    for asm in remaining where asm.type == AssemblerToken.maybeLabel {
      if macros[asm.value] != nil { asm.setType(AssemblerToken.macro) }
    }
    return (remaining, macros, false)
  }
}
