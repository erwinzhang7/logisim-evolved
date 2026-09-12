// ArithPaint.swift: part of logisim-evolved.
//
// Shared drawing helpers for the `Arith` family, derived from logisim-evolution
// (com.cburch.logisim.instance.InstancePainter.drawPort /
// com.cburch.logisim.comp.ComponentDrawContext.{drawPin,drawPinMarker}),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// Every `Arith` component's `paintInstance` calls `painter.drawBounds()` and
// `painter.drawPort(i[, label, dir])`: generic `InstancePainter`/`ComponentDrawContext`
// methods shared by all ~350 stock components, not `Arith`-specific. That shared Instance
// painter is not this slice's to build (see `AbstractTtlGate.swift`'s header for the same call
// on the TTL side), so the small subset `Arith` actually uses is reproduced here instead.
//
// **Deviation (mechanism).** `ComponentDrawContext.drawPin`'s marker colour is
// `getShowState() ? <live value colour> : COMPONENT_COLOR`; `getShowState()` is
// `!printView && showState`, both of which default `true`/`false` respectively, so on-screen
// rendering is *always* the live-value branch in practice. Hardcoded that way here; there is no
// `printView`/`showState` toggle modelled yet (D9: that is UI state, not kernel or component
// state). The ambient `g.setColor(...)` calls each `paintInstance` makes before a `drawPort`
// call are otherwise inert for an *unlabelled* port (the marker colour never reads the ambient
// colour) and matter only for a *labelled* port's text, which upstream restores the ambient
// colour for after drawing the marker: `withColor` reproduces exactly that save/restore.
import LogisimFile
import LogisimKernel
import LogisimRender

enum ArithPaint {

  /// `AppPreferences.COMPONENT_COLOR`'s default (`0x00000000`, opaque black once `new Color(int)`
  /// drops the alpha byte).
  static let componentColor = SceneColor.black

  /// `AppPreferences.COMPONENT_SECONDARY_COLOR`'s default (`0x99999999` → opaque `#999999`).
  static let secondaryColor = SceneColor.rgb(0x99_9999)

  /// `InstancePainter.drawPort(int)` → `ComponentDrawContext.drawPin(Component, int)`.
  static func drawPort(_ painter: SceneBuilder, _ state: any InstanceState, _ index: Int) {
    let loc = state.component.end(at: index).location
    painter.withColor(.palette(state.portValue(index).paletteIndex)) {
      painter.drawPinMarker(loc.x, loc.y)
    }
  }

  /// `InstancePainter.drawPorts()` → `ComponentDrawContext.drawPins(Component)`: every port,
  /// unlabelled, coloured by its live value.
  static func drawAllPorts(_ painter: SceneBuilder, _ state: any InstanceState) {
    let ends = state.component.ends
    for i in 0..<ends.count {
      painter.withColor(.palette(state.portValue(i).paletteIndex)) {
        painter.drawPinMarker(ends[i].location.x, ends[i].location.y)
      }
    }
  }

  /// `InstancePainter.drawPort(int, String, Direction)` →
  /// `ComponentDrawContext.drawPin(Component, int, String, Direction)`. The label is drawn in
  /// whatever colour `painter.color` holds when this is called: the caller's ambient colour,
  /// exactly as Java's `curColor` restore does.
  static func drawPort(
    _ painter: SceneBuilder, _ state: any InstanceState, _ index: Int, label: String,
    direction: Direction
  ) {
    let loc = state.component.end(at: index).location
    painter.withColor(.palette(state.portValue(index).paletteIndex)) {
      painter.drawPinMarker(loc.x, loc.y)
    }
    switch direction {
    case .east:
      painter.drawText(label, x: loc.x + 3, y: loc.y, halign: .left, valign: .center)
    case .west:
      painter.drawText(label, x: loc.x - 3, y: loc.y, halign: .right, valign: .center)
    case .south:
      painter.drawText(label, x: loc.x, y: loc.y - 3, halign: .center, valign: .baseline)
    case .north:
      painter.drawText(label, x: loc.x, y: loc.y + 3, halign: .center, valign: .top)
    }
  }
}
