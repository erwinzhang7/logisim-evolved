//
//  AnalyzeFileGoldenData.swift; part of logisim-evolved.
//
//  GENERATED. Do not hand-edit; regenerate with the probe recorded below.
//
//  Captured from the SHIPPED 4.1.0 jar (D16), not a build of main:
//    /Applications/Logisim-evolution.app/Contents/app/logisim-evolution-4.1.0-all.jar
//
//  The probe is `AnaFileProbe`, declared in package `com.cburch.logisim.analyze.file`
//  so it can reach the analyze file/data layer, and run exactly as tools/analyze/README.md
//  describes for the model probes:
//
//    JAR=/Applications/Logisim-evolution.app/Contents/app/logisim-evolution-4.1.0-all.jar
//    javac -cp "$JAR" -d /tmp/anaprobe AnaFileProbe.java
//    java -Djava.awt.headless=true -cp "$JAR:/tmp/anaprobe" \
//        com.cburch.logisim.analyze.file.AnaFileProbe <mode> < cases.txt
//
//  It sets `Main.headless = true` first (D17), which turns every `OptionPane` dialog into
//  a log line and makes `showConfirmDialog` return `CANCEL_OPTION`: the same answer as
//  this port's default `resolveInconsistentRows` closure. Without it the error paths all
//  die with `HeadlessException` and record nothing.
//
//  Two non-reproducible lines are stripped on both sides before comparison: the `.txt`
//  export's `# Exported on <Date>` and the `.tex` export's `\fancyhead[C] {...<Date>}`.
//

/// Differential golden data for the analyze file and data layer, from the 4.1.0 jar.
enum AnalyzeFileGolden {

  // MARK: - VariableTab.checkindex

  /// `checkindex(String)` -> its `int` result. Positive is a bit count; 0 and the negative
  /// `VariableTab` codes are failures.
  static let checkIndex: [(input: String, result: Int)] = [
    ("[3..0]", 4),
    ("[4]", 4),
    ("[0]", 0),
    ("[1]", 1),
    ("[7..0]", 8),
    ("[31..0]", 32),
    ("[3..3]", 1),
    ("[0..3]", -5),
    ("[3..1]", 3),
    ("[]", -2),
    ("[", 0),
    ("]", 0),
    ("x", 0),
    ("[3", -6),
    ("[3.0]", -3),
    ("[3..]", -4),
    ("[3..0", -6),
    ("[3..0]x", -7),
    ("[a..0]", -2),
    ("[3..a]", -4),
    ("[-1..0]", -2),
    ("[ 3..0]", -2),
    ("[03..00]", 4),
    ("[10..2]", 9),
    ("[2..10]", -5),
    ("[3..0][", -7),
    ("[3..0]]", -7),
    ("[[3..0]", -2),
    ("[3..0", -6),
    ("[..]", -2),
    ("[..0]", -2),
    ("[3..0 ]", -6),
    ("[2147483647..0]", -2147483648),
    ("[2147483646..0]", 2147483647),
  ]

  /// The inputs on which upstream's `Integer.parseInt` escapes `checkindex` uncaught. D13
  /// forbids reproducing an uncatchable crash, so the port returns a failure code instead;
  /// the expected code is stated here so the divergence stays visible.
  static let checkIndexThrowsUpstream: [(input: String, javaException: String, portResult: Int)] = [
    ("[99999999999..0]", "NumberFormatException", -2),
  ]

  // MARK: - SyntaxChecker.getErrorMessage

  /// `getErrorMessage(String)` in the `en` locale, `nil` for an acceptable name.
  ///
  /// The VHDL/Verilog keyword rows are the ones this module cannot answer on its own: see
  /// `AnalyzeSyntaxChecker.hdlKeywordCheck`. The test installs a stub for exactly the
  /// keywords these rows use.
  static let syntaxErrors: [(name: String, message: String?)] = [
    ("a", nil),
    ("abc", nil),
    ("A1", nil),
    ("a_b", nil),
    ("a__b", "Error: Detected concatenated “_”-symbols!\n"),
    ("a_", "Error: Name ends with a “_”-symbol!\n"),
    ("_a", "Error: Detected invalid characters!\nError: The character “_” is not allowed.\n"),
    ("1a", "Error: Detected invalid characters!\nError: The name must not start with a digit.\n"),
    ("1abc", "Error: Detected invalid characters!\nError: The name must not start with a digit.\n"),
    ("$abc", "Error: Detected invalid characters!\nError: The character “$” is not allowed.\n"),
    ("ab$cd", "Error: Detected invalid characters!\nError: The character “$” is not allowed.\n"),
    ("abc$", "Error: Detected invalid characters!\nError: The character “$” is not allowed.\n"),
    ("a b", "Error: Detected invalid characters!\nError: The character “ ” is not allowed.\n"),
    ("in", "Error: Detected VHDL keyword!\n"),
    ("out", "Error: Detected VHDL keyword!\n"),
    ("entity", "Error: Detected VHDL keyword!\n"),
    ("signal", "Error: Detected VHDL keyword!\n"),
    ("begin", "Error: Detected VHDL keyword!\n"),
    ("module", "Error: Detected Verilog keyword!\n"),
    ("wire", "Error: Detected Verilog keyword!\n"),
    ("reg", "Error: Detected Verilog keyword!\n"),
    ("always", "Error: Detected Verilog keyword!\n"),
    ("Q", nil),
    ("q0", nil),
    ("x1y2", nil),
    ("a-b", "Error: Detected invalid characters!\nError: The character “-” is not allowed.\n"),
    ("a.b", "Error: Detected invalid characters!\nError: The character “.” is not allowed.\n"),
    ("café", "Error: Detected invalid characters!\nError: The character “é” is not allowed.\n"),
    ("a1_", "Error: Name ends with a “_”-symbol!\n"),
    ("__", "Error: Detected invalid characters!\nError: The character “_” is not allowed.\nError: Detected concatenated “_”-symbols!\nError: Name ends with a “_”-symbol!\n"),
    ("a__", "Error: Detected concatenated “_”-symbols!\nError: Name ends with a “_”-symbol!\n"),
    ("_", "Error: Detected invalid characters!\nError: The character “_” is not allowed.\nError: Name ends with a “_”-symbol!\n"),
    ("0", "Error: Detected invalid characters!\nError: The name must not start with a digit.\n"),
    ("9z", "Error: Detected invalid characters!\nError: The name must not start with a digit.\n"),
    ("zzz9", nil),
  ]

  // MARK: - CsvInterpretor.parseCsvLine

  /// `parseCsvLine(line, ',', '"')`. `nil` is upstream's empty-field marker, which is
  /// distinct from `""` and is what the header parser reads as "continues the previous
  /// vector".
  static let csvLines: [(line: String, fields: [String?])] = [
    ("a,b,c", ["a", "b", "c"]),
    ("\"a\",\"b\",\"c\"", ["a", "b", "c"]),
    ("\"A\",\"B[3..0]\",,,,\"|\",\"D:3\",\"D:2\",\"D:1\",\"D:0\"", ["A", "B[3..0]", nil, nil, nil, "|", "D:3", "D:2", "D:1", "D:0"]),
    ("0,0,0,-,0,\"|\",1,0,1,0", ["0", "0", "0", "-", "0", "|", "1", "0", "1", "0"]),
    (",,,", [nil, nil, nil, nil]),
    ("a,,b", ["a", nil, "b"]),
    ("\"a\"", ["a"]),
    ("\"\"", [nil]),
    ("a", ["a"]),
    ("\"a\"\"b\",c", ["a\"b", "c"]),
    ("\"a\"\"\"\"b\",c", ["a\"\"b", "c"]),
    ("\"a,b\",c", ["a,b", "c"]),
    ("a\"b", ["ab"]),
    ("\"a", ["a"]),
    ("a\"", ["a"]),
    ("\"\",a", [nil, "a"]),
    ("1,2,3,", ["1", "2", "3", nil]),
    (",1", [nil, "1"]),
    ("\"|\"", ["|"]),
    ("\"\"\"\"", [nil]),
    ("\"\"\"\",a", ["\"", "a"]),
    ("a,\"b", ["a", "b"]),
    ("x\"y,z", ["xy,z"]),
    ("\"x\"y,z", ["xy", "z"]),
    ("\"x\",,\"y\"", ["x", nil, "y"]),
  ]

  // MARK: - KarnaughMapPanel.getRow / getCol

  /// For each input count: the map's row and column count, then every truth-table row's
  /// `(row, col)` on the map, in table order.
  static let kmapPlacement: [(inputs: Int, rows: Int, cols: Int, cells: [(row: Int, col: Int)])] = [
    (1, 1, 2, [(0, 0), (0, 1)]),
    (2, 2, 2, [(0, 0), (0, 1), (1, 0), (1, 1)]),
    (3, 2, 4, [(0, 0), (0, 1), (0, 3), (0, 2), (1, 0), (1, 1), (1, 3), (1, 2)]),
    (4, 4, 4, [(0, 0), (0, 1), (0, 3), (0, 2), (1, 0), (1, 1), (1, 3), (1, 2), (3, 0), (3, 1), (3, 3), (3, 2), (2, 0), (2, 1), (2, 3), (2, 2)]),
    (5, 4, 8, [(0, 0), (0, 1), (0, 3), (0, 2), (0, 7), (0, 6), (0, 4), (0, 5), (1, 0), (1, 1), (1, 3), (1, 2), (1, 7), (1, 6), (1, 4), (1, 5), (3, 0), (3, 1), (3, 3), (3, 2), (3, 7), (3, 6), (3, 4), (3, 5), (2, 0), (2, 1), (2, 3), (2, 2), (2, 7), (2, 6), (2, 4), (2, 5)]),
    (6, 8, 8, [(0, 0), (0, 1), (0, 3), (0, 2), (0, 7), (0, 6), (0, 4), (0, 5), (1, 0), (1, 1), (1, 3), (1, 2), (1, 7), (1, 6), (1, 4), (1, 5), (3, 0), (3, 1), (3, 3), (3, 2), (3, 7), (3, 6), (3, 4), (3, 5), (2, 0), (2, 1), (2, 3), (2, 2), (2, 7), (2, 6), (2, 4), (2, 5), (7, 0), (7, 1), (7, 3), (7, 2), (7, 7), (7, 6), (7, 4), (7, 5), (6, 0), (6, 1), (6, 3), (6, 2), (6, 7), (6, 6), (6, 4), (6, 5), (4, 0), (4, 1), (4, 3), (4, 2), (4, 7), (4, 6), (4, 4), (4, 5), (5, 0), (5, 1), (5, 3), (5, 2), (5, 7), (5, 6), (5, 4), (5, 5)]),
  ]

  // MARK: - CoverColor

