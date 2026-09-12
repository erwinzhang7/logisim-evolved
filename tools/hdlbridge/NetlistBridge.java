// Headless netlist oracle: dumps what the shipped 4.1.0 jar's
// com.cburch.logisim.fpga.designrulecheck.Netlist builds for a circuit.
//
// WHY THIS EXISTS
//
// The Swift port's Netlist decides `s_LOGISIM_NET_<id>` / `s_LOGISIM_BUS_<id>` names, and those
// go straight into generated HDL text. Reading the Java and transcribing it is not evidence
// that the numbering agrees; net discovery order comes from JVM HashSet iteration order, which
// is precisely the kind of thing a transcription gets wrong silently. This runs the real thing
// and prints a canonical report the Swift side can be compared against.
//
// The jar's own HDL path (`--test-fpga <circ> <circuit> <board> ... HDLONLY`) is not usable as
// an oracle for this: it needs a board XML *and* a saved pin map for that board in the .circ,
// and with an unmapped design it exits silently having written nothing (verified on
// the corpus/golden-15.circ against BASYS3). Driving the netlist directly needs neither.
//
// Same two load-bearing tricks as tools/valuebridge/CircBridge.java, for the same reasons:
// `Main.headless = true` degrades every modal dialog to a log line, and the explicit
// System.exit at the end is required because loading a LogisimFile starts the AWT event
// dispatch thread and the JVM would otherwise hang at exit looking exactly like a blocked
// dialog.
//
// Declared in com.cburch.logisim.fpga.designrulecheck so it can read Net/ConnectionPoint state
// that is public but whose *containers* (ConnectionPointArray) are package-private, and to stay
// consistent with CircBridge's precedent of living where 4.1.0's access modifiers require.
//
// Build:
//   javac -cp <logisim-fat.jar> -d out NetlistBridge.java
// Run (one request per line on stdin: <circ-path>[TAB<circuit-name>]):
//   java -Djava.awt.headless=true -cp <logisim-fat.jar>:out \
//        com.cburch.logisim.fpga.designrulecheck.NetlistBridge < requests.tsv
//
// Output is a flat, sorted-where-order-is-meaningless line protocol; every line that carries an
// ordering (NET, PORT, COMP) is emitted in the netlist's own order, because that order IS the
// thing under test.

package com.cburch.logisim.fpga.designrulecheck;

import com.cburch.logisim.circuit.Circuit;
import com.cburch.logisim.circuit.SubcircuitFactory;
import com.cburch.logisim.comp.Component;
import com.cburch.logisim.data.Location;
import com.cburch.logisim.file.Loader;
import com.cburch.logisim.fpga.data.ComponentMapInformationContainer;
import com.cburch.logisim.fpga.data.MapComponent;
import com.cburch.logisim.instance.StdAttr;
import java.io.BufferedReader;
import java.io.File;
import java.io.InputStreamReader;
import java.io.PrintStream;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.TreeSet;

public final class NetlistBridge {

  private static String oneLine(String s) {
    return s == null ? "" : s.replace('\n', ' ').replace('\r', ' ').replace('\t', ' ');
  }

  private static String label(Component comp) {
    final String raw = comp.getAttributeSet().getValue(StdAttr.LABEL);
    return raw == null || raw.isEmpty() ? "-" : raw;
  }

  private static void dumpEnds(PrintStream out, String kind, int index, netlistComponent comp,
      Netlist netlist) {
    // The FACTORY name, not getHDLName(attrs): getHDLName is overridden by the per-component
    // HDL generators, and those are not ported yet (see HdlGeneratorLookup.swift). Factory names
    // are the stable identity both sides already agree on; they are what .circ files carry.
    out.println(kind + " " + index + " " + comp.getComponent().getFactory().getName()
        + " " + label(comp.getComponent()) + " ends=" + comp.nrOfEnds());
    for (int e = 0; e < comp.nrOfEnds(); e++) {
      final ConnectionEnd end = comp.getEnd(e);
      final StringBuilder sb = new StringBuilder();
      sb.append("  END ").append(e)
          .append(" out=").append(end.isOutputEnd() ? 1 : 0)
          .append(" bits=").append(end.getNrOfBits())
          .append(" cont=").append(netlist.isContinuesBus(comp, e) ? 1 : 0)
          .append(" ->");
      for (int b = 0; b < end.getNrOfBits(); b++) {
        final ConnectionPoint point = end.get((byte) b);
        if (point == null || point.getParentNet() == null) {
          sb.append(" -");
        } else {
          sb.append(' ').append(netlist.getNetId(point.getParentNet()))
              .append(':').append(point.getParentNetBitIndex());
        }
      }
      out.println(sb);
    }
  }

