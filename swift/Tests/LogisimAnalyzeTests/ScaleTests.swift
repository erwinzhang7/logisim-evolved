// ScaleTests: part of logisim-evolved.
//
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// Quine-McCluskey plus Petrick is worst-case exponential in the input count, which is why
// upstream refuses to run it unasked past six inputs. Measured on the shipped 4.1.0 jar with
// pseudo-random functions (tools/analyze/MinProbe.java, seed 7):
//
//     8 inputs  ->  5.0 s, 47 implicants
//     9 inputs  ->  0.8 s, 89 implicants
//    10 inputs  ->  did not finish in 9 minutes
//
// So the wall at ~9 inputs is the algorithm's, not the port's. These two cases are here to
// keep it that way: they are the widest differential cases in the suite, and a change that
// makes the Swift dramatically slower than those numbers is a regression even though nothing
// fails.
//
// Cost of this file: ~2.2 s for both cases in a release build: against ~5.8 s for the same
// two in the JVM, so the sorted traversals that buy determinism do not cost anything in the
// end. A debug build takes ~29 s, which is the price of running it in CI.

import Testing

@testable import LogisimAnalyze

enum ScaleGolden {
  static let cases = """
8 1010001000011000100001000011001000100001111111000011111001010110011111001100111110110010010011100111011111000000001011001110011111011000010010000010001011110011111000111000100101101010001001100111011110000101010110010101101110000001011000000100010101110011 | 47 {2/4,11/48,21/32,39/192,68/9,98/5,52/65,129/66,146/44,152/3,167/8,52/130,61/128,194/5,72/128,212/8,160/64,105/144,234/16,12/160,26/132,50/1,30/224,65/36,162/20,40/132,41/20,82/4,128/4,155/68,197/10,0/16,34/8,76/3,16/64,161/16,76/17,66/17,241/4,104/17,137/16,114/8,209/10,217/34,73/20,125/2,215/40} ~a⋅~b⋅~c⋅~d⋅~e⋅v6⋅~v7+~a⋅~b⋅e⋅~v5⋅v6⋅v7+~a⋅~b⋅d⋅~e⋅v5⋅~v6⋅v7+c⋅~d⋅~e⋅v5⋅v6⋅v7+~a⋅b⋅~c⋅~d⋅v5⋅~v6+~a⋅b⋅c⋅~d⋅~e⋅v6+~a⋅c⋅d⋅~e⋅v5⋅~v6+a⋅~c⋅~d⋅~e⋅~v5⋅v7+a⋅~b⋅d⋅v6⋅~v7+a⋅~b⋅~c⋅d⋅e⋅~v5+a⋅~b⋅c⋅~d⋅v5⋅v6⋅v7+~b⋅c⋅d⋅~e⋅v5⋅~v7+~b⋅c⋅d⋅e⋅v5⋅~v6⋅v7+a⋅b⋅~c⋅~d⋅~e⋅v6+b⋅~c⋅~d⋅e⋅~v5⋅~v6⋅~v7+a⋅b⋅~c⋅d⋅v5⋅~v6⋅~v7+a⋅c⋅~d⋅~e⋅~v5⋅~v6⋅~v7+b⋅c⋅e⋅~v5⋅~v6⋅v7+a⋅b⋅c⋅e⋅~v5⋅v6⋅~v7+~b⋅~d⋅e⋅v5⋅~v6⋅~v7+~b⋅~c⋅d⋅e⋅v6⋅~v7+~a⋅~b⋅c⋅d⋅~e⋅~v5⋅v6+d⋅e⋅v5⋅v6⋅~v7+~a⋅b⋅~d⋅~e⋅~v6⋅v7+a⋅~b⋅c⋅~e⋅v6⋅~v7+~b⋅c⋅~d⋅e⋅~v6⋅~v7+~a⋅~b⋅c⋅e⋅~v6⋅v7+~a⋅b⋅~c⋅d⋅~e⋅v6⋅~v7+a⋅~b⋅~c⋅~d⋅~e⋅~v6⋅~v7+a⋅~c⋅d⋅e⋅v6⋅v7+a⋅b⋅~c⋅~d⋅v5⋅v7+~a⋅~b⋅~c⋅~e⋅~v5⋅~v6⋅~v7+~a⋅~b⋅c⋅~d⋅~v5⋅v6⋅~v7+~a⋅b⋅~c⋅~d⋅e⋅v5+~a⋅~c⋅d⋅~e⋅~v5⋅~v6⋅~v7+a⋅~b⋅c⋅~e⋅~v5⋅~v6⋅v7+~a⋅b⋅~c⋅e⋅v5⋅~v6+~a⋅b⋅~c⋅~e⋅~v5⋅v6+a⋅b⋅c⋅d⋅~e⋅~v6⋅v7+~a⋅b⋅c⋅e⋅~v5⋅~v6+a⋅~b⋅~c⋅e⋅~v5⋅~v6⋅v7+~a⋅b⋅c⋅d⋅~v5⋅v6⋅~v7+a⋅b⋅~c⋅d⋅~v5⋅v7+a⋅b⋅d⋅e⋅~v5⋅v7+~a⋅b⋅~c⋅e⋅~v6⋅v7+~a⋅b⋅c⋅d⋅e⋅v5⋅v7+a⋅b⋅d⋅v5⋅v6⋅v7
9 10001000001001100001001001101110101010111001001001010100110001111011010111011100000110010111011010010100100010101110000010001101101101000010101111001001100001100011010100110111100101001101100001001010110001110100100000001011000110100011010001110110000111001011001111110010101101110000011010101110001111011110101110001110110111010010011101101000110110001111111101110000010111100000101011001110111011100010111110001110011100000010000001011000101100011110100011000110101101011110010010100101101001100100001000111000 | 89 {0/36,13/80,22/264,67/20,69/288,61/66,130/33,140/258,151/256,29/384,144/40,206/17,196/34,256/50,278/33,274/192,89/258,353/10,353/18,308/74,443/4,357/130,124/384,25/36,14/48,64/2,73/18,26/68,0/384,142/33,145/64,212/8,56/384,300/17,321/48,288/70,356/17,404/32,467/4,205/288,246/256,10/388,72/36,84/256,108/2,14/400,165/10,185/2,193/264,245/8,299/4,325/10,405/72,38/1,43/128,133/256,53/128,200/257,320/132,344/4,34/384,480/10,448/18,462/32,266/68,290/200,170/65,442/65,163/88,464/10,67/288,113/384,114/128,392/20,417/18,96/24,258/21,49/320,384/13,19/32,264/3,148/256,32/72,456/17,184/4,277/136,292/9,28/2,262/152} ~a⋅~b⋅~c⋅~e⋅~v5⋅~v7⋅~v8+~a⋅~b⋅~d⋅v5⋅v6⋅~v7⋅v8+~b⋅~c⋅~d⋅e⋅v6⋅v7⋅~v8+~a⋅~b⋅c⋅~d⋅~v5⋅v7⋅v8+~b⋅c⋅~e⋅~v5⋅v6⋅~v7⋅v8+~a⋅~b⋅d⋅e⋅v5⋅v6⋅v8+~a⋅b⋅~c⋅~e⋅~v5⋅~v6⋅v7+b⋅~c⋅~d⋅~e⋅v5⋅v6⋅~v8+b⋅~c⋅~d⋅e⋅~v5⋅v6⋅v7⋅v8+~c⋅~d⋅e⋅v5⋅v6⋅~v7⋅v8+~a⋅b⋅~c⋅e⋅~v6⋅~v7⋅~v8+~a⋅b⋅c⋅~d⋅v5⋅v6⋅v7+~a⋅b⋅c⋅~e⋅~v5⋅v6⋅~v8+a⋅~b⋅~c⋅~v5⋅~v6⋅~v8+a⋅~b⋅~c⋅e⋅~v5⋅v6⋅v7+a⋅~d⋅e⋅~v5⋅~v6⋅v7⋅~v8+~b⋅c⋅~d⋅e⋅v5⋅~v6⋅v8+a⋅~b⋅c⋅d⋅~e⋅~v6⋅v8+a⋅~b⋅c⋅d⋅~v5⋅~v6⋅v8+a⋅~b⋅d⋅e⋅v6⋅~v8+a⋅b⋅~c⋅d⋅e⋅v5⋅v7⋅v8+a⋅c⋅d⋅~e⋅~v5⋅v6⋅v8+c⋅d⋅e⋅v5⋅v6⋅~v7⋅~v8+~a⋅~b⋅~c⋅e⋅v5⋅~v7⋅v8+~a⋅~b⋅~c⋅v5⋅v6⋅v7⋅~v8+~a⋅~b⋅c⋅~d⋅~e⋅~v5⋅~v6⋅~v8+~a⋅~b⋅c⋅~d⋅v5⋅~v6⋅v8+~a⋅~b⋅~d⋅e⋅v5⋅v7⋅~v8+~c⋅~d⋅~e⋅~v5⋅~v6⋅~v7⋅~v8+~a⋅b⋅~c⋅~e⋅v5⋅v6⋅v7+~a⋅b⋅~d⋅e⋅~v5⋅~v6⋅~v7⋅v8+~a⋅b⋅c⋅~d⋅e⋅v6⋅~v7⋅~v8+~c⋅d⋅e⋅v5⋅~v6⋅~v7⋅~v8+a⋅~b⋅~c⋅d⋅v5⋅v6⋅~v7+a⋅~b⋅c⋅~v5⋅~v6⋅~v7⋅v8+a⋅~b⋅d⋅~e⋅~v5⋅~v8+a⋅~b⋅c⋅d⋅~v5⋅v6⋅~v7+a⋅b⋅~c⋅e⋅~v5⋅v6⋅~v7⋅~v8+a⋅b⋅c⋅~d⋅e⋅~v5⋅v7⋅v8+b⋅c⋅~e⋅v5⋅v6⋅~v7⋅v8+b⋅c⋅d⋅e⋅~v5⋅v6⋅v7⋅~v8+~c⋅~d⋅~e⋅v5⋅v7⋅~v8+~a⋅~b⋅c⋅~e⋅v5⋅~v7⋅~v8+~b⋅c⋅~d⋅e⋅~v5⋅v6⋅~v7⋅~v8+~a⋅~b⋅c⋅d⋅~e⋅v5⋅v6⋅~v8+~c⋅~d⋅v5⋅v6⋅v7⋅~v8+~a⋅b⋅~c⋅d⋅~e⋅v6⋅v8+~a⋅b⋅~c⋅d⋅e⋅v5⋅~v6⋅v8+b⋅c⋅~d⋅~e⋅~v6⋅~v7⋅v8+~a⋅b⋅c⋅d⋅e⋅v6⋅~v7⋅v8+a⋅~b⋅~c⋅d⋅~e⋅v5⋅v7⋅v8+a⋅~b⋅c⋅~d⋅~e⋅v6⋅v8+a⋅b⋅~d⋅e⋅v6⋅~v7⋅v8+~a⋅~b⋅~c⋅d⋅~e⋅~v5⋅v6⋅v7+~a⋅~c⋅d⋅~e⋅v5⋅~v6⋅v7⋅v8+b⋅~c⋅~d⋅~e⋅~v5⋅v6⋅~v7⋅v8+~a⋅~c⋅d⋅e⋅~v5⋅v6⋅~v7⋅v8+b⋅c⋅~d⋅~e⋅v5⋅~v6⋅~v7+a⋅c⋅~d⋅~e⋅~v5⋅~v7⋅~v8+a⋅~b⋅c⋅~d⋅e⋅v5⋅~v7⋅~v8+~c⋅d⋅~e⋅~v5⋅~v6⋅v7⋅~v8+a⋅b⋅c⋅d⋅~e⋅~v6⋅~v8+a⋅b⋅c⋅~d⋅~v5⋅~v6⋅~v8+a⋅b⋅c⋅~e⋅v5⋅v6⋅v7⋅~v8+a⋅~b⋅~d⋅~e⋅v5⋅v7⋅~v8+a⋅d⋅~e⋅~v6⋅v7⋅~v8+~a⋅b⋅d⋅~e⋅v5⋅~v6⋅v7+a⋅b⋅d⋅e⋅v5⋅~v6⋅v7+~a⋅b⋅d⋅~v6⋅v7⋅v8+a⋅b⋅c⋅~d⋅e⋅~v6⋅~v8+~b⋅c⋅~e⋅~v5⋅~v6⋅v7⋅v8+c⋅d⋅e⋅~v5⋅~v6⋅~v7⋅v8+~a⋅c⋅d⋅e⋅~v5⋅~v6⋅v7⋅~v8+a⋅b⋅~c⋅~d⋅v5⋅~v7⋅~v8+a⋅b⋅~c⋅d⋅~v5⋅~v6⋅v8+~a⋅~b⋅c⋅d⋅~v6⋅~v7⋅~v8+a⋅~b⋅~c⋅~d⋅~v5⋅v7+~b⋅d⋅e⋅~v5⋅~v6⋅~v7⋅v8+a⋅b⋅~c⋅~d⋅~e⋅~v7+~a⋅~b⋅~c⋅e⋅~v5⋅~v6⋅v7⋅v8+a⋅~b⋅~c⋅~d⋅~e⋅v5⋅~v6+b⋅~c⋅~d⋅e⋅~v5⋅v6⋅~v7⋅~v8+~a⋅~b⋅d⋅~e⋅~v6⋅~v7⋅~v8+a⋅b⋅c⋅~d⋅v5⋅~v6⋅~v7+~a⋅b⋅~c⋅d⋅e⋅v5⋅~v7⋅~v8+a⋅~c⋅~d⋅e⋅v6⋅~v7⋅v8+a⋅~b⋅~c⋅d⋅~e⋅v6⋅~v7+~a⋅~b⋅~c⋅~d⋅e⋅v5⋅v6⋅~v8+a⋅~c⋅~d⋅v6⋅v7⋅~v8
"""
}

