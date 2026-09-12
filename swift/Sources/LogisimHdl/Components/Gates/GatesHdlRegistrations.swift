// GatesHdlRegistrations: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// the `getHDLGenerator` / `getHDLName` answers of the `std/gates`, `std/wiring` and
// `std/plexers` factories. Copyright by the Logisim-evolution developers. GPL-3.0-only.
// See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ══ THE RULE, taken from AbstractComponentFactory.java:103-137 ══════════════════════════════
//
//     public HdlGeneratorFactory getHDLGenerator(AttributeSet attrs) {
//       if (isHDLSupportedComponent(attrs)) return myHDLGenerator;
//       else return null;
//     }
//     public boolean isHDLSupportedComponent(AttributeSet attrs) {
//       if (myHDLGenerator != null) return myHDLGenerator.isHdlSupportedTarget(attrs);
//       return false;
//     }
//
// So a registration is NOT "here is the generator". It is "here is the generator, **if** it
// supports this attribute set". An AND gate whose output behaviour is `0Z` has no generator at
// all, and `Netlist` keys membership on `getHDLGenerator(attrs) != null`, so that gate drops out
// of the netlist entirely rather than being emitted wrongly. `AbstractGateHdlGenerator` and
// `AbstractBufferHdlGenerator` both override `isHdlSupportedTarget` for exactly that case.
//
// Every registration below therefore gates, uniformly: including the ones whose generator never
// refuses today. Gating unconditionally costs nothing and cannot silently become wrong later;
// omitting the gate is invisible until some generator gains an override.
//
// ── Why the names are strings and where they came from ──────────────────────────────────────
//
// `ComponentFactory.name` is the identity `.circ` files carry, and it cannot change without
// breaking every saved file. These are not transcribed from the Java source by eye: they are the
// strings the 4.1.0 jar itself reported, via `tools/hdlbridge/NetlistBridge.java`, which walks
// the real builtin libraries and prints one `SYNTH <name> <0|1>` line per placed factory. Note
// the ones a careful reading would get wrong; `LED` and `RGBLED` are upper-case, the display is
// `7-Segment Display` with a hyphen, and `NoConnect` has no space.

import LogisimFile
import LogisimKernel

/// The `(ComponentFactory.name, Registration)` pairs the gates, wiring-constant and plexer
/// families contribute to `HdlGeneratorLookup`.
///
/// Parameterised rather than self-contained because the generators need `StdAttr` /
/// `GateAttributes` / `PlexersLibrary` attribute *objects* by identity (`AnyAttribute` compares
/// by `===`, D4), and those live in `LogisimStd`, which this module must not import; that edge
/// would close a cycle. Same technique `MemoryHdlGenerators.registrations(romContents:)` and
/// `ArithHdlRegistrations` already use.
public enum GatesHdlRegistrations {

  /// `ComponentFactory.name` for every factory this family registers.
  public enum FactoryName {
    public static let andGate = "AND Gate"
    public static let orGate = "OR Gate"
    public static let nandGate = "NAND Gate"
    public static let norGate = "NOR Gate"
    public static let xorGate = "XOR Gate"
    public static let xnorGate = "XNOR Gate"
    public static let oddParity = "Odd Parity"
    public static let evenParity = "Even Parity"

    public static let buffer = "Buffer"
    public static let notGate = "NOT Gate"
    public static let controlledBuffer = "Controlled Buffer"
    public static let controlledInverter = "Controlled Inverter"

    public static let constant = "Constant"
    public static let power = "Power"
    public static let ground = "Ground"
    public static let noConnect = "NoConnect"
    public static let bitExtender = "Bit Extender"

    public static let multiplexer = "Multiplexer"
    public static let demultiplexer = "Demultiplexer"
    public static let decoder = "Decoder"
    public static let bitSelector = "BitSelector"
    public static let priorityEncoder = "Priority Encoder"

    public static let clock = "Clock"
    public static let pla = "PLA"

    /// Every name above, for a caller that wants to assert coverage.
    public static let all: [String] = [
      andGate, orGate, nandGate, norGate, xorGate, xnorGate, oddParity, evenParity,
      buffer, notGate, controlledBuffer, controlledInverter,
      constant, power, ground, noConnect, bitExtender,
      multiplexer, demultiplexer, decoder, bitSelector, priorityEncoder,
      clock, pla,
    ]
  }

  /// What `PlaHdlGeneratorFactory` needs from `LogisimStd`'s `Pla`. Bundled so the registration
  /// entry point does not grow seven more parameters; `nil` omits `PLA` from the result.
  public struct PlaBindings {
    public let inWidth: AnyAttribute
    public let outWidth: AnyAttribute
    public let inPort: Int
    public let outPort: Int
    public let rows: (any AttributeSet) -> [PlaHdlRow]
    public let outputSize: (any AttributeSet) -> Int

