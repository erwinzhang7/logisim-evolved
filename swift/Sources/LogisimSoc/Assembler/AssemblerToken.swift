// AssemblerToken.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.soc.util.AssemblerToken),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// Uses `javaParseInt32` (LogisimKernel/Location.swift) for `Integer.parseInt` fidelity: 32-bit
// range, Unicode-digit acceptance; see that file's header for why `Int(_:)` is wrong here.
//
// Java gives `AssemblerToken` no `equals`/`hashCode` override, so every `HashMap<AssemblerToken,
// ...>` in this subsystem (error markers, label maps) keys by *reference identity*. This is
// ported as a `final class` with identity `Hashable`/`Equatable` (`===`), the same convention
// D4 uses for `Component`; structural equality here would silently merge distinct tokens that
// happen to carry the same type/value/offset (e.g. two `add` opcodes on different lines).
import LogisimKernel

public final class AssemblerToken {
  public static let label = 1
  public static let instruction = 2
  public static let asmInstruction = 3
  public static let bracketedRegister = 4
  public static let register = 5
  public static let decNumber = 6
  public static let hexNumber = 7
  public static let maybeLabel = 8
  public static let string = 9
  public static let seperator = 10
  public static let bracketOpen = 11
  public static let bracketClose = 12
  public static let labelIdentifier = 13
  public static let mathSubtract = 14
  public static let mathAdd = 15
  public static let parameterLabel = 16
  public static let mathMul = 17
  public static let mathDiv = 18
  public static let mathRem = 19
  public static let mathShiftLeft = 20
  public static let mathShiftRight = 21
  public static let programCounter = 22
  public static let macro = 23
  public static let macroParameter = 24
  /* All numbers below 256 are reserved for internal usage; numbers starting from 256 are
   * free for CPU-specific purposes (Nios2Assembler.CUSTOM_REGISTER/CONTROL_REGISTER use
   * 256/257 for exactly this reason). */

  public static let mathOperators: Set<Int> = [
    mathAdd, mathSubtract, mathMul, mathDiv, mathRem, mathShiftLeft, mathShiftRight,
  ]

  public private(set) var type: Int
  public private(set) var value: String
  public let offset: Int
  public private(set) var isValid: Bool
  public private(set) var isLabel: Bool

  public init(type: Int, value: String?, offset: Int) {
    self.type = type
    self.value = value ?? ""
    self.offset = offset
    self.isValid = true
    self.isLabel = type == AssemblerToken.label

    if type == AssemblerToken.hexNumber {
      let split = javaSplitTrailingEmptyRemoved(self.value.uppercased(), on: "X")
      if split.count != 2 {
        self.isValid = false
        return
      }
      self.value = split[1]
    }
    if type == AssemblerToken.string {
      let v = self.value
      var start = v.startIndex
      var end = v.endIndex
      if v.first == "\"" { start = v.index(after: start) }
      if v.count > 1 {
        let lastIndex = v.index(before: end)
        let secondLastIndex = v.index(before: lastIndex)
        if v[lastIndex] == "\"" && v[secondLastIndex] != "\\" {
          end = lastIndex
        }
      }
      self.value = start >= end ? "" : String(v[start..<end])
    }
  }

  public var isNumber: Bool {
    type == AssemblerToken.decNumber || type == AssemblerToken.hexNumber
  }

  public func setType(_ newType: Int) {
    type = newType
    if newType == AssemblerToken.label || newType == AssemblerToken.labelIdentifier
      || newType == AssemblerToken.parameterLabel
    {
      isLabel = true
    }
  }

  public func setValue(_ val: Int) {
    value = String(val)
    type = AssemblerToken.decNumber
  }

  public func setValue(_ str: String) {
    value = str
  }

  /// `getNumberValue()`. Mutates `value` in place the first time a hex token still carrying its
  /// `0x` prefix is queried (see `AssemblerAsmInstruction.replaceLabels`/`replacePcAndDoCalc`,
  /// which `setValue(String.format("0x%08X", …))` then `setType(HEX_NUMBER)` without going back
  /// through the constructor): ported literally, including the mutation.
  public func getNumberValue() -> Int {
    if type == AssemblerToken.decNumber {
      return javaParseInt32(value) ?? 0
    } else if type == AssemblerToken.hexNumber {
      if value.uppercased().contains("X") {
        let split = javaSplitTrailingEmptyRemoved(value.uppercased(), on: "X")
        if split.count != 2 {
          isValid = false
          return 0
        }
        value = split[1]
      }
      return javaParseUnsignedInt32(value, radix: 16) ?? 0
    } else if type == AssemblerToken.macroParameter {
      if !value.isEmpty {
        return javaParseUnsignedInt32(String(value.dropFirst()), radix: 10) ?? 0
      }
      return 0
    }
    return 0
  }

  /// `getLongValue()`. Same in-place-mutation caveat as `getNumberValue()`.
  public func getLongValue() -> Int64 {
    if type == AssemblerToken.decNumber {
      return javaParseInt64(value) ?? 0
    } else if type == AssemblerToken.hexNumber {
      if value.uppercased().contains("X") {
        let split = javaSplitTrailingEmptyRemoved(value.uppercased(), on: "X")
        if split.count != 2 {
          isValid = false
          return 0
        }
        value = split[1]
      }
      return javaParseUnsignedInt64(value, radix: 16) ?? 0
    }
    return 0
  }
}

extension AssemblerToken: Hashable {
  public static func == (lhs: AssemblerToken, rhs: AssemblerToken) -> Bool { lhs === rhs }
  public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}
