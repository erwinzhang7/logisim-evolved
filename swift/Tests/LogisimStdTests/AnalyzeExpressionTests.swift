// AnalyzeExpressionTests.swift: part of logisim-evolved.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// The gate for `CircuitExpressions` (the port of `com.cburch.logisim.circuit.Analyze`) and for
// the `ExpressionComputer` feature on the gates.
//
// ── The oracle, and the trap that nearly invalidated it ─────────────────────────────────────
//
// `ExprProbe.java` runs the 4.1.0 jar's own `Analyze.computeExpression` headlessly and prints
// each derived expression as a fully-parenthesised prefix form, `(OR (AND (VAR a) (VAR b))
// (VAR c))`, so the assertion is on the expression **tree**, not on a rendered string that
// both sides would have to print identically for the test to mean anything. The probe source is
// reproduced at the bottom of this file.
//
// **The first version of that probe measured the wrong thing, and it looked right.** It read the
// result back with `model.getOutputExpressions().getExpression(name)`, which is the obvious API
// and is what the Analyze window itself displays. That returned:
//
//     nand2  ~a+~b          (OR (NOT (VAR a)) (NOT (VAR b)))
//     xor2   ~a⋅b+a⋅~b      (OR (AND (NOT a) b) (AND a (NOT b)))
//
// Both are plausible, both are correct boolean logic, and both are **Quine–McCluskey output,
// not the netlist walk's**. `OutputExpressions.invalidate` (`OutputExpressions.java:148-178`)
// silently replaces the stored expression with the minimised one whenever its column disagrees
// with the model's truth table, and on a model that has only been through `computeExpression`,
// the table is empty, so it always disagrees. Asserting the port against those strings would
// have made a correct port fail and, worse, would have been "fixed" by teaching `NandGate` to
// emit De Morgan's law, which upstream does not do. The probe now subclasses `OutputExpressions`
// and records `setExpression` at the source; against the raw values, `NandGate` derives
// `~(a⋅b)` and `XorGate` derives `a⊕b`, which is what `Expressions.not`/`Expressions.xor`
// actually build (neither simplifies; `Expressions.java:300-315`).
//
// Every expectation below is a literal from that probe's stdout, and every probe run was
// asserted to have produced non-empty output on stdout and nothing on stderr.
//
// ── What is asserted, beyond "it compiles" ──────────────────────────────────────────────────
//
// The defect class this port keeps hitting is a feature that exists and is wired to nothing, so
// `everyGateVendsTheFeature` asserts on `Component.feature(.expressionComputer)` returning a
// non-nil computer for a real placed component of all eleven implementing factories; the
// question "is the protocol reachable through the feature key" answered directly, not inferred
// from a derivation happening to work.
// ═════════════════════════════════════════════════════════════════════════════════════════════

import Foundation
import LogisimFile
import LogisimKernel
import Testing

@testable import LogisimStd

// MARK: - A concrete expression, private to the test

/// The test's stand-in for `LogisimAnalyze.Expression`.
///
/// `LogisimStdTests` depends on LogisimStd, LogisimFile and LogisimKernel, deliberately not on
/// LogisimAnalyze, since LogisimStd itself does not, so the real expression type is not
/// reachable here. That is not a hole in the gate: `ExpressionAlgebra` is the *entire* interface
/// the derivation has to an expression, so an algebra that records exactly what was built proves
/// what the walk did. Rendering it as a prefix S-expression makes it directly diffable against
/// the jar probe's output.
private final class Sexpr {
  enum Kind {
    case variable(String)
    case constant(Int)
    case not(Sexpr)
    case binary(String, Sexpr, Sexpr)
  }

  let kind: Kind
  init(_ kind: Kind) { self.kind = kind }

  var text: String {
    switch kind {
    case let .variable(name): return "(VAR \(name))"
    case let .constant(value): return "(CONST \(value))"
    case let .not(operand): return "(NOT \(operand.text))"
    case let .binary(op, lhs, rhs): return "(\(op) \(lhs.text) \(rhs.text))"
    }
  }
}

private final class SexprAlgebra: ExpressionAlgebra {
  private func wrap(_ kind: Sexpr.Kind) -> ExpressionRef { ExpressionRef(Sexpr(kind)) }
  private func node(_ ref: ExpressionRef) -> Sexpr { ref.boxed as! Sexpr }

