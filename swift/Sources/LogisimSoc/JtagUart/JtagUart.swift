// JtagUart.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.soc.jtaguart.JtagUart),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// Ten fixed ports: clock/reset in, IRQ out, and two independent 7-bit "keyboard"/"TTY" byte
// interfaces each with a handshake pair: see `JtagUartState.handleOperations` for the protocol.
//
// Not ported: `paintInstance` (D6/D9).

import Foundation
import LogisimFile
import LogisimKernel
import LogisimStd

/// `com.cburch.logisim.soc.jtaguart.JtagUart`.
public final class JtagUart: SocInstanceFactoryBase {
  /// `JtagUart._ID`. Do NOT change: `.circ` files reference this string.
  public static let id = "SocJtagUart"

  public static let clockPin = 0
  public static let resetPin = 1
  public static let irqPin = 2
  public static let readEnablePin = 3
  public static let clearKeyboardPin = 4
  public static let availablePin = 5
  public static let dataInPin = 6
  public static let dataOutPin = 7
  public static let writePin = 8
  public static let clearTtyPin = 9

  public init() {
    super.init(JtagUart.id, displayName: "JTAG UART", socKind: .slave)
    setOffsetBounds(Bounds.create(0, 0, 300, 60))
  }

  public override func createAttributeSet() -> any AttributeSet { JtagUartAttributes() }

  public override func validateAttributeSet(_ attributes: any AttributeSet) throws {
    guard attributes is JtagUartAttributes else {
      throw ComponentError.wrongAttributeSet(factory: name)
    }
  }

  // `Port` is qualified because Foundation re-exports `NSPort` as `Port`, making the bare
  // name ambiguous wherever Foundation and LogisimStd are both imported.
  public override func ports(_ attributes: any AttributeSet) -> [LogisimStd.Port] {
    [
      LogisimStd.Port(0, 50, .input, 1),  // CLOCK_PIN
      LogisimStd.Port(0, 30, .input, 1),  // RESET_PIN
      LogisimStd.Port(300, 50, .output, 1),  // IRQ_PIN
      LogisimStd.Port(10, 0, .output, 1),  // READ_ENABLE_PIN
      LogisimStd.Port(20, 0, .output, 1),  // CLEAR_KEYBOARD_PIN
      LogisimStd.Port(130, 0, .input, 1),  // AVAILABLE_PIN
      LogisimStd.Port(140, 0, .input, 7),  // DATA_IN_PIN
      LogisimStd.Port(160, 0, .output, 7),  // DATA_OUT_PIN
      LogisimStd.Port(180, 0, .output, 1),  // WRITE_PIN
      LogisimStd.Port(190, 0, .output, 1),  // CLEAR_TTY_PIN
    ]
  }

  public override func propagate(_ state: any InstanceState) throws {
    guard let jtagState = state.attributeValue(JtagUartAttributes.jtagState) else { return }
    jtagState.handleOperations(state)
  }

  public override func slaveInterface(
    _ attributes: any AttributeSet
  ) -> (any SocBusSlaveInterface)? {
    attributes.getValue(JtagUartAttributes.jtagState)
  }
}
