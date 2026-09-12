// StdLibrariesExtra.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.tcl.*, com.cburch.logisim.std.hdl.*
// and com.cburch.logisim.std.bfh.*), https://github.com/logisim-evolution/logisim-evolution.
// Copyright by the Logisim-evolution developers. This translation is a derivative work and is
// therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// WHAT THIS FILE IS
//
// `StdLibraries.swift` registers seven builtin libraries. Four of the fourteen `Builtin`
// declares still have nothing behind them, `#TCL`, `#HDL-IP`, `#BFH-Praktika` and `#Soc`, and
// an unregistered library is NOT inert. The shell resolves, so the `<lib>` declaration
// survives, but every `<tool>` under it fails to resolve and takes D8's verbatim path, which
// re-emits exactly what the file said. That is lossless and it is not what the oracle writes:
// Java resolves the tool, absorbs the attribute, finds it equal to the factory default and
// drops the element.
//
// Measured on the 539-file round-trip corpus, before this file existed:
//
//     #TCL            177 files carry <tool name="TclGeneric"><a name="content">…
//     #Soc            155 files carry seven <tool> blocks (SocBusSelection / SocBusIdentifier)
//     #HDL-IP          20 files carry <tool name="VHDL Entity"><a name="content">…
//     #BFH-Praktika   346 files declare it, ALWAYS empty: nothing to fix, see below
//
// and 154 files differed from the oracle in nothing but `#Soc` and/or `#TCL`.
//
// This file supplies the three that belong to `com.cburch.logisim.std.*`, which is `LogisimStd`
// by construction. `#Soc` is `com.cburch.logisim.soc.*` and lives in `LogisimSoc`
// (`SocLibrary.swift`); it cannot be registered from here, because `LogisimSoc` depends on
// `LogisimStd` and the arrow cannot point back. See the hand-off note at the bottom.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// HOW MUCH OF EACH LIBRARY IS ACTUALLY PORTABLE
//
// `#BFH-Praktika`; fully. `BinToBcd` and `BcdToSevenSegmentDisplay` are two combinational
//   components with no external dependencies, and both are ported here including `propagate`.
//   Neither appears in any corpus file, so this buys nothing on the gate; it is here because
//   the library is small enough that a stub would cost more explanation than the port.
//
// `#TCL`: the codec half only, and that is a permanent limit rather than a deferral.
//   `TclWrapper` starts an external `tclsh` process, hands it a Unix socket and talks to it on
//   a background thread (`TclWrapperListenerThread`); `TclComponentData` marshals port values
//   across that socket every propagation. That is D11 territory, it needs a Tcl interpreter on
//   the user's machine, and porting it is a decision, not a translation. So `propagate` is a
//   documented no-op here: a placed TCL component simulates as inert instead of crashing.
//
//   NOT PORTED, by Java file: `TclWrapper.java`, `TclWrapperListenerThread.java`,
//   `TclComponentData.java`, `TclComponentListener.java`, and the `paintInstance`/
//   `HdlContentEditor` halves of `TclComponent.java`, `TclConsoleReds.java`, `TclGeneric.java`
//   and `TclGenericAttributes.java`.
//
// `#HDL-IP`; the codec half only. `VhdlEntityComponent`'s simulation runs through
//   `VhdlSimulator`/Questa (external), and `BlifCircuitComponent`'s runs through
//   `DenseLogicCircuit`, a 1,000-line compiled-netlist evaluator. Both are out of scope for a
//   library-registration slice.
//
//   NOT PORTED, by Java file: `DenseLogicCircuit.java`, `DenseLogicCircuitBuilder.java`,
//   `BlifParser.java`, `HdlContentEditor.java`, `GenericInterfaceComponent.java`,
//   `VhdlHdlGeneratorFactory.java`, and the parsing half of `VhdlParser.java` (`LogisimVhdl`
//   has its own port of that, for the `<vhdl>` element: a different code path).
//
//   Note the port-count consequence, stated rather than hidden: Java derives a VHDL/BLIF
//   component's ports from its parsed content, so a placed `<comp name="VHDL Entity">` here has
//   no ports. No corpus file places one. Before this file it was an `UnresolvedComponent`, also
//   with no ports, so this is not a regression, but it is not finished either.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// THE CONTENT ATTRIBUTE, WHICH IS THE WHOLE GAME FOR #TCL
//
// `HdlContentAttribute.parse` is not "store the string":
//
//     public C parse(String value) {
//       C content = contentFactory.get(); // a fresh component, holding the TEMPLATE
//       if (!content.compare(value)) content.setContent(value);
//       return content;
//     }
//
// and `HdlContent.compare` flattens `\r\n|\r|\n` to a space before comparing. So a file whose
// content differs from the template only in line endings parses back to the TEMPLATE, with the
// template's own separators, which then equals the factory default and is dropped on save.
// That is exactly what 90 of the 177 corpus `#TCL` blocks need: they are CRLF (`&#13;`) copies
// of an LF template.
//
// One asymmetry is real and is reproduced deliberately. `TclGeneric.ContentAttribute.parse`
// builds a plain `VhdlContentComponent`, the **VHDL** template, while
// `TclGenericAttributes`' default is a `TclVhdlEntityContent`, the **TCL** template. So the
// parse baseline and the attribute default are different strings for `TclGeneric` and the same
// string for `VHDL Entity`. `hdlContentAttribute(parseBaseline:)` takes the baseline as a
// parameter for precisely this reason; collapsing the two would silently break the 87 corpus
// files whose content is the TCL template verbatim.
//
// The three templates below are byte-identical to the Java resources
// (`resources/logisim/{tcl/entity,hdl/vhdl,hdl/blif}.templ`) and are generated from them rather
// than transcribed. `loadTemplate()` reads them line by line and re-joins with
// `System.lineSeparator()`, which on macOS is `\n`, so the literal and the resource agree.

