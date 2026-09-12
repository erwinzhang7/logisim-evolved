//
//  AnalyzerTexWriter.swift: part of logisim-evolved.
//
//  Derived from logisim-evolution, specifically
//  `src/main/java/com/cburch/logisim/analyze/file/AnalyzerTexWriter.java`. GPL-3.0-only.
//  See LICENSE.md.
//

import Foundation

/// Java: `com.cburch.logisim.analyze.file.AnalyzerTexWriter`: exports the whole analysis as
/// a standalone LaTeX document: truth tables, Karnaugh maps (empty, filled, and with covers
/// drawn by `tikz`'s `karnaugh` library), and the minimal expressions.
///
/// The Swing `FileFilter` is NOT-PORTED; ``fileExtension`` is what a save panel needs.
public enum AnalyzerTexWriter {
  private static let sectionSeparator =
    "%==============================================================================="
  private static let subSectionSeparator =
    "%-------------------------------------------------------------------------------"

  /// Java: `MAX_TRUTH_TABLE_ROWS`. Past this the document says so instead of printing a table
  /// nobody can read.
  public static let maxTruthTableRows = 64

  public static let fileExtension = "tex"

  // MARK: - Number formatting

  /// Java: `(DecimalFormat) NumberFormat.getNumberInstance(Locale.ENGLISH)`, then `format`.
  ///
  /// That is: up to three fraction digits, no trailing zeros, half-even rounding, `.` for the
  /// decimal point. Every value it is handed here is a half-integer between -0.5 and about
  /// 8.5, so what actually matters is that `4.0` prints as `"4"` and not `"4.0"`; a `"4.0"`
  /// in a `tikz` coordinate is still valid, but the file would stop matching Java's byte for
  /// byte and this is an export format.
  static func decimalFormat(_ value: Double) -> String {
    let rounded = (value * 1000).rounded(.toNearestOrEven) / 1000
    if rounded == rounded.rounded() && abs(rounded) < 1e15 {
      return String(Int(rounded))
    }
    var text = String(format: "%.3f", rounded)
    while text.hasSuffix("0") { text.removeLast() }
    if text.hasSuffix(".") { text.removeLast() }
    return text
  }

  // MARK: - Truth table

  private static func inputColumnCount(_ model: AnalyzerModel) -> Int {
    model.inputs.vars.reduce(0) { $0 + $1.width }
  }

  private static func outputColumnCount(_ model: AnalyzerModel) -> Int {
    model.outputs.vars.reduce(0) { $0 + $1.width }
  }

  /// Java: `truthTableHeader(AnalyzerModel)`.
  static func truthTableHeader(_ model: AnalyzerModel) -> String {
    var out = "\\begin{center}\n\\begin{tabular}{"
    out += String(repeating: "c", count: inputColumnCount(model))
    out += "|"
    out += String(repeating: "c", count: outputColumnCount(model))
    out += "}\n"
    let inputVars = model.inputs.vars
    let outputVars = model.outputs.vars
    for (i, input) in inputVars.enumerated() {
      if input.width == 1 {
        out += "$\(input.name)$&"
      } else {
        // The vertical rule after the last input column rides on the `\multicolumn` format,
        // which is why only the last one gets `c|`.
        let format = i == inputVars.count - 1 ? "c|" : "c"
        out += "\\multicolumn{\(input.width)}{\(format)}{$\(input.name)[\(input.width - 1)..0]$}&"
      }
    }
    for (i, output) in outputVars.enumerated() {
      if output.width == 1 {
        out += "$\(output.name)$"
      } else {
        out += "\\multicolumn{\(output.width)}{c}{$\(output.name)[\(output.width - 1)..0]$}"
      }
      out += i < outputVars.count - 1 ? "&" : "\\\\"
    }
    out += "\n\\hline"
    return out
  }

  /// Java: `getCompactTruthTable(TruthTable, AnalyzerModel)`, the visible (merged) rows.
  static func compactTruthTable(_ model: AnalyzerModel) -> String {
    let table = model.truthTable
    return truthTableBody(
      model,
      rowCount: table.visibleRowCount,
      input: { table.visibleInputEntry(row: $0, column: $1) },
      output: { table.visibleOutputEntry(row: $0, column: $1) })
  }

