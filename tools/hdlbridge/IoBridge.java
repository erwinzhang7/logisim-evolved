// Headless HDL oracle for the std/io per-component generator factories: dumps exactly what the
// shipped 4.1.0 jar's own classes emit, for a spread of attribute settings, in both VHDL and
// Verilog.
//
// WHY THIS EXISTS
//
// The Swift port of `std/io/*HdlGeneratorFactory` is a transcription of string-building code, and
// a transcription of string-building code is precisely what cannot be trusted by reading. HDL
// text is byte-diffable, so the honest gate is "run upstream's class, run ours, diff". This runs
// upstream's.
//
// WHY IT DOES NOT LOAD A .circ
//
// The io generators consume three things: the component's AttributeSet, a `netlistComponent`
// whose ConnectionEnds are soldered to Nets, and the component's *local bubble ids* (the index
// range it occupies in `logisimInputBubbles`/`logisimOutputBubbles`/`logisimInOutBubbles`).
// Bubble ids are only assigned by `Netlist.designRuleCheckResult` -> `setLocalBubbleID` during a
// full hierarchy walk with an FPGA board attached, and the jar's own `--test-fpga ... HDLONLY`
// path additionally needs a board XML plus a saved pin map and **exits 0 having written nothing**
// when the design is unmapped (recorded in docs/objectives.md). Building the netlistComponent
// directly needs none of that and makes every input to the generator an explicit, swept
// parameter, which is the point.
//
// Declared in `com.cburch.logisim.std.io` because `DotMatrixBase.ATTR_INPUT_TYPE`,
// `INPUT_COLUMN`, `INPUT_ROW`, `INPUT_SELECT`, `ATTR_PERSIST` and `LedBar.ATTR_INPUT_TYPE` /
// `INPUT_ONE_WIRE` are `protected static`: same precedent as CircBridge living in
// `com.cburch.logisim.file` because 4.1.0's `write` overloads are package-private.
//
// `new Netlist(null)` is safe for everything reached here: the constructor only stores the
// Circuit and calls `clear()`, which iterates empty collections, and neither `getNetId` nor
// `isContinuesBus` dereferences it. `projName()`/`getCircuitName()` do, so the two that a
// non-inlined generator calls are overridden in `FakeNetlist` below.
//
// Build:
//   javac -cp <logisim-fat.jar> -d out IoBridge.java
// Run:
//   java -Djava.awt.headless=true -cp <logisim-fat.jar>:out com.cburch.logisim.std.io.IoBridge

package com.cburch.logisim.std.io;

import com.cburch.logisim.comp.Component;
import com.cburch.logisim.comp.ComponentFactory;
import com.cburch.logisim.data.Attribute;
import com.cburch.logisim.data.AttributeSet;
import com.cburch.logisim.data.BitWidth;
import com.cburch.logisim.data.Location;
import com.cburch.logisim.fpga.designrulecheck.Net;
import com.cburch.logisim.fpga.designrulecheck.Netlist;
import com.cburch.logisim.fpga.designrulecheck.netlistComponent;
import com.cburch.logisim.fpga.hdlgenerator.HdlGeneratorFactory;
import com.cburch.logisim.instance.StdAttr;
import com.cburch.logisim.prefs.AppPreferences;
import java.io.PrintStream;
import java.util.List;

public final class IoBridge {

  /** A Netlist with no Circuit behind it; see the file header. */
  static final class FakeNetlist extends Netlist {
    FakeNetlist() {
      super(null);
    }

    @Override
    public String projName() {
      return "oracleProject";
    }

    @Override
    public String getCircuitName() {
      return "oracleCircuit";
    }
  }

  private static PrintStream out;

  // ── net plumbing ───────────────────────────────────────────────────────────────────────────

  /**
   * Registers a fresh Net of `width` bits with `nets` and returns it. `getAllNets()` hands back
   * the live backing list, so adding to it is exactly what the DRC does internally, and
   * `getNetId` is `myNets.indexOf(net)`.
   */
  private static Net newNet(Netlist nets, int width) {
    final Net net = new Net(Location.create(0, 0, false), width);
    nets.getAllNets().add(net);
    return net;
  }

