// VhdlNotPorted: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution),
// GPL-3.0-only. See LICENSE.md. Reference tree: upstream-java-4.1.0 (D16).
//
// This file contains no code. It is the module's NOT-PORTED manifest: every one of the 22
// `.java` files under `com/cburch/logisim/vhdl/` accounted for, so a gap is a decision on the
// record rather than something nobody noticed. That convention is used throughout this port,
// and the reason is measured: "each half is individually correct and nothing owns the join" is
// the largest defect class here (see `tools/seamcheck.py`'s header), and an unrecorded gap is
// indistinguishable from an oversight.
//
// ══ INVENTORY ══════════════════════════════════════════════════════════════════════════════
//
// Counted 2026-09-05 with
//   find upstream-java-4.1.0/src/main/java/com/cburch/logisim/vhdl -name '*.java'
// → 22 files: 10 in `base/`, 1 in `file/`, 5 in `gui/`, 5 in `sim/`, 1 at the package root.
//
//   ── base/ (10) ──────────────────────────────────────────────────────────────────────────
//   HdlContent.java              → HdlContent.swift                          PORTED
//   HdlModel.java                → HdlModel.swift                            PORTED
//   HdlModelListener.java        → HdlModel.swift (folded in)                PORTED
//   VhdlContent.java             → VhdlContent.swift                         PORTED
//   VhdlEntityAttributes.java    → VhdlEntityAttributes.swift                PORTED
//   VhdlParser.java              → VhdlParser.swift                          PORTED
//   VhdlSimConstants.java        → VhdlSimConstants.swift              PORTED, minus one method
//   VhdlEntity.java              → VhdlEntity.swift                    PARTIAL, see (1)
//   VhdlAppearance.java          →: NOT PORTED, see (2)
//   VhdlHdlGeneratorFactory.java →: NOT PORTED, see (3)
//
//   ── file/ (1) ───────────────────────────────────────────────────────────────────────────
//   HdlFile.java                 → HdlFile.swift                             PORTED
//
//   ── gui/ (5) ────────────────────────────────────────────────────────────────────────────
//   HdlContentEditor.java        →: NOT PORTED, see (4)
//   HdlContentView.java          →: NOT PORTED, see (4)
//   HdlToolbarModel.java         →: NOT PORTED, see (4)
//   VhdlSimState.java            →: NOT PORTED, see (4)
//   VhdlSimulatorConsole.java    →: NOT PORTED, see (4)
//
//   ── sim/ (5) ────────────────────────────────────────────────────────────────────────────
//   VhdlSimulatorVhdlTop.java    → VhdlSimulatorVhdlTop.swift          PARTIAL, see (5)
//   VhdlSimulatorTclComp.java    → VhdlSimulatorTclComp.swift          PARTIAL, see (5)
//   VhdlSimulatorTop.java        → VhdlSimConstants.swift (State only) NOT PORTED, see (5)
//   VhdlSimulatorTclBinder.java  →: NOT PORTED, see (5)
//   VhdlSimulatorListener.java   →: NOT PORTED, see (5)
//
//   ── package root (1) ────────────────────────────────────────────────────────────────────
//   Strings.java                 →: NOT PORTED, see (6)
//
// ══ REASONS ════════════════════════════════════════════════════════════════════════════════
//
// (1) `VhdlEntity`: the component factory, not the model.
//
//     Java's `VhdlEntity extends InstanceFactory implements HdlModelListener`. What ports here
//     is the handful of pure functions deriving HDL identifiers from content and attributes.
//     What does not:
//       * `configureNewInstance`, `createAttributeSet`, `getOffsetBounds`,
//         `instanceAttributeChanged`, `updatePorts`, `getPins`: `Instance`/`InstanceFactory`/
//         `Pin`/`Port` live in `LogisimStd`, which this module does not depend on.
//       * `paintInstance`: drawing (D9), and it goes through `VhdlAppearance`, see (2).
//       * `propagate`: the QuestaSim/ModelSim socket protocol, see (5).
//       * `getCircuitsUsingThis`/`addCircuitUsing`/`removeCircuitUsing`/`removeComponent`:
//         a `WeakHashMap<Component, Circuit>`; `Component`/`Circuit` are `LogisimFile` types.
//         Pure bookkeeping, no logic; a couple of lines once the dependency exists.
//     `VhdlEntity.swift` carries its own NOT-PORTED note for the icon and the dead
//     `WIDTH`/`HEIGHT`/`PORT_GAP`/`X_PADDING` constants.
//
// (2) `VhdlAppearance`; needs the appearance model, which is two modules away.
//
//     37 lines, all of them delegation: `extends CircuitAppearance`, and `create(pins, name,
//     style)` picks between `DefaultClassicAppearance.build`, `DefaultHolyCrossAppearance.build`
//     and `DefaultEvolutionAppearance.build`. `CircuitAppearance` is in `LogisimFile`, the three
//     `Default*Appearance` builders are in `circuit/appear` and are **not ported anywhere yet**
//     (checked: no `DefaultEvolutionAppearance` in `swift/Sources`), and the `CanvasObject`
//     shapes they emit are `LogisimDraw`. Writing a version of this here would mean either
//     adding two dependency edges to `Package.swift` (which this module's owner does not own)
//     or inventing a shape protocol nothing could conform to; the exact seam shape this
//     project keeps paying for. The *style selection* it performs is not lost: the three
//     `AttributeOption`s it switches on are `VhdlAppearanceStyle.classic/.fpga/.evolution` in
//     `VhdlContent.swift`, with the naming trap documented there.
//
// (3) `VhdlHdlGeneratorFactory`: belongs to `LogisimHdl`, not here.
//
//     `extends AbstractHdlGeneratorFactory`, and every type it touches, `Netlist`,
//     `FileWriter`, `Hdl`, `myPorts`, is in `com.cburch.logisim.fpga.*`, which this port
//     places in the `LogisimHdl` module (`AbstractHdlGeneratorFactory.swift`, `FileWriter.swift`,
//     `Hdl.swift` are all already there). `LogisimVhdl` depends on `LogisimKernel` only, and
//     `LogisimHdl` does not depend on `LogisimVhdl`, so this class cannot live in either module
//     as the graph stands. It is ~20 lines of real code: `getGenerationTimeWiresPorts` copies
//     `content.getPorts()` into `myPorts`, and `getArchitecture` emits the generate-remark
//     followed by `content.getLibraries()` and `content.getArchitecture()`. Both inputs are
//     already public on `VhdlContent`. Placing it is an integration decision for whoever owns
//     `Package.swift`, not a translation problem.
//
// (4) `gui/`: D9, all five.
//
//     `HdlContentEditor` and `HdlContentView` are `JPanel`/`JTextArea` editors with
//     `JFileChooser` import/export; `HdlToolbarModel` extends `AbstractToolbarModel` and paints
//     `Icon`s; `VhdlSimState` is a `JPanel` that paints an `Ellipse2D` status dot;
//     `VhdlSimulatorConsole` is a `JTextArea` log pane. D9 keeps AppKit out of the kernel-side
//     modules entirely, so these belong above this module in the UI layer and are a native
//     rewrite rather than a translation.
//
//     What they need from here already exists and is public: `HdlModel`/`HdlModelListener` for
//     change notification (`HdlModel.swift`), `HdlFile.load`/`save` for the import/export
//     buttons (`HdlFile.swift`), `VhdlContent.isValid`/`lastValidationError` for the validate
//     button and the status dot (dialogs converted to data, D9/D17), and `VhdlSimulatorState`
//     for the dot's colour.
//
// (5) `sim/`; D11: VHDL co-simulation requires QuestaSim/ModelSim.
//
//     D11 records this as a permanent functional gap: co-simulation drives an external
//     QuestaSim/ModelSim over a TCL socket, and neither vendor ships a macOS build. What that
//     rules out concretely:
//       * `VhdlSimulatorTclBinder`: `Runtime.exec` of `vsim`, a reader thread over the
//         process's stdout, and a `Socket` handshake.
//       * `VhdlSimulatorTop`: the owning state machine: `SocketClient`, `Project`, `Frame`,
//         `CircuitListener`, plus `generateFiles()` copying four `.tcl`/`.ini` resources into
//         a temp directory. Its `State` enum *is* ported, as `VhdlSimulatorState` in
//         `VhdlSimConstants.swift`, because it is inert data the (also unported) console UI
//         names. The transition rules are not, and neither is `VhdlSimConstants
//         .getVhdlComponents`, which only `VhdlSimulatorTop` calls.
//       * `VhdlSimulatorListener`; a one-method (`stateChanged()`) callback whose only
//         publisher is `VhdlSimulatorTop` and whose only subscribers are the two `gui/` classes
//         in (4). Declaring the protocol with neither end present would be a textbook unwired
//         seam; it is left out until something can be on both ends of it.
//       * `VhdlEntity.propagate`: the line protocol itself (`type:name_port:bits:index`,
//         `"sync"`, then parsing the replies back into `Value`s). Note upstream's non-simulating
//         branch throws `UnsupportedOperationException` after driving every output to UNKNOWN,
//         so a VHDL entity in a circuit is *already* a propagation error without a simulator
//         attached; the port inherits that outcome by not having the component at all.
//     The two generators (`VhdlSimulatorVhdlTop`, `VhdlSimulatorTclComp`) are ported anyway,
//     minus their file writes, because their output is byte-exact generated source that can be
//     tested today and is the part that would be tedious to reconstruct later.
//
// (6) `Strings`: D9, no `LocaleManager`.
//
//     Two lines: a `LocaleManager("resources/logisim", "hdl")`. Localisation does not come
//     across (D9); every user-visible string in this module is the English from
//     `resources/logisim/strings/hdl/hdl.properties` and `std/std.properties`, spelled out at
//     its use site: `VhdlParserError`, `VhdlNameError.message`, `HdlFileError.Kind`. That
//     keeps the strings greppable against the properties files, which is how the parser's error
//     texts were verified.
//
// ══ THE ONE INTEGRATION SEAM THIS MODULE CANNOT CLOSE FROM INSIDE ══════════════════════════
//
// `<vhdl>` elements still do not round-trip through the model. `VhdlContentReader.handler`
// (`LogisimFile/XmlReaderSupport.swift`) and `LogisimFile.makeVhdlEntity` are both nil, so a
// loaded `<vhdl>` becomes a `PreservedVhdlContent`, D8's verbatim placeholder, rather than a
// parsed entity.
//
// `VhdlContent` is *ready* to be the conformer: `VhdlContentReference` needs `name`,
// `VhdlContentSaving` needs `name`/`content`/`aboutToSave()`, and all three are public on it
// with the right shapes. What is missing is an adaptor conforming `VhdlContent` to
// `VhdlContentLoading`, and it cannot live here; `VhdlContentLoading.parse` takes a
// `LogisimFile`, and `LogisimVhdl` does not depend on `LogisimFile` (nor does `LogisimFile`
// depend on `LogisimVhdl`; the dependency would have to go that way and would be a cycle in
// spirit). It needs a module that sees both, i.e. `LogisimUI` or a new adaptor target, plus a
// `Package.swift` edit. Recorded here so the remaining work is a one-line question, "where
// does the adaptor live?": rather than a rediscovery.
//
// The same shape, and the same answer, for `VhdlNameCollisionChecking` in `VhdlContent.swift`:
// its intended conformer is `LogisimFile` (Java passes one to `VhdlContent`'s constructor and
// calls `file.containsFactory(label)`), and it lands in the same adaptor. Omitting it is not
// silent; `VhdlContent.validate` simply skips the duplicate-name check, which is exactly the
// path Java itself takes when it passes a null file.
//
// **`tools/seamcheck.py` reports 19 candidates after this file was added, up from 18, and the
// new line is `VhdlContentLoading`.** That is not a seam this work introduced. The checker only
// reports a protocol with more than two references, `VhdlContentLoading` had exactly two, and
// naming it in the paragraph above is the third, so the effect of writing the gap down was to
// make an already-existing, already-tracked seam visible to the tool. Left that way
// deliberately: wording around it to keep the count at 18 would hide a real defect, and the
// count is not the thing being optimised.

// (No declarations. See above.)
