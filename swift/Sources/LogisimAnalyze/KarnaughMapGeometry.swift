//
//  KarnaughMapGeometry.swift: part of logisim-evolved.
//
//  Derived from logisim-evolution, specifically the `static` members of
//  `src/main/java/com/cburch/logisim/analyze/gui/KarnaughMapPanel.java`. GPL-3.0-only.
//  See LICENSE.md.
//

/// Where a truth-table row lands on a Karnaugh map.
///
/// Java keeps this on `analyze/gui/KarnaughMapPanel`, which is a `JPanel`. The rest of that
/// class is Swing and is NOT-PORTED (see `AnalyzeNotPorted.swift`), but these six members are
/// `static`, pure, and called from two non-GUI files, `data/KarnaughMapGroups` and
/// `file/AnalyzerTexWriter`, so they are lifted down here rather than dragging a `JPanel`
/// into the model layer.
public enum KarnaughMapGeometry {
  /// Java: `KarnaughMapPanel.MAX_VARS`. Past six inputs the panel refuses to draw a map at
  /// all, and both callers check this before asking for anything else.
  public static let maxVars = 6

  /// Java: `KarnaughMapPanel.ROW_VARS`: how many of the `n` inputs index the map's rows.
  /// Indexed by input count, so it is one longer than `maxVars`.
  public static let rowVars = [0, 0, 1, 1, 2, 2, 3]

  /// Java: `KarnaughMapPanel.COL_VARS`: how many index the columns.
  public static let colVars = [0, 1, 1, 2, 2, 3, 3]

  /// Java: `KarnaughMapPanel.bigColPlace`. The three-bit Gray-code permutation, used when a
  /// map axis carries more than two variables (8 cells rather than 4).
  private static let bigColPlace = [0, 1, 3, 2, 7, 6, 4, 5]

  /// Java: `KarnaughMapPanel.getCol(int tableRow, int rows, int cols)`.
  ///
  /// Note what upstream actually does: it Gray-codes `tableRow % cols`, but decides *which*
  /// permutation to use from `cols`, while `getRow`, given the same `bigColPlace` table,
  /// decides from `rows`. The 2/3 swap in the `else` branch is the two-bit Gray code written
  /// out by hand.
  public static func col(tableRow: Int, rows: Int, cols: Int) -> Int {
    let ret = tableRow % cols
    if cols > 4 { return bigColPlace[ret] }
    switch ret {
    case 2: return 3
    case 3: return 2
    default: return ret
    }
  }

  /// Java: `KarnaughMapPanel.getRow(int tableRow, int rows, int cols)`.
  ///
  /// Upstream indexes `bigColPlace`, the *column* table, here too. That is not a typo on
  /// this side: both axes use the same three-bit Gray permutation, and the array simply
  /// carries the column name. Reproduced as written.
  public static func row(tableRow: Int, rows: Int, cols: Int) -> Int {
    let ret = tableRow / cols
    if rows > 4 { return bigColPlace[ret] }
    switch ret {
    case 2: return 3
    case 3: return 2
    default: return ret
    }
  }
}
