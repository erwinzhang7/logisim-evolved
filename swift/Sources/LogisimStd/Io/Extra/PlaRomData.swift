// PlaRomData.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.io.extra.PlaRomData),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// The programmable AND/OR matrix behind `PlaRom`: `inputAnd[row][input*2 + {0=NOT,1=direct}]`
// selects which (possibly inverted) inputs feed AND-term `row`; `andOutput[row][output]`
// selects which AND-terms feed each OR'd output. `saveData()`/`decodeSavedData(_:)` are the
// run-length-encoded `.circ` attribute text this all round-trips through: ported bit-for-bit,
// including its quirks (see inline notes), since a byte-exact `Contents` attribute is exactly
// what M2's round-trip gate would catch a divergence in.
//
// ── What did not come across ─────────────────────────────────────────────────────────────────
//
//   * `editWindow()` / `PlaRomPanel`; the Swing matrix editor. Pure UI (M6+); every method here
//     that the editor calls (`setInputAndValue`, `setAndOutputValue`, `clearMatrixValues`) is
//     ported because `propagate` depends on the same state, just not the dialog itself.
//   * `rowHovered` / `columnHovered`: mouse-hover highlighting in the editor. UI-only.

import Foundation
import LogisimKernel

/// D13: the two unchecked exceptions `PlaRomData.decodeSavedData` raises on malformed `Contents`
/// text. Java throws `NumberFormatException` and `ArrayIndexOutOfBoundsException` respectively;
/// both reach `Simulator.recordException` by way of `PlaRom.propagate`, so both become throws
/// rather than the `?? 0` substitution (and, for a negative repeat count, the range trap) the
/// first port had.
public enum PlaRomContentsError: Error, CustomStringConvertible, Equatable, Sendable {
  /// `Integer.parseInt` on a token that is not a 32-bit decimal integer.
  case notANumber(String)
  /// A token containing `*` whose `split("\\*")` has no element at index 1, `"1*"`, `"*"`.
  case missingRepeatCount(String)

  public var description: String {
    switch self {
    case .notANumber(let token):
      return "PLA ROM contents: for input string: \"\(token)\""
    case .missingRepeatCount(let token):
      return "PLA ROM contents: repeat token \"\(token)\" has no count after '*'"
    }
  }
}

/// Java's `String.split(String regex)` for a single literal character: keeps leading and interior
/// empty segments, discards trailing ones. `"0 0 ".split(" ")` is `["0", "0"]`, which is what
/// `saveData()`'s trailing space relies on, while `"0  0".split(" ")` is `["0", "", "0"]`, whose
/// empty middle segment Java then throws on. `Substring.split` drops *every* empty segment and so
/// silently accepted both.
///
/// A near-twin of `LogisimFile`'s `javaSplitOnLiteral`, which is `internal` to that module and
/// therefore not reachable from here; worth hoisting into `LogisimKernel` once something outside
/// this file pair needs it.
func javaSplitOnLiteral(_ text: String, separator: Character) -> [String] {
  var parts = text.split(separator: separator, omittingEmptySubsequences: false).map(String.init)
  while let last = parts.last, last.isEmpty { parts.removeLast() }
  return parts
}

/// `com.cburch.logisim.std.io.extra.PlaRomData`.
public final class PlaRomData: InstanceData {
  private var inputCount: Int
  private var outputCount: Int
  private var andCount: Int
  private(set) var savedData = ""
  private var inputAndPlane: [[Bool]]
  private var andOutputPlane: [[Bool]]
  private var inputPlane: [Value]
  private var andPlane: [Value]
  private var outputPlane: [Value]

  public init(inputs: Int, outputs: Int, and: Int) {
    self.inputCount = inputs
    self.outputCount = outputs
    self.andCount = and
    self.inputAndPlane = Array(repeating: Array(repeating: false, count: inputs * 2), count: and)
    self.andOutputPlane = Array(repeating: Array(repeating: false, count: outputs), count: and)
    self.inputPlane = Array(repeating: .unknownValue, count: inputs)
    self.andPlane = Array(repeating: .falseValue, count: and)
    self.outputPlane = Array(repeating: .falseValue, count: outputs)
    recomputeAnd()
    recomputeOutput()
  }

