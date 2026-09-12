// Ttl74182.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.ttl.Ttl74182),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// TTL 74x182: look-ahead carry generator. Model based on
// https://www.ti.com/lit/ds/symlink/sn54s182.pdf (74LS182 datasheet).
//
// **Deviation (mechanism).** See `Ttl74194.swift`'s header: `state` is threaded as an explicit
// parameter rather than stashed in a shared mutable factory field.
//
import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

public final class Ttl74182: AbstractTtlGate {

  /// `Ttl74182._ID`. "Unique identifier of the tool, used as reference in project files. Do NOT
  /// change as it will prevent project files from loading.", upstream's own comment.
  public static let id = "74182"

  private static let delay = 1

  // IC pin indices as specified in the datasheet.
  private static let nG0 = 3
  private static let nG1 = 1
  private static let nG2 = 14
  private static let nG3 = 5
  private static let nP0 = 4
  private static let nP1 = 2
  private static let nP2 = 15
  private static let nP3 = 6
  private static let cn = 13
  private static let nP = 7
  private static let nG = 10
  private static let cnx = 12
  private static let cny = 11
  private static let cnz = 9
  private static let gnd = 8

  public init() {
    super.init(
      Ttl74182.id,
      pins: 16,
      outputPorts: [Ttl74182.nP, Ttl74182.nG, Ttl74182.cnx, Ttl74182.cny, Ttl74182.cnz],
      portNames: [
        "G1", "P1", "G0", "P0", "G3", "P3", "P",
        "Cnz", "G", "Cny", "Cnx", "Cn", "G2", "P2",
      ])
  }

  /// IC pin indices are datasheet based (1-indexed), but ports are 0-indexed with GND/VCC
  /// omitted: the port-index contract every chip in this family shares
  /// (`AbstractTtlGate.swift`'s header).
  private func pinNrToPortNr(_ dsPinNr: Int) -> Int {
    dsPinNr <= Ttl74182.gnd ? dsPinNr - 1 : dsPinNr - 2
  }

  private func getPort(_ state: any InstanceState, _ dsPinNr: Int) -> Bool {
    state.portValue(pinNrToPortNr(dsPinNr)) == .trueValue
  }

  private func setPort(_ state: any InstanceState, _ dsPinNr: Int, _ b: Bool) {
    state.setPort(pinNrToPortNr(dsPinNr), b ? .trueValue : .falseValue, Ttl74182.delay)
  }

  public override func propagateTtl(_ state: any InstanceState) throws {
    let p = [
      !getPort(state, Ttl74182.nP0), !getPort(state, Ttl74182.nP1),
      !getPort(state, Ttl74182.nP2), !getPort(state, Ttl74182.nP3),
    ]  // Active low
    let g = [
      !getPort(state, Ttl74182.nG0), !getPort(state, Ttl74182.nG1),
      !getPort(state, Ttl74182.nG2), !getPort(state, Ttl74182.nG3),
    ]  // Active low
    let ci = getPort(state, Ttl74182.cn)

    let po = p[3] && p[2] && p[1] && p[0]
    let go = g[3] || (p[3] && g[2]) || (p[3] && p[2] && g[1]) || (p[3] && p[2] && p[1] && g[0])
    let cx = g[0] || (p[0] && ci)
    let cy = g[1] || (p[1] && g[0]) || (p[1] && p[0] && ci)
    let cz =
      g[2] || (p[2] && g[1]) || (p[2] && p[1] && g[0]) || (p[2] && p[1] && p[0] && ci)

    setPort(state, Ttl74182.nP, !po)  // Active low
    setPort(state, Ttl74182.nG, !go)  // Active low
    setPort(state, Ttl74182.cnx, cx)
    setPort(state, Ttl74182.cny, cy)
    setPort(state, Ttl74182.cnz, cz)
  }

  public override func paintInternal(
    _ painter: SceneBuilder, _ state: any TtlPainter, x: Int, y: Int, height: Int, up: Bool
  ) {
    let names = Drawgates.shortenPortNames(portNames ?? [])
    paintBase(painter, state, drawName: true, ghost: false)
    Drawgates.paintPortNames(painter, x: x, y: y, height: height, portNames: names)
  }
}
