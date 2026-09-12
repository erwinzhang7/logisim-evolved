//
//  KarnaughMapGroups.swift: part of logisim-evolved.
//
//  Derived from logisim-evolution, specifically
//  `src/main/java/com/cburch/logisim/analyze/data/KarnaughMapGroups.java`. GPL-3.0-only.
//  See LICENSE.md.
//

/// Java: `com.cburch.logisim.analyze.data.KarnaughMapGroups`: turns the minimal cover of one
/// output into rectangles on the Karnaugh map, one group per prime implicant.
///
/// This is the model half. `paint(Graphics2D, …)` and `getBackgroundColor()` are NOT-PORTED
/// (D9): they only translate the rectangles below into `fillRoundRect` calls with the group's
/// colour at 128 or 180 alpha, and the UI can do that from `areas` and `colorIndex`. The
/// `IMP_RADIUS`/`IMP_INSET` constants those methods use are carried as
/// ``cornerRadius``/``inset`` so the UI does not have to re-derive them.
///
/// Ownership (D3): `model` is `unowned`, matching the rest of the analyze graph.
public final class KarnaughMapGroups {
  /// Java: `IMP_RADIUS`; half the `arcWidth` passed to `fillRoundRect`.
  public static let cornerRadius = 5
  /// Java: `IMP_INSET`; the pixel gap left around a group inside its cells.
  public static let inset = 4

  /// Java: `KarnaughMapGroups.CoverInfo`; one axis-aligned rectangle of map cells.
  ///
  /// A single prime implicant can need more than one of these: on a K-map a term that wraps
  /// around an edge shows up as two disjoint rectangles.
  public struct CoverInfo: Equatable {
    /// Java: `startCol`, `getCol()`.
    public let col: Int
    /// Java: `startRow`, `getRow()`.
    public let row: Int
    /// Java: `getWidth()`, in cells.
    public private(set) var width: Int
    /// Java: `getHeight()`, in cells.
    public private(set) var height: Int

    public init(col: Int, row: Int) {
      self.col = col
      self.row = row
      self.width = 1
      self.height = 1
    }

    /// Java: `canMerge(int, int)`. The comment upstream is load-bearing; this is only
    /// correct because ``KMapGroupInfo/build(_:)`` scans strictly left-to-right, top-down,
    /// so a candidate cell can only ever extend a rectangle by one column or one row.
    private func canMerge(col: Int, row: Int) -> Bool {
      if col >= self.col && col < self.col + width {
        // Same column range. Either the same rows...
        if row >= self.row && row < self.row + height { return true }
        // ...or exactly one row below.
        return row >= self.row && row <= self.row + height
      }
      if row >= self.row && row < self.row + height {
        // Same row range, so this can only be one column to the right; the "same columns
        // too" case was already answered by the branch above.
        return col >= self.col && col <= self.col + width
      }
      return false
    }

    /// Java: `merge(int, int)`. Returns whether the cell was absorbed, growing the rectangle
    /// if it had to.
    public mutating func merge(col: Int, row: Int) -> Bool {
      guard canMerge(col: col, row: row) else { return false }
      if col >= self.col && col < self.col + width {
        if row >= self.row && row < self.row + height {
          return true  // already inside
        }
        height += 1  // one row down
      } else {
        width += 1  // one column right
      }
      return true
    }
  }

  /// Java: `KarnaughMapGroups.KMapGroupInfo`: one prime implicant, as drawn.
  ///
  /// Java makes this a *non-static* inner class so that `addSingleCover` can reach the
  /// enclosing `covers` list and steal an implicant from whichever earlier group already
  /// claimed it. That mutation-during-construction cannot be expressed by a Swift initialiser
  /// without handing it the list, so the loop lives in ``KarnaughMapGroups/rebuild()`` and
  /// this type is a plain struct. The resulting group list is identical.
  public struct KMapGroupInfo {
    /// Java: `getAreas()`.
    public internal(set) var areas: [CoverInfo] = []
    /// Java: `getColor()`, as a `CoverColor` palette index (D9, see `CoverColor.swift`).
    public let colorIndex: Int
    /// Java: `singleCoveredImplicants`; the minterms this group is the *sole* owner of.
    /// Used by `insideCover`, i.e. by hit-testing, so exactly one group highlights when the
    /// pointer is over a cell that several covers overlap.
    public internal(set) var singleCoveredImplicants: [Implicant] = []
    /// Java: `expression`: this one implicant rendered on its own, shown when the group is
    /// highlighted.
    public let expression: Expression?

