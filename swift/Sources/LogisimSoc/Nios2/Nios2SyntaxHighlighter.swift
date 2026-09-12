// Nios2SyntaxHighlighter.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.soc.nios2.Nios2SyntaxHighlighter),
// GPL-3.0-only. See LICENSE.md. Reference tree: upstream-java-4.1.0 (D16).
//
// Upstream carries this class's own doc comment: `// FIXME: this class seems to be unused`.
// Ported anyway per the fidelity brief ("preserve upstream behaviour even where it looks
// wrong": docs/decisions.md rule 5), and it earns its keep here regardless: its
// `getWordsToHighlight()` is exactly the word-classification map `AssemblerLexer` needs to tell
// opcodes from registers from plain labels, so `Nios2Assembler`'s tokenizer wordMap
// (`Assembler.swift`'s caller) is built from this, not reinvented. See AssemblerLexer.swift's
// header for the one-word map upstream's `AbstractTokenMaker.addToken` override reduces to.
public enum Nios2SyntaxHighlighter {
  /// `getWordsToHighlight()`: `AssemblerHighlighter`'s directive map (→ `.asmInstruction`,
  /// `AssemblerDirectives.all`) plus every register spelling and `pc` (→ `.register`; the
  /// `pc`-vs-plain-register split happens downstream in `AssemblerRunner.buildTokens`, exactly
  /// where upstream's `checkAndBuildTokens` does it, off the raw lexeme rather than the map
  /// value) plus every opcode this assembler knows (→ `.instruction`).
  public static func wordMap() -> [String: Int] {
    var map: [String: Int] = [:]
    for directive in AssemblerDirectives.all {
      map[directive] = AssemblerToken.asmInstruction
    }
    for name in Nios2ProcessorState.registerABINames {
      map[name] = AssemblerToken.register
    }
    map["pc"] = AssemblerToken.register
    for i in 0..<32 {
      map["r\(i)"] = AssemblerToken.register
      map["c\(i)"] = AssemblerToken.register
      map["ctl\(i)"] = AssemblerToken.register
    }
    for opcode in Nios2Assembler().getOpcodes() {
      map[opcode.lowercased()] = AssemblerToken.instruction
    }
    return map
  }
}