  func variable(_ name: String) -> ExpressionRef { wrap(.variable(name)) }
  func constant(_ value: Int) -> ExpressionRef { wrap(.constant(value)) }
  func not(_ operand: ExpressionRef) -> ExpressionRef { wrap(.not(node(operand))) }
  func and(_ lhs: ExpressionRef, _ rhs: ExpressionRef) -> ExpressionRef {
    wrap(.binary("AND", node(lhs), node(rhs)))
  }
  func or(_ lhs: ExpressionRef, _ rhs: ExpressionRef) -> ExpressionRef {
    wrap(.binary("OR", node(lhs), node(rhs)))
  }
  func xor(_ lhs: ExpressionRef, _ rhs: ExpressionRef) -> ExpressionRef {
    wrap(.binary("XOR", node(lhs), node(rhs)))
  }

  /// Structural, as `Expression.equals` is; two separately built `(VAR a)` nodes are equal.
  /// Identity comparison here would re-dirty every point on every round and turn every circuit
  /// into a false `Circular` after 100 iterations, which is exactly the failure the fixpoint
  /// loop's `!Objects.equals` guard exists to prevent.
  func equals(_ lhs: ExpressionRef, _ rhs: ExpressionRef) -> Bool {
    node(lhs).text == node(rhs).text
  }

  /// `Expression.isCircular`: provably false for a tree, as it is for the real port's
  /// `indirect enum`. See `CircuitExpressions.checkForCircularExpressions`.
  func isCircular(_ expression: ExpressionRef) -> Bool { false }
}

// MARK: - Harness

private func load(_ text: String, circuit name: String) throws -> Circuit {
  StdLibraries.registerAll()
  let file = try #require(try Loader().openLogisimFile(data: Data(text.utf8)))
  return try #require(file.circuit(named: name))
}

/// Runs the whole derivation and returns `name -> prefix form`, in output-bit order.
private func derive(_ text: String, circuit name: String) throws -> [(String, String)] {
  let circuit = try load(text, circuit: name)
  let simulated = SimulatedCircuit(circuit)
  let columns = TruthTableRun.pinColumns(of: circuit)
  let derived = try CircuitExpressions.compute(
    circuit: circuit,
    connectivity: simulated.wireStore,
    columns: columns,
    algebra: SexprAlgebra())
  return derived.map { ($0.name, ($0.expression?.boxed as? Sexpr)?.text ?? "<null>") }
}

// MARK: - Fixtures
//
// `andor` and `notbus` are the two fixtures `AnalyzeModelTests` already pins against the jar for
// the *table* path; reusing them verbatim means the geometry is known-good (that file records a
// false start where a mis-placed gate made the jar return `E` in every row, which would have
// been embedded as an expectation had it not been caught). The rest are new, and each was run
// through `ExprProbe` before its expectation was written down.

private let andOrCirc = """
  <?xml version="1.0" encoding="UTF-8" standalone="no"?>
  <project source="4.1.0" version="1.0">
    <lib desc="#Wiring" name="0"/>
    <lib desc="#Gates" name="1"/>
    <main name="andor"/>
    <options>
      <a name="gateUndefined" val="ignore"/>
      <a name="simlimit" val="1000"/>
      <a name="simrand" val="0"/>
    </options>
    <circuit name="andor">
      <a name="circuit" val="andor"/>
      <comp lib="0" loc="(80,100)" name="Pin">
        <a name="label" val="a"/>
      </comp>
      <comp lib="0" loc="(80,140)" name="Pin">
        <a name="label" val="b"/>
      </comp>
      <comp lib="0" loc="(80,220)" name="Pin">
        <a name="label" val="c"/>
      </comp>
      <comp lib="0" loc="(390,170)" name="Pin">
        <a name="facing" val="west"/>
        <a name="label" val="y"/>
        <a name="output" val="true"/>
      </comp>
      <comp lib="1" loc="(220,120)" name="AND Gate"/>
      <comp lib="1" loc="(340,170)" name="OR Gate"/>
      <wire from="(80,100)" to="(180,100)"/>
      <wire from="(80,140)" to="(180,140)"/>
      <wire from="(220,120)" to="(290,120)"/>
      <wire from="(290,120)" to="(290,150)"/>
      <wire from="(80,220)" to="(290,220)"/>
      <wire from="(290,190)" to="(290,220)"/>
      <wire from="(340,170)" to="(390,170)"/>
    </circuit>
  </project>
  """

