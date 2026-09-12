//
//  Parser.swift: part of logisim-evolved.
//
//  Derived from logisim-evolution, specifically
//  `src/main/java/com/cburch/logisim/analyze/model/Parser.java`. GPL-3.0-only. See LICENSE.md.
//

/// Java: `com.cburch.logisim.analyze.model.Parser`: a precedence-climbing parser over the
/// many notations the analyzer accepts (`+ * ~ ' ! & | ^ && || == != and or xor not`, plus
/// the mathematical and logic glyphs).
public enum Parser {

  // Java: the TOKEN_* int constants.
  enum TokenType {
    case and, or, xor, eq, xnor, not, notPostfix, lparen, rparen, ident, const, white
    case errorBadChar, errorBrace, errorSubscript, errorIdent
  }

  /// Java: `Parser.Token`. A class because `parse` rewrites `type`/`precedence` in place
  /// (an identifier can turn out to be the word `and`) and because a `Context` holds on to
  /// the token that caused it.
  final class Token {
    var type: TokenType
    let offset: Int
    let length: Int
    var precedence: Int
    let text: String

    init(_ type: TokenType, _ offset: Int, _ length: Int, _ text: String, _ precedence: Int) {
      self.type = type
      self.offset = offset
      self.length = length
      self.precedence = precedence
      self.text = text
    }

    convenience init(_ type: TokenType, _ offset: Int, _ text: String, _ precedence: Int) {
      self.init(type, offset, text.count, text, precedence)
    }

    func error(_ key: String, _ args: [String] = []) -> ParserError {
      ParserError(key, args: args, offset: offset, length: length)
    }
  }

  /// Java: `Parser.Context`: one suspended operator on the shunting stack.
  private struct Context {
    let level: Int
    let current: Expression?
    let cause: Token
  }

  /// Java: `okCharacter(char)`; everything the tokenizer can make sense of. Used to decide
  /// how far an unrecognised-character run extends.
  static func okCharacter(_ c: Character) -> Bool {
    if c.isWhitespace || isJavaIdentifierStart(c) { return true }
    if "()01~-^+*!&|=\\':[]".contains(c) { return true }
    if "\u{2260}\u{2262}\u{22C0}\u{22C1}\u{2227}\u{2228}\u{2295}\u{22C5}\u{00AC}\u{2219}".contains(c)
    {
      return true
    }
    if "\u{21D4}\u{2261}\u{2194}\u{02DC}\u{00B7}\u{2225}\u{22BB}\u{22A4}\u{22A5}".contains(c) {
      return true
    }
    return false
  }

  /// Java: `Character.isJavaIdentifierStart`. Approximated by letters plus `_` and `$`; the
  /// exotic remainder (currency symbols, connector punctuation) is not something the analyzer
  /// can name a circuit pin after anyway.
  static func isJavaIdentifierStart(_ c: Character) -> Bool {
    c.isLetter || c == "_" || c == "$"
  }

  /// Java: `Character.isJavaIdentifierPart`.
  static func isJavaIdentifierPart(_ c: Character) -> Bool {
    isJavaIdentifierStart(c) || ("0"..."9").contains(c)
  }

  // MARK: - Public entry points

  /// Java: `parse(String, AnalyzerModel)`.
  public static func parse(_ input: String, _ model: AnalyzerModel) throws -> Expression? {
    try parse(input, model, allowOutputAssignment: false)
  }

  /// Java: `parseMaybeAssignment(String, AnalyzerModel)`: also accepts `out = expr` when
  /// `out` names an output.
  public static func parseMaybeAssignment(_ input: String, _ model: AnalyzerModel) throws
    -> Expression?
  {
    try parse(input, model, allowOutputAssignment: true)
  }

