// Direction.swift: part of logisim-evolved.
// Derived from logisim-evolution (com.cburch.logisim.data.Direction), GPL-3.0-only. See LICENSE.md.
//
// Java's `Direction` is a class with exactly four static singleton instances (EAST/NORTH/WEST/
// SOUTH); the natural Swift mapping is a `CaseIterable` enum backed by the same numeric `id`
// Java used (0=east, 1=north, 2=west, 3=south).
//
// Per docs/decisions.md D9, LogisimKernel must not reach into any localization/resource-bundle
// system: Java's `Direction` carries a `StringGetter` per direction resolved through
// `Strings.S` (an i18n bundle lookup), used by `toDisplayString()`/`toVerticalDisplayString()`.
// That is a UI-layer concern analogous to the `AppPreferences`/display-character reach-in this
// port avoids elsewhere. So this type does NOT resolve display text itself; instead it exposes
// the resource-bundle *keys* Java used (`displayKey`, `verticalDisplayKey`) so a UI layer can
// look them up in whatever localization system it has. `name` (the lowercase serialized form)
// and `parse` ARE preserved exactly, because those round-trip through `.circ` attribute values
// (e.g. `facing="east"`): that's a file-format concern, not a UI one.
//
// Java's `Direction implements AttributeOptionInterface` is not ported: that interface belongs
// to the attribute-editor UI (`getValue()` for populating an enumerated attribute's option list),
// which has no Swift counterpart yet and is out of scope for this geometry-only port.

import Foundation

/// One of the four cardinal directions a component or wire endpoint can face, analogous to
/// Java's `com.cburch.logisim.data.Direction`.
public enum Direction: Int, CaseIterable, Hashable, CustomStringConvertible, Sendable {
  case east = 0
  case north = 1
  case west = 2
  case south = 3

  /// Thrown by `Direction.parse`, mirroring the message Java's `NumberFormatException` carried.
  public struct ParseError: Error, CustomStringConvertible, Equatable {
    public let message: String
    public var description: String { message }
  }

  /// Parses Java's serialized direction name ("east", "north", "west", "south").
  public static func parse(_ str: String) throws -> Direction {
    switch str {
    case Direction.east.name: return .east
    case Direction.north.name: return .north
    case Direction.west.name: return .west
    case Direction.south.name: return .south
    default:
      throw ParseError(message: "illegal direction '\(str)'")
    }
  }

  /// Mirrors Java's `Direction.cardinals` array (`{EAST, NORTH, WEST, SOUTH}`, i.e. ascending id).
  public static let cardinals: [Direction] = [.east, .north, .west, .south]

  /// Java's private numeric `id`; identical to `rawValue`. Kept as a named accessor because it's
  /// what `getLeft`/`getRight`/`reverse`/`toDegrees`/`toRadians` are defined in terms of below,
  /// same as the Java source.
  public var id: Int { rawValue }

  /// The lowercase serialized name, matching Java's private `name` field and `toString()`. This
  /// is what round-trips through `.circ` attribute values.
  public var name: String {
    switch self {
    case .east: return "east"
    case .north: return "north"
    case .west: return "west"
    case .south: return "south"
    }
  }

  public func getLeft() -> Direction {
    return Direction.cardinals[(id + 1) % 4]
  }

  public func getRight() -> Direction {
    return Direction.cardinals[(id + 3) % 4]
  }

  public func reverse() -> Direction {
    return Direction.cardinals[(id + 2) % 4]
  }

  public func toDegrees() -> Int {
    return id * 90
  }

  public func toRadians() -> Double {
    return Double(id) * Double.pi / 2.0
  }

  /// Resource-bundle key Java resolved via `S.getter("direction<Name>Option")` for
  /// `toDisplayString()`. See the file header: the kernel names the key, a UI layer translates.
  public var displayKey: String {
    return "direction\(capitalizedName)Option"
  }

  /// Resource-bundle key Java resolved via `S.getter("direction<Name>Vertical")` for
  /// `toVerticalDisplayString()`. See the file header.
  public var verticalDisplayKey: String {
    return "direction\(capitalizedName)Vertical"
  }

  private var capitalizedName: String {
    switch self {
    case .east: return "East"
    case .north: return "North"
    case .west: return "West"
    case .south: return "South"
    }
  }

  /// Matches Java's `toString()`, which returns the raw serialized name (not a display string).
  public var description: String { name }
}