  // ══ The FPGA bubble tree ═══════════════════════════════════════════════════════════════════
  //
  // A "bubble" is one board-facing signal of a component: one LED, one switch, one segment.
  // `Netlist.constructHierarchyTree` numbers every bubble in the whole design, twice: a LOCAL
  // index within each sheet and a GLOBAL index keyed by the instance's hierarchy path. Those
  // numbers index `s_LOGISIM_INPUT_BUBBLES`/`_OUTPUT_`/`_INOUT_` in the generated toplevel, and
  // `MapComponent` reads the global ones to bind a component pin to a physical FPGA pin. So the
  // numbering is output, exactly as `getNetId` is, and it is dumped here rather than reasoned
  // about; `constructHierarchyTree` is package-visible-by-accident (`public`), and running it is
  // the only way to know that the *order* agrees.
  //
  // `constructHierarchyTree` runs inside `designRuleCheckResult(true, ...)`, so by the time
  // `report` gets here the tree already exists; this only reads it back out.

  /** `CorrectLabel.getCorrectLabel(comp.getAttributeSet().getValue(StdAttr.LABEL))`. */
  private static String hierarchyName(Component comp) {
    final String corrected =
        CorrectLabel.getCorrectLabel(comp.getAttributeSet().getValue(StdAttr.LABEL));
    return corrected == null || corrected.isEmpty() ? "-" : corrected;
  }

  private static String path(List<String> names) {
    return names.isEmpty() ? "/" : String.join("/", names);
  }

  private static String localRange(netlistComponent comp) {
    return comp.getLocalBubbleInputStartId() + ".." + comp.getLocalBubbleInputEndId()
        + "," + comp.getLocalBubbleOutputStartId() + ".." + comp.getLocalBubbleOutputEndId()
        + "," + comp.getLocalBubbleInOutStartId() + ".." + comp.getLocalBubbleInOutEndId();
  }

  private static String globalRange(netlistComponent comp, List<String> names) {
    final BubbleInformationContainer info = comp.getGlobalBubbleId(names);
    if (info == null) return "-";
    return info.getInputStartIndex() + ".." + info.getInputEndIndex()
        + "," + info.getOutputStartIndex() + ".." + info.getOutputEndIndex()
        + "," + info.getInOutStartIndex() + ".." + info.getInOutEndIndex();
  }

  /**
   * Walks the hierarchy the way `enumerateGlobalBubbleTree` does, subcircuits first, in
   * `mySubCircuits` order, then the map-carrying entries of `myComponents`, and prints one line
   * per visited instance. Terminates for the same reason upstream's walk does: Logisim forbids a
   * circuit from containing itself.
   */
  private static void dumpBubbleTree(PrintStream out, Netlist netlist, List<String> names) {
    out.println("BUBBLES " + path(names)
        + " in=" + netlist.getNumberOfInputBubbles()
        + " out=" + netlist.numberOfOutputBubbles()
        + " io=" + netlist.numberOfInOutBubbles());
    for (final netlistComponent comp : netlist.getSubCircuits()) {
      final List<String> sub = new ArrayList<>(names);
      sub.add(hierarchyName(comp.getComponent()));
      out.println("BUB SUB " + path(sub)
          + " " + comp.getComponent().getFactory().getName()
          + " local=" + localRange(comp)
          + " global=" + globalRange(comp, sub));
      final SubcircuitFactory factory = (SubcircuitFactory) comp.getComponent().getFactory();
      dumpBubbleTree(out, factory.getSubcircuit().getNetList(), sub);
    }
    for (final netlistComponent comp : netlist.getNormalComponents()) {
      final ComponentMapInformationContainer map = comp.getMapInformationContainer();
      if (map == null) continue;
      final List<String> sub = new ArrayList<>(names);
      sub.add(hierarchyName(comp.getComponent()));
      out.println("BUB COMP " + path(sub)
          + " " + comp.getComponent().getFactory().getName()
          + " n=" + map.getNrOfInPorts() + "," + map.getNrOfOutPorts() + ","
          + map.getNrOfInOutPorts()
          + " local=" + localRange(comp)
          + " global=" + globalRange(comp, sub));
    }
  }