private let notBusCirc = """
  <?xml version="1.0" encoding="UTF-8" standalone="no"?>
  <project source="4.1.0" version="1.0">
    <lib desc="#Wiring" name="0"/>
    <lib desc="#Gates" name="1"/>
    <main name="notbus"/>
    <options>
      <a name="gateUndefined" val="ignore"/>
      <a name="simlimit" val="1000"/>
      <a name="simrand" val="0"/>
    </options>
    <circuit name="notbus">
      <a name="circuit" val="notbus"/>
      <comp lib="0" loc="(80,100)" name="Pin">
        <a name="label" val="d"/>
        <a name="width" val="2"/>
      </comp>
      <comp lib="0" loc="(240,100)" name="Pin">
        <a name="facing" val="west"/>
        <a name="label" val="q"/>
        <a name="output" val="true"/>
        <a name="width" val="2"/>
      </comp>
      <comp lib="1" loc="(180,100)" name="NOT Gate">
        <a name="width" val="2"/>
      </comp>
      <wire from="(80,100)" to="(150,100)"/>
      <wire from="(180,100)" to="(240,100)"/>
    </circuit>
  </project>
  """

/// Nine one-gate circuits, one per thing that has to be checked. `a` sits at `(80,100)` and `b`
/// at `(80,140)`, which are a 2-input medium gate's two input rows; the horizontal wires run to
/// `x = 215`, past every gate's input `x` whatever its `axisLength` works out to, so the same
/// geometry serves AND (body 40), NAND (50), OR/XOR (50) and NOR/XNOR (60) without any
/// per-gate arithmetic. A 3-input medium gate's rows are `y-20, y, y+20`.
private let zooCirc = """
  <?xml version="1.0" encoding="UTF-8" standalone="no"?>
  <project source="4.1.0" version="1.0">
    <lib desc="#Wiring" name="0"/>
    <lib desc="#Gates" name="1"/>
    <lib desc="#Plexers" name="2"/>
    <main name="nand2"/>
    <options>
      <a name="gateUndefined" val="ignore"/>
      <a name="simlimit" val="1000"/>
      <a name="simrand" val="0"/>
    </options>
    <circuit name="nand2">
      <a name="circuit" val="nand2"/>
      <comp lib="0" loc="(80,100)" name="Pin"><a name="label" val="a"/></comp>
      <comp lib="0" loc="(80,140)" name="Pin"><a name="label" val="b"/></comp>
      <comp lib="0" loc="(300,120)" name="Pin">
        <a name="facing" val="west"/><a name="label" val="y"/><a name="output" val="true"/>
      </comp>
      <comp lib="1" loc="(220,120)" name="NAND Gate"/>
      <wire from="(80,100)" to="(215,100)"/>
      <wire from="(80,140)" to="(215,140)"/>
      <wire from="(220,120)" to="(300,120)"/>
    </circuit>
    <circuit name="nor2">
      <a name="circuit" val="nor2"/>
      <comp lib="0" loc="(80,100)" name="Pin"><a name="label" val="a"/></comp>
      <comp lib="0" loc="(80,140)" name="Pin"><a name="label" val="b"/></comp>
      <comp lib="0" loc="(300,120)" name="Pin">
        <a name="facing" val="west"/><a name="label" val="y"/><a name="output" val="true"/>
      </comp>
      <comp lib="1" loc="(220,120)" name="NOR Gate"/>
      <wire from="(80,100)" to="(215,100)"/>
      <wire from="(80,140)" to="(215,140)"/>
      <wire from="(220,120)" to="(300,120)"/>
    </circuit>
    <circuit name="xor2">
      <a name="circuit" val="xor2"/>
      <comp lib="0" loc="(80,100)" name="Pin"><a name="label" val="a"/></comp>
      <comp lib="0" loc="(80,140)" name="Pin"><a name="label" val="b"/></comp>
      <comp lib="0" loc="(300,120)" name="Pin">
        <a name="facing" val="west"/><a name="label" val="y"/><a name="output" val="true"/>
      </comp>
      <comp lib="1" loc="(220,120)" name="XOR Gate"/>
      <wire from="(80,100)" to="(215,100)"/>
      <wire from="(80,140)" to="(215,140)"/>
      <wire from="(220,120)" to="(300,120)"/>
    </circuit>
    <circuit name="xnor2">
      <a name="circuit" val="xnor2"/>
      <comp lib="0" loc="(80,100)" name="Pin"><a name="label" val="a"/></comp>
      <comp lib="0" loc="(80,140)" name="Pin"><a name="label" val="b"/></comp>
      <comp lib="0" loc="(300,120)" name="Pin">
        <a name="facing" val="west"/><a name="label" val="y"/><a name="output" val="true"/>
      </comp>
      <comp lib="1" loc="(220,120)" name="XNOR Gate"/>
      <wire from="(80,100)" to="(215,100)"/>
      <wire from="(80,140)" to="(215,140)"/>
      <wire from="(220,120)" to="(300,120)"/>
    </circuit>
    <circuit name="andneg">
      <a name="circuit" val="andneg"/>
      <comp lib="0" loc="(80,100)" name="Pin"><a name="label" val="a"/></comp>
      <comp lib="0" loc="(80,140)" name="Pin"><a name="label" val="b"/></comp>
      <comp lib="0" loc="(300,120)" name="Pin">
        <a name="facing" val="west"/><a name="label" val="y"/><a name="output" val="true"/>
      </comp>
      <comp lib="1" loc="(220,120)" name="AND Gate"><a name="negate0" val="true"/></comp>
      <wire from="(80,100)" to="(215,100)"/>
      <wire from="(80,140)" to="(215,140)"/>
      <wire from="(220,120)" to="(300,120)"/>
    </circuit>
    <circuit name="or3">
      <a name="circuit" val="or3"/>
      <comp lib="0" loc="(80,100)" name="Pin"><a name="label" val="a"/></comp>
      <comp lib="0" loc="(80,120)" name="Pin"><a name="label" val="b"/></comp>
      <comp lib="0" loc="(80,140)" name="Pin"><a name="label" val="c"/></comp>
      <comp lib="0" loc="(300,120)" name="Pin">
        <a name="facing" val="west"/><a name="label" val="y"/><a name="output" val="true"/>
      </comp>
      <comp lib="1" loc="(220,120)" name="OR Gate"><a name="inputs" val="3"/></comp>
      <wire from="(80,100)" to="(215,100)"/>
      <wire from="(80,120)" to="(215,120)"/>
      <wire from="(80,140)" to="(215,140)"/>
      <wire from="(220,120)" to="(300,120)"/>
    </circuit>
    <circuit name="xor3">
      <a name="circuit" val="xor3"/>
      <comp lib="0" loc="(80,100)" name="Pin"><a name="label" val="a"/></comp>
      <comp lib="0" loc="(80,120)" name="Pin"><a name="label" val="b"/></comp>
      <comp lib="0" loc="(80,140)" name="Pin"><a name="label" val="c"/></comp>
      <comp lib="0" loc="(300,120)" name="Pin">
        <a name="facing" val="west"/><a name="label" val="y"/><a name="output" val="true"/>
      </comp>
      <comp lib="1" loc="(220,120)" name="XOR Gate"><a name="inputs" val="3"/></comp>
      <wire from="(80,100)" to="(215,100)"/>
      <wire from="(80,120)" to="(215,120)"/>
      <wire from="(80,140)" to="(215,140)"/>
      <wire from="(220,120)" to="(300,120)"/>
    </circuit>
    <circuit name="muxed">
      <a name="circuit" val="muxed"/>
      <comp lib="0" loc="(80,100)" name="Pin"><a name="label" val="a"/></comp>
      <comp lib="0" loc="(80,140)" name="Pin"><a name="label" val="b"/></comp>
      <comp lib="0" loc="(80,200)" name="Pin"><a name="label" val="s"/></comp>
      <comp lib="0" loc="(300,120)" name="Pin">
        <a name="facing" val="west"/><a name="label" val="y"/><a name="output" val="true"/>
      </comp>
      <comp lib="2" loc="(220,130)" name="Multiplexer"/>
      <wire from="(80,100)" to="(190,100)"/>
      <wire from="(80,140)" to="(190,140)"/>
      <wire from="(80,200)" to="(210,200)"/>
      <wire from="(220,130)" to="(300,130)"/>
      <wire from="(300,120)" to="(300,130)"/>
    </circuit>
    <circuit name="latch">
      <a name="circuit" val="latch"/>
      <comp lib="0" loc="(80,100)" name="Pin"><a name="label" val="a"/></comp>
      <comp lib="0" loc="(400,120)" name="Pin">
        <a name="facing" val="west"/><a name="label" val="y"/><a name="output" val="true"/>
      </comp>
      <comp lib="1" loc="(220,120)" name="AND Gate"/>
      <wire from="(80,100)" to="(215,100)"/>
      <wire from="(220,120)" to="(300,120)"/>
      <wire from="(300,120)" to="(400,120)"/>
      <wire from="(300,120)" to="(300,220)"/>
      <wire from="(140,220)" to="(300,220)"/>
      <wire from="(140,140)" to="(140,220)"/>
      <wire from="(140,140)" to="(215,140)"/>
    </circuit>
  </project>
  """

