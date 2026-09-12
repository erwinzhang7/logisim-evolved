// MinimizationGoldenTests: part of logisim-evolved.
//
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// Runs the 616 golden cases in MinimizationGoldenData.swift against the Swift minimiser, and
// adds the two properties a golden file cannot express: that each cover is *correct*
// (checked against the truth table it came from) and *minimum* (checked against an
// independent brute-force search), and that it is *reproducible*.
//
// On ties, the golden file cannot be an exact oracle and it would be dishonest to pretend
// otherwise. Upstream picks among equally cheap covers by `HashSet` iteration order,
// `cheapestCovers.get(0)` in Petrick's method, and the order essential primes are discovered
// in, which the JLS leaves unspecified. So the assertions are:
//
//   * cover CARDINALITY must match exactly, on all 616 cases (this is the real answer);
//   * the cover itself must match exactly, OR be a genuine tie: same cardinality and the same
//     total unknown count, which is upstream's own cost function (`costMap` keyed on the
//     summed `getUnknownCount`). A cover that is worse by either measure is a bug and fails;
//   * expression *construction* is tested separately and exactly, by feeding Java's own
//     implicant list, in Java's own order, through the Swift `toExpression` and comparing
//     the rendered string. That isolates toProduct/toSum/rendering from cover selection, and
//     it has to match on all 616.

import Foundation
import Testing

@testable import LogisimAnalyze

// MARK: - Harness

struct MinimizationCase {
  let line: String
  let inputs: Int
  let spec: [Character]
  let format: Int
  let expectedCount: Int
  /// `(values, unknowns)` in the order Java returned them.
  let expectedImplicants: [(values: Int, unknowns: Int)]
  let expectedExpression: String

  init?(line: String) {
    self.line = line
    let halves = line.components(separatedBy: " | ")
    guard halves.count == 2 else { return nil }
    let lhs = halves[0].split(separator: " ").map(String.init)
    guard lhs.count >= 2, let n = Int(lhs[0]) else { return nil }
    inputs = n
    spec = Array(lhs[1])
    format =
      lhs.count > 2 && lhs[2] == "pos"
      ? AnalyzerModel.formatProductOfSums : AnalyzerModel.formatSumOfProducts
    let rhs = halves[1]
    guard let braceOpen = rhs.firstIndex(of: "{"), let braceClose = rhs.firstIndex(of: "}") else {
      return nil
    }
    expectedCount = Int(rhs[rhs.startIndex..<braceOpen].trimmingCharacters(in: .whitespaces)) ?? -1
    let inner = String(rhs[rhs.index(after: braceOpen)..<braceClose])
    expectedImplicants = inner.isEmpty
      ? []
      : inner.components(separatedBy: ",").map {
        let p = $0.components(separatedBy: "/")
        return (values: Int(p[0]) ?? 0, unknowns: Int(p[1]) ?? 0)
      }
    expectedExpression = String(rhs[rhs.index(braceClose, offsetBy: 2)...])
  }

  var expectedKeys: [String] { expectedImplicants.map { "\($0.values)/\($0.unknowns)" }.sorted() }
  var expectedCost: Int { expectedImplicants.reduce(0) { $0 + $1.unknowns.nonzeroBitCount } }
}

/// Builds the model the Java probe built: `n` one-bit inputs named a…e, one output `q`.
func makeModel(inputs n: Int, spec: [Character]) throws -> AnalyzerModel {
  let model = AnalyzerModel()
  // Same naming rule as the Java probe: a…e, then v5, v6, … for the wide cases.
  let alphabet = ["a", "b", "c", "d", "e"]
  let names = (0..<n).map { $0 < alphabet.count ? alphabet[$0] : "v\($0)" }
  try model.setVariables(inputs: names.map { Var($0, 1) }, outputs: [Var("q", 1)])
  var column = [Entry](repeating: .dontCare, count: 1 << n)
  for i in 0..<(1 << n) {
    column[i] = spec[i] == "1" ? .one : (spec[i] == "0" ? .zero : .dontCare)
  }
  try model.truthTable.setOutputColumn(0, column)
  return model
}

