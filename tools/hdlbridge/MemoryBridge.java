// Headless HDL oracle for the std/memory component generators, run inside the shipped 4.1.0 jar.
//
// WHY THIS EXISTS
//
// The Swift port of the seven `std/memory/*HdlGeneratorFactory` classes has to emit
// byte-identical VHDL and Verilog. Reading the Java and transcribing it is not evidence: the
// text is produced by `LineBuffer`'s placeholder substitution over Java *text blocks*, which
// carry a trailing line separator Swift's multi-line literals do not, and by
// `AbstractHdlGeneratorFactory`'s entity/architecture assembly whose sort orders and column
// padding are computed, not written down. This runs the real classes and prints their output.
//
// It deliberately does NOT go through `--test-fpga … HDLONLY`: that entry point needs a board
// XML plus a saved pin map and exits 0 having written nothing for an unmapped design (recorded
// in docs/objectives.md). Driving the generator objects directly needs neither.
//
// Declared in com.cburch.logisim.std.memory so it can construct the package-private inner
// generator classes' owning factories and read package-private attribute identities, and to
// follow CircBridge/NetlistBridge's precedent of living where 4.1.0's access modifiers require.
//
// Build:
//   javac -cp <logisim-fat.jar> -d out MemoryBridge.java
// Run (one request per line on stdin):
//   <component>\t<VHDL|Verilog>\t<attr=value,attr=value,...>
// Output: a BEGIN/END framed, section-tagged dump; every line is prefixed so a diff points at
// the exact section that disagrees.

package com.cburch.logisim.std.memory;

import com.cburch.logisim.data.Attribute;
import com.cburch.logisim.data.AttributeSet;
import com.cburch.logisim.circuit.Circuit;
import com.cburch.logisim.comp.ComponentFactory;
import com.cburch.logisim.file.Loader;
import com.cburch.logisim.fpga.designrulecheck.Netlist;
import com.cburch.logisim.fpga.designrulecheck.netlistComponent;
import com.cburch.logisim.fpga.hdlgenerator.HdlGeneratorFactory;
import com.cburch.logisim.prefs.AppPreferences;
import java.io.BufferedReader;
import java.io.File;
import java.io.InputStreamReader;
import java.io.PrintStream;
import java.util.List;

public final class MemoryBridge {

  private static ComponentFactory factoryFor(String name) {
    switch (name) {
      case "D Flip-Flop": return new DFlipFlop();
      case "T Flip-Flop": return new TFlipFlop();
      case "J-K Flip-Flop": return new JKFlipFlop();
      case "S-R Flip-Flop": return new SRFlipFlop();
      case "Register": return new Register();
      case "Counter": return new Counter();
      case "Shift Register": return new ShiftRegister();
      case "Random": return new Random();
      case "RAM": return new Ram();
      case "ROM": return new Rom();
      default: return null;
    }
  }

  @SuppressWarnings({"unchecked", "rawtypes"})
  private static void applyOverrides(AttributeSet attrs, String spec) throws Exception {
    if (spec == null || spec.isEmpty()) return;
    for (final String pair : spec.split(",")) {
      final int eq = pair.indexOf('=');
      if (eq < 0) continue;
      final String key = pair.substring(0, eq).trim();
      final String value = pair.substring(eq + 1).trim();
      Attribute found = null;
      for (final Attribute<?> attr : attrs.getAttributes()) {
        if (attr.getName().equals(key)) { found = attr; break; }
      }
      if (found == null) throw new IllegalArgumentException("no attribute named " + key);
      attrs.setValue(found, found.parse(value));
    }
  }

  private static void section(PrintStream out, String tag, List<String> lines) {
    if (lines == null) {
      out.println(tag + " <null>");
      return;
    }
    out.println(tag + " " + lines.size());
    for (final String line : lines) {
      // A buffer entry may itself contain newlines (a Java text block is ONE entry). That is
      // exactly the property the Swift port has to reproduce, so embedded newlines are made
      // visible rather than flattened away.
      out.println(tag + "| " + line.replace("\n", "\\n").replace("\r", "\\r"));
    }
  }

