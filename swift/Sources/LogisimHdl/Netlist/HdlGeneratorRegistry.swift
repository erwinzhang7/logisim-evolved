// HdlGeneratorRegistry: part of logisim-evolved.
//
// The join. Not a port of any single upstream file: upstream has no such function because each
// `ComponentFactory` passes its own generator to its `InstanceFactory` super constructor
// (`Button.java:114`, `Adder.java`, …). This port cannot do that: `ComponentFactory` lives in
// `LogisimFile` and the factories in `LogisimStd`, and neither may name `LogisimHdl` without
// closing a module cycle (see `HdlGeneratorLookup`'s header and D9). So the same mapping is
// expressed as data on the HDL side, and this file is the one place that assembles all of it.
//
// GPL-3.0-only, as a derivative work. See LICENSE.md.
//
// ══ WHY THIS FILE EXISTS AT ALL ═════════════════════════════════════════════════════════════
//
// Four families were ported in parallel and each reported its registration list without
// installing it, deliberately, so that four concurrent agents could not corrupt one file. That
// left the join owned by nobody, and "a registry nothing populates" is this project's single
// most repeated defect, with ten recorded occurrences including a gate that was structurally
// dead for its entire existence.
//
// `registerAllBuiltins` is that join, in one call, with `HdlGeneratorRegistryTests` failing if
// any family's entry is missing.
//
// ══ AND THE PART THAT IS STILL NOT DONE; READ THIS ═════════════════════════════════════════
//
// **Nothing in a shipping target calls this, and nothing can, because no shipping target links
// `LogisimHdl` at all.** From `Package.swift` as it stands:
//
//     LogisimStd   deps: LogisimKernel, LogisimFile, LogisimRender
//     LogisimUI    deps: LogisimKernel, LogisimFile, LogisimRender, LogisimStd
//     logisim-cli  deps: LogisimKernel, LogisimFile, LogisimStd, LogisimSoc
//     LogisimHdl   deps: LogisimKernel, LogisimFile
//
// `LogisimHdlTests` is the ONLY target in the package that can see both `LogisimHdl` and
// `LogisimStd`, and a test target is not a runtime. So the honest answer to "is the
// registration call reached at runtime?" is **no, and it cannot be until the package graph
// gains an edge**. That edge is not this task's to add; `Package.swift` is owned elsewhere
// and `tools/graphcheck.py` gates it. The precise request is in the report.
//
// This is written down here rather than only in a hand-off note because a future reader finding
// `registerAllBuiltins` will otherwise reasonably assume it runs.

import LogisimFile
import LogisimKernel

extension HdlGeneratorLookup {

  /// Everything a caller must supply from `LogisimStd` to build the full registry.
  ///
  /// One struct rather than a dozen loose parameters so that adding a family later is a
  /// source-compatible change, and so the call site reads as a list of bindings rather than a
  /// wall of arguments.
  public struct BuiltinBindings {
    public var gates: GatesHdlBindings
    public var clock: ClockHdlBindings
    public var pla: GatesHdlRegistrations.PlaBindings?

    /// `Comparator.modeAttr` and `Shifter.attrShift`, by identity (`AnyAttribute` compares by
    /// `===`, D4; the wrong object silently fails `containsAttribute`).
    public var comparatorMode: AnyAttribute
    public var multiplierMode: AnyAttribute
    public var shifterShift: AnyAttribute

    /// How to read one word out of a ROM's `contents`. `MemContents` lives in `LogisimStd`.
    /// Left `nil`, a ROM's inlined code comes from an all-zero image, which is wrong.
    public var romContents: MemoryHdlContentsReader?

    public var io: IoHdlAttributes
    /// `StdAttr.LABEL`, for `ReptarLocalBus.getHDLName`.
    public var label: AnyAttribute?

    public init(
      gates: GatesHdlBindings,
      clock: ClockHdlBindings,
      pla: GatesHdlRegistrations.PlaBindings? = nil,
      comparatorMode: AnyAttribute,
      multiplierMode: AnyAttribute,
      shifterShift: AnyAttribute,
      romContents: MemoryHdlContentsReader? = nil,
      io: IoHdlAttributes = IoHdlAttributes(),
      label: AnyAttribute? = nil
    ) {
      self.gates = gates
      self.clock = clock
      self.pla = pla
      self.comparatorMode = comparatorMode
      self.multiplierMode = multiplierMode
      self.shifterShift = shifterShift
      self.romContents = romContents
      self.io = io
      self.label = label
    }
  }

  /// Every registration all four ported families contribute, keyed by `ComponentFactory.name`.
  ///
  /// Pure, it installs nothing, so a test can assert the *contents* of the list separately
  /// from the act of installing it. That separation is deliberate: the two failure modes are
  /// different (a wrong name versus a call that never happens) and a test that only checked the
  /// installed registry could not tell them apart.
  public static func builtinRegistrations(_ bindings: BuiltinBindings) -> [String: Registration] {
    var result: [String: Registration] = [:]

    // gates + wiring constants + plexers + clock + PLA
    for (name, registration) in GatesHdlRegistrations.registrations(
      bindings: bindings.gates, clock: bindings.clock, pla: bindings.pla)
    {
      result[name] = registration
    }

    // arith. `Divider` is deliberately absent: the jar reports `SYNTH 0` / `SUPP 0` for it at
    // every width and mode, so registering it would ADD a component to the netlist that upstream
    // excludes. An absent entry is the correct answer, not a gap.
    result[ArithHdlRegistrations.adderName] = ArithHdlRegistrations.adder()
    result[ArithHdlRegistrations.subtractorName] = ArithHdlRegistrations.subtractor()
    result[ArithHdlRegistrations.negatorName] = ArithHdlRegistrations.negator()
    result[ArithHdlRegistrations.multiplierName] =
      ArithHdlRegistrations.multiplier(modeAttribute: bindings.multiplierMode)
    result[ArithHdlRegistrations.comparatorName] =
      ArithHdlRegistrations.comparator(modeAttribute: bindings.comparatorMode)
    result[ArithHdlRegistrations.shifterName] =
      ArithHdlRegistrations.shifter(shiftAttribute: bindings.shifterShift)

    // memory
    for (name, registration) in MemoryHdlGenerators.registrations(
      romContents: bindings.romContents)
    {
      result[name] = registration
    }

    // io
    for (name, registration) in IoHdlRegistrations.registrations(
      attributes: bindings.io, labelAttribute: bindings.label)
    {
      result[name] = registration
    }

    return result
  }

  /// Install every builtin registration into this lookup.
  ///
  /// Returns the names installed, so a caller can log or assert them rather than trusting that
  /// the call did anything; a silently-zero-output success looks exactly like agreement.
  @discardableResult
  public func registerAllBuiltins(_ bindings: BuiltinBindings) -> [String] {
    let registrations = Self.builtinRegistrations(bindings)
    for (name, registration) in registrations {
      register(factoryName: name, registration)
    }
    return registrations.keys.sorted()
  }
}