func implicantKeys(_ implicants: [Implicant]) -> [String] {
  implicants.map { "\($0.values)/\($0.unknowns)" }.sorted()
}

/// Does this cover reproduce the truth table on every row that is not a don't-care?
/// Sum-of-products: the minterm cover must hit every 1 and miss every 0. Product-of-sums:
/// the maxterm cover must hit every 0 and miss every 1.
func coverIsCorrect(_ implicants: [Implicant], spec: [Character], inputs n: Int, format: Int)
  -> Bool
{
  for row in 0..<(1 << n) where spec[row] != "x" {
    var covered = false
    for imp in implicants where (row & ~imp.unknowns) == (imp.values & ~imp.unknowns) {
      covered = true
      break
    }
    let shouldCover = (format == AnalyzerModel.formatSumOfProducts) == (spec[row] == "1")
    if covered != shouldCover { return false }
  }
  return true
}

func goldenCases() -> [MinimizationCase] {
  MinimizationGolden.cases.split(separator: "\n").compactMap { MinimizationCase(line: String($0)) }
}

// MARK: - The differential comparison

@Test func minimisationMatchesTheJavaOracle() throws {
  let cases = goldenCases()
  #expect(cases.count == 616)
  var exact = 0
  var ties = 0
  for c in cases {
    let model = try makeModel(inputs: c.inputs, spec: c.spec)
    // A report sink is what lifts the 6-input guard; the Java probe passed a JTextArea for
    // exactly the same reason, so the two paths stay identical.
    let implicants = Implicant.computeMinimal(
      format: c.format, model: model, variable: "q", report: MinimizationReport())

    #expect(implicants.count == c.expectedCount, "cover size for \(c.line)")
    if implicantKeys(implicants) == c.expectedKeys {
      exact += 1
    } else {
      ties += 1
      let cost = implicants.reduce(0) { $0 + $1.unknownCount }
      let detail =
        "cover differs from Java by more than a tie-break for \(c.line): got "
        + "\(implicantKeys(implicants)) cost \(cost)"
      #expect(implicants.count == c.expectedCount && cost == c.expectedCost, "\(detail)")
      #expect(
        coverIsCorrect(implicants, spec: c.spec, inputs: c.inputs, format: c.format),
        "tie-broken cover is not equivalent to its table for \(c.line)")
    }
  }
  // Measured against 4.1.0: 593 of 616 covers are identical, 23 are equal-cost alternatives
  // that upstream selects by hash order.
  //
  // Java's own answer is stable run to run (two full passes of the probe over these 616 cases
  // are byte-identical) because `HashMap` order is a function of `Implicant.hashCode`, which
  // is `(unknowns << 16) | values`. It is arbitrary, not random. Swift's `Hasher` is seeded
  // per process, so the same code written naively here would NOT be stable: hence the sorted
  // traversals in `Implicant.computeMinimal`, and hence 23 cases where two equally cheap
  // covers exist and the two implementations pick different ones.
  //
  // If this ratio moves, the minimiser changed, and that is worth a human look even when
  // every case still passes the correctness assertions above.
  #expect(exact == 593, "exact agreement with the oracle changed: \(exact) exact, \(ties) tied")
}

/// Expression construction, isolated from cover selection: feed the oracle's own implicants,
/// in the oracle's own order, through the Swift `toExpression` and compare the rendering.
@Test func expressionConstructionMatchesTheJavaOracleExactly() throws {
  for c in goldenCases() {
    let model = try makeModel(inputs: c.inputs, spec: c.spec)
    let implicants = c.expectedImplicants.map {
      Implicant(unknowns: $0.unknowns, values: $0.values)
    }
    let expr = Implicant.toExpression(format: c.format, model: model, implicants: implicants)
    #expect((expr?.toString(.mathematical) ?? "null") == c.expectedExpression, "for \(c.line)")
  }
}

// MARK: - Properties the golden file cannot state

