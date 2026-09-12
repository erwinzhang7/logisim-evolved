# Java 4.1.0 hash/iteration-order experiment

Date: 2026-09-05

## Verdict

**NO: simulation truth-table output did not depend on hash iteration order in these experiments.** None of the three probes detected a byte difference. In particular, `-XX:hashCode=2`, which makes all identity hashes collide, produced output byte-for-byte identical to the ordinary JVM baseline on both stress circuits. The Swift port can keep its deterministic insertion-ordered containers on the evidence of this experiment.

This is an experimental result, not a source-code or JDK-internals argument.

## Environment and oracle-driving details

The tested JVM was:

```text
openjdk version "21.0.11" 2026-04-21
OpenJDK Runtime Environment Homebrew (build 21.0.11)
OpenJDK 64-Bit Server VM Homebrew (build 21.0.11, mixed mode, sharing)
```

The fixed paths were:

```sh
JAVA=/opt/homebrew/opt/openjdk@21/bin/java
JAR=/Applications/Logisim-evolution.app/Contents/app/logisim-evolution-4.1.0-all.jar
CORPUS="${LOGISIM_CORPUS:?}/harvested"
TMPDIR=/tmp/hashorder.i2U4Cx
```

I first read `tools/difftest/rig.py` and `tools/difftest/canonical.py`. Following the rig, every oracle invocation used `-Djava.awt.headless=true`, ran with the `.circ` file's directory as the working directory, passed the basename rather than the absolute path, and used `--toplevel-circuit CIRCUIT -tty table FILE`. Exit status and stderr were captured directly from Java; no pipeline or macOS `timeout` command was used.

## Cases selected

1. `3.3.0__case-269.circ`, top-level `ALU_component`. This is a mid-size ALU datapath, not a gate demo. The selected circuit has eight sibling subcircuit instances (`func0` through `func7`) and 112 wire elements. Its truth table has 2,049 lines (38,931 bytes), so it exercises many input combinations and multiple nets.
2. `3.6.1__case-435.circ`, top-level `ALU`. This is an independent CSC258 ALU implementation. The selected circuit has eight sibling subcircuit instances (`op0` through `op7`) and 61 wire elements. Its truth table also has 2,049 lines (43,029 bytes).

The corpus scan also found the much larger `3.5.0__case-541.circ` (80 subcircuit-instance references), but its `main` circuit emitted only two blank lines under `-tty table`. I did not use that empty result as a sensitivity case.

## Probe 1: determinism across separate JVM runs

The actual loop was run once for each of the following `(FILE, CIRCUIT, LABEL)` triples:

```text
3.3.0__case-269.circ ALU_component case-213
3.6.1__case-435.circ ALU case-304
```

For each triple I assigned `FILE`, `CIRCUIT`, and `LABEL` to those values and ran from `$CORPUS`.

**The `case-NNN` names here are anonymous handles, not filenames.** The corpus is coursework and
is not published, so the commands below are the ones that were run, transcribed, rather than
commands you can paste. `tools/corpus.py` resolves a handle to the real filename when the corpus
is present.

Command (the Java command is inside the loop, so this creates ten separate JVM processes rather than reusing one):

```sh
mkdir -p "$TMPDIR/probe1/$LABEL"
for i in $(seq 1 10); do
  "$JAVA" -Djava.awt.headless=true -jar "$JAR" \
    --toplevel-circuit "$CIRCUIT" -tty table "$FILE" \
    > "$TMPDIR/probe1/$LABEL/run-$i.out" \
    2> "$TMPDIR/probe1/$LABEL/run-$i.err"
  printf '%s %s %s\n' "$i" "$?" \
    "$(shasum -a 256 "$TMPDIR/probe1/$LABEL/run-$i.out" | awk '{print $1}')"
done
```

Raw results:

| File/circuit | Distinct outputs | Runs | Exit/stderr result | SHA-256 on every run |
|---|---:|---:|---|---|
| `3.3.0__case-269.circ::ALU_component` | **1** | 10 | all exit 0; all stderr empty | `b9ceb880458691bd7051caccce0536dae3b3276c3ff07bdf7d9b78940bb81058` |
| `3.6.1__case-435.circ::ALU` | **1** | 10 | all exit 0; all stderr empty | `b9dee385085db3b3771523a286c0d595e04223a1839bb8d170f58bac0bf52614` |

Thus each case produced 1 distinct output out of 10 separate JVM invocations.

## Probe 2: sensitivity to identity-hash behavior

For each case and each literal value `0 1 2 3 4 5`, I ran:

