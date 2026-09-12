// Ttl74381.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.ttl.Ttl74381),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// TTL 74x381: arithmetic logic unit. Model based on
// http://bitsavers.org/components/ti/_dataBooks/1976_TI_The_TTL_Data_Book_2ed/07.pdf, pp
// 7-484 to 7-486 (74LS381 datasheet).
//
// Same PAL-network transcription approach as `Ttl74181.swift`; see that file's header for why
// `pal32L1` is duplicated here rather than shared (upstream duplicates it too).
//
// **Deviation (mechanism).** See `Ttl74194.swift`'s header: `state` is threaded as an explicit
// parameter rather than stashed in a shared mutable factory field.
//
import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

public final class Ttl74381: AbstractTtlGate {

  /// `Ttl74381._ID`. "Unique identifier of the tool, used as reference in project files. Do NOT
  /// change as it will prevent project files from loading.", upstream's own comment.
  public static let id = "74381"

  private static let delay = 1

  // IC pin indices as specified in the datasheet.
  private static let a0 = 3
  private static let a1 = 1
  private static let a2 = 19
  private static let a3 = 17
  private static let b0 = 4
  private static let b1 = 2
  private static let b2 = 18
  private static let b3 = 16
  private static let f0 = 8
  private static let f1 = 9
  private static let f2 = 11
  private static let f3 = 12
  private static let s0 = 5
  private static let s1 = 6
  private static let s2 = 7
  private static let ci = 15
  private static let p = 14
  private static let g = 13
  private static let gnd = 10

  public init() {
    super.init(
      Ttl74381.id,
      pins: 20,
      outputPorts: [Ttl74381.f0, Ttl74381.f1, Ttl74381.f2, Ttl74381.f3, Ttl74381.p, Ttl74381.g],
      portNames: [
        "A1", "B1", "A0", "B0", "S0", "S1", "S2", "F0", "F1",
        "F2", "F3", "Gn", "Pn", "Ci", "B3", "A3", "B2", "A2",
      ])
  }

  /// IC pin indices are datasheet based (1-indexed), but ports are 0-indexed with GND/VCC
  /// omitted: the port-index contract every chip in this family shares
  /// (`AbstractTtlGate.swift`'s header).
  private func pinNrToPortNr(_ dsPinNr: Int) -> Int {
    dsPinNr <= Ttl74381.gnd ? dsPinNr - 1 : dsPinNr - 2
  }

  private func getPort(_ state: any InstanceState, _ dsPinNr: Int) -> Bool {
    state.portValue(pinNrToPortNr(dsPinNr)) == .trueValue
  }

  private func setPort(_ state: any InstanceState, _ dsPinNr: Int, _ b: Bool) {
    state.setPort(pinNrToPortNr(dsPinNr), b ? .trueValue : .falseValue, Ttl74381.delay)
  }

  /// `pal32L1(ArrayList<Boolean>, int[])`: see `Ttl74181.swift`'s copy of the same helper for
  /// the full explanation; transcribed identically.
  private func pal32L1(_ inputs: [Bool], _ products: [Int]) -> Bool {
    var or = false
    for product in products {
      if or { break }
      var and = true
      for j in 0..<32 {
        if !and { break }
        if product & (1 << j) != 0 {
          and = inputs[j]
        }
      }
      or = and
    }
    return !or  // Active low
  }

