// M1 gate: the Swift Value must agree with the real Java Value.
//
// Cases come from tools/valuebridge/gen_golden.py, which drives the actual
// logisim-evolution jar once and writes `<input>\t<java result>` lines. Reading a
// file rather than spawning a JVM per assertion keeps this fast and keeps Java out
// of the test loop.
//
// The golden set lives outside the repo (it is 3.1 MB and regenerable):
//     LOGISIM_CORPUS=/path/to/corpus swift test
//
// Without LOGISIM_CORPUS the gate SKIPS with a printed reason, like every other
// corpus-dependent suite here. It does not fail: see the guard in the gate below.
//
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.

import Foundation
import Testing

@testable import LogisimKernel

// MARK: - harness

private struct Case {
    let line: String
    let expected: String
}

/// Ops that cannot be string-compared against Java for principled reasons.
/// Listed explicitly so they are visibly excluded rather than quietly passing.
private let numericOps: Set<String> = ["float", "double", "fp16", "fp8"]
/// These return a Java `float`. Comparing them as `Double` is wrong: Java prints
/// "1.4E-45" and Swift prints "1e-45" for the SAME Float (the least denormal), and
/// those two strings parse to different Doubles. Compare at Float precision.
private let floatOps: Set<String> = ["float", "fp16", "fp8"]
private let skippedOps: Set<String> = [
    // Java's Object.hashCode contract and Swift's Hasher are different algorithms
    // by design. Equal values must hash equally *within* a language; across
    // languages the numbers carry no meaning.
    "hash",
]

private func goldenPath() -> String? {
    guard let corpus = ProcessInfo.processInfo.environment["LOGISIM_CORPUS"] else { return nil }
    return (corpus as NSString).appendingPathComponent("golden_value.txt")
}

/// Java's Value.describe(): every observable property on one line.
private func describe(_ v: Value?) -> String {
    guard let v else { return "null" }
    return [
        String(v.getWidth()),
        v.toBinaryString(),
        v.toHexString(),
        v.toDecimalString(signed: false),
        v.toDecimalString(signed: true),
        String(v.toLongValue()),
        String(v.toSignExtendedLongValue()),
        String(v.isFullyDefined()),
        String(v.isUnknown()),
        String(v.isErrorValue()),
    ].joined(separator: " ")
}

/// Canonical construction, matching what ValueBridge does on the Java side.
///
/// Both sides MUST build values the same way. The Java bridge goes through
/// `create(Value[])` because Java's canonicalising `create(int,long,long,long)` is
/// private; that masks the value to the width. Using `createUnsafe` here instead
/// left Swift holding an unmasked value, so `toLongValue()` returned 99 for a
/// width-4 value and `set(99)` trapped on an index Java had already masked to 3;
/// a harness inconsistency that looked exactly like a port bug.
private func mk(_ w: Int, _ e: Int64, _ u: Int64, _ v: Int64) -> Value {
    Value.create(width: w, error: e, unknown: u, value: v)
}

/// `X`-kind cases deliberately probe `createUnsafe`, which validates and masks nothing.
private func mkUnsafe(_ w: Int, _ e: Int64, _ u: Int64, _ v: Int64) -> Value {
    Value.createUnsafe(width: w, error: e, unknown: u, value: v)
}

private func evalUnary(_ op: String, _ a: Value) throws -> String? {
    switch op {
    case "id": return describe(a)
    case "not": return describe(a.not())
    case "all": return a.getAll().map { describe($0) + " | " }.joined()
    case "binary": return a.toBinaryString()
    case "hex": return a.toHexString()
    case "dec": return a.toDecimalString(signed: true)
    case "decu": return a.toDecimalString(signed: false)
    case "long": return String(a.toLongValue())
    case "slong": return String(a.toSignExtendedLongValue())
    case "width": return String(a.getWidth())
    // getBitWidth() throws for a width outside 0...64, which createUnsafe can produce and
    // Java also throws on. Let it propagate so the gate compares throw-for-throw.
    case "bw": return try a.getBitWidth().description
    case "float": return String(a.toFloatValue())
    case "double": return String(a.toDoubleValue())
    case "fp16": return String(a.toFloatValueFromFP16())
    case "fp8": return String(a.toFloatValueFromFP8())
    default: return nil
    }
}

