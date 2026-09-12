// Headless per-component HDL oracle for the std/arith family: dumps exactly what the shipped
// 4.1.0 jar's Adder/Subtractor/Multiplier/Divider/Negator/Comparator/Shifter
// HdlGeneratorFactory classes produce, for a spread of attribute settings, in both VHDL and
// Verilog.
//
// WHY THIS EXISTS
//
// HDL text is byte-diffable, so transcribing the Java and eyeballing it is the weakest possible
// check when the strongest one is available for the same effort. This runs upstream's own
// generator objects and prints entity / architecture / component-instantiation text plus the
// declared parameter, port and wire tables. `ArithHdlGeneratorTests` on the Swift side asserts
// byte equality against the checked-in transcript.
//
// Three things it deliberately does NOT drive, and why:
//   * `getComponentMap` / `getPortMap` need a real `netlistComponent` with resolved nets. Those
//     live in `AbstractHdlGeneratorFactory`, which is already ported and covered by the netlist
//     gate; nothing in std/arith overrides them. The per-component half of a component map is
//     the *parameter* map, and that is dumped directly (PARAM lines).
//   * `generateAllHdlDescriptions` is the inherited no-op for every arith generator.
//   * The jar's own `--test-fpga … HDLONLY` path, which writes nothing at all for an unmapped
//     design and exits 0; a silent zero-output success. Driving the generator objects needs
//     no board XML and no pin map.
//
// Declared in com.cburch.logisim.fpga.hdlgenerator because `myParametersList`, `myWires`,
// `myPorts` and `getWiresPortsDuringHDLWriting` are `protected` on AbstractHdlGeneratorFactory,
// which in Java also means package-accessible. Same precedent as CircBridge/NetlistBridge
// living where 4.1.0's access modifiers require.
//
// Attribute sets come from the real component factories (`new Adder().createAttributeSet()`),
// not hand-built, so defaults and attribute identity are upstream's own. `Shifter.ATTR_SHIFT`
// and `Comparator.MODE_ATTR`'s options are reached by name + `Attribute.parse`, because
// `ATTR_SHIFT` is package-private to com.cburch.logisim.std.arith.
//
// Build:
//   javac -cp <logisim-fat.jar> -d out ArithBridge.java
// Run:
//   java -Djava.awt.headless=true -cp <logisim-fat.jar>:out \
//        com.cburch.logisim.fpga.hdlgenerator.ArithBridge > arith-4.1.0.oracle

package com.cburch.logisim.fpga.hdlgenerator;

import com.cburch.logisim.circuit.Circuit;
import com.cburch.logisim.comp.ComponentFactory;
import com.cburch.logisim.data.Attribute;
import com.cburch.logisim.data.AttributeSet;
import com.cburch.logisim.data.BitWidth;
import com.cburch.logisim.fpga.designrulecheck.Netlist;
import com.cburch.logisim.instance.StdAttr;
import com.cburch.logisim.prefs.AppPreferences;
import com.cburch.logisim.std.arith.Adder;
import com.cburch.logisim.std.arith.AdderHdlGeneratorFactory;
import com.cburch.logisim.std.arith.Comparator;
import com.cburch.logisim.std.arith.ComparatorHdlGeneratorFactory;
import com.cburch.logisim.std.arith.Divider;
import com.cburch.logisim.std.arith.DividerHdlGeneratorFactory;
import com.cburch.logisim.std.arith.Multiplier;
import com.cburch.logisim.std.arith.MultiplierHdlGeneratorFactory;
import com.cburch.logisim.std.arith.Negator;
import com.cburch.logisim.std.arith.NegatorHdlGeneratorFactory;
import com.cburch.logisim.std.arith.Shifter;
import com.cburch.logisim.std.arith.ShifterHdlGeneratorFactory;
import com.cburch.logisim.std.arith.Subtractor;
import com.cburch.logisim.std.arith.SubtractorHdlGeneratorFactory;
import java.io.PrintStream;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Map;

public final class ArithBridge {

  /** One request: which generator, which component factory supplies the attribute set. */
  private interface GeneratorMaker {
    AbstractHdlGeneratorFactory make();
  }

  private static Netlist netlist;

  @SuppressWarnings("unchecked")
  private static void setOption(AttributeSet attrs, String attrName, String optionName) {
    for (final Attribute<?> attr : attrs.getAttributes()) {
      if (attr.getName().equals(attrName)) {
        final Attribute<Object> typed = (Attribute<Object>) attr;
        attrs.setValue(typed, typed.parse(optionName));
        return;
      }
    }
    throw new IllegalStateException("no attribute named " + attrName);
  }

  /** Java's Shifter.configurePorts: the smallest `shift` with `(1 << shift) >= data`, from 1. */
  private static int shiftBits(int data) {
    int shift = 1;
    while ((1 << shift) < data) shift++;
    return shift;
  }

