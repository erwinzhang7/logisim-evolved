//
//  TruthTable.swift: part of logisim-evolved.
//
//  Derived from logisim-evolution, specifically
//  `src/main/java/com/cburch/logisim/analyze/model/TruthTable.java`,
//  `.../TruthTableEvent.java` and `.../TruthTableListener.java`. GPL-3.0-only. See LICENSE.md.
//

/// Java: `com.cburch.logisim.analyze.model.TruthTableEvent`.
public struct TruthTableEvent {
  public weak var source: TruthTable?
  public let column: Int
  public let data: VariableListEvent?

  public init(source: TruthTable?, column: Int, data: VariableListEvent? = nil) {
    self.source = source
    self.column = column
    self.data = data
  }
}

/// Java: `com.cburch.logisim.analyze.model.TruthTableListener`.
public protocol TruthTableListener: AnyObject {
  func rowsChanged(_ event: TruthTableEvent)
  func cellsChanged(_ event: TruthTableEvent)
  func structureChanged(_ event: TruthTableEvent)
}

/// Java: `com.cburch.logisim.analyze.model.TruthTable`.
///
/// **Storage cost, kept deliberately.** Each output column is a dense array of `2^n` cells,
/// `n = AnalyzerModel.MAX_INPUTS = 20`, so a fully populated column is 1,048,576 entries.
/// Java pays 8 MB per column for that (an `Entry[]` of references); the Swift `[Entry]` is
/// one byte per cell, so 1 MB. Columns stay **lazily allocated**; `nil` means "every cell is
/// the default `.dontCare`"; because the analyzer routinely has more declared outputs than
/// the user has actually filled in, and that laziness is what keeps a 20-input table opening
/// instantly. The semantics are unchanged from Java; only the constant factor is.
///
/// The *visible* rows are a separate, much smaller list of cubes (`Row`): the table shown to
/// the user merges adjacent rows into don't-care patterns, and `rows` is that partition.
public final class TruthTable {
  /// Java: `DEFAULT_ENTRY`.
  static let defaultEntry: Entry = .dontCare

  private var listeners: [WeakListenerBox<AnyObject>] = []
  /// D3: the model owns the table, so the back-edge is unowned.
  unowned let model: AnalyzerModel

  /// The last structural failure a *listener callback* hit, if any.
  ///
  /// Reshaping the table in response to a variable change can violate a row-merge invariant.
  /// Java throws `IllegalStateException` out of the Swing listener; a Swift protocol method
  /// cannot throw, so the failure is recorded here instead of vanishing. `nil` means the
  /// table has never been left inconsistent.
  public internal(set) var structuralFailure: AnalyzeError?

  /// Java: `rows`: the visible input rows, kept sorted by `baseIndex`.
  var rows: [Row] = []
  /// Java: `columns`: one dense `Entry[]` per output bit, created lazily.
  var columns: [[Entry]?] = []

  /// Java: `TruthTable.Row`: one visible row, i.e. a cube over the inputs.
  ///
  /// A `struct` rather than a class. Java relies on `ArrayList.remove(Object)` using
  /// `Object.equals`, i.e. identity, but the rows of a truth table are pairwise disjoint
  /// cubes, so no two distinct rows can ever have identical `inputs`: identity removal and
  /// structural removal pick the same element.
  struct Row: Equatable {
    /// Java: `final Entry[] inputs`.
    var inputs: [Entry]

    /// Java: `Row(int idx, int numInputs, int mask)`.
    init(idx: Int, numInputs: Int, mask: Int) {
      var idx = idx
      var mask = mask
      inputs = [Entry](repeating: .zero, count: numInputs)
      for i in stride(from: numInputs - 1, through: 0, by: -1) {
        inputs[i] = (mask & 1) == 0 ? ((idx & 1) == 0 ? .zero : .one) : .dontCare
        idx >>= 1
        mask >>= 1
      }
    }

    /// Java: `Row(Entry[] entries, int numInputs)`; takes the first `numInputs` cells.
    init(entries: [Entry], numInputs: Int) {
      inputs = Array(entries[0..<numInputs])
    }

    /// Java: `baseIndex()`.
    var baseIndex: Int {
      var idx = 0
      for input in inputs { idx = (idx << 1) | (input == .one ? 1 : 0) }
      return idx
    }