  /// Java: `getCompleteTruthTable(TruthTable, AnalyzerModel)`: every one of the `2^n` rows.
  static func completeTruthTable(_ model: AnalyzerModel) -> String {
    let table = model.truthTable
    return truthTableBody(
      model,
      rowCount: table.rowCount,
      // `getInputEntry` throws for an out-of-range row; the loop bound makes that
      // unreachable, and a `try?` here would hide a real bug rather than a user error.
      input: { (try? table.inputEntry(row: $0, column: $1)) ?? .dontCare },
      output: { table.outputEntry(row: $0, column: $1) })
  }

  private static func truthTableBody(
    _ model: AnalyzerModel,
    rowCount: Int,
    input: (Int, Int) -> Entry,
    output: (Int, Int) -> Entry
  ) -> String {
    let inCols = inputColumnCount(model)
    let outCols = outputColumnCount(model)
    var out = ""
    for row in 0..<rowCount {
      for col in 0..<inCols {
        out += "$\(input(row, col).description())$&"
      }
      for col in 0..<outCols {
        out += "$\(output(row, col).description())$"
        out += col == outCols - 1 ? "\\\\\n" : "&"
      }
    }
    return out
  }

  // MARK: - Karnaugh maps

  private static let kIntro = "\\begin{tikzpicture}[karnaugh,"
  private static let kNumbered = "disable bars,"
  private static let kSetup =
    "x=1\\kmunitlength,y=1\\kmunitlength,kmbar left sep=1\\kmunitlength,"
    + "grp/.style n args={4}{#1,fill=#1!30,minimum width= #2\\kmunitlength,"
    + "minimum height=#3\\kmunitlength,rounded corners=0.2\\kmunitlength,fill opacity=0.6,"
    + "rectangle,draw}]"

  /// Java: `reordered(int)`.
  ///
  /// The `karnaugh` tikz package assigns input variables to axes in a different order than
  /// Logisim does, so the bits have to be permuted on the way out:
  ///
  /// | inputs | Logisim | karnaugh_tikz |
  /// |---|---|---|
  /// | 3 | `ABC` | `BAC` |
  /// | 4 | `ABCD` | `ACBD` |
  /// | 5 | `ABCDE` | `CADBE` |
  /// | 6 | `ABCDEF` | `ADBECF` |
  static func reordered(_ inputCount: Int) -> [Int] {
    switch inputCount {
    case 1: return [0]
    case 2: return [0, 1]
    case 3: return [1, 0, 2]
    case 4: return [0, 2, 1, 3]
    case 5: return [2, 0, 3, 1, 4]
    case 6: return [0, 3, 1, 4, 2, 5]
    default: return []
    }
  }

  /// Java: `reorderedIndex(int, int)`; the same permutation applied to a truth-table row
  /// number, so the values come out in the order the package wants them listed.
  static func reorderedIndex(inputCount: Int, row: Int) -> Int {
    var result = 0
    let reorder = reordered(inputCount)
    guard reorder.count == inputCount else { return 0 }
    var values = [Int](repeating: 0, count: inputCount)
    for i in 0..<inputCount { values[i] = 1 << (inputCount - reorder[i] - 1) }
    var mask = 1 << (inputCount - 1)
    for i in 0..<inputCount {
      if (row & mask) == mask { result |= values[i] }
      mask >>= 1
    }
    return result
  }

  /// Java: `getKarnaughInputs(AnalyzerModel)`.
  static func karnaughInputs(_ model: AnalyzerModel) -> String {
    var out = ""
    let bits = model.inputs.bits
    let reorder = reordered(bits.count)
    for i in 0..<bits.count {
      guard i < reorder.count, reorder[i] < bits.count else { continue }
      // Java catches ParserException and does nothing, silently dropping the axis label.
      guard let bit = try? Var.Bit.parse(bits[reorder[i]]) else { continue }
      out += "{$\(bit.name)"
      if bit.bitIndex >= 0 { out += "_\(bit.bitIndex)" }
      out += "$}"
    }
    return out
  }