import Foundation
import LogisimFile
import LogisimKernel

// MARK: - HDL content templates

/// `resources/logisim/tcl/entity.templ`, `TclVhdlEntityContent`'s TEMPLATE.
let tclEntityTemplate = """
library ieee;
use ieee.std_logic_1164.all;

entity TCL_Generic is
  port(
    --Insert input ports below
    horloge_i  : in  std_logic;                    -- input bit example
    val_i      : in  std_logic_vector(3 downto 0); -- input vector example

	  --Insert output ports below
    max_o      : out std_logic;                    -- output bit example
    cpt_o      : out std_logic_Vector(3 downto 0)  -- output vector example
  );
end TCL_Generic;

"""

/// `resources/logisim/hdl/vhdl.templ`, `VhdlContentComponent`'s TEMPLATE.
let vhdlEntityTemplate = """
--------------------------------------------------------------------------------
-- HEIG-VD, institute REDS, 1400 Yverdon-les-Bains
-- Project :
-- File    :
-- Autor   :
-- Date    :
--
--------------------------------------------------------------------------------
-- Description :
--
--------------------------------------------------------------------------------

library ieee;
  use ieee.std_logic_1164.all;
  --use ieee.numeric_std.all;

entity VHDL_Component is
  port(
  ------------------------------------------------------------------------------
  --Insert input ports below
    horloge_i  : in  std_logic;                    -- input bit example
    val_i      : in  std_logic_vector(3 downto 0); -- input vector example
  ------------------------------------------------------------------------------
  --Insert output ports below
    max_o      : out std_logic;                    -- output bit example
    cpt_o      : out std_logic_vector(3 downto 0)  -- output vector example
    );
end VHDL_Component;

--------------------------------------------------------------------------------
--Complete your VHDL description below
architecture type_architecture of VHDL_Component is


begin


end type_architecture;

"""