/// `W`-kind: BitWidth operations. Added after a width-63 `mask` crash slipped past 32,929
/// Value cases; `getMask` simply was not covered, so the gate could not have caught it.
private func evalBitWidth(_ op: String, _ w: Int) throws -> String? {
    let bw = try BitWidth.create(w)
    switch op {
    case "mask": return String(bw.mask)
    case "width": return String(bw.width)
    case "str": return bw.description
    default: return nil
    }
}

/// The line protocol is whitespace-separated, so `parse` inputs arrive escaped.
private func unescape(_ s: String) -> String {
    s.replacingOccurrences(of: "\\s", with: " ")
        .replacingOccurrences(of: "\\n", with: "\n")
        .replacingOccurrences(of: "\\t", with: "\t")
        .replacingOccurrences(of: "\\r", with: "\r")
        .replacingOccurrences(of: "\\e", with: "")
}

/// `P`-kind: Location. Java's `int` is 32-bit and wraps, `Integer.parseInt` is 32-bit and takes
/// any Unicode decimal digit, and `String.trim()` strips everything <= U+0020. All three were
/// wrong in the first port and none was reachable through the Value cases.
private func evalLocation(_ op: String, _ f: [String]) throws -> String? {
    func fld(_ i: Int) -> String? { i < f.count ? f[i] : nil }
    switch op {
    case "parse":
        guard let a = fld(2) else { return nil }
        return try Location.parse(unescape(a)).description
    case "create":
        guard f.count >= 5, let x = Int(f[2]), let y = Int(f[3]) else { return nil }
        return Location.create(x, y, hasToSnap: f[4] == "true").description
    case "translate":
        guard f.count >= 7, let x = Int(f[2]), let y = Int(f[3]),
              let dx = Int(f[5]), let dy = Int(f[6]) else { return nil }
        return Location.create(x, y, hasToSnap: f[4] == "true").translate(dx, dy).description
    case "manhattan":
        guard f.count >= 6, let x = Int(f[2]), let y = Int(f[3]),
              let tx = Int(f[4]), let ty = Int(f[5]) else { return nil }
        return String(Location.create(x, y, hasToSnap: false).manhattanDistance(toX: tx, y: ty))
    default: return nil
    }
}

/// `F`-kind: java.awt.Font.decode, which `.circ` `font=` attributes round-trip through.
private func evalFont(_ op: String, _ f: [String]) throws -> String? {
    guard op == "decode", f.count >= 3 else { return nil }
    let spec = AttributeTextFormat.decodeFont(unescape(f[2]))
    return "\(spec.family)|\(spec.style.rawValue)|\(spec.size)"
}

/// `D`-kind: Double text formats. Java's `Double.toString` widens a one-digit shortest
/// round-trip to two digits, and `Double.valueOf` requires a `p` exponent on hex literals.
private func evalDouble(_ op: String, _ f: [String]) throws -> String? {
    switch op {
    case "str":
        guard f.count >= 3, let bits = Int64(f[2]) else { return nil }
        return AttributeTextFormat.javaDoubleString(Double(bitPattern: UInt64(bitPattern: bits)))
    case "parse":
        guard f.count >= 3 else { return nil }
        let d = try AttributeTextFormat.parseDouble(unescape(f[2]))
        return AttributeTextFormat.javaDoubleString(d)
    default: return nil
    }
}

/// `R`-kind: Bounds.
private func evalBounds(_ op: String, _ f: [String]) throws -> String? {
    guard f.count >= 6, let x = Int(f[2]), let y = Int(f[3]),
          let w = Int(f[4]), let h = Int(f[5]) else { return nil }
    let a = Bounds.create(x, y, w, h)
    switch op {
    case "create": return a.description
    case "addpt":
        guard f.count >= 8, let px = Int(f[6]), let py = Int(f[7]) else { return nil }
        return a.add(px, py).description
    case "contains":
        guard f.count >= 8, let px = Int(f[6]), let py = Int(f[7]) else { return nil }
        return String(a.contains(px, py))
    case "add":
        guard f.count >= 10, let bx = Int(f[6]), let by = Int(f[7]),
              let bw = Int(f[8]), let bh = Int(f[9]) else { return nil }
        return a.add(Bounds.create(bx, by, bw, bh)).description
    default: return nil
    }
}