  // ── Reflective access to myPorts / myWires / myParametersList ─────────────────────────────
  //
  // These are `protected` on AbstractHdlGeneratorFactory (package com.cburch.logisim.fpga
  // .hdlgenerator), so a class in std.memory cannot touch them even though it can see the
  // concrete subclasses. Their *contents* are what a port most easily gets wrong, a port id
  // off by one, a wire declared as a `wire` where upstream declares a `reg`, a generic whose
  // value formula silently differs, and none of that is visible in the entity text, so it is
  // worth the reflection. The jar is on the classpath, hence in the unnamed module, so
  // setAccessible succeeds without --add-opens.
  private static Object field(Object owner, String name) throws Exception {
    Class<?> type = owner.getClass();
    while (type != null) {
      try {
        final java.lang.reflect.Field f = type.getDeclaredField(name);
        f.setAccessible(true);
        return f.get(owner);
      } catch (NoSuchFieldException ignored) {
        type = type.getSuperclass();
      }
    }
    throw new NoSuchFieldException(name);
  }

  @SuppressWarnings("unchecked")
  private static void dumpStructure(PrintStream out, HdlGeneratorFactory gen, AttributeSet attrs)
      throws Exception {
    final com.cburch.logisim.fpga.hdlgenerator.HdlPorts ports =
        (com.cburch.logisim.fpga.hdlgenerator.HdlPorts) field(gen, "myPorts");
    final java.util.List<String> names = new java.util.ArrayList<>(ports.keySet());
    out.println("PORTS " + names.size());
    for (final String name : names) {
      final StringBuilder sb = new StringBuilder("PORT| ").append(name)
          .append(" bits=").append(ports.get(name, attrs))
          .append(" clock=").append(ports.isClock(name) ? 1 : 0)
          .append(" pulldown=").append(ports.doPullDownOnFloat(name) ? 1 : 0);
      if (ports.isFixedMapped(name)) {
        sb.append(" fixed=").append(ports.getFixedMap(name));
      } else {
        sb.append(" pin=").append(ports.getComponentPortId(name));
      }
      if (ports.isClock(name)) sb.append(" tick=").append(ports.getTickName(name));
      out.println(sb);
    }
    for (final String direction : new String[] {"input", "output", "inout"}) {
      out.println("PORTDIR " + direction + " " + ports.keySet(direction));
    }

    final com.cburch.logisim.fpga.hdlgenerator.HdlWires wires =
        (com.cburch.logisim.fpga.hdlgenerator.HdlWires) field(gen, "myWires");
    final java.util.List<String> wireNames = new java.util.ArrayList<>(wires.wireKeySet());
    final java.util.List<String> regNames = new java.util.ArrayList<>(wires.registerKeySet());
    out.println("WIRES " + wireNames.size() + " REGS " + regNames.size());
    for (final String name : wireNames) out.println("WIRE| " + name + " " + wires.get(name));
    for (final String name : regNames) out.println("REG| " + name + " " + wires.get(name));

    final com.cburch.logisim.fpga.hdlgenerator.HdlParameters params =
        (com.cburch.logisim.fpga.hdlgenerator.HdlParameters) field(gen, "myParametersList");
    final java.util.List<Integer> ids = new java.util.ArrayList<>(params.keySet(attrs));
    out.println("PARAMS " + ids.size() + " empty=" + params.isEmpty(attrs));
    for (final Integer id : ids) {
      out.println("PARAM| " + id + " " + params.get(id, attrs)
          + " int=" + (params.isPresentedByInteger(id, attrs) ? 1 : 0)
          + (params.isPresentedByInteger(id, attrs)
              ? "" : " vecbits=" + params.getNumberOfVectorBits(id, attrs)));
    }
    final java.util.Map<String, String> maps = params.getMaps(attrs);
    final java.util.List<String> keys = new java.util.ArrayList<>(maps.keySet());
    java.util.Collections.sort(keys);
    out.println("PARAMMAP " + keys.size());
    for (final String key : keys) out.println("PARAMMAP| " + key + " = " + maps.get(key));
  }

