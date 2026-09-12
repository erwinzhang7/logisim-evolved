// Regression: BitWidth.mask must wrap at width 63, as Java's `(1L << 63) - 1` does.
// Five independent reviewers found this; the 32,929-case Value gate did not, because
// getMask() was not one of the bridge's operations. Covered here and in the bridge.

import Testing

@testable import LogisimKernel

@Test("BitWidth.mask matches Java at every width, including the width-63 overflow")
func bitWidthMaskMatchesJavaAtEveryWidth() throws {
  // Values taken from the Java: `(w == 64) ? -1L : ((1L << w) - 1)`.
  #expect(BitWidth.known(0).mask == 0)
  #expect(BitWidth.known(1).mask == 1)
  #expect(BitWidth.known(62).mask == 0x3FFF_FFFF_FFFF_FFFF)
  #expect(BitWidth.known(63).mask == 0x7FFF_FFFF_FFFF_FFFF)  // Long.MAX_VALUE; used to trap
  #expect(BitWidth.known(64).mask == -1)

  // Every width in range must produce exactly (2^w - 1) with wraparound, and must not trap.
  for w in 0...64 {
    let expected: Int64 = w == 64 ? -1 : (Int64(1) &<< Int64(w)) &- 1
    #expect(BitWidth.known(w).mask == expected, "width \(w)")
  }
}