  private init(
    inputCount: Int, outputCount: Int, andCount: Int, savedData: String,
    inputAndPlane: [[Bool]], andOutputPlane: [[Bool]], inputPlane: [Value], andPlane: [Value],
    outputPlane: [Value]
  ) {
    self.inputCount = inputCount
    self.outputCount = outputCount
    self.andCount = andCount
    self.savedData = savedData
    self.inputAndPlane = inputAndPlane
    self.andOutputPlane = andOutputPlane
    self.inputPlane = inputPlane
    self.andPlane = andPlane
    self.outputPlane = outputPlane
  }

  public func cloneData() -> any InstanceData {
    PlaRomData(
      inputCount: inputCount, outputCount: outputCount, andCount: andCount, savedData: savedData,
      inputAndPlane: inputAndPlane, andOutputPlane: andOutputPlane, inputPlane: inputPlane,
      andPlane: andPlane, outputPlane: outputPlane)
  }

  public var inputs: Int { inputCount }
  public var outputs: Int { outputCount }
  public var and: Int { andCount }

  /// `PlaRomData.getSizeString()`: `inputs + 'x' + and + "x" + outputs`.
  public var sizeString: String { "\(inputCount)x\(andCount)x\(outputCount)" }

  public func getSavedData() -> String { savedData }

  public func inputAndValue(row: Int, column: Int) -> Bool { inputAndPlane[row][column] }
  public func andOutputValue(row: Int, column: Int) -> Bool { andOutputPlane[row][column] }
  public func andValue(at i: Int) -> Value { andPlane[i] }
  public func inputValue(at i: Int) -> Value { inputPlane[i] }
  public func outputValue(at i: Int) -> Value { outputPlane[i] }

  /// `PlaRomData.getOutputValues()`: reverses the array (LSB-first port ↔ MSB-first matrix
  /// column order), exactly as upstream.
  public func reversedOutputValues() -> [Value] {
    var reversed = [Value](repeating: .falseValue, count: outputCount)
    for i in stride(from: outputCount - 1, through: 0, by: -1) {
      reversed[i] = outputPlane[outputPlane.count - i - 1]
    }
    return reversed
  }

  /// `PlaRomData.clearMatrixValues()`.
  public func clearMatrixValues() {
    for i in 0..<andCount {
      for j in 0..<outputCount { andOutputPlane[i][j] = false }
      for k in 0..<(inputCount * 2) { inputAndPlane[i][k] = false }
    }
    savedData = ""
  }

  public func setAndOutputValue(row: Int, column: Int, _ value: Bool) {
    andOutputPlane[row][column] = value
    recomputeAnd()
    recomputeOutput()
  }

  public func setInputAndValue(row: Int, column: Int, _ value: Bool) {
    inputAndPlane[row][column] = value
    recomputeAnd()
    recomputeOutput()
  }

  /// `PlaRomData.setInputsValue(Value[])`: right-aligns `inputs` into the input plane, matching
  /// upstream's `System.arraycopy` offsets exactly (a caller supplying more values than this ROM
  /// has inputs is truncated from the front, not the back).
  public func setInputsValue(_ inputs: [Value]) {
    let n = min(inputCount, inputs.count)
    guard n > 0 else { return }
    for i in 0..<n {
      inputPlane[inputCount - n + i] = inputs[inputs.count - n + i]
    }
    recomputeAnd()
    recomputeOutput()
  }