  // ── getPortMap / getComponentMap over a synthetic, fully-unconnected placement ─────────────
  //
  // `getPortMap` is where the per-generator overrides live (the width-1 `d(0)`/`q(0)` rewrite in
  // Register/Counter/Random, and ShiftRegister's complete rebuild of `d`/`q` from taps that are
  // `2 * stage` apart), and none of it is visible in the entity text. It needs a
  // `netlistComponent`, which needs a placed `Component`, but NOT a connected one: both
  // `netlistComponent`'s constructor and `ConnectionEnd` are happy with every solder point
  // unattached, and the floating case still exercises every branch of the overrides plus the
  // "component has no clock connection" and "gated clock" arms of the base class.
  //
  // What this does NOT cover is stated rather than implied: with no nets there is no clock tree,
  // so `Hdl.getClockNetName` returns "" and only the gated-clock arm of the base class's clock
  // handling is reached. The connected arms need a real circuit and are left to the netlist gate.
  private static void dumpPortMap(PrintStream out, HdlGeneratorFactory gen,
      ComponentFactory factory, AttributeSet attrs, Netlist netlist) {
    final com.cburch.logisim.comp.Component comp =
        factory.createComponent(com.cburch.logisim.data.Location.create(0, 0, true), attrs);
    final netlistComponent info = new netlistComponent(comp);
    out.println("ENDS " + info.nrOfEnds());
    // `getPortMap` is declared on AbstractHdlGeneratorFactory, not on the HdlGeneratorFactory
    // interface: the same shape the Swift port mirrors.
    final java.util.SortedMap<String, String> map = new java.util.TreeMap<>(
        ((com.cburch.logisim.fpga.hdlgenerator.AbstractHdlGeneratorFactory) gen)
            .getPortMap(netlist, info));
    out.println("PORTMAP " + map.size());
    for (final java.util.Map.Entry<String, String> entry : map.entrySet()) {
      out.println("PORTMAP| " + entry.getKey() + " => " + entry.getValue());
    }
    section(out, "COMPMAP",
        gen.getComponentMap(netlist, 7L, info, factory.getHDLName(attrs)).get());
  }

  private static Circuit scratchCircuit() throws Exception {
    // getArchitecture/getEntity only read projName()/circuitName() off the netlist, so any
    // loadable file gives a usable one. The file is supplied on the command line.
    final Loader loader = new Loader(null);
    final com.cburch.logisim.file.LogisimFile file = loader.openLogisimFile(new File(scratchPath));
    return file.getCircuits().iterator().next();
  }

  private static String scratchPath;

