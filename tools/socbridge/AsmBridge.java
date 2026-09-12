/*
 * AsmBridge: drives upstream's OWN RV32imAssembler / Nios2Assembler and prints what it encodes.
 *
 * The port's brief says it in capitals: do not transcribe the Java and hope, run upstream's own
 * class and diff its output. `setAsmInstruction` is 8 files of dense bit-packing with pseudo-
 * instruction rewrites (LI/MV/NOT/SEQZ/NOP/J/JR/RET/BEQZ/BNEZ/CALL/…) layered on top, and a
 * transcription error there produces a *plausible* wrong word: the worst kind.
 *
 * Deliberately NOT driving `com.cburch.logisim.soc.util.Assembler`: that class is an
 * RSyntaxTextArea `AbstractParser` and reads its tokens back out of a live editor widget, so
 * exercising it means constructing Swing components. This bridge tokenizes the one line itself,
 * builds the `AssemblerAsmInstruction` directly, and calls `AbstractAssembler.assemble`, which
 * is exactly, and only, the code path being ported.
 *
 * It lives in `com.cburch.logisim.soc.util` because `AssemblerAsmInstruction.getBytes()` and the
 * `AssemblerToken` constructor are public but the package is the natural home, and because
 * 4.1.0's package-private members are reachable only from inside it (D16/D17 record the same
 * trick for CircBridge).
 *
 * Usage: one instruction per line on stdin, `<cpu>\t<pc>\t<text>`:
 *
 *   rv32im	0	addi x1,x0,5
 *   rv32im	16	beq x1,x2,-8
 *   nios2	0	addi r2,r3,4
 *
 * Output, one line per input: `OK\t<hex-word>`  or  `ERR\t<message>` or `PARSE\t<reason>`.
 *
 * ASSERT THE ORACLE PRODUCED OUTPUT: the driver counts lines in and lines out and fails loudly
 * if they differ. A drivable-looking entry point that writes nothing and exits 0 has cost this
 * project real time before.
 */
package com.cburch.logisim.soc.util;

import com.cburch.logisim.soc.nios2.Nios2Assembler;
import com.cburch.logisim.soc.rv32im.RV32imAssembler;
import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.io.PrintStream;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;

public class AsmBridge {

  /** Classify one whitespace-free parameter atom the way the real tokenizer would. */
  private static AssemblerToken classify(String atom, int offset) {
    // The WHOLE `0x…` text, prefix included. `AssemblerToken`'s constructor does
    // `value.toUpperCase().split("X")` and requires length 2, so a pre-stripped value sets
    // `valid = false` and **returns before `isLabel` is assigned**: leaving that `Boolean` null
    // and making the next `isLabel()` call NPE inside upstream's own `setAsmInstruction`.
    // (Measured here, not reasoned: that NPE is what this bridge hit first.)
    if (atom.startsWith("0x") || atom.startsWith("0X")) {
      return new AssemblerToken(AssemblerToken.HEX_NUMBER, atom, offset);
    }
    if (atom.equals("pc")) {
      return new AssemblerToken(AssemblerToken.PROGRAM_COUNTER, atom, offset);
    }
    if (atom.startsWith("-") || Character.isDigit(atom.charAt(0))) {
      return new AssemblerToken(AssemblerToken.DEC_NUMBER, atom, offset);
    }
    if (atom.startsWith("(") && atom.endsWith(")")) {
      return new AssemblerToken(
          AssemblerToken.BRACKETED_REGISTER, atom.substring(1, atom.length() - 1), offset);
    }
    return new AssemblerToken(AssemblerToken.REGISTER, atom, offset);
  }