  /// `getColorName(getColor(i))` and the RGB triple behind it, for all 16 slots.
  static let coverPalette: [(name: String, red: Int, green: Int, blue: Int)] = [
    ("LogisimKMapColor0", 128, 0, 0),
    ("LogisimKMapColor1", 230, 25, 75),
    ("LogisimKMapColor2", 250, 190, 190),
    ("LogisimKMapColor3", 170, 110, 40),
    ("LogisimKMapColor4", 245, 130, 48),
    ("LogisimKMapColor5", 255, 215, 180),
    ("LogisimKMapColor6", 128, 128, 0),
    ("LogisimKMapColor7", 255, 255, 25),
    ("LogisimKMapColor8", 210, 245, 60),
    ("LogisimKMapColor9", 0, 0, 128),
    ("LogisimKMapColor10", 145, 30, 180),
    ("LogisimKMapColor11", 60, 180, 175),
    ("LogisimKMapColor12", 0, 130, 203),
    ("LogisimKMapColor13", 230, 190, 255),
    ("LogisimKMapColor14", 170, 255, 195),
    ("LogisimKMapColor15", 240, 50, 230),
  ]

  /// Twenty consecutive `getNext()` calls after `reset()`, so the wrap at 16 is covered.
  static let coverRotation: [String] = [
    "LogisimKMapColor0",
    "LogisimKMapColor1",
    "LogisimKMapColor2",
    "LogisimKMapColor3",
    "LogisimKMapColor4",
    "LogisimKMapColor5",
    "LogisimKMapColor6",
    "LogisimKMapColor7",
    "LogisimKMapColor8",
    "LogisimKMapColor9",
    "LogisimKMapColor10",
    "LogisimKMapColor11",
    "LogisimKMapColor12",
    "LogisimKMapColor13",
    "LogisimKMapColor14",
    "LogisimKMapColor15",
    "LogisimKMapColor0",
    "LogisimKMapColor1",
    "LogisimKMapColor2",
    "LogisimKMapColor3",
  ]

  // MARK: - TruthtableTextFile.doSave

  /// The fixed preamble every `.txt` export starts with, minus the `# Exported on <Date>`
  /// line. It is `tableRemark1`, a blank line, `tableRemark4` and another blank line, so it
  /// doubles as a check that `AnalyzeStrings`' copy of the `en` bundle is verbatim.
  static let textFilePreamble: String = "# Truth table\n\n# Hints and Notes on Formatting:\n# * You can edit this file then import it back into Logisim!\n# * Anything after a ‘#’ is a comment and will be ignored.\n# * Blank lines and separator lines (e.g., ~~~~~~) are ignored.\n# * Keep column names simple (no spaces, punctuation, etc.)\n# * ‘Name[N..0]’ indicates an N+1 bit variable, whereas\n#   ‘Name’ by itself indicates a 1-bit variable.\n# * You can use ‘x’ or ‘-’ to indicate “don’t care” for both\n#   input and output bits.\n# * You can use binary (e.g., ‘10100011xxxx’) notation or\n#   or hex (e.g., ‘C3x’). Logisim will figure out which is which.\n\n"

  /// Model spec -> the `.txt` export body that follows ``textFilePreamble``.
  ///
  /// `inputs`/`outputs` are comma-separated `name` or `name/width`; `bits` is the output
  /// column content, cycled across every output column.
  static let textSave: [(inputs: String, outputs: String, bits: String, body: String)] = [
    ("a,b", "q", "0110", "a b | q\n~~~~~~~\n0 0 | 0\n0 1 | 1\n1 0 | 1\n1 1 | 0\n"),
    ("a,b,c", "q", "01101001", "a b c | q\n~~~~~~~~~\n0 0 0 | 0\n0 0 1 | 1\n0 1 0 | 1\n0 1 1 | 0\n1 0 0 | 1\n1 0 1 | 0\n1 1 0 | 0\n1 1 1 | 1\n"),
    ("a,b", "q,r", "0110", "a b | q r\n~~~~~~~~~\n0 0 | 0 0\n0 1 | 1 1\n1 0 | 1 1\n1 1 | 0 0\n"),
    ("a,bb/4", "q/4", "0110100110010110", "a bb[3..0] | q[3..0]\n~~~~~~~~~~~~~~~~~~~~\n0   0000   |  0000  \n0   0001   |  1111  \n0   0010   |  1111  \n0   0011   |  0000  \n0   0100   |  1111  \n0   0101   |  0000  \n0   0110   |  0000  \n0   0111   |  1111  \n0   1000   |  1111  \n0   1001   |  0000  \n0   1010   |  0000  \n0   1011   |  1111  \n0   1100   |  0000  \n0   1101   |  1111  \n0   1110   |  1111  \n0   1111   |  0000  \n1   0000   |  0000  \n1   0001   |  1111  \n1   0010   |  1111  \n1   0011   |  0000  \n1   0100   |  1111  \n1   0101   |  0000  \n1   0110   |  0000  \n1   0111   |  1111  \n1   1000   |  1111  \n1   1001   |  0000  \n1   1010   |  0000  \n1   1011   |  1111  \n1   1100   |  0000  \n1   1101   |  1111  \n1   1110   |  1111  \n1   1111   |  0000  \n"),
    ("A,B/3", "D/3", "01101001", "A B[2..0] | D[2..0]\n~~~~~~~~~~~~~~~~~~~\n0   000   |   000  \n0   001   |   111  \n0   010   |   111  \n0   011   |   000  \n0   100   |   111  \n0   101   |   000  \n0   110   |   000  \n0   111   |   111  \n1   000   |   000  \n1   001   |   111  \n1   010   |   111  \n1   011   |   000  \n1   100   |   111  \n1   101   |   000  \n1   110   |   000  \n1   111   |   111  \n"),
    ("x/2,y/2", "z", "1100101011010010", "x[1..0] y[1..0] | z\n~~~~~~~~~~~~~~~~~~~\n  00      00    | 1\n  00      01    | 1\n  00      10    | 0\n  00      11    | 0\n  01      00    | 1\n  01      01    | 0\n  01      10    | 1\n  01      11    | 0\n  10      00    | 1\n  10      01    | 1\n  10      10    | 0\n  10      11    | 1\n  11      00    | 0\n  11      01    | 0\n  11      10    | 1\n  11      11    | 0\n"),
    ("in1,in2,in3", "out1,out2", "0110100110010110", "in1 in2 in3 | out1 out2\n~~~~~~~~~~~~~~~~~~~~~~~\n 0   0   0  |  0    1  \n 0   0   1  |  1    0  \n 0   1   0  |  1    0  \n 0   1   1  |  0    1  \n 1   0   0  |  1    0  \n 1   0   1  |  0    1  \n 1   1   0  |  0    1  \n 1   1   1  |  1    0  \n"),
    ("a", "q/2", "0110", "a | q[1..0]\n~~~~~~~~~~~\n0 |   01   \n1 |   10   \n"),
    ("longname,b", "result", "0110", "longname b | result\n~~~~~~~~~~~~~~~~~~~\n   0     0 |   0   \n   0     1 |   1   \n   1     0 |   1   \n   1     1 |   0   \n"),
    ("a,b,c,d", "q", "0110100110010110", "a b c d | q\n~~~~~~~~~~~\n0 0 0 0 | 0\n0 0 0 1 | 1\n0 0 1 0 | 1\n0 0 1 1 | 0\n0 1 0 0 | 1\n0 1 0 1 | 0\n0 1 1 0 | 0\n0 1 1 1 | 1\n1 0 0 0 | 1\n1 0 0 1 | 0\n1 0 1 0 | 0\n1 0 1 1 | 1\n1 1 0 0 | 0\n1 1 0 1 | 1\n1 1 1 0 | 1\n1 1 1 1 | 0\n"),
  ]

  // MARK: - TruthtableCsvFile.doSave

  /// Model spec -> the whole `.csv` export. Upstream calls `compactVisibleRows()` first, so
  /// several of these also pin row merging.
  static let csvSave: [(inputs: String, outputs: String, bits: String, csv: String)] = [
    ("a,b", "q", "0110", "\"a\",\"b\",\"|\",\"q\"\n0,0,\"|\",0\n0,1,\"|\",1\n1,0,\"|\",1\n1,1,\"|\",0\n"),
    ("a,b,c", "q", "01101001", "\"a\",\"b\",\"c\",\"|\",\"q\"\n0,0,0,\"|\",0\n0,0,1,\"|\",1\n0,1,0,\"|\",1\n0,1,1,\"|\",0\n1,0,0,\"|\",1\n1,0,1,\"|\",0\n1,1,0,\"|\",0\n1,1,1,\"|\",1\n"),
    ("a,b", "q,r", "0110", "\"a\",\"b\",\"|\",\"q\",\"r\"\n0,0,\"|\",0,0\n0,1,\"|\",1,1\n1,0,\"|\",1,1\n1,1,\"|\",0,0\n"),
    ("a,bb/4", "q/4", "0110100110010110", "\"a\",\"bb[3..0]\",,,,\"|\",\"q[3..0]\",,,\n-,0,0,0,0,\"|\",0,0,0,0\n-,0,0,0,1,\"|\",1,1,1,1\n-,0,0,1,0,\"|\",1,1,1,1\n-,0,0,1,1,\"|\",0,0,0,0\n-,0,1,0,0,\"|\",1,1,1,1\n-,0,1,0,1,\"|\",0,0,0,0\n-,0,1,1,0,\"|\",0,0,0,0\n-,0,1,1,1,\"|\",1,1,1,1\n-,1,0,0,0,\"|\",1,1,1,1\n-,1,0,0,1,\"|\",0,0,0,0\n-,1,0,1,0,\"|\",0,0,0,0\n-,1,0,1,1,\"|\",1,1,1,1\n-,1,1,0,0,\"|\",0,0,0,0\n-,1,1,0,1,\"|\",1,1,1,1\n-,1,1,1,0,\"|\",1,1,1,1\n-,1,1,1,1,\"|\",0,0,0,0\n"),
    ("A,B/3", "D/3", "01101001", "\"A\",\"B[2..0]\",,,\"|\",\"D[2..0]\",,\n-,0,0,0,\"|\",0,0,0\n-,0,0,1,\"|\",1,1,1\n-,0,1,0,\"|\",1,1,1\n-,0,1,1,\"|\",0,0,0\n-,1,0,0,\"|\",1,1,1\n-,1,0,1,\"|\",0,0,0\n-,1,1,0,\"|\",0,0,0\n-,1,1,1,\"|\",1,1,1\n"),
    ("x/2,y/2", "z", "1100101011010010", "\"x[1..0]\",,\"y[1..0]\",,\"|\",\"z\"\n-,0,0,-,\"|\",1\n0,0,1,-,\"|\",0\n0,1,-,0,\"|\",1\n-,1,-,1,\"|\",0\n1,0,1,0,\"|\",0\n1,0,1,1,\"|\",1\n1,1,0,0,\"|\",0\n1,1,1,0,\"|\",1\n"),
    ("in1,in2,in3", "out1,out2", "0110100110010110", "\"in1\",\"in2\",\"in3\",\"|\",\"out1\",\"out2\"\n0,0,0,\"|\",0,1\n0,0,1,\"|\",1,0\n0,1,0,\"|\",1,0\n0,1,1,\"|\",0,1\n1,0,0,\"|\",1,0\n1,0,1,\"|\",0,1\n1,1,0,\"|\",0,1\n1,1,1,\"|\",1,0\n"),
    ("a", "q/2", "0110", "\"a\",\"|\",\"q[1..0]\",\n0,\"|\",0,1\n1,\"|\",1,0\n"),
    ("longname,b", "result", "0110", "\"longname\",\"b\",\"|\",\"result\"\n0,0,\"|\",0\n0,1,\"|\",1\n1,0,\"|\",1\n1,1,\"|\",0\n"),
    ("a,b,c,d", "q", "0110100110010110", "\"a\",\"b\",\"c\",\"d\",\"|\",\"q\"\n0,0,0,0,\"|\",0\n0,0,0,1,\"|\",1\n0,0,1,0,\"|\",1\n0,0,1,1,\"|\",0\n0,1,0,0,\"|\",1\n0,1,0,1,\"|\",0\n0,1,1,0,\"|\",0\n0,1,1,1,\"|\",1\n1,0,0,0,\"|\",1\n1,0,0,1,\"|\",0\n1,0,1,0,\"|\",0\n1,0,1,1,\"|\",1\n1,1,0,0,\"|\",0\n1,1,0,1,\"|\",1\n1,1,1,0,\"|\",1\n1,1,1,1,\"|\",0\n"),
  ]