  /// Java: `getGrayCode(int)`.
  static func grayCode(_ varCount: Int) -> String {
    switch varCount {
    case 2: return "{0/00,1/01,2/11,3/10}"
    case 3: return "{0/000,1/001,2/011,3/010,4/110,5/111,6/101,7/100}"
    default: return "{0/0,1/1}"
    }
  }

  /// Java: `getNumberedHeader(String, AnalyzerModel)`; the hand-drawn axis labels used when
  /// the K-map is in "numbered" rather than "lined" style.
  static func numberedHeader(name: String, model: AnalyzerModel) -> String {
    let table = model.truthTable
    let inputCount = table.inputColumnCount
    guard inputCount < KarnaughMapGeometry.rowVars.count else { return "\n" }
    let kmapRows = 1 << KarnaughMapGeometry.rowVars[inputCount]
    let leftVarCount = KarnaughMapGeometry.rowVars[inputCount]

    var leftVars = ""
    var topVars = ""
    var count = 0
    for variable in table.inputVariables {
      if variable.width == 1 {
        if count < leftVarCount {
          if !leftVars.isEmpty { leftVars += ", " }
          leftVars += "$\(variable.name)$"
        } else {
          if !topVars.isEmpty { topVars += ", " }
          topVars += "$\(variable.name)$"
        }
        count += 1
      } else {
        // Upstream: `for (int idx = variable.width; idx >= 0; idx--)`. That emits width + 1
        // labels, bit `width` does not exist, and so shifts every later variable's
        // left/top assignment by one. It is a real upstream defect, but it is what the
        // shipped .tex files contain, and this is an export format whose whole point is
        // matching. Reproduced verbatim; not fixed.
        for idx in stride(from: variable.width, through: 0, by: -1) {
          if count < leftVarCount {
            if !leftVars.isEmpty { leftVars += ", " }
            leftVars += "$\(variable.name)_{\(idx)}$"
          } else {
            if !topVars.isEmpty { topVars += ", " }
            topVars += "$\(variable.name)_{\(idx)}$"
          }
          count += 1
        }
      }
    }

    var out = "\n"
    out += "\\draw[kmbox] (\(decimalFormat(-0.5)),\(decimalFormat(Double(kmapRows) + 0.5)))\n"
    out += "   node[below left]{\(leftVars)}\n"
    out += "   node[above right]{\(topVars)} +(-0.2,0.2)\n"
    out += "   node[above left]{\(name)};"
    out += "\\draw (0,\(kmapRows)) -- (-0.7,\(decimalFormat(Double(kmapRows) + 0.7)));\n"
    out += "\\foreach \\x/\\1 in %\n"
    out += grayCode(KarnaughMapGeometry.colVars[inputCount]) + " {\n"
    out += "   \\node at (\\x+0.5,\(decimalFormat(Double(kmapRows) + 0.2))) {\\1};\n}\n"
    out += "\\foreach \\y/\\1 in %\n"
    out += grayCode(KarnaughMapGeometry.rowVars[inputCount]) + " {\n"
    out += "   \\node at (-0.4,-0.5-\\y+\(decimalFormat(Double(kmapRows)))) {\\1};\n}\n"
    return out
  }

  /// Java: `getKarnaughEmpty(String, boolean, AnalyzerModel)`.
  static func karnaughEmpty(name: String, lined: Bool, model: AnalyzerModel) -> String {
    var out = "\\begin{center}\n"
    out += kIntro + (lined ? "" : kNumbered) + kSetup + "\n"
    out += "\\karnaughmap{\(inputColumnCount(model))}{\(name)}{\(karnaughInputs(model))}{}{"
    if !lined { out += numberedHeader(name: name, model: model) }
    out += "}\n\\end{tikzpicture}\n\\end{center}"
    return out
  }

