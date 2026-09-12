// BuiltinHdlWiring: part of logisim-evolved.
//
// SPDX-License-Identifier: GPL-3.0-only
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// THE ONE PLACE THAT SEES BOTH `LogisimStd` AND `LogisimHdl`.
//
// `HdlGeneratorLookup.registerAllBuiltins` holds all 40 per-component HDL generator
// registrations, each verified byte-exact against the 4.1.0 jar. When they landed, **nothing
// called it and nothing could**: no shipping target linked `LogisimHdl`, so `LogisimHdlTests` was
// the only place in the package able to see both modules, and a test target is not a runtime.
// That is the eleventh occurrence of this project's signature defect, and the reason this target
// exists.
//
// It cannot live in either module it joins:
//
//   * `LogisimHdl` must never depend on `LogisimStd`: the per-component generators need
//     `LogisimStd -> LogisimHdl`, so the reverse edge closes a cycle. (This is also what blocks
//     `MapComponent`; see task #38.)
//   * `LogisimStd` cannot depend on `LogisimHdl` for the same reason from the other side.
//
// So the bindings, which read *real* `LogisimStd` attributes (`Comparator.modeAttr`,
// `Shifter.attrShift`, `StdAttr.label`, the `Pla` table, a ROM's `MemContents`) and hand them to
// `HdlGeneratorLookup.BuiltinBindings`, are constructed here, above both, and depended on by the
// two things that actually run: `logisim-cli` and `LogisimUI`.
//
// ── EVERY BINDING IS A REAL ATTRIBUTE OBJECT, NOT A PLAUSIBLE ONE ───────────────────────────
//
// D4: `AnyAttribute` compares by `===`. A binding handed the *wrong* object does not error;
// `containsAttribute` answers false and the generator silently takes its default branch. So each
// field below is the exact `LogisimStd` constant the corresponding factory's attribute set
// actually holds, and each is annotated with the upstream `Attribute` it mirrors. There are no
// stand-ins here: the closest thing to one, `romContents`, would make every ROM emit an all-zero
// lookup table, which is wrong rather than degraded, and is therefore bound to the real
// `MemContents`.
//
// ── PROOF THAT THIS RUNS ────────────────────────────────────────────────────────────────────
//
// `installBuiltins()` returns the installed names rather than `Void`, so a caller can assert the
// call did something. `Tests/LogisimHdlWiringTests/BuiltinHdlWiringInstallationTests.swift` runs the
// built `logisim-cli` binary and asserts its registry is non-empty at startup; deleting the call
// from `main.swift` turns that test red. It does not call `installBuiltins` itself, which would
// prove only that the function works.
// ═════════════════════════════════════════════════════════════════════════════════════════════

import LogisimFile
import LogisimHdl
import LogisimKernel
import LogisimStd

/// Builds the `HdlGeneratorLookup.BuiltinBindings` out of `LogisimStd` and installs the 40
/// builtin registrations into the process-wide lookup.
///
/// Called from `logisim-cli/main.swift` and from `LogisimUI`'s
/// `LogisimFileProjectHostFactory.registerBuiltinLibrariesIfNeeded()`, beside
/// `StdLibraries.registerAll()` in both; a registration living in one executable's `main` is a
/// registration the other executable silently lacks.
public enum BuiltinHdlWiring {

  // MARK: - The bindings

  /// Everything `HdlGeneratorLookup` needs from `LogisimStd`, by identity.
  ///
  /// The gates half is identical in shape to `GatesOracle.bindings`, which the byte-exact gates
  /// differential (952 cases) drives, so these objects are the ones already proven against the
  /// jar, not a second transcription of them.
  public static func bindings() -> HdlGeneratorLookup.BuiltinBindings {
    HdlGeneratorLookup.BuiltinBindings(
      gates: gatesBindings,
      clock: ClockHdlBindings(
        width: StdAttr.width,
        high: Clock.attrHigh,
        low: Clock.attrLow,
        phase: Clock.attrPhase),
      pla: plaBindings,
      // `Comparator.MODE_ATTR`. `Multiplier.java:132` declares the *same* attribute object in its
      // own attribute list, so both fields are correctly the one constant.
      comparatorMode: Comparator.modeAttr,
      multiplierMode: Comparator.modeAttr,
      // `Shifter.ATTR_SHIFT`.
      shifterShift: Shifter.attrShift,
      romContents: romContents,
      io: ioAttributes,
      // `StdAttr.LABEL`, for `ReptarLocalBus.getHDLName`.
      label: StdAttr.label)
  }