    /// Java: `dcMask()`.
    var dcMask: Int {
      var mask = 0
      for input in inputs { mask = (mask << 1) | (input == .dontCare ? 1 : 0) }
      return mask
    }

    /// Java: `duplicity()`: how many concrete input combinations this cube covers.
    var duplicity: Int {
      var count = 1
      for input in inputs where input == .dontCare { count *= 2 }
      return count
    }

    /// Java: `contains(int)`.
    func contains(_ idx: Int) -> Bool { (idx & ~dcMask) == baseIndex }

    /// Java: `contains(Row)`.
    func contains(_ other: Row) -> Bool {
      contains(other.baseIndex) && (other.dcMask & ~dcMask) == 0
    }

    /// Java: `intersects(Row)`.
    func intersects(_ other: Row) -> Bool {
      let dc = dcMask | other.dcMask
      return (other.baseIndex & ~dc) == (baseIndex & ~dc)
    }

    /// Java: `Row.iterator()`: every concrete row index this cube covers, in increasing
    /// order of the don't-care counter (not of the index itself).
    var indexes: [Int] {
      let base = baseIndex
      let mask = dcMask
      let nbits = inputs.count
      let count = duplicity
      var out: [Int] = []
      out.reserveCapacity(count)
      for iter in 0..<count {
        var add = iter
        var keep = 0
        for b in 0..<nbits {
          if (mask & (1 << b)) == 0 {
            add = ((add & ~keep) << 1) | (add & keep)
          }
          keep |= (1 << b)
        }
        out.append(base | add)
      }
      return out
    }

    /// Java: `toBitString(List<Var>)`.
    func toBitString(_ vars: [Var]) -> String {
      var s = ""
      var i = 0
      for variable in vars {
        s += " "
        for _ in 0..<variable.width {
          s += inputs[i].toBitString()
          i += 1
        }
      }
      return s
    }

    /// Java: `toString()`.
    var description: String {
      var s = "row["
      for (i, input) in inputs.enumerated() {
        if i != 0 { s += " " }
        s += input.description()
      }
      s += "]"
      s += " dup=\(duplicity)"
      s += " base=\(String(baseIndex, radix: 16)) dcmask=\(String(dcMask, radix: 16))"
      return s
    }
  }

  public init(model: AnalyzerModel) {
    self.model = model
    initRows()
    initColumns()
    model.inputs.addVariableListListener(self)
    model.outputs.addVariableListListener(self)
  }

  // MARK: - Shape

  /// Java: `getInputColumnCount()`.
  public var inputColumnCount: Int { model.inputs.bits.count }
  /// Java: `getOutputColumnCount()`.
  public var outputColumnCount: Int { model.outputs.bits.count }
  /// Java: `getRowCount()`: `2^inputs`, the dense row count.
  public var rowCount: Int { 1 << model.inputs.bits.count }
  /// Java: `getVisibleRowCount()`.
  public var visibleRowCount: Int { rows.count }

  /// Java: `getInputHeader(int)`.
  public func inputHeader(_ col: Int) -> String { model.inputs.bits[col] }
  /// Java: `getOutputHeader(int)`.
  public func outputHeader(_ col: Int) -> String { model.outputs.bits[col] }
  /// Java: `getInputIndex(String)`.
  public func inputIndex(of input: String) -> Int { model.inputs.bits.firstIndex(of: input) ?? -1 }
  /// Java: `getOutputIndex(String)`.
  public func outputIndex(of output: String) -> Int {
    model.outputs.bits.firstIndex(of: output) ?? -1
  }
  /// Java: `getInputVariables()`.
  public var inputVariables: [Var] { model.inputs.vars }
  /// Java: `getOutputVariables()`.
  public var outputVariables: [Var] { model.outputs.vars }
  /// Java: `getInputVariable(int)`.
  public func inputVariable(_ index: Int) -> Var { model.inputs.vars[index] }
  /// Java: `getOutputVariable(int)`.
  public func outputVariable(_ index: Int) -> Var { model.outputs.vars[index] }

  func initRows() {
    let inputs = inputColumnCount
    let n = rowCount
    rows.removeAll(keepingCapacity: true)
    rows.reserveCapacity(n)
    for i in 0..<n { rows.append(Row(idx: i, numInputs: inputs, mask: 0)) }
  }