  /// Java: `getKValues(int, AnalyzerModel)`.
  static func kValues(outputColumn: Int, model: AnalyzerModel) -> String {
    var out = ""
    let table = model.truthTable
    let bitCount = model.inputs.bits.count
    for row in 0..<table.rowCount {
      let idx = reorderedIndex(inputCount: bitCount, row: row)
      out += table.outputEntry(row: idx, column: outputColumn).description()
    }
    return out
  }

  /// Java: `getKarnaugh(String, boolean, int, AnalyzerModel)`.
  static func karnaugh(
    name: String, lined: Bool, outputColumn: Int, model: AnalyzerModel
  ) -> String {
    var out = "\\begin{center}\n"
    out += kIntro + (lined ? "" : kNumbered) + kSetup + "\n"
    out += "\\karnaughmap{\(inputColumnCount(model))}{\(name)}{\(karnaughInputs(model))}\n"
    out += "{\(kValues(outputColumn: outputColumn, model: model))}{"
    if !lined { out += numberedHeader(name: name, model: model) }
    out += "}\n\\end{tikzpicture}\n\\end{center}"
    return out
  }

  private static let offset = 0.2

  /// Java: `getCovers(String, AnalyzerModel)`: the `\node[grp={colour}{w}{h}]` rectangles.
  static func covers(output: String, model: AnalyzerModel) -> String {
    let table = model.truthTable
    let inputCount = table.inputColumnCount
    guard inputCount <= KarnaughMapGeometry.maxVars else { return "" }
    let groups = KarnaughMapGroups(model: model)
    groups.setOutput(output)
    let kmapRows = 1 << KarnaughMapGeometry.rowVars[inputCount]
    var out = ""
    var idx = 0
    for group in groups.covers {
      for cover in group.areas {
        // `getColorName` returns null for an unrecognised colour upstream, which lands in
        // the .tex as the literal text `null`. The index cannot be out of range here, but
        // the fallback is kept so the two trees produce the same bytes if it ever is.
        let colorName = CoverColor.colorName(index: group.colorIndex) ?? "null"
        out += "   \\node[grp={\(colorName)}"
        let width = Double(cover.width) - offset
        let height = Double(cover.height) - offset
        out += "{\(decimalFormat(width))}{\(decimalFormat(height))}]"
        out += "(n\(idx)) at"
        idx += 1
        let y = Double(kmapRows) - Double(cover.height) / 2.0 - Double(cover.row)
        let x = Double(cover.width) / 2.0 + Double(cover.col)
        out += "(\(decimalFormat(x)),\(decimalFormat(y))) {};\n"
      }
    }
    return out
  }

  /// Java: `getKarnaughGroups(String, String, boolean, int, AnalyzerModel)`.
  static func karnaughGroups(
    output: String, name: String, lined: Bool, outputColumn: Int, model: AnalyzerModel
  ) -> String {
    var out = "\\begin{center}\n"
    out += kIntro + (lined ? "" : kNumbered) + kSetup + "\n"
    out += "\\karnaughmap{\(inputColumnCount(model))}{\(name)}{\(karnaughInputs(model))}\n"
    out += "{\(kValues(outputColumn: outputColumn, model: model))}{"
    if !lined {
      out += numberedHeader(name: name, model: model)
    } else {
      out += "\n"
    }
    out += covers(output: output, model: model)
    out += "}\n\\end{tikzpicture}\n\\end{center}"
    return out
  }

  // MARK: - The document

