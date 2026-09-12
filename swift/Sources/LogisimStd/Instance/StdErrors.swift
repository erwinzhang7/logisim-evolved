// StdErrors.swift: part of logisim-evolved.
//
// Part of the logisim-evolution port (GPL-3.0-only, see LICENSE.md).
//
// D13: a catchable Java exception becomes a Swift `throw`. These are the two `RuntimeException`
// shapes component code raises that the kernel's own error enums do not already cover.

import Foundation

public enum ComponentError: Error, Equatable, CustomStringConvertible, Sendable {

  /// A hand-written `AbstractAttributeSet` was handed a value of a kind it does not store:
  /// upstream's `ClassCastException` inside `setValue`. Reachable from a `.circ` file whose
  /// `<a name= val=>` parses to the wrong storage case.
  case unsupportedAttributeValue(factory: String, attribute: String)

  /// A factory that requires its own attribute-set subclass was given a different one:
  /// upstream's `(GateAttributes) state.getAttributeSet()` throwing `ClassCastException`.
  /// Reachable when a `.circ` repair pass retargets a component at a foreign factory.
  case wrongAttributeSet(factory: String)

  public var description: String {
    switch self {
    case .unsupportedAttributeValue(let factory, let attribute):
      return "\(factory): unsupported value for attribute '\(attribute)'"
    case .wrongAttributeSet(let factory):
      return "\(factory): component does not carry this factory's attribute set"
    }
  }
}
