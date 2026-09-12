// Headless per-component HDL-generator oracle for the gates / wiring / plexers families;
// dumps exactly what the shipped 4.1.0 jar's own generator classes emit.
//
// WHY THIS EXISTS
//
// The Swift port has to reproduce `AbstractGateHdlGenerator`, the five plexer generators and the
// three wiring generators byte for byte. Reading the Java and transcribing it is not evidence:
// the output is threaded through LineBuffer's `{{key}}` substitution, Hdl's VHDL/Verilog
// branching, HdlPorts' sorted key sets and HdlParameters' generic-value formulas, and every one
// of those is a place where a plausible transcription silently differs by a space. HDL text is
// exactly diffable, so the honest check is to run upstream's own class and diff.
//
// Same two load-bearing tricks as NetlistBridge.java / CircBridge.java: `Main.headless = true`
// so no dialog can block, and an explicit System.exit(0) because touching a component factory
// initialises AWT and starts the non-daemon event dispatch thread (the JVM would otherwise hang
// at exit, looking exactly like a modal dialog).
//
// Declared in com.cburch.logisim.std.gates so it can see the package-private gate factories
// (`class AndGate`, `class OrGate`, ...) that GatesLibrary hands out only as Tools; it reaches
// the plexer and wiring factories through their public libraries.
//
// Build:
//   javac -cp <logisim-fat.jar> -d out GatesBridge.java
// Run:
//   java -Djava.awt.headless=true -cp <logisim-fat.jar>:out \
//        com.cburch.logisim.std.gates.GatesBridge > gates-4.1.0.oracle
//
// Output is a flat line protocol. Every case is a `CASE <lang> <factory> <attr=val,...>` header
// followed by tagged text blocks; `.` marks an empty block so a block that produced nothing is
// distinguishable from a block that was never attempted. That distinction is the whole point:
// this project has already been bitten by an oracle that wrote nothing and exited 0.

package com.cburch.logisim.std.gates;

import com.cburch.logisim.circuit.Circuit;
import com.cburch.logisim.comp.ComponentFactory;
import com.cburch.logisim.data.Attribute;
import com.cburch.logisim.data.AttributeSet;
import com.cburch.logisim.data.BitWidth;
import com.cburch.logisim.fpga.designrulecheck.Netlist;
import com.cburch.logisim.fpga.hdlgenerator.HdlGeneratorFactory;
import com.cburch.logisim.prefs.AppPreferences;
import com.cburch.logisim.tools.AddTool;
import com.cburch.logisim.tools.Library;
import com.cburch.logisim.tools.Tool;
import java.io.PrintStream;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

public final class GatesBridge {

  private static PrintStream out;
  /** Every emitted CASE, counted, so a silent zero-output run cannot look like a pass. */
  private static int caseCount = 0;
  private static int blockCount = 0;

  // ── factory lookup ───────────────────────────────────────────────────────────────────────

  private static final Map<String, ComponentFactory> FACTORIES = new LinkedHashMap<>();

  private static void harvest(Library lib) {
    for (final Tool tool : lib.getTools()) {
      if (tool instanceof final AddTool addTool) {
        final ComponentFactory factory = addTool.getFactory();
        FACTORIES.put(factory.getName(), factory);
      }
    }
  }

  // ── attribute helpers ────────────────────────────────────────────────────────────────────

  /** Set an attribute by its `.circ` name, parsing the value the same way the loader would. */
  @SuppressWarnings({"unchecked", "rawtypes"})
  private static void set(AttributeSet attrs, String name, String value) {
    for (final Attribute<?> attr : attrs.getAttributes()) {
      if (attr.getName().equals(name)) {
        final Object parsed = attr.parse(value);
        attrs.setValue((Attribute) attr, parsed);
        return;
      }
    }
    throw new IllegalArgumentException("no attribute '" + name + "' on this set");
  }

  private static boolean has(AttributeSet attrs, String name) {
    for (final Attribute<?> attr : attrs.getAttributes()) {
      if (attr.getName().equals(name)) return true;
    }
    return false;
  }

