// SocVga.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.soc.vga.SocVga),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// No pins at all (a pure bus slave/sniffer/master, like `SocMemory`); its footprint is whatever
// the current display mode needs, which is why `offsetBounds`, not a fixed `setOffsetBounds`,
// is overridden.
//
// Not ported: `paintInstance` (D6/D9; the renderer draws the framebuffer via
// `VgaDisplayState.image(circuitState:)`), `DynamicElementProvider`/`createDynamicElement`
// (the appearance-editor "drop a VGA display into a subcircuit icon" feature; `SocVgaShape` is
// pure drawing, D6/D9; a `.circ` that already carries such a shape is not lost, because
// `visible-*` elements take `CircuitAppearanceReader`'s D8 verbatim path and re-emit unchanged).
//
// Also not ported, and previously unrecorded anywhere in this module: `getInstanceFeature
// (MenuExtender.class)` (`SocVga.java:82-85`) and the `VgaMenu` it returns. `VgaMenu` is one menu
// item, **Export C**, and, exactly as `SocPio.swift` now records for `PioMenu`, the dialog half
// is UI (D9) while the body is a generator: `VgaMenu.java:104-107` emits the five
// `SOFT_MODE_*_MASK` defines from `VgaAttributes`, then `SocSupport.addAllFunctions(…,
// "VgaMode", startAddress, 0)` for the mode-select register. That generator is genuinely
// missing, not excluded; `SocSupport.swift` carries the costing for both components.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimStd

/// `com.cburch.logisim.soc.vga.SocVga`.
public final class SocVga: SocInstanceFactoryBase {
  /// `SocVga._ID`. Do NOT change: `.circ` files reference this string.
  public static let id = "SocVga"

  public init() {
    super.init(SocVga.id, displayName: "VGA screen", socKind: [.slave, .sniffer, .master])
  }

  public override func createAttributeSet() -> any AttributeSet { VgaAttributes() }

  public override func validateAttributeSet(_ attributes: any AttributeSet) throws {
    guard attributes is VgaAttributes else {
      throw ComponentError.wrongAttributeSet(factory: name)
    }
  }

  /// `getOffsetBounds(AttributeSet)`.
  public override func offsetBounds(_ attributes: any AttributeSet) -> Bounds {
    let mode = attributes.getValue(VgaAttributes.vgaState)?.currentMode ?? .mode160x120
    return VgaState.size(for: mode)
  }

  public override func propagate(_ state: any InstanceState) throws {
    if state.data == nil {
      state.setData(state.attributeValue(VgaAttributes.vgaState)?.newState())
    }
  }

  public override func slaveInterface(
    _ attributes: any AttributeSet
  ) -> (any SocBusSlaveInterface)? {
    attributes.getValue(VgaAttributes.vgaState)
  }

  public override func snifferInterface(
    _ attributes: any AttributeSet
  ) -> (any SocBusSnifferInterface)? {
    attributes.getValue(VgaAttributes.vgaState)
  }
}