  func initColumns() {
    columns = [[Entry]?](repeating: nil, count: outputColumnCount)
  }

  // MARK: - Reading

  /// Java: `getOutputEntry(int idx, int col)`: tolerant of out-of-range indices, which is
  /// how the GUI probes cells that do not exist yet.
  ///
  /// Java guards `idx < 0 || col < 0` but then indexes `columns.get(col)` unguarded, so a
  /// too-large column throws `IndexOutOfBoundsException` while a too-large row returns the
  /// default. The port answers the default in both directions; every in-tree caller derives
  /// `col` from `bits.indexOf`, so the difference is only reachable from a caller that was
  /// already asking about a column that does not exist.
  public func outputEntry(row idx: Int, column col: Int) -> Entry {
    if idx < 0 || col < 0 || col >= columns.count { return TruthTable.defaultEntry }
    guard let column = columns[col] else { return TruthTable.defaultEntry }
    return idx < column.count ? column[idx] : TruthTable.defaultEntry
  }

  /// Java: `getVisibleOutputEntry(int row, int col)`.
  public func visibleOutputEntry(row: Int, column col: Int) -> Entry {
    outputEntry(row: rows[row].baseIndex, column: col)
  }

  /// Java: `getVisibleInputEntry(int row, int col)`.
  public func visibleInputEntry(row: Int, column col: Int) -> Entry {
    rows[row].inputs[col]
  }

  /// Java: `getVisibleOutputs(int)`, but as entries rather than a string of description
  /// characters.
  ///
  /// Upstream round-trips this through `Entry.parse(String)` in `compactVisibleRows`, and
  /// that round trip is **lossy**: `parse` returns `null` for `'@'` (`OSCILLATE_ERROR`) and
  /// for the unknown character, so a table holding an oscillation error gets `null` written
  /// into its column and NPEs on the next read. Keeping entries as entries removes the
  /// hazard without changing any behaviour that upstream gets right.
  public func visibleOutputEntries(row: Int) -> [Entry] {
    let idx = rows[row].baseIndex
    return columns.map { $0 == nil ? TruthTable.defaultEntry : $0![idx] }
  }

  /// Java: `getVisibleOutputs(int)`, the display string.
  public func visibleOutputs(row: Int, chars: EntryCharacters = .standard) -> String {
    visibleOutputEntries(row: row).map { $0.description(chars: chars) }.joined()
  }

  /// Java: `getVisibleRowDcMask(int)`.
  public func visibleRowDcMask(row: Int) -> Int { rows[row].dcMask }
  /// Java: `getVisibleRowIndex(int)`.
  public func visibleRowIndex(row: Int) -> Int { rows[row].baseIndex }
  /// Java: `getVisibleRowIndexes(int)`.
  public func visibleRowIndexes(row: Int) -> [Int] { rows[row].indexes }

  /// Java: `getInputEntry(int idx, int col)`.
  public func inputEntry(row idx: Int, column col: Int) throws -> Entry {
    if idx < 0 || idx >= rowCount { throw AnalyzeError.indexOutOfBounds("row index") }
    let inputs = inputColumnCount
    if col < 0 || col >= inputs { throw AnalyzeError.indexOutOfBounds("input column index") }
    return TruthTable.isInputSet(row: idx, column: col, inputs: inputs) ? .one : .zero
  }

  /// Java: `isInputSet(int idx, int col, int inputs)`; column 0 is the *most* significant
  /// bit of the row index.
  public static func isInputSet(row idx: Int, column col: Int, inputs: Int) -> Bool {
    (idx & (1 << (inputs - col - 1))) != 0
  }

  /// Java: `getOutputColumn(int)`, materialises the lazy column.
  @discardableResult
  public func outputColumn(_ col: Int) throws -> [Entry] {
    if col < 0 || col >= outputColumnCount {
      throw AnalyzeError.indexOutOfBounds("output column index")
    }
    ensureColumn(col)
    return columns[col]!
  }

  /// Whether a column has been materialised. Java tests `columns.get(col) == null`.
  func isColumnAllocated(_ col: Int) -> Bool { columns[col] != nil }

  /// Materialise `col` and return a direct index for mutation, mirroring Java's habit of
  /// holding the `Entry[]` and writing through it.
  private func ensureColumn(_ col: Int) {
    if columns[col] == nil {
      columns[col] = [Entry](repeating: TruthTable.defaultEntry, count: rowCount)
    }
  }

