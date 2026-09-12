//
//  Implicant.swift: part of logisim-evolved.
//
//  Derived from logisim-evolution, specifically
//  `src/main/java/com/cburch/logisim/analyze/model/Implicant.java`. GPL-3.0-only.
//  See LICENSE.md.
//

/// Java: `com.cburch.logisim.analyze.model.Implicant`; a cube over the input variables:
/// `values` gives the fixed bits and `unknowns` marks the free ones.
///
/// A **class**, not a struct, and deliberately so: `isPrime` is mutated in place on objects
/// that are simultaneously keys of the working tables, which is how Quine-McCluskey marks a
/// term as "was merged, therefore not prime". `==` and `hash` cover only `(unknowns, values)`,
/// exactly like Java; `isPrime` and `isDontCare` are excluded, so an implicant stays findable
/// in a table after being marked.
public final class Implicant: Hashable, Comparable, CustomStringConvertible {
  /// Java: `MAXIMAL_NR_OF_INPUTS_FOR_AUTO_MINIMAL_FORM`: above this, minimisation only runs
  /// when the user explicitly asks (i.e. when a report sink is supplied), because
  /// Quine-McCluskey is worst-case exponential in the input count.
  public static let maximalNrOfInputsForAutoMinimalForm = 6

  /// Java: `unknowns`; set bit means "this input is a don't-care in this cube".
  public let unknowns: Int
  /// Java: `values`, the fixed input bits.
  public let values: Int
  /// Java: `isDontCare`; the whole term came from a don't-care table entry.
  public let isDontCare: Bool
  /// Java: `isPrime`: cleared when this term merges into a larger cube.
  var isPrime = true

  /// Java: `Implicant(int unknowns, int values)`.
  init(unknowns: Int, values: Int) {
    self.unknowns = unknowns
    self.values = values
    self.isDontCare = false
  }

  /// Java: `Implicant(int unknowns, int values, boolean dontCareTerm)`.
  init(unknowns: Int, values: Int, dontCareTerm: Bool) {
    self.unknowns = unknowns
    self.values = values
    self.isDontCare = dontCareTerm
  }

  /// Java: `Implicant(int values, boolean dontCareTerm)`, a minterm, no unknowns.
  init(values: Int, dontCareTerm: Bool) {
    self.unknowns = 0
    self.values = values
    self.isDontCare = dontCareTerm
  }

  /// Java: `MINIMAL_IMPLICANT`; the "everything" answer handed back when no output is
  /// selected.
  public static let minimalImplicant = Implicant(unknowns: 0, values: -1)
  /// Java: `MINIMAL_LIST`.
  public static let minimalList: [Implicant] = [minimalImplicant]

  public static func == (lhs: Implicant, rhs: Implicant) -> Bool {
    lhs.unknowns == rhs.unknowns && lhs.values == rhs.values
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(unknowns)
    hasher.combine(values)
  }

  /// Java: `compareTo(Implicant)`: by `values`, then by `unknowns`. Consistent with `==`
  /// (it returns 0 exactly when the two are equal), which is what lets it stand in for
  /// `HashSet` iteration order everywhere below.
  public static func < (lhs: Implicant, rhs: Implicant) -> Bool {
    if lhs.values != rhs.values { return lhs.values < rhs.values }
    return lhs.unknowns < rhs.unknowns
  }

  /// Java: `getRow()`; the table row this implicant is, or -1 if it spans several.
  public var row: Int { unknowns != 0 ? -1 : values }

  /// Java: `getUnknownCount()`; the cube's dimension; bigger is cheaper.
  public var unknownCount: Int { unknowns.nonzeroBitCount }

  public var description: String {
    "Implicant(values: \(values), unknowns: \(unknowns))"
  }