    public init(
      inWidth: AnyAttribute, outWidth: AnyAttribute, inPort: Int, outPort: Int,
      rows: @escaping (any AttributeSet) -> [PlaHdlRow],
      outputSize: @escaping (any AttributeSet) -> Int
    ) {
      self.inWidth = inWidth
      self.outWidth = outWidth
      self.inPort = inPort
      self.outPort = outPort
      self.rows = rows
      self.outputSize = outputSize
    }
  }

  /// Every registration this family contributes.
  ///
  /// - Parameters:
  ///   - bindings: the `StdAttr`/`GateAttributes`/`PlexersLibrary`/`BitSelector` attributes,
  ///     by identity.
  ///   - clock: `Clock.ATTR_HIGH`/`ATTR_LOW`/`ATTR_PHASE`.
  ///   - pla: `Pla`'s ports and table reader; `nil` leaves `PLA` unregistered, which upstream
  ///     would report as "not synthesizable" rather than as a wrong emission.
  public static func registrations(
    bindings: GatesHdlBindings,
    clock: ClockHdlBindings,
    pla: PlaBindings? = nil
  ) -> [String: HdlGeneratorLookup.Registration] {
    var result: [String: HdlGeneratorLookup.Registration] = [:]

    // MARK: gates — hdlName is AbstractGate.getHDLName

    func gate(_ name: String, _ generator: AbstractGateHdlGenerator) {
      result[name] = gated(generator, hdlName: gateHdlName(name, bindings: bindings))
    }
    gate(FactoryName.andGate, AndGateHdlGenerator(bindings: bindings))
    gate(FactoryName.orGate, OrGateHdlGenerator(bindings: bindings))
    gate(FactoryName.nandGate, NandGateHdlGenerator(bindings: bindings))
    gate(FactoryName.norGate, NorGateHdlGenerator(bindings: bindings))
    gate(FactoryName.xorGate, XorGateHdlGenerator(bindings: bindings))
    gate(FactoryName.xnorGate, XnorGateHdlGenerator(bindings: bindings))
    gate(FactoryName.oddParity, OddParityGateHdlGenerator(bindings: bindings))
    gate(FactoryName.evenParity, EvenParityGateHdlGenerator(bindings: bindings))

    // MARK: buffers
    //
    // `Buffer.getHDLName` and `NotGate.getHDLName` are their OWN overrides, not AbstractGate's;
    // neither class extends AbstractGate. Buffer appends a literal `_COMPONENT`; NotGate does
    // not. The jar found this; reading the two files would plausibly have inherited the gate
    // base's version and produced `BUFFER` where the jar emits `BUFFER_COMPONENT`.

    result[FactoryName.buffer] = gated(
      AbstractBufferHdlGenerator(isInverter: false),
      hdlName: { attrs in
        var name = CorrectLabel.correctLabel(FactoryName.buffer).uppercased() + "_COMPONENT"
        if busWidth(attrs, bindings) > 1 { name += "_BUS" }
        return name
      })
    result[FactoryName.notGate] = gated(
      AbstractBufferHdlGenerator(isInverter: true),
      hdlName: { attrs in
        var name = CorrectLabel.correctLabel(FactoryName.notGate).uppercased()
        if busWidth(attrs, bindings) > 1 { name += "_BUS" }
        return name
      })
    result[FactoryName.controlledBuffer] = gated(ControlledBufferHdlGenerator(isInverter: false))
    result[FactoryName.controlledInverter] = gated(ControlledBufferHdlGenerator(isInverter: true))

    // MARK: constants
    //
    // `DoNotConnect` uses a bare `InlinedHdlGeneratorFactory` upstream: it HAS a generator, so it
    // is not excluded from the netlist, but that generator emits nothing. Registering it with a
    // real generator that emits nothing is the faithful answer; leaving it out would wrongly
    // drop it from the graph.

    result[FactoryName.constant] = gated(
      AbstractConstantHdlGeneratorFactory(
        constant: AbstractConstantHdlGeneratorFactory.constantAttributeValue))
    result[FactoryName.power] = gated(
      AbstractConstantHdlGeneratorFactory(constant: AbstractConstantHdlGeneratorFactory.allOnes))
    result[FactoryName.ground] = gated(
      AbstractConstantHdlGeneratorFactory(constant: AbstractConstantHdlGeneratorFactory.zero))
    result[FactoryName.noConnect] = gated(InlinedHdlGeneratorFactory())
    result[FactoryName.bitExtender] = gated(BitExtenderHdlGeneratorFactory())

    // MARK: plexers
    //
    // `Multiplexer`/`Demultiplexer`: base, `_bus` when multi-bit, then `_<numberOfInputs>`.
    // `Decoder`'s is base + `_<numberOfOutputs>` with no bus suffix.

    func plexerName(_ name: String) -> (any AttributeSet) -> String {
      { attrs in
        var complete = CorrectLabel.correctLabel(name)
        if busWidth(attrs, bindings) > 1 { complete += "_bus" }
        complete += "_\(1 << selectWidth(attrs, bindings))"
        return complete
      }
    }

    result[FactoryName.multiplexer] = gated(
      MultiplexerHdlGeneratorFactory(bindings: bindings),
      hdlName: plexerName(FactoryName.multiplexer))
    result[FactoryName.demultiplexer] = gated(
      DemultiplexerHdlGeneratorFactory(bindings: bindings),
      hdlName: plexerName(FactoryName.demultiplexer))
    result[FactoryName.decoder] = gated(
      DecoderHdlGeneratorFactory(bindings: bindings),
      hdlName: { attrs in
        CorrectLabel.correctLabel(FactoryName.decoder) + "_\(1 << selectWidth(attrs, bindings))"
      })
    result[FactoryName.bitSelector] = gated(
      BitSelectorHdlGeneratorFactory(bindings: bindings),
      hdlName: { attrs in
        var complete = CorrectLabel.correctLabel(FactoryName.bitSelector)
        if width(attrs, bindings.bitSelectorGroup) > 1 { complete += "_bus" }
        return complete
      })
    result[FactoryName.priorityEncoder] = gated(
      PriorityEncoderHdlGeneratorFactory(bindings: bindings))

    // MARK: clock
    //
    // `Clock.getHDLName` is a constant: every Clock in a design shares one generated entity.

    result[FactoryName.clock] = gated(
      ClockHdlGeneratorFactory(bindings: clock), hdlName: { _ in "LogisimClockComponent" })

    if let pla {
      result[FactoryName.pla] = gated(
        PlaHdlGeneratorFactory(
          width: bindings.width, inWidth: pla.inWidth, outWidth: pla.outWidth,
          inPort: pla.inPort, outPort: pla.outPort, rows: pla.rows, outputSize: pla.outputSize))
    }

    return result
  }

