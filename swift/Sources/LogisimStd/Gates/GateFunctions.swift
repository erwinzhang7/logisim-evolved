// GateFunctions.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.gates.GateFunctions),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// Every function takes `(inputs, numInputs)` because upstream's caller allocates an array sized
// to the *declared* input count and fills only the *connected* prefix; the tail is null. The
// port keeps the pair rather than slicing, so a transcription reads identically.

import Foundation
import LogisimKernel

public enum GateFunctions {

  /// `computeAnd`.
  public static func computeAnd(_ inputs: [Value], _ numInputs: Int) -> Value {
    var result = inputs[0]
    for i in 1..<max(numInputs, 1) {
      result = result.and(inputs[i])
    }
    return result
  }

  /// `computeOr`.
  public static func computeOr(_ inputs: [Value], _ numInputs: Int) -> Value {
    var result = inputs[0]
    for i in 1..<max(numInputs, 1) {
      result = result.or(inputs[i])
    }
    return result
  }

  /// `computeOddParity`.
  public static func computeOddParity(_ inputs: [Value], _ numInputs: Int) -> Value {
    var result = inputs[0]
    for i in 1..<max(numInputs, 1) {
      result = result.xor(inputs[i])
    }
    return result
  }

  /// `computeExactlyOne`.
  ///
  /// D13: `Value.create([Value])` throws where Java's does (more than 64 bits), so this throws.
  public static func computeExactlyOne(_ inputs: [Value], _ numInputs: Int) throws -> Value {
    let width = inputs[0].getWidth()
    var result = [Value]()
    result.reserveCapacity(max(width, 0))
    for i in 0..<max(width, 0) {
      var count = 0
      for j in 0..<numInputs {
        let v = inputs[j].get(i)
        if v == .trueValue {
          count += 1
        } else if v == .falseValue {
          // do nothing
        } else {
          count = -1
          break
        }
      }
      if count < 0 {
        result.append(.errorValue)
      } else if count == 1 {
        result.append(.trueValue)
      } else {
        result.append(.falseValue)
      }
    }
    return try Value.create(result)
  }
}
