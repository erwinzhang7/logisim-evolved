//
//  ExpressionRendering.swift: part of logisim-evolved.
//
//  Derived from logisim-evolution, specifically `Expression.toString(Notation, boolean,
//  Expression)` in `src/main/java/com/cburch/logisim/analyze/model/Expression.java` and
//  `src/main/java/com/cburch/logisim/analyze/data/Range.java`. GPL-3.0-only. See LICENSE.md.
//

/// Java: `com.cburch.logisim.analyze.data.Range`.
///
/// Renamed because `Range` is a stdlib type in Swift. `depth` is filled in later by the
/// renderer that draws overbars (`data/ExpressionRenderData`), which is UI and not ported
/// here; it is carried so the M6/M7 layer has somewhere to put it.
public struct TextRange: Hashable, Sendable {
  public var startIndex: Int
  public var stopIndex: Int
  public var depth: Int

  public init(startIndex: Int = 0, stopIndex: Int = 0, depth: Int = 0) {
    self.startIndex = startIndex
    self.stopIndex = stopIndex
    self.depth = depth
  }
}

extension Expression {
  /// Java: `Expression.Notation`.
  ///
  /// `opLevel` and `opSym` are indexed by `Op.id`, i.e. `{ EQ, XNOR, OR, XOR, AND, NOT }`;
  /// note that this is *not* the order the operators are declared in the doc comments
  /// upstream. Localisation of the notation's own display name does not come across (same
  /// rule as D5): the UI names these.
  public enum Notation: Int, CaseIterable, Sendable {
    case mathematical = 0
    case logic = 1
    case altLogic = 2
    case progBools = 3
    case progBits = 4
    case latex = 5

    // Precedence levels, verbatim from Java. All forms of NOT bind tightest; all forms of
    // `=` bind loosest.
    public static let notPrecedence = 14
    public static let implicitAndPrecedence = 13
    public static let timesPrecedence = 13
    public static let oplusPrecedence = 12
    public static let plusPrecedence = 11
    public static let otimesPrecedence = 10
    public static let logicPrecedence = 9
    public static let bitAndPrecedence = 8
    public static let bitXorPrecedence = 7
    public static let bitOrPrecedence = 6
    public static let andPrecedence = 5
    public static let orPrecedence = 4
    public static let pythonAndPrecedence = 3
    public static let pythonXorPrecedence = 2
    public static let pythonOrPrecedence = 1
    public static let eqPrecedence = 0

    /// Java: `Notation.opLvl`.
    public var opLevel: [Int] {
      switch self {
      case .logic, .altLogic: return [0, 9, 9, 9, 9, 14]
      case .progBools: return [0, 9, 4, 9, 5, 14]
      case .progBits: return [0, 9, 6, 7, 8, 14]
      case .latex, .mathematical: return [0, 10, 11, 12, 13, 14]
      }
    }

    /// Java: `Notation.opSym`.
    public var opSym: [String] {
      switch self {
      case .logic:
        return [" = ", "\u{2261}", "\u{2228}", "\u{22BB}", "\u{2227}", "\u{00AC}"]
      case .altLogic:
        return [" = ", "\u{2261}", "\u{2228}", "\u{2262}", "\u{2227}", "~"]
      case .progBools:
        return [" = ", "==", "||", "!=", "&&", "!"]
      case .progBits:
        return [" = ", "^~", "|", "^", "&", "~"]
      case .latex:
        return [" = ", " \\oplus ", "+", " \\oplus ", " \\cdot ", " \\overline{"]
      case .mathematical:
        return [" = ", "\u{2299}", "+", "\u{2295}", "\u{22C5}", "~"]
      }
    }
  }

