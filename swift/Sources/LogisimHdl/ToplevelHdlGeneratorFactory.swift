// ToplevelHdlGeneratorFactory; NOT PORTED. This file exists to say so, and to say why.
//
// Concerns logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// `com/cburch/logisim/fpga/hdlgenerator/ToplevelHdlGeneratorFactory.java` (397 lines).
// GPL-3.0-only with the rest of the port. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ══ WHAT IT IS ══════════════════════════════════════════════════════════════════════════════
//
// The one generator that assembles a *whole design*: it wraps the top circuit's
// `CircuitHdlGeneratorFactory` in an entity whose ports are the FPGA's physical pins, adds the
// tick generator and the synthesized clock, declares the LED-array and scanning-seven-segment
// drivers, and wires every "bubble", one on-board LED, switch, button or segment, to the
// component that maps onto it.
//
// ══ WHY IT IS NOT HERE ══════════════════════════════════════════════════════════════════════
//
// **This section was stale and is now corrected.** It used to say the whole board and
// pin-mapping model was unported. Most of it is:
//
//     PORTED   FpgaIoInformationContainer, IoComponentTypes, BoardInformation, FpgaBoardRectangle,
//              FpgaClass, PinActivity, PullBehaviors, IoStandards, DriveStrength,
//              LedArrayDriving, SevenSegmentScanningDriving, ComponentMapInformationContainer,
//              BoardReaderClass/BoardWriterClass : 29 of 29 shipped boards and 1,440 IO
//              components byte-identical against `BoardReaderClass` driven inside the jar.
//     PORTED   MapComponent, as `Fpga/FpgaMapComponent.swift`: 800 lines, gated at 800
//              components / 2,842 pins against the real class inside the jar.
//     PORTED   `Netlist.constructHierarchyTree` / `enumerateGlobalBubbleTree` /
//              `getMappableResources`; the bubble numbering this file's port maps read.
//
// What is genuinely left between here and a synthesizable toplevel is now **two files**:
//
//     MappableResourcesContainer.java (219) : a map from hierarchy path to `MapComponent`,
//         filled by `getMappableResources`, plus `Circuit.setBoardMap` and a `ProjectActions`
//         save that is UI. Its three `getMapped*PinNames()` accessors are what this file reads.
//     ComponentMapParser.java (147)         : parses a standalone `.xml` map into the above.
//
// plus, sideways, `com.cburch.logisim.circuit.CircuitHdlGeneratorFactory` (639) and the
// `std.io` LED-array / scanning-seven-segment drivers, which belong with the per-component
// generators. `Fpga/FpgaNotPorted.swift` is the authoritative ledger; keep it and this in step.
//
// Porting this file in isolation would still produce a type that cannot be constructed, but
// the distance is now two files, not twenty-two.
//
// ── This is a DEFERRAL, not a D11 exclusion ─────────────────────────────────────────────────
//
// Being explicit, because the distinction matters and the task that produced this file asked
// for it: D11 permanently excludes *vendor toolchains* (Vivado, ISE, Quartus, QuestaSim);
// there is no macOS build of any of them, so shelling out to them is out of scope forever. It
// does **not** exclude generating HDL, and the open path it names (ghdl, yosys, nextpnr-ecp5,
// ecppack, openFPGALoader) needs exactly this file to produce something synthesizable for a
// real board. `ToplevelHdlGeneratorFactory` is therefore *deferred behind* the board model, not
// ruled out.
//
// The neighbouring `XilinxSeries7SynthesizedClockHdlGeneratorFactory.java` IS a D11 exclusion,
// see `SynthesizedClockHdlGeneratorFactory.swift`, which already records it, because a Series-7
// MMCM primitive is only synthesizable by Vivado.
//
// ── What DOES work without it ───────────────────────────────────────────────────────────────
//
// Everything below the toplevel: `Netlist` (this module's `Netlist/` directory) resolves a
// circuit's connection graph, and `AbstractHdlGeneratorFactory` + `Hdl` + `HdlPorts`/`HdlWires`/
// `HdlParameters` turn one component plus that netlist into entity/architecture text. What is
// missing is the *board-facing wrapper*, and `CircuitHdlGeneratorFactory` (the per-circuit
// generator, `com/cburch/logisim/circuit/CircuitHdlGeneratorFactory.java`) which is likewise
// not ported; it belongs with the component generators that come back to `LogisimStd` once the
// component library is complete (see `Package.swift`'s note on the `LogisimHdl` target).
//
// ── When it lands ───────────────────────────────────────────────────────────────────────────
//
// Order of work, cheapest first: `MappableResourcesContainer` -> `ComponentMapParser` ->
// `CircuitHdlGeneratorFactory` -> this file. Nothing in this module needs to change shape for
// any of it; `Netlist` already exposes every count the constructor reads:
// `numberOfClockTrees`, `inputPorts`/`outputPorts`/`inOutPorts` and their bit counts, and now
// `numberOfInputBubbles`/`numberOfOutputBubbles`/`numberOfInOutBubbles`, which return real
// values rather than zero.
//
// Deliberately no stub type: an `HdlGeneratorFactory` conformer that cannot generate anything
// is worse than an absence, because it compiles and callers can reach it.