/// `resources/logisim/hdl/blif.templ`, `BlifContentComponent`'s TEMPLATE.
let blifCircuitTemplate = """
# A subset of BLIF is supported.
# Only one model is defined.
# All lines not beginning with '.' (after trimming) are ignored.
# Custom gates (via truth table) cannot be specified.
# Instead, a set of predefined subcircuits exist for various gates.

# The value of the .model statement is usually set to the top module name.
# For that reason, it is used to set a visible label.

.model lightswitch
.inputs button reset
.outputs light_out

# These three .names statements are the only .names statements permitted.
# They are ignored.
.names $false
.names $true
1
.names $undef

# gates can be placed with .subckt or .gate.
# An example of a binary gate would be: .subckt OR A=in_a B=in_b Y=output
# Various gates are supported.
# However, the definition of new subcircuits is not supported.
# The expectation is that your BLIF will come from synthesis.
.subckt NOT A=light Y=light_inv
.subckt DFFSR C=button D=light_inv Q=light R=reset S=$false

# Buffers may be specified using the BUF gate, similar to NOT above.
# '.conn' has the same effect.
.conn light light_out

# ignored
.end

# The goal of this subset is to be sufficiently compatible with Yosys.
# You can find an example of the necessary cell files in the 'examples/cmos' directory of Yosys.
# An example Yosys script:

# read_verilog example.v
# read_verilog -lib yosys-cmos/cmos_cells.v
# check -assert
# synth -flatten -top example
# dfflibmap -liberty yosys-cmos/cmos_cells.lib
# abc -liberty yosys-cmos/cmos_cells.lib
# opt_clean
# write_blif -icells -conn example.blif

# The libraries can be expanded somewhat, also.

# The full list of binary gates:
# BUS, TRIS, TRISI, AND, OR, XOR, NAND, NOR, NXOR, ANDNOT, ORNOT
# BUS is essentially two buffers.
# TRIS is a buffer which only sends A to Y when B is high.
# TRISI is like TRIS but with the B input inverted.
# ANDNOT is A & !B ; ORNOT is A | !B.
# The rest should be self-explanatory.
# The unary gates are NOT and BUF.
# Then there are the special gates:
# MUX A=. B=. S=. Y=. outputs A to Y if S isn't high, outputs B to Y if S is high.
# DFFSR is a D flip-flop with asynchronous set/reset pins.
# DFF is like DFFSR but without the S/R pins. Honestly not that much to say here.
# DLATCH D=. E=. Q. continually sets Q to D while (and only while) E is high. 
# PULLUP/PULLDOWN are very special; they change the default state of a line if nothing else is driving it.
# PULLUP/PULLDOWN do not work with lines directly connected to external inputs (inputs outside of the BLIF).
# They will likely create very hard-to-find internal logic error states if you try.

# Something worth keeping in mind is that the BLIF simulation processes all combinatorial logic
#  until it settles (or it runs out of time), then flip-flops/'sequential logic', then updates combinatorial logic again.
# This is important for D-flip-flop consistency across registers larger than 1 bit (i.e. for counters).

"""

// MARK: - HdlContent, reduced to its codec surface

/// `HdlContent.compare(String)` / `VhdlContentComponent.compare(String)`:
/// `a.replaceAll("\\r\\n|\\r|\\n", " ").equals(b.replaceAll(…))`.
///
/// Line-ending-insensitive, not whitespace-insensitive; a tab or a doubled space still
/// differs. Ported exactly, because it is the test that decides whether a CRLF copy of the
/// template is recognised as the template.
/// Iterates **unicode scalars**, not `Character`s. Swift's `Character` is a grapheme cluster and
/// `"\r\n"` is a single one, so a `Character`-level `== "\r"` or `== "\n"` test never matches a
/// CRLF pair and the whole comparison silently degenerates to string equality. That is the same
/// trap `XmlWriter.addAttributeSetContent`'s newline test fell into, and it is worth naming
/// twice: Java's `replaceAll` works on UTF-16 code units, where `\r` and `\n` are separate.
func hdlContentMatches(_ lhs: String, _ rhs: String) -> Bool {
  func flatten(_ text: String) -> String {
    var out = String.UnicodeScalarView()
    out.reserveCapacity(text.unicodeScalars.count)
    var pendingCarriageReturn = false
    for scalar in text.unicodeScalars {
      if pendingCarriageReturn {
        pendingCarriageReturn = false
        // `\r\n` is ONE alternative in Java's `"\\r\\n|\\r|\\n"`, and the alternation is
        // ordered, so a CRLF pair becomes a single space rather than two.
        if scalar == "\n" { continue }
      }
      switch scalar {
      case "\r":
        pendingCarriageReturn = true
        out.append(" ")
      case "\n":
        out.append(" ")
      default:
        out.append(scalar)
      }
    }
    return String(out)
  }
  return flatten(lhs) == flatten(rhs)
}