    /// Java: `containsSingleCover(Implicant)`.
    public func containsSingleCover(_ implicant: Implicant) -> Bool {
      singleCoveredImplicants.contains(implicant)
    }
  }

  private unowned let model: AnalyzerModel
  private var output: String?
  private var format: Int = AnalyzerModel.formatSumOfProducts

  /// Java: `CoverColor.COVER_COLOR`, the process-wide singleton, rotated by `update()`.
  ///
  /// **This one is per-instance, and that is observationally identical.** `update()` calls
  /// `reset()` before its first `getNext()` and then consumes slots strictly in order, so the
  /// colour a group receives is a pure function of its position in the cover list: the
  /// shared cursor contributes nothing to the result. The singleton's other two callers
  /// (`AnalyzerTexWriter`'s `\definecolor` preamble and its `getColorName` lookups) only read
  /// the palette and never advance it.
  ///
  /// What it *does* remove is a hazard Java does not have to think about: upstream's two
  /// `KarnaughMapGroups` users both run on the EDT, so the shared cursor is never touched
  /// from two threads. Nothing in this module is pinned to a thread, and a global rotation
  /// cursor is exactly the kind of state that produces a wrong colour once and never again.
  /// `CoverColor.shared` still exists for API parity; nothing here rotates it.
  private let colors = CoverColor()

  /// Java: `getCovers()`.
  ///
  /// Java leaves this `null` until the first `setOutput`/`setformat`, and
  /// `AnalyzerTexWriter.getCovers` would NPE if it iterated one that had not been set. An
  /// empty array is the honest Swift equivalent and reaches the same output.
  public private(set) var covers: [KMapGroupInfo] = []

  /// Java: `highlighted`, `-1` for none.
  public private(set) var highlighted: Int = -1

  public init(model: AnalyzerModel) {
    self.model = model
  }

  /// Java: `setformat(int)`: note the lowercase `f` upstream.
  public func setFormat(_ format: Int) {
    self.format = format
    rebuild()
  }

  /// Java: `setOutput(String)`.
  public func setOutput(_ name: String?) {
    output = name
    rebuild()
  }

  /// Java: `highlight(int col, int row)`. Returns whether the highlight actually moved, which
  /// is what upstream uses to decide whether a repaint is needed.
  public func highlight(col: Int, row: Int) -> Bool {
    let previous = highlighted
    highlighted = -1
    var index = 0
    while index < covers.count && highlighted < 0 {
      if insideCover(covers[index], col: col, row: row) { highlighted = index }
      index += 1
    }
    return previous != highlighted
  }

  /// Java: `clearHighlight()`.
  @discardableResult
  public func clearHighlight() -> Bool {
    let wasHighlighted = highlighted >= 0
    highlighted = -1
    return wasHighlighted
  }

  /// Java: `getHighlightedExpression()`.
  public var highlightedExpression: Expression? {
    guard highlighted >= 0 && highlighted < covers.count else { return nil }
    return covers[highlighted].expression
  }

  /// Java: `getBackgroundColor()` returns the highlighted group's colour at alpha 60. D9 says
  /// the colour does not cross this boundary, so only the index does; the alpha is the UI's.
  public var highlightedColorIndex: Int? {
    guard highlighted >= 0 && highlighted < covers.count else { return nil }
    return covers[highlighted].colorIndex
  }

  /// Java: `KMapGroupInfo.insideCover(int, int)`.
  ///
  /// Reproduces one upstream quirk exactly: the loop `return`s `false` on the first
  /// solely-covered implicant whose `getRow()` is negative, rather than skipping it. A
  /// negative row means the implicant still has don't-cares in it, which cannot happen for a
  /// member of `getTerms()`, so the branch is unreachable, but it is reproduced rather than
  /// tidied, because "unreachable" here rests on `getTerms`'s behaviour and not on anything
  /// local.
  private func insideCover(_ group: KMapGroupInfo, col: Int, row: Int) -> Bool {
    let table = model.truthTable
    let inputCount = table.inputColumnCount
    guard inputCount <= KarnaughMapGeometry.maxVars else { return false }
    let kmapRows = 1 << KarnaughMapGeometry.rowVars[inputCount]
    let kmapCols = 1 << KarnaughMapGeometry.colVars[inputCount]
    for square in group.singleCoveredImplicants {
      let tableRow = square.row
      if tableRow < 0 { return false }
      let mappedRow = KarnaughMapGeometry.row(tableRow: tableRow, rows: kmapRows, cols: kmapCols)
      let mappedCol = KarnaughMapGeometry.col(tableRow: tableRow, rows: kmapRows, cols: kmapCols)
      if mappedRow == row && mappedCol == col { return true }
    }
    return false
  }

