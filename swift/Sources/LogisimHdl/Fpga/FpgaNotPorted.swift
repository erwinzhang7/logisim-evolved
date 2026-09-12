// FpgaNotPorted.swift: part of logisim-evolved.
//
// The ledger for `com.cburch.logisim.fpga`: what this directory ports, what it does not, and,
// for each omission, whether it is a D11 exclusion, a D9/D17 UI boundary, or a **deferral**
// waiting on something specific. Deliberately code-free; it exists so the next person does not
// have to re-derive the boundary from 5,599 lines of Java.
//
// Reference tree: `upstream-java-4.1.0` (D16). GPL-3.0-only. See LICENSE.md.
//
// ══ Real file and line counts, measured ═════════════════════════════════════════════════════
//
//   com/cburch/logisim/fpga/data/   22 files, 4,657 lines
//   com/cburch/logisim/fpga/file/    6 files, 942 lines
//                                   ── total 5,599 lines in the two packages this task names.
//
// Plus the two consumers up the chain:
//   com/cburch/logisim/circuit/CircuitHdlGeneratorFactory.java          639 lines
//   com/cburch/logisim/fpga/hdlgenerator/ToplevelHdlGeneratorFactory.java  397 lines
//
// ══ PORTED: 12 of the 22 `data` files, 2 of the 6 `file` files ═════════════════════════════
//
//   data/PinActivity.java                 45 ─┐
//   data/PullBehaviors.java               63  │
//   data/IoStandards.java                 66  ├─ Fpga/FpgaPinAttributes.swift
//   data/DriveStrength.java               70  │  (+ the vendor table from
//   data/LedArrayDriving.java             73  │   settings/VendorSoftware.java)
//   data/SevenSegmentScanningDriving.java 60 ─┘
//   data/IoComponentTypes.java           600 ── Fpga/IoComponentTypes.swift (minus paintPartialMap)
//   data/BoardRectangle.java             205 ── Fpga/FpgaBoardRectangle.swift
//   data/FpgaClass.java                  184 ── Fpga/FpgaClass.swift
//   data/BoardInformation.java           152 ── Fpga/BoardInformation.swift
//   data/FpgaIoInformationContainer.java 1157 ─ Fpga/FpgaIoInformationContainer.swift
//                                                (lines 1–857; 858–1157 are Swing)
//   data/ComponentMapInformationContainer.java 112 ── Fpga/ComponentMapInformationContainer.swift
//   file/BoardReaderClass.java           273 ── Fpga/BoardReader.swift
//   file/BoardWriterClass.java           199 ── Fpga/BoardWriter.swift (XML half)
//   file/ImageXmlFactory.java            254 ── Fpga/BoardImageCodec.swift (codec half)
//
// Verified, not merely read: `tools/hdlbridge/BoardBridge.java` drives the real
// `BoardReaderClass` inside `logisim-evolution-4.1.0-all.jar` over all 29 bundled board XMLs;
// `LogisimHdlTests/BoardGateTests` diffs the Swift model against that oracle field by field.
// **29 of 29 boards, 1,440 IO components, identical.** `tools/hdlbridge/synthcheck.py` does the
// same for the eight synthetic fixtures in `BoardModelTests` that cover paths no shipped board
// reaches.
//
// ══ NOT PORTED: D9/D17, the board editor and the mapping GUI ═══════════════════════════════
//
// Nine `data` files and two `file` files are Swing, and nothing below the UI reads them:
//
//   data/BoardManipulatorListener.java     17   a listener interface for the editor canvas
//   data/IoComponentsListener.java         16   ditto
//   data/FpgaCommanderListModel.java       85   a `javax.swing.AbstractListModel`
//   data/MapListModel.java                129   ditto, plus `MapInfo`
//   data/IoComponentsInformation.java     231   holds a `JPanel`, an `Image`, a scale factor
//   data/ConstantButton.java              111   a `JButton` subclass for the map dialog
//   data/SimpleRectangle.java             115   the rubber-band rectangle the editor drags
//   file/PngFileFilter.java                31   `javax.swing.filechooser.FileFilter`
//   file/XmlFileFilter.java                32   ditto
//
// plus, inside the ported files: `FpgaIoInformationContainer.paint`/`mouseMoved`/`edit`,
// `IoComponentTypes.paintPartialMap`, and `BoardWriterClass.printXml`. `getPartialMapInfo`,
// the geometry those painters consume, **is** ported, so a renderer written against
// `LogisimRender` needs no arithmetic from here.
//
// The picture seam, stated once: `BoardInformation.image` is a `BoardImage`, which is either
// JPEG bytes or raw RGB. Turning it into a `CGImage` is the UI's job and is two calls
// (`CGImageSourceCreateWithData`, or a `CGDataProvider` at 8 bits/component and 24 bits/pixel).
// Nothing in this module imports CoreGraphics and nothing needs to (D9).
//
// ══ PORTED, 2026-09-05, `data/MapComponent.java` (800 lines) ═══════════════════════════════
//
//   data/MapComponent.java (instance half) ── Fpga/FpgaMapComponent.swift
//   data/MapComponent.java (static half)   ── LogisimFile/XmlReaderSupport.swift, as
//                                             `MapComponent`, it was already there, because
//                                             the `.circ` reader needs `getMapInfo(Element)`
//                                             and `LogisimFile` sits below this module.
//
// **The `LogisimStd` edge was broken by injection**, not by adding the edge. `MapComponent`
// imports `std.io.RgbLed` and `std.io.SevenSegment`; `LogisimHdl` may not depend on
// `LogisimStd`, because the per-component generators need `LogisimStd -> LogisimHdl` and the
// pair would close a cycle. `Fpga/FpgaStdIoFacts.swift` takes the four values that requires,
// and it is four, enumerated by grepping every `std.io` reference out of `fpga/data`, not
// estimated. `LogisimHdlWiring` supplies them; it is the one target that sees both modules.
//
// The bubble counts are a **separate** injection with a different owner:
// `HdlGeneratorLookup.mapInformation(for:)`, keyed by factory name, because the answer depends
// on the instance's attributes (a `7-Segment Display` is 7 or 8 bubbles by `ATTR_DP`).
//
// The second blocker is also gone: `Netlist.constructHierarchyTree` and
// `enumerateGlobalBubbleTree` are ported, so `getGlobalBubbleId` has real values and the
// constructor has a path. `MappableComponent` now has its conformer.
//
// Verified, not merely read: `NetlistBridge.dumpMappableResources` builds the real
// `MapComponent` inside the jar for every mappable resource of every DRC-passing corpus
// circuit; `MapComponentGateTests` diffs **800 components / 2,842 pins**. That covers everything
// an *unmapped* component answers. The mapping mutators are **not** covered, no corpus file
// carries a saved pin map, and `FpgaMapComponent.swift`'s header says so at the site.
//
// ══ NOT PORTED; the two that are now the whole remaining gap ════════════════════════════════
//
// ── 1. `data/MappableResourcesContainer.java` (219 lines) ────────────────────────────────────
//
// No longer blocked. `Netlist.mappableResources(hierarchy:isTopLevel:)` is ported and
// `FpgaMapComponent` is constructible, so this is now a straight port of a map from hierarchy
// path to `FpgaMapComponent` plus `updateMapableComponents`. Two of its calls need adapting:
// `Circuit.setBoardMap` exists in `LogisimFile` as `Circuit.addLoadedMap`/`getMapInfo`, and
// `ProjectActions.doSave(myCircuit.getProject())` is UI (D9) and belongs to the caller.
//
// Its three `getMapped*PinNames()` accessors are what `ToplevelHdlGeneratorFactory` reads, so
// this is the *last* thing between the board model and a synthesizable toplevel.
//
// ── 2. `data/ComponentMapParser.java` (147 lines) ────────────────────────────────────────────
//
// Blocked on 1: it parses a standalone `.xml` map file straight into a
// `MappableResourcesContainer`.
//
// ── Still blocked on the same edge, and it is now the ONLY thing that is ─────────────────────
//
// `IoComponentTypes.getInputLabel`/`getOutputLabel`/`getIoLabel` and
// `FpgaIoInformationContainer.getPinName` need `SevenSegment.getOutputLabel(int)` and
// `RgbLed.getLabel(int)`: both already declared on `FpgaStdIoFacts`, so the injection is in
// place and unused. What they *additionally* need is the `S` resource bundle for the fallback
// `S.get("FpgaIoPins", id)`, which D5 records as not coming across, and `getPinName` also wants
// `instanceof SevenSegment || instanceof HexDigit` plus `SevenSegment.ATTR_DP`. Those are
// display strings for the mapping GUI, so they belong above D9's line; the fifth
// `FpgaStdIoFacts` entry they would need is an `isSevenSegmentOrHexDigit` predicate of exactly
// the same shape as `isRgbLed`.
//
// ══ NOT PORTED, up the chain ═══════════════════════════════════════════════════════════════
//
//   `circuit/CircuitHdlGeneratorFactory.java` (639) , needs the component generators, which
//       are themselves waiting on the `LogisimStd -> LogisimHdl` edge (task #32).
//   `fpga/hdlgenerator/ToplevelHdlGeneratorFactory.java` (397): needs
//       `MappableResourcesContainer` above, and the LED array / scanning-seven-segment drivers
//       from `std.io`. See `ToplevelHdlGeneratorFactory.swift`: still a **deferral, not a D11
//       exclusion**. D11 rules out vendor toolchains, and the open path (ghdl, yosys, nextpnr,
//       openFPGALoader) needs precisely this file. Its own NOT-PORTED note used to claim the
//       board model was unported and has been corrected.
//
// ══ D11 confirmations found while surveying ═════════════════════════════════════════════════
//
// `settings/VendorSoftware.java` resolves per-vendor toolchain binaries out of `AppPreferences`
// (`QuartusToolPath`, `ISEToolPath`, `VivadoToolPath`, `OpenFpgaToolPath`). Three of the four
// are D11 exclusions with no macOS build. Only the **vendor name table** is needed to read a
// board, `Vendor="ALTERA"` must decode to id 0 whether or not Quartus exists, and that is all
// `FpgaVendor` in `FpgaPinAttributes.swift` ports. Note the id survives into
// `BoardWriterClass`'s output, so getting the table order wrong would corrupt written boards
// even on a machine with no vendor tool installed at all.