```sh
cd "$CORPUS"
for H in 0 1 2 3 4 5; do
"$JAVA" -XX:+UnlockExperimentalVMOptions -XX:hashCode="$H" \
  -Djava.awt.headless=true -jar "$JAR" \
  --toplevel-circuit "$CIRCUIT" -tty table "$FILE" \
  > "$TMPDIR/probe2/$LABEL/hash-$H.out" \
  2> "$TMPDIR/probe2/$LABEL/hash-$H.err"
RC=$?
cmp -s "$TMPDIR/probe1/$LABEL/run-1.out" \
       "$TMPDIR/probe2/$LABEL/hash-$H.out"
done
```

Acceptance below is based on the actual Java exit behavior, not an assumption. Every requested setting was accepted by this specific JVM: Java exited 0 and wrote zero bytes to stderr in every run.

| `-XX:hashCode` | Accepted/rejected | Java exit | Stderr bytes | case-213 output vs baseline | case-304 output vs baseline |
|---:|---|---:|---:|---|---|
| 0 | **accepted** | 0 | 0 | identical | identical |
| 1 | **accepted** | 0 | 0 | identical | identical |
| 2 | **accepted** | 0 | 0 | identical | identical |
| 3 | **accepted** | 0 | 0 | identical | identical |
| 4 | **accepted** | 0 | 0 | identical | identical |
| 5 | **accepted** | 0 | 0 | identical | identical |

Across the six accepted settings, each circuit had **1 distinct output out of 6 conditions**. Most importantly, the all-colliding `hashCode=2` output was identical to the no-`-XX:hashCode` baseline for both circuits.

## Probe 3: sensitivity to allocation/XML element order

I copied `3.3.0__case-269.circ` to scratch space and hand-reordered the two independent top-level input-pin `<comp>` subtrees (`A` at `(170,340)` and `B` at `(170,460)`) inside `ALU_component`. Locations, labels, attributes, components, and all wires were unchanged.

Creation and oracle commands:

```sh
cp "$CORPUS/3.3.0__case-269.circ" \
   "$TMPDIR/reordered.circ"

# Hand edit: move the complete B <comp> subtree immediately before the
# complete A <comp> subtree; make no other edit.

cd "$TMPDIR"
"$JAVA" -Djava.awt.headless=true -jar "$JAR" \
  --toplevel-circuit ALU_component -tty table reordered.circ \
  > "$TMPDIR/probe3-variant.out" \
  2> "$TMPDIR/probe3-variant.err"

cmp -s "$TMPDIR/probe1/case-213/run-1.out" "$TMPDIR/probe3-variant.out"
```

The file diff contained exactly this subtree move:

```diff
-    <comp lib="0" loc="(170,340)" name="Pin">
-      <a name="appearance" val="NewPins"/>
-      <a name="label" val="A"/>
-      <a name="width" val="4"/>
-    </comp>
     <comp lib="0" loc="(170,460)" name="Pin">
       <a name="appearance" val="NewPins"/>
       <a name="label" val="B"/>
       <a name="width" val="4"/>
     </comp>
+    <comp lib="0" loc="(170,340)" name="Pin">
+      <a name="appearance" val="NewPins"/>
+      <a name="label" val="A"/>
+      <a name="width" val="4"/>
+    </comp>
```

I also parsed both XML files and recursively compared each element as `(tag, sorted attributes, stripped text, unordered multiset of child subtrees)`. The check printed `unordered_structures_equal=true`, confirming that the XML structures differ only in child order. The exact structural check was:

```sh
python3 -c 'import sys,xml.etree.ElementTree as E
def canon(e):
 return (e.tag,tuple(sorted(e.attrib.items())),(e.text or "").strip(),tuple(sorted((canon(x) for x in e),key=repr)))
a=E.parse(sys.argv[1]).getroot(); b=E.parse(sys.argv[2]).getroot(); print("unordered_structures_equal="+str(canon(a)==canon(b)).lower())' \
  "$CORPUS/3.3.0__case-269.circ" \
  "$TMPDIR/reordered.circ"
```

Result: Java exited 0, stderr was empty, and the original and reordered truth-table outputs were **byte-for-byte identical**. Both had SHA-256 `b9ceb880458691bd7051caccce0536dae3b3276c3ff07bdf7d9b78940bb81058`. There is therefore no output diff to reproduce.

## Final interpretation

- Probe 1 detected no run-to-run nondeterminism.
- Probe 2 detected no output sensitivity to any accepted identity-hash mode, including complete identity-hash collision under mode 2.
- Probe 3 detected no output sensitivity to a semantics-preserving component-allocation/XML-order change.

**Answer: NO. Java 4.1.0's `-tty table` simulation output did not depend on hash iteration order in these stress measurements. The Swift implementation can retain deterministic insertion order; these measurements provide no reason to emulate HotSpot hash-container iteration order.**