/// `com.cburch.logisim.std.hdl.HdlContentAttribute<C>`, narrowed to the string it wraps.
///
/// Java's value is a live `HdlContent` object that also carries the parsed entity name, port
/// list and architecture. Nothing in the `.circ` codec reads any of those, `toStandardString`
/// is `value.getContent()` and the writer's default test compares those strings, and the port
/// list is what a not-ported `propagate` would have needed. So the attribute value here is the
/// content text, and `parse` reproduces the template-substitution behaviour described in the
/// file header.
///
/// `toStandardString` deliberately does NOT scrub control characters the way `Attribute`'s base
/// implementation does: Java overrides it, and scrubbing would corrupt a tab-indented template.
func hdlContentAttribute(parseBaseline: @escaping @Sendable () -> String) -> Attribute<String> {
  Attribute(
    name: "content",
    codec: AttributeCodec(
      parse: { text in
        let baseline = parseBaseline()
        return hdlContentMatches(baseline, text) ? baseline : text
      },
      toStandardString: { $0 },
      encode: { .string($0) },
      decode: { if case .string(let text) = $0 { return text } else { return nil } }))
}

// MARK: - #TCL

/// `com.cburch.logisim.std.tcl.TclComponentAttributes.ContentFileAttribute`.
///
/// Java's value is a `java.io.File`; `toStandardString` is `file.getPath()` and `parse` is
/// `new File(path)`, so the round trip is the path string and nothing else. Modelled as a
/// `String` for that reason. `XmlWriter` has a special branch keyed on the attribute *name*
/// `"filePath"` that rewrites the value relative to the output file, so the name matters.
let tclContentFileAttribute: Attribute<String> = Attributes.forString("filePath")

/// `TclComponentAttributes()`: `contentFile = new File(System.getProperty("user.home"))`.
///
/// Environment-dependent in Java and here, and harmless in both: the tool's live value and the
/// factory default are produced by the same expression, so they are always equal and the
/// attribute is never written. It would only become visible if a `.circ` carried an explicit
/// `filePath`, which none in the corpus does.
private var tclDefaultContentFilePath: String { NSHomeDirectory() }

/// `com.cburch.logisim.std.tcl.TclConsoleReds`.
///
/// NOT PORTED: `paintInstance`, and the whole `TclComponent`/`TclWrapper` simulation path (see
/// the file header). Java's port list is fixed for this component but is built by
/// `TclComponent`'s content-driven machinery, which is not here; ports are therefore empty.
public final class TclConsoleReds: InstanceFactoryBase {
  /// `TclConsoleReds._ID`. Do NOT change: `.circ` files reference this string.
  public static let id = "TclConsoleReds"

  public init() {
    super.init(TclConsoleReds.id, displayName: "TCL REDS console")
    // `TclComponentAttributes.getAttributes()`, in order.
    setAttributes([
      tclContentFileAttribute.binding(tclDefaultContentFilePath),
      StdAttr.label.binding(""),
      StdAttr.labelFont.binding(StdAttr.defaultLabelFont),
    ])
  }

  /// See the file header: the Tcl interpreter is not driven from this port, so a placed TCL
  /// component holds its outputs. A no-op rather than the inherited trap, because reaching it
  /// is a user action (placing the component) and not a port defect.
  public override func propagate(_ state: any InstanceState) throws {}
}