  /**
   * Every attribute on the set, as `name=standardString`, sorted. `Attributes.forNoSave()` builds
   * attributes whose `getName()` is null (BitSelector's SELECT_ATTR / EXTENDED_ATTR), so those are
   * reported positionally as `?<n>` rather than dropped; they feed generic values and a
   * disagreement about them changes the emitted HDL.
   */
  private static void dumpAttrs(AttributeSet attrs) {
    final List<String> entries = new ArrayList<>();
    int anonymous = 0;
    for (final Attribute<?> attr : attrs.getAttributes()) {
      final String name = attr.getName() == null ? "?" + (anonymous++) : attr.getName();
      // `labelfont` renders as `java.awt.Font[family=…]`, a JDK toString the port has no reason
      // to reproduce, and no generator in these families reads it. Recorded as present but not
      // compared, so its absence from the diff is deliberate rather than an oversight.
      if ("labelfont".equals(name)) {
        entries.add(name + "=<font>");
        continue;
      }
      final Object value = attrs.getValue(attr);
      // PLA's table attribute stringifies to multi-line text. Left raw it would break the
      // one-record-per-line invariant the whole protocol rests on; the file would still *diff*
      // cleanly, but a consumer comparing records against lines would silently misalign by the
      // number of embedded newlines. Escaped, exactly as the block() bodies are.
      final String text = value == null ? "null" : value.toString();
      entries.add(name + "="
          + text.replace("\\", "\\\\").replace("\n", "\\n").replace("\r", "\\r"));
    }
    java.util.Collections.sort(entries);
    out.println("  ATTRS " + String.join(",", entries));
  }

  // ── emission ─────────────────────────────────────────────────────────────────────────────

  private static void block(String tag, List<String> lines) {
    blockCount++;
    if (lines == null) {
      out.println("  " + tag + " null");
      return;
    }
    if (lines.isEmpty()) {
      out.println("  " + tag + " .");
      return;
    }
    out.println("  " + tag + " " + lines.size());
    // A LineBuffer element can itself contain newlines (Hdl.getExtendedLibrary adds one
    // multi-line string as a single entry). Escaping keeps one element on one physical line, so
    // a diff cannot silently realign across an element boundary.
    for (final String line : lines) {
      out.println("    |" + line.replace("\\", "\\\\").replace("\n", "\\n").replace("\r", "\\r"));
    }
  }

  /**
   * Runs every generator entry point that does not need a wired-up netlistComponent. The inlined
   * generators (Buffer, NOT, Controlled Buffer, Constant, Power, Ground, Bit Extender) have no
   * meaningful output here, they only implement getInlinedCode, so this records their identity
   * facts and the fact that they are inline-only, which the Swift side must also report.
   */
  private static void emit(String factoryName, ComponentFactory factory, String descr,
      AttributeSet attrs, Netlist nets) {
    final HdlGeneratorFactory generator = factory.getHDLGenerator(attrs);
    caseCount++;
    out.println("CASE " + (com.cburch.logisim.fpga.hdlgenerator.Hdl.isVhdl() ? "VHDL" : "VERILOG")
        + " " + factoryName + " " + descr);
    // The exact attribute set every block below was computed from. Without this a Swift-side
    // disagreement about a *default* (BitSelector's forNoSave select/extended widths, say) reads
    // as a generator bug, and the two sides can silently be testing different inputs.
    dumpAttrs(attrs);
    if (generator == null) {
      out.println("  GENERATOR null");
      return;
    }
    out.println("  GENERATOR " + generator.getClass().getSimpleName());
    out.println("  ONLYINLINED " + generator.isOnlyInlined());
    out.println("  SUPPORTEDTARGET " + generator.isHdlSupportedTarget(attrs));
    out.println("  HDLNAME " + factory.getHDLName(attrs));
    if (generator.isOnlyInlined()) {
      // getRelativeDirectory/getEntity/... all throw IllegalAccessError for these; recording
      // that they are inline-only is the whole contract the Swift side owes.
      return;
    }
    out.println("  RELDIR " + generator.getRelativeDirectory());
    final String compName = factory.getHDLName(attrs);
    try {
      block("ENTITY", generator.getEntity(nets, attrs, compName));
    } catch (Throwable t) {
      out.println("  ENTITY throw " + t.getClass().getSimpleName());
    }
    try {
      block("ARCH", generator.getArchitecture(nets, attrs, compName));
    } catch (Throwable t) {
      out.println("  ARCH throw " + t.getClass().getSimpleName());
    }
    try {
      block("INST", generator.getComponentInstantiation(nets, attrs, compName).get());
    } catch (Throwable t) {
      out.println("  INST throw " + t.getClass().getSimpleName());
    }
    // getComponentMap is deliberately NOT exercised here. With a null componentInfo Java throws
    // NullPointerException for 784 of the 856 cases (its parameter-value formulas dereference
    // the absent attribute set), so the block carries no information about agreement, and
    // driving it needs a placed, connected component, which is the netlist-level gate's job.
  }

