// RomPortGeometryTests.swift: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// THE ROM DATA-OUT PORT IS 10 UNITS TO THE RIGHT OF WHERE UPSTREAM PUTS IT
//
// Task #47. One defect, thirteen corpus oracles.
//
// `Rom` is the ONLY memory factory that overrides `getOffsetBounds` (`Rom.java:166-173`); it
// returns `SymbolWidth + 40` in **both** appearance branches and never consults `xoffset`.
// `RamAppearance.getBounds` (`RamAppearance.java:199-208`) computes
// `xoffset = seperatedBus(attrs) ? 40 : 50` and uses it in the evolution branch.
// `RomAttributes.getValue(ATTR_DBUS)` returns `null` (`RomAttributes.java:106-134`), so
// `seperatedBus` is false for every ROM and the shared function yields 250 where `Rom`'s own
// override yields 240.
//
// Upstream never notices, because `RamAppearance.configurePorts` takes the data-out x from
// **`instance.getBounds().getWidth()`** (`RamAppearance.java:183`): the *factory's* bounds, i.e.
// the override. The port's `RamAppearance.ports(_:)` had no instance and reached for
// `RamAppearance.offsetBounds(attrs).width` instead, which for a ROM is the wrong function.
//
// WHY THIS IS A SIMULATION BUG AND NOT A DRAWING ONE. A port 10 units off the wire is not
// connected to anything. The ROM drives no net, and every reader downstream sees `U`, which,
// from a truth table alone, is indistinguishable from a propagation defect. It is invisible to
// every existing gate: `tools/difftest/BoundsOracle.java` compares `getOffsetBounds` and nothing
// else, and `Rom.offsetBounds` was transcribed *correctly*. Nothing in this project had ever
// compared port geometry against upstream.
//
// It also explains why only some ROMs fail. In the CLASSIC branch `Rom.getOffsetBounds` gives
// `SymbolWidth + 40 = 240` and `RamAppearance.getBounds` gives `SymbolWidth + 40 = 240` too
// (the classic branch hardcodes `+ 40` and ignores `xoffset`: upstream's own dead variable).
// The two agree, so classic ROMs were never affected.
//
// ── Measured, whole corpus, release CLI, `rig.py --max-fail 2000 --jobs 6 --timeout 90` ──────
//
//   before  pass 1329 · fail 63  · of 1392
//   after   pass 1342 · fail 50  · of 1392
//
// Exactly **13 fixed, 0 regressed**. All 13 were inside a set computed independently of the
// diagnosis, the circuits that reach an evolution-appearance ROM transitively, derived from the
// XML alone, and **no case outside that set changed state**, which is what makes this one cause
// rather than a coincidence of thirteen. Timeouts were 1 before and 1 after, so nothing was
// bought by a case simply running longer.
//
// Five circuits in that set still fail, and none of them can pass a byte comparison for an
// unrelated reason: each carries a label `VhdlContent.labelVHDLInvalid` rejects, so
// `XmlReader.buildValidLabels` rewrites it through `generateValidVHDLLabel`, which appends a
// fresh `UUID.randomUUID()` prefix on every run; the jar does not reproduce itself there.
//
// ── The expectations below are literal jar output, not arithmetic ───────────────────────────
//
// Produced by `tools/valuebridge/RomBridge.java` against the shipped 4.1.0 jar on
// a corpus file that is Pin x2 and
// ROM x1 and nothing else:
//
//   ROM logisim_evolution loc=(170,150) bounds=170,150,240x540 ends=[(170,160)Iw8 (410,210)Ow24]
//   RAM logisim_evolution loc=(360,170) bounds=360,170,240x250
//                              ends=[(360,180)Iw8 (600,260)Ow8 (360,260)Iw8 ...]
//
// The ROM's ends are at offsets (0,10) and (240,60). That file's wires run to (170,160) and
// (410,210), so 240 is the coordinate that has to be hit, and 250 is a dead output.
//
// Regenerate with:
//   javac -cp <logisim-fat.jar> -d /tmp/rombridge tools/valuebridge/RomBridge.java
//   java -Djava.awt.headless=true -cp <logisim-fat.jar>:/tmp/rombridge RomBridge <file.circ>
// It exits 3 if it emitted nothing, so a silent no-op cannot be mistaken for agreement.
//
// The RAM row is asserted alongside the ROM one deliberately: it is the control. RAM's data-out
// is also at x=240 here, but for the OTHER reason (`Ram.getOffsetBounds` just returns
// `RamAppearance.getBounds`, and this RAM's bus is separated so `xoffset` is 40). If a future
// change fixes ROM by hardcoding 240 somewhere shared, this row moves and the suite says so.
// ═════════════════════════════════════════════════════════════════════════════════════════════

