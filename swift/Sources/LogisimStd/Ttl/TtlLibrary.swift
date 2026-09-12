// TtlLibrary.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.ttl.TtlLibrary),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── `FactoryDescription`'s LAZY half is not ported; its DISPLAY-NAME half is ─────────────────
//
// Same reasoning as `Memory/MemoryLibrary.swift` and `Io/IoLibrary.swift`: upstream defers
// factory construction through `FactoryDescription` (the lazy/reflective machinery behind
// JAR-loaded libraries, D11); this port always holds a live `ComponentFactory`, so the library
// just builds every factory once, eagerly. `cachedTools` is memoized for the same identity
// reason those files document: `AddTool.sharesSource` and `Library.tool(named:)` compare
// factories by reference (D4), so a freshly-rebuilt array on every access would hand out
// non-`===`-matching factories.
//
// **But every one of these 61 tools is named by its description, not by its factory**, and this
// library is where that shows up most: `Ttl7400`'s constructor passes no getter, so the factory
// answers "7400", while `DESCRIPTIONS` passes `S.getter("TTL7400")`, which resolves to
// "7400: quad 2-input NAND gate". The explorer sidebar and the palette render the *tool's*
// name, so before `DescribedAddTool` existed this whole library read as a column of bare part
// numbers. `Instance/FactoryDescription.swift` explains the split; the strings below are the
// measured output of `tools/valuebridge/NameBridge.java` against the 4.1.0 jar, not a
// transcription of the `.properties` keys.
//
// The list below is transcribed in upstream's `DESCRIPTIONS` order; that order is what a user
// sees in the tool palette, so it is preserved even though nothing else depends on it.
//
// ── What did not come across ─────────────────────────────────────────────────────────────────
//
//   * `getDisplayName()`'s localisation (`S.get("ttlLibrary")`); the string itself DOES come
//     across; it lives with the library's identity in `LogisimFile/Builtin.swift`'s
//     `BuiltinLibraryShell` table, because that shell, not this class, is the `Library`
//     object the loader hands to the app. This class is registered only as a tool provider.
//   * The `"ttl.gif"` icon filenames threaded through `FactoryDescription`, M6/paint (D6).

