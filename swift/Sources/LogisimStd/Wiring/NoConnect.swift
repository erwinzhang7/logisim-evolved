// NoConnect.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.wiring.DoNotConnect),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// Filed here as `NoConnect.swift` per the task's file list; the Java **class** is named
// `DoNotConnect` (file `DoNotConnect.java`) but its `_ID`, the token every `.circ` file actually
// stores, is `"NoConnect"`. Both names are recorded so a reader searching for either finds this
// file.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

/// `com.cburch.logisim.std.wiring.DoNotConnect`.
public final class NoConnect: InstanceFactoryBase {

  /// `DoNotConnect._ID`. Do not change, `.circ` files reference it.
  public static let id = "NoConnect"

  /// Java has no `DoNotConnect.FACTORY` constant; `WiringLibrary` builds `new
  /// AddTool(new DoNotConnect())` inline. Named `factory` for consistency with the rest of this
  /// port.
  public static let factory = NoConnect()

  public init() {
    super.init(NoConnect.id, displayName: "Do not connect")
    setAttributes([StdAttr.width.binding(.one)])
    setOffsetBounds(Bounds.create(-5, -5, 10, 10))
    setPorts([Port(0, 0, .inout_, StdAttr.width)])
  }

  // NOT PORTED: `setIconName("noconnect.gif")`, icon, M6.

  // NOT PORTED: `InlinedHdlGeneratorFactory`, HDL backlog (D11).

  /// `DoNotConnect.propagate(InstanceState)`: "do nothing"; this component exists purely to
  /// mark a pin the designer intentionally leaves unconnected, silencing the "unconnected input"
  /// warning elsewhere; it drives nothing itself.
  public override func propagate(_ state: any InstanceState) throws {
    // do nothing
  }

  // MARK: Painting (DoNotConnect.java:46-68)

  /// `drawInstance(InstancePainter, boolean isGhost)`: a bare X, red when placed and grey
  /// while dragging.
  ///
  /// Note this one does **not** translate by the location: it adds `loc` to every coordinate
  /// by hand. Same result, and transcribed the same way so the two files line up.
  private func drawInstance(_ painter: InstancePainter, isGhost: Bool) {
    let g = painter.g
    let loc = painter.location
    g.color = isGhost ? .rgba(.gray) : .rgba(.red)
    g.drawLine(loc.x - 5, loc.y - 5, loc.x + 5, loc.y + 5)
    g.drawLine(loc.x - 5, loc.y + 5, loc.x + 5, loc.y - 5)
  }

  public func paintGhost(_ painter: InstancePainter) {
    drawInstance(painter, isGhost: true)
  }

  public func paintInstance(_ painter: InstancePainter) {
    drawInstance(painter, isGhost: false)
    painter.drawPorts()
  }
}

extension NoConnect: InstancePaintable {}
