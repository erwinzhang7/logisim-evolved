// MinimizationExhaustiveTests: part of logisim-evolved.
//
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// `docs/objectives.md` records an open hazard: Java's `HashMap`/`HashSet` iteration order
// reaches into `Implicant.computeMinimal`'s final cover selection, and the experiment that
// closed the question for the simulator (`docs/experiments/hashorder.md`) covered the
// simulator only. `MinimizationGoldenData.swift` has 616 cases and, on a tie, deliberately
// asserts only cardinality and cost, so it cannot answer "does the port ever pick a
// different cover than the jar?", it can only fail to notice.
//
// This test answers it by exhaustion instead of by sampling: all 65,536 four-variable
// Boolean functions, in both sum-of-products and product-of-sums form, 131,072 cases.
//
// Regenerate the input with the existing MinProbe:
//
//     python3 -c 'print("\n".join(f"4 {bin(v)[2:].zfill(16)[::-1]}"+s for v in range(1<<16)
//                                 for s in ("", " pos")))' > min4.txt
//     JAR=/Applications/Logisim-evolution.app/Contents/app/logisim-evolution-4.1.0-all.jar
//     javac -cp "$JAR" -d /tmp/anaprobe tools/analyze/MinProbe.java
//     java -Djava.awt.headless=true -Xmx4g -cp "$JAR:/tmp/anaprobe" \
//         com.cburch.logisim.analyze.model.MinProbe < min4.txt > min4.out
//     LOGISIM_MIN_EXHAUSTIVE=$PWD/min4.out swift test --filter minimisation
//
// The 4.5 MB output is not committed; it is derivable in six seconds and the repo already
// keeps generated oracles out (the same rule as the corpus). Without the variable the test
// skips, exactly as the corpus-backed tests do.
//
// ============================================================================
// RESULT; the hazard is REAL. Measured 2026-09-05, all 131,072 cases:
//
//   exact (same implicants, same order)      123,770   94.4%
//   differs from the jar's choice              7,302    5.6%
//       ... same set, different ORDER          2,188
//       ... genuinely different cover          5,114
//       ... split by format          3,651 sop / 3,651 pos
//
//   wrong cardinality                              0
//   wrong cost (upstream's own cost function)      0
//   cover does not reproduce its table             0
//
// Read those two blocks together. The port is never *worse*: every cover it returns is
// minimum-cardinality, minimum-cost by `costMap`'s own measure, and correct against the
// table. But on one function in eighteen it returns a DIFFERENT equally-optimal answer than
// the shipped jar, and the user sees that; a different set of product terms, or the same
// terms in a different order, which is a different expression on screen and a different
// circuit out of "build circuit".
//
// This is not a bug to fix by patching a comparator. Both programs are choosing arbitrarily
// among equally good optima; upstream's arbitrary choice is `cheapestCovers.get(0)` out of a
// list built by iterating a `HashSet<Implicant>` whose `hashCode()` is `(unknowns << 16) |
// values` (`Implicant.java:467`), so its answer is a deterministic function of `java.util`'s
// bucket layout. The port sorts instead, which is deterministic too; just differently
// arbitrary. Matching the jar exactly would mean reimplementing `HashMap`'s hash spreading,
// table sizing and resize order, i.e. encoding a JDK implementation detail as port behaviour,
// for no gain in answer quality.
//
// So: recorded, quantified, and pinned. `docs/objectives.md` lists cover selection as an open
// hazard; this closes the *question* (yes, order matters, here is how much) without closing
// the *divergence*. It also corrects an over-optimistic reading of
// `docs/experiments/hashorder.md`, whose finding was about the simulator and does not
// transfer to the analyzer.
//
// n=4 is exhaustive. n=5 and n=6 are far too large to exhaust and remain sampled by
// `MinimizationGoldenData.swift`, where the same 5.6% should be expected.
// ============================================================================

import Foundation
import Testing

@testable import LogisimAnalyze

@Test func minimisationMatchesTheJavaOracleExhaustivelyAtFourInputs() throws {
  guard let path = ProcessInfo.processInfo.environment["LOGISIM_MIN_EXHAUSTIVE"],
    let text = try? String(contentsOfFile: path, encoding: .utf8)
  else {
    // Not an Issue.record: the oracle file is generated, not committed, and a developer
    // without it should see a green suite rather than a red one they cannot fix.
    return
  }

  var exact = 0
  var tie = 0
  var reorderedOnly = 0
  var differentSet = 0
  var tieSop = 0
  var tiePos = 0
  var badCardinality = 0
  var badCost = 0
  var incorrect = 0
  var checked = 0

  for line in text.split(separator: "\n") {
    guard let c = MinimizationCase(line: String(line)) else { continue }
    checked += 1
    let model = try makeModel(inputs: c.inputs, spec: c.spec)
    let implicants = Implicant.computeMinimal(
      format: c.format, model: model, variable: "q", report: MinimizationReport())

    if implicants.count != c.expectedCount {
      badCardinality += 1
      if badCardinality < 5 { Issue.record("cover size for \(c.line)") }
      continue
    }
    let actualKeys = implicants.map { "\($0.values)/\($0.unknowns)" }
    let expectedKeys = c.expectedImplicants.map { "\($0.values)/\($0.unknowns)" }
    if actualKeys == expectedKeys {
      exact += 1
      continue
    }
    tie += 1
    if c.format == AnalyzerModel.formatSumOfProducts { tieSop += 1 } else { tiePos += 1 }
    if actualKeys.sorted() == expectedKeys.sorted() {
      reorderedOnly += 1
    } else {
      differentSet += 1
    }
    // Every alternative the port picks must still be a correct cover of the table, or it is
    // not a tie at all; it is a bug that happens to have the right cardinality.
    if !coverIsCorrect(implicants, spec: c.spec, inputs: c.inputs, format: c.format) {
      incorrect += 1
      if incorrect < 5 { Issue.record("cover does not reproduce the table for \(c.line)") }
    }
    // A different choice is only acceptable if it is equally good by upstream's own cost
    // function; the summed unknown count that `costMap` is keyed on.
    let actualCost = implicants.reduce(0) { $0 + $1.unknowns.nonzeroBitCount }
    if actualCost != c.expectedCost {
      badCost += 1
      if badCost < 5 { Issue.record("cover cost for \(c.line)") }
    }
  }

  print(
    """
    exhaustive n=4: checked=\(checked) exact=\(exact) tie=\(tie) \
    (sop \(tieSop) / pos \(tiePos), reorderedOnly \(reorderedOnly), \
    differentSet \(differentSet)) badCardinality=\(badCardinality) \
    badCost=\(badCost) incorrect=\(incorrect)
    """)

  #expect(checked == 131_072, "expected the whole four-variable space, got \(checked)")

  // These four are the correctness assertions, and they must stay at zero. Every cover the
  // port returns is minimum-cardinality, minimum-cost by upstream's own cost function, and
  // reproduces the table it came from.
  #expect(badCardinality == 0)
  #expect(badCost == 0)
  #expect(incorrect == 0)

  // These four are the *pinned measurement* of the divergence, not a target. They are here so
  // that any change to the port's tie-breaking shows up as a failing test with a number in it
  // rather than as a silent shift in what users see. If you change the traversal order in
  // `Implicant.computeMinimal`, re-run and update these: and update the note at the top.
  #expect(exact == 123_770)
  #expect(tie == 7_302)
  #expect(reorderedOnly == 2_188)
  #expect(differentSet == 5_114)
  #expect(tieSop == 3_651)
  #expect(tiePos == 3_651)
}
