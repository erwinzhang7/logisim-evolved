// Divider: the signed `Int64.min / -1` case, which Java defines and Swift traps on.
//
// ⚠️ THE FIRST TEST BELOW ENDS THE TEST PROCESS (SIGTRAP: "Division results in an overflow").
//    That crash IS the finding. Run it on its own:
//
//        swift test --filter DividerSignedOverflowTests
//
// ── What this is ────────────────────────────────────────────────────────────────────────────
//
// `Divider.computeResult` guards the *zero* divisor (`bb == 0 ? 1 : bb`, three times) but not the
// other total-vs-partial difference in integer division. JLS 15.17.2 makes `ldiv` TOTAL:
//
//     "if the dividend is the negative integer of largest possible magnitude and the divisor is
//      -1, then integer overflow occurs and the result is equal to the dividend"
//
// so `Long.MIN_VALUE / -1L == Long.MIN_VALUE` and `Long.MIN_VALUE % -1L == 0`, no exception.
// Swift's `/` and `%` are PARTIAL at exactly that point and trap.
//
// The dividend is not a value anyone types; it is ASSEMBLED by the component from two ports:
//
//     num = (upper.toSignExtendedLongValue() << w) | a.toLongValue()
//
// With `w == 32` and `UPPER == 0x8000_0000`, the sign-extension makes `upper == -2^31` and the
// shift makes `num == -2^63 == Int64.min` exactly. `IN1 == 0xFFFF_FFFF` sign-extends to `-1`.
// So three ordinary constants on an ordinary 32-bit Divider in signed mode reach it.
//
// ── Measured against the shipped 4.1.0 jar ──────────────────────────────────────────────────
//
// Probe compiled INTO `com.cburch.logisim.std.arith` (computeResult is package-private) and run
// against /Applications/Logisim-evolution.app/Contents/app/logisim-evolution-4.1.0-all.jar
// (sha256 66863191e9c5e0235c8de4a0c9d00328948253cc7db91036548a818ccbf6a41c):
//
//   [A] width 32, signed, UPPER=0x80000000, IN0=0, IN1=0xFFFFFFFF -> quotient 0, remainder 0
//   [B] width 64, signed, UPPER=0x8000000000000000, IN0=0, IN1=-1 -> quotient 0, remainder 0
//
// Both answer 0/0 rather than crashing: the `ldiv` wraps to `Long.MIN_VALUE`, and
// `Value.createKnown(BitWidth(32), Long.MIN_VALUE)` then keeps only the low 32 bits, which are 0.
// Bytecode confirms the shape; `javap -c com.cburch.logisim.std.arith.Divider` shows the signed
// branch at offsets 149-160 as a bare `ldiv`/`lrem` pair (the unsigned branch at 132/141 calls
// `Long.divideUnsigned`/`remainderUnsigned`, which is why only the SIGNED mode is affected).
//
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.

import Foundation
import LogisimKernel
import Testing

@testable import LogisimStd

@Suite("Divider signed-overflow parity")
struct DividerSignedOverflowTests {

  /// A 32-bit signed Divider fed UPPER=0x80000000, IN0=0, IN1=0xFFFFFFFF must answer 0/0,
  /// as the 4.1.0 jar does. The port traps instead.
  @Test("width 32, signed, UPPER=0x80000000 / -1 -> 0 rem 0 (jar 4.1.0)")
  func widthThirtyTwoSignedMinDividedByNegativeOne() throws {
    let width = BitWidth.known(32)
    let a = Value.createKnown(width, 0)
    let b = Value.createKnown(width, 0xFFFF_FFFF)  // sign-extends to -1
    let upper = Value.createKnown(width, 0x8000_0000)  // sign-extends to -2^31

    // num = (-2^31 << 32) | 0 == Int64.min ; den == -1  -> Swift traps here.
    let out = try Divider.computeResult(width, a, b, upper, unsigned: false)

    #expect(out.quotient == Value.createKnown(width, 0))
    #expect(out.remainder == Value.createKnown(width, 0))
  }

  /// The same shape at width 64, where the port uses `Int128` and the jar uses `BigInteger`.
  /// `Int128.min / -1` is the identical partial-vs-total difference one width up.
  @Test("width 64, signed, UPPER=0x8000000000000000 / -1 -> 0 rem 0 (jar 4.1.0)")
  func widthSixtyFourSignedMinDividedByNegativeOne() throws {
    let width = BitWidth.known(64)
    let a = Value.createKnown(width, 0)
    let b = Value.createKnown(width, -1)
    let upper = Value.createKnown(width, Int64.min)

    let out = try Divider.computeResult(width, a, b, upper, unsigned: false)

    #expect(out.quotient == Value.createKnown(width, 0))
    #expect(out.remainder == Value.createKnown(width, 0))
  }

  /// Control: ordinary division is unaffected, so the two tests above are isolating the
  /// overflow case and not a broken harness. 100 / 7 == 14 rem 2 in the jar (probe case [C]).
  @Test("control: width 32 signed 100 / 7 -> 14 rem 2")
  func ordinaryDivisionStillAgrees() throws {
    let width = BitWidth.known(32)
    let out = try Divider.computeResult(
      width, Value.createKnown(width, 100), Value.createKnown(width, 7),
      Value.createKnown(width, 0), unsigned: false)

    #expect(out.quotient == Value.createKnown(width, 14))
    #expect(out.remainder == Value.createKnown(width, 2))
  }
}