  /// `PlaRomData.updateSize(byte, byte, byte)`. Returns whether the size actually changed
  /// (upstream's boolean result, used by callers to know whether to re-save `Contents`).
  @discardableResult
  public func updateSize(inputs newInputs: Int, outputs newOutputs: Int, and newAnd: Int) -> Bool {
    guard newInputs != inputCount || newOutputs != outputCount || newAnd != andCount else {
      return false
    }
    let minInputs = min(inputCount, newInputs)
    let minOutputs = min(outputCount, newOutputs)
    let minAnd = min(andCount, newAnd)
    let oldInputAnd = inputAndPlane
    let oldAndOutput = andOutputPlane

    inputCount = newInputs
    outputCount = newOutputs
    andCount = newAnd
    inputAndPlane = Array(repeating: Array(repeating: false, count: inputCount * 2), count: andCount)
    andOutputPlane = Array(repeating: Array(repeating: false, count: outputCount), count: andCount)
    inputPlane = Array(repeating: .unknownValue, count: inputCount)
    andPlane = Array(repeating: .falseValue, count: andCount)
    outputPlane = Array(repeating: .falseValue, count: outputCount)

    for i in 0..<minAnd {
      for k in 0..<(minInputs * 2) { inputAndPlane[i][k] = oldInputAnd[i][k] }
      for j in 0..<minOutputs { andOutputPlane[i][j] = oldAndOutput[i][j] }
    }
    recomputeAnd()
    recomputeOutput()
    saveData()
    return true
  }

  /// `PlaRomData.setAndValue()`. Bug-for-bug: an AND row with no dots selected at all reports
  /// `ERROR`, not `TRUE`; preserved (`thereisadot` starts `false` and the fallback fires
  /// whenever it stays that way).
  private func recomputeAnd() {
    for i in 0..<andCount {
      var value: Value = .trueValue
      var hasDot = false
      outer: for j in 0..<(inputCount * 2) {
        guard inputAndPlane[i][j] else { continue }
        hasDot = true
        if j % 2 == 0 {
          // NOT-input dot.
          if !inputPlane[j / 2].isFullyDefined() {
            value = .errorValue
          } else if inputPlane[j / 2] == .trueValue {
            value = .falseValue
            break outer
          }
        } else {
          // Direct-input dot.
          if !inputPlane[(j - 1) / 2].isFullyDefined() {
            value = .errorValue
          } else if inputPlane[(j - 1) / 2] == .falseValue {
            value = .falseValue
            break outer
          }
        }
      }
      andPlane[i] = hasDot ? value : .errorValue
    }
  }

  /// `PlaRomData.setOutputValue()`.
  private func recomputeOutput() {
    for i in 0..<outputCount {
      var value: Value = .falseValue
      var hasDot = false
      for j in 0..<andCount where andOutputPlane[j][i] {
        value = value.or(andPlane[j])
        hasDot = true
      }
      outputPlane[i] = hasDot ? value : .errorValue
    }
  }

  // MARK: `Contents` attribute codec

  /// `PlaRomData.decodeSavedData(String)`.
  ///
  /// D13. Java's body is nothing but `Integer.parseInt` calls on untrusted `Contents` text, every
  /// one of which can throw `NumberFormatException`, plus a `tmp[1]` that can throw
  /// `ArrayIndexOutOfBoundsException`; both are unchecked, both reach `Simulator.recordException`
  /// through `propagate`, and both must therefore be Swift `throw`s. The previous port used
  /// `Int(...) ?? 0` and `0..<count`, which got all three of the following wrong:
  ///
  ///   * `"1*-1"`: `Integer.parseInt("-1")` is `-1`, `j < -1` is false, and Java writes nothing.
  ///     `0..<(-1)` is a **trap**: "Range requires lowerBound <= upperBound". This is the D13
  ///     violation proper, and a one-token `Contents` attribute reaches it.
  ///   * `"256"`: Java parses 256 and *then* narrows with `(byte)`, giving 0, which clears the
  ///     cell. `Int("256")` gave 256, which `writeData`'s `default:` silently ignored. Hence
  ///     `writeData` now takes an `Int8` and the truncation happens at the call, where Java's is.
  ///   * `"1*"` / `"x"`; Java throws. `?? 0` substituted a legal value and wrote a cell the user
  ///     never asked for, turning a corrupt file into a silently *different* circuit.
  ///
  /// The evaluation order of the repeat loop is load-bearing and preserved: `Integer.parseInt`
  /// on the count sits in the `for` **condition**, so it runs before the value is parsed at all.
  /// `"*0"` therefore parses the count, finds zero iterations, and never touches the empty value
  /// : no throw. `"*5"` parses the same count, enters the loop, and only then throws on `""`.
  public func decodeSavedData(_ text: String?) throws {
    guard let text, !text.isEmpty else { return }
    var index = 0
    for token in javaSplitOnLiteral(text, separator: " ") {
      if token.contains("*") {
        // `datum.split("\\*")`: `"1*"` yields just `["1"]` because Java drops trailing empty
        // segments, so `tmp[1]` is an out-of-bounds read, not an empty count.
        let parts = javaSplitOnLiteral(token, separator: "*")
        guard parts.count > 1 else {
          throw PlaRomContentsError.missingRepeatCount(token)
        }
        guard let repeats = javaParseInt32(parts[1]) else {
          throw PlaRomContentsError.notANumber(parts[1])
        }
        var j = 0
        while j < repeats {
          guard let value = javaParseInt32(parts[0]) else {
            throw PlaRomContentsError.notANumber(parts[0])
          }
          writeData(Int8(truncatingIfNeeded: value), at: index)
          index += 1
          j += 1
        }
      } else {
        guard let value = javaParseInt32(token) else {
          throw PlaRomContentsError.notANumber(token)
        }
        writeData(Int8(truncatingIfNeeded: value), at: index)
        index += 1
      }
    }
  }