  private static void dumpPorts(PrintStream out, AbstractHdlGeneratorFactory gen,
      AttributeSet attrs) {
    for (final String name : gen.myPorts.keySet()) {
      out.println("PORT " + name
          + " bits=" + gen.myPorts.get(name, attrs)
          + " pin=" + (gen.myPorts.isFixedMapped(name) ? "fixed:" + gen.myPorts.getFixedMap(name)
              : Integer.toString(gen.myPorts.getComponentPortId(name)))
          + " clock=" + (gen.myPorts.isClock(name) ? 1 : 0)
          + " pulldown=" + (gen.myPorts.doPullDownOnFloat(name) ? 1 : 0));
    }
    for (final String dir : new String[] {"input", "output", "inout"}) {
      final List<String> names = gen.myPorts.keySet(dir);
      out.println("PORTDIR " + dir + " " + String.join(",", names));
    }
  }

  private static void dumpWires(PrintStream out, AbstractHdlGeneratorFactory gen) {
    for (final String name : gen.myWires.wireKeySet()) {
      out.println("WIRE " + name + " bits=" + gen.myWires.get(name));
    }
    for (final String name : gen.myWires.registerKeySet()) {
      out.println("REG " + name + " bits=" + gen.myWires.get(name));
    }
  }

  private static void dumpParams(PrintStream out, AbstractHdlGeneratorFactory gen,
      AttributeSet attrs) {
    final List<Integer> ids = gen.myParametersList.keySet(attrs);
    for (final Integer id : ids) {
      out.println("PARAMKEY " + id
          + " name=" + gen.myParametersList.get(id, attrs)
          + " int=" + (gen.myParametersList.isPresentedByInteger(id, attrs) ? 1 : 0));
    }
    final Map<String, String> maps = gen.myParametersList.getMaps(attrs);
    final List<String> keys = new ArrayList<>(maps.keySet());
    Collections.sort(keys);
    for (final String key : keys) out.println("PARAM " + key + " = " + maps.get(key));
    out.println("PARAMEMPTY " + (gen.myParametersList.isEmpty(attrs) ? 1 : 0));
  }

  private static void emit(PrintStream out, String tag, List<String> lines) {
    if (lines == null) {
      out.println(tag + " <null>");
      return;
    }
    // Entries can carry embedded newlines (Java text blocks are added as one entry); split so
    // the transcript is one physical line per physical line of HDL, which is what a diff wants.
    for (final String entry : lines) {
      for (final String line : entry.split("\n", -1)) out.println(tag + "|" + line);
    }
  }

  private static void emitBuffer(PrintStream out, String tag,
      com.cburch.logisim.util.LineBuffer buffer) {
    emit(out, tag, buffer == null ? null : buffer.get());
  }

  private static void runCase(PrintStream out, String caseName, GeneratorMaker maker,
      AttributeSet attrs, String componentName, ComponentFactory factory) {
    final AbstractHdlGeneratorFactory gen = maker.make();
    out.println("CASE " + caseName);
    out.println("LANG " + AppPreferences.HdlType.get());
    // The three ComponentFactory answers HdlGeneratorLookup has to reproduce as registrations.
    // HDLNAME pins the getHDLName overrides; SYNTH is the predicate Netlist keys membership of
    // getNormalComponents() on, and it is 0 for Divider in 4.1.0 because Divider's constructor
    // never passes a generator.
    out.println("HDLNAME " + factory.getHDLName(attrs));
    out.println("SYNTH " + (factory.getHDLGenerator(attrs) != null ? 1 : 0));
    out.println("SUPP " + (factory.isHDLSupportedComponent(attrs) ? 1 : 0));
    out.println("DIR " + gen.getRelativeDirectory());
    out.println("INLINED " + (gen.isOnlyInlined() ? 1 : 0));
    out.println("SUPPORTED " + (gen.isHdlSupportedTarget(attrs) ? 1 : 0));
    out.println("GENTIME " + (gen.getWiresPortsDuringHDLWriting ? 1 : 0));

    // Mirror exactly what AbstractHdlGeneratorFactory does before reading the tables.
    if (gen.getWiresPortsDuringHDLWriting) {
      gen.myWires.removeWires();
      gen.myTypedWires.clear();
      gen.myPorts.removePorts();
      gen.getGenerationTimeWiresPorts(netlist, attrs);
    }
    dumpParams(out, gen, attrs);
    dumpPorts(out, gen, attrs);
    dumpWires(out, gen);

    emitBuffer(out, "FUNC", gen.getModuleFunctionality(netlist, attrs));
    emit(out, "ENTITY", gen.getEntity(netlist, attrs, componentName));
    emit(out, "ARCH", gen.getArchitecture(netlist, attrs, componentName));
    emitBuffer(out, "INST", gen.getComponentInstantiation(netlist, attrs, componentName));
    out.println("ENDCASE");
    out.println();
  }

  private static AttributeSet attrsOf(ComponentFactory factory) {
    return factory.createAttributeSet();
  }

