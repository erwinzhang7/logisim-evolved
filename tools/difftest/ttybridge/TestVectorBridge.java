// Headless test-vector runner; the oracle for `logisim-cli --test`.
//
// WHY THIS EXISTS
//
// Upstream's own flag for this is `-w` / `--test-vector <circuit> <vectorfile> <file.circ>`,
// and MEASURED AGAINST THE 4.1.0 JAR IT DOES NOT WORK HEADLESSLY:
//
//   $ java -Djava.awt.headless=true -jar logisim-evolution-4.1.0-all.jar \
//         --test-vector ripple_carry4 test.txt golden-08.circ
//   Exception in thread "main" java.awt.HeadlessException
//       at java.awt.GraphicsEnvironment.checkHeadless(GraphicsEnvironment.java:164)
//       ...
//       at com.cburch.logisim.gui.generic.OptionPane.showMessageDialog(OptionPane.java:53)
//       at com.cburch.logisim.Main.main(Main.java:81)
//   EXIT=1        (no stdout at all)
//
// The reason is structural, not incidental. `Startup.parseArgs` sets `Main.headless = true`
// ONLY for `-t`/`--tty` and `--test-fpga` (Startup.java:357-360). `--test-vector` leaves it
// false, so the run takes the GUI branch of `Startup.run()`, some dialog fires, the throw
// unwinds into `Main`'s `catch (Throwable)`, and that handler's FIRST act is
// `OptionPane.showMessageDialog(null, ...)`, which with `Main.headless` still false tries to
// build an AWT Frame and throws a SECOND HeadlessException out of the catch block. So
// `System.exit(100)` on the line below it is never reached and the JVM dies with the default
// exit 1. The error the user actually needs is destroyed by the error reporter.
//
// That is the substance of upstream #1546 for a TA: the one flag advertised for automated
// vector checking cannot be run from a script on a headless machine.
//
// THE MACHINERY UNDERNEATH IS FINE. `TestVectorEvaluator` never touches Swing. Setting
// `Main.headless = true` first, D17's switch, exactly as tools/valuebridge/CircBridge.java
// does it, degrades every dialog to a log line and the same code path runs to completion.
// This bridge does that, so the port has a real oracle to diff against.
//
// Protocol: one tab-separated case per line, one result line per input:
//   <circ-path>\t<circuit-name>\t<vector-path>
//     ->  OK\t<circ>\t<circuit>\t<pass>\t<fail>\t<rc>
//     or  FAIL\t<circ>\t<circuit>\t<ExceptionClass>: <message>
//
// `<rc>` is what `Project.doTestVector` returns, which is what upstream would have used as its
// process exit code: the number of FAILING vectors, or -1 if the vector file or the test setup
// could not be loaded.
//
// Build:
//   javac -cp <logisim-fat.jar> -d out TestVectorBridge.java
// Run:
//   java -Djava.awt.headless=true -cp <logisim-fat.jar>:out \
//        com.cburch.logisim.gui.start.TestVectorBridge < cases.tsv

package com.cburch.logisim.gui.start;

import com.cburch.logisim.proj.Project;
import com.cburch.logisim.proj.ProjectActions;
import java.io.BufferedReader;
import java.io.File;
import java.io.InputStreamReader;
import java.io.PrintStream;

public final class TestVectorBridge {

  private static String oneLine(String s) {
    return s == null ? "" : s.replace('\n', ' ').replace('\r', ' ').replace('\t', ' ');
  }

  public static void main(String[] args) throws Exception {
    // D17's dialog switch. Without it this bridge reproduces the very HeadlessException it
    // exists to route around.
    com.cburch.logisim.Main.headless = true;

    final BufferedReader in = new BufferedReader(new InputStreamReader(System.in));
    final PrintStream out = System.out;

    String line;
    while ((line = in.readLine()) != null) {
      line = line.trim();
      if (line.isEmpty()) continue;
      if (line.equals("PING")) {
        out.println("PONG");
        out.flush();
        continue;
      }

      final String[] parts = line.split("\t");
      if (parts.length != 3) {
        out.println("FAIL\t" + oneLine(line) + "\t\tbad-line (expected circ<TAB>circuit<TAB>vector)");
        out.flush();
        continue;
      }
      final String circPath = parts[0];
      final String circuitName = parts[1];
      final String vectorPath = parts[2];

      try {
        // A fresh Loader per case, for the same reason CircBridge uses one: shared
        // library-resolution state between files is exactly the kind of order dependence that
        // makes a baseline irreproducible.
        final Project proj = ProjectActions.doOpenNoWindow(null, new File(circPath));

        // `Project.doTestVector` prints its own progress to stdout (`testLoadingVector`,
        // `testRunning`, a per-row counter, `testResults`). That would interleave with this
        // bridge's protocol, so it is captured and discarded here; the numbers the gate needs
        // are recovered from the return code and from a second evaluation below.
        final java.io.PrintStream real = System.out;
        final java.io.ByteArrayOutputStream sink = new java.io.ByteArrayOutputStream();
        final int rc;
        try {
          System.setOut(new PrintStream(sink, true, "UTF-8"));
          rc = proj.doTestVector(vectorPath, circuitName);
        } finally {
          System.setOut(real);
        }

        // Recover pass/fail from upstream's own summary line rather than recomputing it: the
        // point of an oracle is to report what upstream said, not what we think it meant.
        // `testResults = Passed: %s, Failed: %s`.
        final String captured = sink.toString("UTF-8");
        int pass = -1;
        int fail = -1;
        for (final String l : captured.split("\n")) {
          final int p = l.indexOf("Passed: ");
          if (p < 0) continue;
          final String rest = l.substring(p + "Passed: ".length());
          final int comma = rest.indexOf(',');
          if (comma < 0) continue;
          try {
            pass = Integer.parseInt(rest.substring(0, comma).trim());
            final int f = rest.indexOf("Failed: ");
            if (f >= 0) fail = Integer.parseInt(rest.substring(f + "Failed: ".length()).trim());
          } catch (NumberFormatException ignored) {
            // leave -1; the caller can see the summary line was not parseable
          }
        }

        // The RAW stdout, base64'd, is the actual oracle. Pass/fail/rc are a convenience for
        // reading the log; the gate diffs these bytes, because a port that produced the right
        // two numbers with different text would otherwise pass.
        //
        // Base64 rather than an escaped form because upstream's per-row progress counter emits
        // bare carriage returns (`System.out.print((row + 1) + " \r")`), and any line-oriented
        // encoding of this protocol would mangle them, which would then be "fixed" on the port
        // side to match the mangling.
        final String b64 = java.util.Base64.getEncoder()
            .encodeToString(captured.getBytes("UTF-8"));
        out.println("OK\t" + circPath + "\t" + circuitName + "\t" + pass + "\t" + fail + "\t" + rc
            + "\t" + b64);
      } catch (Throwable t) {
        out.println("FAIL\t" + circPath + "\t" + circuitName + "\t"
            + t.getClass().getSimpleName() + ": " + oneLine(t.getMessage()));
      }
      out.flush();
    }

    // MUST exit explicitly; loading a LogisimFile starts the non-daemon EDT, and without this
    // every case succeeds and the JVM then hangs at exit, which looks exactly like a blocking
    // dialog and is not one. (tools/valuebridge/CircBridge.java records the same trap.)
    out.flush();
    System.exit(0);
  }
}
