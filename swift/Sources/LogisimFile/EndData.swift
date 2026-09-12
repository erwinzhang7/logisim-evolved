// EndData.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.comp.EndData),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.

import Foundation
import LogisimKernel

/// `EndData`'s `int i_o` field, whose three constants are a bit mask (`INPUT_ONLY = 1`,
/// `OUTPUT_ONLY = 2`, `INPUT_OUTPUT = 3`) tested with `&`.
///
/// Modelled as an `OptionSet` so the mask arithmetic is the same arithmetic, rather than an enum
/// that would have to re-derive `isInput`/`isOutput` by hand.
public struct EndType: OptionSet, Hashable, Sendable {
  public let rawValue: Int
  public init(rawValue: Int) { self.rawValue = rawValue }

  /// `EndData.INPUT_ONLY`.
  public static let inputOnly = EndType(rawValue: 1)
  /// `EndData.OUTPUT_ONLY`.
  public static let outputOnly = EndType(rawValue: 2)
  /// `EndData.INPUT_OUTPUT`.
  public static let inputOutput: EndType = [.inputOnly, .outputOnly]
}

/// `com.cburch.logisim.comp.EndData`: one connection point of a component.
///
/// **Deviation (deliberate).** Java overrides `equals` without overriding `hashCode`, so an
/// `EndData` hashes by identity while comparing by value; the classic unpaired-`equals` bug.
/// Nothing upstream uses `EndData` as a hash key (it appears only as a `HashMap` *value* in
/// `Circuit.MyComponentListener.toMap`), so the bug is unobservable, and this port simply does
/// not conform to `Hashable`. If a future milestone needs to hash one, it must decide
/// deliberately rather than inherit a synthesised conformance.
public struct EndData: Equatable, CustomStringConvertible, Sendable {
  public let location: Location
  public let width: BitWidth
  public let type: EndType
  public let isExclusive: Bool

  /// `EndData(Location, BitWidth, int)`: `exclusive` defaults to `type == OUTPUT_ONLY`, which
  /// is an exact equality against the constant, not a mask test: `INPUT_OUTPUT` is not exclusive.
  public init(location: Location, width: BitWidth, type: EndType) {
    self.init(
      location: location, width: width, type: type,
      isExclusive: type == EndType.outputOnly)
  }

  /// `EndData(Location, BitWidth, int, boolean)`.
  public init(location: Location, width: BitWidth, type: EndType, isExclusive: Bool) {
    self.location = location
    self.width = width
    self.type = type
    self.isExclusive = isExclusive
  }

  /// `isInput()`, `(i_o & INPUT_ONLY) != 0`.
  public var isInput: Bool { type.contains(.inputOnly) }

  /// `isOutput()`, `(i_o & OUTPUT_ONLY) != 0`.
  public var isOutput: Bool { type.contains(.outputOnly) }

  public var description: String {
    "EndData[\(location) \(width) type=\(type.rawValue) exclusive=\(isExclusive)]"
  }
}
