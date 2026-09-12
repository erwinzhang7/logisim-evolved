// CounterPoker.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.memory.CounterPoker),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// Upstream's `CounterPoker extends RegisterPoker` and overrides **`paint` only**; the edit
// caret is drawn at a different place and in a different shape for a counter's two appearances
// than for a register's. All the actual editing (`init`, `keyTyped`, `keyPressed`, and the
// `RegisterData` a `Counter` shares with a `Register`) is inherited unchanged.
//
// That one override is ported below (M6). See `MemPainter.swift` for the paint seam.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

/// `com.cburch.logisim.std.memory.CounterPoker`.
public final class CounterPoker: RegisterPoker {

  /// `CounterPoker.paint(InstancePainter)` (`CounterPoker.java:18-39`).
  ///
  /// The CLASSIC branch's `7 * len + 2` is genuinely 7, not the 8 `RegisterPoker` uses; the
  /// counter's classic readout is drawn in a narrower spot. Reproduced as written.
  public override func paint(_ painter: any MemPainter) {
    let bds = painter.bounds
    let width = painter.attributeValue(StdAttr.width)?.width ?? 8
    let len = (width + 3) / 4

    let g = painter.graphics
    g.color = MemPaint.red
    if painter.attributeValue(StdAttr.appearance) == StdAttr.appearClassic {
      if len > 4 {
        g.drawRect(bds.x, bds.y + 3, bds.width, 25)
      } else {
        let wid = 7 * len + 2
        g.drawRect(bds.x + (bds.width - wid) / 2, bds.y + 4, wid, 15)
      }
    } else {
      let xcenter = Counter.symbolWidth(width) - 25
      g.drawRect(bds.x + xcenter - len * 4, bds.y + 22, len * 8, 16)
    }
    g.color = MemPaint.black
  }
}