  /// Java: `getTerms()` / `TermIterator`; every minterm inside this cube.
  ///
  /// The bit trick is upstream's: `currentMask` walks the subsets of `unknowns` and the
  /// sentinel `-1` ends the walk.
  public var terms: [Implicant] {
    var out: [Implicant] = []
    var currentMask = 0
    while currentMask >= 0 {
      let ret = currentMask | values
      let diffs = currentMask ^ unknowns
      let diff = diffs ^ ((diffs - 1) & diffs)
      if diff == 0 {
        currentMask = -1
      } else {
        currentMask = (currentMask & -diff) | diff
      }
      out.append(Implicant(unknowns: 0, values: ret))
    }
    return out
  }

  /// Java: `getNrOfOnes(int value, int nrOfBits)`.
  static func nrOfOnes(_ value: Int, _ nrOfBits: Int) -> Int {
    var nrOfOnes = 0
    var mask = 1
    for _ in 0..<nrOfBits {
      if (value & mask) != 0 { nrOfOnes += 1 }
      mask <<= 1
    }
    return nrOfOnes
  }

  /// Java: `getGroupRepresentation(int, int, int)`, `"01-1"` style, for the report.
  static func groupRepresentation(_ value: Int, _ dontCares: Int, _ nrOfBits: Int) -> String {
    var result = ""
    var mask = 1 << (nrOfBits - 1)
    while mask > 0 {
      if (dontCares & mask) != 0 {
        result += "-"
      } else {
        result += (value & mask) != 0 ? "1" : "0"
      }
      mask >>= 1
    }
    return result
  }

  // MARK: - Expressions

  /// Java: `toProduct(TruthTable)`: the AND term for a minterm cover.
  public func toProduct(_ source: TruthTable) -> Expression {
    var term: Expression?
    let cols = source.inputColumnCount
    for i in stride(from: cols - 1, through: 0, by: -1) where (unknowns & (1 << i)) == 0 {
      var literal = Expressions.variable(source.inputHeader(cols - 1 - i))
      if (values & (1 << i)) == 0 { literal = .not(literal) }
      term = Expressions.and(term, literal)
    }
    return term ?? Expressions.constant(1)
  }

  /// Java: `toSum(TruthTable)`: the OR term for a maxterm cover.
  public func toSum(_ source: TruthTable) -> Expression {
    var term: Expression?
    let cols = source.inputColumnCount
    for i in stride(from: cols - 1, through: 0, by: -1) where (unknowns & (1 << i)) == 0 {
      var literal = Expressions.variable(source.inputHeader(cols - 1 - i))
      if (values & (1 << i)) != 0 { literal = .not(literal) }
      term = Expressions.or(term, literal)
    }
    return term ?? Expressions.constant(0)
  }

  /// Java: `toExpression(int format, AnalyzerModel, List<Implicant>)`.
  public static func toExpression(
    format: Int, model: AnalyzerModel, implicants: [Implicant]?
  ) -> Expression? {
    guard let implicants else { return nil }
    let table = model.truthTable
    if format == AnalyzerModel.formatProductOfSums {
      var product: Expression?
      for implicant in implicants { product = Expressions.and(product, implicant.toSum(table)) }
      return product ?? Expressions.constant(1)
    } else {
      var sum: Expression?
      for implicant in implicants { sum = Expressions.or(sum, implicant.toProduct(table)) }
      return sum ?? Expressions.constant(0)
    }
  }
}

/// Java: the `JTextArea` that `computeMinimal` narrates its progress into.
///
/// It is not merely cosmetic: passing a sink is also how the caller says "the user asked for
/// this explicitly", which is what lifts the 6-input guard. D9 forbids a Swing type here, so
/// it is a plain text sink.
public final class MinimizationReport {
  public private(set) var text = ""
  public init() {}
  public func append(_ info: String) { text += info }
}