  /**
   * Split one parameter into its atoms. A parameter may be several tokens, `pc+8`, `4(sp)`,
   * and the real assembler folds those before `setAsmInstruction` sees them, so the folding
   * happens here too: `pc+8` becomes PROGRAM_COUNTER, MATH_ADD, DEC_NUMBER, and `4(sp)` becomes
   * DEC_NUMBER, BRACKETED_REGISTER, matching what `Assembler`'s fourth pass produces.
   */
  private static AssemblerToken[] parameter(String text, int offset) {
    final var out = new ArrayList<AssemblerToken>();
    int i = 0;
    final var atom = new StringBuilder();
    while (i < text.length()) {
      final char c = text.charAt(i);
      if (c == '+' || c == '-') {
        // A leading sign belongs to the number, an infix one is an operator.
        if (atom.length() == 0) {
          atom.append(c);
          i++;
          continue;
        }
        out.add(classify(atom.toString(), offset));
        atom.setLength(0);
        out.add(
            new AssemblerToken(
                c == '+' ? AssemblerToken.MATH_ADD : AssemblerToken.MATH_SUBTRACT,
                String.valueOf(c),
                offset));
        i++;
        continue;
      }
      if (c == '(') {
        if (atom.length() > 0) {
          out.add(classify(atom.toString(), offset));
          atom.setLength(0);
        }
        final int close = text.indexOf(')', i);
        if (close < 0) return null;
        out.add(
            new AssemblerToken(
                AssemblerToken.BRACKETED_REGISTER, text.substring(i + 1, close), offset));
        i = close + 1;
        continue;
      }
      atom.append(c);
      i++;
    }
    if (atom.length() > 0) out.add(classify(atom.toString(), offset));
    return out.toArray(new AssemblerToken[0]);
  }

  public static void main(String[] args) throws Exception {
    final var in = new BufferedReader(new InputStreamReader(System.in));
    final PrintStream out = System.out;
    final var rv32im = new RV32imAssembler();
    final var nios2 = new Nios2Assembler();

    int lines = 0;
    int emitted = 0;
    String line;
    while ((line = in.readLine()) != null) {
      if (line.isEmpty()) continue;
      lines++;
      final var fields = line.split("\t", -1);
      if (fields.length < 3) {
        out.println("PARSE\tneed <cpu>\\t<pc>\\t<text>");
        emitted++;
        continue;
      }
      final AssemblerInterface asm = fields[0].equals("nios2") ? nios2 : rv32im;
      final long pc = Long.parseLong(fields[1]);
      final var text = fields[2].trim();

      final int space = text.indexOf(' ');
      final var opcode = (space < 0) ? text : text.substring(0, space);
      final var rest = (space < 0) ? "" : text.substring(space + 1).trim();

      final var instrToken = new AssemblerToken(AssemblerToken.ASM_INSTRUCTION, opcode, 0);
      final var instr =
          new AssemblerAsmInstruction(instrToken, asm.getInstructionSize(opcode));
      instr.setProgramCounter(pc);

      if (!rest.isEmpty()) {
        boolean bad = false;
        for (final var raw : rest.split(",", -1)) {
          final var param = parameter(raw.trim(), 0);
          if (param == null || param.length == 0) {
            bad = true;
            break;
          }
          instr.addParameter(param);
        }
        if (bad) {
          out.println("PARSE\tcould not tokenize: " + rest);
          emitted++;
          continue;
        }
      }

      // `Assembler`'s own fourth pass does this before handing the instruction over; without it
      // a `pc`-relative parameter is still three tokens and every branch would report an error
      // that upstream never shows.
      final var calcErrors = new HashMap<AssemblerToken, com.cburch.logisim.util.StringGetter>();
      instr.replacePcAndDoCalc(pc, calcErrors);
      if (!calcErrors.isEmpty()) {
        out.println("PARSE\tpc/math folding failed");
        emitted++;
        continue;
      }

      final boolean ok = asm.assemble(instr);
      if (!ok || instr.hasErrors()) {
        final var messages = new ArrayList<String>();
        for (final var e : instr.getErrors().entrySet()) messages.add(e.getValue().toString());
        out.println("ERR\t" + String.join(" | ", messages));
        emitted++;
        continue;
      }
      final Byte[] bytes = instr.getBytes();
      if (bytes == null) {
        out.println("ERR\tno bytes produced");
        emitted++;
        continue;
      }
      // Little-endian, as `setInstructionByteCode` packs it.
      long word = 0;
      for (int b = bytes.length - 1; b >= 0; b--) {
        word = (word << 8) | (bytes[b] & 0xFF);
      }
      out.printf("OK\t%08X%n", word);
      emitted++;
    }

    out.flush();
    if (emitted != lines) {
      System.err.printf("AsmBridge: %d lines in, %d out — refusing to look like agreement%n",
          lines, emitted);
      System.exit(3);
    }
    if (lines == 0) {
      System.err.println("AsmBridge: no input — a zero-output success is not a passing run");
      System.exit(4);
    }
    System.exit(0);
  }
}