private func evalBinary(_ op: String, _ a: Value, _ b: Value) throws -> String? {
    switch op {
    case "and": return describe(a.and(b))
    case "or": return describe(a.or(b))
    case "xor": return describe(a.xor(b))
    case "combine": return describe(a.combine(b))
    case "controls": return describe(a.controls(b))
    case "compat": return String(a.compatible(b))
    case "equals": return String(a == b)
    case "extend": return describe(a.extendWidth(b.getWidth(), b.get(0)))
    case "get": return describe(a.get(Int(b.toLongValue())))
    case "set": return describe(try a.set(Int(b.toLongValue()), Value.trueValue))
    default: return nil
    }
}

/// Java and Swift print floats differently ("1.0E10" vs "1e+10"), so compare the
/// parsed numbers instead of the strings. NaN equals NaN here: both sides agreeing
/// that the result is not a number IS agreement.
private func numericallyEqual(_ lhs: String, _ rhs: String, asFloat: Bool) -> Bool {
    if lhs == rhs { return true }
    let a = lhs.replacingOccurrences(of: "E", with: "e")
    let b = rhs.replacingOccurrences(of: "E", with: "e")
    if asFloat {
        guard let l = Float(a), let r = Float(b) else { return false }
        if l.isNaN && r.isNaN { return true }
        return l == r
    }
    guard let l = Double(a), let r = Double(b) else { return false }
    if l.isNaN && r.isNaN { return true }
    return l == r
}

// MARK: - the gate

// An explicit skip, not a silent `return`: a gate that returns early still reports as a
// PASS, and the corpus is not published, so in a clean clone there is nothing to compare.
@Test("Swift Value matches the Java implementation across the golden set",
  .enabled(if: ProcessInfo.processInfo.environment["LOGISIM_CORPUS"] != nil,
    "needs LOGISIM_CORPUS: the corpus is coursework and is not in this repository"))