/// `TclGeneric.CONTENT_ATTR`, whose parse baseline is a plain `VhdlContentComponent`, the VHDL
/// template, even though `TclGenericAttributes`' default is the TCL one. See the file header.
let tclGenericContentAttribute: Attribute<String> = hdlContentAttribute(
  parseBaseline: { vhdlEntityTemplate })

/// `com.cburch.logisim.std.tcl.TclGeneric`.
///
/// NOT PORTED: `paintInstance`, `configureNewInstance`'s `HdlModelListener` registration,
/// `updatePorts` (content-derived), and the `TclWrapper` simulation path.
public final class TclGeneric: InstanceFactoryBase {
  /// `TclGeneric._ID`. Do NOT change: `.circ` files reference this string.
  public static let id = "TclGeneric"

  public init() {
    super.init(TclGeneric.id, displayName: "TCL generic")
    // `TclGenericAttributes.attributes`, in order:
    // {CONTENT_FILE_ATTR, TclGeneric.CONTENT_ATTR, StdAttr.LABEL, StdAttr.LABEL_FONT}.
    setAttributes([
      tclContentFileAttribute.binding(tclDefaultContentFilePath),
      tclGenericContentAttribute.binding(tclEntityTemplate),
      StdAttr.label.binding(""),
      StdAttr.labelFont.binding(StdAttr.defaultLabelFont),
    ])
  }

  public override func propagate(_ state: any InstanceState) throws {}
}

/// `com.cburch.logisim.std.tcl.TclLibrary`.
public final class TclLibrary: Library {
  /// `TclLibrary._ID`. Do NOT change: `<lib desc="#TCL">` resolves against it.
  public override class var libraryId: String { "TCL" }

  /// `DESCRIPTIONS`, in upstream's order. Memoised for the identity reason every library file
  /// in this port records: `AddTool.sharesSource` and `Library.contains` compare factories by
  /// reference (D4).
  private lazy var cachedTools: [Tool] = [
    AddTool(factory: TclConsoleReds()),
    AddTool(factory: TclGeneric()),
  ]

  public override var tools: [Tool] { cachedTools }
}

// MARK: - #HDL-IP

/// `VhdlEntityComponent.CONTENT_ATTR`, `new HdlContentAttribute<>(VhdlContentComponent::create)`.
let vhdlEntityContentAttribute: Attribute<String> = hdlContentAttribute(
  parseBaseline: { vhdlEntityTemplate })

/// `BlifCircuitComponent.CONTENT_ATTR`, `new HdlContentAttribute<>(BlifContentComponent::create)`.
let blifCircuitContentAttribute: Attribute<String> = hdlContentAttribute(
  parseBaseline: { blifCircuitTemplate })

/// `VhdlSimConstants.SIM_NAME_ATTR`. Hidden upstream, and excluded from saving by
/// `VhdlEntityAttributes.isToSave`; expressed as `isToSave: false` on the attribute itself,
/// which is observationally identical because it appears in exactly one attribute set.
let vhdlSimNameAttribute: Attribute<String> = Attribute(
  name: "vhdlSimName",
  isHidden: true,
  isToSave: false,
  codec: AttributeCodec(
    parse: { $0 },
    toStandardString: { $0 },
    encode: { .string($0) },
    decode: { if case .string(let text) = $0 { return text } else { return nil } }))

/// `com.cburch.logisim.std.hdl.VhdlEntityComponent`.
///
/// Distinct from `LogisimVhdl`'s `VhdlEntity`, which is `com.cburch.logisim.vhdl.base.VhdlEntity`
/// : the `<vhdl>`-element entity, a different class with a different `_ID`. Both exist in 4.1.0.
///
/// NOT PORTED: `paintInstance`, `VhdlHdlGeneratorFactory`, `setSimName`/`getSimName`'s use by
/// the Questa simulator bridge, and the content-derived port list.
public final class VhdlEntityComponent: InstanceFactoryBase {
  /// `VhdlEntityComponent._ID`; note the space. Do NOT change.
  public static let id = "VHDL Entity"

