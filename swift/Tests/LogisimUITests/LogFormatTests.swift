// LogFormatTests: part of logisim-evolved.
//
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// Two formats that leave the app and are therefore contracts, not conveniences:
// `RadixOption.toString(Value)`, which labels every waveform, and `Model.formatDuration(long)`,
// which appears in the `# duration` comment on every row of an exported log.
//
// `decimalMaxLengthsMatchUpstreamTable` transcribes upstream's 65-arm switch verbatim and checks
// the arithmetic replacement against it, so the shortcut taken in LogRadix.swift cannot drift.

import LogisimKernel
import Testing

@testable import LogisimUI

@Suite("Log formatting — RadixOption and Model.formatDuration")
struct LogFormatTests {

  @Test("Radix save strings and decode round-trip, and an unknown radix falls back to binary")
  func radixDecode() {
    for radix in LogRadix.allCases {
      #expect(LogRadix.decode(radix.saveString) == radix)
    }
    #expect(LogRadix.decode("hexadecimal") == .binary)
    #expect(LogRadix.decode("") == .binary)
  }

  @Test("Each radix formats through the kernel's own Value renderer")
  func radixFormats() {
    let v = Value.createKnown(BitWidth.known(8), 0xA5)
    #expect(LogRadix.binary.format(v) == v.toDisplayString(radix: 2))
    #expect(LogRadix.octal.format(v) == v.toDisplayString(radix: 8))
    #expect(LogRadix.hexadecimal.format(v) == v.toDisplayString(radix: 16))
    #expect(LogRadix.decimalSigned.format(v) == v.toDecimalString(signed: true))
    #expect(LogRadix.decimalUnsigned.format(v) == v.toDecimalString(signed: false))
    #expect(LogRadix.float.format(v) == v.toStringFromFloatValue())
  }

  @Test("Binary maxLength inserts a separator every four bits, as Radix2 does")
  func binaryMaxLength() {
    // Java: `(bits <= 1) ? 1 : bits + ((bits - 1) / 4)`.
    #expect(LogRadix.binary.maxLength(BitWidth.known(1)) == 1)
    #expect(LogRadix.binary.maxLength(BitWidth.known(4)) == 4)
    #expect(LogRadix.binary.maxLength(BitWidth.known(5)) == 6)
    #expect(LogRadix.binary.maxLength(BitWidth.known(8)) == 9)
  }

  @Test("Octal, hex and float maxLength match upstream's formulas")
  func otherMaxLengths() {
    #expect(LogRadix.octal.maxLength(BitWidth.known(1)) == 1)
    #expect(LogRadix.octal.maxLength(BitWidth.known(9)) == 3)
    #expect(LogRadix.hexadecimal.maxLength(BitWidth.known(1)) == 1)
    #expect(LogRadix.hexadecimal.maxLength(BitWidth.known(16)) == 4)
    #expect(LogRadix.float.maxLength(BitWidth.known(32)) == 12)
    #expect(LogRadix.float.maxLength(BitWidth.known(64)) == 24)
  }