  // MARK: - TruthtableTextFile.doLoad

  /// A `.txt` source -> either the loaded model, dumped, or the `IOException` upstream
  /// raised.
  ///
  /// The dump is `in=<name>/<width>,… out=… rows=<n> <inputbits>:<outputbits> …`, using
  /// `getVisibleInputEntry`/`getVisibleOutputEntry`: so it pins the *visible* (merged)
  /// rows, which is what the file format round-trips.
  ///
  /// A row whose rows do not partition the input space is NOT an error: upstream asks
  /// "Ignore errors and try again?", and headless that answers CANCEL. The model keeps the
  /// new variables and a default all-don't-care table, which is what those `dump` values
  /// show. This port's default `resolveInconsistentRows` declines identically.
  static let textLoad: [(source: String, dump: String?, error: String?)] = [
    ("a b | q\n~~~~~~~\n0 0 | 0\n0 1 | 1\n1 0 | 1\n1 1 | 0\n", "in=a/1,b/1, out=q/1, rows=4 00:0 01:1 10:1 11:0", nil),
    ("# a comment\nA B[3..0] | D[3..0]\n~~~~~~~~~~~~~~~~~~~\n0  0000   |  1010\n0  0001   |  1101\n0  001x   |  1010\n0  01--   |  0001\n0  1---   |  1000\n1  ----   |  0000\n", "in=A/1,B/4, out=D/4, rows=6 00000:1010 00001:1101 0001-:1010 001--:0001 01---:1000 1----:0000", nil),
    ("A B[3..0] | D[3..0]\n-------------------\n0  0      |  A\n0  1      |  5\n0  2      |  x\n0  3      |  -\n0  4      |  0\n0  5      |  F\n0  6      |  9\n0  7      |  3\n1  -      |  0\n", "in=A/1,B/4, out=D/4, rows=32 00000:---- 00001:---- 00010:---- 00011:---- 00100:---- 00101:---- 00110:---- 00111:---- 01000:---- 01001:---- 01010:---- 01011:---- 01100:---- 01101:---- 01110:---- 01111:---- 10000:---- 10001:---- 10010:---- 10011:---- 10100:---- 10101:---- 10110:---- 10111:---- 11000:---- 11001:---- 11010:---- 11011:---- 11100:---- 11101:---- 11110:---- 11111:----", nil),
    ("a | q\n0 | 0\n1 | 1\n", "in=a/1, out=q/1, rows=2 0:0 1:1", nil),
    ("a b q\n0 0 0\n", nil, "Line 1: Truth table has no outputs."),
    ("a b | q | r\n0 0 | 0 | 1\n", nil, "Line 1: Separator '|' must appear only once."),
    ("a b | q\n0 0 | 0\n0 1 |\n", nil, "Line 3: Not enough output columns."),
    ("a b | q\n0 0 | 0 0\n", nil, "Line 2: Too many output columns."),
    ("Q[5..0] | z\n0 | 0\n", nil, "Line 2: Expected 6 bits (or 2 hex digits) in column Q, but found \"0\"."),
    ("1abc | q\n0 | 0\n", nil, "Line 1: Invalid variable name '1abc'."),
    ("a[0..3] | q\n0000 | 0\n", nil, "Line 1: Invalid bit range in 'a[0..3]'."),
    ("a[3..1] | q\n000 | 0\n", nil, "Line 1: Invalid bit range in 'a[3..1]'."),
    ("\n", nil, "End of file: Truth table has no rows."),
    ("a b | q\n~~~~~~~\n0 0 | 2\n", nil, "Line 3: Bit value '2' in \"2\" must be one of '0', '1', 'x', or '-'."),
    ("a b | q\n0 0 | 0\n0 1 | 1\n1 0 | 1\n1 1 | 0\n1 1 | 1\n", "in=a/1,b/1, out=q/1, rows=4 00:- 01:- 10:- 11:-", nil),
    ("x[2..0] | y\n0    | 0\n1    | 1\n2    | x\n3    | -\n4    | 0\n5    | 1\n6    | 1\n7    | 0\n", "in=x/3, out=y/1, rows=8 000:0 001:1 010:- 011:- 100:0 101:1 110:1 111:0", nil),
    ("B[3..0] | D[3..0]\n~~~~~~~~~~~~~~~~~\n0       |  A\n1       |  5\n2       |  x\n3       |  -\n4       |  0\n5       |  F\n6       |  9\n7       |  3\n8       |  1\n9       |  2\na       |  C\nb       |  6\nC       |  8\nD       |  9\ne       |  E\nf       |  0\n", "in=B/4, out=D/4, rows=16 0000:1010 0001:0101 0010:---- 0011:---- 0100:0000 0101:1111 0110:1001 0111:0011 1000:0001 1001:0010 1010:1100 1011:0110 1100:1000 1101:1001 1110:1110 1111:0000", nil),
    ("B[11..0] | D[4..0]\n------------------\nxxx      | 0x\n", "in=B/12, out=D/5, rows=1 ------------:0----", nil),
    ("B[4..0] | q\nxxxxx   | 0\n", "in=B/5, out=q/1, rows=1 -----:0", nil),
    ("B[4..0] | q\nxx      | 0\n", "in=B/5, out=q/1, rows=1 -----:0", nil),
    ("B[4..0] | q\n3x      | 0\n", nil, "Line 2: Hex value \"3x\" contains too many bits for B."),
    ("B[4..0] | q\n1x      | 0\n", "in=B/5, out=q/1, rows=32 00000:- 00001:- 00010:- 00011:- 00100:- 00101:- 00110:- 00111:- 01000:- 01001:- 01010:- 01011:- 01100:- 01101:- 01110:- 01111:- 10000:- 10001:- 10010:- 10011:- 10100:- 10101:- 10110:- 10111:- 11000:- 11001:- 11010:- 11011:- 11100:- 11101:- 11110:- 11111:-", nil),
    ("B[4..0] | q\n2x      | 0\n", nil, "Line 2: Hex value \"2x\" contains too many bits for B."),
    ("B[5..0] | q\n0x      | 0\n", "in=B/6, out=q/1, rows=64 000000:- 000001:- 000010:- 000011:- 000100:- 000101:- 000110:- 000111:- 001000:- 001001:- 001010:- 001011:- 001100:- 001101:- 001110:- 001111:- 010000:- 010001:- 010010:- 010011:- 010100:- 010101:- 010110:- 010111:- 011000:- 011001:- 011010:- 011011:- 011100:- 011101:- 011110:- 011111:- 100000:- 100001:- 100010:- 100011:- 100100:- 100101:- 100110:- 100111:- 101000:- 101001:- 101010:- 101011:- 101100:- 101101:- 101110:- 101111:- 110000:- 110001:- 110010:- 110011:- 110100:- 110101:- 110110:- 110111:- 111000:- 111001:- 111010:- 111011:- 111100:- 111101:- 111110:- 111111:-", nil),
    ("B[5..0] | q\n3f      | 0\n", "in=B/6, out=q/1, rows=64 000000:- 000001:- 000010:- 000011:- 000100:- 000101:- 000110:- 000111:- 001000:- 001001:- 001010:- 001011:- 001100:- 001101:- 001110:- 001111:- 010000:- 010001:- 010010:- 010011:- 010100:- 010101:- 010110:- 010111:- 011000:- 011001:- 011010:- 011011:- 011100:- 011101:- 011110:- 011111:- 100000:- 100001:- 100010:- 100011:- 100100:- 100101:- 100110:- 100111:- 101000:- 101001:- 101010:- 101011:- 101100:- 101101:- 101110:- 101111:- 110000:- 110001:- 110010:- 110011:- 110100:- 110101:- 110110:- 110111:- 111000:- 111001:- 111010:- 111011:- 111100:- 111101:- 111110:- 111111:-", nil),
    ("B[5..0] | q\n4f      | 0\n", nil, "Line 2: Hex value \"4f\" contains too many bits for B."),
  ]

  // MARK: - CsvInterpretor

