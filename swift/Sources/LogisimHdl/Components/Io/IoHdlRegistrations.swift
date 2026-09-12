// IoHdlRegistrations: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// the `HdlGeneratorFactory` each `std/io` factory passes to its `InstanceFactory` super
// constructor. Copyright by the Logisim-evolution developers. GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// The pairing below is not inferred from file names; it is read off the `super(_ID, …, new
// XHdlGeneratorFactory(), …)` call in each factory, which is the only place upstream states it:
//
//     Button.java:114        new AbstractSimpleIoHdlGeneratorFactory(true)
//     DipSwitch.java:130     new AbstractSimpleIoHdlGeneratorFactory(true)
//     Led.java:67            new AbstractSimpleIoHdlGeneratorFactory(false)
//     RgbLed.java:89         new AbstractSimpleIoHdlGeneratorFactory(false)
//     SevenSegment.java:140  new AbstractSimpleIoHdlGeneratorFactory(false)
//     HexDigit.java:57       new HexDigitHdlGeneratorFactory()
//     LedBar.java:115        new LedBarHdlGeneratorFactory()
//     DotMatrix.java:33      new DotMatrixHdlGeneratorFactory()
//     PortIo.java:216        new PortHdlGeneratorFactory()
//     ReptarLocalBus.java:80 new ReptarLocalBusHdlGeneratorFactory()
//
// ── What is deliberately NOT here ───────────────────────────────────────────────────────────
//
// `LedArrayGenericHdlGeneratorFactory` and `SevenSegmentScanningGenericHdlGenerator` are **not**
// component registrations. They are board-level drivers selected by a mapping's driving mode
// (`LedArrayGenericHdlGeneratorFactory.java:48-53` switches on `LedArrayDriving`), not by a
// `ComponentFactory`, and no `.circ` component name reaches them. Registering them under some
// invented name would put entries in the registry that nothing can ever look up; the
// mirror-image of the defect this whole file exists to close. `IoLedArrayOracleTests` covers
// them directly instead.

import LogisimFile
import LogisimKernel

/// The `(ComponentFactory.name, Registration)` pairs the `std/io` family contributes to
/// `HdlGeneratorLookup`.
public enum IoHdlRegistrations {

  /// `ComponentFactory.name`: the `_ID` constants, verbatim from the 4.1.0 source. Note the
  /// casing and punctuation a transcription would plausibly get wrong: `LED` and `RGBLED` are
  /// upper-case, `7-Segment Display` is hyphenated, `ReptarLB` is abbreviated, and `PortIO` has
  /// a capital O where the class is `PortIo`.
  public enum FactoryName {
    public static let button = "Button"
    public static let dipSwitch = "DipSwitch"
    public static let led = "LED"
    public static let rgbLed = "RGBLED"
    public static let sevenSegment = "7-Segment Display"
    public static let hexDigit = "Hex Digit Display"
    public static let ledBar = "LedBar"
    public static let dotMatrix = "DotMatrix"
    public static let portIo = "PortIO"
    public static let reptarLocalBus = "ReptarLB"

    public static let all: [String] = [
      button, dipSwitch, led, rgbLed, sevenSegment, hexDigit, ledBar, dotMatrix, portIo,
      reptarLocalBus,
    ]
  }

  /// Every registration this family contributes.
  ///
  /// - Parameters:
  ///   - attributes: the `LogisimStd` attribute readers the io generators need. Defaulted so a
  ///     caller can get a working registry without `LogisimStd`, but a real integration must
  ///     supply the bound version: the defaults answer conservatively, not correctly.
  ///   - labelAttribute: `StdAttr.LABEL`, by identity, for `ReptarLocalBus`.
  public static func registrations(
    attributes: IoHdlAttributes = IoHdlAttributes(),
    labelAttribute: AnyAttribute? = nil
  ) -> [String: HdlGeneratorLookup.Registration] {
    var result: [String: HdlGeneratorLookup.Registration] = [:]

    let input = AbstractSimpleIoHdlGeneratorFactory(
      isInputComponent: true, attributes: attributes)
    let output = AbstractSimpleIoHdlGeneratorFactory(
      isInputComponent: false, attributes: attributes)

    result[FactoryName.button] = gated(input)
    result[FactoryName.dipSwitch] = gated(input)
    result[FactoryName.led] = gated(output)
    result[FactoryName.rgbLed] = gated(output)
    result[FactoryName.sevenSegment] = gated(output)

    result[FactoryName.hexDigit] = gated(HexDigitHdlGeneratorFactory(attributes: attributes))
    result[FactoryName.ledBar] = gated(LedBarHdlGeneratorFactory(attributes: attributes))
    result[FactoryName.dotMatrix] = gated(DotMatrixHdlGeneratorFactory(attributes: attributes))
    result[FactoryName.portIo] = gated(PortHdlGeneratorFactory(attributes: attributes))

    // `ReptarLocalBus.getHDLName` returns `attrs.getValue(StdAttr.LABEL)` verbatim: the only io
    // factory that overrides it, and note it does NOT go through `CorrectLabel`
    // (`ReptarLocalBus.java:136-139`). Its `isHdlSupportedTarget` is `Hdl.isVhdl()`, so in a
    // Verilog target this registration correctly yields no generator at all.
    result[FactoryName.reptarLocalBus] = gated(
      ReptarLocalBusHdlGeneratorFactory(labelAttribute: labelAttribute),
      hdlName: { attrs in attributes.label(attrs) })

    return result
  }

  /// THE RULE: see `GatesHdlRegistrations` for the Java it transcribes.
  private static func gated(
    _ generator: any HdlGeneratorFactory,
    hdlName: ((any AttributeSet) -> String)? = nil
  ) -> HdlGeneratorLookup.Registration {
    HdlGeneratorLookup.Registration(
      generator: { attrs in generator.isHdlSupportedTarget(attrs: attrs) ? generator : nil },
      hdlName: hdlName)
  }
}
