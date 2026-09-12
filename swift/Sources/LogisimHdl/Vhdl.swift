// Vhdl: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// `com/cburch/logisim/fpga/hdlgenerator/Vhdl.java`. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore licensed GPL-3.0-only.
// See LICENSE.md.

/// `com.cburch.logisim.fpga.hdlgenerator.Vhdl`: the VHDL reserved-word table and the
/// keyword-casing helper `LineBuffer`'s `{{keyword}}` placeholders resolve through.
public enum Vhdl {
  /// Verbatim transcription of `Vhdl.RESERVED_VHDL_WORDS`, lower-case, in source order.
  public static let vhdlKeywords: [String] = [
    "abs", "all", "access", "after", "alias", "all", "and", "architecture", "array", "assert",
    "attribute", "begin", "block", "body", "buffer", "bus", "case", "component", "configuration",
    "constant", "disconnect", "downto", "else", "elsif", "end", "entity", "exit", "file", "for",
    "function", "generate", "generic", "group", "guarded", "if", "integer", "impure", "in",
    "inertial", "inout", "is", "label", "library", "linkage", "literal", "loop", "map", "mod",
    "nand", "new", "next", "nor", "not", "null", "of", "on", "open", "or", "others", "out",
    "package", "port", "postponed", "procedure", "process", "pure", "range", "record",
    "register", "reject", "rem", "report", "return", "rol", "ror", "select", "severity",
    "signal", "shared", "sla", "sll", "sra", "srl", "subtype", "then", "to", "transport", "type",
    "unaffected", "units", "until", "use", "variable", "wait", "when", "while", "with", "xnor",
    "xor",
  ]

  /// `Vhdl.getVhdlKeywords()`: the deduplicated, sorted, case-adjusted set every
  /// `LineBuffer.addVhdlKeywords()` pairs up as `{{keyword}}` placeholders.
  public static func vhdlKeywordSet() -> Set<String> {
    var keywords = Set<String>()
    for keyword in vhdlKeywords {
      keywords.insert(HdlSettings.vhdlKeywordsUppercase ? keyword.uppercased() : keyword)
    }
    return keywords
  }

  /// `Vhdl.getVhdlKeyword(String)`.
  ///
  /// Java strips spaces and lower-cases before matching (so callers can pass `"END "` or
  /// `"NOT "` with padding intact for alignment) and then throws `IllegalArgumentException` on
  /// an unknown keyword. That is a generator-authoring bug, not something a `.circ` file can
  /// trigger, so the port traps rather than throws (D13's "genuine programmer error" branch).
  public static func vhdlKeyword(_ keyword: String) -> String {
    let stripped = keyword.replacingOccurrences(of: " ", with: "").lowercased()
    guard vhdlKeywords.contains(stripped) else {
      preconditionFailure("An unknown VHDL keyword was passed: '\(keyword)'")
    }
    return HdlSettings.vhdlKeywordsUppercase ? keyword.uppercased() : keyword.lowercased()
  }
}
