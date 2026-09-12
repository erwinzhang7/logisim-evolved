# analyze/ — differential probes for the LogisimAnalyze port

Each probe is declared in package `com.cburch.logisim.analyze.model` so that it can reach the
package-private members of the analyze model (`Implicant.computeMinimal`,
`Expression.removeVariable`, `TruthTable.findRow`, …). They print one line per case; those
lines are the golden data embedded in `swift/Tests/LogisimAnalyzeTests/*GoldenData.swift`.

    JAR=/Applications/Logisim-evolution.app/Contents/app/logisim-evolution-4.1.0-all.jar
    JAVA=/opt/homebrew/opt/openjdk@21/bin/java
    /opt/homebrew/opt/openjdk@21/bin/javac -cp "$JAR" -d /tmp/anaprobe *.java
    "$JAVA" -Djava.awt.headless=true -cp "$JAR:/tmp/anaprobe" \
        com.cburch.logisim.analyze.model.MinProbe < cases.txt

| probe | feeds |
|---|---|
| `MinProbe` | `MinimizationGoldenData.swift`, `ScaleTests.swift`; `stdin` is `<inputs> <outputSpec> [pos]` |
| `ParseProbe` | `ParserGoldenData.swift`; `stdin` is one expression per line, `A:` prefix for `parseMaybeAssignment` |
| `EvalProbe` | `ExpressionTests.evaluationAndRewritesMatchTheJavaOracle` |
| `RenderProbe` | `ExpressionTests.reducedRenderingMatchesTheJavaOracle` |
| `TableProbe` | `TruthTableTests`: a fixed reshaping script, no stdin |
| `OutProbe` | `OutputExpressionsTests`: a fixed editing script, no stdin |
| `AnaFileProbe` | `AnalyzeFileGoldenData.swift`; the file/data layer. Takes the mode as `argv[0]`; see its class comment for the eleven modes and their stdin shapes. It is declared in `com.cburch.logisim.analyze.file`, not `.model`. |

D16: the jar is **4.1.0**, the shipped one, not a build of `main`.

`AnaFileProbe` sets `Main.headless = true` (D17) before anything else. Every error path in the
file/data layer ends in an `OptionPane`, so without it the probe dies with
`HeadlessException` and records nothing; with it, messages go to stderr and
`showConfirmDialog` returns `CANCEL_OPTION`; the same answer as the port's default
`resolveInconsistentRows`. Its stderr is golden data too (`csvLoadRejectMessages`).

Two probes deliberately record upstream *crashes* rather than results
(`StringIndexOutOfBoundsException` from `Parser` on any expression ending in a bracketed bit
subscript). See the divergence notes in `Parser.swift` and `ParserTests.swift`.
