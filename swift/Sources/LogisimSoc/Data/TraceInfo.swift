// TraceInfo.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.soc.data.TraceInfo),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// One instruction-trace row for a CPU core's debug window: program counter, raw instruction
// word, disassembly text, and whether execution of this instruction raised an error. Owned here
// (not by Rv32im/Nios2) because it is pure data with no ISA-specific content: both cores record
// the same three fields. `paint(Graphics2D, ...)` is dropped per D6/D9; the UI renders a row
// directly from these four properties.
public struct TraceInfo {
  public let pc: Int32
  public let instruction: Int32
  public let asm: String
  public private(set) var error: Bool

  public init(pc: Int32, instruction: Int32, asm: String, error: Bool) {
    self.pc = pc
    self.instruction = instruction
    self.asm = asm
    self.error = error
  }

  /// `setError()`.
  public mutating func setError() { error = true }
}
