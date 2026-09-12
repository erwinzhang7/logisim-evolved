// Headless .circ converter; a dialog-free replacement for `-jar logisim.jar -n in out`.
//
// WHY THIS EXISTS
//
// `-n` routes through ProjectActions.doOpen, which builds a Project with a Frame, so it
// requires a GUI session. Two consequences made it unusable for generating gate baselines
// across a corpus:
//
//   1. Every file with source < 2.7.2 pops a modal "Old file format -- compatibility mode"
//      warning (XmlReader.java:405), and every file naming a library this build does not
//      have (#MIPS Tools, #Yosys Components, #Risc-V appear in the corpus) pops
//      "The built-in library X is not available in this version". Both block forever
//      waiting for a click, at whoever happens to be at the keyboard.
//   2. One JVM per conversion, so ~0.9 s of startup dominated the actual work.
//
// Under -Djava.awt.headless=true, logisim's OptionPane degrades those dialogs to log lines
// instead of showing them: verified: "[main] WARN ... OptionPane - Old file format". The
// load itself succeeds. So loading through the file layer (Loader + LogisimFile) rather than
// the project layer gets identical output with no window and no dialog.
//
// It also batches: one JVM converts every pair on stdin.
//
// Protocol: one tab-separated pair per line, one result line per input:
//   <in-path>\t<out-path>   ->   OK <in-path>
//                            or  FAIL <in-path>\t<ExceptionClass>: <message>
//
// Build:
//   javac -cp <logisim-fat.jar> -d out CircBridge.java
// Run:
//   java -Djava.awt.headless=true -cp <logisim-fat.jar>:out CircBridge < pairs.tsv

// Declared IN com.cburch.logisim.file because 4.1.0's LogisimFile.write overloads are all
// package-private. (Main-branch 4.2.0-dev added a public write(OutputStream, LibraryLoader,
// File); the shipped 4.1.0 jar has no such overload. The jar is the oracle, so 4.1.0 wins.)
package com.cburch.logisim.file;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.io.PrintStream;

public final class CircBridge {

  private static String oneLine(String s) {
    return s == null ? "" : s.replace('\n', ' ').replace('\r', ' ').replace('\t', ' ');
  }

  public static void main(String[] args) throws Exception {
    // THE DIALOG SWITCH. OptionPane gates every dialog on Main.hasGui():
    //
    //     if (Main.hasGui()) { JOptionPane.showMessageDialog(...); }   // modal, blocks
    //     else if (message instanceof String msg) { logger.info(msg); } // just a log line
    //
    // `Main.headless` is a public static field and `hasGui()` is `!headless`, so setting it
    // turns every warning into a log line: the pre-2.7.2 "Old file format" notice, the
    // "built-in library X is not available" notice, and the file-error reports. Without it
    // the JVM either blocks on a modal dialog (with a display) or throws HeadlessException
    // (without one), and neither produces a converted file.
    com.cburch.logisim.Main.headless = true;

    final BufferedReader in = new BufferedReader(new InputStreamReader(System.in));
    final PrintStream out = System.out;

    String line;
    while ((line = in.readLine()) != null) {
      line = line.trim();
      if (line.isEmpty()) continue;
      if (line.equals("PING")) { out.println("PONG"); out.flush(); continue; }

      final String[] parts = line.split("\t");
      if (parts.length != 2) {
        out.println("FAIL\t" + oneLine(line) + "\tbad-line (expected in<TAB>out)");
        out.flush();
        continue;
      }
      final String src = parts[0];
      final String dst = parts[1];

      try {
        // A fresh Loader per file. Sharing one across files would let library resolution
        // and substitution state from an earlier file leak into a later one, which is
        // exactly the kind of order dependence that makes a baseline irreproducible.
        final Loader loader = new Loader(null);
        final LogisimFile file = loader.openLogisimFile(new File(src));
        if (file == null) {
          out.println("FAIL\t" + src + "\tnull LogisimFile (load reported an error)");
          out.flush();
          continue;
        }
        final File destFile = new File(dst);
        try (OutputStream os = new FileOutputStream(destFile)) {
          // 4.1.0: write(OutputStream, LibraryLoader, File dest, String mainCircFile)
          file.write(os, loader, destFile, null);
        }
        out.println("OK\t" + src);
      } catch (Throwable t) {
        out.println("FAIL\t" + src + "\t" + t.getClass().getSimpleName()
                    + ": " + oneLine(t.getMessage()));
      }
      out.flush();
    }

    // MUST exit explicitly. Loading a LogisimFile initialises AWT/Swing machinery, which
    // starts the non-daemon Event Dispatch Thread; without this the conversions all succeed
    // and the JVM then hangs forever at exit. That looks exactly like a blocking dialog;
    // it is not one, and chasing it as a dialog wastes time.
    out.flush();
    System.exit(0);
  }
}