@Test func everyCoverActuallyCoversItsTable() throws {
  for c in goldenCases() {
    let model = try makeModel(inputs: c.inputs, spec: c.spec)
    let implicants = Implicant.computeMinimal(
      format: c.format, model: model, variable: "q", report: MinimizationReport())
    #expect(
      coverIsCorrect(implicants, spec: c.spec, inputs: c.inputs, format: c.format),
      "cover is not equivalent to the table for \(c.line)")
  }
}

/// The determinism trap. Swift's `Dictionary`/`Set` reseed per process, so repeating a case
/// *within* one process would not catch order-dependence that survives seeding; rebuilding
/// the model each time, repopulating every intermediate dictionary, does.
@Test func minimisationIsDeterministicAcrossRebuilds() throws {
  // Cyclic cores: precisely the shape that reaches Petrick's method, where upstream picks
  // `cheapestCovers.get(0)` out of a HashSet-ordered list.
  let specs = [
    (3, "01101101"),
    (3, "01111110"),
    (4, "0110100110010110"),
    (4, "1x01x110011x0101"),
    (4, "0101101011x10100"),
    (5, "11010101100011001111100x00111111"),
  ]
  for (n, spec) in specs {
    var answers = Set<String>()
    for _ in 0..<25 {
      let model = try makeModel(inputs: n, spec: Array(spec))
      let implicants = Implicant.computeMinimal(
        format: AnalyzerModel.formatSumOfProducts, model: model, variable: "q",
        report: MinimizationReport())
      // The ORDER of the returned list matters too, it decides the shape of the expression
      // the user is shown, so compare the list as a sequence, not as a set.
      answers.insert(implicants.map { "\($0.values)/\($0.unknowns)" }.joined(separator: ","))
    }
    #expect(answers.count == 1, "nondeterministic minimisation for \(spec): \(answers)")
  }
}

/// Independent of the oracle: brute force over all 256 three-variable functions confirms the
/// cover is not merely *a* cover but a **minimum-cardinality** one.
@Test func threeVariableCoversAreMinimumCardinality() throws {
  for f in 0..<256 {
    let spec = (0..<8).map { (f >> $0) & 1 == 1 ? Character("1") : Character("0") }
    let model = try makeModel(inputs: 3, spec: spec)
    let implicants = Implicant.computeMinimal(
      format: AnalyzerModel.formatSumOfProducts, model: model, variable: "q",
      report: MinimizationReport())
    #expect(implicants.count == bruteForceMinimumCoverSize(spec: spec, inputs: 3),
      "not a minimum cover for function \(f)")
  }
}

/// Every cube over `n` inputs that covers no zero, then an exhaustive search for the smallest
/// subset covering every one. Exponential, hence three variables only.
func bruteForceMinimumCoverSize(spec: [Character], inputs n: Int) -> Int {
  let rows = 1 << n
  let ones = (0..<rows).filter { spec[$0] == "1" }
  if ones.isEmpty { return 0 }
  var cubes: [Int] = []  // bitmask of covered minterms
  for unknowns in 0..<rows {
    for values in 0..<rows where (values & unknowns) == 0 {
      var maskOfCovered = 0
      var ok = true
      for row in 0..<rows where (row & ~unknowns) == values {
        if spec[row] == "0" { ok = false }
        if spec[row] == "1" { maskOfCovered |= 1 << row }
      }
      if ok && maskOfCovered != 0 { cubes.append(maskOfCovered) }
    }
  }
  let target = ones.reduce(0) { $0 | (1 << $1) }
  for size in 1...cubes.count where searchCover(cubes, 0, 0, target, size) { return size }
  return cubes.count
}

private func searchCover(_ cubes: [Int], _ start: Int, _ acc: Int, _ target: Int, _ left: Int)
  -> Bool
{
  if acc & target == target { return true }
  if left == 0 { return false }
  for i in start..<cubes.count where searchCover(cubes, i + 1, acc | cubes[i], target, left - 1) {
    return true
  }
  return false
}