  // MARK: - Writing

  /// Java: `setOutputColumn(int col, Entry[] values)`.
  public func setOutputColumn(_ col: Int, _ values: [Entry]) throws {
    if values.count != rowCount {
      throw AnalyzeError.badColumnLength(expected: rowCount, actual: values.count)
    }
    // Java early-returns when `columns.set` hands back the *same array reference*, which no
    // caller ever arranges (every one passes a freshly allocated column). Swift arrays have
    // no identity, so testing content here would suppress the `cellsChanged` event upstream
    // always fires; the store just proceeds.
    columns[col] = values
    // Expand rows as dictated by column inconsistencies.
    //
    // Divergence, deliberate: upstream re-splits the *same stale `Row` object* on every pass
    // of its `while (split)` loop. The first `splitRow` removes that row from `rows`, so the
    // second pass finds the same offending index, calls `splitRow` again, and dies on
    // `IllegalStateException("unexpected row split")` when the halves are already present:
    // reachable by setting an expression on a compacted table. Here the walk continues from
    // whichever half still holds `base`, which is the evident intent and terminates: each
    // split halves the row's duplicity.
    var rowsChanged = false
    let bases = rows.map { $0.baseIndex }
    for base in bases.reversed() {
      let v = values[base]
      var split = true
      while split {
        split = false
        guard let r = rows.first(where: { $0.contains(base) }) else { break }
        for idx in r.indexes where v != values[idx] {
          try splitRow(r, at: idx)
          rowsChanged = true
          split = true
          break
        }
      }
    }
    if rowsChanged { fireRowsChanged() }
    fireCellsChanged(col)
  }

  /// Java: `setOutputEntry(int idx, int col, Entry value)`.
  public func setOutputEntry(row idx: Int, column col: Int, _ value: Entry) throws {
    if columns[col] == nil && value == TruthTable.defaultEntry { return }
    ensureColumn(col)
    if columns[col]![idx] == value { return }
    columns[col]![idx] = value
    let r = try findRow(idx)
    if r.duplicity > 1 {
      try splitRow(r, at: idx)
      fireRowsChanged()
    }
    fireCellsChanged(col)
  }

  /// Java: `setVisibleOutputEntry(int row, int col, Entry value)`.
  public func setVisibleOutputEntry(row: Int, column col: Int, _ value: Entry) {
    let r = rows[row]
    if columns[col] == nil && value == TruthTable.defaultEntry { return }
    ensureColumn(col)
    var changed = false
    for idx in r.indexes where columns[col]![idx] != value {
      changed = true
      columns[col]![idx] = value
    }
    if changed { fireCellsChanged(col) }
  }

  /// Java: `setVisibleInputEntry(int row, int col, Entry value, boolean force)`.
  @discardableResult
  public func setVisibleInputEntry(
    row: Int, column col: Int, _ value: Entry, force: Bool
  ) throws -> Bool {
    let r = rows[row]
    if r.inputs[col] == value { return false }
    let dc = 1 << (r.inputs.count - 1 - col)
    switch value {
    case .dontCare:
      var changed = [Bool](repeating: false, count: columns.count)
      if try !setDontCare(r, dc, force: force, changed: &changed) { return false }
      fireRowsChanged()
      for ocol in changed.indices where changed[ocol] { fireCellsChanged(ocol) }
      return true
    case .one, .zero:
      if r.inputs[col] != .dontCare { return false }
      try splitRow(r, at: r.baseIndex | dc)
      fireRowsChanged()
      return true
    default:
      throw AnalyzeError.invalidInputEntry
    }
  }

