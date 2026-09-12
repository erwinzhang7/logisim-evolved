# Wiring "Analyze Circuit" — what the module had, what it was missing, what the jar says

2026-09-06. Reference tree `upstream-java-4.1.0` (D16); oracle jar
`/Applications/Logisim-evolution.app/Contents/app/logisim-evolution-4.1.0-all.jar`.

---

## 0. The premise, checked

Briefed: *`LogisimAnalyze` is 22 files imported by nothing; the `Package.swift` edges are already
added and graphcheck reads 14 edges / 12 test targets.*

**The gap is real. The edges were not on the branch.** They exist as an **uncommitted change in
the main working copy** (`swift/Package.swift` in the main working copy,
mtime 01:55, and `tools/graphcheck.py`, 02:05). A worktree branched from `swift-port`
(`507baace6`) does not have them, and `tools/graphcheck.py` there reports **10 edges**, not 14.

Consequence for anyone reading a later gate number: until those two files are committed, every
agent worktree measures a package graph the owner's checkout does not have, and any of them can
lose the edit. This branch carries `swift/Package.swift` re-applied **verbatim** from the working
copy (`diff` reports the two files identical) so it merges as a no-op; `tools/graphcheck.py` was
deliberately left alone, which is why graphcheck still says 10 here.

---

## 1. What is in the module, and where the entry point actually lives

`swift/Sources/LogisimAnalyze/`: 22 files, 6,489 lines. The whole analyze *model*:
`TruthTable`, `Implicant` (Quine-McCluskey + Petrick), `Expression`/`Parser`/`ExpressionRendering`,
`OutputExpressions`, `KarnaughMapGroups`, `KarnaughMapGeometry`, `CoverColor`, the CSV/text/TeX
writers, and `AnalyzeNotPorted.swift`: an exhaustive, file-by-file record of the 20 Swing classes
under `analyze/gui/` that are deliberately excluded under D9.

**That record is accurate and it is not the reason the module was unreachable.** The reason is
one class it does not mention, because it is not in the `analyze` package at all:

    com.cburch.logisim.circuit.Analyze          <- NOT PORTED, and not listed as not-ported

`Analyze` is upstream's only bridge from a `Circuit` to an `AnalyzerModel`. It holds
`getPinLabels`, `computeExpression` and `computeTable`. Without it there is no function anywhere
in the tree that takes a circuit and returns a truth table, so nothing above the module could
have used it even with the dependency edge in place. The edge was necessary and not sufficient.

The call chain in 4.1.0, for the record:

    MenuProject "Analyze Circuit"
      -> ProjectCircuitActions.doAnalyze(proj, circuit)          :177
           Analyze.getPinLabels(circuit)                          -> pin order + labels
           MAX_INPUTS 20 / MAX_OUTPUTS 256 guards, on BIT counts
           AnalyzerManager.getAnalyzer(frame)                     -> one static JFrame, reused
           configureAnalyzer(...)                                 :55
             try   Analyze.computeExpression(...)  -> EXPRESSION_TAB
             catch Analyze.computeTable(...)       -> TABLE_TAB

---

## 2. The oracle: `DeriveProbe`

The existing probes in `tools/analyze/` all exercise the model in isolation; none starts from a
`.circ`. This one does what `doAnalyze` does and prints all three results. Source is at the end
of this file.

    JAR=/Applications/Logisim-evolution.app/Contents/app/logisim-evolution-4.1.0-all.jar
    /opt/homebrew/opt/openjdk@21/bin/javac -cp "$JAR" -d /tmp/anaderive DeriveProbe.java
    /opt/homebrew/opt/openjdk@21/bin/java -Djava.awt.headless=true -cp "$JAR:/tmp/anaderive" \
        com.cburch.logisim.circuit.DeriveProbe <file.circ> <circuit>

Three traps hit while building it, all worth keeping:

1. **`Main.headless = true` is required** (D17) or the corpus files with `source=3.6.1` block on
   the "Old file format" modal.
