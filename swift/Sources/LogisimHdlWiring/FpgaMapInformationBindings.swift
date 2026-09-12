// FpgaMapInformationBindings.swift: part of logisim-evolved.
//
// The `StdAttr.MAPINFO` half of the injection task #38 settled: how many board-facing *bubbles*
// each `com.cburch.logisim.std.io` component contributes, and what each is called.
//
// ══ THIS FILE IS A PROPOSAL AS MUCH AS IT IS A FIXTURE ══════════════════════════════════════
//
// It lives in the test target because that is the only place in the package, other than
// `LogisimHdlWiring`, that may import **both** `LogisimStd` and `LogisimHdl`, and the test
// target is not a runtime, which is exactly the defect that left 40 HDL registrations
// unreachable. So this is the *shape* the real binding takes; moving it into `LogisimHdlWiring`
// verbatim (rename `install(into:)` to sit beside `registerAllBuiltins`) is what makes it live,
// and the suite here is the evidence that it is right before it moves.
//
// ── Why injection at all ────────────────────────────────────────────────────────────────────
//
// `ComponentMapInformationContainer` lives in `LogisimHdl`. `LogisimStd` does not depend on
// `LogisimHdl`, so it cannot construct one; `LogisimHdl` must never depend on `LogisimStd`,
// because the per-component generators need that edge and the pair would close a cycle. The
// same argument already produced `AbstractHdlGeneratorFactory.clockAttributes` and
// `HdlParameters(widthAttribute:)`, and it produces this.
//
// ── Why closures over the attribute set, and not a table ────────────────────────────────────
//
// Because a table would be **wrong**, and the jar says so. `netlist-4.1.0.oracle` contains two
// different `MAPINFO DotMatrix n=0,16,0` rows, one `Row0Col0…Row0Col15`, one
// `Row0Col0…Row1Col7`, the same factory, the same bubble count, different labels, because one
// is 1×16 and the other 2×8. Keying by factory name alone silently picks whichever was seen
// last. Upstream stores a live container per instance and mutates it from
// `instanceAttributeChanged`; a pure function of the attribute set reproduces that exactly, and
// `MapInformationOracleTests` checks it does, component by component, against the jar.
//
// Derived from logisim-evolution (`com/cburch/logisim/std/io/*.java`), GPL-3.0-only. See LICENSE.md.

import LogisimFile
import LogisimHdl
import LogisimKernel
import LogisimStd

public enum FpgaMapInformationBindings {

  /// Installs the `StdAttr.MAPINFO` answer for every `std.io` factory that declares one.
  ///
  /// Uses the merging registrar rather than `register(factoryName:_:)` so it composes with
  /// whatever `registerAllBuiltins` already put there; a full `Registration` would clobber the
  /// generator alongside it.
  public static func install(into lookup: HdlGeneratorLookup) {
    for (name, build) in bindings {
      lookup.registerMapInformation(factoryName: name, build)
    }
  }

  /// The nine factories `StdAttr.MAPINFO` appears on in 4.1.0, minus `ReptarLocalBus`: see the
  /// note at the bottom of the file.
  static let bindings: [String: (any AttributeSet) -> ComponentMapInformationContainer] = [

    // `Button.java:136`, `new ComponentMapInformationContainer(1, 0, 0)`, no labels, so the
    // container answers the index as a decimal string and the jar prints `in=0`.
    Button.id: { _ in ComponentMapInformationContainer(inputPorts: 1, outputPorts: 0, inOutPorts: 0)
    },

    // `Led.java:91`, `new ComponentMapInformationContainer(0, 1, 0)`.
    Led.id: { _ in ComponentMapInformationContainer(inputPorts: 0, outputPorts: 1, inOutPorts: 0) },

    // `RgbLed.java:109`.
    RgbLed.id: { _ in
      ComponentMapInformationContainer(
        inputPorts: 0, outputPorts: 3, inOutPorts: 0,
        inputLabels: nil, outputLabels: RgbLed.labels(), inOutLabels: nil)
    },

    // `SevenSegment.java:194`; the *constructor* default is 8 and `updatePorts` immediately
    // rewrites it to `hasDp ? 8 : 7`, so the effective value is the latter. The label list stays
    // 8 long in both cases and the extra entry is simply never indexed.
    SevenSegment.id: { attrs in
      sevenSegmentContainer(hasDecimalPoint: attrs.getValue(SevenSegment.attrDecimalPoint) ?? true)
    },

    // `HexDigit.java:97`, `setNrOfOutports(6 + nrPorts, SevenSegment.getLabels())` with
    // `nrPorts = dp ? 2 : 1`, which is the same 7-or-8 as above by a different route.
    HexDigit.id: { attrs in
      sevenSegmentContainer(hasDecimalPoint: attrs.getValue(SevenSegment.attrDecimalPoint) ?? true)
    },

    // `DipSwitch.java:151` / `:214`, one input bubble per switch, `sw_1`-based.
    DipSwitch.id: { attrs in
      let switches = (attrs.getValue(DipSwitch.size) ?? BitWidth.known(4)).width
      return ComponentMapInformationContainer(
        inputPorts: switches, outputPorts: 0, inOutPorts: 0,
        inputLabels: dipSwitchLabels(switches), outputLabels: nil, inOutLabels: nil)
    },

    // `DotMatrixBase.java:262` / `:347`, `rows * cols` output bubbles in row-major order.
    DotMatrix.id: { attrs in
      dotMatrixContainer(
        rows: (attrs.getValue(DotMatrix.attrMatrixRows) ?? BitWidth.known(4)).width,
        cols: (attrs.getValue(DotMatrix.attrMatrixCols) ?? BitWidth.known(5)).width)
    },

    // `LedBar` is a `DotMatrixBase` and shares every one of those code paths; only its default
    // row count differs.
    LedBar.id: { attrs in
      dotMatrixContainer(
        rows: (attrs.getValue(LedBar.attrMatrixRows) ?? BitWidth.known(1)).width,
        cols: (attrs.getValue(LedBar.attrMatrixCols) ?? BitWidth.known(4)).width)
    },

    // `PortIo.java:352-367`. Note the direction split: `INPUT` and `OUTPUT` put every pin on the
    // corresponding side, and BOTH in-out modes put every pin in the in-out group.
    PortIo.id: { attrs in
      let pins = (attrs.getValue(PortIo.attrSize) ?? BitWidth.known(8)).width
      let labels = PortIo.labels(count: pins)
      switch attrs.getValue(PortIo.attrDirection) ?? .inOutSingleEnable {
      case .input:
        return ComponentMapInformationContainer(
          inputPorts: pins, outputPorts: 0, inOutPorts: 0,
          inputLabels: labels, outputLabels: labels, inOutLabels: labels)
      case .output:
        return ComponentMapInformationContainer(
          inputPorts: 0, outputPorts: pins, inOutPorts: 0,
          inputLabels: labels, outputLabels: labels, inOutLabels: labels)
      case .inOutSingleEnable, .inOutMultiEnable:
        return ComponentMapInformationContainer(
          inputPorts: 0, outputPorts: 0, inOutPorts: pins,
          inputLabels: labels, outputLabels: labels, inOutLabels: labels)
      }
    },
  ]

