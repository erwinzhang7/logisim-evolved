// Ttl74670.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.ttl.Ttl74670),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// TTL 74x670: 4-by-4 register file with three-state outputs. Model based on
// https://www.ti.com/lit/ds/symlink/sn74ls670.pdf (74LS670 datasheet).
//
// One `TtlClockState` clock index per write address; `isTriggered` calls `updateClock(which:
// getWriteAddress())`, so each of the four words tracks its own last-write-enable edge
// independently, exactly as upstream's per-address `ClockState.updateClock(Value, int, Object)`
// does. This is the other file (besides `Ttl7474`) that needs `TtlClockState`'s indexed form.
//
// **Deviation (mechanism).** See `Ttl74194.swift`'s header: `state` and the register data are
// threaded as explicit parameters rather than stashed in shared mutable factory fields
// (`_state`/`_data`).

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

public final class Ttl74670: AbstractTtlGate {

  /// `Ttl74670._ID`. "Unique identifier of the tool, used as reference in project files. Do NOT
  /// change as it will prevent project files from loading.", upstream's own comment.
  public static let id = "74670"

  private static let delay = 1

  // IC pin indices as specified in the datasheet.
  private static let d1 = 15
  private static let d2 = 1
  private static let d3 = 2
  private static let d4 = 3
  private static let wa0 = 14
  private static let wa1 = 13
  private static let ra0 = 5
  private static let ra1 = 4
  private static let nWe = 12
  private static let nOe = 11
  private static let q1 = 10
  private static let q2 = 9
  private static let q3 = 7
  private static let q4 = 6
  private static let gnd = 8

  private static let dataOutputs = [q1, q2, q3, q4]

  public init() {
    super.init(
      Ttl74670.id,
      pins: 16,
      outputPorts: Ttl74670.dataOutputs,
      portNames: [
        "D2", "D3", "D4", "RA1", "RA0", "Q4", "Q3",
        "Q2", "Q1", "nOE", "nWE", "WA1", "WA0", "D1",
      ])
  }

  /// IC pin indices are datasheet based (1-indexed), but ports are 0-indexed with GND/VCC
  /// omitted: the port-index contract every chip in this family shares
  /// (`AbstractTtlGate.swift`'s header).
  private func pinNrToPortNr(_ dsPinNr: Int) -> Int {
    dsPinNr <= Ttl74670.gnd ? dsPinNr - 1 : dsPinNr - 2
  }

  private func getPort(_ state: any InstanceState, _ dsPinNr: Int) -> Value {
    state.portValue(pinNrToPortNr(dsPinNr))
  }

  private func setPort(_ state: any InstanceState, _ dsPinNr: Int, _ v: Value) {
    state.setPort(pinNrToPortNr(dsPinNr), v, Ttl74670.delay)
  }

  private func getData(_ state: any InstanceState) -> TtlRegisterData {
    if let existing = state.data as? TtlRegisterData {
      return existing
    }
    let data = TtlRegisterData(width: BitWidth.known(4), depth: 4)
    state.setData(data)
    return data
  }

  private func getAddress(_ state: any InstanceState, msbPinNr: Int, lsbPinNr: Int) -> Int {
    (getPort(state, msbPinNr) == .trueValue ? 2 : 0)
      + (getPort(state, lsbPinNr) == .trueValue ? 1 : 0)
  }

  private func getReadAddress(_ state: any InstanceState) -> Int {
    getAddress(state, msbPinNr: Ttl74670.ra1, lsbPinNr: Ttl74670.ra0)
  }

  private func getWriteAddress(_ state: any InstanceState) -> Int {
    getAddress(state, msbPinNr: Ttl74670.wa1, lsbPinNr: Ttl74670.wa0)
  }

  private func isTriggered(_ state: any InstanceState, _ data: TtlRegisterData) throws -> Bool {
    try data.clock.updateClock(
      getPort(state, Ttl74670.nWe), which: getWriteAddress(state), trigger: StdAttr.triggerLow)
  }

  private func propagateWritePort(_ state: any InstanceState, _ data: TtlRegisterData) throws {
    // Upstream wraps this write in a `for (i = 0; i < 4; i++)` loop whose body does not read
    // `i`; four identical writes to the same address, which is observably the same as one.
    // Not reproduced; see the file header on mechanism-only deviations.
    if try isTriggered(state, data) {
      let word = try Value.create([
        getPort(state, Ttl74670.d1), getPort(state, Ttl74670.d2), getPort(state, Ttl74670.d3),
        getPort(state, Ttl74670.d4),
      ])
      data.setValue(getWriteAddress(state), word)
    }
  }

  private func propagateReadPort(_ state: any InstanceState, _ data: TtlRegisterData) {
    let readEnabled = getPort(state, Ttl74670.nOe) == .falseValue  // nOE is active low
    let readData = data.getValue(getReadAddress(state))

    for i in 0..<4 {
      setPort(state, Ttl74670.dataOutputs[i], readEnabled ? readData.get(i) : .unknownValue)
    }
  }

  public override func propagateTtl(_ state: any InstanceState) throws {
    let data = getData(state)
    // Must write before read in order to simulate the internal latches.
    try propagateWritePort(state, data)
    propagateReadPort(state, data)
  }

  // PAINT (M6): this file had no comment marking it, unlike its siblings; the internal
  // drawing is nonetheless the same one-liner as `Ttl7485`/`Ttl7447`/etc. See
  // Ttl74670.java:76-80.
  public override func paintInternal(
    _ painter: SceneBuilder, _ state: any TtlPainter, x: Int, y: Int, height: Int, up: Bool
  ) {
    paintBase(painter, state, drawName: true, ghost: false)
    Drawgates.paintPortNames(painter, x: x, y: y, height: height, portNames: portNames ?? [])
  }
}