  // MARK: - Helpers

  /// THE RULE, in one place: the generator is returned only when it supports the attribute set.
  private static func gated(
    _ generator: any HdlGeneratorFactory,
    hdlName: ((any AttributeSet) -> String)? = nil
  ) -> HdlGeneratorLookup.Registration {
    HdlGeneratorLookup.Registration(
      generator: { attrs in generator.isHdlSupportedTarget(attrs: attrs) ? generator : nil },
      hdlName: hdlName)
  }

  /// `AbstractGate.getHDLName`: uppercased base name, `_BUS` for a multi-bit gate,
  /// `_<n>_INPUTS` past two inputs, `_ONEHOT` for a one-hot XOR/XNOR.
  private static func gateHdlName(_ baseName: String, bindings: GatesHdlBindings)
    -> (any AttributeSet) -> String
  {
    { attrs in
      var name = CorrectLabel.correctLabel(baseName).uppercased()
      if busWidth(attrs, bindings) > 1 { name += "_BUS" }
      let inputCount = integer(attrs, bindings.gateInputs) ?? 2
      if inputCount > 2 { name += "_\(inputCount)_INPUTS" }
      if let xor = optionToken(attrs, named: "xor"), xor == "1" { name += "_ONEHOT" }
      return name
    }
  }

  private static func busWidth(_ attrs: any AttributeSet, _ bindings: GatesHdlBindings) -> Int {
    width(attrs, bindings.width)
  }

  private static func selectWidth(_ attrs: any AttributeSet, _ bindings: GatesHdlBindings) -> Int {
    width(attrs, bindings.plexerSelect)
  }

  private static func width(_ attrs: any AttributeSet, _ attribute: AnyAttribute) -> Int {
    guard attrs.containsAttribute(attribute) else { return 1 }
    if case .bitWidth(let value)? = attrs.rawValue(attribute) { return Int(value) }
    if case .integer(let value)? = attrs.rawValue(attribute) { return Int(value) }
    return 1
  }

  private static func integer(_ attrs: any AttributeSet, _ attribute: AnyAttribute) -> Int? {
    guard attrs.containsAttribute(attribute) else { return nil }
    if case .integer(let value)? = attrs.rawValue(attribute) { return Int(value) }
    return nil
  }

  /// `GateAttributes.ATTR_XOR` is read by name rather than by identity: the object is not part of
  /// `GatesHdlBindings`, and only XOR/XNOR carry it.
  private static func optionToken(_ attrs: any AttributeSet, named name: String) -> String? {
    guard let attribute = attrs.attributes.first(where: { $0.name == name }) else { return nil }
    if case .option(let option)? = attrs.rawValue(attribute) { return option.name }
    return nil
  }
}