  // ══ MapComponent, driven for real ══════════════════════════════════════════════════════════
  //
  // `Netlist.getMappableResources(hierarchy, true)` is the map the FPGA commander binds to
  // physical pins, and `MapComponent`'s constructor is where the bubble tree above turns into
  // per-pin signal names. `getHdlSignalName(pin)` is emitted verbatim into the generated
  // toplevel, so it is output in the same sense `getNetId` is, and it is dumped rather than
  // reasoned about.
  //
  // The jar's own `--test-fpga` path cannot produce this: it needs a board XML *and* a saved pin
  // map in the .circ, and with an unmapped design it exits silently having written nothing.
  // Constructing the container directly needs neither, and an *unmapped* MapComponent is exactly
  // the interesting case: the constructor, the pin classification and the bubble indices are all
  // fully determined before anything is mapped.
  //
  // `MapComponent` lives in `com.cburch.logisim.fpga.data` and is public, so no reflection is
  // needed. The hierarchy key is `[boardName] + path`, matching what
  // `MappableResourcesContainer` passes; the board name is a placeholder here because
  // `getHdlString`/`getHdlSignalName` both skip element 0 by design.
  private static void dumpMappableResources(PrintStream out, Netlist netlist) {
    // `getHdlSignalName` calls `Hdl.bracketOpen()`, which reads AppPreferences. Pin it so the
    // oracle does not depend on whatever the last GUI session left behind.
    com.cburch.logisim.prefs.AppPreferences.HdlType.set(
        com.cburch.logisim.fpga.hdlgenerator.HdlGeneratorFactory.VHDL);
    final java.util.List<String> boardId = new ArrayList<>();
    boardId.add("ORACLEBOARD");
    final java.util.Map<ArrayList<String>, netlistComponent> resources =
        netlist.getMappableResources(boardId, true);
    // A HashMap: iteration order is JVM hash order and is NOT part of what the port must
    // reproduce (upstream's consumers key by the path). Sorted so the oracle is stable.
    final java.util.List<ArrayList<String>> keys = new ArrayList<>(resources.keySet());
    keys.sort((a, b) -> String.join("/", a).compareTo(String.join("/", b)));
    out.println("MAPPABLE " + keys.size());
    for (final ArrayList<String> key : keys) {
      final MapComponent map = new MapComponent(key, resources.get(key));
      out.println("MAP " + String.join("/", key)
          + " " + resources.get(key).getComponent().getFactory().getName()
          + " pins=" + map.getNrOfPins()
          + " n=" + map.nrInputs() + "," + map.nrOutputs() + "," + map.nrIOs()
          + " has=" + (map.hasInputs() ? 1 : 0) + (map.hasOutputs() ? 1 : 0)
          + (map.hasIos() ? 1 : 0)
          + " mapped=" + (map.hasMap() ? 1 : 0));
      for (int pin = 0; pin < map.getNrOfPins(); pin++) {
        final String kind = map.isInput(pin) ? "in" : map.isOutput(pin) ? "out"
            : map.isIo(pin) ? "io" : "?";
        out.println("  MAPPIN " + pin + " " + kind
            + " hdl=" + oneLine(map.getHdlString(pin))
            + " sig=" + oneLine(map.getHdlSignalName(pin))
            + " disp=" + oneLine(map.getDisplayString(pin)));
      }
    }
  }