  /// What `Expression.toString(Notation, boolean, Expression)` produces.
  ///
  /// Java writes the four side-channels into **mutable fields on the expression object**
  /// (`nots`, `subscripts`, `marks`, `badness`) and returns only the string, so the caller has
  /// to read them back off the node afterwards. Two consequences that do not survive the
  /// translation, both improvements:
  ///
  /// - `marks` is only cleared when `reduce` is true, so repeated `toString(notation, false,
  ///   other)` calls on the same node **accumulate** stale ranges forever. A fresh value type
  ///   per call cannot.
  /// - the fields make `toString` unsafe to call concurrently on a shared tree.
  public struct Rendering: Hashable, Sendable {
    /// The rendered text. LaTeX is wrapped in `$…$`, as upstream does.
    public var text: String
    /// Java: `Expression.nots`; the spans an overbar is drawn across. Only populated when
    /// `reduce` is on and the notation is `.mathematical`.
    public var nots: [TextRange] = []
    /// Java: `Expression.subscripts`; the spans set as a subscript (bus bit indices).
    public var subscripts: [TextRange] = []
    /// Java: `Expression.marks`: the spans occupied by the `highlighting:` subexpression.
    public var marks: [TextRange] = []
    /// Java: `Expression.getBadness()`: per character, how bad a line break there would be.
    ///
    /// Indices are UTF-16 offsets into `text`, matching Java's `StringBuilder`. It is one
    /// entry per character *except* in LaTeX XNOR, where Java appends `" \\overline{"` and
    /// `"}"` straight to the buffer instead of through `add(...)` and so skips them. That
    /// desynchronisation is upstream's and is reproduced.
    public var badness: [Int] = []
  }

  /// Java: `toString(Notation notation, boolean reduce, Expression other)`.
  ///
  /// - Parameter highlighting: Java's `other`; every subexpression equal to it gets a
  ///   `marks` range. Note Java compares with `equals`, so it marks every *structurally*
  ///   equal subtree, not just the one the user clicked.
  public func render(
    _ notation: Notation = .mathematical,
    reduce: Bool = false,
    highlighting other: Expression? = nil
  ) -> Rendering {
    let renderer = Renderer(notation: notation, reduce: reduce, other: other)
    renderer.visit(self)
    var out = Rendering(text: renderer.text)
    out.nots = renderer.nots
    out.subscripts = renderer.subscripts
    out.marks = renderer.marks
    out.badness = renderer.badness
    if notation == .latex { out.text = "$" + out.text + "$" }
    return out
  }

  /// The anonymous `Visitor<Void>` inside `Expression.toString`, as a class because it is
  /// exactly what that visitor is: a bag of mutable rendering state (`curBadness`, `andOp`,
  /// `inXnor`) threaded through a recursive walk.
  private final class Renderer {
    private static let badnessNotBreak = 15
    private static let badnessParenthesisBreak = 10
    private static let badnessConstBreak = 100
    private static let badnessVarBreak = 200
    private static let badnessAndBreak = 5

    let notation: Notation
    let reduce: Bool
    let other: Expression?

    var text = ""
    var nots: [TextRange] = []
    var subscripts: [TextRange] = []
    var marks: [TextRange] = []
    var badness: [Int] = []

    private var curBadness = 0
    private var andOp = false
    private var inXnor = false

    init(notation: Notation, reduce: Bool, other: Expression?) {
      self.notation = notation
      self.reduce = reduce
      self.other = other
    }

    /// Java's `StringBuilder.length()`: UTF-16 code units, which is what every recorded
    /// range and the `badness` array are indexed by.
    private var length: Int { text.utf16.count }

    private func add(_ txt: String) {
      text += txt
      for _ in 0..<txt.utf16.count { badness.append(curBadness) }
    }

    /// Java: `text.append(...)` used directly, bypassing `add`; no badness recorded.
    private func appendRaw(_ txt: String) {
      text += txt
    }

    func visit(_ e: Expression) {
      switch e {
      case let .variable(name):
        visitVariable(name)
      case let .constant(value):
        visitConstant(value)
      case let .not(a):
        visitNot(a)
      case let .and(a, b):
        visitAnd(a, b)
      case let .xnor(a, b):
        visitXnor(a, b)
      case let .or(a, b):
        visitBinary(a, b, .or)
      case let .xor(a, b):
        visitBinary(a, b, .xor)
      case let .eq(a, b):
        visitBinary(a, b, .eq)
      }
    }