  public init() {
    super.init(VhdlEntityComponent.id)
    // `VhdlEntityAttributes.attributes`, in order. `labelVisible` defaults to **false** here,
    // unlike most components: transcribed from the field initialiser, not assumed.
    setAttributes([
      vhdlEntityContentAttribute.binding(vhdlEntityTemplate),
      StdAttr.label.binding(""),
      StdAttr.labelFont.binding(StdAttr.defaultLabelFont),
      StdAttr.labelVisibility.binding(false),
      vhdlSimNameAttribute.binding(""),
    ])
  }

  public override func propagate(_ state: any InstanceState) throws {}
}

/// `com.cburch.logisim.std.hdl.BlifCircuitComponent`.
///
/// NOT PORTED: `BlifParser`, `DenseLogicCircuit`, `paintInstance`, and the content-derived port
/// list; i.e. everything except the attribute set the `.circ` codec needs.
public final class BlifCircuitComponent: InstanceFactoryBase {
  /// `BlifCircuitComponent._ID`. Do NOT change.
  public static let id = "BLIFCircuit"

  public init() {
    super.init(BlifCircuitComponent.id, displayName: "BLIF Component")
    // `BlifCircuitAttributes.attributes`, in order.
    setAttributes([
      blifCircuitContentAttribute.binding(blifCircuitTemplate),
      StdAttr.label.binding(""),
      StdAttr.labelFont.binding(StdAttr.defaultLabelFont),
      StdAttr.labelVisibility.binding(false),
    ])
  }

  public override func propagate(_ state: any InstanceState) throws {}
}

/// `com.cburch.logisim.std.hdl.HdlLibrary`.
public final class HdlLibrary: Library {
  /// `HdlLibrary._ID`. Do NOT change: `<lib desc="#HDL-IP">` resolves against it.
  public override class var libraryId: String { "HDL-IP" }

  private lazy var cachedTools: [Tool] = [
    AddTool(factory: VhdlEntityComponent()),
    AddTool(factory: BlifCircuitComponent()),
  ]

  public override var tools: [Tool] { cachedTools }
}

// MARK: - #BFH-Praktika

/// `com.cburch.logisim.std.bfh.BinToBcd`.
///
/// NOT PORTED: `paintInstance` and `BinToBcdHdlGeneratorFactory` (D6 / D11). Everything that
/// decides values, the attribute, the bounds, the port list and `propagate`, is here.
public final class BinToBcd: InstanceFactoryBase {
  /// `BinToBcd._ID`. Do NOT change.
  public static let id = "Binary_to_BCD_converter"

  /// `BinToBcd.PER_DELAY`.
  private static let perDelay = 1
  /// `BINin`.
  private static let binInput = 0
  /// `InnerDistance`.
  private static let innerDistance = 60

  /// `ATTR_BinBits`, `Attributes.forBitWidth("binvalue", …, 4, 13)`.
  public static let binBits: Attribute<BitWidth> = Attributes.forBitWidth(
    "binvalue", min: 4, max: 13)

  public init() {
    super.init(BinToBcd.id, displayName: "Binary to BCD")
    setAttributes([BinToBcd.binBits.binding(BitWidth.known(9))])
  }

  /// `(int) (Math.log10(1 << bits) + 1.0)`; the number of decimal digits the widest value of
  /// this bit width needs. `getOffsetBounds` and `updatePorts` use `1 << width`, `propagate`
  /// uses `Math.pow(2.0, width)`; the two agree for every width in 4...13.
  private static func digitCount(_ bits: BitWidth) -> Int {
    Int((log10(Double(1 << bits.width)) + 1.0))
  }

  private func bits(_ attributes: any AttributeSet) -> BitWidth {
    attributes.getValue(BinToBcd.binBits) ?? BitWidth.known(9)
  }

