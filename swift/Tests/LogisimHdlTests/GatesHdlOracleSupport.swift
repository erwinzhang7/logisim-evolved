// GatesHdlOracleSupport: part of logisim-evolved.
//
// Test-side half of the gates / wiring / plexers HDL oracle. Regenerates, from the Swift
// generators, exactly the line protocol `tools/hdlbridge/GatesBridge.java` dumps out of the
// shipped 4.1.0 jar, so the two can be diffed line for line. Copyright by the Logisim-evolution
// developers where derived; GPL-3.0-only. See LICENSE.md.
//
// The case matrix, its ordering, and every emitted tag must stay in lockstep with the bridge.
// If you change one, change both; a matrix that has silently drifted produces a diff that looks
// like a port bug and is not one.

import LogisimHdl
import LogisimFile
import LogisimKernel
import LogisimStd

// MARK: - A netlist that is just enough to drive these generators

/// None of the gates / wiring / plexers generators consults the netlist for anything except
/// `projName` (which reaches the file-header remark). The Java bridge drives them with a
/// `Netlist` over a `Circuit` that has no `LogisimFile`, whose `getProjName()` is `""`; this is
/// the same thing with no `Circuit` behind it.
final class EmptyHdlNetlist: HdlNetlist {
  func netId(for net: any HdlNet) -> Int { 0 }
  func isContinuesBus(_ component: any HdlNetlistComponent, endIndex: Int) -> Bool { false }
  var currentHierarchyLevel: [String]? { nil }
  func clockSourceId(hierarchyLevel: [String], net: any HdlNet, bitIndex: Int) -> Int { -1 }
  var circuitName: String { "bridge" }
  var projName: String { "" }
  var requiresGlobalClockConnection: Bool { false }
}

// MARK: - The bindings, built from the real LogisimStd attribute constants

enum GatesOracle {

  /// Exactly the `GatesHdlBindings` an integrator has to construct to register these generators.
  /// Building it here rather than in a fixture is deliberate: the differential gate then covers
  /// the registration seam itself, not just the generator bodies.
  static let bindings = GatesHdlBindings(
    width: StdAttr.width,
    gateInputs: GateAttributes.inputs,
    plexerSelect: PlexersLibraryAttributes.select,
    bitSelectorGroup: BitSelector.groupAttr,
    bitSelectorSelect: BitSelector.selectAttr,
    bitSelectorExtended: BitSelector.extendedAttr,
    negatedInput: { index in NegateAttributes.attribute(index: index, side: nil) })

  // MARK: Registration table — the list this task reports for HdlGeneratorLookup

  /// `(ComponentFactory.name, generator, hdlName)` for every component in these three families.
  ///
  /// `generator` is a *closure over the attribute set* because upstream's
  /// `AbstractComponentFactory.getHDLGenerator(attrs)` returns the generator **only when
  /// `isHDLSupportedComponent(attrs)`**, which defaults to `isHdlSupportedTarget(attrs)`. A gate
  /// whose output behaviour is `0Z` or `Z1` therefore has *no* generator at all and drops out of
  /// the netlist. Verified against the jar, which reports `GENERATOR null` for those cases.
  struct Entry {
    let name: String
    let factory: () -> any ComponentFactory
    let generator: any HdlGeneratorFactory
    let hdlName: (any AttributeSet) -> String
  }

  /// `AbstractGate.getHDLName`: uppercased base name, `_BUS` for a multi-bit gate, `_N_INPUTS`
  /// past two inputs, `_ONEHOT` for a one-hot XOR/XNOR.
  static func gateHdlName(_ baseName: String) -> (any AttributeSet) -> String {
    { attrs in
      var name = CorrectLabel.correctLabel(baseName).uppercased()
      if attrs.hdlOracleBitWidth("width") > 1 { name += "_BUS" }
      let inputCount = attrs.hdlOracleInteger("inputs", default: 2)
      if inputCount > 2 { name += "_\(inputCount)_INPUTS" }
      if let xor = attrs.hdlOracleOptionToken("xor"), xor == "1" { name += "_ONEHOT" }
      return name
    }
  }

