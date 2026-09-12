// PlexersLibraryAttributes.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.plexers.PlexersLibrary: the attribute
// and constant declarations, and `contains`), https://github.com/logisim-evolution/logisim-evolution.
// Copyright by the Logisim-evolution developers. This translation is a derivative work and is
// therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// `drawTrapezoid` is D6/M6 and is not here. `PlexersLibrary` the `Library`, its tool list and
// `FactoryDescription`s, belongs to the library-registration workflow.

import Foundation
import LogisimKernel

/// The attributes and constants shared by Multiplexer, Demultiplexer, Decoder, PriorityEncoder
/// and BitSelector.
public enum PlexersLibraryAttributes {

  /// `SIZE_NARROW` / `SIZE_WIDE`: `new AttributeOption(Integer, …)`, so the `.circ` token is
  /// the number. Upstream's comment on WIDE: "30 for 2-to-1".
  public static let sizeNarrow = AttributeOption(value: Int32(20))
  public static let sizeWide = AttributeOption(value: Int32(40))

  /// `PlexersLibrary.ATTR_SIZE`. Note the `.circ` name is `size`, colliding with the gates'
  /// `ATTR_SIZE`; the two are different `Attribute` objects with different choice sets, and
  /// nothing resolves attributes by name across factories, so the collision is harmless: and
  /// is upstream's.
  public static let size: Attribute<AttributeOption> = Attributes.forOption(
    "size", choices: [sizeNarrow, sizeWide])

  /// `PlexersLibrary.ATTR_SELECT`: the number of select bits, 1…8.
  public static let select: Attribute<BitWidth> = Attributes.forBitWidth("select", min: 1, max: 8)
  /// `PlexersLibrary.DEFAULT_SELECT`.
  public static let defaultSelect = BitWidth.known(1)

  /// `PlexersLibrary.ATTR_TRISTATE` / `DEFAULT_TRISTATE`. Legacy: read by the `.circ` migration
  /// path only, no current component declares it.
  public static let tristate: Attribute<Bool> = Attributes.forBoolean("tristate")
  public static let defaultTristate = false

  /// `DISABLED_FLOATING` / `DISABLED_ZERO`.
  public static let disabledFloating = AttributeOption(value: "Z")
  public static let disabledZero = AttributeOption(value: "0")

  /// `PlexersLibrary.ATTR_DISABLED`: what a disabled plexer drives.
  public static let disabled: Attribute<AttributeOption> = Attributes.forOption(
    "disabled", choices: [disabledFloating, disabledZero])

  /// `PlexersLibrary.ATTR_ENABLE` / `DEFAULT_ENABLE`.
  public static let enable: Attribute<Bool> = Attributes.forBoolean("enable")
  public static let defaultEnable = false

  /// `PlexersLibrary.DELAY`.
  public static let delay = 3

  /// `PlexersLibrary.contains(Location, Bounds, Direction)`: the trapezoid hit test the whole
  /// family shares. The two 5-pixel corners on the sloped edge are excluded.
  public static func contains(_ loc: Location, _ bds: Bounds, _ facing: Direction) -> Bool {
    guard bds.contains(loc, 1) else { return false }
    let x = loc.x
    let y = loc.y
    let x0 = bds.x
    let x1 = x0 + bds.width
    let y0 = bds.y
    let y1 = y0 + bds.height
    if facing == .north || facing == .south {
      if x < x0 + 5 || x > x1 - 5 {
        return facing == .south ? y < y0 + 5 : y > y1 - 5
      }
      return true
    } else {
      if y < y0 + 5 || y > y1 - 5 {
        return facing == .east ? x < x0 + 5 : x > x1 - 5
      }
      return true
    }
  }
}