import Foundation
import LogisimFile
import LogisimKernel
import Testing

@testable import LogisimStd

@Suite("ROM port geometry vs the 4.1.0 jar")
struct RomPortGeometryTests {

  /// The ROM placement measured in a corpus file: `dataWidth=24`,
  /// `appearance=logisim_evolution`, everything else defaulted.
  private func reproducerRomAttributes() throws -> any AttributeSet {
    let rom = Rom()
    let attrs = rom.createAttributeSet()
    try attrs.setValue(StdAttr.appearance, StdAttr.appearEvolution)
    try attrs.setValue(Mem.data, BitWidth.known(24))
    return attrs
  }

  /// The whole defect in one assertion: where does the data-out port sit?
  ///
  /// Before the fix this read 250: `RamAppearance.offsetBounds(attrs).width`, which is
  /// `symbolWidth + 50` because `RomAttributes` carries no `dataBus` attribute and
  /// `separatedBus` is therefore false.
  @Test("evolution ROM data-out is at x=240, the factory's own offset bounds")
  func evolutionRomDataOutX() throws {
    let rom = Rom()
    let attrs = try reproducerRomAttributes()

    // The factory's own override; this was always right, which is why no bounds gate caught it.
    #expect(rom.offsetBounds(attrs).width == 240)

    let ports = rom.ports(attrs)
    #expect(ports.count == 2, "jar: ends=[(170,160)Iw8 (410,210)Ow24] — two ends")

    let addrPort = ports[RamAppearance.addrPortIndex(0, attrs)]
    #expect(addrPort.dx == 0 && addrPort.dy == 10, "jar: (170,160) from loc (170,150)")

    let dataOut = ports[RamAppearance.dataOutPortIndex(0, attrs)]
    #expect(
      dataOut.dx == 240,
      """
      jar puts the ROM data-out at (410,210) from loc (170,150), i.e. dx=240. \
      dx=250 is RamAppearance.offsetBounds(attrs).width, which is the wrong function for a ROM \
      (Rom overrides getOffsetBounds; RomAttributes has no dataBus). At 250 the port misses the \
      file's wire at (410,210) entirely, the ROM drives nothing, and every downstream reader \
      emits U.
      """)
    #expect(dataOut.dy == 60, "jar: (410,210) from loc (170,150)")
  }

  /// The port must agree with the factory's bounds *by construction*, not by coincidence: for
  /// every data width, and in both appearance branches. This is the invariant
  /// `configurePorts(instance.getBounds().getWidth())` enforces upstream for free.
  @Test("data-out x tracks the factory's offsetBounds width for every ROM configuration")
  func dataOutTracksFactoryBounds() throws {
    let rom = Rom()
    for appearance in [StdAttr.appearClassic, StdAttr.appearEvolution] {
      for width in [1, 4, 8, 16, 24, 32] {
        let attrs = rom.createAttributeSet()
        try attrs.setValue(StdAttr.appearance, appearance)
        try attrs.setValue(Mem.data, BitWidth.known(width))

        let expected = rom.offsetBounds(attrs).width
        #expect(
          expected == 240,
          "Rom.getOffsetBounds is SymbolWidth + 40 in BOTH branches (Rom.java:166-173)")

        let ports = rom.ports(attrs)
        for i in 0..<RamAppearance.dataOutPortCount(attrs) {
          let port = ports[RamAppearance.dataOutPortIndex(i, attrs)]
          #expect(
            port.dx == Int(expected),
            "appearance=\(appearance) width=\(width) dataOut[\(i)].dx")
        }
      }
    }
  }

  /// The control. `Ram` does NOT override `getOffsetBounds` (`Ram.java:175-177`), so routing it
  /// through the same two-argument call must not move a single port.
  @Test("RAM port geometry is unchanged — it does not override offsetBounds")
  func ramGeometryUnmoved() throws {
    let ram = Ram()
    for appearance in [StdAttr.appearClassic, StdAttr.appearEvolution] {
      for width in [1, 8, 32] {
        let attrs = ram.createAttributeSet()
        try attrs.setValue(StdAttr.appearance, appearance)
        try attrs.setValue(Mem.data, BitWidth.known(width))

        let expected = ram.offsetBounds(attrs).width
        #expect(expected == RamAppearance.offsetBounds(attrs).width)

        let ports = ram.ports(attrs)
        for i in 0..<RamAppearance.dataOutPortCount(attrs) {
          #expect(ports[RamAppearance.dataOutPortIndex(i, attrs)].dx == Int(expected))
        }
      }
    }
  }
}