  public static void main(String[] args) throws Exception {
    com.cburch.logisim.Main.headless = true;
    scratchPath = args.length > 0 ? args[0] : null;

    final BufferedReader in = new BufferedReader(new InputStreamReader(System.in));
    final PrintStream out = System.out;

    Circuit circuit = scratchPath == null ? null : scratchCircuit();
    final Netlist netlist = circuit == null ? null : circuit.getNetList();
    if (netlist != null) {
      // Without a DRC pass the netlist's ClockSourceContainer is never allocated and
      // `requiresGlobalClockConnection()` throws an NPE from inside getPortMap. The result is
      // not used; only the side effect of building the (empty) clock tree is.
      netlist.designRuleCheckResult(true, new java.util.ArrayList<String>());
      netlist.cleanClockTree(
          new com.cburch.logisim.fpga.designrulecheck.ClockSourceContainer());
    }

    String line;
    while ((line = in.readLine()) != null) {
      line = line.trim();
      if (line.isEmpty()) continue;
      if (line.equals("PING")) { out.println("PONG"); out.flush(); continue; }

      final String[] parts = line.split("\t", -1);
      final String compName = parts[0];
      final String lang = parts.length > 1 ? parts[1] : "VHDL";
      final String overrides = parts.length > 2 ? parts[2] : "";

      out.println("BEGIN\t" + line);
      try {
        // `AppPreferences.HdlType` is a PrefMonitorString whose cached value is refreshed by a
        // java.util.prefs change listener on a *different* thread, so `set` does not take
        // effect synchronously. Measured: without this wait, 1 of 84 Verilog cases printed
        // `RELDIR vhdl/memory/` and then generated Verilog: a flaky oracle, which is worse
        // than a wrong one. Spin until the value the generators actually read has caught up.
        AppPreferences.HdlType.set(lang);
        for (int spin = 0; spin < 1000 && !AppPreferences.HdlType.get().equals(lang); spin++) {
          Thread.sleep(1);
        }
        if (!AppPreferences.HdlType.get().equals(lang)) {
          throw new IllegalStateException("HdlType never settled on " + lang);
        }
        final ComponentFactory factory = factoryFor(compName);
        if (factory == null) throw new IllegalArgumentException("unknown component " + compName);
        final AttributeSet attrs = factory.createAttributeSet();
        applyOverrides(attrs, overrides);

        for (final Attribute<?> attr : attrs.getAttributes()) {
          out.println("ATTR " + attr.getName() + " = "
              + String.valueOf(attrs.getValue(attr)).replace('\n', ' '));
        }

        final HdlGeneratorFactory gen = factory.getHDLGenerator(attrs);
        if (gen == null) {
          out.println("GENERATOR <null>");
        } else {
          final String hdlName = factory.getHDLName(attrs);
          out.println("GENERATOR " + gen.getClass().getName());
          out.println("HDLNAME " + hdlName);
          out.println("SUPPORTEDTARGET " + gen.isHdlSupportedTarget(attrs));
          out.println("ONLYINLINED " + gen.isOnlyInlined());
          if (!gen.isOnlyInlined()) {
            out.println("RELDIR " + gen.getRelativeDirectory());
            section(out, "ENTITY", gen.getEntity(netlist, attrs, hdlName));
            section(out, "ARCH", gen.getArchitecture(netlist, attrs, hdlName));
            section(out, "INST",
                gen.getComponentInstantiation(netlist, attrs, hdlName).get());
            // AFTER the entity/architecture calls: a generator with
            // getWiresPortsDuringHDLWriting = true (ShiftRegister, RAM) only populates myPorts
            // and myWires from inside them, so dumping first would show an empty structure and
            // look like agreement with a port that also had none. Skipped for inlined-only
            // generators (ROM), which extend InlinedHdlGeneratorFactory and have no such fields.
            dumpStructure(out, gen, attrs);
            dumpPortMap(out, gen, factory, attrs, netlist);
          }
          // NOT dumped, and the reason is worth recording rather than leaving as a silent gap:
          // ROM is inlined-only, so `getInlinedCode` is the only thing it produces: but it
          // builds a `WithSelectHdlGenerator` from `Hdl.getBusName(...)`, which returns **null**
          // for an unconnected end, and `LineBuffer.pair` then NPEs inside the jar. Measured:
          // `getInlinedCode` on this synthetic placement throws
          // "Cannot invoke Object.toString() because Map$Entry.getValue() is null" for both
          // languages. So a ROM oracle needs a genuinely connected circuit, not a bare
          // placement, and is out of scope for this bridge.
        }
      } catch (Throwable t) {
        out.println("FAIL " + t.getClass().getName() + ": "
            + String.valueOf(t.getMessage()).replace('\n', ' '));
      }
      out.println("END\t" + line);
      out.flush();
    }
    out.flush();
    System.exit(0);
  }
}