import Foundation
import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.std.ttl.TtlLibrary`.
public final class TtlLibrary: Library {

  /// `TtlLibrary._ID`.
  public override class var libraryId: String { "TTL" }

  private lazy var cachedTools: [Tool] = [
    DescribedAddTool(factory: Ttl7400(), displayName: "7400: quad 2-input NAND gate"),
    DescribedAddTool(factory: Ttl7402(), displayName: "7402: quad 2-input NOR gate (right-to-left)"),
    DescribedAddTool(factory: Ttl7404(), displayName: "7404: hex inverter"),
    DescribedAddTool(factory: Ttl7408(), displayName: "7408: quad 2-input AND gate"),
    DescribedAddTool(factory: Ttl7410(), displayName: "7410: triple 3-input NAND gate"),
    DescribedAddTool(factory: Ttl7411(), displayName: "7411: triple 3-input AND gate"),
    DescribedAddTool(factory: Ttl7413(), displayName: "7413: dual 4-input NAND gate(Schmitt trigger)"),
    DescribedAddTool(factory: Ttl7414(), displayName: "7414: hex inverter (Schmitt trigger)"),
    DescribedAddTool(factory: Ttl7418(), displayName: "7418: dual 4-input NAND gate(Schmitt trigger)"),
    DescribedAddTool(factory: Ttl7419(), displayName: "7419: hex inverter (Schmitt trigger)"),
    DescribedAddTool(factory: Ttl7420(), displayName: "7420: dual 4-input NAND gate"),
    DescribedAddTool(factory: Ttl7421(), displayName: "7421: dual 4-input AND gate"),
    DescribedAddTool(factory: Ttl7424(), displayName: "7424: quad 2-input NAND gate (Schmitt trigger)"),
    DescribedAddTool(factory: Ttl7427(), displayName: "7427: triple 3-input NOR gate"),
    DescribedAddTool(factory: Ttl7430(), displayName: "7430: single 8-input NAND gate"),
    DescribedAddTool(factory: Ttl7432(), displayName: "7432: quad 2-input OR gate"),
    DescribedAddTool(factory: Ttl7434(), displayName: "7434: hex buffer gate"),
    DescribedAddTool(factory: Ttl7436(), displayName: "7436: quad 2-input NOR gate"),
    DescribedAddTool(factory: Ttl7442(), displayName: "7442: BCD to decimal decoder"),
    DescribedAddTool(factory: Ttl7443(), displayName: "7443: Excess-3 to decimal decoder"),
    DescribedAddTool(factory: Ttl7444(), displayName: "7444: Gray to decimal decoder"),
    DescribedAddTool(factory: Ttl7447(), displayName: "7447: BCD to 7-segment decoder"),
    DescribedAddTool(factory: Ttl7451(), displayName: "7451: dual AND-OR-INVERT gate"),
    DescribedAddTool(factory: Ttl7454(), displayName: "7454: Four wide AND-OR-INVERT gate"),
    DescribedAddTool(factory: Ttl7458(), displayName: "7458: dual AND-OR gate"),
    DescribedAddTool(factory: Ttl7464(), displayName: "7464: 4-2-3-2 AND-OR-INVERT gate"),
    DescribedAddTool(factory: Ttl7474(), displayName: "7474: dual D-Flipflops with preset and clear"),
    DescribedAddTool(factory: Ttl7485(), displayName: "7485: 4-bit magnitude comparator"),
    DescribedAddTool(factory: Ttl7486(), displayName: "7486: quad 2-input XOR gate"),
    DescribedAddTool(factory: Ttl7487(), displayName: "7487: 4-bit True/complement, zero/one elements"),
    DescribedAddTool(factory: Ttl74125(), displayName: "74125: quad bus buffer, three-state outputs, negative enable"),
    DescribedAddTool(factory: Ttl74138(), displayName: "74138: 3-line to 8-line decoder"),
    DescribedAddTool(factory: Ttl74139(), displayName: "74139: Dual 2-line to 4-line decoder"),
    DescribedAddTool(factory: Ttl74151(), displayName: "74151: 8-line to 1 line data selector"),
    DescribedAddTool(factory: Ttl74153(), displayName: "74153: dual 4-line to 1 line data selector"),
    DescribedAddTool(factory: Ttl74157(), displayName: "74157: quad 2-line to 1 line data selector"),
    DescribedAddTool(factory: Ttl74158(), displayName: "74158: quad 2-line to 1 line data selector, inverted output"),
    DescribedAddTool(factory: Ttl74161(), displayName: "74161: 4-bit sync counter with async clear"),
    DescribedAddTool(factory: Ttl74163(), displayName: "74163: 4-bit sync counter with sync clear"),
    DescribedAddTool(factory: Ttl74164(), displayName: "74164: 8-bit serial-to-parallel shift register"),
    DescribedAddTool(factory: Ttl74165(), displayName: "74165: 8-bit parallel-to-serial shift register"),
    DescribedAddTool(factory: Ttl74166(), displayName: "74166: 8-bit parallel-to-serial shift register with asynchronous clear"),
    DescribedAddTool(factory: Ttl74175(), displayName: "74175: quad D-flipflop, asynchronous reset"),
    DescribedAddTool(factory: Ttl74181(), displayName: "74181: arithmetic logic unit"),
    DescribedAddTool(factory: Ttl74182(), displayName: "74182: look-ahead carry generator"),
    DescribedAddTool(factory: Ttl74192(), displayName: "74192: 4-bit up/down decade counter"),
    DescribedAddTool(factory: Ttl74193(), displayName: "74193: 4-bit up/down binary counter"),
    DescribedAddTool(factory: Ttl74194(), displayName: "74194: 4-bit bidirectional universal shift register"),
    DescribedAddTool(factory: Ttl74240(), displayName: "74240: octal buffers with three-state inverted outputs"),
    DescribedAddTool(factory: Ttl74241(), displayName: "74241: octal buffers with three-state outputs and complementary enables"),
    DescribedAddTool(factory: Ttl74244(), displayName: "74244: octal buffers with three-state outputs"),
    DescribedAddTool(factory: Ttl74245(), displayName: "74245: octal bus transceivers with three-state outputs"),
    DescribedAddTool(factory: Ttl74266(), displayName: "74266: quad 2-input XNOR gate (open-collector)"),
    DescribedAddTool(factory: Ttl74273(), displayName: "74273: octal D-Flipflop with clear"),
    DescribedAddTool(factory: Ttl74283(), displayName: "74283: 4-bit binary full adder"),
    DescribedAddTool(factory: Ttl74299(), displayName: "74299: 8-bit universal shift register with three-state outputs"),
    DescribedAddTool(factory: Ttl74377(), displayName: "74377: octal D-Flipflop with enable"),
    DescribedAddTool(factory: Ttl74381(), displayName: "74381: arithmetic logic unit (ALU)"),
    DescribedAddTool(factory: Ttl74541(), displayName: "74541: Octal buffers with three-state outputs"),
    DescribedAddTool(factory: Ttl74670(), displayName: "74670: 4-by-4 register file with three-state outputs"),
    DescribedAddTool(factory: Ttl747266(), displayName: "747266: quad 2-input XNOR gate"),
  ]

  public override var tools: [Tool] { cachedTools }
}