  /// A `.csv` source -> the loaded model, dumped, or the message upstream logged.
  ///
  /// `dump == nil && error == nil` is upstream's *reject* outcome: `getInputsOutputs` or
  /// `checkEntries` failed, the constructor discarded the content, and `getTruthTable`
  /// therefore left the model untouched. This port throws a ``CsvImportError`` there
  /// instead: same information, same place, but not silently indistinguishable from
  /// "imported an empty file". The expected message is in ``csvLoadRejectMessage``.
  static let csvLoad: [(source: String, dump: String?, javaException: String?)] = [
    ("\"a\",\"b\",\"|\",\"q\"\n0,0,\"|\",0\n0,1,\"|\",1\n1,0,\"|\",1\n1,1,\"|\",0\n", "in=a/1,b/1, out=q/1, rows=4 00:0 01:1 10:1 11:0", nil),
    ("\"A\",\"B[3..0]\",,,,\"|\",\"D:3\",\"D:2\",\"D:1\",\"D:0\"\n0,0,0,-,0,\"|\",1,0,1,0\n0,0,0,0,1,\"|\",1,1,0,1\n0,0,0,1,1,\"|\",1,0,1,0\n0,0,1,0,0,\"|\",0,0,0,1\n0,0,1,0,1,\"|\",1,0,0,0\n0,0,1,1,0,\"|\",0,1,0,1\n0,0,1,1,1,\"|\",1,0,0,1\n0,1,0,0,0,\"|\",0,1,0,1\n0,1,0,0,1,\"|\",0,0,1,0\n0,1,0,1,0,\"|\",1,1,0,0\n0,1,0,1,1,\"|\",0,1,1,0\n0,1,1,0,0,\"|\",1,0,0,0\n0,1,1,0,1,\"|\",1,0,0,1\n0,1,1,1,0,\"|\",0,0,1,0\n0,1,1,1,1,\"|\",1,0,1,0\n1,-,-,-,-,\"|\",0,0,0,0\n", "in=A/1,B/4, out=D/4, rows=16 000-0:1010 00001:1101 00011:1010 00100:0001 00101:1000 00110:0101 00111:1001 01000:0101 01001:0010 01010:1100 01011:0110 01100:1000 01101:1001 01110:0010 01111:1010 1----:0000", nil),
    ("\"a\",\"b\",\"|\",\"q\"\n0,0,\"|\",0\n", "in=a/1,b/1, out=q/1, rows=4 00:- 01:- 10:- 11:-", nil),
    ("\"a\",\"b\",\"q\"\n0,0,0\n", nil, nil),
    ("\"|\",\"a\",\"b\"\n\"|\",0,0\n", nil, nil),
    ("\"a\",\"b\",\"|\"\n0,0,\"|\"\n", "in=a/1,b/1, out= rows=4 00: 01: 10: 11:", nil),
    ("\"D:3\",\"D:2\",\"D:1\",\"D:0\",\"|\",\"q\"\n0,0,0,0,\"|\",0\n", "in=D/4, out=q/1, rows=16 0000:- 0001:- 0010:- 0011:- 0100:- 0101:- 0110:- 0111:- 1000:- 1001:- 1010:- 1011:- 1100:- 1101:- 1110:- 1111:-", nil),
    ("\"D:0\",\"D:1\",\"D:2\",\"D:3\",\"|\",\"q\"\n0,0,0,0,\"|\",0\n", nil, nil),
    ("\"D:3\",\"D:1\",\"D:0\",\"|\",\"q\"\n0,0,0,\"|\",0\n", nil, nil),
    ("\"D:3\",\"D:3\",\"|\",\"q\"\n0,0,\"|\",0\n", nil, "IndexOutOfBoundsException"),
    ("\"D:3\",\"D:2\",\"D:1\",\"|\",\"q\"\n0,0,0,\"|\",0\n", nil, nil),
    ("\"a\",\"a\",\"|\",\"q\"\n0,0,\"|\",0\n", nil, nil),
    ("\"a\",\"B[3..0]\",\"|\",\"q\"\n0,0,\"|\",0\n", nil, nil),
    ("\"a\",\"B[3..0]\",,,\"|\",\"q\"\n0,0,0,0,\"|\",0\n", nil, nil),
    ("\"1a\",\"|\",\"q\"\n0,\"|\",0\n", nil, nil),
    ("\"a\",\"|\",\"q\"\n0,\"|\",2\n", nil, nil),
    ("\"a\",\"|\",\"q\"\n0,\"|\",0,1\n", nil, nil),
    ("\"a\",\"|\",\"q\"\n0,\"|\"\n", nil, nil),
    ("\"a\",\"|\",\"q\"\n", nil, nil),
  ]

  /// The messages upstream logged, in order, for the ``csvLoad`` rows it rejected. Captured
  /// from the probe's stderr; `%s` is the file name, which the probe randomised, so the
  /// name is written back as `FILE` on both sides.
  static let csvLoadRejectMessages: [String] = [
    "Line 1 of the csv file ‘FILE’ contains no separator field, aborting.",
    "Line 1 of the csv file ‘FILE’ does not contain any inputs, aborting.",
    "Line 1 of the csv file ‘FILE’ contains a incorrect bit-sequence for variable ‘D’, aborting.",
    "Line 1 of the csv file ‘FILE’ contains a incorrect bit-sequence for variable ‘D’, aborting.",
    "Line 1 of the csv file ‘FILE’ does not contain bit 0 of variable ‘d’, aborting.",
    "Line 1 of the csv file ‘FILE’ contains multiple times the variable ‘a’, aborting.",
    "Line 1 of the csv file ‘FILE’ contains not enough empty fields after variable ‘B[3..0]’, aborting.",
    "Line 1 of the csv file ‘FILE’ contains not enough empty fields after variable ‘B[3..0]’, aborting.",
    "Line 1 of the csv file ‘FILE’ contains the incorrect formatted label ‘1a’, aborting.",
    "Line 2 of the csv file ‘FILE’ contains an invalid entry ‘2’ at field 3, aborting.",
    "Line 2 of the csv file ‘FILE’ has 4 entries instead of the 3 required, aborting.",
    "Line 2 of the csv file ‘FILE’ has 2 entries instead of the 3 required, aborting.",
    "File “FILE” does not contain any entries, aborting.",
  ]

  // MARK: - KarnaughMapGroups

  /// Model spec + output name -> the covers, as
  /// `[<colourName>:(col,row,width,height)…]` per group, in `getCovers()` order.
  ///
  /// Group order is `OutputExpressions.getMinimalImplicants` order and the colour rotation
  /// is keyed off it, so these rows pin the minimiser's implicant ORDER as well as the
  /// rectangles; the same property `MinimizationGoldenData` exists to protect.
  static let covers: [(inputs: String, outputs: String, bits: String, output: String, count: Int, groups: String)] = [
    ("a,b", "q", "0110", "q", 2, "[LogisimKMapColor0:(1,0,1,1)][LogisimKMapColor1:(0,1,1,1)]"),
    ("a,b", "q", "1111", "q", 1, "[LogisimKMapColor0:(0,0,2,2)]"),
    ("a,b", "q", "0000", "q", 0, ""),
    ("a,b", "q", "1000", "q", 1, "[LogisimKMapColor0:(0,0,1,1)]"),
    ("a,b,c", "q", "01101001", "q", 4, "[LogisimKMapColor0:(1,0,1,1)][LogisimKMapColor1:(3,0,1,1)][LogisimKMapColor2:(0,1,1,1)][LogisimKMapColor3:(2,1,1,1)]"),
    ("a,b,c", "q", "11110000", "q", 1, "[LogisimKMapColor0:(0,0,4,1)]"),
    ("a,b,c", "q", "10101010", "q", 1, "[LogisimKMapColor0:(0,0,1,2)(3,0,1,2)]"),
    ("a,b,c,d", "q", "0110100110010110", "q", 8, "[LogisimKMapColor0:(1,0,1,1)][LogisimKMapColor1:(3,0,1,1)][LogisimKMapColor2:(0,1,1,1)][LogisimKMapColor3:(2,1,1,1)][LogisimKMapColor4:(0,3,1,1)][LogisimKMapColor5:(2,3,1,1)][LogisimKMapColor6:(1,2,1,1)][LogisimKMapColor7:(3,2,1,1)]"),
    ("a,b,c,d", "q", "1111000011110000", "q", 1, "[LogisimKMapColor0:(0,0,4,1)(0,3,4,1)]"),
    ("a,b,c,d", "q", "1001000000001001", "q", 4, "[LogisimKMapColor0:(0,0,1,1)][LogisimKMapColor1:(2,0,1,1)][LogisimKMapColor2:(0,2,1,1)][LogisimKMapColor3:(2,2,1,1)]"),
    ("a,b,c,d", "q", "1111111111111111", "q", 1, "[LogisimKMapColor0:(0,0,4,4)]"),
    ("a,b,c,d", "q", "1000000000000001", "q", 2, "[LogisimKMapColor0:(0,0,1,1)][LogisimKMapColor1:(2,2,1,1)]"),
    ("a,b,c,d", "q", "1100001111000011", "q", 2, "[LogisimKMapColor0:(0,0,2,1)(0,3,2,1)][LogisimKMapColor1:(2,1,2,2)]"),
    ("a,b,c,d,e", "q", "01101001100101100110100110010110", "q", 8, "[LogisimKMapColor0:(1,0,1,1)(1,3,1,1)][LogisimKMapColor1:(3,0,1,1)(3,3,1,1)][LogisimKMapColor2:(7,0,1,1)(7,3,1,1)][LogisimKMapColor3:(5,0,1,1)(5,3,1,1)][LogisimKMapColor4:(0,1,1,2)][LogisimKMapColor5:(2,1,1,2)][LogisimKMapColor6:(6,1,1,2)][LogisimKMapColor7:(4,1,1,2)]"),
    ("a,b,c,d,e", "q", "11110000111100001111000011110000", "q", 1, "[LogisimKMapColor0:(0,0,4,4)]"),
    ("a,b,c,d,e,f", "q", "0110100110010110011010011001011001101001100101100110100110010110", "q", 8, "[LogisimKMapColor0:(1,0,1,1)(1,3,1,2)(1,7,1,1)][LogisimKMapColor1:(3,0,1,1)(3,3,1,2)(3,7,1,1)][LogisimKMapColor2:(7,0,1,1)(7,3,1,2)(7,7,1,1)][LogisimKMapColor3:(5,0,1,1)(5,3,1,2)(5,7,1,1)][LogisimKMapColor4:(0,1,1,2)(0,5,1,2)][LogisimKMapColor5:(2,1,1,2)(2,5,1,2)][LogisimKMapColor6:(6,1,1,2)(6,5,1,2)][LogisimKMapColor7:(4,1,1,2)(4,5,1,2)]"),
    ("a,b,c,d", "q", "0111011101110111", "q", 2, "[LogisimKMapColor0:(1,0,2,4)][LogisimKMapColor1:(2,0,2,4)]"),
    ("a,b,c,d", "q", "0000111100001111", "q", 1, "[LogisimKMapColor0:(0,1,4,2)]"),
    ("a,b,c,d", "q", "1010101010101010", "q", 1, "[LogisimKMapColor0:(0,0,1,4)(3,0,1,4)]"),
    ("a,b,c,d", "q", "0101010101010101", "q", 1, "[LogisimKMapColor0:(1,0,2,4)]"),
  ]

  // MARK: - AnalyzerTexWriter.doSave

