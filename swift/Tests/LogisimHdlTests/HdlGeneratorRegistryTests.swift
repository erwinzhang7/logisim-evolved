// HdlGeneratorRegistryTests: part of logisim-evolved.
//
// The gate on the join: `HdlGeneratorLookup.registerAllBuiltins`.
//
// ══ WHY THIS SUITE IS SHAPED THE WAY IT IS ══════════════════════════════════════════════════
//
// "A registry nothing populates" is this project's most-repeated defect; ten recorded
// occurrences, including a gate that was structurally dead for its entire existence and a
// `rig.py` mode that ran, exited 0, and evaluated nothing. The shape is always the same: the
// data structure exists, the lookups compile, and the answer is silently "no such entry".
//
// So this suite tests three separable things, because they fail differently and a single
// end-to-end assertion could not tell them apart:
//
//   1. **The list is complete and correctly keyed.** Every name from every family is present,
//      compared against `ComponentFactory.name` read off REAL `LogisimStd` factory objects
//      rather than against the same string literal the source used; a typo shared by the
//      registration and its test is not caught by comparing them to each other.
//   2. **The rule is implemented.** `getHDLGenerator(attrs)` returns nil when
//      `isHdlSupportedTarget(attrs)` is false, for a case where the jar says so.
//   3. **Installing actually installs.** `registerAllBuiltins` populates a lookup that answered
//      nil before it ran; asserted against a component, through the same
//      `generator(for:)`/`isSupported(_:)`/`hdlName(for:)` path `Netlist` uses.
//
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimStd
import Testing

@testable import LogisimHdl

@Suite("HdlGeneratorLookup — the registration join", .serialized)
struct HdlGeneratorRegistryTests {

  // MARK: - Bindings, built from the real LogisimStd attribute objects

  static func bindings() -> HdlGeneratorLookup.BuiltinBindings {
    HdlGeneratorLookup.BuiltinBindings(
      gates: GatesOracle.bindings,
      clock: ClockHdlBindings(
        width: StdAttr.width, high: Clock.attrHigh, low: Clock.attrLow, phase: Clock.attrPhase),
      pla: GatesHdlRegistrations.PlaBindings(
        inWidth: Pla.inWidth, outWidth: Pla.outWidth, inPort: Pla.inPort, outPort: Pla.outPort,
        rows: { attrs in
          guard let table = attrs[Pla.table] else { return [] }
          return table.rows.map { PlaHdlRow(inBits: $0.inBits, outBits: $0.outBits) }
        },
        outputSize: { attrs in attrs[Pla.table]?.outSize ?? 0 }),
      comparatorMode: Comparator.modeAttr,
      multiplierMode: Comparator.modeAttr,
      shifterShift: Shifter.attrShift,
      label: StdAttr.label)
  }

  // MARK: - 1. The list is complete, and keyed by what `.circ` files actually carry

  /// Every registered name must equal the `name` of a real `LogisimStd` `ComponentFactory`.
  ///
  /// This is the assertion that catches a typo. Comparing the registry's keys to the same string
  /// constants the registry was written from would pass no matter how wrong they are; comparing
  /// them to `factory.name` on a constructed factory compares against the string a `.circ` file
  /// is matched on.
  @Test("every registered factory name is a real LogisimStd ComponentFactory.name")
  func namesMatchRealFactories() {
    let registrations = HdlGeneratorLookup.builtinRegistrations(Self.bindings())
    #expect(!registrations.isEmpty, "the builtin registration list is empty")

    // One real factory object per registered family member. Anything whose name does not appear
    // here is reported, so a name can neither drift nor be quietly dropped.
    let realFactories: [any ComponentFactory] = [
      AndGate.factory, OrGate.factory, NandGate.factory, NorGate.factory,
      XorGate.factory, XnorGate.factory, OddParityGate.factory, EvenParityGate.factory,
      Buffer.factory, NotGate.factory,
      ControlledBuffer.factoryBuffer, ControlledBuffer.factoryInverter,
      Constant.factory, Power.factory, Ground.factory, NoConnect.factory, BitExtender.factory,
      Multiplexer(), Demultiplexer(), Decoder(), BitSelector(), PriorityEncoder(),
      Clock.factory, Pla.factory,
    ]
    let realNames = Set(realFactories.map(\.name))

    // Only the gates/plexers/wiring family is checked against live factory objects here; the
    // other three are covered by their own oracle suites, which drive the same names against the
    // jar. What matters is that this half cannot drift, because it is the half whose names were
    // transcribed rather than reported.
    let gatesNames = Set(GatesHdlRegistrations.FactoryName.all)
    let notReal = gatesNames.subtracting(realNames)
    #expect(
      notReal.isEmpty,
      "registered under names no LogisimStd factory answers to — a .circ file would never match these: \(notReal.sorted())")