  /// `StdAttr.WIDTH`, `GateAttributes.ATTR_INPUTS`, `PlexersLibrary.ATTR_SELECT` and
  /// `BitSelector`'s three attributes.
  ///
  /// `BitSelector.selectAttr` and `.extendedAttr` are `Attributes.forNoSave()` upstream, so their
  /// `getName()` is `null` and they cannot be looked up by name; injection is the only way to
  /// reach them, which is why they are fields rather than name lookups.
  private static let gatesBindings = GatesHdlBindings(
    width: StdAttr.width,
    gateInputs: GateAttributes.inputs,
    plexerSelect: PlexersLibraryAttributes.select,
    bitSelectorGroup: BitSelector.groupAttr,
    bitSelectorSelect: BitSelector.selectAttr,
    bitSelectorExtended: BitSelector.extendedAttr,
    negatedInput: { index in NegateAttributes.attribute(index: index, side: nil) })

  /// `Pla.IN_PORT` / `OUT_PORT` and `Pla.ATTR_TABLE_*`.
  ///
  /// `PlaTable` is a `LogisimStd` type, so the row list is read through a closure for the same
  /// reason `MemContents` is: `LogisimHdl` cannot name it.
  private static let plaBindings = GatesHdlRegistrations.PlaBindings(
    inWidth: Pla.inWidth,
    outWidth: Pla.outWidth,
    inPort: Pla.inPort,
    outPort: Pla.outPort,
    rows: { attrs in
      guard let table = attrs[Pla.table] else { return [] }
      return table.rows.map { PlaHdlRow(inBits: $0.inBits, outBits: $0.outBits) }
    },
    outputSize: { attrs in attrs[Pla.table]?.outSize ?? 0 })

  /// `RomHdlGeneratorFactory.java:29,39`; `attrs.getValue(Rom.CONTENTS_ATTR).get(addr)`.
  ///
  /// Left `nil` this reads every word as zero and the emitted `with … select` table is empty,
  /// which is a wrong ROM rather than a missing one. `Rom.contentsAttr` is the object `Rom`'s own
  /// attribute set holds (`Rom.swift:209` reads it back by the same constant), so the `===` lookup
  /// hits.
  ///
  /// A component that is *not* a `Rom` has no such attribute; `getValue` answers `nil` there and
  /// the word reads zero, matching Java, whose `MemoryRomHdlGeneratorFactory` is only ever reached
  /// through the `Rom` registration.
  private static let romContents: MemoryHdlContentsReader = { attrs, address in
    attrs.getValue(Rom.contentsAttr)?.get(address) ?? 0
  }