/// A set of implicants with a **defined iteration order**.
///
/// This type is the whole answer to the determinism problem. Upstream stores these in
/// `HashSet<Implicant>` / `HashMap<Implicant, …>` and iterates them in hash order, which the
/// JLS leaves unspecified; the final cover Petrick's method picks (`cheapestCovers.get(0)`)
/// and the order implicants land in the answer both follow that iteration. Swift's
/// `Dictionary`/`Set` are not merely *differently* unspecified; they are **seeded per
/// process**, so a literal port would give a different minimal expression on different runs
/// of the same binary for the same truth table. That is strictly worse than upstream, where
/// the order at least holds still for a given JVM build.
///
/// So every set and map that can influence the result is iterated in `Implicant`'s own
/// `compareTo` order (`values`, then `unknowns`), which is total and consistent with `==`.
/// Same input, same output, every run, on every machine.
struct ImplicantSet: Hashable, Comparable, Sequence {
  /// Ascending by `Implicant.<`, and unique.
  private(set) var elements: [Implicant] = []

  init() {}

  init<S: Sequence>(_ implicants: S) where S.Element == Implicant {
    for i in implicants { insert(i) }
  }

  var count: Int { elements.count }
  var isEmpty: Bool { elements.isEmpty }

  func makeIterator() -> IndexingIterator<[Implicant]> { elements.makeIterator() }

  /// Index of `implicant`, or `-(insertionPoint) - 1`.
  private func search(_ implicant: Implicant) -> Int {
    var lo = 0
    var hi = elements.count - 1
    while lo <= hi {
      let mid = (lo + hi) >> 1
      if elements[mid] < implicant {
        lo = mid + 1
      } else if implicant < elements[mid] {
        hi = mid - 1
      } else {
        return mid
      }
    }
    return -(lo + 1)
  }

  func contains(_ implicant: Implicant) -> Bool { search(implicant) >= 0 }

  mutating func insert(_ implicant: Implicant) {
    let pos = search(implicant)
    if pos < 0 { elements.insert(implicant, at: -pos - 1) }
  }

  mutating func remove(_ implicant: Implicant) {
    let pos = search(implicant)
    if pos >= 0 { elements.remove(at: pos) }
  }

  mutating func formUnion(_ other: ImplicantSet) {
    for e in other.elements { insert(e) }
  }

  func union(_ other: ImplicantSet) -> ImplicantSet {
    var out = self
    out.formUnion(other)
    return out
  }

  /// Java: `Set.containsAll(other)`.
  func isSuperset(of other: ImplicantSet) -> Bool {
    for e in other.elements where !contains(e) { return false }
    return true
  }

  static func == (lhs: ImplicantSet, rhs: ImplicantSet) -> Bool { lhs.elements == rhs.elements }

  func hash(into hasher: inout Hasher) { hasher.combine(elements) }

  /// Lexicographic over the sorted elements, shorter first on a prefix. Only used to make
  /// "pick one of the equally cheap covers" reproducible.
  static func < (lhs: ImplicantSet, rhs: ImplicantSet) -> Bool {
    for (a, b) in zip(lhs.elements, rhs.elements) {
      if a < b { return true }
      if b < a { return false }
    }
    return lhs.elements.count < rhs.elements.count
  }
}

extension Implicant {

