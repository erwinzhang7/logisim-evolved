#!/usr/bin/env python3
"""Capture what the 4.1.0 jar's own RV32imAssembler encodes, as a committed golden file.

The Swift suite must not need a JVM to run, so the oracle is captured once here and pinned.
Regenerate with:

    python3 tools/socbridge/gen_asm_golden.py

Output: swift/Tests/LogisimSocTests/Fixtures/rv32im-asm-4.1.0.oracle, tab-separated
`<pc>\t<source>\t<OK|ERR>\t<hex-word-or-message>`.

The instruction list below is written to cover every mnemonic the eight execution units claim,
including every pseudo-instruction, because the pseudo-instructions are where the operand
*positions* get shuffled and where a transcription error produces a plausible wrong word rather
than a failure. Boundary immediates are included on purpose: each range check in the Java is
exercised from both sides.
"""
import pathlib
import subprocess
import sys

JAR = "/Applications/Logisim-evolution.app/Contents/app/logisim-evolution-4.1.0-all.jar"
JAVA = "/opt/homebrew/opt/openjdk@21/bin/java"
JAVAC = "/opt/homebrew/opt/openjdk@21/bin/javac"
ROOT = pathlib.Path(__file__).resolve().parents[2]
CLASSES = pathlib.Path("/tmp/socbridge")
OUT = ROOT / "swift/Tests/LogisimSocTests/Fixtures/rv32im-asm-4.1.0.oracle"

# (pc, source). pc matters only for the pc-relative forms.
CASES = [
    # ── Integer register-immediate, and its five pseudo-instructions ────────────────────────
    (0, "addi x1,x0,5"),
    (0, "addi x31,x30,-2048"),
    (0, "addi x1,x2,2047"),
    (0, "addi x1,x2,2048"),          # out of range on purpose
    (0, "addi x1,x2,-2049"),         # out of range on purpose
    (0, "slti a0,a1,-7"),
    (0, "sltiu t0,t1,1"),
    (0, "xori s0,s1,-1"),
    (0, "ori gp,tp,255"),
    (0, "andi sp,ra,15"),
    (0, "slli x5,x6,31"),
    (0, "slli x5,x6,32"),            # out of range on purpose
    (0, "srli x5,x6,1"),
    (0, "srai x5,x6,3"),
    (0, "lui x5,0x1000"),
    (0, "lui x5,1048575"),
    (0, "lui x5,1048576"),           # out of range on purpose
    (16, "auipc x7,4096"),
    (0, "nop"),
    (0, "nop x1"),                   # NOP takes no arguments
    (0, "li x1,5"),
    (0, "li ra,-2048"),
    (0, "mv x1,x2"),
    (0, "not x1,x2"),
    (0, "seqz x1,x2"),
    # NOT `addi x99,x0,1`. The bridge's mini-tokenizer classifies any bare word as REGISTER, so
    # Java's setAsmInstruction sees a REGISTER "x99" and answers "Unknown register". The real
    # lexer maps only x0..x31, ABI names, CSR names and `pc`, so `x99` is an unmapped word ->
    # MAYBE_LABEL, and the Swift pipeline rejects it in the label/define pass BEFORE the encoder
    # sees it ("Could not find a definition of this parameter"). Both reject it; they reject it
    # at different stages, and that difference is the bridge's, not the port's. The
    # out-of-range-register path is covered directly instead, in Rv32imAssemblerOracleTests.
    # ── Integer register-register, and SNEZ ─────────────────────────────────────────────────
    (0, "add x1,x2,x3"),
    (0, "sub x1,x2,x3"),
    (0, "sll x1,x2,x3"),
    (0, "slt x1,x2,x3"),
    (0, "sltu x1,x2,x3"),
    (0, "xor x1,x2,x3"),
    (0, "srl x1,x2,x3"),
    (0, "sra x1,x2,x3"),
    (0, "or x1,x2,x3"),
    (0, "and x1,x2,x3"),
    (0, "snez x1,x2"),
    (0, "add x1,x2"),                # wrong arity
    # ── Control transfer, and its five pseudo-instructions ──────────────────────────────────
    (16, "beq x1,x2,pc+8"),
    (16, "bne x1,x2,pc-8"),
    (16, "blt x1,x2,pc+4"),
    (16, "bge x1,x2,pc+4"),
    (16, "bltu x1,x2,pc+4"),
    (16, "bgeu x1,x2,pc+4"),
    (16, "beq x1,x2,pc+2048"),       # out of range on purpose
    (0, "jal x1,pc+16"),
    (0, "jalr x1,x2,4"),
    (0, "jalr x1,x2,1024"),          # out of range on purpose
    (0, "j pc+8"),
    (0, "jr x5"),
    (0, "ret"),
    (0, "ret x1"),                   # RET takes no arguments
    (16, "beqz x1,pc+8"),
    (16, "bnez x1,pc-4"),
    # ── Load and store ──────────────────────────────────────────────────────────────────────
    (0, "lb x1,0(x2)"),
    (0, "lh x1,2(x2)"),
    (0, "lw x3,4(x2)"),
    (0, "lbu x1,-1(x2)"),
    (0, "lhu x1,2047(x2)"),
    (0, "sb x3,1(sp)"),
    (0, "sh x3,2(sp)"),
    (0, "sw x3,8(sp)"),
    (0, "sw x3,2048(sp)"),           # out of range on purpose
    (0, "lw x1,x2"),                 # not an immediate-indexed register
    # ── M extension ─────────────────────────────────────────────────────────────────────────
    (0, "mul x1,x2,x3"),
    (0, "mulh x1,x2,x3"),
    (0, "mulhsu x1,x2,x3"),
    (0, "mulhu x1,x2,x3"),
    (0, "div x1,x2,x3"),
    (0, "divu x1,x2,x3"),
    (0, "rem x1,x2,x3"),
    (0, "remu x1,x2,x3"),
    # ── Environment calls ───────────────────────────────────────────────────────────────────
    (0, "ecall"),
    (0, "ebreak"),
    (0, "mret"),
    (0, "ecall x1"),                 # takes no arguments
    # ── Zicsr, both arities and both operand kinds ──────────────────────────────────────────
    (0, "csrrw x1,0x300,x2"),
    (0, "csrrs x1,0x300,x2"),
    (0, "csrrc x1,0x300,x2"),
    (0, "csrrwi x1,0x300,5"),
    (0, "csrrsi x1,0x300,31"),
    (0, "csrrci x1,0x300,32"),       # 5-bit immediate out of range
    (0, "csrrw x1,mstatus,x2"),
    (0, "csrw 0x300,x2"),
    (0, "csrs mstatus,x2"),
    (0, "csrc 0x300,x2"),
    (0, "csrwi 0x300,7"),
    (0, "csrsi 0x300,7"),
    (0, "csrci 0x300,7"),
    (0, "csrrw x1,0x300"),           # wrong arity for a three-operand form
    (0, "csrw 0x300,x2,x3"),         # wrong arity for a two-operand form
    # ── Memory ordering: upstream refuses to assemble these ────────────────────────────────
    (0, "fence"),
    (0, "fence.tso"),
]