  /**
   * `netlistComponent.getMapInformationContainer()` for every factory in the file, as DATA rather
   * than as part of the compared report.
   *
   * The container is built by `com.cburch.logisim.std.io` components (`Button`, `Led`,
   * `SevenSegment`, `DipSwitch`, `PortIo`, `DotMatrixBase`, ...) and stored in `StdAttr.MAPINFO`.
   * The Swift `LogisimHdl` module may not name `LogisimStd`, that closes the module cycle the
   * per-component generators need, so it takes the mapping by injection, and this is where the
   * expected content of that injection comes from. Same arrangement as the `SYNTH` lines above:
   * a fact about the std library, answered by the library itself rather than transcribed.
   *
   * Keyed by factory name plus the attributes that change the answer, because they do: a
   * `7-Segment Display` is 7 or 8 output bubbles depending on `ATTR_DP`, a `DipSwitch` one input
   * bubble per switch. The key is the component's own `toString` of the relevant width/flag
   * attributes, printed alongside so the Swift side can be checked per instance.
   */
  private static void collectMapInfo(Circuit circuit, TreeSet<String> into) {
    for (final Component comp : circuit.getNonWires()) {
      if (!comp.getAttributeSet().containsAttribute(StdAttr.MAPINFO)) continue;
      final ComponentMapInformationContainer map =
          comp.getAttributeSet().getValue(StdAttr.MAPINFO);
      if (map == null) {
        into.add("MAPINFO " + comp.getFactory().getName() + " null");
        continue;
      }
      final StringBuilder sb = new StringBuilder("MAPINFO ");
      sb.append(comp.getFactory().getName())
          .append(" n=").append(map.getNrOfInPorts())
          .append(',').append(map.getNrOfOutPorts())
          .append(',').append(map.getNrOfInOutPorts())
          .append(" in=");
      for (int i = 0; i < map.getNrOfInPorts(); i++) {
        if (i > 0) sb.append('|');
        sb.append(map.getInPortLabel(i));
      }
      sb.append(" out=");
      for (int i = 0; i < map.getNrOfOutPorts(); i++) {
        if (i > 0) sb.append('|');
        sb.append(map.getOutPortLabel(i));
      }
      sb.append(" io=");
      for (int i = 0; i < map.getNrOfInOutPorts(); i++) {
        if (i > 0) sb.append('|');
        sb.append(map.getInOutportLabel(i));
      }
      into.add(oneLine(sb.toString()));
    }
  }

