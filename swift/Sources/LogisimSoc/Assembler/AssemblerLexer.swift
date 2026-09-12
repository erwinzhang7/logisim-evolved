// AssemblerLexer.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.soc.data.AssemblerHighlighter,
// com.cburch.logisim.soc.util.Assembler.checkAndBuildTokens), GPL-3.0-only. See LICENSE.md.
// Reference tree: upstream-java-4.1.0 (D16).
//
// SEAM (D9): upstream's tokenizer is not a standalone lexer; it is an
// `org.fife.ui.rsyntaxtextarea.AbstractTokenMaker` wired into a live `RSyntaxTextArea` Swing
// editor widget, and `Assembler.checkAndBuildTokens` reads already-classified tokens back out
// of that widget's per-line token cache. None of that can live in a UI-free module. This is a
// from-scratch hand-written scanner over `[String]` source lines that reproduces the same
// *classification outcome* `AssemblerHighlighter.check()` computes character-by-character:
// not a line-by-line port of its (Swing-token-type-indexed) state-machine encoding, which has
// no meaning outside a live `RSyntaxTextArea`. What must match, and does:
//
//   * Punctuation `( ) { } [ ] , : + - * / %` each become their own one-character token; `<<`
//     and `>>` are recognised as two-character shift operators, everything else single-char.
//   * `#` starts a line comment that runs to end of line (dropped, matching
//     `Assembler.checkAndBuildTokens`, which never emits `COMMENT_EOL`/`NULL`/`WHITESPACE`).
//   * A run of digits is a decimal-number token UNLESS it is immediately followed by `x`/`X`
//     (case-insensitively), in which case that whole run, leading digit(s), the `x`, and every
//     following hex digit, becomes ONE hex-number token (`AssemblerToken`'s constructor then
//     splits off the part after the `x`). This mirrors `check()`'s `case 'x','X'` transition,
//     which keeps accumulating into the *same* token run rather than starting a new one.
//   * `"..."` is a string token; an unterminated string at end-of-line carries its open state
//     into the next line (mirrors `RSyntaxTextArea` re-invoking the token maker with
//     `initialTokenType` equal to the previous line's trailing type), so
//     `Assembler.swift`'s "merge consecutive STRING tokens" pass has the same multi-line
//     fragments to merge that upstream produces. A backslash inside a string escapes the next
//     character (so `\"` does not close it).
//   * `@` starts a macro-parameter token that runs while the identifier-continuation predicate
//     holds (`Token.PREPROCESSOR`).
//   * Everything else contiguous (letters, digits once past a leading letter, `.` for
//     directives like `.byte`) is a bare word, classified against an injected `wordMap`
//     exactly like `AbstractTokenMaker.addToken`'s `wordsToHighlight` override: opcodes →
//     `.instruction`, registers/`pc` → `.register`/`.programCounter`, directives →
//     `.asmInstruction` (see `AssemblerDirectives.all`), anything unmatched → `.maybeLabel`.
//     `Nios2SyntaxHighlighter` (itself dead code per its own "FIXME: unused" comment, ported
//     anyway per the fidelity brief) is exactly the map-construction logic this file's caller
//     runs to build that `wordMap`.
//
// Known, narrow divergence: word-map matching here is case-SENSITIVE (an identifier must match
// a registered opcode/register/directive spelling exactly), consistent with every name in this
// codebase already being registered and emitted in lowercase. Upstream's `TokenMap()` default
// case-sensitivity was not independently re-verified against the (unvendored) RSyntaxTextArea
// sources; flagged for confirmation once a Swing-editor-based golden trace exists.
public enum AssemblerRawTokenKind: Equatable {
  case literalChar(Character)
  case mathShiftLeft
  case mathShiftRight
  case decNumber
  case hexNumber
  case string
  /// A bare word matched against the injected word map; carries the `AssemblerToken.*` type
  /// constant the map assigned (`.asmInstruction`, `.instruction`, `.register`,
  /// `.programCounter`, or a CPU-custom type ≥ 256).
  case word(Int)
  case maybeLabel
  case preprocessor
}

public struct AssemblerRawToken {
  public let kind: AssemblerRawTokenKind
  public let text: String
  public let offset: Int
}

public enum AssemblerLexer {

  /// Tokenizes every line. `wordMap` classifies bare words (built by the CPU-specific
  /// `AssemblerInterface`, mirroring `*SyntaxHighlighter.getWordsToHighlight()`).
  /// `usesRoundedBrackets` selects `(`/`)` vs `[`/`]` as this CPU's index brackets
  /// (`AssemblerInterface.usesRoundedBrackets`); the wrong kind is reported via `onError`,
  /// matching `Assembler.checkAndBuildTokens`'s `AssemblerWrongOpeningBracket`/
  /// `WrongClosingBracket` handling.
  public static func tokenize(
    lines: [String],
    wordMap: [String: Int],
    usesRoundedBrackets: Bool,
    onError: (_ offset: Int, _ message: AssemblerMessage) -> Void
  ) -> [AssemblerRawToken] {
    var result: [AssemblerRawToken] = []
    var offset = 0
    var openString: (text: String, offset: Int, escapeNext: Bool)? = nil
    for line in lines {
      let chars = Array(line)
      let (tokens, carried) = tokenizeLine(
        chars: chars, baseOffset: offset, openString: openString, wordMap: wordMap,
        usesRoundedBrackets: usesRoundedBrackets, onError: onError)
      result.append(contentsOf: tokens)
      openString = carried
      // Upstream's Document offsets count the newline between lines (`getLineStartOffset`
      // includes it); `+ 1` reproduces that so token offsets land on the values a real
      // multi-line source buffer would produce.
      offset += chars.count + 1
    }
    if let open = openString {
      result.append(AssemblerRawToken(kind: .string, text: open.text, offset: open.offset))
    }
    return result
  }

