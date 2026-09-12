// SocPio.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.soc.pio.SocPio),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// Unlike every other factory in this module, `SocPio`'s port list is genuinely attribute-
// dependent (width, direction, and whether an IRQ pin is present all change the port count and
// layout); this is exactly the shape `ports(_:)` exists for (see `InstanceFactory.swift`'s file
// header): Java's `updatePorts(Instance)` collapses into a pure function of `attributes`.
//
// Not ported: `paintInstance`/`paintPins` (D6/D9), `PioMenu`/`getInstanceFeature(MenuExtender
// .class)` (right-click menu; UI).
//
// ── THE `PioMenu` HALF OF THAT LINE USED TO SAY "carries no model logic to port". IT DOES ────
//
// That claim was wrong, and it is the reason this component's one genuinely-missing feature was
// invisible in the parity count. `PioMenu` has a single menu item, **Export C**
// (`PioMenu.java:43`), whose body (`PioMenu.java:54-160`) is not a dialog with a file write on
// the end; it is a code generator that branches on this component's model state and emits a
// different set of accessors for each configuration:
//
//   * port direction decides whether `OutputValue` (setter), `InputValue` (getter) or both
//     appear (`:95`, `:102`);
//   * `PORT_BIDIR` adds a `DirectionReg` getter+setter pair at offset 2 (`:107`);
//   * `inputGeneratesIrq()` adds `IrqMaskReg` at offset 2, and the *comment text* differs for
//     edge- versus level-sensitive (`:112`);
//   * `inputIsCapturedSynchronisely()` adds `EdgeCapturReg` at offset 3, with the remark text
//     keyed on rising/falling/any and on whether per-bit clearing is supported (`:120`);
//   * `outputSupportsBitManipulations()` adds `OutsetReg`/`OutclearReg` at offset 4 (`:137`).
//
// So the correct statement is: the **dialog** is UI (D9), and the **generator** is model content
// this port does not have. It is genuinely missing, not deliberately excluded: see
// `SocSupport.swift`, which owns the three emitters (`addAllFunctions`, `addGetterFunction`,
// `addSetterFunction`) the body above calls, and which now carries the costing.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimStd

/// `com.cburch.logisim.soc.pio.SocPio`.
public final class SocPio: SocInstanceFactoryBase {
  /// `SocPio._ID`. Do NOT change: `.circ` files reference this string.
  public static let id = "SocPio"

  public static let resetIndex = 0
  public static let irqIndex = 1

  public init() {
    super.init(SocPio.id, displayName: "Parallel input/output expander", socKind: .slave)
    setOffsetBounds(Bounds.create(0, 0, 380, 120))
  }

  public override func createAttributeSet() -> any AttributeSet { PioAttributes() }

  public override func validateAttributeSet(_ attributes: any AttributeSet) throws {
    guard attributes is PioAttributes else {
      throw ComponentError.wrongAttributeSet(factory: name)
    }
  }

  private static func hasIrqPin(_ attributes: any AttributeSet) -> Bool {
    attributes.containsAttribute(PioAttributes.genIrq)
      && (attributes.getValue(PioAttributes.genIrq) ?? false)
  }

  /// `updatePorts(Instance)`.
  //
  // `Port` is qualified throughout this file: Foundation re-exports `NSPort` under the name
  // `Port`, so the bare name is ambiguous in any module that imports both Foundation and
  // LogisimStd. The project type keeps its name (it mirrors
  // `com.cburch.logisim.instance.Port` and is used across the whole component library);
  // the reference is what gets qualified.
  public override func ports(_ attributes: any AttributeSet) -> [LogisimStd.Port] {
    let nrBits = (attributes.getValue(StdAttr.width) ?? BitWidth.known(1)).width
    var nrOfPorts = nrBits
    let direction = attributes.getValue(PioAttributes.direction) ?? .input
    let hasIrq = Self.hasIrqPin(attributes)
    if direction == .inout_ { nrOfPorts *= 2 }
    var index = hasIrq ? 2 : 1
    nrOfPorts += index

    var ports = [LogisimStd.Port?](repeating: nil, count: nrOfPorts)
    if hasIrq {
      ports[Self.irqIndex] = LogisimStd.Port(20, 0, .output, 1)
    }
    ports[Self.resetIndex] = LogisimStd.Port(0, 110, .input, 1)
    if direction == .input || direction == .inout_ {
      for b in 0..<nrBits {
        ports[index + b] = LogisimStd.Port(370 - b * 10, 120, .input, 1)
      }
      index += nrBits
    }
    if direction == .inout_ || direction == .output || direction == .bidir {
      let portType: PortType = (direction == .bidir) ? .inout_ : .output
      for b in 0..<nrBits {
        ports[index + b] = LogisimStd.Port(370 - b * 10, 0, portType, 1)
      }
    }
    return ports.map { $0 ?? LogisimStd.Port(0, 0, .input, 1) }
  }

  public override func propagate(_ state: any InstanceState) throws {
    guard let pioState = state.attributeValue(PioAttributes.pioState) else { return }
    _ = pioState.handleOperations(state, captureOnly: false)
  }

  public override func slaveInterface(
    _ attributes: any AttributeSet
  ) -> (any SocBusSlaveInterface)? {
    attributes.getValue(PioAttributes.pioState)
  }
}
