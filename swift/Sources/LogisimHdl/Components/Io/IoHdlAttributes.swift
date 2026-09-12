// IoHdlAttributes: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution): the
// attribute reads performed by `com/cburch/logisim/std/io/*HdlGeneratorFactory.java`
// (`Button.ATTR_PRESS`, `DotMatrixBase.ATTR_INPUT_TYPE`/`ATTR_PERSIST`, `DotMatrix.ATTR_MATRIX_*`,
// `LedBar.ATTR_INPUT_TYPE`/`ATTR_MATRIX_COLS`, `PortIo.ATTR_DIR`/`ATTR_SIZE`,
// `SevenSegment.ATTR_DP`, `StdAttr.LABEL`). Copyright by the Logisim-evolution developers. This
// translation is a derivative work and is therefore licensed GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── Why the generators read attributes through closures ─────────────────────────────────────
//
// Upstream's generators are inner-package neighbours of the components they describe, so
// `Button.ATTR_PRESS` is just a field reference. Here they are not: the components live in
// `LogisimStd` and the intended module edge is `LogisimStd -> LogisimHdl` (`Package.swift`,
// and `HdlGeneratorLookup.swift`'s header for why it must stay that way). A generator in this
// module therefore cannot name `Button.press` at all.
//
// The framework already solved the same problem twice, `HdlParameters(widthAttribute:)` for
// `StdAttr.WIDTH`, and `AbstractHdlGeneratorFactory.clockAttributes`/`labelAttribute` for
// `StdAttr.EDGE_TRIGGER`/`LABEL`, by injecting the attribute. This goes one step further and
// injects the *question* rather than the attribute, for two reasons that are specific to io:
//
//   1. `PortIo.ATTR_DIR` is not an `Attribute<AttributeOption>` in this port. `LogisimStd`
//      models it as `Attribute<PortIoDirection>`, a native Swift enum conforming to
//      `AttributeOptionValue`; the shape `Attributes.swift` explicitly recommends for new
//      ports. There is no `AttributeOption` to compare against, so an attribute handle would
//      not be enough.
//   2. Java reads `Button.ATTR_PRESS` off components that do not have it (a `DipSwitch`, a
//      `SevenSegment`). `AttributeSet.getValue` answers null there and the `== BUTTON_PRESS_PASSIVE`
//      comparison is false. Verified against the jar: `DipSwitch/size=2` emits
//      `s_logisimNet0 <= logisimInputBubbles(3);` with no `NOT`. Every closure below is
//      documented with the fallback its caller must supply for exactly this case.
//
// The defaults on `IoHdlAttributes()` reproduce those fallbacks, so an unconfigured instance
// behaves like a component that declares none of these attributes rather than trapping.

import LogisimFile
import LogisimKernel

/// `DotMatrixBase.INPUT_COLUMN` / `INPUT_ROW` / `INPUT_SELECT`.
public enum IoDotMatrixInputType: Sendable {
  case column
  case row
  /// `INPUT_SELECT`, and also the answer for a component that does not declare the attribute;
  /// Java's `getValue` returns null there, which matches neither `INPUT_COLUMN` nor `INPUT_ROW`
  /// and so falls into the same `else` branch.
  case select
}

/// `PortIo.INPUT` / `OUTPUT` / `INOUTSE` / `INOUTME`.
public enum IoPortDirection: Sendable {
  case input
  case output
  case inOutSingleEnable
  case inOutMultiEnable
}

/// The component attributes the std/io generators read, expressed as questions rather than as
/// attribute handles. See this file's header for why.
public struct IoHdlAttributes {

  /// `attrs.getValue(Button.ATTR_PRESS) == Button.BUTTON_PRESS_PASSIVE`.
  /// **Must answer `false` for a component with no such attribute** (DipSwitch).
  public var isButtonPressPassive: (any AttributeSet) -> Bool

  /// `attrs.getValue(LedBar.ATTR_INPUT_TYPE).equals(LedBar.INPUT_ONE_WIRE)`.
  public var isLedBarSingleBus: (any AttributeSet) -> Bool

  /// `attrs.getValue(LedBar.ATTR_MATRIX_COLS).getWidth()`.
  public var ledBarColumns: (any AttributeSet) -> Int

  /// `attrs.getValue(DotMatrixBase.ATTR_INPUT_TYPE)`, mapped onto `IoDotMatrixInputType`.
  public var dotMatrixInputType: (any AttributeSet) -> IoDotMatrixInputType

  /// `attrs.getValue(DotMatrix.ATTR_MATRIX_ROWS).getWidth()`.
  public var dotMatrixRows: (any AttributeSet) -> Int

  /// `attrs.getValue(DotMatrix.ATTR_MATRIX_COLS).getWidth()`.
  public var dotMatrixColumns: (any AttributeSet) -> Int

