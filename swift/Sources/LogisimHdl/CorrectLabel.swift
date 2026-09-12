// CorrectLabel: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// `com/cburch/logisim/fpga/designrulecheck/CorrectLabel.java`. Copyright by the
// Logisim-evolution developers. This translation is a derivative work and is therefore
// licensed GPL-3.0-only. See LICENSE.md.
//
// This is a small, self-contained string-validation utility that `AbstractHdlGeneratorFactory`
// needs for instance-identifier sanitisation; it happens to live in the (out-of-scope)
// `designrulecheck` package upstream, but has no dependency on `Netlist`/`Component` at all.
//
// Dropped relative to Java: localised error text (`S.get(...)`), matching the kernel's
// established D9 practice, error text here is plain English, and `isKeyword`'s
// `OptionPane.showMessageDialog` side effect, which is a UI action out of scope for this
// module; callers that want a dialog can do so themselves from the boolean this returns.
public enum CorrectLabel {
  /// `CorrectLabel.getCorrectLabel(String)`.
  public static func correctLabel(_ label: String) -> String {
    guard !label.isEmpty else { return label }
    var result = ""
    if let first = label.first, first.isNumber { result += "L_" }
    result += label.replacingOccurrences(of: " ", with: "_").replacingOccurrences(
      of: "-", with: "_")
    return result
  }

  /// `CorrectLabel.isCorrectLabel(String, String)`. Reports the failure through `Reporter` and
  /// returns whether the label was accepted, exactly as upstream does.
  public static func isCorrectLabel(_ label: String, _ errorIdentifierString: String) -> Bool {
    if let error = nameErrors(label, errorIdentifierString) {
      Reporter.shared.addFatalError(error)
      return false
    }
    return true
  }

  /// `CorrectLabel.vhdlNameErrors(String)`.
  public static func vhdlNameErrors(_ label: String) -> String? {
    nameErrors(label, "VHDL entity name")
  }

  /// `CorrectLabel.nameErrors(String, String)`.
  public static func nameErrors(_ label: String, _ errorIdentifierString: String) -> String? {
    guard !label.isEmpty else { return nil }
    for character in label {
      let lower = Character(character.lowercased())
      if !allowedCharacters.contains(lower) && !numbers.contains(character) {
        return "\(errorIdentifierString): illegal character '\(character)'"
      }
    }
    if Hdl.isVhdl() {
      if Vhdl.vhdlKeywords.contains(label.lowercased()) {
        return "\(errorIdentifierString): reserved VHDL keyword"
      }
    } else if Hdl.isVerilog() {
      if verilogKeywords.contains(label) {
        return "\(errorIdentifierString): reserved Verilog keyword"
      }
    }
    return nil
  }

  /// `CorrectLabel.hdlCorrectLabel(String)`.
  public static func hdlCorrectLabel(_ label: String) -> HdlLanguage? {
    guard !label.isEmpty else { return nil }
    if Vhdl.vhdlKeywords.contains(label.lowercased()) { return .vhdl }
    if verilogKeywords.contains(label) { return .verilog }
    return nil
  }

  /// `CorrectLabel.firstInvalidCharacter(String)`.
  public static func firstInvalidCharacter(_ label: String) -> String {
    guard !label.isEmpty else { return "" }
    for character in label {
      let lower = Character(character.lowercased())
      if !allowedCharacters.contains(lower) && !numbers.contains(character) {
        return String(lower)
      }
    }
    return ""
  }

  /// `CorrectLabel.isCorrectLabel(String)`.
  public static func isCorrectLabel(_ label: String) -> Bool {
    guard !label.isEmpty else { return true }
    for character in label {
      let lower = Character(character.lowercased())
      if !allowedCharacters.contains(lower) && !numbers.contains(character) {
        return false
      }
    }
    if Hdl.isVhdl() {
      return !Vhdl.vhdlKeywords.contains(label.lowercased())
    } else if Hdl.isVerilog() {
      return !verilogKeywords.contains(label)
    }
    return true
  }

  /// `CorrectLabel.isKeyword(String, Boolean)`, minus the dialog side effect (UI, out of
  /// scope). Callers that want the upstream popup can present one themselves using the boolean
  /// this returns.
  public static func isKeyword(_ label: String) -> Bool {
    Vhdl.vhdlKeywords.contains(label.lowercased()) || verilogKeywords.contains(label.lowercased())
  }

  private static let numbers: Set<Character> = Set("0123456789")
  private static let allowedCharacters: Set<Character> = Set(
    "abcdefghijklmnopqrstuvwxyz -_")

  /// Verbatim transcription of `CorrectLabel.RESERVED_VERILOG_WORDS`.
  private static let verilogKeywords: Set<String> = [
    "always", "ifnone", "rpmos", "and", "initial", "rtran", "assign", "inout", "rtranif0",
    "begin", "input", "rtranif1", "buf", "integer", "scalared", "bufif0", "join", "small",
    "bufif1", "large", "specify", "case", "macromodule", "specparam", "casex", "medium",
    "strong0", "casez", "module", "strong1", "cmos", "nand", "supply0", "deassign", "negedge",
    "supply1", "default", "nmos", "table", "defparam", "nor", "task", "disable", "not", "time",
    "edge", "notif0", "tran", "else", "notif1", "tranif0", "end", "or", "tranif1", "endcase",
    "output", "tri", "endmodule", "parameter", "tri0", "endfunction", "pmos", "tri1",
    "endprimitive", "posedge", "triand", "endspecify", "primitive", "trior", "endtable", "pull0",
    "trireg", "endtask", "pull1", "vectored", "event", "pullup", "wait", "for", "pulldown",
    "wand", "force", "rcmos", "weak0", "forever", "real", "weak1", "fork", "realtime", "while",
    "function", "reg", "wire", "highz0", "release", "wor", "highz1", "repeat", "xnor", "if",
    "rnmos", "xor", "automatic", "incdir", "pulsestyle_ondetect", "cell", "include",
    "pulsestyle_onevent", "config", "instance", "signed", "endconfig", "liblist",
    "showcancelled", "endgenerate", "library", "unsigned", "generate", "localparam", "use",
    "genvar", "noshowcancelled",
  ]
}