  static let entries: [Entry] = {
    var result: [Entry] = []

    func gate(_ name: String, _ factory: @escaping () -> any ComponentFactory,
              _ generator: AbstractGateHdlGenerator) {
      result.append(
        Entry(name: name, factory: factory, generator: generator, hdlName: gateHdlName(name)))
    }

    gate("AND Gate", { AndGate.factory }, AndGateHdlGenerator(bindings: bindings))
    gate("OR Gate", { OrGate.factory }, OrGateHdlGenerator(bindings: bindings))
    gate("NAND Gate", { NandGate.factory }, NandGateHdlGenerator(bindings: bindings))
    gate("NOR Gate", { NorGate.factory }, NorGateHdlGenerator(bindings: bindings))
    gate("XOR Gate", { XorGate.factory }, XorGateHdlGenerator(bindings: bindings))
    gate("XNOR Gate", { XnorGate.factory }, XnorGateHdlGenerator(bindings: bindings))
    gate("Odd Parity", { OddParityGate.factory }, OddParityGateHdlGenerator(bindings: bindings))
    gate("Even Parity", { EvenParityGate.factory }, EvenParityGateHdlGenerator(bindings: bindings))

    let plain: (String) -> (any AttributeSet) -> String = { name in
      { _ in CorrectLabel.correctLabel(name) }
    }

    // `Buffer.getHDLName` and `NotGate.getHDLName` are their own overrides, *not* AbstractGate's
    // : neither class extends AbstractGate (both extend InstanceFactory directly). Buffer appends
    // a literal `_COMPONENT`; NotGate does not. Found by the oracle: reading the two files would
    // plausibly have inherited them from the gate base and produced `BUFFER` / `NOT_GATE_BUS`
    // where the jar emits `BUFFER_COMPONENT` / `NOT_GATE_BUS`.
    result.append(
      Entry(name: "Buffer", factory: { Buffer.factory },
            generator: AbstractBufferHdlGenerator(isInverter: false),
            hdlName: { attrs in
              var name = CorrectLabel.correctLabel("Buffer").uppercased() + "_COMPONENT"
              if attrs.hdlOracleBitWidth("width") > 1 { name += "_BUS" }
              return name
            }))
    result.append(
      Entry(name: "NOT Gate", factory: { NotGate.factory },
            generator: AbstractBufferHdlGenerator(isInverter: true),
            hdlName: { attrs in
              var name = CorrectLabel.correctLabel("NOT Gate").uppercased()
              if attrs.hdlOracleBitWidth("width") > 1 { name += "_BUS" }
              return name
            }))
    result.append(
      Entry(name: "Controlled Buffer", factory: { ControlledBuffer.factoryBuffer },
            generator: ControlledBufferHdlGenerator(isInverter: false),
            hdlName: plain("Controlled Buffer")))
    result.append(
      Entry(name: "Controlled Inverter", factory: { ControlledBuffer.factoryInverter },
            generator: ControlledBufferHdlGenerator(isInverter: true),
            hdlName: plain("Controlled Inverter")))
    result.append(
      Entry(name: "Constant", factory: { Constant.factory },
            generator: AbstractConstantHdlGeneratorFactory(
              constant: AbstractConstantHdlGeneratorFactory.constantAttributeValue),
            hdlName: plain("Constant")))
    result.append(
      Entry(name: "Power", factory: { Power.factory },
            generator: AbstractConstantHdlGeneratorFactory(
              constant: AbstractConstantHdlGeneratorFactory.allOnes),
            hdlName: plain("Power")))
    result.append(
      Entry(name: "Ground", factory: { Ground.factory },
            generator: AbstractConstantHdlGeneratorFactory(
              constant: AbstractConstantHdlGeneratorFactory.zero),
            hdlName: plain("Ground")))
    // `DoNotConnect` uses a bare `InlinedHdlGeneratorFactory` upstream; it has a generator (so
    // it is not excluded from the netlist) but that generator emits nothing. The base class is
    // already ported, so this needs no new type.
    result.append(
      Entry(name: "NoConnect", factory: { NoConnect.factory },
            generator: InlinedHdlGeneratorFactory(), hdlName: plain("NoConnect")))
    result.append(
      Entry(name: "Bit Extender", factory: { BitExtender.factory },
            generator: BitExtenderHdlGeneratorFactory(), hdlName: plain("Bit Extender")))

    // `Multiplexer.getHDLName` / `Demultiplexer.getHDLName`: base, `_bus` when multi-bit, then
    // `_<numberOfInputs>`. `Decoder`'s is base + `_<numberOfOutputs>` with no bus suffix.
    let plexerName: (String) -> (any AttributeSet) -> String = { name in
      { attrs in
        var complete = CorrectLabel.correctLabel(name)
        if attrs.hdlOracleBitWidth("width") > 1 { complete += "_bus" }
        complete += "_\(1 << attrs.hdlOracleBitWidth("select"))"
        return complete
      }
    }

    result.append(
      Entry(name: "Multiplexer", factory: { Multiplexer() },
            generator: MultiplexerHdlGeneratorFactory(bindings: bindings),
            hdlName: plexerName("Multiplexer")))
    result.append(
      Entry(name: "Demultiplexer", factory: { Demultiplexer() },
            generator: DemultiplexerHdlGeneratorFactory(bindings: bindings),
            hdlName: plexerName("Demultiplexer")))
    result.append(
      Entry(name: "Decoder", factory: { Decoder() },
            generator: DecoderHdlGeneratorFactory(bindings: bindings),
            hdlName: { attrs in
              CorrectLabel.correctLabel("Decoder") + "_\(1 << attrs.hdlOracleBitWidth("select"))"
            }))
    result.append(
      Entry(name: "BitSelector", factory: { BitSelector() },
            generator: BitSelectorHdlGeneratorFactory(bindings: bindings),
            hdlName: { attrs in
              var complete = CorrectLabel.correctLabel("BitSelector")
              if attrs.hdlOracleBitWidth("group") > 1 { complete += "_bus" }
              return complete
            }))
    result.append(
      Entry(name: "Priority Encoder", factory: { PriorityEncoder() },
            generator: PriorityEncoderHdlGeneratorFactory(bindings: bindings),
            hdlName: plain("Priority Encoder")))

    // `Clock.getHDLName` is a constant: every Clock in a design shares one generated entity.
    result.append(
      Entry(name: "Clock", factory: { Clock.factory },
            generator: ClockHdlGeneratorFactory(
              bindings: ClockHdlBindings(
                width: StdAttr.width, high: Clock.attrHigh, low: Clock.attrLow,
                phase: Clock.attrPhase)),
            hdlName: { _ in "LogisimClockComponent" }))

    result.append(
      Entry(name: "PLA", factory: { Pla.factory },
            generator: PlaHdlGeneratorFactory(
              width: StdAttr.width,
              inWidth: Pla.inWidth,
              outWidth: Pla.outWidth,
              inPort: Pla.inPort,
              outPort: Pla.outPort,
              rows: { attrs in
                guard let table = attrs[Pla.table] else { return [] }
                return table.rows.map { PlaHdlRow(inBits: $0.inBits, outBits: $0.outBits) }
              },
              outputSize: { attrs in attrs[Pla.table]?.outSize ?? 0 }),
            hdlName: plain("PLA")))

    return result
  }()