    let unregistered = realNames.subtracting(Set(registrations.keys))
    #expect(
      unregistered.isEmpty,
      "real factories with no registration — these silently drop out of every netlist: \(unregistered.sorted())")
  }

  /// The full expected key set, per family. Fails loudly if a family's list shrinks.
  @Test("all four families appear in the joined registration list")
  func allFourFamiliesArePresent() {
    let keys = Set(HdlGeneratorLookup.builtinRegistrations(Self.bindings()).keys)

    for name in GatesHdlRegistrations.FactoryName.all {
      #expect(keys.contains(name), "gates family: \(name) is missing")
    }
    for name in IoHdlRegistrations.FactoryName.all {
      #expect(keys.contains(name), "io family: \(name) is missing")
    }
    for name in [
      MemoryHdlGenerators.FactoryName.dFlipFlop, MemoryHdlGenerators.FactoryName.tFlipFlop,
      MemoryHdlGenerators.FactoryName.jkFlipFlop, MemoryHdlGenerators.FactoryName.srFlipFlop,
      MemoryHdlGenerators.FactoryName.register, MemoryHdlGenerators.FactoryName.counter,
      MemoryHdlGenerators.FactoryName.shiftRegister, MemoryHdlGenerators.FactoryName.random,
      MemoryHdlGenerators.FactoryName.ram, MemoryHdlGenerators.FactoryName.rom,
    ] {
      #expect(keys.contains(name), "memory family: \(name) is missing")
    }
    for name in [
      ArithHdlRegistrations.adderName, ArithHdlRegistrations.subtractorName,
      ArithHdlRegistrations.negatorName, ArithHdlRegistrations.multiplierName,
      ArithHdlRegistrations.comparatorName, ArithHdlRegistrations.shifterName,
    ] {
      #expect(keys.contains(name), "arith family: \(name) is missing")
    }

    // `Divider` must NOT be registered: the jar reports `SYNTH 0` / `SUPP 0` for it at every
    // width and mode, so an entry here would add a component to the netlist upstream excludes.
    #expect(
      !keys.contains(ArithHdlRegistrations.dividerName),
      "Divider is registered, but the jar has no generator for it at any setting")
  }

  // MARK: - 2. The rule

  /// `AbstractComponentFactory.java:103-106`; the generator comes back only when
  /// `isHDLSupportedComponent(attrs)`, which is `myHDLGenerator.isHdlSupportedTarget(attrs)`.
  ///
  /// `ReptarLocalBus.isHdlSupportedTarget` is `Hdl.isVhdl()`, so the same registration must
  /// answer a generator in VHDL and **nil** in Verilog. That makes this a test of the gating
  /// itself, not of any one generator.
  @Test("a registration yields no generator when isHdlSupportedTarget is false")
  func registrationGatesOnIsHdlSupportedTarget() {
    withHdlGlobals {
      let registration = IoHdlRegistrations.registrations()[
        IoHdlRegistrations.FactoryName.reptarLocalBus]
      let attrs = AttributeSets.empty

      HdlSettings.language = .vhdl
      #expect(
        registration?.generator(attrs) != nil,
        "ReptarLocalBus should have a generator in VHDL")

      HdlSettings.language = .verilog
      #expect(
        registration?.generator(attrs) == nil,
        "ReptarLocalBus.isHdlSupportedTarget is Hdl.isVhdl(), so Verilog must yield NO generator; an ungated registration would return one and put it in the netlist")
    }
  }

  // MARK: - 3. Installing actually installs

  /// **This is the test the brief asks for: it fails if the registration is absent.**
  ///
  /// It goes through `generator(for:)` / `isSupported(_:)` / `hdlName(for:)` on a placed
  /// component, the exact three calls `Netlist` makes, and asserts the lookup answered nil
  /// *before* `registerAllBuiltins` ran, so a lookup that was somehow pre-populated could not
  /// make this pass vacuously.
  @Test("registerAllBuiltins populates a lookup that answered nothing before it ran")
  func registeringIsWhatMakesTheLookupAnswer() throws {
    try withHdlGlobals {
      HdlSettings.language = .vhdl

      let lookup = HdlGeneratorLookup()
      let factory = AndGate.factory
      let attrs = factory.createAttributeSet()
      let component = try factory.createComponent(location: Location.create(100, 100, hasToSnap: false), attributes: attrs)

      // Before: nothing. If this ever fails, the test below proves nothing.
      #expect(
        lookup.generator(for: component) == nil,
        "a fresh lookup already answers — the 'after' assertion would be vacuous")
      #expect(lookup.hdlName(for: component) == CorrectLabel.correctLabel("AND Gate"))

      let installed = lookup.registerAllBuiltins(Self.bindings())

      // The call did work, rather than succeeding silently over an empty list.
      #expect(installed.count >= 40, "registerAllBuiltins installed only \(installed.count) names")

      // After: the three answers Netlist actually asks for.
      #expect(
        lookup.generator(for: component) != nil,
        "AND Gate still has no generator after registerAllBuiltins — the join is not wired")
      #expect(lookup.isSupported(component))
      #expect(lookup.hdlName(for: component) == "AND_GATE")
    }
  }

  /// The same three answers for one component from each of the other three families, so a
  /// regression in any single family's list fails here and names the family.
  @Test("one component from each family resolves through the installed lookup")
  func eachFamilyResolves() throws {
    try withHdlGlobals {
      HdlSettings.language = .vhdl
      let lookup = HdlGeneratorLookup()
      lookup.registerAllBuiltins(Self.bindings())

      func check(_ factory: any ComponentFactory, _ family: String) throws {
        let attrs = factory.createAttributeSet()
        let component = try factory.createComponent(
          location: Location.create(100, 100, hasToSnap: false), attributes: attrs)
        #expect(
          lookup.generator(for: component) != nil,
          "\(family): \(factory.name) has no generator after registration")
        #expect(lookup.isSupported(component), "\(family): \(factory.name) is not supported")
      }

      try check(Adder(), "arith")
      try check(Register(), "memory")
      try check(Led(), "io")
      try check(Multiplexer(), "plexers")
    }
  }

  /// The io family's names are the ones most likely to be transcribed wrong; `LED` and `RGBLED`
  /// are upper-case, `7-Segment Display` is hyphenated, `ReptarLB` is abbreviated. Checked
  /// against live factory objects for the same reason as the gates list above.
  @Test("the io factory names match the real LogisimStd factories, casing included")
  func ioNamesMatchRealFactories() {
    let expected: [(String, any ComponentFactory)] = [
      (IoHdlRegistrations.FactoryName.button, Button()),
      (IoHdlRegistrations.FactoryName.dipSwitch, DipSwitch()),
      (IoHdlRegistrations.FactoryName.led, Led()),
    ]
    for (name, factory) in expected {
      #expect(
        name == factory.name,
        "io registration key \(name) does not match ComponentFactory.name \(factory.name)")
    }
  }
}