  /** Solders every bit of end `endIndex` onto a freshly created net of the matching width. */
  private static void connectEnd(Netlist nets, netlistComponent comp, int endIndex) {
    final var end = comp.getEnd(endIndex);
    final int bits = end.getNrOfBits();
    final Net net = newNet(nets, bits);
    for (byte b = 0; b < bits; b++) {
      end.get(b).setParentNet(net, b);
    }
  }

  /** Solders every end of the component, each onto its own net. */
  private static void connectAll(Netlist nets, netlistComponent comp) {
    for (int e = 0; e < comp.nrOfEnds(); e++) connectEnd(nets, comp, e);
  }

  // ── component construction ─────────────────────────────────────────────────────────────────

  @SuppressWarnings("unchecked")
  private static <V> void set(AttributeSet attrs, Attribute<V> attr, Object value) {
    attrs.setValue(attr, (V) value);
  }

  private static Component place(ComponentFactory factory, AttributeSet attrs) {
    return factory.createComponent(Location.create(100, 100, false), attrs);
  }

  // ── emission ───────────────────────────────────────────────────────────────────────────────

  private static void header(String caseName) {
    // `Hdl.isVhdl()`, not `AppPreferences.HdlType.get()`: see setLanguage's note on the async
    // preference cache. The generators branch on the former, so the label must too.
    out.println(
        "CASE\t"
            + caseName
            + "\t"
            + (com.cburch.logisim.fpga.hdlgenerator.Hdl.isVhdl() ? "VHDL" : "Verilog"));
  }

  private static void body(List<String> lines) {
    if (lines == null) {
      out.println("  <null>");
    } else {
      for (final String line : lines) out.println("  " + line);
    }
    out.println("ENDCASE");
  }

  /**
   * Some upstream generators throw while building their own text (an undefined `{{key}}` makes
   * `LineBuffer.abort` raise). That is real 4.1.0 behaviour and must be recorded, not crashed on.
   */
  private interface Producer {
    List<String> get() throws Exception;
  }

  private static void bodyCatching(Producer producer) {
    try {
      body(producer.get());
    } catch (Throwable t) {
      out.println(
          "  <throws "
              + t.getClass().getName()
              + ": "
              + String.valueOf(t.getMessage()).replace('\n', '|').replace('\r', ' ')
              + ">");
      out.println("ENDCASE");
    }
  }

  /**
   * `AbstractComponentFactory.getHDLGenerator(attrs)` returns **null** when the generator's own
   * `isHdlSupportedTarget(attrs)` is false, so "has a generator" is attribute-dependent for every
   * io component whose generator overrides it (LedBar, DotMatrix, ReptarLocalBus). Both answers
   * are emitted; a port that always returns a generator object diverges here.
   */
  private static void supported(String caseName, ComponentFactory factory, AttributeSet attrs) {
    header(caseName);
    final HdlGeneratorFactory gen = factory.getHDLGenerator(attrs);
    out.println("  getHDLGenerator=" + (gen == null ? "null" : gen.getClass().getSimpleName()));
    out.println("  isHDLSupportedComponent=" + factory.isHDLSupportedComponent(attrs));
    out.println("ENDCASE");
  }

  private static void emitInlined(
      String caseName, Netlist nets, Component comp, netlistComponent info) {
    header(caseName);
    final HdlGeneratorFactory gen = comp.getFactory().getHDLGenerator(comp.getAttributeSet());
    if (gen == null) {
      out.println("  <no generator>");
      out.println("ENDCASE");
      return;
    }
    bodyCatching(() -> gen.getInlinedCode(nets, 1L, info, "oracleCircuit").get());
  }

  // ── cases ──────────────────────────────────────────────────────────────────────────────────