  private static void allCases(PrintStream out) {
    final int[] widths = {1, 2, 3, 4, 8, 16, 31, 32, 33, 63, 64};
    final String[] modes = {"twosComplement", "unsigned"};
    final String[] shifts = {"ll", "lr", "ar", "rl", "rr"};

    for (final int width : widths) {
      // --- Adder / Subtractor / Negator: WIDTH only ---------------------------------------
      ComponentFactory factory = new Adder();
      AttributeSet attrs = attrsOf(factory);
      attrs.setValue(StdAttr.WIDTH, BitWidth.create(width));
      runCase(out, "Adder w=" + width, AdderHdlGeneratorFactory::new, attrs, "Adder_" + width,
          factory);

      factory = new Subtractor();
      attrs = attrsOf(factory);
      attrs.setValue(StdAttr.WIDTH, BitWidth.create(width));
      runCase(out, "Subtractor w=" + width, SubtractorHdlGeneratorFactory::new, attrs,
          "Subtractor_" + width, factory);

      factory = new Negator();
      attrs = attrsOf(factory);
      attrs.setValue(StdAttr.WIDTH, BitWidth.create(width));
      runCase(out, "Negator w=" + width, NegatorHdlGeneratorFactory::new, attrs,
          "Negator_" + width, factory);

      // --- Comparator / Multiplier / Divider: WIDTH x MODE ---------------------------------
      for (final String mode : modes) {
        factory = new Comparator();
        attrs = attrsOf(factory);
        attrs.setValue(StdAttr.WIDTH, BitWidth.create(width));
        setOption(attrs, "mode", mode);
        runCase(out, "Comparator w=" + width + " mode=" + mode,
            ComparatorHdlGeneratorFactory::new, attrs, "Comparator_" + width, factory);

        factory = new Multiplier();
        attrs = attrsOf(factory);
        attrs.setValue(StdAttr.WIDTH, BitWidth.create(width));
        setOption(attrs, "mode", mode);
        runCase(out, "Multiplier w=" + width + " mode=" + mode,
            MultiplierHdlGeneratorFactory::new, attrs, "Multiplier_" + width, factory);

        factory = new Divider();
        attrs = attrsOf(factory);
        attrs.setValue(StdAttr.WIDTH, BitWidth.create(width));
        setOption(attrs, "mode", mode);
        runCase(out, "Divider w=" + width + " mode=" + mode,
            DividerHdlGeneratorFactory::new, attrs, "Divider_" + width, factory);
      }

      // --- Shifter: WIDTH x SHIFT MODE -----------------------------------------------------
      for (final String shift : shifts) {
        factory = new Shifter();
        attrs = attrsOf(factory);
        attrs.setValue(StdAttr.WIDTH, BitWidth.create(width));
        setOption(attrs, "shift", shift);
        // A placed Shifter's SHIFT_BITS_ATTR is written by configurePorts, which only runs for
        // a real Instance. Model that here or the generator sees the constructor default (4)
        // for every width, which is not what any placed component carries.
        attrs.setValue(Shifter.SHIFT_BITS_ATTR, shiftBits(width));
        runCase(out, "Shifter w=" + width + " shift=" + shift, ShifterHdlGeneratorFactory::new,
            attrs, "Shifter_" + width + "_bit", factory);
      }
    }
  }

  /**
   * `AppPreferences.HdlType` is a `PrefMonitorStringOpts`, whose `set()` only writes the backing
   * `java.util.prefs` node; the in-memory `value` is updated later, from the preferences
   * change-listener thread. So a naive `set(VERILOG)` immediately followed by generation still
   * emits VHDL, silently and for every case. Poll until it actually takes, and fail loudly if
   * it never does.
   */
  private static void selectLanguage(String language) throws Exception {
    AppPreferences.HdlType.set(language);
    for (int attempt = 0; attempt < 200 && !AppPreferences.HdlType.get().equals(language);
        attempt++) {
      AppPreferences.getPrefs().flush();
      Thread.sleep(10);
    }
    if (!AppPreferences.HdlType.get().equals(language)) {
      throw new IllegalStateException("HdlType did not take: " + AppPreferences.HdlType.get());
    }
    // Belt and braces: prove the switch reached the code under test, not just the preference.
    final boolean wantVhdl = HdlGeneratorFactory.VHDL.equals(language);
    if (Hdl.isVhdl() != wantVhdl) {
      throw new IllegalStateException("Hdl.isVhdl() disagrees with HdlType");
    }
  }

  public static void main(String[] args) throws Exception {
    com.cburch.logisim.Main.headless = true;
    // projName() is the only thing any of these generators asks a Netlist for; an empty
    // LogisimFile gives "".
    netlist = new Netlist(new Circuit("oracle", null, null));

    // Selecting the language mutates a real user preference, so put it back afterwards.
    final String originalLanguage = AppPreferences.HdlType.get();
    final PrintStream out = System.out;
    try {
      for (final String language : new String[] {HdlGeneratorFactory.VHDL,
          HdlGeneratorFactory.VERILOG}) {
        selectLanguage(language);
        out.println("### LANGUAGE " + language);
        allCases(out);
      }
    } finally {
      selectLanguage(originalLanguage);
    }
    out.flush();
    System.exit(0);
  }
}