  /// Java: `setVisibleRows(List<Entry[]>, boolean force)`; used by the table importer and
  /// by paste.
  public func setVisibleRows(_ newEntries: [[Entry]], force: Bool) throws {
    let ni = inputColumnCount
    let no = outputColumnCount
    var newRows: [Row] = []
    newRows.reserveCapacity(newEntries.count)
    for values in newEntries {
      if values.count != ni + no { throw AnalyzeError.inconsistentRows("wrong column count") }
      newRows.append(Row(entries: values, numInputs: ni))
    }
    // check that newRows has no intersections
    let ivars = inputVariables
    var taken = [Int](repeating: 0, count: rowCount)
    for i in newRows.indices {
      let r = newRows[i]
      for idx in r.indexes {
        if taken[idx] != 0 && !force {
          let existingValues = newEntries[taken[idx] - 1]
          let currentValues = newEntries[i]
          for col in 0..<no {
            let existingValue = existingValues[ni + col]
            let currentValue = currentValues[ni + col]
            if existingValue != .dontCare && currentValue != .dontCare
              && currentValue != existingValue
            {
              throw AnalyzeError.inconsistentRows(
                "Some inputs are repeated. For example, rows \(taken[idx]) and \(i + 1) have "
                  + "overlapping input values \(newRows[taken[idx] - 1].toBitString(ivars)) and "
                  + "\(r.toBitString(ivars)).")
            }
          }
        } else if taken[idx] != 0 {
          throw AnalyzeError.inconsistentRows(
            "Sorry, this error can't yet be fixed. Eliminate duplicate rows then try again.")
        } else {
          taken[idx] = i + 1
        }
      }
    }
    // check that newRows covers all possible cases
    for i in 0..<rowCount where taken[i] == 0 {
      if !force {
        throw AnalyzeError.inconsistentRows(
          "Some inputs are missing. For example, there is no row for input "
            + "\(Row(idx: i, numInputs: ni, mask: 0).toBitString(ivars)).")
      }
      newRows.append(Row(idx: i, numInputs: ni, mask: 0))
    }

    newRows.sort { $0.baseIndex < $1.baseIndex }
    rows = newRows
    initColumns()

    for values in newEntries {
      let r = Row(entries: values, numInputs: ni)
      for col in 0..<no {
        let value = values[ni + col]
        if columns[col] == nil && value == TruthTable.defaultEntry { continue }
        ensureColumn(col)
        for idx in r.indexes { columns[col]![idx] = value }
      }
    }
    fireRowsChanged()
    for col in 0..<no where columns[col] != nil { fireCellsChanged(col) }
  }

  // MARK: - Row partition maintenance

  /// Java: `expandVisibleRows()`.
  public func expandVisibleRows() {
    if visibleRowCount == rowCount { return }
    initRows()
    fireRowsChanged()
  }

  /// Java: `compactVisibleRows()`: re-derives the visible partition from the output values
  /// via `Implicant.computePartition`.
  public func compactVisibleRows() {
    let partition = Implicant.computePartition(model: model)
    rows.removeAll(keepingCapacity: true)
    initColumns()
    let ni = inputColumnCount
    let no = outputColumnCount
    for (imp, val) in partition {
      let r = Row(idx: imp.values, numInputs: ni, mask: imp.unknowns)
      rows.append(r)
      for col in 0..<no {
        let value = val[col]
        if columns[col] == nil && value == TruthTable.defaultEntry { continue }
        ensureColumn(col)
        for idx in r.indexes { columns[col]![idx] = value }
      }
    }
    fireRowsChanged()
    for col in 0..<no where columns[col] != nil { fireCellsChanged(col) }
  }

  /// Java: `splitRow(Row r, int idx)`.
  func splitRow(_ r: Row, at idx: Int) throws {
    let base = r.baseIndex
    if idx == base || !r.contains(idx) { throw AnalyzeError.rowStructure("bad row split") }
    let diff = idx ^ base
    let n = r.duplicity
    if n <= 1 { throw AnalyzeError.rowStructure("row duplicity should be at least 2") }
    let splits = Row(idx: base, numInputs: r.inputs.count, mask: diff)
    var m = 0
    if let pos = rows.firstIndex(of: r) { rows.remove(at: pos) }
    for other in splits.indexes {
      let s = Row(idx: other, numInputs: r.inputs.count, mask: r.dcMask & ~diff)
      m += s.duplicity
      let pos = binarySearchByBaseIndex(s)
      if pos < 0 {
        rows.insert(s, at: -pos - 1)
      } else {
        throw AnalyzeError.rowStructure("unexpected row split")
      }
    }
    if m != n { throw AnalyzeError.rowStructure("assertion failed in row split") }
  }

  /// Java: `findRow(int)`.
  func findRow(_ idx: Int) throws -> Row {
    for i in stride(from: rows.count - 1, through: 0, by: -1) where rows[i].contains(idx) {
      return rows[i]
    }
    throw AnalyzeError.rowStructure("missing row")
  }