  private static func parse(
    _ input: String, _ model: AnalyzerModel, allowOutputAssignment: Bool
  ) throws -> Expression? {
    let tokens = toTokens(input, includeWhite: false)
    if tokens.isEmpty { return nil }

    for (i, token) in tokens.enumerated() {
      switch token.type {
      case .errorBadChar:
        throw token.error("invalidCharacterError", [token.text])
      case .errorBrace:
        throw token.error("missingBraceError", [token.text])
      case .errorSubscript:
        throw token.error("missingSubscriptError", [token.text])
      case .errorIdent:
        throw token.error("missingIdentifierError", [token.text])
      case .eq where i != 1 || !allowOutputAssignment:
        throw token.error("unexpectedAssignmentError", [token.text])
      case .ident:
        let index = model.inputs.bits.firstIndex(of: token.text)
        if index != nil { continue }
        // ok; but maybe this is a python-like (spelled out) operator
        switch token.text.uppercased() {
        case "NOT":
          token.type = .not
          token.precedence = Expression.Notation.notPrecedence
        case "AND":
          token.type = .and
          token.precedence = Expression.Notation.pythonAndPrecedence
        case "XOR":
          token.type = .xor
          token.precedence = Expression.Notation.pythonXorPrecedence
        case "OR":
          token.type = .or
          token.precedence = Expression.Notation.pythonOrPrecedence
        case "EQUALS":
          token.type = .xnor
          token.precedence = Expression.Notation.logicPrecedence
        default:
          // or, maybe it is a top-level assignment like "foo: expr", "foo = expr", etc
          if i == 0 && allowOutputAssignment {
            let outIndex = model.outputs.bits.firstIndex(of: token.text)
            if outIndex != nil && tokens.count >= 2
              && (tokens[1].type == .xnor || tokens[1].type == .eq)
            {
              tokens[1].type = .eq
              tokens[1].precedence = Expression.Notation.eqPrecedence
              continue
            }
          }
          throw token.error("badVariableName", [token.text])
        }
      default:
        break
      }
    }

    return try parse(tokens)
  }

  // MARK: - The shunting-yard core

  /// Java: `parse(ArrayList<Token>)`.
  private static func parse(_ tokens: [Token]) throws -> Expression? {
    var stack: [Context] = []
    var current: Expression?
    var i = 0
    while i < tokens.count {
      let t = tokens[i]
      switch t.type {
      case .ident, .const:
        var here: Expression
        if t.type == .ident {
          here = Expressions.variable(t.text)
        } else {
          // Java: Integer.parseInt(t.text, 16). The tokenizer only ever emits "0" or "1".
          here = Expressions.constant(Int(t.text, radix: 16) ?? 0)
        }
        while i + 1 < tokens.count && tokens[i + 1].type == .notPostfix {
          here = .not(here)
          i += 1
        }
        while peekLevel(stack) == Expression.Notation.notPrecedence {
          here = .not(here)
          stack.removeLast()
        }
        current = Expressions.and(current, here)
        if peekLevel(stack) == Expression.Notation.implicitAndPrecedence {
          let top = stack.removeLast()
          current = Expressions.and(top.current, current)
        }
      case .not:
        if current != nil {
          stack.append(
            Context(
              level: Expression.Notation.implicitAndPrecedence, current: current,
              cause: Token(
                .and, t.offset, AnalyzeStrings.message("implicitAndOperator"),
                Expression.Notation.implicitAndPrecedence)))
        }
        stack.append(Context(level: Expression.Notation.notPrecedence, current: nil, cause: t))
        current = nil
      case .notPostfix:
        throw t.error("unexpectedApostrophe")
      case .lparen:
        if current != nil {
          stack.append(
            Context(
              level: Expression.Notation.implicitAndPrecedence, current: current,
              cause: Token(
                .and, t.offset, 0, AnalyzeStrings.message("implicitAndOperator"),
                Expression.Notation.implicitAndPrecedence)))
        }
        stack.append(Context(level: -2, current: nil, cause: t))
        current = nil
      case .rparen:
        current = try popTo(&stack, -1, current)
        // there had better be a LPAREN atop the stack now.
        if stack.isEmpty { throw t.error("lparenMissingError") }
        stack.removeLast()
        while i + 1 < tokens.count && tokens[i + 1].type == .notPostfix {
          current = Expressions.not(current)
          i += 1
        }
        current = try popTo(&stack, Expression.Notation.implicitAndPrecedence, current)
      default:
        guard current != nil else {
          throw t.error("missingLeftOperandError", [t.text])
        }
        let folded = try popTo(&stack, t.precedence, current)
        stack.append(Context(level: t.precedence, current: folded, cause: t))
        current = nil
      }
      i += 1
    }
    current = try popTo(&stack, -1, current)
    if !stack.isEmpty {
      let top = stack.removeLast()
      throw top.cause.error("rparenMissingError")
    }
    return current
  }

  private static func peekLevel(_ stack: [Context]) -> Int {
    stack.last?.level ?? -3
  }

