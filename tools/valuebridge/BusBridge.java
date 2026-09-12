// Oracle bridge for the U-vs-E family of M3 simulation mismatches.
//
// WHAT QUESTION THIS ANSWERS
//
// `TtyInterface.doTableAnalysis` (4.1.0, TtyInterface.java:435-441) does this per row:
//
//     for (final var pin : outputPins) {
//       if (prop.isOscillating()) {
//         valueMap.put(pin, Value.createError(pin.getAttributeValue(StdAttr.WIDTH)));
//       } else {
//         valueMap.put(pin, Pin.FACTORY.getValue(circuitState.getInstanceState(pin)));
//       }
//     }
//
// So an all-`E` row in a golden table has TWO possible causes that are indistinguishable from
// the table alone: the circuit really resolved to error values, or **the propagation hit the
// oscillation cap and every output was overwritten with `createError`**. The second is a
// property of the propagator, not of any component, and a port whose event queue drains one
// iteration sooner reports the real values instead, which reads as "the port is less defined"
// on some rows and "more defined" on others, both from one cause.
//
// This bridge replays `doTableAnalysis` verbatim and prints `prop.isOscillating()` per row, so
// the two causes can be told apart. It reports the values too, so a row can be checked without
// re-running `-tty table`.
//
// The rest of the loop is copied from upstream rather than paraphrased: same
// `CircuitState.createRootState` per row (a fresh state each time, NOT one carried across rows),
// same `Pin.FACTORY.driveInputPin`, same `TruthTable.isInputSet` bit order (b counts DOWN from
// width-1), same input-pins-then-output-pins column order taken from `Analyze.getPinLabels`'s
// map iteration. Any of those getting out of step would silently mis-attribute a divergence.
//
// Protocol: one request per line on stdin:
//     <circ-path>\t<circuit-name>
// Output, one line per truth-table row, plus a trailing summary line:
//     ROW\t<circuit>\t<row-index>\tosc=<true|false>\t<pin>=<value>\t<pin>=<value>...
//     DONE\t<circuit>\t<rows>\t<oscillating-rows>
// or, on failure:
//     FAIL\t<path>\t<circuit>\t<ExceptionClass>: <message>
//
// Declared IN com.cburch.logisim.circuit so it can reach package-private simulator internals if
// this bridge is extended to dump `CircuitWires.State.buses` (the next question after this one:
// *which* net diverges). Nothing package-private is needed for the oscillation report itself.
//
// Build:
//   javac -cp <logisim-fat.jar> -d out BusBridge.java
// Run:
//   java -Djava.awt.headless=true -cp <logisim-fat.jar>:out \
//        com.cburch.logisim.circuit.BusBridge < requests.tsv
//
// Derived from logisim-evolution, GPL-3.0-only.

package com.cburch.logisim.circuit;

import com.cburch.logisim.analyze.model.TruthTable;
import com.cburch.logisim.instance.StdAttr;
import com.cburch.logisim.data.Value;
import com.cburch.logisim.file.Loader;
import com.cburch.logisim.instance.Instance;
import com.cburch.logisim.proj.Project;
import com.cburch.logisim.std.wiring.Pin;

import java.io.BufferedReader;
import java.io.File;
import java.io.InputStreamReader;
import java.io.PrintStream;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.Map;

public final class BusBridge {

  private static String oneLine(String s) {
    return s == null ? "" : s.replace('\n', ' ').replace('\r', ' ').replace('\t', ' ');
  }

