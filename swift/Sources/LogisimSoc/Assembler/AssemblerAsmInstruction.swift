// AssemblerAsmInstruction.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.soc.util.AssemblerAsmInstruction),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// One assembled source-line instruction: its opcode token, its raw parameter token groups
// (still needing label/define/pc resolution), and, once resolved, its emitted bytes. `Byte[]`
// (nullable boxed array) becomes `[UInt8]?`.
public final class AssemblerAsmInstruction {
  private let instructionToken: AssemblerToken
  private var parameters: [[AssemblerToken]] = []
  private let size: Int
  private var errors: [AssemblerToken: AssemblerMessage] = [:]
  private var bytes: [UInt8]?
  private var programCounter: Int64 = -1

  public init(instruction: AssemblerToken, size: Int) {
    self.instructionToken = instruction
    self.size = size
  }

  public var opcode: String { instructionToken.value }
  public var instruction: AssemblerToken { instructionToken }
  public var numberOfParameters: Int { parameters.count }

  public func addParameter(_ param: [AssemblerToken]) { parameters.append(param) }

  public var sizeInBytes: Int { size }

  public var hasErrors: Bool { !errors.isEmpty }

  public func setError(_ token: AssemblerToken, _ message: AssemblerMessage) {
    errors[token] = message
  }

  public func getErrors() -> [AssemblerToken: AssemblerMessage] { errors }

  public func getBytes() -> [UInt8]? { bytes }

  public func setProgramCounter(_ value: Int64) { programCounter = value }
  public func getProgramCounter() -> Int64 { programCounter }

  /// `setInstructionByteCode(int, int)`.
  public func setInstructionByteCode(_ value: Int, nrOfBytes: Int) {
    var b = bytes ?? [UInt8](repeating: 0, count: size)
    for i in 0..<nrOfBytes where i < size {
      b[i] = UInt8(truncatingIfNeeded: value >> (i * 8))
    }
    bytes = b
  }

  /// `setInstructionByteCode(int[], int)`; used for multi-word pseudo-instructions (e.g.
  /// `movia`, which expands to two 32-bit instructions).
  public func setInstructionByteCode(_ values: [Int], nrOfBytes: Int) {
    var b = bytes ?? [UInt8](repeating: 0, count: size)
    for j in 0..<values.count {
      for i in 0..<nrOfBytes where i < size {
        let idx = j * nrOfBytes + i
        if idx < b.count {
          b[idx] = UInt8(truncatingIfNeeded: values[j] >> (i * 8))
        }
      }
    }
    bytes = b
  }

  public func getParameter(_ index: Int) -> [AssemblerToken]? {
    guard index >= 0, index < parameters.count else { return nil }
    return parameters[index]
  }

  /// `replaceLabels`.
  public func replaceLabels(
    _ labels: [String: Int64], _ errors: inout [AssemblerToken: AssemblerMessage]
  ) -> Bool {
    for parameter in parameters {
      for token in parameter where token.type == AssemblerToken.parameterLabel {
        let name = token.value
        guard let addr = labels[name] else {
          errors[token] = .assemblerCouldNotFindAddressForLabel
          return false
        }
        token.setType(AssemblerToken.hexNumber)
        token.setValue(String(format: "0x%08X", addr))
      }
    }
    return true
  }

  /// `replaceDefines`.
  public func replaceDefines(
    _ defines: [String: Int], _ errors: inout [AssemblerToken: AssemblerMessage]
  ) -> Bool {
    for parameter in parameters {
      for token in parameter where token.type == AssemblerToken.maybeLabel {
        let name = token.value
        guard let value = defines[name] else {
          errors[token] = .assemblerCouldNotFindValueForDefine
          return false
        }
        token.setType(AssemblerToken.hexNumber)
        token.setValue(String(format: "0x%08X", value))
      }
    }
    return true
  }

  /// `replacePcAndDoCalc`. The math folding here is deliberately left-to-right and re-derives
  /// the same limited operator set `Assembler.assemble()`'s fourth pass handles for the
  /// non-pc-relative case; see that file for the "why left-to-right" note.
  public func replacePcAndDoCalc(_ pc: Int64, _ errors: inout [AssemblerToken: AssemblerMessage]) {
    for idx in 0..<parameters.count {
      var parameter = parameters[idx]
      var found = false
      for token in parameter where token.type == AssemblerToken.programCounter {
        found = true
        token.setType(AssemblerToken.hexNumber)
        token.setValue(String(format: "0x%08X", pc))
      }
      if found && parameter.count > 1 {
        var i = 0
        var toBeRemoved = Set<Int>()
        while i < parameter.count {
          if AssemblerToken.mathOperators.contains(parameter[i].type) {
            var beforeValue: Int64 = -1
            if i == 0 || !parameter[i - 1].isNumber {
              beforeValue = 0
            } else if i + 1 >= parameter.count || !parameter[i + 1].isNumber {
              errors[parameter[i]] = .assemblerExpectedImmediateValueAfterMath
            } else {
              if beforeValue < 0 {
                toBeRemoved.insert(i - 1)
                beforeValue = parameter[i - 1].getLongValue()
              }
              let afterValue = parameter[i + 1].getLongValue()
              toBeRemoved.insert(i)
              var result: Int64 = 0
              switch parameter[i].type {
              case AssemblerToken.mathAdd: result = beforeValue &+ afterValue
              case AssemblerToken.mathSubtract: result = beforeValue &- afterValue
              case AssemblerToken.mathShiftLeft: result = beforeValue << (afterValue & 63)
              case AssemblerToken.mathShiftRight: result = beforeValue >> (afterValue & 63)
              case AssemblerToken.mathMul: result = beforeValue &* afterValue
              case AssemblerToken.mathDiv:
                if afterValue == 0 { errors[parameter[i + 1]] = .assemblerDivZero }
                else { result = beforeValue / afterValue }
              case AssemblerToken.mathRem:
                if afterValue == 0 { errors[parameter[i + 1]] = .assemblerDivZero }
                else { result = beforeValue % afterValue }
              default: break
              }
              parameter[i + 1].setType(AssemblerToken.hexNumber)
              parameter[i + 1].setValue(String(format: "0x%X", result))
            }
          }
          i += 1
        }
        var newParameter: [AssemblerToken] = []
        for i in 0..<parameter.count where !toBeRemoved.contains(i) {
          newParameter.append(parameter[i])
        }
        parameters[idx] = newParameter
      }
    }
  }
}
