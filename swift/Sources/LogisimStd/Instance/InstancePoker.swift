// InstancePoker.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.instance.InstancePoker),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).

import Foundation
import LogisimFile
import LogisimKernel

/// AppKit-free stand-in for the coordinates used from `java.awt.event.MouseEvent`.
public struct PokeMouseEvent {
  public let x: Int
  public let y: Int

  public init(x: Int, y: Int) {
    self.x = x
    self.y = y
  }
}

/// AppKit-free stand-in for the fields used from `java.awt.event.KeyEvent`.
public struct PokeKeyEvent {
  /// An AWT `KeyEvent.VK_*` value.
  public let keyCode: Int
  /// Java's UTF-16 `char`; `nil` represents `KeyEvent.CHAR_UNDEFINED`.
  public let keyChar: UInt16?
  /// Mirrors `InputEvent.consume()`; poker key callbacks take this value `inout`.
  public var consumed: Bool = false

  public init(keyCode: Int, keyChar: UInt16?, consumed: Bool = false) {
    self.keyCode = keyCode
    self.keyChar = keyChar
    self.consumed = consumed
  }
}

/// `com.cburch.logisim.instance.InstancePoker` (lines 16–39), expressed as a protocol so stock
/// components can supply their existing nested `Poker` classes without subclassing a base class.
public protocol InstancePoker: AnyObject {
  func mousePressed(_ state: any InstanceState, _ event: PokeMouseEvent)
  func mouseReleased(_ state: any InstanceState, _ event: PokeMouseEvent)
  func mouseDragged(_ state: any InstanceState, _ event: PokeMouseEvent)
  func keyPressed(_ state: any InstanceState, _ event: inout PokeKeyEvent)
  func keyReleased(_ state: any InstanceState, _ event: inout PokeKeyEvent)
  func keyTyped(_ state: any InstanceState, _ event: inout PokeKeyEvent)
  func stopEditing(_ state: any InstanceState)

  /// Corresponds to Java's `init(InstanceState, MouseEvent)` (lines 21–23).
  func beginPoke(_ state: any InstanceState, _ event: PokeMouseEvent) -> Bool

  /// `getBounds(InstancePainter)` (`InstancePoker.java:17-19`): the rectangle the poke caret
  /// occupies, which is what decides whether the *next* click stays inside this poke or ends it
  /// (`PokeTool.mousePressed`: `if (pokeCaret != null && !pokeCaret.getBounds(g).contains(loc))`).
  ///
  /// Takes an `InstancePainter` rather than the component because upstream's does: two of the
  /// three overriders (`MemPoker`'s two sub-pokers) derive the rectangle from paint-time
  /// geometry, not from the model.
  func pokeBounds(_ painter: InstancePainter) -> Bounds

  /// `paint(InstancePainter)` (`InstancePoker.java:37`): the poke highlight, drawn over the
  /// component every frame for as long as the poke is live.
  ///
  /// D6: the painter carries the `SceneBuilder`; nothing here touches a drawing context.
  func paint(_ painter: InstancePainter)
}

extension InstancePoker {
  public func mousePressed(_ state: any InstanceState, _ event: PokeMouseEvent) {}
  public func mouseReleased(_ state: any InstanceState, _ event: PokeMouseEvent) {}
  public func mouseDragged(_ state: any InstanceState, _ event: PokeMouseEvent) {}
  public func keyPressed(_ state: any InstanceState, _ event: inout PokeKeyEvent) {}
  public func keyReleased(_ state: any InstanceState, _ event: inout PokeKeyEvent) {}
  public func keyTyped(_ state: any InstanceState, _ event: inout PokeKeyEvent) {}
  public func stopEditing(_ state: any InstanceState) {}
  public func beginPoke(_ state: any InstanceState, _ event: PokeMouseEvent) -> Bool { true }

  /// Java's default is `painter.getInstance().getBounds()` (`InstancePoker.java:18`).
  ///
  /// `InstancePainter.bounds` is `component.bounds` whenever the painter is component-backed,
  /// which is the only way a poke painter is ever built (`PokeOverlayRenderer` refuses a ghost),
  /// so the two agree exactly. For a factory-backed painter upstream would throw an NPE: a
  /// catchable `RuntimeException`, so D13 forbids a trap here, and `paint` cannot `throw`; the
  /// painter answers `.empty` instead, which the caller treats the same way it treats an
  /// off-screen caret.
  public func pokeBounds(_ painter: InstancePainter) -> Bounds { painter.bounds }

  /// Java's `paint` is an empty body (`InstancePoker.java:37`), so a poker that draws no
  /// highlight is not an omission; it is upstream's default, and `Button`, `DipSwitch`,
  /// `Switch`, `Slider`, `Keyboard`, `PortIo` and the flip-flops all take it.
  public func paint(_ painter: InstancePainter) {}
}