  /// Java: `computeMinimal(int format, AnalyzerModel, String variable, JTextArea outputArea)`.
  ///
  /// Quine-McCluskey (iterated adjacent-cube merging to find all prime implicants), then
  /// essential-prime extraction by alternating column and row reduction, then **Petrick's
  /// method** on whatever cyclic core is left. Worst-case exponential in the number of
  /// inputs, which is why upstream refuses to run it unasked past 6 inputs: ported as-is,
  /// with no attempt to be cleverer than the original.
  ///
  /// Every `HashMap`/`HashSet` traversal that can affect the answer is replaced by a sorted
  /// traversal; see `ImplicantSet` for why that is not optional.
  public static func computeMinimal(
    format: Int, model: AnalyzerModel, variable: String, report: MinimizationReport? = nil
  ) -> [Implicant] {
    let table = model.truthTable
    guard let outputVariableIndex = model.outputs.bits.firstIndex(of: variable) else { return [] }

    // first we do some house keeping
    let desiredTerm: Entry = format == AnalyzerModel.formatSumOfProducts ? .one : .zero
    let skippedTerm: Entry = desiredTerm == .one ? .zero : .one
    let nrOfInputs = table.inputColumnCount
    var oneHotTable = Set<Int>()
    var mask = 1
    for _ in 0..<nrOfInputs {
      oneHotTable.insert(mask)
      mask <<= 1
    }

    // The first table holds every desired term (minterms or maxterms) plus the don't cares.
    // `primes` maps a group (the cube) to the min/maxterms inside it.
    var primes: [Implicant: ImplicantSet] = [:]
    var essentialPrimes: [Implicant] = []
    // For currentTable/newTable the key is the number of ones in the term (the group id).
    var currentTable: [Int: [Implicant: ImplicantSet]] = [:]
    var newTable: [Int: [Implicant: ImplicantSet]] = [:]
    // termsToCover maps a term that must be covered to the primes that can cover it.
    var termsToCover: [Implicant: [Implicant]] = [:]
    var allDontCare = true
    for inputCombination in 0..<table.rowCount {
      let term = table.outputEntry(row: inputCombination, column: outputVariableIndex)
      if term == skippedTerm {
        allDontCare = false
        continue
      }
      let nrOfOnes = Implicant.nrOfOnes(inputCombination, nrOfInputs)
      let isDontCare = term != desiredTerm
      let implicant = Implicant(values: inputCombination, dontCareTerm: isDontCare)
      var implicantsSet = ImplicantSet()
      if !isDontCare {
        termsToCover[implicant] = []
        implicantsSet.insert(implicant)
        allDontCare = false
      }
      newTable[nrOfOnes, default: [:]][implicant] = implicantsSet
    }

    if allDontCare { return [] }
    // Past ~8 inputs this algorithm takes a long time. To keep the UI responsive, only
    // minimise beyond 6 inputs when the user asked for it (i.e. when a report sink exists).
    if nrOfInputs > maximalNrOfInputsForAutoMinimalForm && report == nil {
      return []
    }
    report?.append("\n\(AnalyzeStrings.message("implicantOutputName", [variable]))\n")

    // Here the real work starts: determine all primes.
    var couldMerge = false
    var groupSize = 2
    repeat {
      report?.append("\n\(AnalyzeStrings.message("implicantGroupSize", [String(groupSize)]))")
      var nrOfPrimes = 0
      couldMerge = false
      currentTable = newTable
      newTable = [:]
      var minimalKey = Int.max
      var maximalKey = 0
      for key in currentTable.keys {
        if key < minimalKey { minimalKey = key }
        if key > maximalKey { maximalKey = key }
      }
      if minimalKey < maximalKey {
        for key in minimalKey..<maximalKey {
          guard let group1 = currentTable[key], let group2 = currentTable[key + 1] else {
            continue
          }
          // we see if we can merge terms
          // Sorted once per group pair, not once per outer term: the sort is only here to
          // fix the iteration order, and re-sorting inside the loop would add a factor.
          let sortedGroup1 = group1.keys.sorted()
          let sortedGroup2 = group2.keys.sorted()
          for termGroup1 in sortedGroup1 {
            for termGroup2 in sortedGroup2 {
              if termGroup1.unknowns != termGroup2.unknowns { continue }
              let differenceMask = termGroup1.values ^ termGroup2.values
              guard oneHotTable.contains(differenceMask) else { continue }
              let dontCareMask = termGroup1.unknowns | differenceMask
              let newValue =
                (termGroup1.values & differenceMask) == 0 ? termGroup1.values : termGroup2.values
              let isDontCareGroup = termGroup1.isDontCare && termGroup2.isDontCare
              let newImplicant = Implicant(
                unknowns: dontCareMask, values: newValue, dontCareTerm: isDontCareGroup)
              var newImplicantTerms = ImplicantSet()
              couldMerge = true
              termGroup1.isPrime = false
              termGroup2.isPrime = false
              newImplicantTerms.formUnion(group1[termGroup1]!)
              newImplicantTerms.formUnion(group2[termGroup2]!)
              if let existing = newTable[key] {
                // see if the new implicant already is in the set
                var found = false
                for implicant in existing.keys {
                  found = found || (implicant.values == newValue && implicant.unknowns == dontCareMask)
                }
                if !found { newTable[key]![newImplicant] = newImplicantTerms }
              } else {
                newTable[key] = [newImplicant: newImplicantTerms]
              }
            }
          }
        }
      }
      // now we add the primes to the set
      for key in currentTable.keys.sorted() {
        for implicant in currentTable[key]!.keys.sorted()
        where implicant.isPrime && !implicant.isDontCare {
          primes[implicant] = currentTable[key]![implicant]!
          if nrOfPrimes % 16 == 0 { report?.append("\n") }
          report?.append(
            "\(groupRepresentation(implicant.values, implicant.unknowns, nrOfInputs)) ")
          nrOfPrimes += 1
        }
      }
      if nrOfPrimes == 0 {
        report?.append("\n\(AnalyzeStrings.message("implicantNoneFound"))")
      }
      groupSize <<= 1
    } while couldMerge

    // we build now the table, with for each term which prime it covers
    let sortedTerms = termsToCover.keys.sorted()
    for prime in primes.keys.sorted() {
      for term in sortedTerms where primes[prime]!.contains(term) {
        termsToCover[term]!.append(prime)
      }
    }

    // finally we have to find the essential primes
    var couldDoRowReduction = false
    var couldDoColumnReduction = false
    report?.append("\n\(AnalyzeStrings.message("implicantColumRowReduction"))")
    var nrEssentialPrimes = 0
    repeat {
      couldDoRowReduction = false
      couldDoColumnReduction = false
      var termsToRemove: [Implicant] = []
      // we first try a column reduction
      for term in termsToCover.keys.sorted() {
        let termInfo = termsToCover[term]!
        guard termInfo.count == 1 else { continue }
        // we found a prime cover, as this cover only covers this term
        let prime = termInfo[0]
        guard let primeTerms = primes[prime] else { continue }
        // `primes` gains and loses no keys inside this loop, only the sets it maps to change
        // , so the order can be fixed once.
        let sortedPrimes = primes.keys.sorted()
        for terms in primeTerms.elements {
          for currentPrime in sortedPrimes {
            if currentPrime == prime { continue }
            couldDoColumnReduction = couldDoColumnReduction || primes[currentPrime]!.contains(terms)
            primes[currentPrime]!.remove(terms)
          }
          termsToRemove.append(terms)
        }
        essentialPrimes.append(prime)
        primes[prime] = nil
        if nrEssentialPrimes % 16 == 0 { report?.append("\n") }
        nrEssentialPrimes += 1
        report?.append(" \(groupRepresentation(prime.values, prime.unknowns, nrOfInputs))")
      }
      // we do the cleanup
      for term in termsToRemove { termsToCover[term] = nil }

      // now we perform the row reduction; first we look for empty primes
      var primesToRemove = ImplicantSet()
      var primeHierarchy: [Int: [Implicant]] = [:]
      var nrOfElementGroups: [Int] = []
      for prime in primes.keys.sorted() {
        let primeElements = primes[prime]!
        if primeElements.isEmpty {
          primesToRemove.insert(prime)
          couldDoRowReduction = true
        } else {
          let nrOfElements = primeElements.count
          // appended in sorted order, so each hierarchy bucket is sorted too
          primeHierarchy[nrOfElements, default: []].append(prime)
          if !nrOfElementGroups.contains(nrOfElements) { nrOfElementGroups.append(nrOfElements) }
        }
      }
      nrOfElementGroups.sort()
      if !nrOfElementGroups.isEmpty {
        for mergeGroupId in stride(from: nrOfElementGroups.count - 1, to: 0, by: -1) {
          for bigPrime in primeHierarchy[nrOfElementGroups[mergeGroupId]]! {
            if primesToRemove.contains(bigPrime) { continue }
            for checkGroupId in stride(from: mergeGroupId - 1, through: 0, by: -1) {
              for smallPrime in primeHierarchy[nrOfElementGroups[checkGroupId]]! {
                if primesToRemove.contains(smallPrime) { continue }
                if primes[bigPrime]!.isSuperset(of: primes[smallPrime]!) {
                  couldDoRowReduction = true
                  primesToRemove.insert(smallPrime)
                }
              }
            }
          }
        }
      }
      let coveredTerms = termsToCover.keys.sorted()
      for prime in primesToRemove.elements {
        primes[prime] = nil
        for element in coveredTerms {
          // Java's List.remove(Object) drops the first occurrence only; a prime is listed at
          // most once per term, so this is the same thing.
          if let idx = termsToCover[element]!.firstIndex(where: { $0 == prime }) {
            termsToCover[element]!.remove(at: idx)
          }
        }
      }
    } while couldDoRowReduction || couldDoColumnReduction

    // It is possible that we still have multiple covers left. The minimal cover can be found
    // using Petrick's method: build the product-of-sums "which primes cover each remaining
    // term", multiply it out, absorb the non-minimal conjunctions, and pick the cheapest
    // remaining one.
    if !termsToCover.isEmpty {
      var simplificationExpression: [Set<ImplicantSet>] = []

      // Populate the sets in order to begin Petrick's method
      for term in termsToCover.keys.sorted() {
        var group = Set<ImplicantSet>()
        for impl in termsToCover[term]! { group.insert(ImplicantSet([impl])) }
        simplificationExpression.append(group)
      }

      // A term with no covering prime left would make the product empty; upstream then dies
      // in `Collections.min` on an empty set. Bail out with what we have instead.
      if simplificationExpression.contains(where: { $0.isEmpty }) { return essentialPrimes }

      repeat {
        var i = 0
        while i < simplificationExpression.count {
          let first = simplificationExpression[i]
          if i + 1 >= simplificationExpression.count { break }  // only one left, skip it
          let second = simplificationExpression.remove(at: i + 1)

          // If there are two elements left, then combine them
          var group = Set<ImplicantSet>()
          let sortedSecond = second.sorted()
          for firstConj in first.sorted() {
            for secondConj in sortedSecond {
              group.insert(firstConj.union(secondConj))
            }
          }
          simplificationExpression[i] = group
          i += 1
        }

        // After combining elements, apply reductions (absorption: X + XY = X)
        for gi in simplificationExpression.indices {
          let group = simplificationExpression[gi].sorted()
          var implGrpToRemove: [ImplicantSet] = []
          for conj1 in group {
            if implGrpToRemove.contains(conj1) { continue }
            for conj2 in group {
              if conj1 == conj2 || implGrpToRemove.contains(conj2) { continue }
              if conj2.isSuperset(of: conj1) {
                implGrpToRemove.append(conj2)
                continue
              }
              if conj1.isSuperset(of: conj2) {
                implGrpToRemove.append(conj1)
                break
              }
            }
          }
          if !implGrpToRemove.isEmpty {
            simplificationExpression[gi].subtract(implGrpToRemove)
          }
        }
      } while simplificationExpression.count > 1

      // Only one element can be left in the list here.
      let resGroup = simplificationExpression[0]

      var results: [Int: [ImplicantSet]] = [:]
      for grp in resGroup.sorted() { results[grp.count, default: []].append(grp) }
      guard let smallest = results.keys.min(), let minimumPrimes = results[smallest] else {
        return essentialPrimes
      }

      // Select the cheapest prime covers now, meaning the ones with the most total unknowns.
      var costMap: [Int: [ImplicantSet]] = [:]
      for cover in minimumPrimes {
        let unknown = cover.elements.reduce(0) { $0 + $1.unknownCount }
        costMap[unknown, default: []].append(cover)
      }
      guard let dearest = costMap.keys.max(), let cheapestCovers = costMap[dearest] else {
        return essentialPrimes
      }
      // Upstream takes `cheapestCovers.get(0)` out of a list built by iterating a HashSet,
      // i.e. an arbitrary one of the equally cheap minimal covers. Because every traversal
      // above is sorted, this is the lexicographically smallest such cover: an arbitrary
      // choice too, but the *same* arbitrary choice on every run.
      // TODO (upstream too): return all the minimal covers rather than one.
      essentialPrimes.append(contentsOf: cheapestCovers[0].elements)
    }

    return essentialPrimes
  }