  /// Java: `doSave(File, AnalyzerModel)`, as a string.
  ///
  /// **This mutates the model**, twice, and both are upstream's: `enableUpdates()` forces
  /// every output expression to be recomputed (restored afterwards, as upstream does), and
  /// `compactVisibleRows()` merges truth-table rows in place.
  ///
  /// - Parameter lined: Java reads `AppPreferences.KMAP_LINED_STYLE`, whose default is
  ///   `false`. D9 keeps preferences out of this module, so the caller passes it.
  /// - Parameter palette: the RGB triples written into the `\definecolor` preamble. Defaults
  ///   to the shipped `KMAP*_COLOR` preference defaults; a host with live preferences should
  ///   pass its own. See `CoverColor.swift`.
  /// - Parameter exportDate: injected so the output is reproducible under test.
  public static func text(
    for model: AnalyzerModel,
    lined: Bool = false,
    palette: [Int] = CoverColor.defaultRGB,
    exportDate: String = TruthtableTextFile.javaDateString(Date())
  ) -> String {
    let expressions = model.outputExpressions
    let wasUpdating = expressions.updatesEnabled
    expressions.enableUpdates()
    defer { if !wasUpdating { expressions.disableUpdates() } }

    var out = ""
    func line(_ text: String = "") { out += text + "\n" }

    line("\\documentclass [15pt,a4paper,twoside]{article}")
    line(
      "\\usepackage[" + AnalyzeStrings.message("latexBabelLanguage")
        + ",shorthands=off]{babel}        % shorhands=off is required for babel french in "
        + "combination with tikz karnaugh....")
    line("\\usepackage[utf8x]{inputenc}")
    line("\\usepackage[T1]{fontenc}")
    line("\\usepackage{amsmath}")
    line("\\usepackage{geometry}")
    line(
      "\\geometry{verbose,a4paper, tmargin=3.5cm,bmargin=3.5cm,lmargin=2.5cm,rmargin=2.5cm,"
        + "headsep=1cm,footskip=1.5cm}")
    line("\\usepackage{fancyhdr}")
    line("\\usepackage{colortbl}")
    line("\\usepackage[dvipsnames]{xcolor}")
    line("\\usepackage{tikz -timing}")
    line("\\usepackage{tikz}")
    line("\\usetikzlibrary{karnaugh}")
    line("\\pagestyle{fancy}")
    line()

    // The cover colours, by name, so `\node[grp={LogisimKMapColor3}…]` resolves.
    for index in 0..<palette.count {
      let value = palette[index]
      let name = CoverColor.colorName(index: index) ?? "null"
      line(
        "\\definecolor{\(name)}{RGB}{\((value >> 16) & 0xFF),\((value >> 8) & 0xFF),"
          + "\(value & 0xFF)}")
    }
    line()

    line("\\fancyhead{}")
    line("\\fancyhead[C] {" + AnalyzeStrings.message("latexHeader", [exportDate]) + "}")
    line("\\fancyfoot[C] {\\thepage}")
    line("\\renewcommand{\\headrulewidth}{0.4pt}")
    line("\\renewcommand{\\footrulewidth}{0.4pt}")
    line()
    line("\\makeatother")
    line()
    line("\\begin{document}")
    line("\\section{" + AnalyzeStrings.message("latexIntroduction") + "}")
    line(AnalyzeStrings.message("latexIntroductionText"))

    if model.inputs.vars.isEmpty || model.outputs.vars.isEmpty {
      line(sectionSeparator)
      line("\\section{" + AnalyzeStrings.message("latexEmpty") + "}")
      line(AnalyzeStrings.message("latexEmptyText"))
      line("\\end{document}")
      return out
    }

    let table = model.truthTable
    line(sectionSeparator)
    line("\\section{" + AnalyzeStrings.message("latexTruthTable") + "}")
    line(AnalyzeStrings.message("latexTruthTableText"))
    if table.rowCount > maxTruthTableRows {
      line(AnalyzeStrings.message("latexTruthTableToBig", ["\(maxTruthTableRows)"]))
    } else {
      table.compactVisibleRows()
      line(subSectionSeparator)
      line("\\subsection{" + AnalyzeStrings.message("latexTruthTableCompact") + "}")
      line(truthTableHeader(model))
      line(compactTruthTable(model))
      line("\\end{tabular}")
      line("\\end{center}")
      line(subSectionSeparator)
      line("\\subsection{" + AnalyzeStrings.message("latexTruthTableComplete") + "}")
      line(truthTableHeader(model))
      line(completeTruthTable(model))
      line("\\end{tabular}")
      line("\\end{center}")
    }

    line(sectionSeparator)
    line("\\section{" + AnalyzeStrings.message("latexKarnaugh") + "}")
    if table.rowCount > maxTruthTableRows {
      // Java: `(int) Math.ceil(Math.log(MAX_TRUTH_TABLE_ROWS) / Math.log(2))`, i.e. 6.
      let maxVars = Int(ceil(log(Double(maxTruthTableRows)) / log(2.0)))
      line(AnalyzeStrings.message("latexKarnaughToBig", ["\(maxVars)"]))
      line("\\end{document}")
      return out
    }

    line(AnalyzeStrings.message("latexKarnaughText"))
    line(subSectionSeparator)
    line("\\subsection{" + AnalyzeStrings.message("latexKarnaughEmpty") + "}")
    for output in model.outputs.vars {
      if output.width == 1 {
        line(karnaughEmpty(name: "$\(output.name)$", lined: lined, model: model))
      } else {
        for idx in stride(from: output.width - 1, through: 0, by: -1) {
          line(karnaughEmpty(name: "$\(output.name)_{\(idx)}$", lined: lined, model: model))
        }
      }
    }

    line(subSectionSeparator)
    line("\\subsection{" + AnalyzeStrings.message("latexKarnaughFilledIn") + "}")
    var outputColumn = 0
    for output in model.outputs.vars {
      if output.width == 1 {
        line(
          karnaugh(
            name: "$\(output.name)$", lined: lined, outputColumn: outputColumn, model: model))
        outputColumn += 1
      } else {
        for idx in stride(from: output.width - 1, through: 0, by: -1) {
          line(
            karnaugh(
              name: "$\(output.name)_{\(idx)}$", lined: lined, outputColumn: outputColumn,
              model: model))
          outputColumn += 1
        }
      }
    }

    line(subSectionSeparator)
    line("\\subsection{" + AnalyzeStrings.message("latexKarnaughFilledInGroups") + "}")
    outputColumn = 0
    for output in model.outputs.vars {
      if output.width == 1 {
        line(
          karnaughGroups(
            output: output.name, name: "$\(output.name)$", lined: lined,
            outputColumn: outputColumn, model: model))
        outputColumn += 1
      } else {
        for idx in stride(from: output.width - 1, through: 0, by: -1) {
          line(
            karnaughGroups(
              output: "\(output.name)[\(idx)]", name: "$\(output.name)_{\(idx)}$", lined: lined,
              outputColumn: outputColumn, model: model))
          outputColumn += 1
        }
      }
    }

    line(sectionSeparator)
    line("\\section{" + AnalyzeStrings.message("latexMinimal") + "}")
    for o in 0..<table.outputVariables.count {
      let output = table.outputVariable(o)
      if output.width == 1 {
        let expression = Expressions.eq(
          Expressions.variable(output.name), expressions.minimalExpression(for: output.name))
        line(latexLine(expression))
      } else {
        for idx in stride(from: output.width - 1, through: 0, by: -1) {
          let name = output.bitName(idx)
          let expression = Expressions.eq(
            Expressions.variable(name), expressions.minimalExpression(for: name))
          line(latexLine(expression))
        }
      }
    }

    line("\\end{document}")
    return out
  }

  /// Java: `exp.toString(Notation.LATEX) + "~\\\\"`.
  ///
  /// `Expressions.eq` returns the other operand when one side is `null`, so a missing minimal
  /// expression prints as the bare variable: upstream behaviour, not a guard added here.
  private static func latexLine(_ expression: Expression?) -> String {
    let rendered = expression?.render(.latex).text ?? ""
    return rendered + "~\\\\"
  }

  /// Java: `doSave(File, AnalyzerModel)`.
  public static func save(
    _ model: AnalyzerModel,
    to url: URL,
    lined: Bool = false,
    palette: [Int] = CoverColor.defaultRGB,
    exportDate: String = TruthtableTextFile.javaDateString(Date())
  ) throws {
    let contents = text(
      for: model, lined: lined, palette: palette, exportDate: exportDate)
    try contents.write(to: url, atomically: true, encoding: .utf8)
  }
}
