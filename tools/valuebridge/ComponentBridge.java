// Enumerates every builtin component and its port/attribute signature from the 4.1.0 jar.
//
// WHY
//
// Six agents are bulk-porting ~350 components. The likeliest failure of a bulk port is SILENT
// OMISSION; a family that returned early looks exactly like one that finished, and no test
// fails because the missing component simply has no test. This produces the manifest to diff
// against, so "did it port everything" becomes a measurement rather than a hope.
//
// It is also the first half of the exhaustive truth-table harness: to drive a component through
// all its input combinations you first need its ports and their widths, which is what this
// emits.
//
// Runs headless: Main.headless = true turns OptionPane dialogs into log lines (see D17), so
// nothing blocks waiting for a click.
//
// Output is one TSV line per component:
//   <library-id> \t <component-name> \t <port-count> \t <ports> \t <attributes>
// where <ports> is a comma-separated list of type:width:exclusive
//   type      IN | OUT | INOUT | UNKNOWN
//   width     the BitWidth the factory declares, or ? if attribute-dependent
//
// Build:
//   javac -cp <logisim-fat.jar> -d out ComponentBridge.java
// Run:
//   java -Djava.awt.headless=true -cp <logisim-fat.jar>:out ComponentBridge

import com.cburch.logisim.comp.ComponentFactory;
import com.cburch.logisim.comp.Component;
import com.cburch.logisim.comp.EndData;
import com.cburch.logisim.circuit.Circuit;
import com.cburch.logisim.circuit.CircuitMutation;
import com.cburch.logisim.circuit.CircuitState;
import com.cburch.logisim.data.Attribute;
import com.cburch.logisim.data.AttributeSet;
import com.cburch.logisim.data.Location;
import com.cburch.logisim.file.Loader;
import com.cburch.logisim.file.LogisimFile;
import com.cburch.logisim.instance.Port;
import com.cburch.logisim.proj.Project;
import com.cburch.logisim.tools.AddTool;
import com.cburch.logisim.tools.Library;
import com.cburch.logisim.tools.Tool;

import java.lang.reflect.Field;
import java.util.ArrayList;
import java.util.List;

public final class ComponentBridge {

  private static final class LiveContext {
    Circuit circuit;
    CircuitState circuitState;

    void initialize() {
      if (circuit != null) return;
      final Loader loader = new Loader(null);
      final LogisimFile file = LogisimFile.createNew(loader, null);
      final Project project = new Project(file);
      circuit = file.getMainCircuit();
      circuit.setProject(project);
      circuitState = CircuitState.createRootState(project, circuit);
    }
  }

  private static String clean(String s) {
    return s == null ? "" : s.replace('\t', ' ').replace('\n', ' ').trim();
  }

  /** Port list, if the factory exposes one. Not every factory does, hence the reflection. */
  @SuppressWarnings("unchecked")
  private static String portsOf(ComponentFactory factory, AttributeSet attrs) {
    final List<String> out = new ArrayList<>();
    try {
      // InstanceFactory keeps its ports in a private `portList`; there is no public accessor
      // that does not require a live Instance, and building one needs a Circuit and a
      // CircuitState. Reflection here is deliberate: the alternative is standing up the whole
      // simulation just to ask a static question.
      Class<?> c = factory.getClass();
      Field f = null;
      while (c != null && f == null) {
        try {
          f = c.getDeclaredField("portList");
        } catch (NoSuchFieldException ignored) {
          c = c.getSuperclass();
        }
      }
      if (f == null) return "?";
      f.setAccessible(true);
      final Object value = f.get(factory);
      if (!(value instanceof List)) return "?";
      for (final Port p : (List<Port>) value) {
        // Port.getType() returns an int (EndData.INPUT_ONLY / OUTPUT_ONLY / INPUT_OUTPUT),
        // not the String constant of the same name. Map it back.
        final String type = switch (p.getType()) {
          case com.cburch.logisim.comp.EndData.INPUT_ONLY -> "IN";
          case com.cburch.logisim.comp.EndData.OUTPUT_ONLY -> "OUT";
          case com.cburch.logisim.comp.EndData.INPUT_OUTPUT -> "INOUT";
          default -> "UNKNOWN";
        };
        String width;
        try {
          width = String.valueOf(p.getFixedBitWidth().getWidth());
        } catch (Throwable t) {
          width = "?";  // attribute-dependent width
        }
        out.add(type + ":" + width);
      }
    } catch (Throwable t) {
      return "?";
    }
    return out.isEmpty() ? "-" : String.join(",", out);
  }