  /// Java: `popTo(stack, level, current)`.
  private static func popTo(
    _ stack: inout [Context], _ level: Int, _ currentIn: Expression?
  ) throws -> Expression? {
    var current = currentIn
    while !stack.isEmpty && peekLevel(stack) >= level {
      let top = stack.removeLast()
      guard current != nil else {
        throw top.cause.error("missingRightOperandError", [top.cause.text])
      }
      switch top.cause.type {
      case .and: current = Expressions.and(top.current, current)
      case .or: current = Expressions.or(top.current, current)
      case .xor: current = Expressions.xor(top.current, current)
      case .xnor: current = Expressions.xnor(top.current, current)
      case .eq: current = Expressions.eq(top.current, current)
      case .not: current = Expressions.not(current)
      default: break
      }
    }
    return current
  }

  /// Java: `replaceVariable(String in, String oldName, String newName)`: a rename that
  /// preserves the user's own spacing, by tokenizing with whitespace included and
  /// re-stringifying.
  public static func replaceVariable(_ input: String, _ oldName: String, _ newName: String)
    -> String
  {
    var ret = ""
    for token in toTokens(input, includeWhite: true) {
      if token.type == .ident && token.text == oldName {
        ret += newName
      } else {
        ret += token.text
      }
    }
    return ret
  }

  // MARK: - Tokenizer

  static func toTokens(_ input: String, includeWhite: Bool) -> [Token] {
    Tokenizer(input, includeWhite: includeWhite).tokenize()
  }

  /// Java: `Parser.Tokenizer`.
  final class Tokenizer {
    /// Java pads the input with a trailing space "so that we will stop just after reading
    /// whitespace, not in the middle of a token", and then indexes past `len` in a couple of
    /// places. `charAt` returns that padding for any index past the end, which is safe here
    /// and is what makes the fix noted in `tokenize()` possible.
    private let chars: [Character]
    private let includeWhite: Bool
    private let len: Int
    private var pos = 0

    init(_ input: String, includeWhite: Bool) {
      self.chars = Array(input)
      self.len = chars.count
      self.includeWhite = includeWhite
    }

    private func charAt(_ i: Int) -> Character { i < len ? chars[i] : " " }
    private func peek() -> Character { charAt(pos) }
    private func next() -> Character {
      defer { pos += 1 }
      return charAt(pos)
    }
    private func substring(_ from: Int, _ to: Int) -> String {
      String(chars[Swift.min(from, len)..<Swift.min(Swift.max(to, from), len)])
    }
    /// Java's `in.substring(bracestart)`, where `in` is the input **plus its trailing pad
    /// space**, so the reported text of an unterminated-brace error always ends in a space.
    /// That stray space is visible to the user in "No matching brace: “[ ”", so it is
    /// reproduced rather than trimmed away.
    private func substring(from: Int) -> String { substring(from, len) + " " }

    @discardableResult
    private func skipWhile(_ pred: (Character) -> Bool) -> Bool {
      while pos < len && pred(peek()) { pos += 1 }
      return pos == len
    }

    @discardableResult
    private func skipUntil(_ pred: @escaping (Character) -> Bool) -> Bool {
      skipWhile { !pred($0) }
    }

    @discardableResult
    private func skipSpaces() -> Bool { skipWhile { $0.isWhitespace } }

    private func readNumber() -> String {
      let substart = pos
      skipWhile(isDigit)
      return substring(substart, pos)
    }

    private func isDigit(_ c: Character) -> Bool { c >= "0" && c <= "9" }

    private func accept(_ c: Character) -> Bool {
      if peek() == c {
        pos += 1
        return true
      }
      return false
    }