  public static void main(String[] args) throws Exception {
    // Same dialog switch CircBridge documents: OptionPane degrades every modal to a log line
    // when Main.headless is set. Without it the pre-2.7.2 "Old file format" notice blocks
    // forever, and every file in the failing set is pre-2.7.2.
    com.cburch.logisim.Main.headless = true;

    final BufferedReader in = new BufferedReader(new InputStreamReader(System.in));
    final PrintStream out = System.out;

    String line;
    int emitted = 0;
    while ((line = in.readLine()) != null) {
      line = line.trim();
      if (line.isEmpty()) continue;
      final String[] parts = line.split("\t");
      if (parts.length != 2) {
        out.println("FAIL\t" + oneLine(line) + "\t\tbad-line (expected path<TAB>circuit)");
        out.flush();
        continue;
      }
      final String path = parts[0];
      final String circuitName = parts[1];
      try {
        final Loader loader = new Loader(null);
        final var file = loader.openLogisimFile(new File(path));
        if (file == null) {
          out.println("FAIL\t" + path + "\t" + circuitName + "\tnull LogisimFile");
          out.flush();
          continue;
        }
        final Project proj = new Project(file);
        final Circuit circuit =
            (circuitName.isEmpty()) ? file.getMainCircuit() : file.getCircuit(circuitName);
        if (circuit == null) {
          out.println("FAIL\t" + path + "\t" + circuitName + "\tno such circuit");
          out.flush();
          continue;
        }
        emitted += table(out, proj, circuit, circuitName);
      } catch (Throwable t) {
        out.println("FAIL\t" + path + "\t" + circuitName + "\t"
            + t.getClass().getSimpleName() + ": " + oneLine(t.getMessage()));
      }
      out.flush();
    }

    // ASSERT THE ORACLE PRODUCED OUTPUT. A drivable entry point that writes nothing and exits 0
    // looks exactly like agreement, and that has caught this project twice.
    if (emitted == 0) {
      System.err.println("BusBridge: produced 0 rows — the oracle did not run, treat as FAILURE");
      out.flush();
      System.exit(2);
    }
    out.flush();
    // Loading a LogisimFile starts AWT's non-daemon EDT; without this the JVM hangs at exit and
    // it looks exactly like a blocking dialog. (CircBridge records the same trap.)
    System.exit(0);
  }

  /** `TtyInterface.doTableAnalysis`, replayed with the oscillation flag exposed. */
  private static int table(PrintStream out, Project proj, Circuit circuit, String label) {
    final Map<Instance, String> pinLabels = Analyze.getPinLabels(circuit);

    final ArrayList<Instance> inputPins = new ArrayList<>();
    final ArrayList<Instance> outputPins = new ArrayList<>();
    final Map<Instance, String> names = new LinkedHashMap<>();
    int inputCount = 0;
    for (final var entry : pinLabels.entrySet()) {
      final var pin = entry.getKey();
      names.put(pin, entry.getValue());
      if (Pin.FACTORY.isInputPin(pin)) {
        inputPins.add(pin);
        inputCount += pin.getAttributeValue(StdAttr.WIDTH).getWidth();
      } else {
        outputPins.add(pin);
      }
    }

    final int rowCount = 1 << inputCount;
    int oscRows = 0;
    for (int i = 0; i < rowCount; i++) {
      // Upstream builds a FRESH root state per row. Carrying one across rows would let a
      // register's contents leak between rows and change every value below.
      final CircuitState circuitState =
          CircuitState.createRootState(proj, circuit, Thread.currentThread());
      final Propagator prop = circuitState.getPropagator();

      int incol = 0;
      final StringBuilder ins = new StringBuilder();
      for (final var pin : inputPins) {
        final int width = pin.getAttributeValue(StdAttr.WIDTH).getWidth();
        final Value[] v = new Value[width];
        for (int b = width - 1; b >= 0; b--) {
          v[b] = TruthTable.isInputSet(i, incol++, inputCount) ? Value.TRUE : Value.FALSE;
        }
        final var pinState = circuitState.getInstanceState(pin);
        Pin.FACTORY.driveInputPin(pinState, Value.create(v));
        ins.append('\t').append(names.get(pin)).append('=').append(Value.create(v).toString());
      }

      prop.propagate();

      final boolean osc = prop.isOscillating();
      if (osc) oscRows++;

      final StringBuilder outs = new StringBuilder();
      for (final var pin : outputPins) {
        final Value val;
        if (osc) {
          val = Value.createError(pin.getAttributeValue(StdAttr.WIDTH));
        } else {
          val = Pin.FACTORY.getValue(circuitState.getInstanceState(pin));
        }
        outs.append('\t').append(names.get(pin)).append('=').append(val.toString());
      }

      out.println("ROW\t" + label + "\t" + i + "\tosc=" + osc + ins + outs);
    }
    out.println("DONE\t" + label + "\t" + rowCount + "\t" + oscRows);
    return rowCount;
  }
}