/// A 2-bit input, split into two 1-bit lines, ANDed back to a 1-bit output.
///
/// Geometry taken from the jar rather than guessed: `ExprProbe` prints every component's ends,
/// which is how the splitter's `(160,100) (180,80) (180,90)` and the AND gate's
/// `(320,120) (270,100) (270,140)` were established. A first attempt with no wires between them
/// derived `<null>`, which is what an unwired input looks like, not an error.
private let splitAndCirc = """
  <?xml version="1.0" encoding="UTF-8" standalone="no"?>
  <project source="4.1.0" version="1.0">
    <lib desc="#Wiring" name="0"/>
    <lib desc="#Gates" name="1"/>
    <main name="splitand"/>
    <options>
      <a name="gateUndefined" val="ignore"/>
      <a name="simlimit" val="1000"/>
      <a name="simrand" val="0"/>
    </options>
    <circuit name="splitand">
      <a name="circuit" val="splitand"/>
      <comp lib="0" loc="(80,100)" name="Pin">
        <a name="label" val="d"/><a name="width" val="2"/>
      </comp>
      <comp lib="0" loc="(400,120)" name="Pin">
        <a name="facing" val="west"/><a name="label" val="y"/><a name="output" val="true"/>
      </comp>
      <comp lib="0" loc="(160,100)" name="Splitter">
        <a name="fanout" val="2"/><a name="incoming" val="2"/>
      </comp>
      <comp lib="1" loc="(320,120)" name="AND Gate"/>
      <wire from="(80,100)" to="(160,100)"/>
      <wire from="(320,120)" to="(400,120)"/>
      <wire from="(180,80)" to="(250,80)"/>
      <wire from="(250,80)" to="(250,100)"/>
      <wire from="(250,100)" to="(270,100)"/>
      <wire from="(180,90)" to="(230,90)"/>
      <wire from="(230,90)" to="(230,140)"/>
      <wire from="(230,140)" to="(270,140)"/>
    </circuit>
  </project>
  """

