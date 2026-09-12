// IoLibrary.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.io.IoLibrary),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── `FactoryDescription`'s LAZY half is not ported; its DISPLAY-NAME half is ─────────────────
//
// Upstream defers factory construction through `FactoryDescription`, the reflective/lazy
// machinery behind JAR-loaded component libraries (D11). `AddTool` in this port always holds a
// live `ComponentFactory` (see `LibraryModel.swift`'s note on `sourceLoadAttempted`), so this
// library just builds every factory once, eagerly, exactly as `AddTool(Video.factory)` already
// does for the one upstream entry that bypasses `FactoryDescription`.
//
// The description's *other* payload, the tool's display name, is real and observable, and
// exactly one tool in this library needs it (`DipSwitch`, below). See
// `Instance/FactoryDescription.swift`.
//
// Tools are memoized in `cachedTools`, mirroring upstream's `if (tools == null) { … }` cache.
// This is load-bearing, not an optimisation: `AddTool.sharesSource` and every `Library.contains`
// / `indexOf` check compare factories by reference identity (D4), so recomputing the array on
// every access would hand out a fresh, non-`===`-matching factory per placed component.
//
// ── Cross-slice contract ─────────────────────────────────────────────────────────────────────
//
// `attrColor` / `attrOnColor` / `attrOffColor` / `attrBackground` / `attrActive` back
// upstream's `IoLibrary.ATTR_COLOR` / `ATTR_ON_COLOR` / `ATTR_OFF_COLOR` / `ATTR_BACKGROUND` /
// `ATTR_ACTIVE`. Every io component reads them, not just the ones ported in this file, because
// that is where upstream declares them. `Led`, `RgbLed`, `Button`, `DipSwitch`, `Tty` and the
// rest of the input/display slices under this same `Io/` directory are expected to reference
// these names.
//
// ── What did not come across ─────────────────────────────────────────────────────────────────
//
//   * `getDisplayName()`'s localisation (`S.get("ioLibrary")`); the string itself ("Input/Output")
//     DOES come across; it lives with the library's identity in `LogisimFile/Builtin.swift`'s
//     `BuiltinLibraryShell` table, because that shell, not this class, is the `Library` object
//     the loader hands to the app. This class is registered only as a tool provider.
//   * The `.gif` icon filenames threaded through `FactoryDescription`: M6/paint (D6).
//
// ── Components from sibling slices ───────────────────────────────────────────────────────────
//
// `Button`, `DipSwitch`, `Joystick`, `Keyboard`, `Led`, `LedBar`, `RgbLed`, `SevenSegment`,
// `HexDigit`, `DotMatrix`, `Tty` and `Video` are ported by the input/display slices of this
// port, as sibling files under `Io/`. This file references them by name only; it does not
// compile until those land, which is expected under this task's file-ownership split.

import Foundation
import LogisimFile
import LogisimKernel

/// **Stand-in for `StdAttr.LABEL_LOC`, which `LogisimFile/StdAttr.swift` does not declare.**
///
/// Upstream's `StdAttr.LABEL_LOC` is `Attribute<Object>` over a heterogeneous array mixing one
/// `AttributeOption` (`LABEL_CENTER`, token `"center"`) with the four `Direction` singletons
/// used directly as options (`Direction implements AttributeOptionInterface`, tokens `"north"` /
/// `"south"` / `"east"` / `"west"`). `StdAttr.swift`'s own header records this as intentionally
/// not ported: "not expressible as a single `Attribute<V>`... nothing in this milestone needs
/// `LABEL_LOC`." That milestone has arrived: `PortIo`, `Telnet`, `Buzzer`, `Slider`,
/// `DigitalOscilloscope` and `ProgrammableGenerator` all read it, so this is the five-token
/// enum StdAttr.swift's note says the component tranche should decide. Housed here (not in a
/// file I own in `LogisimFile`) purely because `Io/` is what needs it first.
///
/// **This belongs in `StdAttr.swift` as `StdAttr.labelLocation`, serialized name `"labelloc"`,
/// not here.** Reported as a needed change in the task's final output; if a sibling `std` slice
/// has independently stood up the same workaround, only one should survive.
/// Retained so this module's existing call sites keep compiling; the real declaration now lives
/// in `LogisimFile/StdAttr.swift`, exactly as the header above asked.
///
/// This file's stand-in was one of *seven* independent answers to the same missing symbol:
/// six files assumed a `StdAttr`-nested enum and this one invented a top-level pair. Both
/// spellings cannot be the real type: `Pla.swift` mixed them and failed to compile with
/// "cannot assign value of type 'StdAttr.LabelLocation' to type 'LabelLocation'". Aliasing
/// rather than deleting keeps `Telnet.swift` and `DigitalOscilloscope.swift` working while
/// collapsing the two spellings onto one type.
public typealias LabelLocation = StdAttr.LabelLocation