  /// Java: `findVisibleRowContaining(int)`.
  public func findVisibleRowContaining(_ idx: Int) throws -> Int {
    for i in stride(from: rows.count - 1, through: 0, by: -1) where rows[i].contains(idx) {
      return i
    }
    throw AnalyzeError.rowStructure("missing row")
  }

  /// Java: `Collections.binarySearch(rows, s, sortByInputs)`; returns the index if present,
  /// otherwise `-(insertionPoint) - 1`, exactly as `java.util.Collections` does.
  private func binarySearchByBaseIndex(_ s: Row) -> Int {
    var lo = 0
    var hi = rows.count - 1
    let key = s.baseIndex
    while lo <= hi {
      let mid = (lo + hi) >> 1
      let cmp = rows[mid].baseIndex - key
      if cmp < 0 {
        lo = mid + 1
      } else if cmp > 0 {
        hi = mid - 1
      } else {
        return mid
      }
    }
    return -(lo + 1)
  }

  /// Java: `identicalOutputs(int, int)`.
  private func identicalOutputs(_ idx1: Int, _ idx2: Int) -> Bool {
    if idx1 == idx2 { return true }
    for column in columns {
      guard let column else { continue }
      if column[idx1] != column[idx2] { return false }
    }
    return true
  }

  /// Java: `mergeOutputs(int, int, boolean[])`.
  private func mergeOutputs(_ idx1: Int, _ idx2: Int, _ changed: inout [Bool]) {
    if idx1 == idx2 { return }
    for col in columns.indices {
      guard columns[col] != nil else { continue }
      if columns[col]![idx1] != columns[col]![idx2] {
        columns[col]![idx2] = columns[col]![idx1]
        changed[col] = true
      }
    }
  }

  /// Java: `setDontCare(Row r, int dc, boolean force, boolean[] changed)`.
  @discardableResult
  func setDontCare(
    _ r: Row, _ dc: Int, force: Bool, changed: inout [Bool]
  ) throws -> Bool {
    let newRow = Row(idx: r.baseIndex, numInputs: r.inputs.count, mask: r.dcMask | dc)
    let base = newRow.baseIndex
    if !force {
      for idx in newRow.indexes where !identicalOutputs(base, idx) { return false }
    }
    var i = 0
    while i < rows.count {
      let row = rows[i]
      if !newRow.intersects(row) {
        i += 1
        continue
      }
      if newRow.contains(row) {
        for idx in row.indexes { mergeOutputs(base, idx, &changed) }
        rows.remove(at: i)
      } else {
        // find a bit we can flip in s so it doesn't conflict
        var pos = row.inputs.count - 1
        while pos >= 0 {
          if row.inputs[pos] == .dontCare && newRow.inputs[pos] != .dontCare { break }
          pos -= 1
        }
        if pos < 0 { throw AnalyzeError.rowStructure("failed row merge") }
        let bit = 1 << (row.inputs.count - 1 - pos)
        try splitRow(row, at: row.baseIndex ^ bit)
      }
      // Java does `i--` then the for-loop's `i++`: stay on the same index, because the split
      // may need repeating.
    }
    let pos = binarySearchByBaseIndex(newRow)
    if pos < 0 {
      rows.insert(newRow, at: -pos - 1)
    } else {
      throw AnalyzeError.rowStructure("failed row merge")
    }
    return true
  }

  // MARK: - Listeners

  public func addTruthTableListener(_ l: TruthTableListener) {
    listeners.append(WeakListenerBox(l))
  }

  public func removeTruthTableListener(_ l: TruthTableListener) {
    listeners.removeAll { $0.value === l || $0.value == nil }
  }

  private func liveListeners() -> [TruthTableListener] {
    listeners.removeAll { $0.value == nil }
    return listeners.compactMap { $0.value as? TruthTableListener }
  }

  func fireRowsChanged() {
    let event = TruthTableEvent(source: self, column: 0)
    for l in liveListeners() { l.rowsChanged(event) }
  }

  func fireCellsChanged(_ col: Int) {
    let event = TruthTableEvent(source: self, column: col)
    for l in liveListeners() { l.cellsChanged(event) }
  }

  func fireStructureChanged(_ cause: VariableListEvent) {
    let event = TruthTableEvent(source: self, column: 0, data: cause)
    for l in liveListeners() { l.structureChanged(event) }
  }
}
