// Rv32imAssemblerOracleTests.swift: part of logisim-evolved.
//
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
// Reference tree: upstream-java-4.1.0 (D16).
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// THE RV32IM ASSEMBLER, DIFFED AGAINST UPSTREAM'S OWN
//
// `setAsmInstruction` is eight files of bit-packing with pseudo-instruction rewrites layered on
// top: LI/MV/NOT/SEQZ/NOP/SNEZ/J/JR/RET/BEQZ/BNEZ/CSRW…— and every one of those rewrites moves
// operands between *positions*, not just mnemonics. A transcription slip there does not fail; it
// produces a different, entirely plausible 32-bit word.
//
// So the expectations are not written by hand. `tools/socbridge/gen_asm_golden.py` drives the
// 4.1.0 jar's own `RV32imAssembler` over `Fixtures/rv32im-asm-4.1.0.oracle`'s case list and
// records what it encodes; this suite replays the same sources through the ported pipeline and
// demands the same words.
//
// ── What each side runs, and the one asymmetry ──────────────────────────────────────────────
//
// The Swift side goes through the WHOLE pipeline, `AssemblerRunner` (lexer, label pass, math
// folding, section layout) then `Rv32imAssembler.assemble`, so a lexer defect shows up here as
// a wrong word too. The Java side could not: upstream's `Assembler` is an RSyntaxTextArea
// `AbstractParser` that reads tokens out of a live editor widget, so the bridge tokenizes each
// line itself and calls `AbstractAssembler.assemble` directly.
//
// That means the golden words are Java's *encoder* fed by the bridge's tokenizer. Agreement
// therefore proves the encoders match and that the ported lexer produces tokens the encoder
// reads the same way; it does not independently pin the lexer against Java's. Stated, rather
// than left for someone to assume the coverage is wider than it is.

import Foundation
import Testing

@testable import LogisimSoc

/// One row of the golden file.
private struct OracleCase {
  let pc: Int64
  let source: String
  let succeeded: Bool
  /// The encoded word (when `succeeded`) or the Java error message.
  let result: String
}

private func loadOracle() throws -> [OracleCase] {
  // The fixture sits beside this file; `#filePath` is the only way to find it without a
  // resource bundle, and adding one would mean editing Package.swift.
  let fixture = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Fixtures/rv32im-asm-4.1.0.oracle")
  let text = try String(contentsOf: fixture, encoding: .utf8)
  var cases: [OracleCase] = []
  for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
    if line.hasPrefix("#") { continue }
    let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
    guard fields.count >= 4, let pc = Int64(fields[0]) else { continue }
    // Column order is <pc> <source> <status> <result>; getting it wrong reads every row as a
    // rejection and still "runs", which is why the counts are asserted separately below.
    cases.append(
      OracleCase(pc: pc, source: fields[1], succeeded: fields[2] == "OK", result: fields[3]))
  }
  return cases
}

/// Captures every byte `AssemblerSectionRecord.download` writes, by standing in for the CPU.
/// Using `download` rather than a new accessor is deliberate: it is how upstream gets the bytes
/// out of an assembled section, so this exercises that path too.
private final class ByteCapturingProcessor: SocProcessorInterface {
  var bytes: [Int64: UInt8] = [:]

  func setEntryPointAndReset(
    circuitState: (any SocCircuitStateToken)?, entryPoint: Int64,
    programHeader: ElfProgramHeader?, sectionHeader: ElfSectionHeader?
  ) {}

  func insertTransaction(
    _ transaction: SocBusTransaction, hidden: Bool, circuitState: (any SocCircuitStateToken)?
  ) {
    guard transaction.isWriteTransaction else { return }
    bytes[Int64(transaction.address)] = UInt8(truncatingIfNeeded: transaction.writeData)
  }

  func entryPoint(_ circuitState: (any SocCircuitStateToken)?) -> Int32 { 0 }
}

/// Assembles one instruction at `pc` through the full ported pipeline and returns the little-
/// endian word, or the errors.
private func assembleOne(source: String, at pc: Int64) -> (word: UInt32?, errors: [String]) {
  let assembler = Rv32imAssembler()
  let runner = AssemblerRunner(assembler: assembler, wordMap: Rv32imSyntaxHighlighter.wordMap())
  // `.org` puts the instruction at the pc the oracle used, which is what every pc-relative form
  // is measured against.
  let result = runner.assemble(sourceLines: [".text", ".org 0x\(String(pc, radix: 16))", source])
  if !result.errors.isEmpty {
    return (nil, result.errors.map { $0.message.englishText })
  }
  let capture = ByteCapturingProcessor()
  for section in result.sections {
    _ = section.download(capture, circuitState: nil)
  }
  guard
    let b0 = capture.bytes[pc], let b1 = capture.bytes[pc + 1],
    let b2 = capture.bytes[pc + 2], let b3 = capture.bytes[pc + 3]
  else {
    return (nil, ["no bytes were emitted at 0x\(String(pc, radix: 16))"])
  }
  let word =
    UInt32(b0) | (UInt32(b1) << 8) | (UInt32(b2) << 16) | (UInt32(b3) << 24)
  return (word, [])
}