  @Test("Decimal maxLength matches upstream's transcribed 64-entry table exactly")
  func decimalMaxLengthsMatchUpstreamTable() {
    // RadixOption.Radix10Unsigned.getMaxLength, transcribed from 4.1.0. Index = bit width.
    var unsigned = [Int](repeating: 0, count: 65)
    for w in 0...3 { unsigned[w] = 1 }
    for w in 4...6 { unsigned[w] = 2 }
    for w in 7...9 { unsigned[w] = 3 }
    for w in 10...13 { unsigned[w] = 4 }
    for w in 14...16 { unsigned[w] = 5 }
    for w in 17...19 { unsigned[w] = 6 }
    for w in 20...23 { unsigned[w] = 7 }
    for w in 24...26 { unsigned[w] = 8 }
    for w in 27...29 { unsigned[w] = 9 }
    for w in 30...33 { unsigned[w] = 10 }
    for w in 34...36 { unsigned[w] = 11 }
    for w in 37...39 { unsigned[w] = 12 }
    for w in 40...43 { unsigned[w] = 13 }
    for w in 44...46 { unsigned[w] = 14 }
    for w in 47...49 { unsigned[w] = 15 }
    for w in 50...53 { unsigned[w] = 16 }
    for w in 54...56 { unsigned[w] = 17 }
    for w in 57...59 { unsigned[w] = 18 }
    for w in 60...63 { unsigned[w] = 19 }
    unsigned[64] = 20

    // RadixOption.Radix10Signed.getMaxLength.
    var signed = [Int](repeating: 0, count: 65)
    signed[0] = 1
    for w in 1...4 { signed[w] = 2 }
    for w in 5...7 { signed[w] = 3 }
    for w in 8...10 { signed[w] = 4 }
    for w in 11...14 { signed[w] = 5 }
    for w in 15...17 { signed[w] = 6 }
    for w in 18...20 { signed[w] = 7 }
    for w in 21...24 { signed[w] = 8 }
    for w in 25...27 { signed[w] = 9 }
    for w in 28...30 { signed[w] = 10 }
    for w in 31...34 { signed[w] = 11 }
    for w in 35...37 { signed[w] = 12 }
    for w in 38...40 { signed[w] = 13 }
    for w in 41...44 { signed[w] = 14 }
    for w in 45...47 { signed[w] = 15 }
    for w in 48...50 { signed[w] = 16 }
    for w in 51...54 { signed[w] = 17 }
    for w in 55...57 { signed[w] = 18 }
    for w in 58...60 { signed[w] = 19 }
    for w in 61...64 { signed[w] = 20 }

    for w in 0...64 {
      let bits = BitWidth.known(w)
      #expect(
        LogRadix.decimalUnsigned.maxLength(bits) == unsigned[w],
        "unsigned width \(w)")
      #expect(
        LogRadix.decimalSigned.maxLength(bits) == signed[w],
        "signed width \(w)")
    }
  }

  // MARK: formatDuration

  @Test("formatDuration reproduces Model.formatDuration's four branches")
  func durationBranches() {
    let mu = LogDurationFormat.microSign

    // t < 1000 -> nanoseconds.
    #expect(LogDurationFormat.string(for: 0) == "0 ns")
    #expect(LogDurationFormat.string(for: 999) == "999 ns")
    // (t % 100) != 0 keeps it in nanoseconds however large.
    #expect(LogDurationFormat.string(for: 1001) == "1001 ns")
    #expect(LogDurationFormat.string(for: 123_456) == "123456 ns")

    // t >= 1000 and a multiple of 100 -> microseconds.
    #expect(LogDurationFormat.string(for: 1000) == "1.0 \(mu)s")
    #expect(LogDurationFormat.string(for: 5000) == "5.0 \(mu)s")
    #expect(LogDurationFormat.string(for: 123_400) == "123.4 \(mu)s")

    // t >= 1_000_000 and a multiple of 100_000 -> milliseconds.
    #expect(LogDurationFormat.string(for: 1_000_000) == "1.0 ms")
    #expect(LogDurationFormat.string(for: 2_500_000) == "2.5 ms")
    // ...but a multiple of 100 that is NOT a multiple of 100_000 stays in microseconds, which
    // is exactly what upstream's `t < 1000000 || (t % 100000) != 0` says.
    #expect(LogDurationFormat.string(for: 1_000_100) == "1000.1 \(mu)s")

    // t >= 100_000_000 and a multiple of 100_000_000 -> seconds.
    #expect(LogDurationFormat.string(for: 100_000_000) == "0.1 s")
    #expect(LogDurationFormat.string(for: 1_000_000_000) == "1.0 s")
    // Not a multiple of 100_000_000 stays in milliseconds.
    #expect(LogDurationFormat.string(for: 150_000_000) == "150.0 ms")
  }

  @Test("The microsecond unit is U+00B5 MICRO SIGN, not Greek mu")
  func microSignIsMicroSign() {
    // gui.properties: `usFormat = %s µs`. A marking script matching on the byte sequence
    // would break if this became U+03BC.
    #expect(LogDurationFormat.microSign.unicodeScalars.first?.value == 0x00B5)
  }

  @Test("Every value reaching a fractional branch is an exact tenth, so rounding never bites")
  func fractionalBranchesAreExact() {
    // Worth pinning because it is the reason Java's HALF_UP vs C's half-to-even difference is
    // invisible here: each branch's guard already forces the quotient onto a tenth. The µs
    // branch needs `t % 100 == 0`, so `t / 1000.0` has one decimal; likewise `% 100_000` for
    // ms and `% 100_000_000` for s. `javaOneDecimal` is therefore defensive, not load-bearing.
    var probes = Array(stride(from: Int64(1000), through: 2_000_000, by: 100))
    probes += [100_000_000, 150_000_000, 999_900_000, 1_000_000_000, 12_300_000_000]
    for t in probes {
      let s = LogDurationFormat.string(for: t)
      guard let unit = s.split(separator: " ").last, unit != "ns" else { continue }
      let digits = s.split(separator: " ")[0]
      #expect(digits.split(separator: ".").count == 2, "\(t) -> \(s)")
      #expect(digits.split(separator: ".")[1].count == 1, "\(t) -> \(s)")
      // The printed number must reconstruct the input exactly.
      let scale: Double =
        unit == LogDurationFormat.microSign + "s"
        ? 1000 : (unit == "ms" ? 1_000_000 : 1_000_000_000)
      let reconstructed = (Double(digits) ?? -1) * scale
      #expect(Int64(reconstructed.rounded()) == t, "\(t) -> \(s)")
    }
  }
}