  /// Java: `computePartition(AnalyzerModel)`; the minimal set of non-overlapping cubes that
  /// tile each region of equal output values. This is what backs "compact rows" in the table
  /// view, and, as upstream's own comment says, it is a greedy approximation: sort the prime
  /// implicants by generality and keep the non-overlapping ones.
  ///
  /// Returned sorted by `Implicant.<`, matching Java's `TreeMap`.
  static func computePartition(model: AnalyzerModel) -> [(Implicant, [Entry])] {
    let table = model.truthTable
    let maxval = (1 << table.inputColumnCount) - 1
    // Determine the set of regions and the first-cut implicants for each region.
    var regions: [[Entry]: ImplicantSet] = [:]
    for i in 0..<table.visibleRowCount {
      let val = table.visibleOutputEntries(row: i)
      let idx = table.visibleRowIndex(row: i)
      let dc = table.visibleRowDcMask(row: i)
      regions[val, default: ImplicantSet()].insert(Implicant(unknowns: dc, values: idx))
    }
    // For each region... (sorted, so the greedy pass below is reproducible)
    var ret: [(Implicant, [Entry])] = []
    for val in regions.keys.sorted(by: Implicant.entriesLess) {
      let base = regions[val]!

      // Work up to more general implicants.
      var all = ImplicantSet()
      var current = base
      while !current.isEmpty {
        var next = ImplicantSet()
        for implicant in current.elements {
          all.insert(implicant)
          var j = 1
          while j <= maxval {
            defer { j *= 2 }
            if (implicant.unknowns & j) != 0 { continue }
            let opp = Implicant(unknowns: implicant.unknowns, values: implicant.values ^ j)
            if !all.contains(opp) { continue }
            next.insert(Implicant(unknowns: opp.unknowns | j, values: opp.values))
          }
        }
        current = next
      }

      // Java sorts with a comparator that is *not* total: two implicants with the same
      // unknown count and the same base index tie, and `List.sort` is stable, so the winner
      // is decided by `new ArrayList<>(all)`, i.e. by HashSet order. `all` genuinely can
      // hold two such: merging produces cubes whose bits under `unknowns` differ, and
      // `Implicant.equals` calls those distinct. The tiebreak below makes the order total.
      let sorted = all.elements.sorted(by: Implicant.moreGeneralFirst)
      var chosen: [Implicant] = []
      for implicant in sorted where Implicant.disjoint(implicant, chosen) {
        chosen.append(implicant)
        ret.append((implicant, val))
      }
    }

    ret.sort { $0.0 < $1.0 }
    return ret
  }

  /// Java: `CompareGenerality`, plus a total tiebreak. See `computePartition`.
  static func moreGeneralFirst(_ i1: Implicant, _ i2: Implicant) -> Bool {
    let diff = i2.unknownCount - i1.unknownCount
    if diff != 0 { return diff < 0 }
    let base = (i1.values & ~i1.unknowns) - (i2.values & ~i2.unknowns)
    if base != 0 { return base < 0 }
    return i1 < i2
  }

  /// Java: `disjoint(Implicant, ArrayList<Implicant>)`.
  static func disjoint(_ imp: Implicant, _ chosen: [Implicant]) -> Bool {
    for other in chosen {
      let dc = imp.unknowns | other.unknowns
      if (imp.values & ~dc) == (other.values & ~dc) { return false }
    }
    return true
  }

  /// Region keys are output-value vectors; Java keys them by the description string and
  /// iterates a `HashMap`. Ordering them lexicographically keeps the greedy tiling
  /// reproducible.
  static func entriesLess(_ a: [Entry], _ b: [Entry]) -> Bool {
    for (x, y) in zip(a, b) {
      if x != y { return x.rawValue < y.rawValue }
    }
    return a.count < b.count
  }
}