// MARK: - Suite

@Suite("Analyze — the derived expression (Analyze.computeExpression)")
struct AnalyzeExpressionTests {

  // MARK: The feature is reachable at all

  /// Seam assertion. The `expressionComputer` key has existed in `LogisimFile/Component.swift`
  /// since M2 and **no component vended it**: `AbstractGate`, `NotGate`, `Buffer` and
  /// `Constant` each carried a "NOT PORTED: getInstanceFeature(ExpressionComputer)" note at the
  /// site. This asserts the answer to the only question that matters about that: does a real
  /// placed component hand back a computer through the feature key?
  ///
  /// `Constant` is expected to answer `nil`: `LogisimStd/Wiring/Constant.swift` is outside this
  /// change's ownership, so its conformance is reported as a diff rather than applied. The
  /// expectation is written as `false` rather than omitted so that landing that diff makes this
  /// test fail loudly instead of silently passing.
  @Test("Every gate vends an ExpressionComputer through the feature key")
  func everyGateVendsTheFeature() throws {
    StdLibraries.registerAll()
    let vending: [(String, any InstanceFactory)] = [
      ("AND Gate", AndGate.factory),
      ("OR Gate", OrGate.factory),
      ("NAND Gate", NandGate.factory),
      ("NOR Gate", NorGate.factory),
      ("XOR Gate", XorGate.factory),
      ("XNOR Gate", XnorGate.factory),
      ("Odd Parity", OddParityGate.factory),
      ("Even Parity", EvenParityGate.factory),
      ("NOT Gate", NotGate.factory),
      ("Buffer", Buffer.factory),
    ]
    for (label, factory) in vending {
      let component = try factory.createComponent(
        location: Location.create(100, 100, hasToSnap: true),
        attributes: factory.createAttributeSet())
      let feature = component.feature(ComponentFeatureKey.expressionComputer)
      #expect(feature is (any ExpressionComputer), "\(label) vends no ExpressionComputer")
    }

    // Not ported here, see the doc comment.
    let constant = try Constant.factory.createComponent(
      location: Location.create(100, 100, hasToSnap: true),
      attributes: Constant.factory.createAttributeSet())
    #expect(constant.feature(ComponentFeatureKey.expressionComputer) == nil)
  }

