// Dumps every builtin library's and every tool's DISPLAY name from the 4.1.0 jar.
//
// WHY
//
// `ComponentFactory.getName()` is the `.circ` token (`_ID`) and `getDisplayName()` is the
// localised string the explorer, the palette, the tooltips and `-tty stats` all print. The two
// are equal only for the factories whose constructor did not pass an explicit `StringGetter`
// (`AbstractComponentFactory.getDisplayGetter()` = `constantGetter(getName())`). For everything
// that DID pass one, `super(_ID, S.getter("dipswitchComponent"))`, the two differ, and a port
// that answers `_ID` everywhere shows programmer identifiers to the user.
//
// The mapping lives in `.properties` resource bundles, not in the Java source, so reading the
// source gives you the KEY and not the STRING. This asks the running jar instead, which resolves
// the bundle exactly as the app does. That is the whole point: the answer is measured, never
// transcribed.
//
// Runs headless: Main.headless = true turns OptionPane dialogs into log lines (see D17).
//
// Output is TSV, one line per record:
//   LIB  \t <parent-lib-id>   \t <lib._ID>     \t <lib.getDisplayName()>
//   TOOL \t <owning-lib-id>   \t <tool.getName()> \t <tool.getDisplayName()> \t <factory.getDisplayName()> \t <factory-class>
//
// The last two columns are NOT redundant, and that is the finding this bridge exists to make
// visible. `AddTool.getDisplayName()` returns `desc.getDisplayName()` when the tool was built
// from a `FactoryDescription` and only otherwise falls through to the factory. Upstream then
// passes DIFFERENT bundle keys to the two: `IoLibrary` declares
// `new FactoryDescription(DipSwitch.class, S.getter("dipswitchComponent"), …)` while
// `DipSwitch`'s own constructor passes `S.getter("DipSwitchComponent")`: keys differing only
// in one capital letter, resolving to "Dip switch" and "DIP Switch" respectively. So the
// explorer sidebar and `-tty stats` genuinely print different strings for the same component
// (`TtyInterface.java:86,104` uses `count.getFactory().getDisplayName()`;
// `Toolbox`/`ExplorerSidebar` use the Tool's). A port that collapses them into one string is
// wrong for one of the two consumers no matter which it picks.
//
// Build:
//   javac -cp <logisim-fat.jar> -d out NameBridge.java
// Run:
//   java -Djava.awt.headless=true -cp <logisim-fat.jar>:out NameBridge

import com.cburch.logisim.comp.ComponentFactory;
import com.cburch.logisim.tools.AddTool;
import com.cburch.logisim.tools.Library;
import com.cburch.logisim.tools.Tool;

public final class NameBridge {

  private static String clean(String s) {
    return s == null ? "" : s.replace('\t', ' ').replace('\n', ' ').trim();
  }

  private static void walk(Library library, String parentId, StringBuilder out) {
    final String libId = clean(library.getName());
    out.append("LIB\t").append(parentId).append('\t')
       .append(libId).append('\t')
       .append(clean(library.getDisplayName())).append('\n');

    for (final Tool tool : library.getTools()) {
      String factoryClass = "-";
      String factoryDisplay = "-";
      if (tool instanceof AddTool addTool) {
        try {
          final ComponentFactory factory = addTool.getFactory();
          factoryClass = factory == null ? "-" : factory.getClass().getName();
          factoryDisplay = factory == null ? "-" : clean(factory.getDisplayName());
        } catch (Throwable t) {
          factoryClass = "!" + t.getClass().getSimpleName();
          factoryDisplay = factoryClass;
        }
      }
      String name;
      String display;
      try {
        name = clean(tool.getName());
      } catch (Throwable t) {
        name = "!" + t.getClass().getSimpleName();
      }
      try {
        display = clean(tool.getDisplayName());
      } catch (Throwable t) {
        display = "!" + t.getClass().getSimpleName();
      }
      out.append("TOOL\t").append(libId).append('\t')
         .append(name).append('\t').append(display).append('\t')
         .append(factoryDisplay).append('\t')
         .append(factoryClass).append('\n');
    }
    for (final Library sub : library.getLibraries()) walk(sub, libId, out);
  }

  public static void main(String[] args) throws Exception {
    // D17: turns every OptionPane dialog into a log line. Without it a warning blocks forever.
    com.cburch.logisim.Main.headless = true;

    final StringBuilder out = new StringBuilder();
    final var builtin = new com.cburch.logisim.std.Builtin();
    out.append("LIB\t-\t").append(clean(builtin.getName())).append('\t')
       .append(clean(builtin.getDisplayName())).append('\n');
    for (final Library library : builtin.getLibraries()) walk(library, clean(builtin.getName()), out);

    if (out.length() == 0) {
      System.err.println("NameBridge produced NO output — refusing to exit 0");
      System.exit(3);
    }
    System.out.print(out);
    System.out.flush();
    // Loading initialises AWT and starts the non-daemon event thread; without this the JVM
    // hangs at exit, which looks exactly like a blocking dialog and is not one.
    System.exit(0);
  }
}
