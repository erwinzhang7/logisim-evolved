// AttributeBridges: part of logisim-evolved.
//
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// `Attributes.swift` deliberately knows nothing about `BitWidth`, `Direction` or `Location`:
// its storage enum carries the *codec-level* payload (a width, a compass name, a coordinate
// pair) and the typed factories are generic over a bridging protocol. This file is the whole
// of the wiring between the two halves, so the attribute layer and the geometry/width value
// types can be ported, reviewed and changed independently.

import Foundation

/// `BitWidth.Attribute` produces `Attribute<BitWidth>`.
///
/// An out-of-range width in a `.circ` file is a parse failure, not a crash, so the range is
/// checked here and reported as `nil`. Because the guard has already established the range,
/// `known` is used rather than the throwing `create` (D13).
extension BitWidth: AttributeBitWidthRepresentable {
  public init?(attributeBitWidth width: Int32) {
    guard width >= 0, Int(width) <= BitWidth.maxWidth else { return nil }
    self = BitWidth.known(Int(width))
  }

  public var attributeBitWidth: Int32 { Int32(width) }
}

/// `Attributes.forDirection` produces `Attribute<Direction>`.
extension Direction: AttributeDirectionRepresentable {
  public init?(attributeDirection: AttributeValue.Direction) {
    switch attributeDirection {
    case .east: self = .east
    case .north: self = .north
    case .west: self = .west
    case .south: self = .south
    }
  }

  public var attributeDirection: AttributeValue.Direction {
    switch self {
    case .east: return .east
    case .north: return .north
    case .west: return .west
    case .south: return .south
    }
  }
}

/// `Attributes.forLocation` produces `Attribute<Location>`.
///
/// The initialiser snaps, because `Location.parse` always calls
/// `Location.create(x, y, hasToSnap: true)`: including its truncating `(v / 5) * 5`, which is
/// not round-to-nearest. See `Location.create` for why.
///
/// `Location` stores `Int`; Java stores `int`. The 32-bit narrowing on the way out truncates,
/// matching what Java would have done had the value ever exceeded 32 bits (it cannot: every
/// coordinate that reaches an attribute came from a 32-bit parse).
extension Location: AttributeLocationRepresentable {
  public init(attributeX: Int32, attributeY: Int32) {
    self = Location.create(Int(attributeX), Int(attributeY), hasToSnap: true)
  }

  public var attributeX: Int32 { Int32(truncatingIfNeeded: x) }
  public var attributeY: Int32 { Int32(truncatingIfNeeded: y) }
}