func valueMatchesJavaGoldenSet() throws {
    guard let path = goldenPath() else {
        // Skip, matching every other corpus-dependent suite in this project. This used to
        // record an Issue so a skipped gate could not be mistaken for a passing one, but
        // the effect was worse: a no-corpus `swift test` could NEVER be green, so a real
        // regression was indistinguishable from an unset environment variable, and twice
        // that cost real time. The printed reason is the loudness; the failure signal is
        // reserved for actual divergence.
        print("LOGISIM_CORPUS unset — Value golden gate skipped")
        return
    }
    guard FileManager.default.fileExists(atPath: path) else {
        Issue.record("""
            LOGISIM_CORPUS is set but \(path) is missing.
            Regenerate it with tools/valuebridge/gen_golden.py
            """)
        return
    }

    let text = try String(contentsOfFile: path, encoding: .utf8)
    var cases: [Case] = []
    for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
        let parts = raw.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { continue }
        cases.append(Case(line: String(parts[0]), expected: String(parts[1])))
    }
    #expect(cases.count > 1000, "golden set looks truncated: \(cases.count) cases")

    var checked = 0
    var skipped = 0
    let pendingD13 = 0
    var mismatches: [(String, String, String)] = []

    for c in cases {
        let f = c.line.split(separator: " ").map(String.init)
        // Arity varies by line kind: U/X take 6 fields, B takes 10, but W/F/D take 3 and P/R
        // vary by op. A blanket `f.count >= 6` here silently skipped every W, F and D case;
        // they sat in the golden file looking like coverage while never being evaluated, which
        // is how the width-63 mask fix appeared "gated" when it was not. Each branch validates
        // its own arity now.
        guard f.count >= 3 else { continue }
        let op = f[1]
        if skippedOps.contains(op) { skipped += 1; continue }

        // Since D13, Java's catchable exceptions map to Swift `throw`s, so a case where
        // Java threw is now directly verifiable: Swift must throw on the same input.
        let javaThrew = c.expected.hasPrefix("!")

        let got: String?
        if f[0] == "U" {
            guard f.count >= 6, let w = Int(f[2]), let e = Int64(f[3]), let u = Int64(f[4]), let v = Int64(f[5])
            else { continue }
            do { got = try evalUnary(op, mk(w, e, u, v)) }
            catch {
                checked += 1
                if !javaThrew { mismatches.append((c.line, c.expected, "threw \(error)")) }
                continue
            }
        } else if f[0] == "P" || f[0] == "R" || f[0] == "F" || f[0] == "D" {
            do {
                switch f[0] {
                case "P": got = try evalLocation(op, f)
                case "R": got = try evalBounds(op, f)
                case "F": got = try evalFont(op, f)
                default: got = try evalDouble(op, f)
                }
            } catch {
                checked += 1
                if !javaThrew { mismatches.append((c.line, c.expected, "threw \(error)")) }
                continue
            }
        } else if f[0] == "W" {
            guard f.count >= 3, let w = Int(f[2]) else { continue }
            do { got = try evalBitWidth(op, w) }
            catch {
                checked += 1
                if !javaThrew { mismatches.append((c.line, c.expected, "threw \(error)")) }
                continue
            }
        } else if f[0] == "X" {
            guard f.count >= 6, let w = Int(f[2]), let e = Int64(f[3]), let u = Int64(f[4]), let v = Int64(f[5])
            else { continue }
            // Java's createUnsafe accepts widths outside 0...64 and renders them
            // (width 100 gives a 100-digit binary string). Call in and compare rather
            // than assuming; a divergence here is worth knowing about explicitly.
            do { got = try evalUnary(op, mkUnsafe(w, e, u, v)) }
            catch {
                checked += 1
                if !javaThrew { mismatches.append((c.line, c.expected, "threw \(error)")) }
                continue
            }
        } else if f[0] == "B", f.count >= 10 {
            guard let w1 = Int(f[2]), let e1 = Int64(f[3]), let u1 = Int64(f[4]), let v1 = Int64(f[5]),
                  let w2 = Int(f[6]), let e2 = Int64(f[7]), let u2 = Int64(f[8]), let v2 = Int64(f[9])
            else { continue }
            do {
                got = try evalBinary(op, mk(w1, e1, u1, v1), mk(w2, e2, u2, v2))
            } catch {
                // Swift threw. Correct exactly when Java threw too.
                checked += 1
                if !javaThrew {
                    mismatches.append((c.line, c.expected, "threw \(error)"))
                }
                continue
            }
        } else {
            continue
        }

        guard let got else { skipped += 1; continue }
        checked += 1

        // Swift returned a value where Java threw, a real divergence.
        if javaThrew {
            mismatches.append((c.line, c.expected, got))
            continue
        }

        let ok = numericOps.contains(op)
            ? numericallyEqual(c.expected, got, asFloat: floatOps.contains(op))
            : (got == c.expected)
        if !ok && mismatches.count < 40 {
            mismatches.append((c.line, c.expected, got))
        } else if !ok {
            mismatches.append(("", "", ""))  // keep counting past the printed cap
        }
    }

    if !mismatches.isEmpty {
        let shown = mismatches.filter { !$0.0.isEmpty }
        var report = "\(mismatches.count) of \(checked) cases diverge from Java:\n"
        for (line, want, got) in shown.prefix(40) {
            report += "\n  \(line)\n     java:  \(want)\n     swift: \(got)\n"
        }
        if mismatches.count > shown.count {
            report += "\n  ... and \(mismatches.count - shown.count) more\n"
        }
        Issue.record(Comment(rawValue: report))
    }

    let skipList = skippedOps.sorted().joined(separator: ", ")
    let summary = "Value diverges from Java on \(mismatches.count)/\(checked) cases (\(skipped) skipped: \(skipList))"
    #expect(mismatches.isEmpty, Comment(rawValue: summary))

    // Reported separately so it cannot hide inside a green run. These are cases where
    // Java throws catchably and the port traps; see decisions.md D13 and task #9.
    if pendingD13 > 0 {
        Issue.record(Comment(rawValue: """
            \(pendingD13) case(s) not verified: Java throws a catchable exception where the \
            Swift port currently traps. Not counted as passing. See decisions.md D13.
            """))
    }
}