  private static func tokenizeLine(
    chars: [Character], baseOffset: Int,
    openString: (text: String, offset: Int, escapeNext: Bool)?,
    wordMap: [String: Int], usesRoundedBrackets: Bool,
    onError: (_ offset: Int, _ message: AssemblerMessage) -> Void
  ) -> (tokens: [AssemblerRawToken], carriedString: (text: String, offset: Int, escapeNext: Bool)?) {
    var tokens: [AssemblerRawToken] = []
    var i = 0
    var stringState = openString

    func isWordStart(_ c: Character) -> Bool { c.isLetter || c == "." || c == "_" }
    func isWordContinuation(_ c: Character) -> Bool {
      c.isLetter || c.isNumber || c == "." || c == "_"
    }
    func isDigitASCII(_ c: Character) -> Bool { c.isASCII && c.isNumber }
    func isHexDigit(_ c: Character) -> Bool {
      isDigitASCII(c) || ("a"..."f").contains(c) || ("A"..."F").contains(c)
    }

    while i < chars.count {
      // Continue an already-open string carried from a previous line, or one opened earlier
      // on this same line.
      if stringState != nil {
        var open = stringState!
        while i < chars.count {
          let c = chars[i]
          open.text.append(c)
          i += 1
          if c == "\"" && !open.escapeNext {
            tokens.append(AssemblerRawToken(kind: .string, text: open.text, offset: open.offset))
            stringState = nil
            break
          }
          open.escapeNext = (c == "\\") && !open.escapeNext
          stringState = open
        }
        continue
      }

      let c = chars[i]
      switch c {
      case " ", "\t":
        i += 1

      case "#":
        i = chars.count  // line comment: consume to end of line, emit nothing

      case "\"":
        stringState = (text: "\"", offset: baseOffset + i, escapeNext: false)
        i += 1

      case "<":
        if i + 1 < chars.count, chars[i + 1] == "<" {
          tokens.append(AssemblerRawToken(kind: .mathShiftLeft, text: "<<", offset: baseOffset + i))
          i += 2
        } else {
          onError(baseOffset + i, .assemblerUnknowCharacter)
          i += 1
        }

      case ">":
        if i + 1 < chars.count, chars[i + 1] == ">" {
          tokens.append(AssemblerRawToken(kind: .mathShiftRight, text: ">>", offset: baseOffset + i))
          i += 2
        } else {
          onError(baseOffset + i, .assemblerUnknowCharacter)
          i += 1
        }

      case "@":
        let start = i
        i += 1
        while i < chars.count, isWordContinuation(chars[i]) { i += 1 }
        tokens.append(
          AssemblerRawToken(kind: .preprocessor, text: String(chars[start..<i]), offset: baseOffset + start))

      case "(", ")", "[", "]", "{", "}":
        appendBracket(c, offset: baseOffset + i, usesRoundedBrackets: usesRoundedBrackets, onError: onError)
          .map { tokens.append($0) }
        i += 1

      case ",", ":", "+", "-", "*", "/", "%":
        tokens.append(AssemblerRawToken(kind: .literalChar(c), text: String(c), offset: baseOffset + i))
        i += 1

      default:
        if isDigitASCII(c) {
          let start = i
          while i < chars.count, isDigitASCII(chars[i]) { i += 1 }
          if i < chars.count, chars[i] == "x" || chars[i] == "X" {
            // Hex literal: keep consuming hex digits after the 'x'. The whole run
            // (leading decimal digit(s) + 'x' + hex digits) is ONE hex-number token:
            // `AssemblerToken`'s constructor splits off the part after the 'x'.
            i += 1
            while i < chars.count, isHexDigit(chars[i]) { i += 1 }
            tokens.append(
              AssemblerRawToken(kind: .hexNumber, text: String(chars[start..<i]), offset: baseOffset + start))
          } else {
            tokens.append(
              AssemblerRawToken(kind: .decNumber, text: String(chars[start..<i]), offset: baseOffset + start))
          }
        } else if isWordStart(c) {
          let start = i
          while i < chars.count, isWordContinuation(chars[i]) { i += 1 }
          let text = String(chars[start..<i])
          let offset = baseOffset + start
          if let mapped = wordMap[text] {
            tokens.append(AssemblerRawToken(kind: .word(mapped), text: text, offset: offset))
          } else {
            tokens.append(AssemblerRawToken(kind: .maybeLabel, text: text, offset: offset))
          }
        } else {
          onError(baseOffset + i, .assemblerUnknowCharacter)
          i += 1
        }
      }
    }
    return (tokens, stringState)
  }

  private static func appendBracket(
    _ c: Character, offset: Int, usesRoundedBrackets: Bool,
    onError: (_ offset: Int, _ message: AssemblerMessage) -> Void
  ) -> AssemblerRawToken? {
    switch c {
    case "(":
      if !usesRoundedBrackets { onError(offset, .assemblerWrongOpeningBracket); return nil }
    case ")":
      if !usesRoundedBrackets { onError(offset, .assemblerWrongClosingBracket); return nil }
    case "[":
      if usesRoundedBrackets { onError(offset, .assemblerWrongOpeningBracket); return nil }
    case "]":
      if usesRoundedBrackets { onError(offset, .assemblerWrongClosingBracket); return nil }
    case "{":
      onError(offset, .assemblerWrongOpeningBracket)
      return nil
    case "}":
      onError(offset, .assemblerWrongClosingBracket)
      return nil
    default:
      break
    }
    return AssemblerRawToken(kind: .literalChar(c), text: String(c), offset: offset)
  }
}