  /// `PlaRomData.writeData(byte, int)`. The parameter really is a `byte` upstream: see
  /// `decodeSavedData`'s note on `"256"`.
  private func writeData(_ value: Int8, at node: Int) {
    if node < inputCount * andCount {
      let row = node / inputCount
      let column = node - row * inputCount
      switch value {
      case 0:
        inputAndPlane[row][column * 2] = false
        inputAndPlane[row][column * 2 + 1] = false
      case 1:
        inputAndPlane[row][column * 2] = true
        inputAndPlane[row][column * 2 + 1] = false
      case 2:
        inputAndPlane[row][column * 2] = false
        inputAndPlane[row][column * 2 + 1] = true
      default:
        return
      }
    } else if node < inputCount * andCount + outputCount * andCount {
      let n = node - inputCount * andCount
      let row = n / outputCount
      let column = n - row * outputCount
      switch value {
      case 0: andOutputPlane[row][column] = false
      case 1: andOutputPlane[row][column] = true
      default: return
      }
    }
  }

  /// `PlaRomData.saveData()`: run-length-encodes both matrices, `and`-row-major then
  /// `or`-row-major, dropping the whole string to `""` when nothing is set (`dirty` stays
  /// `false`). Ported field-for-field against the Java, including the odd "count starts at 1
  /// the first time `last` is assigned" bookkeeping.
  private func saveData() {
    var data = ""
    var dirty = false

    func encode(size: Int, valueAt: (Int) -> Character) {
      var last: Character = "x"
      var count = 0
      for i in 0..<size {
        let val = valueAt(i)
        if val != "0" { dirty = true }
        if val == last {
          count += 1
        } else if last == "x" {
          last = val
          count += 1
        }
        if val != last || i == size - 1 {
          if count >= 3 {
            data.append(last)
            data.append("*")
            data.append(String(count))
            data.append(" ")
          } else {
            for _ in 0..<count {
              data.append(last)
              data.append(" ")
            }
          }
          if val != last && i == size - 1 {
            data.append(val)
            data.append(" ")
          }
          count = 1
          last = val
        }
      }
    }

    let size1 = inputCount * andCount
    encode(size: size1) { i in
      let row = i / inputCount
      let column = i - row * inputCount
      if inputAndPlane[row][column * 2] { return "1" }
      if inputAndPlane[row][column * 2 + 1] { return "2" }
      return "0"
    }

    let size2 = outputCount * andCount
    encode(size: size2) { i in
      let row = i / outputCount
      let column = i - row * outputCount
      return andOutputPlane[row][column] ? "1" : "0"
    }

    savedData = dirty ? data : ""
  }
}
