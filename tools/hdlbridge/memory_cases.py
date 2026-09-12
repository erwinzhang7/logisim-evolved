#!/usr/bin/env python3
"""Emit the request lines MemoryBridge.java reads on stdin, one per case.

Each line is  <component>\t<VHDL|Verilog>\t<attr=value,...>  and each case is a
distinct attribute setting the Swift port must reproduce byte-for-byte. The spread is
chosen so every structural branch in the seven std/memory generators is taken at least
once: latch vs flip-flop, width 1 vs bus (the VHDL d(0)/q(0) port-map rewrite), every
Counter on-goal mode, ShiftRegister with and without parallel load and in both
appearances, and RAM's line-enable vs byte-enable implementations.
"""

CASES = []


def add(component, attrs=""):
    for lang in ("VHDL", "Verilog"):
        CASES.append((component, lang, attrs))


# ── Flip-flops ───────────────────────────────────────────────────────────────────────
# D and S-R allow level triggers (StdAttr.TRIGGER, four options); T and J-K are
# edge-only (StdAttr.EDGE_TRIGGER, two). The trigger drives BOTH the invertClockEnable
# generic and the flip-flop-vs-latch branch in getModuleFunctionality.
for comp in ("D Flip-Flop", "S-R Flip-Flop"):
    for trig in ("rising", "falling", "high", "low"):
        add(comp, f"trigger={trig}")
for comp in ("T Flip-Flop", "J-K Flip-Flop"):
    for trig in ("rising", "falling"):
        add(comp, f"trigger={trig}")

# ── Register ─────────────────────────────────────────────────────────────────────────
for width in (1, 8, 32):
    for trig in ("rising", "falling", "high", "low"):
        add("Register", f"width={width},trigger={trig}")

# ── Counter ──────────────────────────────────────────────────────────────────────────
for width in (1, 8):
    for goal in ("wrap", "stay", "continue", "load"):
        add("Counter", f"width={width},ongoal={goal},trigger=rising")
add("Counter", "width=8,ongoal=wrap,trigger=falling")
add("Counter", "width=6,max=0x2a,ongoal=wrap,trigger=rising")

# ── Shift register ───────────────────────────────────────────────────────────────────
for width in (1, 4):
    for length in (2, 8):
        for parallel in ("true", "false"):
            add("Shift Register", f"width={width},length={length},parallel={parallel}")
add("Shift Register", "width=1,length=4,parallel=true,appearance=classic")
add("Shift Register", "width=1,length=4,parallel=true,trigger=falling")

# ── Random ───────────────────────────────────────────────────────────────────────────
for width in (1, 8):
    for seed in (0, 12345):
        add("Random", f"width={width},seed={seed}")

# ── RAM ──────────────────────────────────────────────────────────────────────────────
# The two memory implementations emit structurally different HDL and must not be
# collapsed: ENABLES_ATTR=line routes to getGenerationTimeWiresPortsLineEnables /
# getModuleFunctionalityLineEnables, anything else to the byte-enable pair.
for data in (8, 12, 32):
    for addr in (4, 8):
        add("RAM", f"dataWidth={data},addrWidth={addr},enables=byte,databus=bibus")
# ATTR_ByteEnables only joins RamAttributes' list once dataWidth > 8 (RamAttributes:93),
# so the with/without pair is only exercisable at a wider data bus.
add("RAM", "dataWidth=12,addrWidth=4,enables=byte,databus=bibus,byteenables=byteEnables")
add("RAM", "dataWidth=12,addrWidth=4,enables=byte,databus=bibus,byteenables=NobyteEnables")
add("RAM", "dataWidth=32,addrWidth=4,enables=byte,databus=bibus,byteenables=byteEnables")
add("RAM", "dataWidth=17,addrWidth=4,enables=byte,databus=bibus,byteenables=byteEnables")
add("RAM", "dataWidth=8,addrWidth=4,enables=byte,databus=bibus,asyncread=true")
add("RAM", "dataWidth=8,addrWidth=4,enables=byte,databus=bibus,readbehav=war")
add("RAM", "dataWidth=8,addrWidth=4,enables=byte,databus=bidir")
for data in (8, 32):
    for addr in (4, 8):
        for line in ("single", "dual", "quad", "octo"):
            add("RAM", f"dataWidth={data},addrWidth={addr},enables=line,line={line}")
add("RAM", "dataWidth=8,addrWidth=4,enables=line,clearpin=true")
add("RAM", "dataWidth=8,addrWidth=4,enables=byte,databus=bibus,trigger=high")

# ── ROM ──────────────────────────────────────────────────────────────────────────────
# Inlined-only: no entity/architecture. Recorded so the ONLYINLINED / SUPPORTEDTARGET
# answers are still gated.
for data in (4, 8):
    for addr in (2, 4):
        add("ROM", f"dataWidth={data},addrWidth={addr}")
add("ROM", "dataWidth=8,addrWidth=4,line=dual")


if __name__ == "__main__":
    for comp, lang, attrs in CASES:
        print(f"{comp}\t{lang}\t{attrs}")