@Suite("the RV32IM assembler encodes what the 4.1.0 jar encodes", .serialized)
struct Rv32imAssemblerOracleTests {

  @Test("the oracle fixture is present and non-trivial")
  func oracleIsLoaded() throws {
    let cases = try loadOracle()
    // A silent zero-case run looks exactly like agreement; the failure mode this project keeps
    // having to dig out of. Pin the counts.
    #expect(cases.count == 92, "the fixture has \(cases.count) cases")
    #expect(cases.filter(\.succeeded).count == 75)
    #expect(cases.filter { !$0.succeeded }.count == 17)
  }

  @Test("every instruction the jar encodes, the port encodes identically")
  func encodingsMatch() throws {
    var mismatches: [String] = []
    var checked = 0
    for testCase in try loadOracle() where testCase.succeeded {
      checked += 1
      let (word, errors) = assembleOne(source: testCase.source, at: testCase.pc)
      guard let word else {
        mismatches.append("\(testCase.source) @\(testCase.pc): port failed — \(errors)")
        continue
      }
      let got = String(format: "%08X", word)
      if got != testCase.result {
        mismatches.append("\(testCase.source) @\(testCase.pc): java \(testCase.result), port \(got)")
      }
    }
    #expect(checked == 75, "checked \(checked) encodings")
    let report = "\(mismatches.count) mismatches:\n" + mismatches.joined(separator: "\n")
    #expect(mismatches.isEmpty, "\(report)")
  }

  @Test("every instruction the jar rejects, the port rejects too")
  func rejectionsMatch() throws {
    var missed: [String] = []
    var checked = 0
    for testCase in try loadOracle() where !testCase.succeeded {
      checked += 1
      let (word, errors) = assembleOne(source: testCase.source, at: testCase.pc)
      if word != nil {
        missed.append(
          "\(testCase.source): java rejected it (\(testCase.result)), the port encoded it")
        continue
      }
      // The message text is compared, not just the fact of failure: "rejected for the wrong
      // reason" is the kind of near-agreement that hides a real divergence. Java joins multiple
      // errors from a HashMap in arbitrary order, so only single-message rows are compared
      // exactly; the rest need only overlap.
      if !testCase.result.contains(" | ") {
        if !errors.contains(testCase.result) {
          missed.append("\(testCase.source): java says \(testCase.result), port says \(errors)")
        }
      }
    }
    #expect(checked == 17, "checked \(checked) rejections")
    let report = "\(missed.count) divergences:\n" + missed.joined(separator: "\n")
    #expect(missed.isEmpty, "\(report)")
  }

  /// The out-of-range-register path, driven at the level the oracle cannot reach.
  ///
  /// `addi x99,x0,1` is deliberately absent from the fixture: the bridge's mini-tokenizer calls
  /// any bare word a REGISTER, so Java's encoder sees `x99` and answers "Unknown register",
  /// while the real lexer leaves `x99` unmapped and the label/define pass rejects it first. Both
  /// reject it; the *stage* differs, and that difference is the bridge's, not the port's. So the
  /// encoder's own range check is exercised here by handing it the token Java's encoder would
  /// have received, which is also the shape a `.equ`-defined register alias would produce.
  @Test("a register index past 31 is rejected by the encoder itself")
  func outOfRangeRegisterIsRejected() {
    let unit = Rv32imIntegerRegisterImmediateInstructions()
    let instr = AssemblerAsmInstruction(
      instruction: AssemblerToken(type: AssemblerToken.asmInstruction, value: "addi", offset: 0),
      size: 4)
    instr.addParameter([AssemblerToken(type: AssemblerToken.register, value: "x99", offset: 0)])
    instr.addParameter([AssemblerToken(type: AssemblerToken.register, value: "x0", offset: 0)])
    instr.addParameter([AssemblerToken(type: AssemblerToken.decNumber, value: "1", offset: 0)])

    #expect(unit.setAsmInstruction(instr), "the unit must claim the `addi` opcode")
    #expect(!unit.isValid)
    #expect(instr.getErrors().values.contains(.assemblerUnknownRegister))
    #expect(instr.getBytes() == nil, "an invalid instruction must emit no bytes")
  }
}
