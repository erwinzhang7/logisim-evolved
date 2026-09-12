#!/usr/bin/env python3
"""Generate the Value golden set by driving ValueBridge once.

The Swift property test then reads a plain text file instead of spawning a JVM
per assertion: fast, deterministic, and CI needs no Java.

Cases are edge-first, then seeded-random. The edge set is the part that matters --
the smoke test already showed combine(TRUE, UNKNOWN) == ERROR and that NIL reports
isUnknown() == true, neither of which random sampling reliably finds.

    python3 gen_golden.py --out golden_value.txt --random 20000

Output format, one case per line:
    <input line>\t<java result>
"""
import argparse, os, random, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
JAVA = os.environ.get("LOGISIM_JAVA", "/opt/homebrew/opt/openjdk@21/bin/java")
JAR = os.environ.get(
    "LOGISIM_JAR",
    "/Applications/Logisim-evolution.app/Contents/app/logisim-evolution-4.1.0-all.jar")

UNARY = ["id", "not", "binary", "hex", "dec", "decu", "long", "slong", "hash",
         "width", "bw", "float", "double", "fp16", "fp8", "all"]
BINARY = ["and", "or", "xor", "combine", "controls", "compat", "equals", "extend"]

# Widths that actually break things: 0 is NIL, 1 is the scalar case, 63/64 are the
# shift boundaries where Java's `1L << 64` is undefined and Swift TRAPS.
EDGE_WIDTHS = [0, 1, 2, 3, 4, 7, 8, 15, 16, 31, 32, 33, 63, 64]


def mask(width):
    return 0 if width == 0 else (1 << width) - 1 if width < 64 else (1 << 64) - 1


def as_signed64(u):
    """Java longs are signed; the bridge parses with Long.parseLong."""
    u &= (1 << 64) - 1
    return u - (1 << 64) if u >= (1 << 63) else u


# create_unsafe validates NOTHING and never throws. Measured against the Java:
#
#   U id 65 0 0 0       -> a 65-bit binary string (width > MAX_WIDTH is accepted)
#   U id -1 0 0 0       -> width -1 accepted; empty binary/hex, "U" decimals
#   U id 8 0 0 999999   -> binary/hex/dec mask to 63, but toLongValue() returns 999999
#   B get 4 .. 99       -> out-of-range bit index returns ERROR rather than throwing
#
# A Swift port over UInt64 shifts would TRAP on width 65 where Java produces a
# string, and would likely mask toLongValue() where Java does not. These cases are
# pinned deliberately so that divergence is caught rather than discovered later in
# a circuit that quietly computes the wrong answer.
PATHOLOGICAL = [
    "X id 65 0 0 0", "X binary 65 0 0 0", "X id 100 0 0 1",
    "X id -1 0 0 0", "X binary -1 0 0 0", "X hex -1 0 0 0",
    "X id 8 0 0 999999", "X long 8 0 0 999999", "X binary 8 0 0 999999",
    "X slong 8 0 0 999999", "X dec 8 0 0 999999",
    "B get 4 0 0 5 4 0 0 99", "B get 4 0 0 5 4 0 0 -1",
    "B set 4 0 0 5 4 0 0 99",
    "U id 64 -1 -1 -1", "U id 64 -1 0 -1", "U id 63 -1 -1 -1",
]


def triples_for(width):
    """(error, unknown, value) combinations worth testing at this width."""
    m = mask(width)
    out = [(0, 0, 0), (0, 0, m), (m, 0, 0), (0, m, 0)]
    if width >= 1:
        lsb, msb = 1, (1 << (width - 1))
        out += [
            (0, 0, lsb), (0, 0, msb), (0, 0, m ^ msb),
            (lsb, 0, 0), (0, lsb, 0), (msb, 0, 0), (0, msb, 0),
            (lsb, msb, 0),                 # error and unknown in different bits
            (lsb, lsb, 0),                 # error and unknown in the SAME bit
            (lsb, 0, lsb),                 # error bit that is also set in value
            (0, lsb, lsb),                 # unknown bit that is also set in value
        ]
    if width >= 4:
        out += [(0, 0, m ^ 0b1010), (0, 0, 0b1010 & m), (0b0011 & m, 0b1100 & m, 0)]
    return [(e & m, u & m, v & m) for (e, u, v) in out]


