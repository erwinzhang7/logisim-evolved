// Ttl74163.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.ttl.Ttl74163),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// TTL 74x163: 4-bit synchronous binary counter: same pin/port layout as `Ttl74161`, but
// `CLEAR` is synchronous (gated by the clock edge) rather than asynchronous.

import Foundation
import LogisimFile
import LogisimKernel

public final class Ttl74163: Ttl74161 {

  /// `Ttl74163._ID`. "Unique identifier of the tool, used as reference in project files. Do NOT
  /// change as it will prevent project files from loading.", upstream's own comment.
  public override class var id: String { "74163" }

  public init() {
    super.init(Ttl74163.id)
  }

  public override func propagateTtl(_ state: any InstanceState) throws {
    let data = Ttl74161.getStateData(state)

    let triggered = try data.clock.updateClock(
      state.portValue(Ttl74161.portIndexClk), trigger: StdAttr.triggerRising)
    var counter = data.getValue().toLongValue()
    if triggered {
      let nClear = state.portValue(Ttl74161.portIndexNClr).toLongValue()
      let nLoad = state.portValue(Ttl74161.portIndexNLoad).toLongValue()
      if nClear == 0 {
        counter = 0
      } else if nLoad == 0 {
        counter =
          state.portValue(Ttl74161.portIndexA).toLongValue()
          + (state.portValue(Ttl74161.portIndexB).toLongValue() << 1)
          + (state.portValue(Ttl74161.portIndexC).toLongValue() << 2)
          + (state.portValue(Ttl74161.portIndexD).toLongValue() << 3)
      } else if state.portValue(Ttl74161.portIndexEnP).and(state.portValue(Ttl74161.portIndexEnT))
        .toLongValue() == 1
      {
        counter = (counter + 1) & 15
      }
    }
    Ttl74161.updateState(state, counter)
  }
}
