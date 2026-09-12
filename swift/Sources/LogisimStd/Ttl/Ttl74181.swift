// Ttl74181.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.ttl.Ttl74181),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// TTL 74x181: arithmetic logic unit. Model based on
// https://www.ti.com/lit/ds/symlink/sn54s181.pdf (74LS181 datasheet).
//
// Transcribed verbatim from upstream's PAL-network model: two layers of `pal32L1`, a
// "PAL32L1" device, a programmable-array-logic AND/NOR network with up to 32 inputs per
// product term, reproducing the datasheet's logic diagram term-for-term rather than computing
// the arithmetic/logic result directly. `Ttl74381.swift` duplicates the same `pal32L1` helper
// rather than sharing it, exactly as upstream's two classes each declare their own private copy.
//
// **Deviation (mechanism).** See `Ttl74194.swift`'s header: `state` is threaded as an explicit
// parameter rather than stashed in a shared mutable factory field.
//
import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

public final class Ttl74181: AbstractTtlGate {

  /// `Ttl74181._ID`. "Unique identifier of the tool, used as reference in project files. Do NOT
  /// change as it will prevent project files from loading.", upstream's own comment.
  public static let id = "74181"

  private static let delay = 1

  // IC pin indices as specified in the datasheet.
  private static let a0 = 2
  private static let a1 = 23
  private static let a2 = 21
  private static let a3 = 19
  private static let b0 = 1
  private static let b1 = 22
  private static let b2 = 20
  private static let b3 = 18
  private static let f0 = 9
  private static let f1 = 10
  private static let f2 = 11
  private static let f3 = 13
  private static let s0 = 6
  private static let s1 = 5
  private static let s2 = 4
  private static let s3 = 3
  private static let ci = 7
  private static let m = 8
  private static let aEqB = 14
  private static let co = 16
  private static let p = 15
  private static let g = 17
  private static let gnd = 12

  public init() {
    super.init(
      Ttl74181.id,
      pins: 24,
      outputPorts: [
        Ttl74181.f0, Ttl74181.f1, Ttl74181.f2, Ttl74181.f3, Ttl74181.co, Ttl74181.aEqB,
        Ttl74181.p, Ttl74181.g,
      ],
      portNames: [
        "B0", "A0", "S3", "S2", "S1", "S0", "nCi", "M", "F0", "F1", "F2",
        "F3", "A=B", "Pn", "Co", "Gn", "B3", "A3", "B2", "A2", "B1", "A1",
      ])
  }

  /// IC pin indices are datasheet based (1-indexed), but ports are 0-indexed with GND/VCC
  /// omitted: the port-index contract every chip in this family shares
  /// (`AbstractTtlGate.swift`'s header).
  private func pinNrToPortNr(_ dsPinNr: Int) -> Int {
    dsPinNr <= Ttl74181.gnd ? dsPinNr - 1 : dsPinNr - 2
  }

  private func getPort(_ state: any InstanceState, _ dsPinNr: Int) -> Bool {
    state.portValue(pinNrToPortNr(dsPinNr)) == .trueValue
  }

  private func setPort(_ state: any InstanceState, _ dsPinNr: Int, _ b: Bool) {
    state.setPort(pinNrToPortNr(dsPinNr), b ? .trueValue : .falseValue, Ttl74181.delay)
  }