  /// `attrs.getValue(DotMatrixBase.ATTR_PERSIST)`: the raw persistence duration in ticks.
  /// `LedBarHdlGeneratorFactory` and `DotMatrixHdlGeneratorFactory` both refuse to synthesize
  /// unless this is exactly `0`.
  public var persistTicks: (any AttributeSet) -> Int32

  /// `attrs.getValue(PortIo.ATTR_DIR)`.
  public var portDirection: (any AttributeSet) -> IoPortDirection

  /// `attrs.getValue(PortIo.ATTR_SIZE).getWidth()`.
  public var portSize: (any AttributeSet) -> Int

  /// `attrs.getValue(SevenSegment.ATTR_DP)`.
  public var hasDecimalPoint: (any AttributeSet) -> Bool

  /// `attrs.getValue(StdAttr.LABEL)`. Java hands the raw label straight to
  /// `WithSelectHdlGenerator`, which splices it into a signal name, no `CorrectLabel` scrubbing
  /// on this path, and `ReptarLocalBus.getHDLName` returns it verbatim as the entity name.
  ///
  /// Unlike the others this one has a *real* default: `StdAttr` lives in `LogisimFile`, which
  /// this module already depends on, so no injection is needed and the default is the faithful
  /// implementation rather than a fallback.
  public var label: (any AttributeSet) -> String

  public init(
    isButtonPressPassive: @escaping (any AttributeSet) -> Bool = { _ in false },
    isLedBarSingleBus: @escaping (any AttributeSet) -> Bool = { _ in false },
    ledBarColumns: @escaping (any AttributeSet) -> Int = { _ in 0 },
    dotMatrixInputType: @escaping (any AttributeSet) -> IoDotMatrixInputType = { _ in .select },
    dotMatrixRows: @escaping (any AttributeSet) -> Int = { _ in 0 },
    dotMatrixColumns: @escaping (any AttributeSet) -> Int = { _ in 0 },
    persistTicks: @escaping (any AttributeSet) -> Int32 = { _ in 0 },
    portDirection: @escaping (any AttributeSet) -> IoPortDirection = { _ in .input },
    portSize: @escaping (any AttributeSet) -> Int = { _ in 1 },
    hasDecimalPoint: @escaping (any AttributeSet) -> Bool = { _ in false },
    label: @escaping (any AttributeSet) -> String = IoHdlAttributes.stdAttrLabel
  ) {
    self.isButtonPressPassive = isButtonPressPassive
    self.isLedBarSingleBus = isLedBarSingleBus
    self.ledBarColumns = ledBarColumns
    self.dotMatrixInputType = dotMatrixInputType
    self.dotMatrixRows = dotMatrixRows
    self.dotMatrixColumns = dotMatrixColumns
    self.persistTicks = persistTicks
    self.portDirection = portDirection
    self.portSize = portSize
    self.hasDecimalPoint = hasDecimalPoint
    self.label = label
  }
}

/// Shared constants the std/io generators use.
public enum IoHdl {
  /// Every generator in `com.cburch.logisim.std.io` gets its `subDirectoryName` from
  /// `AbstractHdlGeneratorFactory`'s no-argument constructor, which parses
  /// `getClass().toString()`, `"class com.cburch.logisim.std.io.Xxx"`, and takes the
  /// second-to-last dot-separated part. For every class in that package the answer is `"io"`.
  /// The port names it explicitly, as `AbstractHdlGeneratorFactory.swift`'s header requires.
  public static let subDirectory = "io"

  /// The `Attribute<BitWidth>` handed to `HdlParameters`, standing in for Java's hardcoded
  /// `StdAttr.WIDTH`.
  ///
  /// **No std/io generator ever reads it.** `HdlParameters` consults it in exactly two places:
  /// `isUsed`, which short-circuits to `true` for any parameter not declared `addBusOnly` (and
  /// none of these are), and `parameterValue`, which is only reached from `getMaps`; called
  /// from `AbstractHdlGeneratorFactory.getComponentMap`, which no io generator uses (the LED
  /// array drivers build their own component map in
  /// `LedArrayGenericHdlGeneratorFactory.getComponentMap`, and `ReptarLocalBus` declares no
  /// parameters at all). So a private, never-populated attribute is the honest expression of
  /// "this dependency is not real here", rather than a fake `StdAttr.WIDTH` that would look
  /// like one.
  public static let unusedWidthAttribute: Attribute<BitWidth> = Attributes.forBitWidth(
    "logisimIoHdlUnusedWidth")
}

extension IoHdlAttributes {
  /// `attrs.getValue(StdAttr.LABEL)`, answering `""` where Java answers `null`: every consumer
  /// on this path only ever concatenates it.
  public static func stdAttrLabel(_ attrs: any AttributeSet) -> String {
    guard attrs.containsAttribute(StdAttr.label) else { return "" }
    guard case .string(let label)? = attrs.rawValue(StdAttr.label) else { return "" }
    return label
  }
}