2. **`computeTable(model, null, circuit, pinLabels)` NPEs.** `CircuitState.createRootState` hands
   the `Project` to `Propagator`'s constructor, which reads `proj.getOptions()`. `new
   Project(file)` is what `TtyInterface:280` uses for the headless `-tty table` path; that works.
3. **The first run printed nothing and looked like agreement.** The JVM had actually finished
   `main` and was held open by `LogisimFile$AutosaveThread`, which is non-daemon: the D17 trap,
   from the other side. `jstack` showed no `main` thread and `DestroyJavaVM` waiting. With
   `System.exit(0)` it terminates. Every run below is asserted to have produced non-empty stdout
   and empty stderr.

**The GUI was deliberately not launched.** The owner was using the GUI at the time and the jar's
analyzer window activates the app. A headless probe against `Analyze` + `AnalyzerModel` is the
stronger oracle anyway: it yields the exact `Entry` grid rather than a screenshot. The window's
shape was read from `Analyzer.java:134-181` and `analyze.properties` instead: four tabs, titles
`Inputs & Outputs` / `Table` / `Expression` / `Minimized`, with `configureAnalyzer` choosing the
landing tab.

---

## 3. What the jar printed

### 3.1 Corpus circuits, and the measurement that decides the scope

`DeriveProbe` was run against three corpus circuits: one built purely from primitive gates, one
instantiating a subcircuit multiplexer, and one instantiating a 7408. Results, with the circuits
unnamed and their expressions withheld on purpose, see the note at the end of this section:

| circuit | `computeExpression` | truth table |
| --- | --- | --- |
| primitive gates only | `EXPR-OK`, and its expression equalled the table-derived minimal one | 3 inputs, 8 rows |
| instantiates a subcircuit | `EXPR-FAIL  CannotHandle`, "due to <the subcircuit>" | 6 inputs, 64 rows |
| instantiates a 7408 | `EXPR-FAIL  CannotHandle`, "due to 7408" | 3 inputs, 8 rows |

**`computeExpression` throws on 2 of 3 corpus circuits**, the moment any component lacks an
`ExpressionComputer`: which includes every subcircuit and every TTL part. And on the one where
it succeeds, the netlist expression and the table-derived minimal expression are the *same
string*. That is the number that made "port the table path only" a defensible scope rather than
a shortcut: see §5.

**Why the circuits are not named here and their expressions are not printed.** They are CSC258
coursework, and a minimised Boolean expression for a named lab exercise is that exercise's answer.
This repository is public and its author is a teaching assistant for the course. Nothing in the
argument above needs the names or the expressions: what carries it is which *kind* of component
forces the table path, and that the two derivations agree where both run.

### 3.2 The fixtures the Swift tests are pinned to

Written for this work, not taken from the corpus (the corpus is private and its golden tables are
lab solutions; neither may be committed). Each is embedded verbatim in the Swift test that uses
it.

`andor`: `y = (a AND b) OR c`:

    PIN a in (80,100) · PIN b in (80,140) · PIN y out (390,170) · PIN c in (80,220)
    EXPR-OK   EXPRESSION y  c+a⋅b
    TABLE inputs=3 outputs=1 rows=8
    HEADER a b c | y
    ROW 0 000|0   ROW 1 001|1   ROW 2 010|0   ROW 3 011|1
    ROW 4 100|0   ROW 5 101|1   ROW 6 110|1   ROW 7 111|1
    TABLE-MINIMAL y  c+a⋅b

Note the pin order: `y` sorts **third**, between `b` and `c`. `getPinLabels` sorts every pin
top-to-bottom *before* splitting inputs from outputs, so a port that sorted the two groups
separately would still print `a b c | y` and would be wrong the first time pins interleave. The
Swift test asserts the mixed order explicitly, not just the split one.

`notbus`: `q = NOT d`, both 2 bits:

    TABLE inputs=2 outputs=2 rows=4
    HEADER d[1] d[0] | q[1] q[0]
    ROW 0 00|11   ROW 1 01|10   ROW 2 10|01   ROW 3 11|00
    TABLE-MINIMAL q[1] ~d[1] ; q[0] ~d[0]

`andor` with `output="true"` stripped, the "no outputs" branch:

    PIN a in · PIN b in · PIN y in · PIN c in
    TABLE inputs=4 outputs=0 rows=16

A `Pin` without the attribute is an *input* pin, so `y` joins the inputs and keeps its place in
the sort. (`configureAnalyzer` returns on the IO tab before computing anything here; the probe
calls `computeTable` unconditionally, which is why it still printed a table.)

`xor2` / `and2`: a two-circuit file, so "the analyzer follows the current circuit" is assertable:

    xor2  HEADER a b | y   rows 0..3 -> 0 1 1 0    TABLE-MINIMAL y  ~a⋅b+a⋅~b
    and2  HEADER p q | r   rows 0..3 -> 0 0 0 1    TABLE-MINIMAL r  p⋅q

One false start worth recording: the first `xor2` placed the XOR gate at the AND gate's geometry,
and the jar returned **`E` in all four rows**: a bus conflict from wires terminating off the
gate's input ports, not a port bug. Had that been embedded as an expectation, the Swift side
would have "agreed" with a broken circuit. Geometry was corrected against the jar before pinning.

---

## 4. What was built

| file | what |
|---|---|
| `swift/Sources/LogisimUI/Analyze/CircuitAnalysis.swift` | the port of `doAnalyze` + `Analyze.computeTable`. **No UI in it**: no SwiftUI, no AppKit, not `@MainActor`. |
| `swift/Sources/LogisimUI/Analyze/AnalyzerWindow.swift` | `AnalyzerPresentation` (state) + `AnalyzerWindowController` (the port of `AnalyzerManager`) + the read-only three-pane window. |
| `swift/Sources/LogisimUI/Analyze/EditorModel+Analyze.swift` | the one seam between the menu bar and a real `Circuit`. |
| `swift/Sources/LogisimUI/App/AppCommands.swift` | Circuit ▸ Analyze Circuit… now opens the window instead of throwing. |

**Why the derivation lives in `LogisimUI`.** It needs `Circuit` (LogisimFile), `Pin` +
`SimulationSession` (LogisimStd) and `AnalyzerModel` (LogisimAnalyze) simultaneously.
`LogisimAnalyze` depends on LogisimKernel and LogisimFile only, by design, "it consumes circuits
rather than defining components", so it cannot see `Pin`, and letting it would put the analysis
model underneath the component library. `LogisimUI` is the lowest module that already sees all
three. D9 is satisfied by content, not by module name: `CircuitAnalysis` is tested with nothing on
screen.

**What is NOT duplicated.** Pin ordering and labelling come from `TruthTableRun.pinColumns`, which
the simulation gate already pins against 1,347 jar oracles. The row loop *is* a second loop over
the same simulation, as it is upstream, where `Analyze.computeTable` and
`TtyInterface.doTableAnalysis` are two methods, because one yields `Entry[][]` and the other
padded text. `AnalyzeModelTests.tableAgreesWithTheTtyTablePath` compares them cell for cell so
they cannot drift.

---

## 5. The gap, stated exactly

> **SUPERSEDED 2026-09-06, on branch `analyze-expression-computer`.** This section was accurate
> when written and the gap it describes is now closed. `Analyze.computeExpression` is ported, as
> `LogisimStd/Analyze/CircuitExpressions.swift`, and the `ExpressionComputer` feature is vended
> by all ten gate factories (`LogisimStd/Analyze/ExpressionComputer.swift` holds the protocol,
> beside its implementors). `LogisimUI/Analyze/ExpressionDerivation.swift` fills the algebra in
> with the real `LogisimAnalyze.Expression`; `CircuitAnalysis.deriveExpressions(circuit:)` is
> the entry point. Fifteen tests pin it to the jar
> (`LogisimStdTests/AnalyzeExpressionTests`, `LogisimUITests/AnalyzeDerivedExpressionTests`).
>
> Two corrections to what follows. **The `Package.swift` edge this section implies is not
> needed**; `LogisimStd` still does not depend on `LogisimAnalyze`; the expression type is
> abstracted behind `ExpressionRef`/`ExpressionAlgebra` and filled in one layer up.
> **`Constant` is still not ported** (it is outside that task's file ownership), so a circuit
> containing a constant still falls back to the table; the exact diff is in that task's summary.
> `CircuitBuilder`, "build a circuit from this expression", remains absent as described below.

**`Analyze.computeExpression` is not available, and cannot be made available in this module
alone.** It works by asking each component for its `ExpressionComputer` feature. In the port the
feature *key* exists (`LogisimFile/Component.swift:58`) and **no component vends it**: all four
upstream implementors say so at the site:

    LogisimStd/Gates/AbstractGate.swift:23   "* `computeExpression` and the `ExpressionComputer` feature: the analyze/truth-table path,"
    LogisimStd/Gates/NotGate.swift:115       "NOT PORTED: getInstanceFeature(ExpressionComputer): the analyze/truth-table path."
    LogisimStd/Gates/Buffer.swift:138        "NOT PORTED: getInstanceFeature(ExpressionComputer): the analyze/truth-table path."
    LogisimStd/Wiring/Constant.swift:170     "NOT PORTED: the ExpressionComputer feature (`ConstantExpression`), analyze path."

Porting `computeExpression` without them would return an empty expression map for every circuit;
worse than not having it. Restoring it is four `getInstanceFeature` overrides in `LogisimStd` plus
`Analyze`'s `ExpressionMap` / `propagateComponents` / `propagateWires` / circular-expression
check, roughly 200 lines. It is a `LogisimStd` change, which this file set does not own.

**Measured cost of the gap** (§3.1): upstream itself falls back to the table on 2 of 3 corpus
circuits, and the *minimised* expressions the Minimized tab shows are table-derived in both
paths, and identical on the one circuit where both ran. The user-visible loss is the Expression
tab's unminimised form on
circuits built purely from primitive gates.

**Also not ported, and not in this module either:** `std/gates/CircuitBuilder`, which is what
`analyze/gui/BuildCircuitButton` drives. So "build a circuit from this expression", the reverse
direction, is absent. That is the larger of the two gaps for a teaching workflow and it is a
`LogisimStd/Gates` change.

**Left out of the window on purpose,** each with the reason at the site: editing the table and the
variable lists (model supports it fully; needs `TableTabCaret`/`TableTabClip`-equivalent caret
machinery), the Karnaugh map (`KarnaughMapGroups` + `CoverColor` are ported and ready, but the
panel is a *drawing* surface and D6 says drawing goes through `RenderScene`), and CSV/text/LaTeX
export (all three writers are ported and jar-pinned; needs an `NSSavePanel`).

---

## 6. One live inconsistency left behind, with its exact fix

`ExplorerSidebar.swift:157` has a second "Analyze Circuit…" in the circuit context menu that still
calls `model.perform(.analyzeCircuit)`, which still throws `notImplemented`. That file is not in
this task's ownership. The fix is the same two lines the menu bar now uses:

```diff
--- a/swift/Sources/LogisimUI/Sidebar/ExplorerSidebar.swift
+++ b/swift/Sources/LogisimUI/Sidebar/ExplorerSidebar.swift
@@
-      Button("Analyze Circuit…") { model.perform(.analyzeCircuit) }
+      Button("Analyze Circuit…") {
+        guard let target = model.analyzableCircuit else { return }
+        AnalyzerWindowController.shared.show(circuit: target.circuit, file: target.file)
+      }
+      .disabled(model.analyzableCircuit == nil)
```

Note this popup is attached to a *specific* circuit row, and upstream's equivalent analyses the
circuit under the cursor. `.analyzeCircuit` carries no `CircuitID`, so both the old code and the
patch above analyse the *current* circuit instead. Making it follow the row means adding the ID to
the case: a `Seams/DomainTypes.swift` change.

`.analyzeCircuit` is deliberately left in `ProjectCommand`: the seam check still sees it, and the
host's `default:` arm still reports it honestly if anything else routes through there.

**Why the menu item does not go through `ProjectHost.perform`.** The host owns the *document*;
the analyzer is a process-wide window over one circuit (`AnalyzerManager` holds one static
`Analyzer` for the whole app, not one per project). Routing it through the host would make the
host own a window, which is the coupling `EditorModel`'s header exists to refuse.

---

## 7. Gates

| gate | before | after |
|---|---|---|
| `swift build` | 0 errors | 0 errors |
| `LogisimUITests` | 192 tests / 29 suites | **203 / 31** |
| full `swift test` | none | **980 tests / 86 suites**, 1 pre-existing environmental skip (`ValueGoldenTests` needs `LOGISIM_CORPUS`) |
| `seamcheck` | 651 files, 14 known, 0 new | **654 files, 14 known, 0 new** |
| `graphcheck` | 10 edges / 12 targets | 10 / 12, the owner's uncommitted `tools/graphcheck.py` (14 edges) was not replicated here; see §0 |

The eleven new tests are `AnalyzeModelTests` (6) and `AnalyzeWiringTests` (5). Every expectation
in them is a literal from `DeriveProbe`'s stdout, except two structural ones:
`tableAgreesWithTheTtyTablePath`, and `viewBodyRendersRatherThanMerelyCompiling`; the latter
because `NSHostingController(rootView:)` runs none of a view's body, so a pane that would trap on
layout constructs perfectly happily. It renders each pane through `ImageRenderer` and requires a
non-empty image, which steals no focus.

One defect found by the tests themselves, in this work: `let table = analyze(…).truthTable`
**traps**. D3 puts `TruthTable.model` on an `unowned` edge, so the model is released on the same
line and the first read hits a destroyed object; it killed the whole test bundle with
`Fatal error: Attempted to read an unowned reference`, which reports as a *signal 6*, not a test
failure. The API note is now on `Analysis.truthTable`.

---

## 8. `DeriveProbe.java`

```java
package com.cburch.logisim.circuit;