  /// `pal32L1(ArrayList<Boolean>, int[])`. Implements a "PAL32L1" device: a programmable
  /// array logic device with a virtually unlimited sum of products, up to 32 inputs per
  /// product. `products`: if bit `n` of a product is 1, input `n` is part of that product.
  /// Returns the active-low sum of products.
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
      getPort(state, Ttl74181.a0), getPort(state, Ttl74181.a1), getPort(state, Ttl74181.a2),
      getPort(state, Ttl74181.a3),
    ]
    let b = [
      getPort(state, Ttl74181.b0), getPort(state, Ttl74181.b1), getPort(state, Ttl74181.b2),
      getPort(state, Ttl74181.b3),
    ]
    let bn = b.map { !$0 }
    let s = [
      getPort(state, Ttl74181.s0), getPort(state, Ttl74181.s1), getPort(state, Ttl74181.s2),
      getPort(state, Ttl74181.s3),
    ]
    let ci = getPort(state, Ttl74181.ci)
    let m = getPort(state, Ttl74181.m)

    // The logic diagram in the datasheet shows two layers of AND/NOR networks.
    //
    // The first layer is connected to A, B and S and produces two outputs.
    // The second layer is connected to the outputs of the first layer plus M and Ci
    // and also has a small bit of additional logic (some XOR gates etc.).
    //
    // Output 1 of the first layer, formed by a 2-AND/1-NOR network, is called x.
    // Output 2 of the first layer, formed by a 3-AND/1-NOR network, is called y.
    //
    // The output of second layer, formed by an n-AND/1-NOR network, is called z.

    // Level 1 PAL
    //
    //   15   14   13   12    11    10    9     8    7    6    5    4    3    2    1    0    input number.
    // +----+----+----+----+-----+-----+-----+-----+----+----+----+----+----+----+----+----+
    // | S3 | S2 | S1 | S0 | /B3 | /B2 | /B1 | /B0 | B3 | B2 | B1 | B0 | A3 | A2 | A1 | A0 |
    // +----+----+----+----+-----+-----+-----+-----+----+----+----+----+----+----+----+----+
    let level1 = a + b + bn + s

    let x = [
      pal32L1(level1, [0x0000_8011, 0x0000_4101]),
      pal32L1(level1, [0x0000_8022, 0x0000_4202]),
      pal32L1(level1, [0x0000_8044, 0x0000_4404]),
      pal32L1(level1, [0x0000_8088, 0x0000_4808]),
    ]

    let y = [
      pal32L1(level1, [0x0000_2100, 0x0000_1010, 0x0000_0001]),
      pal32L1(level1, [0x0000_2200, 0x0000_1020, 0x0000_0002]),
      pal32L1(level1, [0x0000_2400, 0x0000_1040, 0x0000_0004]),
      pal32L1(level1, [0x0000_2800, 0x0000_1080, 0x0000_0008]),
    ]

    // Level 2 PAL
    //
    //   9    8    7    6    5    4    3    2    1    0    input number
    // +----+----+----+----+----+----+----+----+----+----+
    // | Ci | /M | Y3 | Y2 | Y1 | Y0 | X3 | X2 | X1 | X0 |
    // +----+----+----+----+----+----+----+----+----+----+
    let level2 = x + y + [!m, ci]

    let z = [
      pal32L1(level2, [0x0000_0300]),
      pal32L1(level2, [0x0000_0301, 0x0000_0110]),
      pal32L1(level2, [0x0000_0303, 0x0000_0112, 0x0000_0120]),
      pal32L1(level2, [0x0000_0307, 0x0000_0116, 0x0000_0124, 0x0000_0140]),
    ]

    // Determine outputs
    let p = pal32L1(level2, [0x0000_000f])
    let g = pal32L1(level2, [0x0000_0080, 0x0000_0048, 0x0000_002c, 0x0000_001e])
    let co = !pal32L1(level2, [0x0000_020f]) || !g

    let eq = a[0] == b[0] && a[1] == b[1] && a[2] == b[2] && a[3] == b[3]

    // Java's boolean `^` is logical XOR; Swift's `!=` on `Bool` is the same operation, but
    // comparison operators are non-associative, so each pair needs its own parentheses.
    let f0 = (x[0] != y[0]) != z[0]
    let f1 = (x[1] != y[1]) != z[1]
    let f2 = (x[2] != y[2]) != z[2]
    let f3 = (x[3] != y[3]) != z[3]

    // Set outputs
    setPort(state, Ttl74181.p, p)
    setPort(state, Ttl74181.g, g)
    setPort(state, Ttl74181.co, co)
    setPort(state, Ttl74181.aEqB, eq)

    setPort(state, Ttl74181.f3, f3)
    setPort(state, Ttl74181.f2, f2)
    setPort(state, Ttl74181.f1, f1)
    setPort(state, Ttl74181.f0, f0)
  }

  public override func paintInternal(
    _ painter: SceneBuilder, _ state: any TtlPainter, x: Int, y: Int, height: Int, up: Bool
  ) {
    let names = Drawgates.shortenPortNames(portNames ?? [])
    paintBase(painter, state, drawName: true, ghost: false)
    Drawgates.paintPortNames(painter, x: x, y: y, height: height, portNames: names)
  }
}