    private func visitBinary(_ a: Expression, _ b: Expression, _ op: Op) {
      // Java appends the mark to `marks` at the moment it opens it and then mutates
      // `stopIndex` through the shared reference. Recording the slot reproduces that
      // ordering, which differs from "append when closed" once marks nest.
      var markSlot: Int?
      if a == other {
        marks.append(TextRange(startIndex: length))
        markSlot = marks.count - 1
      }
      let opLvl = notation.opLevel[op.id]
      let aLvl = a.precedence(in: notation)
      let bLvl = b.precedence(in: notation)
      if aLvl < opLvl || (aLvl == opLvl && a.op != op) {
        curBadness += Renderer.badnessParenthesisBreak
        add("(")
        visit(a)
        add(")")
        curBadness -= Renderer.badnessParenthesisBreak
      } else {
        visit(a)
      }
      if let slot = markSlot {
        marks[slot].stopIndex = length
        markSlot = nil
      }
      add(notation.opSym[op.id])
      if b == other {
        marks.append(TextRange(startIndex: length))
        markSlot = marks.count - 1
      }
      if bLvl < opLvl || (bLvl == opLvl && b.op != op) {
        curBadness += Renderer.badnessParenthesisBreak
        add("(")
        visit(b)
        add(")")
        curBadness -= Renderer.badnessParenthesisBreak
      } else {
        visit(b)
      }
      if let slot = markSlot {
        marks[slot].stopIndex = length
      }
    }

    private func visitConstant(_ value: Int) {
      curBadness += Renderer.badnessConstBreak
      // Java: Integer.toString(value, 16): lower-case hex, signed. Swift's
      // String(_:radix:) formats negatives the same way ("-1f").
      add(String(value, radix: 16))
      curBadness -= Renderer.badnessConstBreak
    }

    private func visitNot(_ a: Expression) {
      curBadness += Renderer.badnessNotBreak
      let opLvl = notation.opLevel[Op.not.id]
      let levelOfA = a.precedence(in: notation)
      if reduce && notation == .mathematical {
        // No `~` is emitted: the UI draws an overbar across the recorded range instead.
        var notData = TextRange(startIndex: length)
        nots.append(notData)
        let slot = nots.count - 1
        visit(a)
        notData.stopIndex = length
        nots[slot] = notData
      } else {
        add(notation.opSym[Op.not.id])
        if notation == .latex {
          visit(a)
          add("} ")
        } else if levelOfA < opLvl || (levelOfA == opLvl && a.op != .not) {
          curBadness += Renderer.badnessParenthesisBreak
          add("(")
          visit(a)
          add(")")
          curBadness -= Renderer.badnessParenthesisBreak
        } else {
          visit(a)
        }
      }
      curBadness -= Renderer.badnessNotBreak
    }

    private func visitXnor(_ a: Expression, _ b: Expression) {
      if inXnor || notation != .latex {
        visitBinary(a, b, notation == .latex ? .xor : .xnor)
      } else {
        inXnor = true
        appendRaw(" \\overline{")
        visitBinary(a, b, .xor)
        appendRaw("}")
        inXnor = false
      }
    }

    private func visitVariable(_ name: String) {
      var baseName = name
      var index: String?
      // Java swallows the ParserException and renders the raw name.
      if let bit = try? Var.Bit.parse(name) {
        baseName = bit.name
        if bit.bitIndex >= 0 { index = String(bit.bitIndex) }
      }
      curBadness += Renderer.badnessVarBreak
      if reduce, let index {
        add(baseName)
        var subscriptRange = TextRange(startIndex: length)
        add(index)
        subscriptRange.stopIndex = length
        subscripts.append(subscriptRange)
      } else if notation == .latex {
        add(baseName)
        if let index { add("_{" + index + "}") }
      } else {
        add(name)
      }
      curBadness -= Renderer.badnessVarBreak
    }

    private func visitAnd(_ a: Expression, _ b: Expression) {
      if andOp {
        visitBinary(a, b, .and)
      } else {
        andOp = true
        curBadness += Renderer.badnessAndBreak
        visitBinary(a, b, .and)
        curBadness -= Renderer.badnessAndBreak
        andOp = false
      }
    }
  }
}