  /// `getOffsetBounds(AttributeSet)`.
  public override func offsetBounds(_ attributes: any AttributeSet) -> Bounds {
    let ports = BinToBcd.digitCount(bits(attributes))
    return Bounds.create(
      Int(-0.5 * Double(BinToBcd.innerDistance)), -20, ports * BinToBcd.innerDistance, 40)
  }

  /// `updatePorts(Instance)`.
  public override func ports(_ attributes: any AttributeSet) -> [LogisimStd.Port] {
    let count = BinToBcd.digitCount(bits(attributes))
    var result = [LogisimStd.Port?](repeating: nil, count: count + 1)
    result[BinToBcd.binInput] = LogisimStd.Port(
      Int(-0.5 * Double(BinToBcd.innerDistance)), 0, .input, BinToBcd.binBits)
    var index = count
    while index > 0 {
      result[index] = LogisimStd.Port(
        (count - index) * BinToBcd.innerDistance, -20, .output, 4)
      index -= 1
    }
    return result.compactMap { $0 }
  }

  /// `propagate(InstanceState)`. The `-1` fallback is upstream's: an undefined input drives the
  /// digit outputs from a negative dividend, which is deliberately reproduced rather than
  /// "fixed" (standing rule 4).
  public override func propagate(_ state: any InstanceState) throws {
    let input = state.portValue(BinToBcd.binInput)
    var binValue =
      (input.isFullyDefined() && !input.isUnknown() && !input.isErrorValue())
      ? Int(input.toLongValue()) : -1
    let count = BinToBcd.digitCount(state.attributeValue(BinToBcd.binBits, default: BitWidth.known(9)))
    var index = count
    while index > 0 {
      let place = Int(pow(10.0, Double(index - 1)))
      let digit = binValue / place
      state.setPort(index, Value.createKnown(BitWidth.known(4), Int64(digit)), BinToBcd.perDelay)
      binValue -= digit * place
      index -= 1
    }
  }
}

/// `com.cburch.logisim.std.bfh.BcdToSevenSegmentDisplay`.
///
/// NOT PORTED: `paintInstance` and `BcdToSevenSegmentDisplayHdlGeneratorFactory`.
public final class BcdToSevenSegmentDisplay: InstanceFactoryBase {
  /// `BcdToSevenSegmentDisplay._ID`. Do NOT change.
  public static let id = "BCD_to_7_Segment_decoder"

  private static let perDelay = 1
  private static let segmentA = 0
  private static let segmentG = 6
  private static let bcdIn = 7

  /// The seven-segment patterns, bit 0 = segment A … bit 6 = segment G, indexed by BCD digit.
  private static let segmentPatterns: [Int] = [
    0b0111111, 0b0000110, 0b1011011, 0b1001111, 0b1100110,
    0b1101101, 0b1111101, 0b0000111, 0b1111111, 0b1101111,
  ]

  public init() {
    super.init(BcdToSevenSegmentDisplay.id, displayName: "BCD to seven segment")
    setAttributes([StdAttr.dummy.binding("")])
    setOffsetBounds(Bounds.create(-10, -20, 50, 100))
    setPorts([
      LogisimStd.Port(20, 0, .output, 1),  // SEGMENT_A
      LogisimStd.Port(30, 0, .output, 1),  // SEGMENT_B
      LogisimStd.Port(20, 60, .output, 1),  // SEGMENT_C
      LogisimStd.Port(10, 60, .output, 1),  // SEGMENT_D
      LogisimStd.Port(0, 60, .output, 1),  // SEGMENT_E
      LogisimStd.Port(10, 0, .output, 1),  // SEGMENT_F
      LogisimStd.Port(0, 0, .output, 1),  // SEGMENT_G
      LogisimStd.Port(10, 80, .input, 4),  // BCD_IN
    ])
  }

  /// `setKnown(InstanceState, int)`.
  private func setKnown(_ state: any InstanceState, _ portValues: Int) {
    var remaining = portValues
    for index in BcdToSevenSegmentDisplay.segmentA...BcdToSevenSegmentDisplay.segmentG {
      let bit = (remaining & 1) == 0 ? 0 : 1
      state.setPort(
        index, Value.createKnown(BitWidth.one, Int64(bit)), BcdToSevenSegmentDisplay.perDelay)
      remaining >>= 1
    }
  }