  // MARK: Jar-pinned derivations

  /// `ExprProbe andOrCirc.circ andor`:
  ///
  ///     EXPR-OK
  ///     EXPR y   (OR (AND (VAR a) (VAR b)) (VAR c))
  ///     STR  y   a⋅b+c
  ///
  /// Two gates, so it exercises the fixpoint loop rather than a single round: the OR gate is
  /// visited once before the AND's output exists (contributing nothing, because
  /// `expressionMap.get` returns nil for its upper input) and again after `propagateWires` has
  /// carried the AND's result down the wire to it.
  @Test("andor — two gates, one fixpoint round apart, matches the jar's tree")
  func andOrMatchesTheJar() throws {
    let derived = try derive(andOrCirc, circuit: "andor")
    #expect(derived.map(\.0) == ["y"])
    #expect(derived[0].1 == "(OR (AND (VAR a) (VAR b)) (VAR c))")
  }

  /// `ExprProbe notBusCirc.circ notbus`:
  ///
  ///     EXPR q[1]  (NOT (VAR d[1]))
  ///     EXPR q[0]  (NOT (VAR d[0]))
  ///
  /// The width > 1 case. Three things could each go wrong silently and none does: the per-bit
  /// variable naming (`d[1]`, not `d1` or `d`), the MSB-first bit order of the output list, and
  /// `NotGate`'s computer looping over every bit rather than only bit 0.
  @Test("notbus — a 2-bit NOT gives one expression per bit, MSB first, matching the jar")
  func notBusMatchesTheJar() throws {
    let derived = try derive(notBusCirc, circuit: "notbus")
    #expect(derived.map(\.0) == ["q[1]", "q[0]"])
    #expect(derived[0].1 == "(NOT (VAR d[1]))")
    #expect(derived[1].1 == "(NOT (VAR d[0]))")
  }

  /// One case per gate family, each a literal from `ExprProbe zoo.circ <name>`.
  ///
  /// Note `nand2` derives `(NOT (AND a b))` and **not** `(OR (NOT a) (NOT b))`: neither
  /// `Expressions.not` nor `Expressions.and` simplifies, so the tree is exactly the gate's
  /// shape. See this file's header for why that distinction cost a rewritten oracle.
  @Test(
    "Each gate family's derived tree matches the jar",
    arguments: [
      ("nand2", "(NOT (AND (VAR a) (VAR b)))"),
      ("nor2", "(NOT (OR (VAR a) (VAR b)))"),
      ("xor2", "(XOR (VAR a) (VAR b))"),
      ("xnor2", "(NOT (XOR (VAR a) (VAR b)))"),
      ("or3", "(OR (OR (VAR a) (VAR b)) (VAR c))"),
    ])
  func gateFamiliesMatchTheJar(name: String, expected: String) throws {
    let derived = try derive(zooCirc, circuit: name)
    #expect(derived.map(\.0) == ["y"])
    #expect(derived[0].1 == expected, "\(name)")
  }

  /// `ExprProbe zoo.circ or3` → `(OR (OR (VAR a) (VAR b)) (VAR c))`.
  ///
  /// Asserted separately from the table above as well, because the *association* is the point:
  /// a right fold would give `(OR (VAR a) (OR (VAR b) (VAR c)))`, which is the same boolean
  /// function and a different tree, and `Expression`'s printer parenthesises by structure, so
  /// getting this wrong changes what the Expression tab shows without changing any truth table.
  @Test("A 3-input gate folds LEFT, as the jar does")
  func threeInputGateFoldsLeft() throws {
    let derived = try derive(zooCirc, circuit: "or3")
    #expect(derived[0].1 == "(OR (OR (VAR a) (VAR b)) (VAR c))")
    #expect(derived[0].1 != "(OR (VAR a) (OR (VAR b) (VAR c)))")
  }

  /// `ExprProbe zoo.circ andneg` → `(AND (NOT (VAR a)) (VAR b))`.
  ///
  /// The `negated` bit mask, which `AbstractGate`'s computer applies per input *before* folding.
  /// A port that applied it after, or that read `negated >> i` instead of `negated >> (i - 1)`,
  /// negates the wrong input and still produces a well-formed expression.
  @Test("An input-negation bubble wraps that input alone, before the fold")
  func inputNegationIsAppliedPerInput() throws {
    let derived = try derive(zooCirc, circuit: "andneg")
    #expect(derived[0].1 == "(AND (NOT (VAR a)) (VAR b))")
  }