    /// Java: `readToken(char, int)`.
    private func readToken(_ startChar: Character, _ start: Int) -> Token {
      typealias N = Expression.Notation
      switch startChar {
      case "(":
        return Token(.lparen, start, "(", Int(Int32.max))
      case ")":
        return Token(.rparen, start, ")", Int(Int32.max))
      case "1", "\u{22A4}":  // down tack
        return Token(.const, start, "1", Int(Int32.max))
      case "0", "\u{22A5}":  // up tack
        return Token(.const, start, "0", Int(Int32.max))
      case "~", "-", "\u{00AC}", "\u{02DC}":  // logical not, tilde
        return Token(.not, start, "~", N.notPrecedence)
      case "!":
        if accept("=") {
          return Token(.xor, start, substring(start, pos), N.logicPrecedence)
        } else {
          return Token(.not, start, "~", N.notPrecedence)
        }
      case "'":
        return Token(.notPostfix, start, "'", N.notPrecedence)
      case "^", "\u{2295}":  // oplus
        return Token(.xor, start, "^", N.oplusPrecedence)
      case "\u{22BB}", "\u{2262}", "\u{2260}":  // vee-underbar, not-equiv, not-equals
        return Token(.xor, start, "^", N.logicPrecedence)
      case "+", "\u{22C1}", "\u{2228}":  // large/small disjunction
        return Token(.or, start, "+", N.logicPrecedence)
      case "\u{2225}":  // logical or
        return Token(.or, start, "+", N.orPrecedence)
      case "*", "\u{22C0}", "\u{2227}":  // large/small conjunction
        return Token(.and, start, "*", N.logicPrecedence)
      case "\u{22C5}", "\u{2219}", "\u{00B7}":  // cdot, bullet, middle-dot
        return Token(.and, start, "*", N.timesPrecedence)
      case "\u{2299}":  // otimes
        return Token(.xnor, start, "^", N.otimesPrecedence)
      case "\u{21D4}", "\u{2261}", "\u{2194}":  // double arrow, equiv, arrow
        return Token(.xnor, start, "=", N.logicPrecedence)
      case "&":
        if accept("&") {
          return Token(.and, start, "&&", N.andPrecedence)
        } else {
          return Token(.and, start, "&", N.bitAndPrecedence)
        }
      case "|":
        if accept("|") {
          return Token(.or, start, "||", N.orPrecedence)
        } else {
          return Token(.or, start, "|", N.bitOrPrecedence)
        }
      case "=":
        _ = accept("=")
        return Token(.xnor, start, substring(start, pos), N.logicPrecedence)
      case ":":
        _ = accept("=")
        return Token(.eq, start, substring(start, pos), N.eqPrecedence)
      case "[", "]":
        return Token(.errorIdent, start, substring(start, start + 1), 0)
      default:
        skipUntil(Parser.okCharacter)
        return Token(.errorBadChar, start, substring(start, pos), 0)
      }
    }

    /// Java: `tokenize()`.
    func tokenize() -> [Token] {
      var tokens: [Token] = []
      pos = 0
      while true {
        let whiteStart = pos
        skipSpaces()
        if includeWhite && pos != whiteStart {
          tokens.append(Token(.white, whiteStart, substring(whiteStart, pos), 0))
        }
        if pos >= len { return tokens }

        let start = pos
        let startChar = next()
        if Parser.isJavaIdentifierStart(startChar) {
          skipWhile(Parser.isJavaIdentifierPart)
          let name = substring(start, pos)
          var subscriptText: String?
          if charAt(pos) == ":" && isDigit(charAt(pos + 1)) {
            pos += 1
            subscriptText = readNumber()
          } else if charAt(pos) == "[" {
            let bracestart = pos
            pos += 1
            if skipSpaces() {  // EOL
              tokens.append(Token(.errorBrace, start, substring(from: bracestart), 0))
              continue
            }
            subscriptText = readNumber()
            if skipSpaces() || !accept("]") {  // EOL or missing bracket
              tokens.append(Token(.errorBrace, start, substring(from: bracestart), 0))
              continue
            }
            // Divergence, measured, deliberate: Java has a second `pos++` here, on top of
            // the one `accept(']')` already did, so it swallows the character *after* the
            // closing bracket. Against the shipped 4.1.0 jar:
            //
            //     parse("a[1]")        -> StringIndexOutOfBoundsException: Index 5, length 5
            //     parse("a[1] + a[0]") -> StringIndexOutOfBoundsException: Index 12, length 12
            //     parse("a[1]+b")      -> a[1]⋅b     (the '+' was eaten; OR became AND)
            //     parse("a[1]'")       -> a[1]       (the postfix NOT was eaten and lost)
            //
            // i.e. every expression ending in a bus subscript crashes, and the two that do
            // not crash are silently *wrong*. There is nothing to preserve here: an
            // uncatchable index crash is not behaviour, and D13 is explicit that a parse
            // failure must be a throw the caller can show the user.
          }
          if var sub = subscriptText {
            sub = sub.trimmedForAnalyze()
            if sub.isEmpty {
              tokens.append(Token(.errorSubscript, start, substring(start, pos), 0))
              continue
            }
            if let s = Int32(sub) {
              tokens.append(Token(.ident, start, "\(name)[\(s)]", Int(Int32.max)))
            } else {
              // should not happen: readNumber only returns digits
              tokens.append(Token(.errorSubscript, start, substring(start, pos), 0))
            }
          } else {
            tokens.append(Token(.ident, start, name, Int(Int32.max)))
          }
        } else {
          tokens.append(readToken(startChar, start))
        }
      }
    }
  }
}