  /// Model spec -> the whole `.tex` document, minus the `\fancyhead[C]` date line.
  /// `AppPreferences.KMAP_LINED_STYLE` defaults to `false`, so these are the numbered style.
  static let tex: [(inputs: String, outputs: String, bits: String, document: String)] = [
    ("a,b", "q", "0110", "\\documentclass [15pt,a4paper,twoside]{article}\n\\usepackage[english,shorthands=off]{babel}        % shorhands=off is required for babel french in combination with tikz karnaugh....\n\\usepackage[utf8x]{inputenc}\n\\usepackage[T1]{fontenc}\n\\usepackage{amsmath}\n\\usepackage{geometry}\n\\geometry{verbose,a4paper, tmargin=3.5cm,bmargin=3.5cm,lmargin=2.5cm,rmargin=2.5cm,headsep=1cm,footskip=1.5cm}\n\\usepackage{fancyhdr}\n\\usepackage{colortbl}\n\\usepackage[dvipsnames]{xcolor}\n\\usepackage{tikz -timing}\n\\usepackage{tikz}\n\\usetikzlibrary{karnaugh}\n\\pagestyle{fancy}\n\n\\definecolor{LogisimKMapColor0}{RGB}{128,0,0}\n\\definecolor{LogisimKMapColor1}{RGB}{230,25,75}\n\\definecolor{LogisimKMapColor2}{RGB}{250,190,190}\n\\definecolor{LogisimKMapColor3}{RGB}{170,110,40}\n\\definecolor{LogisimKMapColor4}{RGB}{245,130,48}\n\\definecolor{LogisimKMapColor5}{RGB}{255,215,180}\n\\definecolor{LogisimKMapColor6}{RGB}{128,128,0}\n\\definecolor{LogisimKMapColor7}{RGB}{255,255,25}\n\\definecolor{LogisimKMapColor8}{RGB}{210,245,60}\n\\definecolor{LogisimKMapColor9}{RGB}{0,0,128}\n\\definecolor{LogisimKMapColor10}{RGB}{145,30,180}\n\\definecolor{LogisimKMapColor11}{RGB}{60,180,175}\n\\definecolor{LogisimKMapColor12}{RGB}{0,130,203}\n\\definecolor{LogisimKMapColor13}{RGB}{230,190,255}\n\\definecolor{LogisimKMapColor14}{RGB}{170,255,195}\n\\definecolor{LogisimKMapColor15}{RGB}{240,50,230}\n\n\\fancyhead{}\n\\fancyfoot[C] {\\thepage}\n\\renewcommand{\\headrulewidth}{0.4pt}\n\\renewcommand{\\footrulewidth}{0.4pt}\n\n\\makeatother\n\n\\begin{document}\n\\section{Introduction}\nThis document was generated by Logisim-evolution. Any part of the TeX sources can be used in your own documents without any problems. In case you want to use all/parts of this generated TeX-sources please (1) do not forget to include the required packages, and (2) include a remark that this source was generated by Logisim-evolution.\n%===============================================================================\n\\section{Truth table}\nThe table may be way to big to be displayed on the page. At generation time no calculation was done on the size of the table with respect to the width/height of the page.\n%-------------------------------------------------------------------------------\n\\subsection{Compacted truth table}\n\\begin{center}\n\\begin{tabular}{cc|c}\n$a$&$b$&$q$\\\\\n\\hline\n$0$&$0$&$0$\\\\\n$0$&$1$&$1$\\\\\n$1$&$0$&$1$\\\\\n$1$&$1$&$0$\\\\\n\n\\end{tabular}\n\\end{center}\n%-------------------------------------------------------------------------------\n\\subsection{Complete truth table}\n\\begin{center}\n\\begin{tabular}{cc|c}\n$a$&$b$&$q$\\\\\n\\hline\n$0$&$0$&$0$\\\\\n$0$&$1$&$1$\\\\\n$1$&$0$&$1$\\\\\n$1$&$1$&$0$\\\\\n\n\\end{tabular}\n\\end{center}\n%===============================================================================\n\\section{Karnaugh diagrams}\nThis section shows various versions of the Karnaugh diagrams of the given functions.\n%-------------------------------------------------------------------------------\n\\subsection{Empty Karnaugh diagrams}\n\\begin{center}\n\\begin{tikzpicture}[karnaugh,disable bars,x=1\\kmunitlength,y=1\\kmunitlength,kmbar left sep=1\\kmunitlength,grp/.style n args={4}{#1,fill=#1!30,minimum width= #2\\kmunitlength,minimum height=#3\\kmunitlength,rounded corners=0.2\\kmunitlength,fill opacity=0.6,rectangle,draw}]\n\\karnaughmap{2}{$q$}{{$a$}{$b$}}{}{\n\\draw[kmbox] (-0.5,2.5)\n   node[below left]{$a$}\n   node[above right]{$b$} +(-0.2,0.2)\n   node[above left]{$q$};\\draw (0,2) -- (-0.7,2.7);\n\\foreach \\x/\\1 in %\n{0/0,1/1} {\n   \\node at (\\x+0.5,2.2) {\\1};\n}\n\\foreach \\y/\\1 in %\n{0/0,1/1} {\n   \\node at (-0.4,-0.5-\\y+2) {\\1};\n}\n}\n\\end{tikzpicture}\n\\end{center}\n%-------------------------------------------------------------------------------\n\\subsection{Filled in Karnaugh diagrams}\n\\begin{center}\n\\begin{tikzpicture}[karnaugh,disable bars,x=1\\kmunitlength,y=1\\kmunitlength,kmbar left sep=1\\kmunitlength,grp/.style n args={4}{#1,fill=#1!30,minimum width= #2\\kmunitlength,minimum height=#3\\kmunitlength,rounded corners=0.2\\kmunitlength,fill opacity=0.6,rectangle,draw}]\n\\karnaughmap{2}{$q$}{{$a$}{$b$}}\n{0110}{\n\\draw[kmbox] (-0.5,2.5)\n   node[below left]{$a$}\n   node[above right]{$b$} +(-0.2,0.2)\n   node[above left]{$q$};\\draw (0,2) -- (-0.7,2.7);\n\\foreach \\x/\\1 in %\n{0/0,1/1} {\n   \\node at (\\x+0.5,2.2) {\\1};\n}\n\\foreach \\y/\\1 in %\n{0/0,1/1} {\n   \\node at (-0.4,-0.5-\\y+2) {\\1};\n}\n}\n\\end{tikzpicture}\n\\end{center}\n%-------------------------------------------------------------------------------\n\\subsection{Filled in Karnaugh diagrams with covers}\n\\begin{center}\n\\begin{tikzpicture}[karnaugh,disable bars,x=1\\kmunitlength,y=1\\kmunitlength,kmbar left sep=1\\kmunitlength,grp/.style n args={4}{#1,fill=#1!30,minimum width= #2\\kmunitlength,minimum height=#3\\kmunitlength,rounded corners=0.2\\kmunitlength,fill opacity=0.6,rectangle,draw}]\n\\karnaughmap{2}{$q$}{{$a$}{$b$}}\n{0110}{\n\\draw[kmbox] (-0.5,2.5)\n   node[below left]{$a$}\n   node[above right]{$b$} +(-0.2,0.2)\n   node[above left]{$q$};\\draw (0,2) -- (-0.7,2.7);\n\\foreach \\x/\\1 in %\n{0/0,1/1} {\n   \\node at (\\x+0.5,2.2) {\\1};\n}\n\\foreach \\y/\\1 in %\n{0/0,1/1} {\n   \\node at (-0.4,-0.5-\\y+2) {\\1};\n}\n   \\node[grp={LogisimKMapColor0}{0.8}{0.8}](n0) at(1.5,1.5) {};\n   \\node[grp={LogisimKMapColor1}{0.8}{0.8}](n1) at(0.5,0.5) {};\n}\n\\end{tikzpicture}\n\\end{center}\n%===============================================================================\n\\section{Minimal expressions}\n$q =  \\overline{a}  \\cdot b+a \\cdot  \\overline{b} $~\\\\\n\\end{document}\n"),
    ("a,b,c", "q", "01101001", "\\documentclass [15pt,a4paper,twoside]{article}\n\\usepackage[english,shorthands=off]{babel}        % shorhands=off is required for babel french in combination with tikz karnaugh....\n\\usepackage[utf8x]{inputenc}\n\\usepackage[T1]{fontenc}\n\\usepackage{amsmath}\n\\usepackage{geometry}\n\\geometry{verbose,a4paper, tmargin=3.5cm,bmargin=3.5cm,lmargin=2.5cm,rmargin=2.5cm,headsep=1cm,footskip=1.5cm}\n\\usepackage{fancyhdr}\n\\usepackage{colortbl}\n\\usepackage[dvipsnames]{xcolor}\n\\usepackage{tikz -timing}\n\\usepackage{tikz}\n\\usetikzlibrary{karnaugh}\n\\pagestyle{fancy}\n\n\\definecolor{LogisimKMapColor0}{RGB}{128,0,0}\n\\definecolor{LogisimKMapColor1}{RGB}{230,25,75}\n\\definecolor{LogisimKMapColor2}{RGB}{250,190,190}\n\\definecolor{LogisimKMapColor3}{RGB}{170,110,40}\n\\definecolor{LogisimKMapColor4}{RGB}{245,130,48}\n\\definecolor{LogisimKMapColor5}{RGB}{255,215,180}\n\\definecolor{LogisimKMapColor6}{RGB}{128,128,0}\n\\definecolor{LogisimKMapColor7}{RGB}{255,255,25}\n\\definecolor{LogisimKMapColor8}{RGB}{210,245,60}\n\\definecolor{LogisimKMapColor9}{RGB}{0,0,128}\n\\definecolor{LogisimKMapColor10}{RGB}{145,30,180}\n\\definecolor{LogisimKMapColor11}{RGB}{60,180,175}\n\\definecolor{LogisimKMapColor12}{RGB}{0,130,203}\n\\definecolor{LogisimKMapColor13}{RGB}{230,190,255}\n\\definecolor{LogisimKMapColor14}{RGB}{170,255,195}\n\\definecolor{LogisimKMapColor15}{RGB}{240,50,230}\n\n\\fancyhead{}\n\\fancyfoot[C] {\\thepage}\n\\renewcommand{\\headrulewidth}{0.4pt}\n\\renewcommand{\\footrulewidth}{0.4pt}\n\n\\makeatother\n\n\\begin{document}\n\\section{Introduction}\nThis document was generated by Logisim-evolution. Any part of the TeX sources can be used in your own documents without any problems. In case you want to use all/parts of this generated TeX-sources please (1) do not forget to include the required packages, and (2) include a remark that this source was generated by Logisim-evolution.\n%===============================================================================\n\\section{Truth table}\nThe table may be way to big to be displayed on the page. At generation time no calculation was done on the size of the table with respect to the width/height of the page.\n%-------------------------------------------------------------------------------\n\\subsection{Compacted truth table}\n\\begin{center}\n\\begin{tabular}{ccc|c}\n$a$&$b$&$c$&$q$\\\\\n\\hline\n$0$&$0$&$0$&$0$\\\\\n$0$&$0$&$1$&$1$\\\\\n$0$&$1$&$0$&$1$\\\\\n$0$&$1$&$1$&$0$\\\\\n$1$&$0$&$0$&$1$\\\\\n$1$&$0$&$1$&$0$\\\\\n$1$&$1$&$0$&$0$\\\\\n$1$&$1$&$1$&$1$\\\\\n\n\\end{tabular}\n\\end{center}\n%-------------------------------------------------------------------------------\n\\subsection{Complete truth table}\n\\begin{center}\n\\begin{tabular}{ccc|c}\n$a$&$b$&$c$&$q$\\\\\n\\hline\n$0$&$0$&$0$&$0$\\\\\n$0$&$0$&$1$&$1$\\\\\n$0$&$1$&$0$&$1$\\\\\n$0$&$1$&$1$&$0$\\\\\n$1$&$0$&$0$&$1$\\\\\n$1$&$0$&$1$&$0$\\\\\n$1$&$1$&$0$&$0$\\\\\n$1$&$1$&$1$&$1$\\\\\n\n\\end{tabular}\n\\end{center}\n%===============================================================================\n\\section{Karnaugh diagrams}\nThis section shows various versions of the Karnaugh diagrams of the given functions.\n%-------------------------------------------------------------------------------\n\\subsection{Empty Karnaugh diagrams}\n\\begin{center}\n\\begin{tikzpicture}[karnaugh,disable bars,x=1\\kmunitlength,y=1\\kmunitlength,kmbar left sep=1\\kmunitlength,grp/.style n args={4}{#1,fill=#1!30,minimum width= #2\\kmunitlength,minimum height=#3\\kmunitlength,rounded corners=0.2\\kmunitlength,fill opacity=0.6,rectangle,draw}]\n\\karnaughmap{3}{$q$}{{$b$}{$a$}{$c$}}{}{\n\\draw[kmbox] (-0.5,2.5)\n   node[below left]{$a$}\n   node[above right]{$b$, $c$} +(-0.2,0.2)\n   node[above left]{$q$};\\draw (0,2) -- (-0.7,2.7);\n\\foreach \\x/\\1 in %\n{0/00,1/01,2/11,3/10} {\n   \\node at (\\x+0.5,2.2) {\\1};\n}\n\\foreach \\y/\\1 in %\n{0/0,1/1} {\n   \\node at (-0.4,-0.5-\\y+2) {\\1};\n}\n}\n\\end{tikzpicture}\n\\end{center}\n%-------------------------------------------------------------------------------\n\\subsection{Filled in Karnaugh diagrams}\n\\begin{center}\n\\begin{tikzpicture}[karnaugh,disable bars,x=1\\kmunitlength,y=1\\kmunitlength,kmbar left sep=1\\kmunitlength,grp/.style n args={4}{#1,fill=#1!30,minimum width= #2\\kmunitlength,minimum height=#3\\kmunitlength,rounded corners=0.2\\kmunitlength,fill opacity=0.6,rectangle,draw}]\n\\karnaughmap{3}{$q$}{{$b$}{$a$}{$c$}}\n{01101001}{\n\\draw[kmbox] (-0.5,2.5)\n   node[below left]{$a$}\n   node[above right]{$b$, $c$} +(-0.2,0.2)\n   node[above left]{$q$};\\draw (0,2) -- (-0.7,2.7);\n\\foreach \\x/\\1 in %\n{0/00,1/01,2/11,3/10} {\n   \\node at (\\x+0.5,2.2) {\\1};\n}\n\\foreach \\y/\\1 in %\n{0/0,1/1} {\n   \\node at (-0.4,-0.5-\\y+2) {\\1};\n}\n}\n\\end{tikzpicture}\n\\end{center}\n%-------------------------------------------------------------------------------\n\\subsection{Filled in Karnaugh diagrams with covers}\n\\begin{center}\n\\begin{tikzpicture}[karnaugh,disable bars,x=1\\kmunitlength,y=1\\kmunitlength,kmbar left sep=1\\kmunitlength,grp/.style n args={4}{#1,fill=#1!30,minimum width= #2\\kmunitlength,minimum height=#3\\kmunitlength,rounded corners=0.2\\kmunitlength,fill opacity=0.6,rectangle,draw}]\n\\karnaughmap{3}{$q$}{{$b$}{$a$}{$c$}}\n{01101001}{\n\\draw[kmbox] (-0.5,2.5)\n   node[below left]{$a$}\n   node[above right]{$b$, $c$} +(-0.2,0.2)\n   node[above left]{$q$};\\draw (0,2) -- (-0.7,2.7);\n\\foreach \\x/\\1 in %\n{0/00,1/01,2/11,3/10} {\n   \\node at (\\x+0.5,2.2) {\\1};\n}\n\\foreach \\y/\\1 in %\n{0/0,1/1} {\n   \\node at (-0.4,-0.5-\\y+2) {\\1};\n}\n   \\node[grp={LogisimKMapColor0}{0.8}{0.8}](n0) at(1.5,1.5) {};\n   \\node[grp={LogisimKMapColor1}{0.8}{0.8}](n1) at(3.5,1.5) {};\n   \\node[grp={LogisimKMapColor2}{0.8}{0.8}](n2) at(0.5,0.5) {};\n   \\node[grp={LogisimKMapColor3}{0.8}{0.8}](n3) at(2.5,0.5) {};\n}\n\\end{tikzpicture}\n\\end{center}\n%===============================================================================\n\\section{Minimal expressions}\n$q =  \\overline{a}  \\cdot  \\overline{b}  \\cdot c+ \\overline{a}  \\cdot b \\cdot  \\overline{c} +a \\cdot  \\overline{b}  \\cdot  \\overline{c} +a \\cdot b \\cdot c$~\\\\\n\\end{document}\n"),
    ("a,b,c,d", "q", "0110100110010110", "\\documentclass [15pt,a4paper,twoside]{article}\n\\usepackage[english,shorthands=off]{babel}        % shorhands=off is required for babel french in combination with tikz karnaugh....\n\\usepackage[utf8x]{inputenc}\n\\usepackage[T1]{fontenc}\n\\usepackage{amsmath}\n\\usepackage{geometry}\n\\geometry{verbose,a4paper, tmargin=3.5cm,bmargin=3.5cm,lmargin=2.5cm,rmargin=2.5cm,headsep=1cm,footskip=1.5cm}\n\\usepackage{fancyhdr}\n\\usepackage{colortbl}\n\\usepackage[dvipsnames]{xcolor}\n\\usepackage{tikz -timing}\n\\usepackage{tikz}\n\\usetikzlibrary{karnaugh}\n\\pagestyle{fancy}\n\n\\definecolor{LogisimKMapColor0}{RGB}{128,0,0}\n\\definecolor{LogisimKMapColor1}{RGB}{230,25,75}\n\\definecolor{LogisimKMapColor2}{RGB}{250,190,190}\n\\definecolor{LogisimKMapColor3}{RGB}{170,110,40}\n\\definecolor{LogisimKMapColor4}{RGB}{245,130,48}\n\\definecolor{LogisimKMapColor5}{RGB}{255,215,180}\n\\definecolor{LogisimKMapColor6}{RGB}{128,128,0}\n\\definecolor{LogisimKMapColor7}{RGB}{255,255,25}\n\\definecolor{LogisimKMapColor8}{RGB}{210,245,60}\n\\definecolor{LogisimKMapColor9}{RGB}{0,0,128}\n\\definecolor{LogisimKMapColor10}{RGB}{145,30,180}\n\\definecolor{LogisimKMapColor11}{RGB}{60,180,175}\n\\definecolor{LogisimKMapColor12}{RGB}{0,130,203}\n\\definecolor{LogisimKMapColor13}{RGB}{230,190,255}\n\\definecolor{LogisimKMapColor14}{RGB}{170,255,195}\n\\definecolor{LogisimKMapColor15}{RGB}{240,50,230}\n\n\\fancyhead{}\n\\fancyfoot[C] {\\thepage}\n\\renewcommand{\\headrulewidth}{0.4pt}\n\\renewcommand{\\footrulewidth}{0.4pt}\n\n\\makeatother\n\n\\begin{document}\n\\section{Introduction}\nThis document was generated by Logisim-evolution. Any part of the TeX sources can be used in your own documents without any problems. In case you want to use all/parts of this generated TeX-sources please (1) do not forget to include the required packages, and (2) include a remark that this source was generated by Logisim-evolution.\n%===============================================================================\n\\section{Truth table}\nThe table may be way to big to be displayed on the page. At generation time no calculation was done on the size of the table with respect to the width/height of the page.\n%-------------------------------------------------------------------------------\n\\subsection{Compacted truth table}\n\\begin{center}\n\\begin{tabular}{cccc|c}\n$a$&$b$&$c$&$d$&$q$\\\\\n\\hline\n$0$&$0$&$0$&$0$&$0$\\\\\n$0$&$0$&$0$&$1$&$1$\\\\\n$0$&$0$&$1$&$0$&$1$\\\\\n$0$&$0$&$1$&$1$&$0$\\\\\n$0$&$1$&$0$&$0$&$1$\\\\\n$0$&$1$&$0$&$1$&$0$\\\\\n$0$&$1$&$1$&$0$&$0$\\\\\n$0$&$1$&$1$&$1$&$1$\\\\\n$1$&$0$&$0$&$0$&$1$\\\\\n$1$&$0$&$0$&$1$&$0$\\\\\n$1$&$0$&$1$&$0$&$0$\\\\\n$1$&$0$&$1$&$1$&$1$\\\\\n$1$&$1$&$0$&$0$&$0$\\\\\n$1$&$1$&$0$&$1$&$1$\\\\\n$1$&$1$&$1$&$0$&$1$\\\\\n$1$&$1$&$1$&$1$&$0$\\\\\n\n\\end{tabular}\n\\end{center}\n%-------------------------------------------------------------------------------\n\\subsection{Complete truth table}\n\\begin{center}\n\\begin{tabular}{cccc|c}\n$a$&$b$&$c$&$d$&$q$\\\\\n\\hline\n$0$&$0$&$0$&$0$&$0$\\\\\n$0$&$0$&$0$&$1$&$1$\\\\\n$0$&$0$&$1$&$0$&$1$\\\\\n$0$&$0$&$1$&$1$&$0$\\\\\n$0$&$1$&$0$&$0$&$1$\\\\\n$0$&$1$&$0$&$1$&$0$\\\\\n$0$&$1$&$1$&$0$&$0$\\\\\n$0$&$1$&$1$&$1$&$1$\\\\\n$1$&$0$&$0$&$0$&$1$\\\\\n$1$&$0$&$0$&$1$&$0$\\\\\n$1$&$0$&$1$&$0$&$0$\\\\\n$1$&$0$&$1$&$1$&$1$\\\\\n$1$&$1$&$0$&$0$&$0$\\\\\n$1$&$1$&$0$&$1$&$1$\\\\\n$1$&$1$&$1$&$0$&$1$\\\\\n$1$&$1$&$1$&$1$&$0$\\\\\n\n\\end{tabular}\n\\end{center}\n%===============================================================================\n\\section{Karnaugh diagrams}\nThis section shows various versions of the Karnaugh diagrams of the given functions.\n%-------------------------------------------------------------------------------\n\\subsection{Empty Karnaugh diagrams}\n\\begin{center}\n\\begin{tikzpicture}[karnaugh,disable bars,x=1\\kmunitlength,y=1\\kmunitlength,kmbar left sep=1\\kmunitlength,grp/.style n args={4}{#1,fill=#1!30,minimum width= #2\\kmunitlength,minimum height=#3\\kmunitlength,rounded corners=0.2\\kmunitlength,fill opacity=0.6,rectangle,draw}]\n\\karnaughmap{4}{$q$}{{$a$}{$c$}{$b$}{$d$}}{}{\n\\draw[kmbox] (-0.5,4.5)\n   node[below left]{$a$, $b$}\n   node[above right]{$c$, $d$} +(-0.2,0.2)\n   node[above left]{$q$};\\draw (0,4) -- (-0.7,4.7);\n\\foreach \\x/\\1 in %\n{0/00,1/01,2/11,3/10} {\n   \\node at (\\x+0.5,4.2) {\\1};\n}\n\\foreach \\y/\\1 in %\n{0/00,1/01,2/11,3/10} {\n   \\node at (-0.4,-0.5-\\y+4) {\\1};\n}\n}\n\\end{tikzpicture}\n\\end{center}\n%-------------------------------------------------------------------------------\n\\subsection{Filled in Karnaugh diagrams}\n\\begin{center}\n\\begin{tikzpicture}[karnaugh,disable bars,x=1\\kmunitlength,y=1\\kmunitlength,kmbar left sep=1\\kmunitlength,grp/.style n args={4}{#1,fill=#1!30,minimum width= #2\\kmunitlength,minimum height=#3\\kmunitlength,rounded corners=0.2\\kmunitlength,fill opacity=0.6,rectangle,draw}]\n\\karnaughmap{4}{$q$}{{$a$}{$c$}{$b$}{$d$}}\n{0110100110010110}{\n\\draw[kmbox] (-0.5,4.5)\n   node[below left]{$a$, $b$}\n   node[above right]{$c$, $d$} +(-0.2,0.2)\n   node[above left]{$q$};\\draw (0,4) -- (-0.7,4.7);\n\\foreach \\x/\\1 in %\n{0/00,1/01,2/11,3/10} {\n   \\node at (\\x+0.5,4.2) {\\1};\n}\n\\foreach \\y/\\1 in %\n{0/00,1/01,2/11,3/10} {\n   \\node at (-0.4,-0.5-\\y+4) {\\1};\n}\n}\n\\end{tikzpicture}\n\\end{center}\n%-------------------------------------------------------------------------------\n\\subsection{Filled in Karnaugh diagrams with covers}\n\\begin{center}\n\\begin{tikzpicture}[karnaugh,disable bars,x=1\\kmunitlength,y=1\\kmunitlength,kmbar left sep=1\\kmunitlength,grp/.style n args={4}{#1,fill=#1!30,minimum width= #2\\kmunitlength,minimum height=#3\\kmunitlength,rounded corners=0.2\\kmunitlength,fill opacity=0.6,rectangle,draw}]\n\\karnaughmap{4}{$q$}{{$a$}{$c$}{$b$}{$d$}}\n{0110100110010110}{\n\\draw[kmbox] (-0.5,4.5)\n   node[below left]{$a$, $b$}\n   node[above right]{$c$, $d$} +(-0.2,0.2)\n   node[above left]{$q$};\\draw (0,4) -- (-0.7,4.7);\n\\foreach \\x/\\1 in %\n{0/00,1/01,2/11,3/10} {\n   \\node at (\\x+0.5,4.2) {\\1};\n}\n\\foreach \\y/\\1 in %\n{0/00,1/01,2/11,3/10} {\n   \\node at (-0.4,-0.5-\\y+4) {\\1};\n}\n   \\node[grp={LogisimKMapColor0}{0.8}{0.8}](n0) at(1.5,3.5) {};\n   \\node[grp={LogisimKMapColor1}{0.8}{0.8}](n1) at(3.5,3.5) {};\n   \\node[grp={LogisimKMapColor2}{0.8}{0.8}](n2) at(0.5,2.5) {};\n   \\node[grp={LogisimKMapColor3}{0.8}{0.8}](n3) at(2.5,2.5) {};\n   \\node[grp={LogisimKMapColor4}{0.8}{0.8}](n4) at(0.5,0.5) {};\n   \\node[grp={LogisimKMapColor5}{0.8}{0.8}](n5) at(2.5,0.5) {};\n   \\node[grp={LogisimKMapColor6}{0.8}{0.8}](n6) at(1.5,1.5) {};\n   \\node[grp={LogisimKMapColor7}{0.8}{0.8}](n7) at(3.5,1.5) {};\n}\n\\end{tikzpicture}\n\\end{center}\n%===============================================================================\n\\section{Minimal expressions}\n$q =  \\overline{a}  \\cdot  \\overline{b}  \\cdot  \\overline{c}  \\cdot d+ \\overline{a}  \\cdot  \\overline{b}  \\cdot c \\cdot  \\overline{d} + \\overline{a}  \\cdot b \\cdot  \\overline{c}  \\cdot  \\overline{d} + \\overline{a}  \\cdot b \\cdot c \\cdot d+a \\cdot  \\overline{b}  \\cdot  \\overline{c}  \\cdot  \\overline{d} +a \\cdot  \\overline{b}  \\cdot c \\cdot d+a \\cdot b \\cdot  \\overline{c}  \\cdot d+a \\cdot b \\cdot c \\cdot  \\overline{d} $~\\\\\n\\end{document}\n"),
    ("a,bb/2", "q/2", "0110100110010110", "\\documentclass [15pt,a4paper,twoside]{article}\n\\usepackage[english,shorthands=off]{babel}        % shorhands=off is required for babel french in combination with tikz karnaugh....\n\\usepackage[utf8x]{inputenc}\n\\usepackage[T1]{fontenc}\n\\usepackage{amsmath}\n\\usepackage{geometry}\n\\geometry{verbose,a4paper, tmargin=3.5cm,bmargin=3.5cm,lmargin=2.5cm,rmargin=2.5cm,headsep=1cm,footskip=1.5cm}\n\\usepackage{fancyhdr}\n\\usepackage{colortbl}\n\\usepackage[dvipsnames]{xcolor}\n\\usepackage{tikz -timing}\n\\usepackage{tikz}\n\\usetikzlibrary{karnaugh}\n\\pagestyle{fancy}\n\n\\definecolor{LogisimKMapColor0}{RGB}{128,0,0}\n\\definecolor{LogisimKMapColor1}{RGB}{230,25,75}\n\\definecolor{LogisimKMapColor2}{RGB}{250,190,190}\n\\definecolor{LogisimKMapColor3}{RGB}{170,110,40}\n\\definecolor{LogisimKMapColor4}{RGB}{245,130,48}\n\\definecolor{LogisimKMapColor5}{RGB}{255,215,180}\n\\definecolor{LogisimKMapColor6}{RGB}{128,128,0}\n\\definecolor{LogisimKMapColor7}{RGB}{255,255,25}\n\\definecolor{LogisimKMapColor8}{RGB}{210,245,60}\n\\definecolor{LogisimKMapColor9}{RGB}{0,0,128}\n\\definecolor{LogisimKMapColor10}{RGB}{145,30,180}\n\\definecolor{LogisimKMapColor11}{RGB}{60,180,175}\n\\definecolor{LogisimKMapColor12}{RGB}{0,130,203}\n\\definecolor{LogisimKMapColor13}{RGB}{230,190,255}\n\\definecolor{LogisimKMapColor14}{RGB}{170,255,195}\n\\definecolor{LogisimKMapColor15}{RGB}{240,50,230}\n\n\\fancyhead{}\n\\fancyfoot[C] {\\thepage}\n\\renewcommand{\\headrulewidth}{0.4pt}\n\\renewcommand{\\footrulewidth}{0.4pt}\n\n\\makeatother\n\n\\begin{document}\n\\section{Introduction}\nThis document was generated by Logisim-evolution. Any part of the TeX sources can be used in your own documents without any problems. In case you want to use all/parts of this generated TeX-sources please (1) do not forget to include the required packages, and (2) include a remark that this source was generated by Logisim-evolution.\n%===============================================================================\n\\section{Truth table}\nThe table may be way to big to be displayed on the page. At generation time no calculation was done on the size of the table with respect to the width/height of the page.\n%-------------------------------------------------------------------------------\n\\subsection{Compacted truth table}\n\\begin{center}\n\\begin{tabular}{ccc|cc}\n$a$&\\multicolumn{2}{c|}{$bb[1..0]$}&\\multicolumn{2}{c}{$q[1..0]$}\\\\\n\\hline\n$0$&$0$&$0$&$0$&$1$\\\\\n$0$&$0$&$1$&$1$&$0$\\\\\n$0$&$1$&$0$&$1$&$0$\\\\\n$0$&$1$&$1$&$0$&$1$\\\\\n$1$&$0$&$0$&$1$&$0$\\\\\n$1$&$0$&$1$&$0$&$1$\\\\\n$1$&$1$&$0$&$0$&$1$\\\\\n$1$&$1$&$1$&$1$&$0$\\\\\n\n\\end{tabular}\n\\end{center}\n%-------------------------------------------------------------------------------\n\\subsection{Complete truth table}\n\\begin{center}\n\\begin{tabular}{ccc|cc}\n$a$&\\multicolumn{2}{c|}{$bb[1..0]$}&\\multicolumn{2}{c}{$q[1..0]$}\\\\\n\\hline\n$0$&$0$&$0$&$0$&$1$\\\\\n$0$&$0$&$1$&$1$&$0$\\\\\n$0$&$1$&$0$&$1$&$0$\\\\\n$0$&$1$&$1$&$0$&$1$\\\\\n$1$&$0$&$0$&$1$&$0$\\\\\n$1$&$0$&$1$&$0$&$1$\\\\\n$1$&$1$&$0$&$0$&$1$\\\\\n$1$&$1$&$1$&$1$&$0$\\\\\n\n\\end{tabular}\n\\end{center}\n%===============================================================================\n\\section{Karnaugh diagrams}\nThis section shows various versions of the Karnaugh diagrams of the given functions.\n%-------------------------------------------------------------------------------\n\\subsection{Empty Karnaugh diagrams}\n\\begin{center}\n\\begin{tikzpicture}[karnaugh,disable bars,x=1\\kmunitlength,y=1\\kmunitlength,kmbar left sep=1\\kmunitlength,grp/.style n args={4}{#1,fill=#1!30,minimum width= #2\\kmunitlength,minimum height=#3\\kmunitlength,rounded corners=0.2\\kmunitlength,fill opacity=0.6,rectangle,draw}]\n\\karnaughmap{3}{$q_{1}$}{{$bb_1$}{$a$}{$bb_0$}}{}{\n\\draw[kmbox] (-0.5,2.5)\n   node[below left]{$a$}\n   node[above right]{$bb_{2}$, $bb_{1}$, $bb_{0}$} +(-0.2,0.2)\n   node[above left]{$q_{1}$};\\draw (0,2) -- (-0.7,2.7);\n\\foreach \\x/\\1 in %\n{0/00,1/01,2/11,3/10} {\n   \\node at (\\x+0.5,2.2) {\\1};\n}\n\\foreach \\y/\\1 in %\n{0/0,1/1} {\n   \\node at (-0.4,-0.5-\\y+2) {\\1};\n}\n}\n\\end{tikzpicture}\n\\end{center}\n\\begin{center}\n\\begin{tikzpicture}[karnaugh,disable bars,x=1\\kmunitlength,y=1\\kmunitlength,kmbar left sep=1\\kmunitlength,grp/.style n args={4}{#1,fill=#1!30,minimum width= #2\\kmunitlength,minimum height=#3\\kmunitlength,rounded corners=0.2\\kmunitlength,fill opacity=0.6,rectangle,draw}]\n\\karnaughmap{3}{$q_{0}$}{{$bb_1$}{$a$}{$bb_0$}}{}{\n\\draw[kmbox] (-0.5,2.5)\n   node[below left]{$a$}\n   node[above right]{$bb_{2}$, $bb_{1}$, $bb_{0}$} +(-0.2,0.2)\n   node[above left]{$q_{0}$};\\draw (0,2) -- (-0.7,2.7);\n\\foreach \\x/\\1 in %\n{0/00,1/01,2/11,3/10} {\n   \\node at (\\x+0.5,2.2) {\\1};\n}\n\\foreach \\y/\\1 in %\n{0/0,1/1} {\n   \\node at (-0.4,-0.5-\\y+2) {\\1};\n}\n}\n\\end{tikzpicture}\n\\end{center}\n%-------------------------------------------------------------------------------\n\\subsection{Filled in Karnaugh diagrams}\n\\begin{center}\n\\begin{tikzpicture}[karnaugh,disable bars,x=1\\kmunitlength,y=1\\kmunitlength,kmbar left sep=1\\kmunitlength,grp/.style n args={4}{#1,fill=#1!30,minimum width= #2\\kmunitlength,minimum height=#3\\kmunitlength,rounded corners=0.2\\kmunitlength,fill opacity=0.6,rectangle,draw}]\n\\karnaughmap{3}{$q_{1}$}{{$bb_1$}{$a$}{$bb_0$}}\n{01101001}{\n\\draw[kmbox] (-0.5,2.5)\n   node[below left]{$a$}\n   node[above right]{$bb_{2}$, $bb_{1}$, $bb_{0}$} +(-0.2,0.2)\n   node[above left]{$q_{1}$};\\draw (0,2) -- (-0.7,2.7);\n\\foreach \\x/\\1 in %\n{0/00,1/01,2/11,3/10} {\n   \\node at (\\x+0.5,2.2) {\\1};\n}\n\\foreach \\y/\\1 in %\n{0/0,1/1} {\n   \\node at (-0.4,-0.5-\\y+2) {\\1};\n}\n}\n\\end{tikzpicture}\n\\end{center}\n\\begin{center}\n\\begin{tikzpicture}[karnaugh,disable bars,x=1\\kmunitlength,y=1\\kmunitlength,kmbar left sep=1\\kmunitlength,grp/.style n args={4}{#1,fill=#1!30,minimum width= #2\\kmunitlength,minimum height=#3\\kmunitlength,rounded corners=0.2\\kmunitlength,fill opacity=0.6,rectangle,draw}]\n\\karnaughmap{3}{$q_{0}$}{{$bb_1$}{$a$}{$bb_0$}}\n{10010110}{\n\\draw[kmbox] (-0.5,2.5)\n   node[below left]{$a$}\n   node[above right]{$bb_{2}$, $bb_{1}$, $bb_{0}$} +(-0.2,0.2)\n   node[above left]{$q_{0}$};\\draw (0,2) -- (-0.7,2.7);\n\\foreach \\x/\\1 in %\n{0/00,1/01,2/11,3/10} {\n   \\node at (\\x+0.5,2.2) {\\1};\n}\n\\foreach \\y/\\1 in %\n{0/0,1/1} {\n   \\node at (-0.4,-0.5-\\y+2) {\\1};\n}\n}\n\\end{tikzpicture}\n\\end{center}\n%-------------------------------------------------------------------------------\n\\subsection{Filled in Karnaugh diagrams with covers}\n\\begin{center}\n\\begin{tikzpicture}[karnaugh,disable bars,x=1\\kmunitlength,y=1\\kmunitlength,kmbar left sep=1\\kmunitlength,grp/.style n args={4}{#1,fill=#1!30,minimum width= #2\\kmunitlength,minimum height=#3\\kmunitlength,rounded corners=0.2\\kmunitlength,fill opacity=0.6,rectangle,draw}]\n\\karnaughmap{3}{$q_{1}$}{{$bb_1$}{$a$}{$bb_0$}}\n{01101001}{\n\\draw[kmbox] (-0.5,2.5)\n   node[below left]{$a$}\n   node[above right]{$bb_{2}$, $bb_{1}$, $bb_{0}$} +(-0.2,0.2)\n   node[above left]{$q_{1}$};\\draw (0,2) -- (-0.7,2.7);\n\\foreach \\x/\\1 in %\n{0/00,1/01,2/11,3/10} {\n   \\node at (\\x+0.5,2.2) {\\1};\n}\n\\foreach \\y/\\1 in %\n{0/0,1/1} {\n   \\node at (-0.4,-0.5-\\y+2) {\\1};\n}\n   \\node[grp={LogisimKMapColor0}{0.8}{0.8}](n0) at(1.5,1.5) {};\n   \\node[grp={LogisimKMapColor1}{0.8}{0.8}](n1) at(3.5,1.5) {};\n   \\node[grp={LogisimKMapColor2}{0.8}{0.8}](n2) at(0.5,0.5) {};\n   \\node[grp={LogisimKMapColor3}{0.8}{0.8}](n3) at(2.5,0.5) {};\n}\n\\end{tikzpicture}\n\\end{center}\n\\begin{center}\n\\begin{tikzpicture}[karnaugh,disable bars,x=1\\kmunitlength,y=1\\kmunitlength,kmbar left sep=1\\kmunitlength,grp/.style n args={4}{#1,fill=#1!30,minimum width= #2\\kmunitlength,minimum height=#3\\kmunitlength,rounded corners=0.2\\kmunitlength,fill opacity=0.6,rectangle,draw}]\n\\karnaughmap{3}{$q_{0}$}{{$bb_1$}{$a$}{$bb_0$}}\n{10010110}{\n\\draw[kmbox] (-0.5,2.5)\n   node[below left]{$a$}\n   node[above right]{$bb_{2}$, $bb_{1}$, $bb_{0}$} +(-0.2,0.2)\n   node[above left]{$q_{0}$};\\draw (0,2) -- (-0.7,2.7);\n\\foreach \\x/\\1 in %\n{0/00,1/01,2/11,3/10} {\n   \\node at (\\x+0.5,2.2) {\\1};\n}\n\\foreach \\y/\\1 in %\n{0/0,1/1} {\n   \\node at (-0.4,-0.5-\\y+2) {\\1};\n}\n   \\node[grp={LogisimKMapColor0}{0.8}{0.8}](n0) at(0.5,1.5) {};\n   \\node[grp={LogisimKMapColor1}{0.8}{0.8}](n1) at(2.5,1.5) {};\n   \\node[grp={LogisimKMapColor2}{0.8}{0.8}](n2) at(1.5,0.5) {};\n   \\node[grp={LogisimKMapColor3}{0.8}{0.8}](n3) at(3.5,0.5) {};\n}\n\\end{tikzpicture}\n\\end{center}\n%===============================================================================\n\\section{Minimal expressions}\n$q_{1} =  \\overline{a}  \\cdot  \\overline{bb_{1}}  \\cdot bb_{0}+ \\overline{a}  \\cdot bb_{1} \\cdot  \\overline{bb_{0}} +a \\cdot  \\overline{bb_{1}}  \\cdot  \\overline{bb_{0}} +a \\cdot bb_{1} \\cdot bb_{0}$~\\\\\n$q_{0} =  \\overline{a}  \\cdot  \\overline{bb_{1}}  \\cdot  \\overline{bb_{0}} + \\overline{a}  \\cdot bb_{1} \\cdot bb_{0}+a \\cdot  \\overline{bb_{1}}  \\cdot bb_{0}+a \\cdot bb_{1} \\cdot  \\overline{bb_{0}} $~\\\\\n\\end{document}\n"),
    ("a,b,c,d,e,f,g", "q", "01101001", "\\documentclass [15pt,a4paper,twoside]{article}\n\\usepackage[english,shorthands=off]{babel}        % shorhands=off is required for babel french in combination with tikz karnaugh....\n\\usepackage[utf8x]{inputenc}\n\\usepackage[T1]{fontenc}\n\\usepackage{amsmath}\n\\usepackage{geometry}\n\\geometry{verbose,a4paper, tmargin=3.5cm,bmargin=3.5cm,lmargin=2.5cm,rmargin=2.5cm,headsep=1cm,footskip=1.5cm}\n\\usepackage{fancyhdr}\n\\usepackage{colortbl}\n\\usepackage[dvipsnames]{xcolor}\n\\usepackage{tikz -timing}\n\\usepackage{tikz}\n\\usetikzlibrary{karnaugh}\n\\pagestyle{fancy}\n\n\\definecolor{LogisimKMapColor0}{RGB}{128,0,0}\n\\definecolor{LogisimKMapColor1}{RGB}{230,25,75}\n\\definecolor{LogisimKMapColor2}{RGB}{250,190,190}\n\\definecolor{LogisimKMapColor3}{RGB}{170,110,40}\n\\definecolor{LogisimKMapColor4}{RGB}{245,130,48}\n\\definecolor{LogisimKMapColor5}{RGB}{255,215,180}\n\\definecolor{LogisimKMapColor6}{RGB}{128,128,0}\n\\definecolor{LogisimKMapColor7}{RGB}{255,255,25}\n\\definecolor{LogisimKMapColor8}{RGB}{210,245,60}\n\\definecolor{LogisimKMapColor9}{RGB}{0,0,128}\n\\definecolor{LogisimKMapColor10}{RGB}{145,30,180}\n\\definecolor{LogisimKMapColor11}{RGB}{60,180,175}\n\\definecolor{LogisimKMapColor12}{RGB}{0,130,203}\n\\definecolor{LogisimKMapColor13}{RGB}{230,190,255}\n\\definecolor{LogisimKMapColor14}{RGB}{170,255,195}\n\\definecolor{LogisimKMapColor15}{RGB}{240,50,230}\n\n\\fancyhead{}\n\\fancyfoot[C] {\\thepage}\n\\renewcommand{\\headrulewidth}{0.4pt}\n\\renewcommand{\\footrulewidth}{0.4pt}\n\n\\makeatother\n\n\\begin{document}\n\\section{Introduction}\nThis document was generated by Logisim-evolution. Any part of the TeX sources can be used in your own documents without any problems. In case you want to use all/parts of this generated TeX-sources please (1) do not forget to include the required packages, and (2) include a remark that this source was generated by Logisim-evolution.\n%===============================================================================\n\\section{Truth table}\nThe table may be way to big to be displayed on the page. At generation time no calculation was done on the size of the table with respect to the width/height of the page.\n\\\\~\\\\The truth table has more than 64 entries, it makes no sense to show it here.\n%===============================================================================\n\\section{Karnaugh diagrams}\nCannot display Karnaugh diagrams with more than 6 input vars.\n\\end{document}\n"),
  ]
}
