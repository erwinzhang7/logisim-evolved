//
//  AnalyzeNotPorted.swift: part of logisim-evolved.
//
//  Derived from logisim-evolution, specifically the `com.cburch.logisim.analyze` package.
//  GPL-3.0-only. See LICENSE.md.
//

// NOT-PORTED (D9); `analyze/gui/*` is Swing and belongs above this module.
//
// The 20 files below are all `javax.swing` subclasses or their direct helpers: they build
// `JPanel`/`JTable`/`JDialog` hierarchies, install `MouseListener`s, and paint through
// `Graphics2D`. None of them holds model state that anything in this module needs, with the
// two exceptions called out at the end. The list is exhaustive against 4.1.0 so that a later
// reader can tell "deliberately excluded" from "forgotten":
//
//   analyze/gui/Analyzer.java              analyze/gui/ImportTableButton.java
//   analyze/gui/AnalyzerManager.java       analyze/gui/KarnaughMapPanel.java
//   analyze/gui/AnalyzerMenuListener.java  analyze/gui/MinimizeButton.java
//   analyze/gui/AnalyzerTab.java           analyze/gui/MinimizedTab.java
//   analyze/gui/BuildCircuitButton.java    analyze/gui/OutputSelector.java
//   analyze/gui/CsvReadParameterDialog.java analyze/gui/TabInterface.java
//   analyze/gui/ExportLatexButton.java     analyze/gui/TableTab.java
//   analyze/gui/ExportTableButton.java     analyze/gui/TableTabCaret.java
//   analyze/gui/ExpressionTab.java         analyze/gui/TableTabClip.java
//   analyze/gui/ExpressionView.java        analyze/gui/VariableTab.java
//
// Two of them carry pure model logic that the non-GUI code genuinely depends on, so that
// logic, and only that logic, was lifted down into this module:
//
//   - `KarnaughMapPanel`'s `MAX_VARS`, `ROW_VARS`, `COL_VARS`, `bigColPlace`, `getRow(int,
//     int, int)` and `getCol(int, int, int)` are `static` constants and pure functions with
//     no Swing in them, yet `data/KarnaughMapGroups` and `file/AnalyzerTexWriter` both call
//     them. They are in `KarnaughMapGeometry.swift`. Everything else in that 1,000-line
//     class, layout, painting, mouse handling, the tooltip, is not ported.
//   - `VariableTab.checkindex(String)` parses a `[msb..lsb]` suffix and is called by
//     `data/CsvInterpretor`. It is in `AnalyzeSyntaxChecker.swift` as
//     `BitRangeParse.checkIndex`. The rest of `VariableTab` is not ported.
//
// NOT-PORTED (D9): three more non-`gui` files, for the same reason:
//
//   - `analyze/data/ExpressionRenderData.java`. It measures text with `FontMetrics`, breaks
//     it into lines against a pixel width, builds `AttributedString`s and paints them into a
//     `Graphics`. It also reads `AppPreferences`. The model-side half of it, where the
//     overbars, subscripts and mark spans fall, already comes across as
//     `Expression.Rendering` in `ExpressionRendering.swift`; the layout half is UI.
//   - `analyze/file/TruthtableFileFilter.java`. It is a `javax.swing.filechooser.FileFilter`
//     for an `NSOpenPanel`-equivalent. The extensions it filters on are carried here as
//     `TruthtableTextFile.fileExtension`, `TruthtableCsvFile.fileExtension` and
//     `AnalyzerTexWriter.fileExtension` so the UI can build its own panel without
//     re-deriving them.
//   - `analyze/data/CoverColor.java`'s *colours*. The rotation it performs is model
//     behaviour and is ported (`CoverColor.swift`); the 16 `java.awt.Color` values it hands
//     out are not, because D9 forbids a colour crossing this boundary. `CoverColor` vends
//     the palette **index** instead, exactly as `Value.getColor()` does in the kernel.
//     Its `preferenceChange(PreferenceChangeEvent)` goes with them: it exists only to swap
//     one `java.awt.Color` for another when a `KMAP*_COLOR` preference changes, and a UI that
//     owns the palette re-reads it without help from here.
//
// NOT-PORTED (D9): two members of otherwise-ported model classes, both of which exist only
// to reach something that lives above this module:
//
//   - `model/Entry`'s `EntryChangedListener`, `addListener`, `removeListener`, `fireChange`
//     and `preferenceChange`. Every `Entry` singleton upstream registers itself with
//     `AppPreferences.getPrefs()` so that a table repaints when the user changes the
//     character that displays a 0, a 1 or a don't-care. The *characters* are model-visible
//     and do come across, as `EntryCharacters`, passed in by the caller; the change
//     notification is a repaint trigger and belongs to whoever owns the preference. Note
//     this also removes a permanent registration on a process-global preference object:
//     five singletons that upstream never unregisters.
//   - `model/AnalyzerModel`'s `currentProject` / `currentCircuit` and their accessors. They
//     are a `com.cburch.logisim.proj.Project` and a `.circuit.Circuit`, held so that the
//     "build circuit" action knows where to put its result, and read by exactly two callers:
//     `gui/BuildCircuitButton` and `file/TruthtableTextFile`'s `tableRemark2` line. The
//     latter's seam is `TruthtableTextFile.text(for:circuitName:)`.
//
// ─────────────────────────────────────────────────────────────────────────────────────────────
// WHAT THE gui/ EXCLUSIONS COST A USER; measured 2026-09-06
// ─────────────────────────────────────────────────────────────────────────────────────────────
//
// The list above is a *file* ledger, and a file ledger cannot show a capability that went
// missing with a file. Measuring the other direction, which public API in this module no
// production code can reach, does show it. Of 254 public declarations here, 15 have no caller
// anywhere in `Sources/` outside this module; every one traces to a `gui/` file, and they fall
// into four groups.
//
// (The 15 is a floor, not a total. The measurement matched *bare* declaration names, so a name
// that any other module also uses is invisible to it; `Parser.parse` is exactly that case, and
// had to be confirmed separately by qualified grep. Read "15" as "at least 15".)
//
//   * Truth-table editing: `TruthTable.setOutputEntry`, `setVisibleOutputEntry`,
//     `setVisibleInputEntry`, `expandVisibleRows`, `visibleRowIndexes`
//     (upstream: `TableTabCaret`, `TableTab`). Recorded: `AnalyzerWindow.swift`, "Editing".
//   * The Karnaugh map: `KarnaughMapGroups.clearHighlight`, `highlightedExpression`,
//     `highlightedColorIndex` (upstream: `KarnaughMapPanel`).
//     Recorded: `AnalyzerWindow.swift`, "The Karnaugh map".
//   * LaTeX export; the whole `AnalyzerTexWriter` type (upstream: `ExportLatexButton`).
//     Recorded: `AnalyzerWindow.swift`, "Export".
//   * **Expression entry; NOT recorded anywhere before this note.** See below.
//
// `Expression.isCnf` is a fifth case and is *not* a gap: it has zero callers in 4.1.0 itself
// (`grep -rn isCnf` over the 4.1.0 tree returns only its own declaration). The port carries an
// upstream-dead method, faithfully. `Expression.Op.arity` is the same shape.
//
// ── The gap: upstream's EXPRESSION_TAB has no counterpart, and had no record ──────────────────
//
// `analyze/gui/ExpressionTab.java` is in the D9 list above, which is correct as a file
// exclusion. What no record stated is that it is the **only caller in all of 4.1.0** of five
// model entry points that are otherwise fully ported and jar-pinned:
//
//   Parser.parse                        ExpressionTab.java:279
//   Parser.parseMaybeAssignment         ExpressionTab.java:496
//   Expression.isAssignment             ExpressionTab.java:520, 529
//   Expression.getAssignmentVariable    ExpressionTab.java:521
//   Expression.getAssignmentExpression  ExpressionTab.java:529
//
// So `Parser`, 482 lines, pinned against the jar by `ParserTests` including the two upstream
// crashes it reproduces, is reachable from this module only through `replaceVariable`, which
// `OutputExpressions` calls when an input is renamed. Its two actual parse entry points are
// production-dead.
//
// In user terms: **you cannot type a Boolean expression into Analyze.** Upstream's window runs
// in both directions, circuit → truth table → expression, and expression → truth table →
// circuit, and only the first direction exists here. `AnalyzerWindow.swift` lists five UI gaps
// with a stated reason each; this is a sixth and is absent from that list, while the window's
// third tab is titled "Minimized" (upstream's MINIMIZED_TAB), so a reader comparing the two
// windows sees three tabs against four and no note saying which one went.
//
// This is a UI-only gap: the model half is complete and now gated end-to-end, not just
// unit-by-unit, by `Tests/LogisimAnalyzeTests/ExpressionEntryTests.swift`, which replays
// `ExpressionTab.importData` (ExpressionTab.java:485-539), parse, route to the output row the
// left-hand side names, strip the assignment, commit through `setExpression`, against the
// 4.1.0 jar, including all three of upstream's rejection paths. Whoever adds the tab is wiring
// to a contract that is already measured.
//
// Everything else under `analyze/` is ported. For the record, the files that look missing
// but are not; each is folded into a neighbour rather than given a file of its own, because
// Swift has no reason to spread them out:
//
//   model/Assignments.java          -> `Assignments` in Expression.swift
//   model/Expressions.java          -> `Expressions` in Expression.swift
//   model/ParserException.java      -> `ParserError` in AnalyzeStrings.swift
//   model/{OutputExpressions,TruthTable,VariableList}{Event,Listener}.java
//                                   -> alongside the class each one belongs to
//   data/Range.java                 -> `TextRange` in ExpressionRendering.swift
//
// Coverage, so a later reader can tell "ported" from "ported and measured": every file above
// the model layer: `data/{CoverColor,CsvInterpretor,CsvParameter,KarnaughMapGroups}`,
// `file/{AnalyzerTexWriter,TruthtableCsvFile,TruthtableTextFile}`, the two lifted helpers, and
// `AnalyzeStrings`' copy of the `en` bundle; is measured against the shipped 4.1.0 jar by
// `Tests/LogisimAnalyzeTests/AnalyzeFileGoldenTests.swift`, generated by
// `tools/analyze/AnaFileProbe.java`. The model layer has its own probes; see that directory's
// README for the full list.