def gen_cases(rng, n_random):
    cases = list(PATHOLOGICAL)
    # BitWidth ops at EVERY width. getMask at width 63 traps in a naive Swift port
    # ((1L<<63)-1 is Int64.min-1) while Java wraps to Long.MAX_VALUE; 32,929 Value
    # cases missed it because getMask was not covered.
    for w in range(0, 65):
        for op in ("mask", "width", "str"):
            cases.append(f"W {op} {w}")

    # Location / Bounds. Java int is 32-bit and wraps; Integer.parseInt is 32-bit and takes
    # any Unicode decimal digit; String.trim() strips everything <= U+0020. All three were
    # wrong in the first port and none was covered by the Value cases.
    INT32 = [0, 1, -1, 5, -5, 7, -7, 2, -3, 100, -100,
             2147483647, -2147483648, 2147483646, -2147483647, 1073741824, -1073741825]
    # D14: Java's Location cache ignores hasToSnap, so create(x,y,true) earlier in the run
    # poisons a later create(x,y,false). Emit every snap=false case while the cache is cold.
    for x in INT32:
        for y in (0, 1, -1, 2147483647, -2147483648):
            for (dx, dy) in ((1, 0), (-1, 0), (0, 1), (2147483647, 0), (-2147483648, 0)):
                cases.append(f"P translate {x} {y} false {dx} {dy}")
        cases.append(f"P manhattan {x} 0 0 0")
        cases.append(f"P manhattan {x} 0 2147483647 0")
    for x in INT32:
        for y in (0, 1, -1, 2147483647, -2147483648):
            for snap in ("true", "false"):
                cases.append(f"P create {x} {y} {snap}")
    # parse: escaped because the protocol is whitespace-separated.
    for lit in ["(10,20)", "10,20", "10\\s20", "(10,20)\\n", "\\n(10,20)\\t",
                "\\s\\s(10,20)\\s\\s", "(2147483648,0)", "(-2147483649,0)",
                "(3000000000,5)", "(2147483647,0)", "(-2147483648,0)",
                "(٨,0)", "(+5,-7)", "(-3,-3)", "(-7,-7)", "()", "(10)", "abc",
                "(10,)", "(,10)", "(0x10,0)", "( 10 , 20 )"]:
        cases.append(f"P parse {lit}")
    # java.awt.Font.decode and Double text formats: both are .circ attribute round-trips.
    for fnt in ["Comic\\sSans\\sMS\\s12", "SansSerif\\splain\\s12", "Times\\sNew\\sRoman\\sbold\\s14",
                "Helvetica\\s10", "Foo\\sBar\\sBaz\\s9", "Monospaced-bold-16", "Arial",
                "Dialog", "Dialog\\sbolditalic\\s11", "A\\sB\\sC\\sD\\s8",
                "SansSerif-italic-9", "X\\s0", "Y\\s-3", "Serif\\sPLAIN\\s12"]:
        cases.append(f"F decode {fnt}")
    # Subnormals and boundaries are where Double.toString's two-digit rule shows up.
    for bits in [0, 1, 2, 3, 10, 12, 14, 16, 18, 20, 4503599627370496,
                 4607182418800017408, 4611686018427387904, -4616189618054758400,
                 9218868437227405312, -4503599627370496, 4372995238176751616]:
        cases.append(f"D str {bits}")
    for lit in ["1.5", "0.1", "-0.0", "1e10", "1E10", "0x10", "0x1p4", "NaN", "Infinity",
                "-Infinity", "1.4E-324", "4.9E-324", "1d", "1f", "\\s1.5\\s"]:
        cases.append(f"D parse {lit}")
    for (x, y, w, h) in [(0,0,0,0), (0,0,1,1), (-5,-5,10,10), (2147483647,0,1,1),
                         (2147483640,0,10,10), (-2147483648,0,1,1), (0,0,-1,-1)]:
        cases.append(f"R create {x} {y} {w} {h}")
        cases.append(f"R addpt {x} {y} {w} {h} 3 4")
        cases.append(f"R addpt {x} {y} {w} {h} 2147483647 2147483647")
        cases.append(f"R contains {x} {y} {w} {h} 0 0")
        cases.append(f"R add {x} {y} {w} {h} 1 1 2 2")
        cases.append(f"R add {x} {y} {w} {h} 2147483647 2147483647 1 1")
    for w in EDGE_WIDTHS:
        for (e, u, v) in triples_for(w):
            for op in UNARY:
                cases.append(f"U {op} {w} {as_signed64(e)} {as_signed64(u)} {as_signed64(v)}")
    # Binary ops across matched and MISMATCHED widths -- mismatch is where
    # compatible()/extendWidth() semantics actually get exercised.
    for w1 in [0, 1, 2, 4, 8, 32, 64]:
        for w2 in [0, 1, 2, 4, 8, 32, 64]:
            for (e1, u1, v1) in triples_for(w1)[:5]:
                for (e2, u2, v2) in triples_for(w2)[:5]:
                    for op in BINARY:
                        cases.append(
                            f"B {op} {w1} {as_signed64(e1)} {as_signed64(u1)} {as_signed64(v1)}"
                            f" {w2} {as_signed64(e2)} {as_signed64(u2)} {as_signed64(v2)}")
    for _ in range(n_random):
        if rng.random() < 0.5:
            w = rng.choice(EDGE_WIDTHS) if rng.random() < 0.4 else rng.randint(0, 64)
            m = mask(w)
            e, u, v = rng.getrandbits(64) & m, rng.getrandbits(64) & m, rng.getrandbits(64) & m
            cases.append(f"U {rng.choice(UNARY)} {w} {as_signed64(e)} {as_signed64(u)} {as_signed64(v)}")
        else:
            w1 = rng.choice(EDGE_WIDTHS) if rng.random() < 0.4 else rng.randint(0, 64)
            w2 = w1 if rng.random() < 0.7 else (rng.choice(EDGE_WIDTHS) if rng.random() < 0.5 else rng.randint(0, 64))
            m1, m2 = mask(w1), mask(w2)
            a = (rng.getrandbits(64) & m1, rng.getrandbits(64) & m1, rng.getrandbits(64) & m1)
            b = (rng.getrandbits(64) & m2, rng.getrandbits(64) & m2, rng.getrandbits(64) & m2)
            cases.append(
                f"B {rng.choice(BINARY)} {w1} {as_signed64(a[0])} {as_signed64(a[1])} {as_signed64(a[2])}"
                f" {w2} {as_signed64(b[0])} {as_signed64(b[1])} {as_signed64(b[2])}")
    return cases


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--random", type=int, default=20000)
    ap.add_argument("--seed", type=int, default=20260904)
    args = ap.parse_args()

    classes = os.path.join(HERE, "out")
    if not os.path.isdir(classes):
        sys.exit(f"compile the bridge first:\n  javac -cp {JAR} -d {classes} ValueBridge.java")

    cases = gen_cases(random.Random(args.seed), args.random)
    print(f"{len(cases)} cases")

    p = subprocess.run(
        [JAVA, "-Djava.awt.headless=true", "-cp", f"{JAR}:{classes}", "ValueBridge"],
        input="\n".join(cases) + "\n", capture_output=True, text=True, timeout=900)
    lines = p.stdout.splitlines()

    if lines and lines[0].startswith("!BRIDGE-INIT-FAILED"):
        sys.exit(f"bridge failed to initialise: {lines[0]}")
    if len(lines) != len(cases):
        sys.exit(f"bridge returned {len(lines)} results for {len(cases)} cases — "
                 "results would be misaligned, refusing to write a corrupt golden set")

    with open(args.out, "w") as f:
        for c, r in zip(cases, lines):
            f.write(f"{c}\t{r}\n")

    throws = sum(1 for r in lines if r.startswith("!"))
    print(f"wrote {args.out}  ({len(lines)} results, {throws} of them exceptions)")
    print("exceptions are expected outcomes: the port must throw on the same inputs")


if __name__ == "__main__":
    main()