  /// The std/io attribute readers, one per upstream `attrs.getValue(...)` the io generators make.
  ///
  /// Each is a closure rather than an attribute object because the io generators ask semantic
  /// questions ("is this `INPUT_ONE_WIRE`?") rather than fetching values, and the option constants
  /// they compare against are `LogisimStd` types too. Every one begins with `containsAttribute`
  /// where upstream's own code tolerates the attribute's absence; `isButtonPressPassive` must
  /// answer `false` for a `DipSwitch`, which has no `ATTR_PRESS`.
  ///
  /// `label` is deliberately not supplied: its default is `IoHdlAttributes.stdAttrLabel`, which
  /// reads `StdAttr.LABEL` out of `LogisimFile`, a module `LogisimHdl` already depends on, so
  /// the default there is the faithful implementation, not a fallback.
  private static let ioAttributes = IoHdlAttributes(
    // `Button.ATTR_PRESS == Button.BUTTON_PRESS_PASSIVE`.
    isButtonPressPassive: { attrs in
      guard attrs.containsAttribute(Button.press) else { return false }
      guard case .option(let option)? = attrs.rawValue(Button.press) else { return false }
      return option == Button.pressPassive
    },
    // `LedBar.ATTR_INPUT_TYPE.equals(LedBar.INPUT_ONE_WIRE)`.
    isLedBarSingleBus: { attrs in
      guard attrs.containsAttribute(LedBar.ledBarInputType) else { return false }
      guard case .option(let option)? = attrs.rawValue(LedBar.ledBarInputType) else { return false }
      return option == LedBar.inputOneWire
    },
    // `LedBar.ATTR_MATRIX_COLS.getWidth()`.
    ledBarColumns: { attrs in Int(attrs.getValue(LedBar.attrMatrixCols)?.width ?? 0) },
    // `DotMatrixBase.ATTR_INPUT_TYPE`.
    dotMatrixInputType: { attrs in
      guard attrs.containsAttribute(DotMatrixBase.attrInputType),
        case .option(let option)? = attrs.rawValue(DotMatrixBase.attrInputType)
      else { return .select }
      if option == DotMatrixBase.inputColumn { return .column }
      if option == DotMatrixBase.inputRow { return .row }
      return .select
    },
    // `DotMatrix.ATTR_MATRIX_ROWS.getWidth()` / `ATTR_MATRIX_COLS.getWidth()`.
    dotMatrixRows: { attrs in Int(attrs.getValue(DotMatrix.attrMatrixRows)?.width ?? 0) },
    dotMatrixColumns: { attrs in Int(attrs.getValue(DotMatrix.attrMatrixCols)?.width ?? 0) },
    // `DotMatrixBase.ATTR_PERSIST`: LedBar and DotMatrix both refuse to synthesize unless 0.
    persistTicks: { attrs in
      guard attrs.containsAttribute(DotMatrixBase.attrPersist) else { return 0 }
      return attrs.getValue(DotMatrixBase.attrPersist) ?? 0
    },
    // `PortIo.ATTR_DIR`.
    portDirection: { attrs in
      switch attrs.getValue(PortIo.attrDirection) {
      case .output: return .output
      case .inOutSingleEnable: return .inOutSingleEnable
      case .inOutMultiEnable: return .inOutMultiEnable
      default: return .input
      }
    },
    // `PortIo.ATTR_SIZE.getWidth()`.
    portSize: { attrs in Int(attrs.getValue(PortIo.attrSize)?.width ?? 1) },
    // `SevenSegment.ATTR_DP`.
    hasDecimalPoint: { attrs in
      guard attrs.containsAttribute(SevenSegment.attrDecimalPoint) else { return false }
      return attrs.getValue(SevenSegment.attrDecimalPoint) ?? false
    })

  // MARK: - Installation

  /// Install every builtin HDL generator into `HdlGeneratorLookup.shared`.
  ///
  /// - Returns: the factory names installed, sorted. **Returned rather than discarded on
  ///   purpose**: a registration call that installs nothing looks exactly like one that works,
  ///   which is how this registry sat unreachable and how `rig.py` reported 0/1392 for its entire
  ///   existence. A caller that wants the guarantee can assert on the count.
  ///
  /// Idempotent: `register(factoryName:_:)` replaces, so calling twice leaves the same registry.
  /// Both call sites are guarded anyway (`main` runs once; the UI's
  /// `registerBuiltinLibrariesIfNeeded` has a `librariesRegistered` flag).
  @discardableResult
  public static func installBuiltins() -> [String] {
    let names = HdlGeneratorLookup.shared.registerAllBuiltins(bindings())

    // The FPGA map bindings, which are a SEPARATE registration from the generators and were
    // reachable from nothing until now.
    //
    // They were written and gated at 224 `MAPINFO` rows against the jar, while living in
    // `Tests/LogisimHdlTests/`. So the bindings were proven correct and **production installed
    // none of them**: without `registerMapInformation`, `mapInformation(for:)` answers `nil` for
    // every factory, which is the same answer a factory that does not declare the attribute
    // gives. Indistinguishable from "this design has no mappable I/O".
    //
    // `registerMapInformation` merges rather than replaces, so order against `registerAllBuiltins`
    // does not matter; that was deliberate on the author's part, and it is why these two lines
    // can sit here rather than being threaded into the generator list.
    FpgaMapInformationBindings.install(into: HdlGeneratorLookup.shared)
    FpgaStdIoFactBindings.install(into: FpgaStdIoFacts.shared)

    return names
  }

  /// Whether the builtin HDL generators have been installed into `HdlGeneratorLookup.shared`.
  ///
  /// The queryable form of the gap: it answered `false` for as long as nothing called
  /// `installBuiltins`, and answers `true` once either startup path has run.
  public static var isInstalled: Bool {
    !HdlGeneratorLookup.shared.registeredFactoryNames.isEmpty
  }
}