/// Alias for `StdAttr.labelLocation`. Must be the *same* `Attribute` instance, not a second
/// `Attributes.forOption("labelloc")`: attribute comparison in this port is reference identity
/// (`===`), mirroring Java, where `Attribute` overrides neither `equals` nor `hashCode`. A
/// duplicate would compile and then silently fail every `attribute === StdAttr.labelLocation`
/// test, so a component's label position would stop round-tripping.
public let stdAttrLabelLocation: Attribute<StdAttr.LabelLocation> = StdAttr.labelLocation

/// `com.cburch.logisim.std.io.IoLibrary`.
public final class IoLibrary: Library {

  /// `IoLibrary._ID`.
  public override class var libraryId: String { "I/O" }

  // MARK: Shared attributes — used across the whole `io` component family

  /// `IoLibrary.ATTR_COLOR`. Note upstream reuses the `.circ` token `"color"` for both this and
  /// `ATTR_ON_COLOR`: two distinct attribute identities sharing one serialized name, exactly
  /// like `StdAttr.trigger`/`edgeTrigger`. Preserved.
  public static let attrColor: Attribute<ColorSpec> = Attributes.forColor("color")
  /// `IoLibrary.ATTR_ON_COLOR`.
  public static let attrOnColor: Attribute<ColorSpec> = Attributes.forColor("color")
  /// `IoLibrary.ATTR_OFF_COLOR`.
  public static let attrOffColor: Attribute<ColorSpec> = Attributes.forColor("offcolor")
  /// `IoLibrary.ATTR_BACKGROUND`.
  public static let attrBackground: Attribute<ColorSpec> = Attributes.forColor("bg")
  /// `IoLibrary.ATTR_ACTIVE`.
  public static let attrActive: Attribute<Bool> = Attributes.forBoolean("active")

  /// `IoLibrary.DEFAULT_BACKGROUND`: `new Color(255, 255, 255, 0)`, i.e. transparent white.
  public static let defaultBackground = ColorSpec(red: 255, green: 255, blue: 255, alpha: 0)

  // MARK: Short-name aliases — reconciling sibling-slice naming
  //
  // The input/display slices under this same `Io/` directory landed while this file was being
  // written and independently settled on shorter names for these same five attributes
  // (`IoLibrary.onColor`/`.offColor`/`.active`/`.background`/`.color` in `Led.swift`,
  // `DotMatrix.swift`, `HexDigit.swift`, `SevenSegment.swift`, `RgbLed.swift`, `Tty.swift`:
  // and inconsistently even among themselves, e.g. `Joystick.swift` uses `.attrColor`/
  // `.attrBackground` while `Tty.swift` uses `.color`/`.background` for the same two
  // attributes). Rather than edit five files this task does not own, both spellings are kept
  // as the *same* `Attribute` object under each name, which is what makes them interchangeable
  // (D4: identity, not name, is what a `FixedAttributeSet` dispatches on). **Pick one spelling
  // and delete the other set of aliases** the next time anyone touches this file with the
  // authority to also fix the five call sites; until then both compile and both round-trip
  // identically because they are the same object.
  public static let onColor = attrOnColor
  public static let offColor = attrOffColor
  public static let active = attrActive
  public static let background = attrBackground
  public static let color = attrColor

  // MARK: Tools

  private lazy var cachedTools: [Tool] = [
    AddTool(factory: Button()),
    // The ONE io tool whose description getter is not the factory's own. Upstream's
    // `IoLibrary.DESCRIPTIONS` passes `S.getter("dipswitchComponent")` -> "Dip switch" while
    // `DipSwitch`'s constructor passes `S.getter("DipSwitchComponent")` -> "DIP Switch". Two
    // keys differing by one capital letter, two different strings, both shipped. See
    // `Instance/FactoryDescription.swift`.
    DescribedAddTool(factory: DipSwitch(), displayName: "Dip switch"),
    AddTool(factory: Joystick()),
    AddTool(factory: Keyboard()),
    AddTool(factory: Led()),
    AddTool(factory: LedBar()),
    AddTool(factory: RgbLed()),
    AddTool(factory: SevenSegment()),
    AddTool(factory: HexDigit()),
    AddTool(factory: DotMatrix()),
    AddTool(factory: Tty()),
    AddTool(factory: PortIo()),
    AddTool(factory: ReptarLocalBus()),
    AddTool(factory: Telnet()),
    // Upstream appends this one directly (`tools.add(new AddTool(Video.factory))`) rather than
    // through `DESCRIPTIONS`, because `Video` publishes a single shared `factory` singleton
    // instead of a no-arg constructor. Preserved as the same special case.
    AddTool(factory: Video.factory),
  ]

  public override var tools: [Tool] { cachedTools }
}
