// D15: `Int128` holds anything `toBigInteger` can return, but NOT what Multiplier, Divider and
// Exponentiator then compute with it. An earlier comment claimed "a 64x64 product still fits";
// this pins the fact that it does not, and that `magnitudeUInt64` + `multipliedFullWidth` is the
// path that works, so the claim cannot quietly come back.
//
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.

import Testing

@testable import LogisimKernel

@Test("a full-width product overflows Int128, and magnitudeUInt64 handles it exactly")
func fullWidthProductNeedsMoreThanInt128() throws {
  let allOnes = Value.createKnown(try BitWidth.create(64), -1)

  // toBigInteger is correct for its own result: 2^64 - 1 unsigned.
  #expect(allOnes.toBigInteger(unsigned: true) == Int128(UInt64.max))
  #expect(allOnes.magnitudeUInt64 == UInt64.max)

  // Multiplier.java:72 does aa.multiply(bb). Int128 cannot hold it.
  let a = allOnes.toBigInteger(unsigned: true)
  let (_, overflow) = a.multipliedReportingOverflow(by: a)
  #expect(overflow, "if this stops overflowing, Int128 grew and D15 can be revisited")

  // The supported path: an exact 128-bit product in two 64-bit halves.
  // (2^64 - 1)^2 == 2^128 - 2^65 + 1, so high = 2^64 - 2 and low = 1.
  let (high, low) = allOnes.magnitudeUInt64.multipliedFullWidth(by: allOnes.magnitudeUInt64)
  #expect(high == UInt64.max - 1)
  #expect(low == 1)

  // Divider.java:68 shifts left by 64 with bit 63 set, which also needs 128 unsigned bits.
  let upper = Value.createKnown(try BitWidth.create(64), Int64.min)  // bit 63 set
  #expect(upper.magnitudeUInt64 == UInt64(1) << 63)
}

@Test("magnitudeUInt64 masks to the declared width")
func magnitudeMasksToWidth() throws {
  #expect(Value.createKnown(try BitWidth.create(8), -1).magnitudeUInt64 == 0xFF)
  #expect(Value.createKnown(try BitWidth.create(1), -1).magnitudeUInt64 == 1)
  #expect(Value.createKnown(try BitWidth.create(63), -1).magnitudeUInt64 == 0x7FFF_FFFF_FFFF_FFFF)
  #expect(Value.createKnown(try BitWidth.create(64), -1).magnitudeUInt64 == UInt64.max)
}