  /** Builds a real component so factories with per-instance ports can configure themselves. */
  private static String livePortsOf(
      ComponentFactory factory, AttributeSet attrs, LiveContext context) {
    Component component = null;
    try {
      context.initialize();
      final Circuit circuit = context.circuit;
      component = factory.createComponent(Location.create(100, 100, true), attrs);
      if (component == null) throw new IllegalStateException("factory returned null component");

      final CircuitMutation add = new CircuitMutation(circuit);
      add.add(component);
      add.execute();

      final List<String> out = new ArrayList<>();
      for (final EndData end : component.getEnds()) {
        final String type = switch (end.getType()) {
          case EndData.INPUT_ONLY -> "IN";
          case EndData.OUTPUT_ONLY -> "OUT";
          case EndData.INPUT_OUTPUT -> "INOUT";
          default -> "UNKNOWN";
        };
        out.add(type + ":" + end.getWidth().getWidth());
      }
      return out.isEmpty() ? "-" : String.join(",", out);
    } finally {
      final Circuit circuit = context.circuit;
      if (component != null && circuit.contains(component)) {
        try {
          final CircuitMutation remove = new CircuitMutation(circuit);
          remove.remove(component);
          remove.execute();
        } catch (Throwable ignored) {
          // Some stateful factories assume simulation data already exists during removal.
          // Their EndData is still valid; the disposable bridge circuit can retain them.
        }
      }
    }
  }

  private static String attributesOf(AttributeSet attrs) {
    if (attrs == null) return "-";
    final List<String> names = new ArrayList<>();
    try {
      for (final Attribute<?> a : attrs.getAttributes()) names.add(clean(a.getName()));
    } catch (Throwable t) {
      return "?";
    }
    return names.isEmpty() ? "-" : String.join(",", names);
  }

  private static void walk(
      Library library, StringBuilder out, LiveContext liveContext) {
    final String libId = clean(library.getName());
    for (final Tool tool : library.getTools()) {
      if (!(tool instanceof AddTool addTool)) continue;
      String name;
      String ports = "?";
      String attributes = "-";
      int portCount = -1;
      try {
        final ComponentFactory factory = addTool.getFactory();
        name = clean(factory.getName());
        final AttributeSet attrs = factory.createAttributeSet();
        ports = portsOf(factory, attrs);
        if ("?".equals(ports) || "-".equals(ports)) {
          try {
            ports = livePortsOf(factory, attrs, liveContext);
          } catch (Throwable t) {
            System.err.println(
                "Cannot enumerate " + libId + "/" + name + ": "
                    + t.getClass().getSimpleName() + ": " + clean(t.getMessage()));
            ports = "?";
          }
        }
        attributes = attributesOf(attrs);
        portCount = "?".equals(ports) || "-".equals(ports) ? -1 : ports.split(",").length;
      } catch (Throwable t) {
        // A factory that cannot even be asked its name is itself worth reporting, not skipping.
        name = clean(tool.getName()) + " !" + t.getClass().getSimpleName();
      }
      out.append(libId).append('\t').append(name).append('\t')
         .append(portCount).append('\t').append(ports).append('\t')
         .append(attributes).append('\n');
    }
    for (final Library sub : library.getLibraries()) walk(sub, out, liveContext);
  }

  public static void main(String[] args) throws Exception {
    // D17: turns every OptionPane dialog into a log line. Without it a warning blocks forever.
    com.cburch.logisim.Main.headless = true;

    final StringBuilder out = new StringBuilder();
    final LiveContext liveContext = new LiveContext();
    final var builtin = new com.cburch.logisim.std.Builtin();
    for (final Library library : builtin.getLibraries()) walk(library, out, liveContext);

    System.out.print(out);
    System.out.flush();
    // Loading initialises AWT and starts the non-daemon event thread; without this the JVM
    // hangs at exit, which looks exactly like a blocking dialog and is not one.
    System.exit(0);
  }
}