  /// Java: `update()`.
  ///
  /// Cover *order* is the order `OutputExpressions.getMinimalImplicants` returns, and the
  /// colour rotation is keyed off that order, so a change in minimisation ordering shows up
  /// here as covers changing colour. That is one more reason the minimisation golden set
  /// compares implicant order and not just the set.
  public func rebuild() {
    let implicants = model.outputExpressions.minimalImplicants(for: output)
    covers = []
    colors.reset()
    for implicant in implicants {
      covers.append(makeGroup(implicant, colorIndex: colors.next()))
    }
    highlighted = -1
  }

  /// Java: the `KMapGroupInfo(Implicant, Color)` constructor plus `build(Implicant)`.
  private func makeGroup(_ implicant: Implicant, colorIndex: Int) -> KMapGroupInfo {
    var group = KMapGroupInfo(
      colorIndex: colorIndex,
      expression: Implicant.toExpression(format: format, model: model, implicants: [implicant])
    )

    let table = model.truthTable
    let inputCount = table.inputColumnCount
    guard inputCount <= KarnaughMapGeometry.maxVars else { return group }
    let kmapRows = 1 << KarnaughMapGeometry.rowVars[inputCount]
    let kmapCols = 1 << KarnaughMapGeometry.colVars[inputCount]

    var occupied = [[Bool]](repeating: [Bool](repeating: false, count: kmapCols), count: kmapRows)
    for square in implicant.terms {
      // Java's addSingleCover: a minterm covered by several groups belongs to the LAST one
      // to claim it, because claiming removes it from every earlier group. Upstream notes
      // this is a choice, not a requirement.
      for other in covers.indices {
        covers[other].singleCoveredImplicants.removeAll { $0 == square }
      }
      group.singleCoveredImplicants.append(square)

      let tableRow = square.row
      // Upstream `return`s out of build() here, abandoning the half-built group rather than
      // skipping the term. Reproduced; see insideCover for why it is unreachable.
      if tableRow < 0 { return group }
      let row = KarnaughMapGeometry.row(tableRow: tableRow, rows: kmapRows, cols: kmapCols)
      let col = KarnaughMapGeometry.col(tableRow: tableRow, rows: kmapRows, cols: kmapCols)
      if row < kmapRows && col < kmapCols { occupied[row][col] = true }
    }

    // The scan that grows rectangles. `current` is the rectangle the previous cell extended;
    // `areas` holds the ones already closed off. Java keeps `current` as a reference into
    // `areas`, so growing it after it has been added mutates the stored one, with a value
    // type that has to be an index instead.
    var areas: [CoverInfo] = []
    var current: CoverInfo?
    var currentIndexInAreas: Int?

    // Writes `current` back into `areas` if it is a stored rectangle, mirroring Java's
    // aliasing.
    func flushCurrent() {
      if let index = currentIndexInAreas, let value = current { areas[index] = value }
    }

    for row in 0..<kmapRows {
      for col in 0..<kmapCols {
        if occupied[row][col] {
          if current != nil {
            if current!.merge(col: col, row: row) {
              flushCurrent()
              continue
            }
            // Java: `if (!areas.contains(current)) areas.add(current)`.
            if currentIndexInAreas == nil {
              areas.append(current!)
              currentIndexInAreas = areas.count - 1
            }
          }
          // Can an already-closed rectangle take this cell?
          var found = false
          for index in areas.indices where !found {
            if areas[index].merge(col: col, row: row) {
              current = areas[index]
              currentIndexInAreas = index
              found = true
            }
          }
          if !found {
            current = CoverInfo(col: col, row: row)
            currentIndexInAreas = nil
          }
        } else {
          if let value = current, currentIndexInAreas == nil {
            areas.append(value)
          }
          current = nil
          currentIndexInAreas = nil
        }
      }
    }
    if let value = current, currentIndexInAreas == nil {
      areas.append(value)
    }

    group.areas = areas
    return group
  }
}