  /** Button / DipSwitch / Led / RgbLed / SevenSegment -> AbstractSimpleIoHdlGeneratorFactory. */
  private static void simpleIoCases() {
    for (final boolean pressPassive : new boolean[] {false, true}) {
      final var factory = new Button();
      final var attrs = factory.createAttributeSet();
      set(attrs, Button.ATTR_PRESS,
          pressPassive ? Button.BUTTON_PRESS_PASSIVE : Button.BUTTON_PRESS_ACTIVE);
      final var comp = place(factory, attrs);
      final var nets = new FakeNetlist();
      final var info = new netlistComponent(comp);
      connectAll(nets, info);
      info.setLocalBubbleID(4, comp.getEnds().size(), 0, 0, 0, 0);
      emitInlined("Button/press=" + (pressPassive ? "passive" : "active"), nets, comp, info);
    }

    // Unconnected input component: the `isEndConnected` guard means nothing is emitted at all.
    {
      final var factory = new Button();
      final var attrs = factory.createAttributeSet();
      final var comp = place(factory, attrs);
      final var nets = new FakeNetlist();
      final var info = new netlistComponent(comp);
      info.setLocalBubbleID(4, comp.getEnds().size(), 0, 0, 0, 0);
      emitInlined("Button/unconnected", nets, comp, info);
    }

    for (final int size : new int[] {2, 4, 8}) {
      final var factory = new DipSwitch();
      final var attrs = factory.createAttributeSet();
      set(attrs, DipSwitch.ATTR_SIZE, BitWidth.create(size));
      final var comp = place(factory, attrs);
      final var nets = new FakeNetlist();
      final var info = new netlistComponent(comp);
      connectAll(nets, info);
      info.setLocalBubbleID(3, comp.getEnds().size(), 0, 0, 0, 0);
      emitInlined("DipSwitch/size=" + size, nets, comp, info);
    }

    {
      final var factory = new Led();
      final var attrs = factory.createAttributeSet();
      final var comp = place(factory, attrs);
      final var nets = new FakeNetlist();
      final var info = new netlistComponent(comp);
      connectAll(nets, info);
      info.setLocalBubbleID(0, 0, 7, comp.getEnds().size(), 0, 0);
      emitInlined("Led", nets, comp, info);
    }

    // Output component with nothing connected: still emitted, sourced from the floating value.
    {
      final var factory = new Led();
      final var attrs = factory.createAttributeSet();
      final var comp = place(factory, attrs);
      final var nets = new FakeNetlist();
      final var info = new netlistComponent(comp);
      info.setLocalBubbleID(0, 0, 7, comp.getEnds().size(), 0, 0);
      emitInlined("Led/unconnected", nets, comp, info);
    }

    {
      final var factory = new RgbLed();
      final var attrs = factory.createAttributeSet();
      final var comp = place(factory, attrs);
      final var nets = new FakeNetlist();
      final var info = new netlistComponent(comp);
      connectAll(nets, info);
      info.setLocalBubbleID(0, 0, 11, comp.getEnds().size(), 0, 0);
      emitInlined("RgbLed", nets, comp, info);
    }

    for (final boolean dp : new boolean[] {false, true}) {
      final var factory = new SevenSegment();
      final var attrs = factory.createAttributeSet();
      set(attrs, SevenSegment.ATTR_DP, dp);
      final var comp = place(factory, attrs);
      final var nets = new FakeNetlist();
      final var info = new netlistComponent(comp);
      connectAll(nets, info);
      info.setLocalBubbleID(0, 0, 2, comp.getEnds().size(), 0, 0);
      emitInlined("SevenSegment/dp=" + dp, nets, comp, info);
    }
  }

  /** HexDigit -> HexDigitHdlGeneratorFactory. */
  private static void hexDigitCases() {
    for (final boolean connected : new boolean[] {true, false}) {
      for (final boolean dp : new boolean[] {false, true}) {
        final var factory = new HexDigit();
        final var attrs = factory.createAttributeSet();
        set(attrs, SevenSegment.ATTR_DP, dp);
        set(attrs, StdAttr.LABEL, "hd1");
        final var comp = place(factory, attrs);
        final var nets = new FakeNetlist();
        final var info = new netlistComponent(comp);
        if (connected) connectAll(nets, info);
        info.setLocalBubbleID(0, 0, 16, 8, 0, 0);
        emitInlined("HexDigit/connected=" + connected + "/dp=" + dp, nets, comp, info);
      }
    }
  }

  /** LedBar -> LedBarHdlGeneratorFactory. */
  private static void ledBarCases() {
    for (final boolean oneWire : new boolean[] {true, false}) {
      for (final int cols : new int[] {1, 4, 8}) {
        final var factory = new LedBar();
        final var attrs = factory.createAttributeSet();
        set(attrs, LedBar.ATTR_MATRIX_COLS, BitWidth.create(cols));
        set(attrs, LedBar.ATTR_INPUT_TYPE,
            oneWire ? LedBar.INPUT_ONE_WIRE : LedBar.INPUT_SEPARATED);
        final var comp = place(factory, attrs);
        final var nets = new FakeNetlist();
        final var info = new netlistComponent(comp);
        connectAll(nets, info);
        info.setLocalBubbleID(0, 0, 5, cols, 0, 0);
        emitInlined("LedBar/oneWire=" + oneWire + "/cols=" + cols, nets, comp, info);
        supported("LedBar/supported/oneWire=" + oneWire + "/cols=" + cols, factory, attrs);
      }
    }
    // ATTR_PERSIST != 0 turns the component un-synthesizable.
    {
      final var factory = new LedBar();
      final var attrs = factory.createAttributeSet();
      set(attrs, DotMatrixBase.ATTR_PERSIST, 3);
      supported("LedBar/supported/persist=3", factory, attrs);
    }
  }

