// Rv32imSyntaxHighlighter.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.soc.rv32im.RV32imSyntaxHighlighter),
// GPL-3.0-only. See LICENSE.md. Reference tree: upstream-java-4.1.0 (D16).
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// NOT MERELY SYNTAX COLOURING; THIS IS THE LEXER'S VOCABULARY
//
// The name says "highlighter" and `Rv32imProcessorState.swift`'s header listed it under
// "editor/IDE concern … not ported". That is what it is *called*; what it *does* is answer, for
// every bare word, whether it is a directive, a register, or an opcode. `AssemblerLexer`
// classifies an unmapped word as `.maybeLabel`, so without this map the RISC-V assembler reads
// `addi x1,x0,5` as four unknown identifiers and reports "I do not know this identifier" four
// times: measured, on the first run of the oracle diff, before this file existed.
//
// `Nios2SyntaxHighlighter.swift` already made exactly this observation for the Nios II family
// and its own header says so. RV32IM having no counterpart was the gap that made the whole
// ported assembler pipeline unusable for RISC-V.
//
// Upstream's map values are RSyntaxTextArea `Token` constants, which
// `Assembler.checkAndBuildTokens` then translates (`Token.OPERATOR` → `REGISTER` unless the
// lexeme is literally `"pc"`, in which case `PROGRAM_COUNTER`; `Token.RESERVED_WORD` →
// `INSTRUCTION`; `Token.FUNCTION` → `ASM_INSTRUCTION`). The port stores the *translated* value
// and keeps the `pc` special case downstream in `AssemblerRunner.buildTokens`, exactly where
// upstream does it: off the raw lexeme, not off the map.

public enum Rv32imSyntaxHighlighter {

  /// `getWordsToHighlight()`, including `super`'s directive entries from `AssemblerHighlighter`.
  ///
  /// Four groups, in upstream's order, and the order matters where they overlap: the opcode
  /// pass runs last, so a mnemonic that is also a CSR name would end up an `INSTRUCTION`. (None
  /// currently is; the ordering is preserved rather than relied upon.)
  public static func wordMap() -> [String: Int] {
    var map: [String: Int] = [:]
    for directive in AssemblerDirectives.all {
      map[directive] = AssemblerToken.asmInstruction
    }
    // `RV32imState.registerABINames`, zero, ra, sp, …
    for name in Rv32imRegisterNames.abi {
      map[name] = AssemblerToken.register
    }
    // `RV32imState.implementedSprNames`, lower-cased; this is what lets `csrrw x1,mstatus,x2`
    // parse, since the Zicsr unit resolves a REGISTER-typed CSR operand by name.
    for name in Rv32imCsr.implementedNames {
      map[name.lowercased()] = AssemblerToken.register
    }
    map["pc"] = AssemblerToken.register
    for index in 0..<32 {
      map["x\(index)"] = AssemblerToken.register
    }
    for opcode in Rv32imAssembler().getOpcodes() {
      map[opcode.lowercased()] = AssemblerToken.instruction
    }
    return map
  }
}
