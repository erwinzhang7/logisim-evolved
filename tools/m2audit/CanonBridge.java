// Prints `new File(arg).getCanonicalPath()` for each argument, so `LibraryManager
// .javaCanonicalPath` can be diffed against the JVM rather than against a reading of
// `canonicalize_md.c`.
//
// WHY A SEPARATE BRIDGE FROM RelativeBridge
//
// `RelativeBridge` exercises the whole of `toRelative`, which mixes two behaviours: which side
// gets canonicalised (the D16 defect) and what canonicalising *means*. When the two are tested
// together a compensating error in one hides an error in the other. This isolates the second.
//
// It matters because the obvious Swift substitutes are both wrong in ways that only show up on
// specific inputs:
//
//   * `URL.resolvingSymlinksInPath()` refuses to resolve /tmp and /var,
//   * `realpath(3)` alone fails outright when the leaf does not exist (every save-as target).
//
// No logisim classes are used, so this needs no jar on the classpath, but it is kept next to
// the other m2audit bridges because it exists for the same measurement.
//
// Build:
//   javac -d out CanonBridge.java
// Run:
//   java -cp out CanonBridge <path> [<path> ...]
//
// Output: one TSV line per argument: input, canonical (or "<IOException>").
// Exits non-zero and prints nothing when given no arguments, so a silent zero-output run
// cannot be mistaken for agreement.

import java.io.File;
import java.io.IOException;

public final class CanonBridge {

  public static void main(String[] args) {
    if (args.length == 0) {
      System.err.println("usage: CanonBridge <path> [<path> ...]");
      System.exit(2);
    }

    int emitted = 0;
    for (final String arg : args) {
      String result;
      try {
        result = new File(arg).getCanonicalPath();
      } catch (IOException e) {
        // toRelative catches exactly this and keeps `file.toString()`; the Swift returns nil.
        result = "<IOException>";
      }
      System.out.println(arg + "\t" + result);
      emitted++;
    }

    // ASSERT THE ORACLE PRODUCED OUTPUT; an entry point that writes nothing and exits 0 looks
    // exactly like agreement.
    if (emitted == 0) {
      System.err.println("CanonBridge produced no output");
      System.exit(3);
    }
  }
}
