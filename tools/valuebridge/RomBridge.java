// Dumps the real 4.1.0 port GEOMETRY of every memory component in a .circ file.
//
// WHY
//
// `tools/difftest/BoundsOracle.java` compares `getOffsetBounds` and nothing else. Nothing in this
// project has ever compared *port* geometry against upstream, and port geometry is what decides
// whether a component's output lands on the net the file's wires are on. A ROM whose data-out
// port is 10 units to the right of the wire drives nothing, and every reader downstream sees `U`,
// which is indistinguishable, from the truth table alone, from a propagation bug.
//
// This asks the jar directly: for each memory component actually placed in a real corpus file,
// where does 4.1.0 put its ends? The port can then be diffed against literal upstream output
// instead of against a reading of RamAppearance.java.
//
// Loads through Loader + LogisimFile (not the raw XML) so that attribute defaulting, the
// RomAttributes/RamAttributes split and appearance migration all run exactly as they do in the
// app. Main.headless = true per D17, or a corpus file with a stale-version warning pops a modal
// dialog and the run hangs forever with no output.
//
// Output, one line per placed memory component:
//   <file> \t <circuit> \t <factory> \t <appearance> \t loc=(x,y) \t bounds=x,y,WxH \t ends=[(x,y)Dw ...]
// where D is I/O/B for input/output/inout and w the width. Nothing else is printed to stdout, so
// an empty stdout means the run did no work: assert on it, do not read it as agreement.
//
// Build:
//   javac -cp <logisim-fat.jar> -d out RomBridge.java
// Run:
//   java -Djava.awt.headless=true -cp <logisim-fat.jar>:out RomBridge <file.circ> [more.circ ...]

import com.cburch.logisim.circuit.Circuit;
import com.cburch.logisim.comp.Component;
import com.cburch.logisim.comp.EndData;
import com.cburch.logisim.data.AttributeSet;
import com.cburch.logisim.data.Bounds;
import com.cburch.logisim.file.Loader;
import com.cburch.logisim.file.LogisimFile;
import com.cburch.logisim.instance.StdAttr;

import java.io.File;
import java.util.ArrayList;
import java.util.List;

public final class RomBridge {

  /** Factory names whose geometry this cares about. Everything else in the file is skipped. */
  private static boolean isMemory(String name) {
    return name.equals("ROM")
        || name.equals("RAM")
        || name.equals("Register")
        || name.equals("Counter")
        || name.equals("Shift Register")
        || name.equals("Random");
  }

  private static String endsOf(Component comp) {
    final List<String> out = new ArrayList<>();
    for (final EndData end : comp.getEnds()) {
      final String dir =
          end.isInput() && end.isOutput() ? "B" : end.isOutput() ? "O" : "I";
      out.add(
          "("
              + end.getLocation().getX()
              + ","
              + end.getLocation().getY()
              + ")"
              + dir
              + "w"
              + end.getWidth().getWidth());
    }
    return String.join(" ", out);
  }

  private static String appearanceOf(AttributeSet attrs) {
    try {
      final Object v = attrs.getValue(StdAttr.APPEARANCE);
      return v == null ? "-" : v.toString();
    } catch (Exception e) {
      return "?";
    }
  }

  public static void main(String[] args) throws Exception {
    // D17: without this a corpus file saved by an older version pops a modal dialog on a headless
    // JVM and the process never returns. `Main.headless` is public static; `hasGui()` is its
    // negation, and OptionPane checks it before every dialog.
    com.cburch.logisim.Main.headless = true;

    int emitted = 0;
    for (final String path : args) {
      final File src = new File(path);
      // A fresh Loader per file: a shared one lets one file's library resolution leak into the
      // next, which is the same aliasing hazard CircBridge documents.
      final Loader loader = new Loader(null);
      final LogisimFile file;
      try {
        file = loader.openLogisimFile(src);
      } catch (Exception e) {
        System.err.println("LOAD-FAIL\t" + path + "\t" + e);
        continue;
      }
      for (final Circuit circuit : file.getCircuits()) {
        for (final Component comp : circuit.getNonWires()) {
          final String name = comp.getFactory().getName();
          if (!isMemory(name)) continue;
          final Bounds b = comp.getBounds();
          System.out.println(
              src.getName()
                  + "\t"
                  + circuit.getName()
                  + "\t"
                  + name
                  + "\t"
                  + appearanceOf(comp.getAttributeSet())
                  + "\tloc=("
                  + comp.getLocation().getX()
                  + ","
                  + comp.getLocation().getY()
                  + ")\tbounds="
                  + b.getX()
                  + ","
                  + b.getY()
                  + ","
                  + b.getWidth()
                  + "x"
                  + b.getHeight()
                  + "\tends=["
                  + endsOf(comp)
                  + "]");
          emitted++;
        }
      }
    }
    // A drivable-looking entry point that writes nothing and exits 0 looks exactly like
    // agreement. Fail loudly instead.
    System.err.println("emitted " + emitted + " component lines from " + args.length + " file(s)");
    System.out.flush();
    // `System.exit`, not a return: loading a LogisimFile starts non-daemon AWT/Swing threads even
    // under -Djava.awt.headless=true, so `main` returning does NOT end the JVM. Observed directly
    // ; a run that had already printed its lines sat live for minutes afterwards, which in a loop
    // over corpus files looks exactly like the loop being stuck on the NEXT file.
    System.exit(emitted == 0 ? 3 : 0);
  }
}