def main():
    if not pathlib.Path(JAR).exists():
        sys.exit(f"no oracle jar at {JAR}")
    CLASSES.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        [JAVAC, "-cp", JAR, "-d", str(CLASSES), str(ROOT / "tools/socbridge/AsmBridge.java")],
        check=True)

    stdin = "".join(f"rv32im\t{pc}\t{text}\n" for pc, text in CASES)
    proc = subprocess.run(
        [JAVA, "-Djava.awt.headless=true", "-cp", f"{JAR}:{CLASSES}",
         "com.cburch.logisim.soc.util.AsmBridge"],
        input=stdin, capture_output=True, text=True)
    if proc.returncode != 0:
        sys.exit(f"bridge failed ({proc.returncode}):\n{proc.stderr}")

    lines = [l for l in proc.stdout.splitlines() if l]
    # ASSERT THE ORACLE PRODUCED OUTPUT: one row per case, no silent truncation.
    if len(lines) != len(CASES):
        sys.exit(f"oracle produced {len(lines)} rows for {len(CASES)} cases")

    OUT.parent.mkdir(parents=True, exist_ok=True)
    with OUT.open("w") as f:
        f.write("# Captured from logisim-evolution-4.1.0-all.jar's own RV32imAssembler by\n")
        f.write("# tools/socbridge/gen_asm_golden.py. Do not hand-edit: regenerate.\n")
        f.write("# <pc>\\t<source>\\t<OK|ERR|PARSE>\\t<hex word or message>\n")
        for (pc, text), result in zip(CASES, lines):
            f.write(f"{pc}\t{text}\t{result}\n")

    ok = sum(1 for l in lines if l.startswith("OK"))
    print(f"{len(CASES)} cases -> {OUT}")
    print(f"  encoded : {ok}")
    print(f"  rejected: {len(CASES) - ok}")


main()
