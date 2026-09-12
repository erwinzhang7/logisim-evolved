# Auditing Java line citations against 4.1.0

Written 2026-09-06, after the D16 trap produced five wrong citations in one day.

## Why

The port's Swift sources carry **1,112 Java line citations**; `Foo.java:123` in comments and doc
comments. They are the evidence for nearly every behavioural claim in the tree, and a citation
read from the wrong tree looks exactly like one read from the right tree. The `src/main/java`
tree in the development fork is upstream **main**, and is not published here; the port target is
the 4.1.0 tag (D16 and its addendum).

## The cheap check, and what it found

For every citation whose basename resolves to exactly one file in
`~/Developer/logisim/upstream-java-4.1.0`, assert the cited line is within that file.

    java citations in swift sources          1,112
    uniquely resolvable to a 4.1.0 file      1,043
    citing a line PAST the end of the file       6

Six is small enough to classify by hand, which is the right size for a first pass:

| citation | verdict |
|---|---|
| `GraphicsUtil.java:282-299`, in 3 files | **REAL; the D16 trap.** main has 311 lines, 4.1.0 has 239. The cited range is main's `textLayout` helper, built on a `TextLayout` class 4.1.0 does not have. |
| `Component.java:156`, in 2 files | **False positive of the checker.** The text is `netlistComponent.java:156-178`; a `[A-Z]\w*\.java` pattern matches `Component.java` inside it. Tighten to require a non-identifier character before the capital. |
| `Drawing.java:844` | **Unresolved.** No `draw/model/Drawing.java` exists in either tree at the path guessed; the basename index matched some other `Drawing.java`. Needs a path-aware lookup, not a basename one. |

**The three real ones are now corrected.** All three made the same claim, that upstream measures
a string twice per draw, which is TRUE in 4.1.0 and at a sharper location than the wrong citation
gave: `drawText:166` calls `getTextBounds`, which builds a `TextMetrics` at `:201`, and then `:167`
builds a **second** one for the same string. So the claim survived; only its evidence was wrong.
That is the dangerous shape; a true statement with a citation nobody can follow.

## What a checker would need before it earns a place in `tools/`

1. **A path-aware index**, not a basename one. `Component.java` is ambiguous across the tree and
   `netlistComponent.java` proves the regex needs a word boundary.
2. **A calibration selftest** pinning both directions, in the shape `deadseam.py --selftest` uses:
   a citation known-good against 4.1.0 and one known-good against main only, so a change that
   breaks the resolution is caught rather than silently passing everything.
3. **An in-range citation can still be wrong.** This check only catches lines past EOF, which is
   why it found 3 of an unknown total. It is a smoke detector, not a proof.

Filed rather than built because 1,043 of 1,043 resolvable citations are now in range, so the
marginal value of automating it is low until the next tree-confusion incident. The measurement
above is the reason to build it if that happens.