  /** DotMatrix -> DotMatrixHdlGeneratorFactory. */
  private static void dotMatrixCases() {
    final Object[] inputTypes = {
      DotMatrixBase.INPUT_COLUMN, DotMatrixBase.INPUT_ROW, DotMatrixBase.INPUT_SELECT
    };
    final String[] inputNames = {"column", "row", "select"};
    final int[][] shapes = {{1, 1}, {1, 3}, {3, 1}, {2, 2}, {5, 7}};
    for (int t = 0; t < inputTypes.length; t++) {
      for (final int[] shape : shapes) {
        final int rows = shape[0];
        final int cols = shape[1];
        final var factory = new DotMatrix();
        final var attrs = factory.createAttributeSet();
        set(attrs, DotMatrix.ATTR_MATRIX_ROWS, BitWidth.create(rows));
        set(attrs, DotMatrix.ATTR_MATRIX_COLS, BitWidth.create(cols));
        set(attrs, DotMatrixBase.ATTR_INPUT_TYPE, inputTypes[t]);
        final var comp = place(factory, attrs);
        final var nets = new FakeNetlist();
        final var info = new netlistComponent(comp);
        connectAll(nets, info);
        info.setLocalBubbleID(0, 0, 6, rows * cols, 0, 0);
        emitInlined(
            "DotMatrix/" + inputNames[t] + "/rows=" + rows + "/cols=" + cols, nets, comp, info);
      }
    }
    {
      final var factory = new DotMatrix();
      final var attrs = factory.createAttributeSet();
      set(attrs, DotMatrixBase.ATTR_PERSIST, 2);
      supported("DotMatrix/supported/persist=2", factory, attrs);
      set(attrs, DotMatrixBase.ATTR_PERSIST, 0);
      supported("DotMatrix/supported/persist=0", factory, attrs);
    }
  }

  /** PortIo -> PortHdlGeneratorFactory. */
  private static void portIoCases() {
    final Object[] dirs = {PortIo.INPUT, PortIo.OUTPUT, PortIo.INOUTSE, PortIo.INOUTME};
    final String[] dirNames = {"input", "output", "inoutse", "inoutme"};
    for (int d = 0; d < dirs.length; d++) {
      for (final int size : new int[] {1, 4, 8}) {
        final var factory = new PortIo();
        final var attrs = factory.createAttributeSet();
        set(attrs, PortIo.ATTR_SIZE, BitWidth.create(size));
        set(attrs, PortIo.ATTR_DIR, dirs[d]);
        final var comp = place(factory, attrs);
        final var nets = new FakeNetlist();
        final var info = new netlistComponent(comp);
        connectAll(nets, info);
        info.setLocalBubbleID(9, size, 13, size, 21, size);
        emitInlined("PortIo/" + dirNames[d] + "/size=" + size, nets, comp, info);
      }
    }
  }

  /** ReptarLocalBus -> ReptarLocalBusHdlGeneratorFactory (a full entity/architecture generator). */
  private static void reptarCases() {
    final var factory = new ReptarLocalBus();
    final var attrs = factory.createAttributeSet();
    final var comp = place(factory, attrs);
    final var nets = new FakeNetlist();
    final var info = new netlistComponent(comp);
    connectAll(nets, info);
    info.setLocalBubbleID(0, 13, 20, 2, 40, 16);
    supported("ReptarLocalBus/supported", factory, attrs);
    final var gen = factory.getHDLGenerator(attrs);
    if (gen == null) {
      header("ReptarLocalBus/entity");
      out.println("  <no generator>");
      out.println("ENDCASE");
      return;
    }

    header("ReptarLocalBus/entity");
    bodyCatching(() -> gen.getEntity(nets, attrs, "LocalBus"));
    header("ReptarLocalBus/architecture");
    bodyCatching(() -> gen.getArchitecture(nets, attrs, "LocalBus"));
    header("ReptarLocalBus/instantiation");
    bodyCatching(() -> gen.getComponentInstantiation(nets, attrs, "LocalBus").get());
    header("ReptarLocalBus/componentMap");
    bodyCatching(() -> gen.getComponentMap(nets, 3L, info, "LocalBus").get());
    header("ReptarLocalBus/hdlName");
    out.println("  " + factory.getHDLName(attrs));
    out.println("ENDCASE");
  }

