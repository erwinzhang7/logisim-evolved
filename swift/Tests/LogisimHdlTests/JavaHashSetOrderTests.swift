// JavaHashSetOrderTests.swift: part of logisim-evolved.
//
// Pins `JavaHashSet` against values taken from a real JVM (OpenJDK 21.0.11, the same runtime the
// difftest rig uses). Every expected value in this file was *printed by Java*, not derived by
// reading the HashMap source; the whole point of the emulation is that reading the source and
// believing it is exactly how this goes wrong.
//
// The probe program, for regeneration:
//
//     record P(int x, int y) { public int hashCode() { return 31 * x + y; } }
//     LinkedHashSet<P> ins = new LinkedHashSet<>(); // fixes insertion order
//     for (int[] p : pts) ins.add(new P(p[0], p[1]));
//     HashSet<P> hs = new HashSet<>(); hs.addAll(ins); // what Netlist.wires does
//     for (P p : hs) System.out.print(p.x() + "," + p.y() + ";");
//
// `P.hashCode()` is `Location.hashCode()` verbatim (`Location.java:25`), so the ordering below
// is the ordering a `HashSet<Location>` really has.
//
// This suite needs no corpus and no jar: it is the part of the netlist gate that still runs in
// a bare checkout.
//
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.

import LogisimHdl
import LogisimKernel
import Testing

@Suite("JavaHashSet — JVM iteration order")
struct JavaHashSetOrderTests {

  /// The 20 points fed to the JVM, in insertion order.
  static let points: [(x: Int, y: Int)] = [
    (0, 0), (10, 0), (20, 0), (0, 10), (10, 10), (20, 10), (30, 30), (100, 200), (-10, -10),
    (40, 50), (70, 20), (90, 90), (110, 10), (130, 70), (150, 150), (170, 30), (190, 110),
    (210, 10), (230, 90), (250, 170),
  ]

  /// Printed by the JVM. Note it is neither insertion order nor sorted order, which is the
  /// reason this file exists.
  static let jvmOrder =
    "0,0;10,10;30,30;90,90;150,150;100,200;130,70;0,10;40,50;20,0;70,20;190,110;250,170;"
    + "170,30;230,90;10,0;20,10;210,10;110,10;-10,-10;"

  @Test("iteration order matches a real java.util.HashSet")
  func orderMatchesJvm() {
    let ordered = JavaHashSet.order(Self.points) { 31 &* $0.x &+ $0.y }
    let rendered = ordered.map { "\($0.x),\($0.y);" }.joined()
    #expect(rendered == Self.jvmOrder)
  }

  @Test("spread() matches HashMap.hash(), including the unsigned shift")
  func spreadMatchesJvm() {
    // Printed by the JVM. `-1` is the case that catches an arithmetic (signed) shift: Java's
    // `>>>` gives 0xFFFF, so -1 ^ 0xFFFF == -65536, whereas `>>` would give -1 ^ -1 == 0.
    #expect(JavaHashSet.spread(31 * 350 + 180) == 11030)
    #expect(JavaHashSet.spread(-1) == -65536)
    #expect(JavaHashSet.spread(65536) == 65537)
  }

  @Test("capacity follows HashMap's 16 / 0.75 growth")
  func capacityGrowth() {
    #expect(JavaHashSet.capacity(forCount: 0) == 16)
    #expect(JavaHashSet.capacity(forCount: 12) == 16)
    #expect(JavaHashSet.capacity(forCount: 13) == 32)
    #expect(JavaHashSet.capacity(forCount: 24) == 32)
    #expect(JavaHashSet.capacity(forCount: 25) == 64)
    #expect(JavaHashSet.capacity(forCount: 48) == 64)
    #expect(JavaHashSet.capacity(forCount: 49) == 128)
  }

  @Test("the 20-point probe stays below the treeify threshold")
  func probeIsExact() {
    // If this ever fails the expected order above is no longer a valid pin, because HashMap
    // would have converted a bucket to a red-black tree and reordered it.
    #expect(!JavaHashSet.wouldTreeify(Self.points) { 31 &* $0.x &+ $0.y })
  }

  @Test("a one-element or empty input is returned unchanged")
  func degenerateInputs() {
    #expect(JavaHashSet.order([Int]()) { $0 }.isEmpty)
    #expect(JavaHashSet.order([42]) { $0 } == [42])
  }
}
