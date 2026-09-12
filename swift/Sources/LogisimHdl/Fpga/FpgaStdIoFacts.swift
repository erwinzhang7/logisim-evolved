// FpgaStdIoFacts.swift: part of logisim-evolved.
//
// The `com.cburch.logisim.std.io` facts the FPGA board model needs and `LogisimHdl` may not
// name. Task #38's decision, applied.
//
// ══ WHY INJECTION, SETTLED ═════════════════════════════════════════════════════════════════
//
// `MapComponent.java` imports `std.io.RgbLed` and `std.io.SevenSegment`;
// `IoComponentTypes.getOutputLabel` imports both again. `LogisimHdl` must never depend on
// `LogisimStd`, because the per-component HDL generators need `LogisimStd -> LogisimHdl` and the
// pair would close a cycle that breaks the whole build.
//
// This is the third instance of a pattern the module already uses and documents,
// `AbstractHdlGeneratorFactory.clockAttributes` and `HdlParameters(widthAttribute:)` both exist
// because `StdAttr` lives in a module `LogisimHdl` cannot name, so it introduces no new concept.
// `LogisimHdlWiring` supplies the values: it is the one target that sees both modules, and both
// runtimes already depend on it.
//
// ── The surface is small on purpose ─────────────────────────────────────────────────────────
//
// Exactly four things, and they are the complete set. Enumerated by grepping every `std.io`
// reference out of `fpga/data`:
//
//   MapComponent.java:227, :334   `myFactory instanceof RgbLed`      -> isRgbLed
//   MapComponent.java:413         `SevenSegment.getLabels()`         -> sevenSegmentLabels
//   IoComponentTypes.java:167     `SevenSegment.getOutputLabel(id)`  -> sevenSegmentOutputLabel
//   IoComponentTypes.java:169     `RgbLed.getLabel(id)`              -> rgbLedLabel
//
// `FpgaIoInformationContainer.getPinName` (`:994`, `:1054`) reaches for the same two classes plus
// `SevenSegment.ATTR_DP`, and is in the Swing half this port does not carry; when it lands it
// needs no new entries here beyond an `isSevenSegmentOrHexDigit` predicate of the same shape.
//
// The per-component bubble *counts* are a different injection with a different owner: see
// `HdlGeneratorLookup.mapInformation(for:)`, which is keyed by factory name because the answer
// depends on the instance's attributes. These four do not: they are constants and a type test.
//
// ── An unconfigured provider must be detectable ─────────────────────────────────────────────
//
// The defaults answer "no RGB LED anywhere" and "no seven-segment labels", which is a legal,
// silent, wrong state; the exact shape that left 40 HDL registrations unreachable with nothing
// complaining. So `isConfigured` exists to be asserted by whoever calls `installBuiltins`, and
// no default pretends to be an implementation.
//
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.

import LogisimFile

/// The four `std.io` facts `com.cburch.logisim.fpga.data` needs, injected.
///
/// Plain mutable state with a process-wide instance, mirroring `HdlGeneratorLookup.shared` and
/// `Reporter.shared`: `LogisimHdl` is a D1 module (Swift 5 language mode, no Concurrency), and
/// upstream's equivalents are `static` methods on `std.io` classes.
public final class FpgaStdIoFacts {

  /// The process-wide provider. `LogisimHdlWiring` fills it; tests fill it themselves.
  public static let shared = FpgaStdIoFacts()

  /// `comp.getFactory() instanceof RgbLed`: the triple-map special case in
  /// `MapComponent.unmap(int)` and `MapComponent.tryMap(CircuitMapInfo, …)`.
  public var isRgbLed: (any ComponentFactory) -> Bool = { _ in false }

  /// `com.cburch.logisim.std.io.SevenSegment.getLabels()`: the eight segment names, in
  /// `Segment_A … DecimalPoint` order. `MapComponent`'s backward-compatible pin-key parser
  /// matches an old `<mc>` key against this list *by index*, so the order is load-bearing.
  public var sevenSegmentLabels: () -> [String] = { [] }

  /// `com.cburch.logisim.std.io.SevenSegment.getOutputLabel(int)`.
  public var sevenSegmentOutputLabel: (Int) -> String = { String($0) }

  /// `com.cburch.logisim.std.io.RgbLed.getLabel(int)`.
  public var rgbLedLabel: (Int) -> String = { String($0) }

  public init() {}

  /// Whether anything has been installed.
  ///
  /// Exists so a caller can ASSERT rather than trust. An unconfigured provider is not an error,
  /// a headless netlist walk never asks it anything, but a board map built against one silently
  /// loses every RGB-LED triple map and every legacy seven-segment pin key, and that is
  /// indistinguishable from a design that has neither.
  public private(set) var isConfigured = false

  /// Install all four at once. One call, so a partially filled provider cannot exist.
  public func install(
    isRgbLed: @escaping (any ComponentFactory) -> Bool,
    sevenSegmentLabels: @escaping () -> [String],
    sevenSegmentOutputLabel: @escaping (Int) -> String,
    rgbLedLabel: @escaping (Int) -> String
  ) {
    self.isRgbLed = isRgbLed
    self.sevenSegmentLabels = sevenSegmentLabels
    self.sevenSegmentOutputLabel = sevenSegmentOutputLabel
    self.rgbLedLabel = rgbLedLabel
    isConfigured = true
  }

  /// Back to the unconfigured defaults. Test hook, and the counterpart to
  /// `HdlGeneratorLookup.removeAll()`.
  public func removeAll() {
    isRgbLed = { _ in false }
    sevenSegmentLabels = { [] }
    sevenSegmentOutputLabel = { String($0) }
    rgbLedLabel = { String($0) }
    isConfigured = false
  }
}