  public override func propagateTtl(_ state: any InstanceState) throws {
    let a = [
      getPort(state, Ttl74381.a0), getPort(state, Ttl74381.a1), getPort(state, Ttl74381.a2),
      getPort(state, Ttl74381.a3),
    ]
    let an = a.map { !$0 }
    let b = [
      getPort(state, Ttl74381.b0), getPort(state, Ttl74381.b1), getPort(state, Ttl74381.b2),
      getPort(state, Ttl74381.b3),
    ]
    let bn = b.map { !$0 }
    let s = [
      getPort(state, Ttl74381.s0), getPort(state, Ttl74381.s1), getPort(state, Ttl74381.s2),
    ]
    let ci = getPort(state, Ttl74381.ci)

    // The logic diagram in the datasheet shows two layers of AND/NOR networks
    // plus some combinatorial functions based on S.
    //
    // The combinatorial network which processes S produces six outputs, which
    // are named U, V, W, X, Y and Z (left to right).
    //
    // The first AND/NOR layer is connected to A, B, U, V, W, X and Y.
    // The second AND/NOR layer is connected to the outputs of the first layer
    // plus Z and Ci, and also has a few XOR gates.
    //
    // Output 1 of the first layer, formed by a 3-AND/1-NOR network, is called J.
    // Output 2 of the first layer, formed by a 4-AND/1-NOR network, is called K.
    //
    // The output of second layer, formed by an n-AND/1-NOR network, is called L.

    let u = s[0] || s[1]
    let v = s[1] || s[2]
    let w = s[0] || !s[1]
    let x = !(s[0] && s[1]) || s[2]
    let y = (s[0] && s[1]) || !s[2]
    let z = !s[2] && u

    // Level 1 PAL
    //
    // +---+---------------+-----------------------+-------------------+-----------------------+-------------------+
    // | 20| 19  18  17  16|  15    14    13    12 | 11   10   9    8  |  7     6     5     4  | 3    2    1    0  |
    // +---+---+---+---+---+-----+-----+-----+-----+----+----+----+----+-----+-----+-----+-----+----+----+----+----+
    // | U | V | W | X | Y | /B3 | /B2 | /B1 | /B0 | B3 | B2 | B1 | B0 | /A3 | /A2 | /A1 | /A0 | A3 | A2 | A1 | A0 |
    // +---+---+---+---+---+-----+-----+-----+-----+----+----+----+----+-----+-----+-----+-----+----+----+----+----+
    let level1 = a + an + b + bn + [y, x, w, v, u]

    let j = [
      pal32L1(level1, [0x000c_1010, 0x0016_1001, 0x000a_0110]),
      pal32L1(level1, [0x000c_2020, 0x0016_2002, 0x000a_0220]),
      pal32L1(level1, [0x000c_4040, 0x0016_4004, 0x000a_0440]),
      pal32L1(level1, [0x000c_8080, 0x0016_8008, 0x000a_0880]),
    ]

    let k = [
      pal32L1(level1, [0x0013_1010, 0x000c_1001, 0x000c_0110, 0x0012_0101]),
      pal32L1(level1, [0x0013_2020, 0x000c_2002, 0x000c_0220, 0x0012_0202]),
      pal32L1(level1, [0x0013_4040, 0x000c_4004, 0x000c_0440, 0x0012_0404]),
      pal32L1(level1, [0x0013_8080, 0x000c_8008, 0x000c_0880, 0x0012_0808]),
    ]

    // Level 2 PAL
    //
    // +--------+-------------------+-------------------+
    // | 9    8 | 7    6    5    4  | 3    2    1    0  |
    // +----+---+----+----+----+----+----+----+----+----+
    // | Ci | Z | K3 | K2 | K1 | K0 | J3 | J2 | J1 | J0 |
    // +----+---+----+----+----+----+----+----+----+----+
    let level2 = j + k + [z, ci]

    let l = [
      pal32L1(level2, [0x0000_0300]),
      pal32L1(level2, [0x0000_0301, 0x0000_0111]),
      pal32L1(level2, [0x0000_0303, 0x0000_0113, 0x0000_0122]),
      pal32L1(level2, [0x0000_0307, 0x0000_0117, 0x0000_0126, 0x0000_0144]),
    ]

    // Determine outputs
    let p = pal32L1(level2, [0x0000_000f])
    let g = pal32L1(level2, [0x0000_0088, 0x0000_004c, 0x0000_002e, 0x0000_001f])

    let f0 = l[0] != k[0]
    let f1 = l[1] != k[1]
    let f2 = l[2] != k[2]
    let f3 = l[3] != k[3]

    // Set outputs
    setPort(state, Ttl74381.p, p)
    setPort(state, Ttl74381.g, g)

    setPort(state, Ttl74381.f3, f3)
    setPort(state, Ttl74381.f2, f2)
    setPort(state, Ttl74381.f1, f1)
    setPort(state, Ttl74381.f0, f0)
  }

  public override func paintInternal(
    _ painter: SceneBuilder, _ state: any TtlPainter, x: Int, y: Int, height: Int, up: Bool
  ) {
    let names = Drawgates.shortenPortNames(portNames ?? [])
    paintBase(painter, state, drawName: true, ghost: false)
    Drawgates.paintPortNames(painter, x: x, y: y, height: height, portNames: names)
  }
}