import com.cburch.logisim.analyze.model.AnalyzerModel;
import com.cburch.logisim.analyze.model.Var;
import com.cburch.logisim.file.Loader;
import com.cburch.logisim.instance.StdAttr;
import com.cburch.logisim.std.wiring.Pin;
import java.io.File;
import java.util.ArrayList;

public final class DeriveProbe {
  public static void main(String[] args) throws Exception {
    com.cburch.logisim.Main.headless = true;                       // D17
    final var loader = new Loader(null);
    final var file = loader.openLogisimFile(new File(args[0]));
    Circuit circuit = null;
    for (final var c : file.getCircuits()) if (c.getName().equals(args[1])) circuit = c;
    if (circuit == null) { System.out.println("NO-SUCH-CIRCUIT " + args[1]); System.exit(0); }

    final var pinNames = Analyze.getPinLabels(circuit);
    final var inputVars = new ArrayList<Var>();
    final var outputVars = new ArrayList<Var>();
    for (final var entry : pinNames.entrySet()) {
      final var pin = entry.getKey();
      final var width = pin.getAttributeValue(StdAttr.WIDTH).getWidth();
      final var v = new Var(entry.getValue(), width);
      System.out.println("PIN\t" + entry.getValue() + "\t"
          + (Pin.FACTORY.isInputPin(pin) ? "in" : "out")
          + "\twidth=" + width + "\tloc=" + pin.getLocation());
      if (Pin.FACTORY.isInputPin(pin)) inputVars.add(v); else outputVars.add(v);
    }

    final var model = new AnalyzerModel();
    model.setVariables(inputVars, outputVars);
    var expressionsWorked = false;
    try {
      Analyze.computeExpression(model, circuit, pinNames);
      expressionsWorked = true;
      System.out.println("EXPR-OK");
    } catch (AnalyzeException ex) {
      System.out.println("EXPR-FAIL\t" + ex.getClass().getSimpleName() + "\t" + ex.getMessage());
    }
    if (expressionsWorked) {
      for (final var name : model.getOutputs().bits) {
        final var e = model.getOutputExpressions().getExpression(name);
        System.out.println("EXPRESSION\t" + name + "\t" + (e == null ? "<null>" : e.toString()));
        final var min = model.getOutputExpressions().getMinimalExpression(name);
        System.out.println("MINIMAL\t" + name + "\t" + (min == null ? "<null>" : min.toString()));
      }
    }

    final var tableModel = new AnalyzerModel();
    final var proj = new com.cburch.logisim.proj.Project(file);    // null Project NPEs
    Analyze.computeTable(tableModel, proj, circuit, pinNames);
    final var table = tableModel.getTruthTable();
    System.out.println("TABLE\tinputs=" + table.getInputColumnCount()
        + "\toutputs=" + table.getOutputColumnCount() + "\trows=" + table.getRowCount());
    final var head = new StringBuilder("HEADER");
    for (var c = 0; c < table.getInputColumnCount(); c++) head.append('\t').append(table.getInputHeader(c));
    head.append("\t|");
    for (var c = 0; c < table.getOutputColumnCount(); c++) head.append('\t').append(table.getOutputHeader(c));
    System.out.println(head);
    for (var r = 0; r < table.getRowCount(); r++) {
      final var row = new StringBuilder("ROW\t" + r);
      for (var c = 0; c < table.getInputColumnCount(); c++)
        row.append('\t').append(table.getInputEntry(r, c).getDescription());
      row.append("\t|");
      for (var c = 0; c < table.getOutputColumnCount(); c++)
        row.append('\t').append(table.getOutputEntry(r, c).getDescription());
      System.out.println(row);
    }
    for (final var name : tableModel.getOutputs().bits) {
      final var min = tableModel.getOutputExpressions().getMinimalExpression(name);
      System.out.println("TABLE-MINIMAL\t" + name + "\t" + (min == null ? "<null>" : min.toString()));
    }
    System.out.flush();
    System.exit(0);                                                // AutosaveThread is non-daemon
  }
  private DeriveProbe() {}
}
```
