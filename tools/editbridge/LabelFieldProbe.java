// LabelFieldProbe: part of logisim-evolved. Test/measurement tooling, not a port of anything.
//
// Answers one question against the real 4.1.0 jar, for every factory named on the command line:
//
//     does a placed instance of this component have a label text field at all?
//
// D18 requires a divergence to be MEASURED against the jar rather than argued from reading, and
// this exists because the reading and the measurement can disagree. The reading here is:
// `InstanceComponent.textField` is private, null-initialised (:73), and written in exactly one
// place (:448, inside the package-private `setTextField`), reachable only from
// `Instance.setTextField` (:107) and `Instance.computeLabelTextField` (:172). A factory that calls
// neither therefore has no field, and `InstanceComponent.drawLabel` (:252) returns early on null,
// so its `painter.drawLabel()` is dead code.
//
// That argument is sound and it is still only an argument. This probe asks the jar instead.
//
// HOW IT ASKS. `InstanceComponent.getFeature(TextEditable.class)` returns the field itself
// (:370-371), so a non-null answer means "this component has a label field" and null means it has
// none. That is exactly the predicate `drawLabel` branches on, which is what makes this a
// measurement of the drawing behaviour and not a proxy for it. No rendering is needed, and no
// Graphics is available headlessly anyway.
//
// Deliberately NOT reused from EditBridge: this needs no Project, no Canvas and no Frame, so it
// stays a plain instantiation with none of that class's three headless concessions. It shares only
// `MemoryPreferences`, and for the same reason; `AppPreferences.getPrefs()` is the developer's
// real Logisim preferences, and a probe that reads host state is not measuring the jar.
//
//   sh tools/editbridge/build.sh
//   java -cp "$JAR:tools/editbridge/out" LabelFieldProbe "Buffer" "AND Gate" "Register"

import com.cburch.logisim.comp.Component;
import com.cburch.logisim.comp.ComponentFactory;
import com.cburch.logisim.data.AttributeSet;
import com.cburch.logisim.data.Location;
import com.cburch.logisim.tools.AddTool;
import com.cburch.logisim.tools.Library;
import com.cburch.logisim.tools.TextEditable;
import com.cburch.logisim.tools.Tool;
import java.util.List;

public final class LabelFieldProbe {

  public static void main(String[] args) throws Exception {
    // `MemoryPreferences` is installed the way EditBridge does it: by the JVM property
    // `-Djava.util.prefs.PreferencesFactory=MemoryPreferences$Factory` on the command line, not by
    // a call. Assert it took, because silently falling back to the real store would mean this
    // probe reads the developer's own Logisim preferences.
    if (!(java.util.prefs.Preferences.userRoot() instanceof MemoryPreferences)) {
      System.err.println(
          "refusing to run: java.util.prefs.PreferencesFactory is not MemoryPreferences$Factory, "
              + "so this would read the developer's real Logisim preferences");
      System.exit(2);
    }

    // The libraries are instantiated DIRECTLY rather than through `LogisimFile.createNew`, which
    // hangs here: it loads the default template and reaches machinery this probe has no need of.
    // Every factory we care about is published by one of these five `Library.getTools()` lists,
    // which is the same route the explorer uses.
    final List<Library> libraries =
        List.of(
            new com.cburch.logisim.std.gates.GatesLibrary(),
            new com.cburch.logisim.std.memory.MemoryLibrary(),
            new com.cburch.logisim.std.wiring.WiringLibrary(),
            new com.cburch.logisim.std.io.IoLibrary(),
            new com.cburch.logisim.std.io.extra.ExtraIoLibrary(),
            new com.cburch.logisim.std.ttl.TtlLibrary(),
            new com.cburch.logisim.std.plexers.PlexersLibrary(),
            new com.cburch.logisim.std.arith.ArithmeticLibrary(),
            new com.cburch.logisim.std.arith.floating.FPArithmeticLibrary(),
            new com.cburch.logisim.std.bfh.BfhLibrary(),
            new com.cburch.logisim.std.tcl.TclLibrary(),
            new com.cburch.logisim.std.hdl.HdlLibrary());

    // No arguments: enumerate EVERY factory in every library and report each. That is the mode
    // that matters, because the whole reason this probe exists is that a grep for the installing
    // call misses factories that install via a helper: `Buffer` and `ControlledBuffer` reach
    // `setTextField` through `NotGate.configureLabel`, two hops from the name being searched for.
    // Asking the jar about every factory cannot miss a hop.
    final List<String> wantedNames = new java.util.ArrayList<>();
    if (args.length > 0) {
      wantedNames.addAll(List.of(args));
    } else {
      for (final Library lib : libraries) collectNames(lib, wantedNames);
      java.util.Collections.sort(wantedNames);
    }

    int withField = 0;
    for (final var wanted : wantedNames) {
      final var factory = findFactory(libraries, wanted);
      if (factory == null) {
        System.out.println(pad(wanted) + "NOT FOUND");
        continue;
      }

      // A bare instantiation: exactly what dropping the component on a canvas produces, minus the
      // canvas. `configureNewInstance` is what installs a text field when the factory installs one.
      final AttributeSet attrs = factory.createAttributeSet();
      final Component comp = factory.createComponent(Location.create(100, 100, false), attrs);

      final var field = comp.getFeature(TextEditable.class);
      if (field != null) withField++;
      System.out.println(
          pad(wanted)
              + (field == null ? "NO  label field" : "HAS label field")
              + "   factory=" + factory.getClass().getName());
    }
    System.out.println();
    System.out.println(withField + " of " + wantedNames.size() + " factories have a label field");
  }

  /** Every factory name published by this library and its sub-libraries. */
  private static void collectNames(Library lib, List<String> into) {
    for (final Tool tool : lib.getTools()) {
      if (tool instanceof AddTool add) {
        final var factory = add.getFactory();
        if (factory != null && factory.getName() != null && !into.contains(factory.getName())) {
          into.add(factory.getName());
        }
      }
    }
    for (final Library sub : lib.getLibraries()) collectNames(sub, into);
  }

  /** Walk the given libraries, looking for an AddTool whose factory has this name. */
  private static ComponentFactory findFactory(List<Library> libraries, String name) {
    for (final Library lib : libraries) {
      final var hit = findIn(lib, name);
      if (hit != null) return hit;
    }
    return null;
  }

  private static ComponentFactory findIn(Library lib, String name) {
    for (final Tool tool : lib.getTools()) {
      if (tool instanceof AddTool add) {
        final var factory = add.getFactory();
        if (factory != null && name.equals(factory.getName())) return factory;
      }
    }
    for (final Library sub : lib.getLibraries()) {
      final var hit = findIn(sub, name);
      if (hit != null) return hit;
    }
    return null;
  }

  private static String pad(String s) {
    final var sb = new StringBuilder(s);
    while (sb.length() < 24) sb.append(' ');
    return sb.toString();
  }
}