  // ── the case matrix ──────────────────────────────────────────────────────────────────────

  private static final String[] GATE_NAMES = {
    "AND Gate", "OR Gate", "NAND Gate", "NOR Gate", "XOR Gate", "XNOR Gate",
    "Odd Parity", "Even Parity",
  };

  private static final String[] INLINE_NAMES = {
    "Buffer", "NOT Gate", "Controlled Buffer", "Controlled Inverter",
    "Constant", "Power", "Ground", "NoConnect", "Bit Extender",
  };

  private static final String[] PLEXER_NAMES = {
    "Multiplexer", "Demultiplexer", "Decoder", "BitSelector", "Priority Encoder",
  };

  private static void gateCases(Netlist nets) {
    for (final String name : GATE_NAMES) {
      final ComponentFactory factory = FACTORIES.get(name);
      if (factory == null) {
        out.println("MISSING " + name);
        continue;
      }
      for (final int width : new int[] {1, 4, 32}) {
        for (final int inputs : new int[] {2, 3, 5}) {
          // negation masks: none, first input, alternating, all
          for (final long negated : new long[] {0L, 1L, 0b10101L, 0b11111L}) {
            for (final String xor : new String[] {null, "1", "odd"}) {
              final AttributeSet attrs = factory.createAttributeSet();
              if (!has(attrs, "xor") && xor != null) continue;
              if (has(attrs, "xor") && xor == null) continue;
              set(attrs, "width", String.valueOf(width));
              if (has(attrs, "inputs")) set(attrs, "inputs", String.valueOf(inputs));
              if (xor != null) set(attrs, "xor", xor);
              for (int i = 0; i < inputs; i++) {
                if (((negated >> i) & 1L) == 1L) {
                  attrs.setValue(new NegateAttribute(i, null), Boolean.TRUE);
                }
              }
              emit(name, factory, "w=" + width + ",in=" + inputs + ",neg=" + negated
                  + ",xor=" + xor, attrs, nets);
            }
          }
        }
      }
      // The out=0Z / out=Z1 variants only change isHdlSupportedTarget, but that predicate is
      // exactly the kind of thing a port drops, so it gets its own cases.
      for (final String outMode : new String[] {"01", "0Z", "Z1"}) {
        final AttributeSet attrs = factory.createAttributeSet();
        if (!has(attrs, "out")) break;
        if (has(attrs, "xor")) set(attrs, "xor", "1");
        set(attrs, "out", outMode);
        emit(name, factory, "out=" + outMode, attrs, nets);
      }
    }
  }

  private static void inlineCases(Netlist nets) {
    for (final String name : INLINE_NAMES) {
      final ComponentFactory factory = FACTORIES.get(name);
      if (factory == null) {
        out.println("MISSING " + name);
        continue;
      }
      for (final int width : new int[] {1, 8}) {
        final AttributeSet attrs = factory.createAttributeSet();
        if (has(attrs, "width")) set(attrs, "width", String.valueOf(width));
        else if (width != 1) continue;
        if (has(attrs, "value")) set(attrs, "value", "0x2a");
        emit(name, factory, "w=" + width, attrs, nets);
      }
    }
  }

  private static void plexerCases(Netlist nets) {
    for (final String name : PLEXER_NAMES) {
      final ComponentFactory factory = FACTORIES.get(name);
      if (factory == null) {
        out.println("MISSING " + name);
        continue;
      }
      for (final int select : new int[] {1, 2, 3}) {
        for (final int width : new int[] {1, 4}) {
          for (final String enable : new String[] {"true", "false"}) {
            final AttributeSet attrs = factory.createAttributeSet();
            if (has(attrs, "select")) set(attrs, "select", String.valueOf(select));
            if (has(attrs, "width")) set(attrs, "width", String.valueOf(width));
            if (has(attrs, "enable")) set(attrs, "enable", enable);
            else if (enable.equals("false")) continue;
            String descr = "sel=" + select + ",w=" + width + ",en=" + enable;
            if (has(attrs, "group")) {
              // BitSelector: the output group width is its own attribute.
              for (final int group : new int[] {1, 2, 4}) {
                final AttributeSet bs = factory.createAttributeSet();
                set(bs, "width", String.valueOf(width));
                set(bs, "group", String.valueOf(group));
                emit(name, factory, "w=" + width + ",group=" + group, bs, nets);
              }
              break;
            }
            emit(name, factory, descr, attrs, nets);
          }
        }
      }
    }
  }

