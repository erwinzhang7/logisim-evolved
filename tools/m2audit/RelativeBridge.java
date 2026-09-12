// Drives 4.1.0's own `LibraryManager.toRelative(Loader, File)`; the method that produces the
// string inside `<lib desc="file#...">`: so the D16 audit compares against the shipped jar
// rather than against a reading of the source.
//
// `toRelative` is `private static`, and `Loader.getCurrentDirectory()` derives from `mainFile`,
// which is set by `Loader.setMainFile` (also package-private). Both are reached reflectively;
// declaring the class IN `com.cburch.logisim.file` is not enough for the private method.
//
// The behaviour under test: 4.1.0 canonicalises only the FILE side
// (`file.getCanonicalPath()`) and compares it against the raw `currentDirectory.toString()`.
// 4.2.0-dev canonicalises BOTH. On macOS `/tmp` and `/var` are symlinks into `/private`, so the
// two produce different descriptors for the same pair of paths.
//
// Build:
//   javac -cp <logisim-fat.jar> -d out RelativeBridge.java
// Run:
//   java -Djava.awt.headless=true -cp <logisim-fat.jar>:out \
//        com.cburch.logisim.file.RelativeBridge <mainFile> <libraryFile> [...]
//
// Output: one TSV line per pair: mainFile, libraryFile, descriptor.
// Exits non-zero and prints nothing on failure, so a silent zero-output success is impossible.

package com.cburch.logisim.file;

import java.io.File;
import java.lang.reflect.Method;

public final class RelativeBridge {

  public static void main(String[] args) throws Exception {
    if (args.length < 2 || args.length % 2 != 0) {
      System.err.println("usage: RelativeBridge <mainFile> <libraryFile> [<mainFile> <libraryFile> ...]");
      System.exit(2);
    }

    final Method toRelative =
        LibraryManager.class.getDeclaredMethod("toRelative", Loader.class, File.class);
    toRelative.setAccessible(true);

    final Method setMainFile = Loader.class.getDeclaredMethod("setMainFile", File.class);
    setMainFile.setAccessible(true);

    int emitted = 0;
    for (int i = 0; i < args.length; i += 2) {
      final File mainFile = new File(args[i]);
      final File libFile = new File(args[i + 1]);

      final Loader loader = new Loader(null);
      setMainFile.invoke(loader, mainFile);

      final File cwd = loader.getCurrentDirectory();
      final String result = (String) toRelative.invoke(null, loader, libFile);

      System.out.println(
          args[i] + "\t" + args[i + 1] + "\t" + (cwd == null ? "<null>" : cwd.toString()) + "\t" + result);
      emitted++;
    }

    // ASSERT THE ORACLE PRODUCED OUTPUT; a drivable entry point that writes nothing and exits 0
    // looks exactly like agreement.
    if (emitted == 0) {
      System.err.println("RelativeBridge produced no output");
      System.exit(3);
    }
  }
}
