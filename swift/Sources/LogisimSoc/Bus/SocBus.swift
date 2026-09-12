// SocBus.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.soc.bus.SocBus),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// The bus component itself: one input pin (Reset), and a `propagate` that does nothing but
// create the component's `SocBusTraceLog` on first run and clear it on a rising reset edge. All
// of the actual arbitration lives in `SocBusFabric`/`SocSimulationManager` (this file's
// `propagate` only reaches the trace log, exactly as upstream's does).
//
// Not ported: `paintInstance` (draws the trace-window strip live on the canvas, D6/D9; the
// renderer draws `SocBusTraceLog.entries` itself), `providesSubCircuitMenu`/
// `getInstanceFeature(MenuExtender.class)` (the right-click "show memory map" menu item: UI),
// `SocBusMenuProvider` (not ported at all: pure `JMenuItem`/`JDialog` wiring with no model
// content, the memory-map inspector it opens is `SocMemoryMap`, already ported).
//
// The two `soc/gui` classes reachable ONLY from that menu provider are not ported either, and
// had no record anywhere in this module until now:
//   * `gui/BusTransactionInsertionGui`; the "insert a bus transaction by hand" dialog. Every
//     transaction it can build, `SocBusFabric.sendTransaction` already executes; what is absent
//     is the dialog that lets a *user* type one. There is no model content in it.
//   * `gui/ListeningFrame`; a `JFrame` subclass that re-titles itself when the locale changes.
//     Swing shell, D9, zero model content; `soc/gui`'s three windows extend it.
// Neither is reachable from a non-GUI path. Measured over the whole 4.1.0 source tree,
// `BusTransactionInsertionGui` is named by exactly two files, its own, and
// `SocBusMenuProvider`, and `ListeningFrame` by four: its own, `SocBusMenuProvider`,
// `SocUpMenuProvider` and `gui/AssemblerPanel`. Every one of those is itself a menu/window
// class this port does not bring across, so dropping these two costs nothing that is not
// already gone with the menu providers. No `.circ` can reference either: they place no
// component and write no XML.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimStd

/// `SocBusStateInfo.TRACE_HEIGHT`; needed here (not just by the dropped painter) because it
/// sizes `offsetBounds`, which is model geometry, not drawing.
public let socBusTraceHeight = 30

/// `com.cburch.logisim.soc.bus.SocBus`.
public final class SocBus: SocInstanceFactoryBase {
  /// `SocBus._ID`. Do NOT change: `.circ` files reference this string.
  public static let id = "SocBus"

  private static let resetPort = 0

  public init() {
    super.init(SocBus.id, displayName: "SoC bus simulator", socKind: .bus)
  }

  public override func createAttributeSet() -> any AttributeSet { SocBusAttributes() }

  public override func validateAttributeSet(_ attributes: any AttributeSet) throws {
    guard attributes is SocBusAttributes else {
      throw ComponentError.wrongAttributeSet(factory: name)
    }
  }

  /// `getOffsetBounds(AttributeSet)`.
  public override func offsetBounds(_ attributes: any AttributeSet) -> Bounds {
    let traces = attributes.getValue(SocBusAttributes.nrOfTraces)?.width ?? 5
    return Bounds.create(0, 0, 640, (traces + 1) * socBusTraceHeight)
  }

  /// `configureNewInstance(Instance)`'s port half (the label text-field placement is UI/paint).
  // `Port` is qualified because Foundation re-exports `NSPort` as `Port`, making the bare
  // name ambiguous wherever Foundation and LogisimStd are both imported.
  public override func ports(_ attributes: any AttributeSet) -> [LogisimStd.Port] {
    [LogisimStd.Port(0, 10, .input, 1)]
  }

  /// `propagate(InstanceState)`.
  public override func propagate(_ state: any InstanceState) throws {
    if let existing = state.data as? SocBusTraceLog {
      if state.portValue(Self.resetPort) == .trueValue {
        existing.clear()
      }
    } else {
      state.setData(SocBusTraceLog())
    }
  }

  public override func slaveInterface(_ attributes: any AttributeSet) -> (any SocBusSlaveInterface)? {
    nil
  }
  public override func snifferInterface(
    _ attributes: any AttributeSet
  ) -> (any SocBusSnifferInterface)? { nil }
  public override func processorInterface(
    _ attributes: any AttributeSet
  ) -> (any SocProcessorInterface)? { nil }
}