  /**
   * Clock and PLA. Both are AbstractHdlGeneratorFactory subclasses like the plexers, but neither
   * fits the plexer attribute matrix: Clock is driven by three duration attributes and PLA by a
   * truth table. Kept in their own pass, appended after the others so the existing case ordering
   * is untouched.
   */
  private static void miscCases(Netlist nets) {
    final ComponentFactory clock = FACTORIES.get("Clock");
    if (clock == null) {
      out.println("MISSING Clock");
    } else {
      for (final int high : new int[] {1, 3, 8}) {
        for (final int low : new int[] {1, 5}) {
          for (final int phase : new int[] {0, 2}) {
            final AttributeSet attrs = clock.createAttributeSet();
            set(attrs, "highDuration", String.valueOf(high));
            set(attrs, "lowDuration", String.valueOf(low));
            set(attrs, "phaseOffset", String.valueOf(phase));
            emit("Clock", clock, "hi=" + high + ",lo=" + low + ",ph=" + phase, attrs, nets);
          }
        }
      }
    }

    final ComponentFactory pla = FACTORIES.get("PLA");
    if (pla == null) {
      out.println("MISSING PLA");
    } else {
      // PlaTable's compact parser accepts `[01x]+\s+[01]+` per line and nothing else: no header
      // row, and the don't-care character is `x`, not the `-` the VHDL output uses. A table
      // written with `-` parses to *zero* rows and silently falls back to `new PlaTable(2, 2)`,
      // which is how the first attempt at these fixtures produced an empty PLA that looked like
      // a working case. Verified by reading back the emitted architecture.
      final String[] tables = {
        "",
        "01 10\n",
        "0x1 10\n1x0 01\nxxx 00\n",
      };
      for (int i = 0; i < tables.length; i++) {
        final AttributeSet attrs = pla.createAttributeSet();
        try {
          set(attrs, "table", tables[i]);
        } catch (Throwable t) {
          out.println("NOTE PLA table " + i + " rejected: " + t.getClass().getSimpleName());
        }
        emit("PLA", pla, "table=" + i, attrs, nets);
      }
    }
  }

  public static void main(String[] args) throws Exception {
    com.cburch.logisim.Main.headless = true;
    out = System.out;

    harvest(new GatesLibrary());
    harvest(new com.cburch.logisim.std.plexers.PlexersLibrary());
    harvest(new com.cburch.logisim.std.wiring.WiringLibrary());

    // getEntity/getArchitecture reach `theNetlist.projName()`, which is `""` for a circuit with
    // no LogisimFile: enough to drive every generator in these three families, none of which
    // otherwise consults the netlist. A DRC-clean netlist is not needed and would only add a
    // corpus dependency.
    final Netlist nets = new Netlist(new Circuit("bridge", null, null));

    final List<String> languages = new ArrayList<>();
    languages.add(HdlGeneratorFactory.VHDL);
    languages.add(HdlGeneratorFactory.VERILOG);

    for (final String language : languages) {
      AppPreferences.HdlType.set(language);
      // `AppPreferences.HdlType` is a PrefMonitor over java.util.prefs, and the write does NOT
      // propagate synchronously: measured here, the first `Hdl.isVhdl()` after switching to
      // Verilog still answered true, so the very first case of the Verilog pass was labelled
      // VHDL while every later one was correct. Left alone that is one wrong line in the oracle
      // : and, worse, a window in which a generator could be driven under the wrong language.
      // Wait for the preference to actually take effect instead of assuming it has.
      final boolean wantVhdl = HdlGeneratorFactory.VHDL.equals(language);
      for (int spin = 0; spin < 1000; spin++) {
        if (com.cburch.logisim.fpga.hdlgenerator.Hdl.isVhdl() == wantVhdl) break;
        Thread.sleep(5);
      }
      if (com.cburch.logisim.fpga.hdlgenerator.Hdl.isVhdl() != wantVhdl) {
        out.println("FATAL language preference never took effect for " + language);
        out.flush();
        System.exit(1);
      }
      out.println("LANGUAGE " + language);
      gateCases(nets);
      inlineCases(nets);
      plexerCases(nets);
      miscCases(nets);
    }

    // A silent zero-output success is the worst possible oracle. Make the count part of the
    // artefact and non-zero-check it in the consumer.
    out.println("TOTALS cases=" + caseCount + " blocks=" + blockCount);
    out.flush();
    System.exit(0);
  }
}