  /// `ExprProbe split.circ splitand` → `(AND (VAR d[0]) (VAR d[1]))`.
  ///
  /// **The only test that exercises the thread walk non-trivially**, and therefore the only one
  /// that covers `CircuitWires.threadPoints(at:bit:)`. A splitter vends no `ExpressionComputer`
  /// , `propagateComponents` skips it explicitly, "splitters are handled elsewhere", so the
  /// bits get across purely because a `WireThread` runs *through* the splitter, carrying bit 0
  /// of the 2-bit bundle onto bit 0 of one 1-bit bundle and bit 1 onto bit 0 of the other. Every
  /// other fixture here has a single-bit bundle at every point, where `position[i]` is always 0
  /// and a port that ignored it would still pass.
  ///
  /// The `d[0]` before `d[1]` ordering is the jar's and is not arbitrary: bit 0 leaves on the
  /// splitter's *upper* fan-out end `(180,80)`, which reaches the AND gate's port 1.
  @Test("A splitter carries bits across on wire threads, with the bit index remapped")
  func splitterRemapsBitsAcrossThreads() throws {
    let derived = try derive(splitAndCirc, circuit: "splitand")
    #expect(derived.map(\.0) == ["y"])
    #expect(derived[0].1 == "(AND (VAR d[0]) (VAR d[1]))")
  }

  // MARK: The three failure modes

  /// `ExprProbe zoo.circ xor3` → `EXPR-FAIL CannotHandle "…due to XOR Gate."`
  ///
  /// `XorGate.xorExpression` refuses three or more inputs outright, because `ATTR_XOR` selects
  /// between odd-parity and exactly-one and a chain of two-operand XORs can only express the
  /// first. This is upstream's only use of `UnsupportedOperationException` on the analyze path,
  /// and the conversion into `CannotHandle(displayName)` happens in `propagateComponents`,
  /// so the assertion is on the *converted* error, which is what the caller sees.
  @Test("A 3-input XOR refuses, and the refusal carries the factory's display name")
  func threeInputXorRefuses() throws {
    #expect(throws: AnalyzeError.cannotHandle("XOR Gate")) {
      try derive(zooCirc, circuit: "xor3")
    }
  }

  /// `ExprProbe zoo.circ muxed` → `EXPR-FAIL CannotHandle "…due to Multiplexer."`
  ///
  /// The measured cost of the feature's coverage: any component without a computer aborts the
  /// whole derivation, which is why upstream falls back to the truth table on most real
  /// circuits. A multiplexer is the mildest possible case; it is pure combinational logic and
  /// upstream still refuses it.
  @Test("A component with no computer aborts with its display name, as upstream does")
  func componentWithoutAComputerAborts() throws {
    #expect(throws: AnalyzeError.cannotHandle("Multiplexer")) {
      try derive(zooCirc, circuit: "muxed")
    }
  }

  /// `ExprProbe zoo.circ latch` → `EXPR-FAIL Circular`.
  ///
  /// **The non-combinational case, and the reason this test has a wall-clock assertion.** An AND
  /// gate with its own output wired back to an input never reaches a fixpoint: each round wraps
  /// the expression in another `AND`, so `dirtyPoints` never empties. Upstream stops it with a
  /// hard cap of 100 rounds; without that cap the walk runs until the expression exhausts
  /// memory. The elapsed-time bound is what distinguishes "the cap fired" from "the walk
  /// happened to be short"; a port that dropped the cap would still throw eventually, or hang,
  /// and only the clock tells those apart.
  @Test("A feedback loop reports Circular and terminates, rather than walking forever")
  func feedbackLoopTerminates() throws {
    let started = Date()
    #expect(throws: AnalyzeError.circular) {
      try derive(zooCirc, circuit: "latch")
    }
    let elapsed = Date().timeIntervalSince(started)
    #expect(elapsed < 5, "the 100-iteration cap did not bound the walk (took \(elapsed)s)")
  }

  // MARK: Structural

  /// `maxIterations` is upstream's, not a number invented here (`Analyze.java:132`), and there
  /// is deliberately no *row* cap on this path; the 2^n bound belongs to the table derivation.
  @Test("The only bound on the symbolic walk is upstream's 100-iteration cap")
  func theCapIsUpstreams() {
    #expect(CircuitExpressions.maxIterations == 100)
  }
}