  static func entry(named name: String) -> Entry? { entries.first { $0.name == name } }
}

// MARK: - Attribute helpers mirroring the bridge's `set` / `has` / `dumpAttrs`

extension AttributeSet {

  func hdlOracleAttribute(_ name: String) -> AnyAttribute? {
    attributes.first { $0.name == name }
  }

  func hdlOracleHas(_ name: String) -> Bool { hdlOracleAttribute(name) != nil }

  func hdlOracleBitWidth(_ name: String, default fallback: Int = 1) -> Int {
    guard let attribute = hdlOracleAttribute(name) else { return fallback }
    if case .bitWidth(let value)? = rawValue(attribute) { return Int(value) }
    return fallback
  }

  func hdlOracleInteger(_ name: String, default fallback: Int) -> Int {
    guard let attribute = hdlOracleAttribute(name) else { return fallback }
    switch rawValue(attribute) {
    case .integer(let value): return Int(value)
    case .long(let value): return Int(truncatingIfNeeded: value)
    case .bitWidth(let value): return Int(value)
    default: return fallback
    }
  }

  func hdlOracleOptionToken(_ name: String) -> String? {
    guard let attribute = hdlOracleAttribute(name) else { return nil }
    guard case .option(let option)? = rawValue(attribute) else { return nil }
    return attribute.standardString(for: .option(option))
  }

  /// The bridge's `set(attrs, name, value)`: parse the `.circ` token and assign.
  func hdlOracleSet(_ name: String, _ value: String) {
    guard let attribute = hdlOracleAttribute(name) else { return }
    guard let parsed = try? attribute.parseToAttributeValue(value) else { return }
    try? setRawValue(attribute, parsed)
  }

  func hdlOracleSetNegated(_ index: Int) {
    guard let attribute = hdlOracleAttribute("negate\(index)") else { return }
    try? setRawValue(attribute, .boolean(true))
  }
}