  private static func sevenSegmentContainer(
    hasDecimalPoint: Bool
  ) -> ComponentMapInformationContainer {
    ComponentMapInformationContainer(
      inputPorts: 0, outputPorts: hasDecimalPoint ? 8 : 7, inOutPorts: 0,
      inputLabels: nil, outputLabels: SevenSegment.labels(), inOutLabels: nil)
  }

  private static func dotMatrixContainer(rows: Int, cols: Int) -> ComponentMapInformationContainer {
    ComponentMapInformationContainer(
      inputPorts: 0, outputPorts: rows * cols, inOutPorts: 0,
      inputLabels: nil, outputLabels: DotMatrix.labels(rows: rows, cols: cols), inOutLabels: nil)
  }

  /// `DipSwitch.getLabels(int)` / `getInputLabel(int)`. Not on the Swift `DipSwitch`, its
  /// header records the omission, so it is spelled out here; it is two lines and moving it onto
  /// the factory is a `LogisimStd` change this task does not own.
  private static func dipSwitchLabels(_ count: Int) -> [String] {
    (0..<max(count, 0)).map { "sw_\($0 + 1)" }
  }
}

/// The other half of task #38's injection: the four `std.io` facts `FpgaMapComponent` and
/// `IoComponentTypes` need. Same argument, same destination; see `FpgaStdIoFacts.swift`.
///
/// Kept beside the map-information bindings because they move to `LogisimHdlWiring` together;
/// two calls, one place.
public enum FpgaStdIoFactBindings {
  public static func install(into facts: FpgaStdIoFacts) {
    facts.install(
      // `myFactory instanceof RgbLed`. By factory *identity*, not by name: `RgbLed.id` is what a
      // `.circ` carries, and a user library could in principle reuse the string, whereas the
      // builtin library holds exactly one `RgbLed` instance (D4).
      isRgbLed: { $0 is RgbLed },
      sevenSegmentLabels: { SevenSegment.labels() },
      sevenSegmentOutputLabel: { SevenSegment.outputLabel($0) },
      // `RgbLed.getLabel(int)`. Not on the Swift `RgbLed`, only `getLabels()` came across, so
      // it is spelled out, bounds check and all. Upstream's guard is `id > getLabels().size()`,
      // an off-by-one that lets index 3 through to `List.get(3)` and throw; the port answers
      // `"Undefined"` there instead, because D13 forbids turning a display-string lookup into a
      // crash and no caller can distinguish the two on a valid index.
      rgbLedLabel: { id in
        let labels = RgbLed.labels()
        return (id < 0 || id >= labels.count) ? "Undefined" : labels[id]
      })
  }
}

// NOT BOUND, deliberately:
//
//   * `ReptarLocalBus`: `ComponentMapInformationContainer(13, 2, 16, …)` with three label lists
//     built from `getInputLabel`/`getOutputLabel`/`getIoLabel`, none of which is ported onto the
//     Swift `ReptarLocalBus` (its own header records that). No corpus circuit instantiates one,
//     so binding it would add ~30 transcribed strings with **nothing able to check them**; the
//     jar oracle would have no row to compare against. Left out rather than guessed; the note is
//     the deliverable.