  private static void report(PrintStream out, Circuit circuit) {
    final Netlist netlist = circuit.getNetList();
    final int status = netlist.designRuleCheckResult(true, new ArrayList<String>());
    out.println("CIRCUIT " + circuit.getName());
    out.println("DRC " + status);
    // Emitted before the DRC-failure early return below, and deliberately: MAPINFO is data about
    // the std library, not about this circuit's netlist, so a circuit that fails DRC still has
    // useful rows in it. Filtered out of the compared report on the Swift side, like SYNTH.
    final TreeSet<String> maps = new TreeSet<>();
    collectMapInfo(circuit, maps);
    for (final String entry : maps) out.println(entry);
    if (status != Netlist.DRC_PASSED) {
      // The nets are cleared on failure, so there is nothing further to report, but *why* it
      // failed is exactly what the Swift side must reproduce, and Reporter's SimpleDrcContainer
      // overload writes nothing without a GUI attached. So re-run the two per-component
      // predicates the preparing stage checks and print them.
      for (final Component comp : circuit.getNonWires()) {
        final StringBuilder sb = new StringBuilder("  WHY ");
        sb.append(comp.getFactory().getName()).append(' ').append(label(comp));
        if (!comp.getFactory().isHDLSupportedComponent(comp.getAttributeSet())) {
          sb.append(" unsupported");
        }
        if (comp.getFactory().requiresNonZeroLabel()
            && CorrectLabel.getCorrectLabel(comp.getAttributeSet().getValue(StdAttr.LABEL))
                .isEmpty()) {
          sb.append(" needs-label");
        }
        if (comp.getFactory().hasThreeStateDrivers(comp.getAttributeSet())) {
          sb.append(" tristate");
        }
        final String text = sb.toString();
        if (text.contains("unsupported") || text.contains("needs-label")
            || text.contains("tristate")) {
          out.println(text);
        }
      }
      return;
    }
    final List<Net> nets = netlist.getAllNets();
    out.println("NETS " + nets.size() + " single=" + netlist.numberOfNets()
        + " bus=" + netlist.numberOfBusses());
    for (int i = 0; i < nets.size(); i++) {
      final Net net = nets.get(i);
      final List<String> points = new ArrayList<>();
      for (final Location loc : net.getPoints()) points.add(loc.getX() + "," + loc.getY());
      Collections.sort(points);
      out.println("NET " + i + " width=" + net.getBitWidth()
          + " bus=" + (net.isBus() ? 1 : 0)
          + " root=" + (net.isRootNet() ? 1 : 0)
          + " forced=" + (net.isForcedRootNet() ? 1 : 0)
          + " points=" + String.join(";", points));
    }
    out.println("CLOCKTREES " + netlist.numberOfClockTrees());
    for (int i = 0; i < netlist.getNumberOfInputPorts(); i++) {
      dumpEnds(out, "INPORT", i, netlist.getInputPin(i), netlist);
    }
    for (int i = 0; i < netlist.numberOfOutputPorts(); i++) {
      dumpEnds(out, "OUTPORT", i, netlist.getOutputPin(i), netlist);
    }
    final List<netlistComponent> subs = netlist.getSubCircuits();
    for (int i = 0; i < subs.size(); i++) dumpEnds(out, "SUBCIRC", i, subs.get(i), netlist);
    final List<netlistComponent> comps = netlist.getNormalComponents();
    for (int i = 0; i < comps.size(); i++) dumpEnds(out, "COMP", i, comps.get(i), netlist);
    dumpBubbleTree(out, netlist, new ArrayList<String>());
    dumpMappableResources(out, netlist);
    // Which factories upstream actually has an HDL generator for. `Netlist` uses exactly this
    // predicate to decide membership of getNormalComponents(), and the Swift port has no
    // generators yet, so it needs the answer as data. Emitted per circuit and merged by the
    // consumer; a factory that answers differently for different attributes shows up as both.
    final List<String> synth = new ArrayList<>();
    for (final Component comp : circuit.getNonWires()) {
      final String flag = comp.getFactory().getHDLGenerator(comp.getAttributeSet()) != null
          ? "1" : "0";
      final String entry = "SYNTH " + comp.getFactory().getName() + " " + flag;
      if (!synth.contains(entry)) synth.add(entry);
      // isHDLSupportedComponent is a DIFFERENT predicate from "has a generator", and the
      // difference is load-bearing: `Text` overrides it to true while its getHDLGenerator stays
      // null, so a Text annotation passes DRC and is then excluded from the netlist. Both
      // answers are needed, so both are emitted.
      final String supported = "SUPP " + comp.getFactory().getName() + " "
          + (comp.getFactory().isHDLSupportedComponent(comp.getAttributeSet()) ? "1" : "0");
      if (!synth.contains(supported)) synth.add(supported);
    }
    Collections.sort(synth);
    for (final String entry : synth) out.println(entry);
  }

  public static void main(String[] args) throws Exception {
    com.cburch.logisim.Main.headless = true;

    final BufferedReader in = new BufferedReader(new InputStreamReader(System.in));
    final PrintStream out = System.out;

    String line;
    while ((line = in.readLine()) != null) {
      line = line.trim();
      if (line.isEmpty()) continue;
      if (line.equals("PING")) { out.println("PONG"); out.flush(); continue; }

      final String[] parts = line.split("\t");
      final String src = parts[0];
      final String wanted = parts.length > 1 ? parts[1] : null;
      try {
        final Loader loader = new Loader(null);
        final com.cburch.logisim.file.LogisimFile file = loader.openLogisimFile(new File(src));
        if (file == null) {
          out.println("FAIL\t" + src + "\tnull LogisimFile");
          out.flush();
          continue;
        }
        Circuit circuit = null;
        for (final Circuit candidate : file.getCircuits()) {
          if (wanted == null || candidate.getName().equals(wanted)) { circuit = candidate; break; }
        }
        if (circuit == null) {
          out.println("FAIL\t" + src + "\tno such circuit: " + wanted);
          out.flush();
          continue;
        }
        out.println("BEGIN\t" + src);
        report(out, circuit);
        out.println("END\t" + src);
      } catch (Throwable t) {
        out.println("FAIL\t" + src + "\t" + t.getClass().getSimpleName() + ": "
            + oneLine(t.getMessage()));
      }
      out.flush();
    }
    out.flush();
    System.exit(0);
  }
}