  /// `setUnknown(InstanceState)`.
  private func setUnknown(_ state: any InstanceState) {
    for index in BcdToSevenSegmentDisplay.segmentA...BcdToSevenSegmentDisplay.segmentG {
      state.setPort(
        index, Value.createUnknown(BitWidth.one), BcdToSevenSegmentDisplay.perDelay)
    }
  }

  public override func propagate(_ state: any InstanceState) throws {
    let input = state.portValue(BcdToSevenSegmentDisplay.bcdIn)
    guard input.isFullyDefined(), !input.isErrorValue(), !input.isUnknown() else {
      setUnknown(state)
      return
    }
    let digit = Int(input.toLongValue())
    // Java's `switch` covers 0...9 and sends everything else to `default -> setUnknown`.
    guard digit >= 0, digit < BcdToSevenSegmentDisplay.segmentPatterns.count else {
      setUnknown(state)
      return
    }
    setKnown(state, BcdToSevenSegmentDisplay.segmentPatterns[digit])
  }
}

/// `com.cburch.logisim.std.bfh.BfhLibrary`.
public final class BfhLibrary: Library {
  /// `BfhLibrary._ID`. Do NOT change: `<lib desc="#BFH-Praktika">` resolves against it.
  public override class var libraryId: String { "BFH-Praktika" }

  private lazy var cachedTools: [Tool] = [
    AddTool(factory: BinToBcd()),
    AddTool(factory: BcdToSevenSegmentDisplay()),
  ]

  public override var tools: [Tool] { cachedTools }
}

// MARK: - Registration

/// The three `com.cburch.logisim.std.*` libraries `StdLibraries.registerAll()` still misses.
///
/// ── FOR THE INTEGRATOR ──────────────────────────────────────────────────────────────────────
///
/// 1. `StdLibraries.registerAll()` must call `StdLibrariesExtra.registerAll()`. That file is not
///    this task's to edit; the call is one line and belongs at the end of `registerAll()`.
///
/// 2. `#Soc` is NOT registered here and cannot be. Its factories are
///    `com.cburch.logisim.soc.*`, they live in `LogisimSoc`, and `LogisimSoc` depends on
///    `LogisimStd`, so this module cannot name them. `LogisimSoc/SocLibrary.swift` is the
///    ported `Soc.java` and exposes `SocLibrary.registerBuiltinTools()`; reaching it needs
///    `"LogisimSoc"` added to the `logisim-cli` target's `dependencies` in `Package.swift` and
///    the call made at startup. That is worth 147 files on the migration gate and is the single
///    largest item left in this area.
public enum StdLibrariesExtra {

  /// Registers `#TCL`, `#HDL-IP` and `#BFH-Praktika`. Idempotent; must run before the first
  /// `.circ` load, because `BuiltinLibraryShell` materialises its tools once per registry
  /// generation and caches.
  ///
  /// The closures hand out clones of a single prototype library each: see
  /// `BuiltinFactoryPrototypes` in `StdLibraries.swift`. Constructing `TclLibrary()` inside the
  /// closure, as this used to, re-minted `TclGeneric` and `VhdlEntityComponent` on every
  /// generation bump, and `AddTool.sharesSource` compares factories by reference, so a toolbar
  /// entry cloned before the bump could no longer be attributed to its library afterwards.
  public static func registerAll() {
    let prototypes = BuiltinFactoryPrototypes.self
    BuiltinToolProviders.register(libraryId: Builtin.tclId) { prototypes.fresh(prototypes.tcl) }
    BuiltinToolProviders.register(libraryId: Builtin.hdlId) { prototypes.fresh(prototypes.hdl) }
    BuiltinToolProviders.register(libraryId: Builtin.bfhId) { prototypes.fresh(prototypes.bfh) }
  }
}