@Test func wideTablesMatchTheJavaOracle() throws {
  for line in ScaleGolden.cases.split(separator: "\n") {
    let c = try #require(MinimizationCase(line: String(line)))
    let model = try makeModel(inputs: c.inputs, spec: c.spec)
    let implicants = Implicant.computeMinimal(
      format: c.format, model: model, variable: "q", report: MinimizationReport())
    #expect(implicants.count == c.expectedCount, "cover size for \(c.inputs) inputs")
    #expect(
      coverIsCorrect(implicants, spec: c.spec, inputs: c.inputs, format: c.format),
      "cover is not equivalent to its table for \(c.inputs) inputs")
    let cost = implicants.reduce(0) { $0 + $1.unknownCount }
    #expect(cost == c.expectedCost, "cover cost for \(c.inputs) inputs")
  }
}

@Test func minimisationRefusesToRunUnaskedPastSixInputs() throws {
  // Java: `if ((nrOfInputs > MAXIMAL_NR_OF_INPUTS_FOR_AUTO_MINIMAL_FORM) && (outputArea == null))
  // return Collections.emptyList();`: the report sink doubles as "the user asked for this".
  let spec = Array(String(repeating: "10", count: 64))  // 7 inputs
  let m = try makeModel(inputs: 7, spec: spec)
  #expect(Implicant.maximalNrOfInputsForAutoMinimalForm == 6)
  #expect(
    Implicant.computeMinimal(
      format: AnalyzerModel.formatSumOfProducts, model: m, variable: "q").isEmpty)
  #expect(
    !Implicant.computeMinimal(
      format: AnalyzerModel.formatSumOfProducts, model: m, variable: "q",
      report: MinimizationReport()).isEmpty)
}
