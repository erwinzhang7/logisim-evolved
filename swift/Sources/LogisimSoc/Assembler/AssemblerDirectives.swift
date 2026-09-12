// AssemblerDirectives.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.soc.data.AssemblerHighlighter's directive
// word lists and `AbstractTokenMaker` word-to-token-type map), GPL-3.0-only. See LICENSE.md.
// Reference tree: upstream-java-4.1.0 (D16).
//
// `AssemblerHighlighter` itself is an `org.fife.ui.rsyntaxtextarea.AbstractTokenMaker` subclass
// wired into a live `RSyntaxTextArea` editor widget: pure UI (D9), and not something this
// module can depend on. What IS shared, CPU-agnostic behaviour is the directive vocabulary
// (`.byte`, `.word`, `.ascii`, …) and which of them take byte/short/int/long/string operands;
// `AssemblerInfo.handleAsmInstructions` switches on exactly these sets. They are reproduced
// here verbatim rather than waiting on whichever slice ports `soc/data`, since the assembler's
// own tokenizer (AssemblerLexer.swift) needs the full directive list to classify identifiers as
// `.asmInstruction` tokens in the first place.
public enum AssemblerDirectives {
  public static let all: [String] = [
    ".ascii", ".align", ".file", ".globl", ".local", ".comm", ".common", ".ident",
    ".section", ".size", ".text", ".data", ".rodata", ".bss", ".string", ".p2align",
    ".asciz", ".equ", ".macro", ".endm", ".type", ".option", ".byte", ".2byte", ".half",
    ".short", ".4byte", ".word", ".long", ".8byte", ".dword", ".quad", ".balign",
    ".zero", ".org",
  ]

  public static let bytes: Set<String> = [".byte"]
  public static let shorts: Set<String> = [".half", ".2byte", ".short"]
  public static let ints: Set<String> = [".word", ".4byte", ".long"]
  public static let longs: Set<String> = [".dword", ".8byte", ".quad"]
  public static let strings: Set<String> = [".ascii", ".asciz", ".string"]
}