// MARK: - The oracle
//
// ```java
// package com.cburch.logisim.circuit;
//
// import com.cburch.logisim.analyze.model.AnalyzerModel;
// import com.cburch.logisim.analyze.model.Expression;
// import com.cburch.logisim.analyze.model.Var;
// import com.cburch.logisim.file.Loader;
// import com.cburch.logisim.instance.StdAttr;
// import com.cburch.logisim.std.wiring.Pin;
// import java.io.File;
// import java.util.ArrayList;
//
// public final class ExprProbe {
//   static String sexpr(Expression e) {
//     if (e == null) return "<null>";
//     return e.visit(new Expression.Visitor<String>() {
//       @Override public String visitVariable(String name) { return "(VAR " + name + ")"; }
//       @Override public String visitConstant(int v) { return "(CONST " + v + ")"; }
//       @Override public String visitNot(Expression a) { return "(NOT " + sexpr(a) + ")"; }
//       @Override public String visitBinary(Expression a, Expression b, Expression.Op op) {
//         return "(" + op.name() + " " + sexpr(a) + " " + sexpr(b) + ")";
//       }
//     });
//   }
//
//   /** Records what computeExpression HANDS to the model; getExpression gives you the
//    *  Quine-McCluskey minimisation instead. See this file's header. */
//   static final class Recording extends com.cburch.logisim.analyze.model.OutputExpressions {
//     final java.util.LinkedHashMap<String, Expression> raw = new java.util.LinkedHashMap<>();
//     Recording(AnalyzerModel model) { super(model); }
//     @Override public void setExpression(String output, Expression expr) { raw.put(output, expr); }
//   }
//
//   static final class ProbeModel extends AnalyzerModel {
//     private Recording recording;
//     @Override public com.cburch.logisim.analyze.model.OutputExpressions getOutputExpressions() {
//       if (recording == null) recording = new Recording(this);
//       return recording;
//     }
//   }
//
//   public static void main(String[] args) throws Exception {
//     com.cburch.logisim.Main.headless = true;                       // D17
//     final var loader = new Loader(null);
//     final var file = loader.openLogisimFile(new File(args[0]));
//     Circuit circuit = null;
//     for (final var c : file.getCircuits()) if (c.getName().equals(args[1])) circuit = c;
//     if (circuit == null) { System.out.println("NO-SUCH-CIRCUIT\t" + args[1]); System.exit(0); }
//
//     final var pinNames = Analyze.getPinLabels(circuit);
//     final var inputVars = new ArrayList<Var>();
//     final var outputVars = new ArrayList<Var>();
//     for (final var entry : pinNames.entrySet()) {
//       final var pin = entry.getKey();
//       final var width = pin.getAttributeValue(StdAttr.WIDTH).getWidth();
//       final var v = new Var(entry.getValue(), width);
//       System.out.println("PIN\t" + entry.getValue() + "\t"
//           + (Pin.FACTORY.isInputPin(pin) ? "in" : "out")
//           + "\twidth=" + width + "\tloc=" + pin.getLocation());
//       if (Pin.FACTORY.isInputPin(pin)) inputVars.add(v); else outputVars.add(v);
//     }
//
//     final var model = new ProbeModel();
//     model.setVariables(inputVars, outputVars);
//     try {
//       Analyze.computeExpression(model, circuit, pinNames);
//       System.out.println("EXPR-OK");
//       final var raw = ((Recording) model.getOutputExpressions()).raw;
//       for (final var name : model.getOutputs().bits) {
//         final var e = raw.get(name);
//         System.out.println("EXPR\t" + name + "\t" + sexpr(e));
//         System.out.println("STR\t" + name + "\t" + (e == null ? "<null>" : e.toString()));
//       }
//     } catch (AnalyzeException ex) {
//       System.out.println("EXPR-FAIL\t" + ex.getClass().getSimpleName() + "\t" + ex.getMessage());
//     }
//     System.out.flush();
//     System.exit(0);                                                // AutosaveThread is non-daemon
//   }
//
//   private ExprProbe() {}
// }
// ```
//
// Run:
//
//     JAR=/Applications/Logisim-evolution.app/Contents/app/logisim-evolution-4.1.0-all.jar
//     javac -cp "$JAR" -d /tmp/anaexpr/classes ExprProbe.java
//     java -Djava.awt.headless=true -cp "$JAR:/tmp/anaexpr/classes" \
//         com.cburch.logisim.circuit.ExprProbe <file.circ> <circuit>