  /**
   * The six board-level LED array drivers plus the scanning seven-segment driver. These are not
   * reached through a ComponentFactory, `LedArrayGenericHdlGeneratorFactory.getSpecificHDLGenerator`
   * builds them from a board's drive mode, but they are `AbstractHdlGeneratorFactory`s whose
   * entity/architecture text is fully determined by the class, so they diff exactly the same way.
   */
  private static void ledArrayCases() {
    final String[] modes = {
      "LedDefault", "LedRowScanning", "LedColumnScanning",
      "RgbDefault", "RgbRowScanning", "RgbColScanning"
    };
    final var nets = new FakeNetlist();
    for (final String mode : modes) {
      final var gen = LedArrayGenericHdlGeneratorFactory.getSpecificHDLGenerator(mode);
      final String name = LedArrayGenericHdlGeneratorFactory.getSpecificHDLName(mode);
      final var attrs = new Button().createAttributeSet(); // never read by these generators
      header("LedArray/" + mode + "/name");
      out.println("  " + name);
      out.println("ENDCASE");
      header("LedArray/" + mode + "/entity");
      bodyCatching(() -> gen.getEntity(nets, attrs, name));
      header("LedArray/" + mode + "/architecture");
      bodyCatching(() -> gen.getArchitecture(nets, attrs, name));
      header("LedArray/" + mode + "/instantiation");
      bodyCatching(() -> gen.getComponentInstantiation(nets, attrs, name).get());
    }
    for (final int[] shape : new int[][] {{1, 1}, {2, 3}, {4, 8}, {8, 16}}) {
      for (final boolean activeLow : new boolean[] {false, true}) {
        for (int m = 0; m < modes.length; m++) {
          final char typeId = (char) m;
          final String tag =
              modes[m] + "/rows=" + shape[0] + "/cols=" + shape[1] + "/activeLow=" + activeLow;
          header("LedArray/" + tag + "/componentMap");
          bodyCatching(
              () ->
                  LedArrayGenericHdlGeneratorFactory.getComponentMap(
                      typeId, shape[0], shape[1], 7, 50_000_000L, activeLow));
          header("LedArray/" + tag + "/externals");
          final var externals =
              LedArrayGenericHdlGeneratorFactory.getExternalSignals(
                  typeId, shape[0], shape[1], 7);
          for (final var entry : externals.entrySet()) {
            out.println("  " + entry.getKey() + " = " + entry.getValue());
          }
          out.println("ENDCASE");
          header("LedArray/" + tag + "/internals");
          final var internals =
              LedArrayGenericHdlGeneratorFactory.getInternalSignals(
                  typeId, shape[0], shape[1], 7);
          for (final var entry : new java.util.TreeMap<>(internals).entrySet()) {
            out.println("  " + entry.getKey() + " = " + entry.getValue());
          }
          out.println("ENDCASE");
          header("LedArray/" + tag + "/pinNames");
          final int nrOfPins = 24;
          for (int pin = 0; pin < nrOfPins; pin++) {
            out.println(
                "  "
                    + pin
                    + " -> "
                    + LedArrayGenericHdlGeneratorFactory.getExternalSignalName(
                        typeId, shape[0], shape[1], 7, pin));
          }
          out.println("ENDCASE");
          header("LedArray/" + tag + "/requiresClock");
          out.println("  " + LedArrayGenericHdlGeneratorFactory.requiresClock(typeId));
          out.println("ENDCASE");
        }
      }
    }
    for (final int value : new int[] {1, 2, 3, 4, 5, 7, 8, 9, 15, 16, 17, 31, 32, 1000, 50000}) {
      header("LedArray/nrOfBitsRequired/" + value);
      out.println("  " + LedArrayGenericHdlGeneratorFactory.getNrOfBitsRequired(value));
      out.println("ENDCASE");
    }
  }

  /** SevenSegmentScanningDecodedHdlGeneratorFactory, the scanning seven-segment board driver. */
  private static void sevenSegmentScanningCases() {
    final var nets = new FakeNetlist();
    final var attrs = new Button().createAttributeSet();
    final var gen = new SevenSegmentScanningDecodedHdlGeneratorFactory();
    final String name = SevenSegmentScanningDecodedHdlGeneratorFactory.HDL_IDENTIFIER;
    header("SevenSegmentScanningDecoded/entity");
    bodyCatching(() -> gen.getEntity(nets, attrs, name));
    header("SevenSegmentScanningDecoded/architecture");
    bodyCatching(() -> gen.getArchitecture(nets, attrs, name));
    header("SevenSegmentScanningDecoded/instantiation");
    bodyCatching(() -> gen.getComponentInstantiation(nets, attrs, name).get());
    for (final int[] shape : new int[][] {{1, 1}, {2, 3}, {4, 8}}) {
      for (final boolean activeLow : new boolean[] {false, true}) {
        header(
            "SevenSegmentScanningDecoded/genericMap/rows="
                + shape[0]
                + "/cols="
                + shape[1]
                + "/activeLow="
                + activeLow);
        body(
            SevenSegmentScanningDecodedHdlGeneratorFactory.getGenericMap(
                    shape[0], shape[1], 50_000_000L, activeLow, false)
                .get());
      }
      header("SevenSegmentScanningDecoded/nrOfControlBits/" + shape[0] + "," + shape[1]);
      out.println(
          "  " + SevenSegmentScanningDecodedHdlGeneratorFactory.nrOfControlBits(shape[0], shape[1]));
      out.println("ENDCASE");
    }
    header("SevenSegmentScanningDecoded/portMap");
    body(SevenSegmentScanningDecodedHdlGeneratorFactory.getPortMap(3).get());
  }

  private static void allCases() {
    simpleIoCases();
    hexDigitCases();
    ledBarCases();
    dotMatrixCases();
    portIoCases();
    reptarCases();
    ledArrayCases();
    sevenSegmentScanningCases();
  }

  /**
   * Switching the HDL language is **asynchronous**, and getting this wrong silently produces two
   * identical Verilog passes labelled VHDL and Verilog. `PrefMonitorString.set()` writes the
   * backing `java.util.prefs` node; the cached value `get()` returns is only updated by a
   * `preferenceChange` callback delivered on the preferences daemon thread, and that callback
   * first replays whatever the *stored* preference was (Verilog on this machine, from the
   * installed app). Measured:
   *
   * <pre>
   *   default=VHDL
   *   immediately after set("VHDL"): get=Verilog  isVhdl=false
   *   500 ms later: get=VHDL     isVhdl=true
   * </pre>
   *
   * So the switch is polled to completion against `Hdl.isVhdl()`/`isVerilog()`, the predicate the
   * generators actually branch on, and a switch that never lands is fatal rather than silent.
   */
  private static void setLanguage(String language) throws Exception {
    AppPreferences.HdlType.set(language);
    final long deadline = System.currentTimeMillis() + 10_000L;
    while (System.currentTimeMillis() < deadline) {
      final boolean landed =
          language.equals("VHDL")
              ? com.cburch.logisim.fpga.hdlgenerator.Hdl.isVhdl()
              : com.cburch.logisim.fpga.hdlgenerator.Hdl.isVerilog();
      if (landed) return;
      Thread.sleep(25L);
      AppPreferences.HdlType.set(language);
    }
    System.err.println(
        "FATAL: HDL language never switched to " + language
            + " (stuck at " + AppPreferences.HdlType.get() + ")");
    System.exit(2);
  }

  public static void main(String[] args) throws Exception {
    com.cburch.logisim.Main.headless = true;
    out = System.out;

    int emitted = 0;
    for (final String language : new String[] {"VHDL", "Verilog"}) {
      setLanguage(language);
      allCases();
      emitted++;
    }
    out.flush();

    // A silent zero-output success is the worst possible oracle (docs/objectives.md). Assert the
    // instrument actually produced something before anyone trusts agreement with it.
    if (emitted != 2) {
      System.err.println("FATAL: expected 2 language passes, ran " + emitted);
      System.exit(2);
    }
    System.exit(0);
  }
}
