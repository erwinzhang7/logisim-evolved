// Port.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.instance.Port),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── Deviations, all deliberate ──────────────────────────────────────────────────────────────
//
//   * **Value type.** Java's `Port` is a mutable class only because `setToolTip` exists; every
//     other field is final. `getPortIndex(Port)` therefore matches by *reference identity*
//     (`List.indexOf` on a class with no `equals`). The port makes `Port` a `struct` with
//     synthesised `Equatable`, so `portIndex(of:)` matches structurally. Upstream's identity
//     match and this structural match differ only if one component declares two ports with the
//     same `(dx, dy, type, width, exclusive)`, which would mean two connection points at the
//     same location; already invalid. The three call sites are `std/tcl` (D11: not ported),
//     `std/hdl` and `vhdl/base`.
//
//   * **No tool tip.** `Port.setToolTip(StringGetter)` carries a localised display string;
//     D5's precedent (`Attribute` keeps its raw name and nothing else) and D9 both put
//     localisation above the model. `InstanceComponent.hasToolTips` is likewise a paint/hover
//     concern. Bulk ports drop every `setToolTip` line; nothing about propagation reads them.
//
//   * **`Port.CLOCK`.** Upstream declares the string constant but never passes it to `toType`,
//     which would throw on it; it is used only as an HDL-generation marker. Not ported (D11).

import Foundation
import LogisimFile
import LogisimKernel

/// `Port.INPUT` / `Port.OUTPUT` / `Port.INOUT`.
///
/// Java passes these as `String`s through `toType(String)`, which throws
/// `IllegalArgumentException` on anything else. A Swift enum makes that unrepresentable, so the
/// throw disappears with no loss: no `.circ` file can reach it; the argument is always a
/// literal in component source.
public enum PortType: Equatable, Sendable {
  case input
  case output
  case inout_

  /// `Port.toType(String)`.
  public var endType: EndType {
    switch self {
    case .input: return .inputOnly
    case .output: return .outputOnly
    case .inout_: return .inputOutput
    }
  }

  /// `Port.defaultExclusive(String)`: OUTPUT is exclusive, INPUT and INOUT are shared.
  ///
  /// Note this is *not* the same rule as `EndData`'s own default (`type == OUTPUT_ONLY`):
  /// they happen to agree, but they are separate pieces of upstream code.
  public var defaultIsExclusive: Bool {
    switch self {
    case .output: return true
    case .input, .inout_: return false
    }
  }
}

/// Errors a port can raise while turning itself into an `EndData`.
public enum PortError: Error, Equatable, CustomStringConvertible, Sendable {
  /// `Port.toEnd`: `throw new IllegalArgumentException("Width attribute not set")`.
  ///
  /// Reachable from a `.circ` file, a component element that names a factory whose width
  /// attribute the set does not carry, so it throws rather than traps (D13).
  case widthAttributeNotSet(attribute: String)

  public var description: String {
    switch self {
    case .widthAttributeNotSet(let name):
      return "Width attribute not set: \(name)"
    }
  }
}

/// `com.cburch.logisim.instance.Port`: the declaration of one connection point, relative to
/// the component's location.
///
/// A `Port` is a *template*; `toEnd(location:attributes:)` turns it into the `EndData` the
/// netlist actually uses.
public struct Port: Equatable, CustomStringConvertible, Sendable {

  /// Java's `widthFixed` / `widthAttr` pair, exactly one of which is non-null.
  public enum Width: Equatable, @unchecked Sendable {
    /// `new Port(dx, dy, type, BitWidth)` and `new Port(dx, dy, type, int)`.
    case fixed(BitWidth)
    /// `new Port(dx, dy, type, Attribute<BitWidth>)`.
    case attribute(Attribute<BitWidth>)

    public static func == (lhs: Width, rhs: Width) -> Bool {
      switch (lhs, rhs) {
      case (.fixed(let a), .fixed(let b)): return a == b
      case (.attribute(let a), .attribute(let b)): return a === b
      default: return false
      }
    }
  }

  public let dx: Int
  public let dy: Int
  public let type: PortType
  public let width: Width
  /// Java's `exclude`.
  public let isExclusive: Bool

  // MARK: Constructors, one per upstream overload

  /// `Port(int dx, int dy, String type, Attribute<BitWidth> attr[, String exclude])`.
  public init(
    _ dx: Int, _ dy: Int, _ type: PortType, _ attribute: Attribute<BitWidth>,
    exclusive: Bool? = nil
  ) {
    self.dx = dx
    self.dy = dy
    self.type = type
    self.width = .attribute(attribute)
    self.isExclusive = exclusive ?? type.defaultIsExclusive
  }

  /// `Port(int dx, int dy, String type, BitWidth bits[, String exclude])`.
  public init(
    _ dx: Int, _ dy: Int, _ type: PortType, _ bits: BitWidth, exclusive: Bool? = nil
  ) {
    self.dx = dx
    self.dy = dy
    self.type = type
    self.width = .fixed(bits)
    self.isExclusive = exclusive ?? type.defaultIsExclusive
  }

  /// `Port(int dx, int dy, String type, int bits[, String exclude])`.
  ///
  /// Java calls `BitWidth.create(bits)`, which throws for a width outside `0…64`. Every one of
  /// the ~600 upstream call sites passes a literal (`1`, `8`, `32`), so this uses the
  /// non-throwing `BitWidth.known`: D13's "literal, cannot fail on user input" carve-out.
  public init(_ dx: Int, _ dy: Int, _ type: PortType, _ bits: Int, exclusive: Bool? = nil) {
    self.init(dx, dy, type, BitWidth.known(bits), exclusive: exclusive)
  }

  // MARK: Queries

  /// `getFixedBitWidth()`; `BitWidth.UNKNOWN` when the width comes from an attribute.
  public var fixedBitWidth: BitWidth {
    if case .fixed(let bits) = width { return bits }
    return BitWidth.unknown
  }

  /// `getWidthAttribute()`.
  public var widthAttribute: Attribute<BitWidth>? {
    if case .attribute(let attribute) = width { return attribute }
    return nil
  }

  /// `toEnd(Location, AttributeSet)`.
  public func toEnd(location: Location, attributes: any AttributeSet) throws -> EndData {
    let point = location.translate(dx, dy)
    switch width {
    case .fixed(let bits):
      return EndData(location: point, width: bits, type: type.endType, isExclusive: isExclusive)
    case .attribute(let attribute):
      guard let bits = attributes.getValue(attribute) else {
        throw PortError.widthAttributeNotSet(attribute: attribute.name)
      }
      return EndData(location: point, width: bits, type: type.endType, isExclusive: isExclusive)
    }
  }

  public var description: String {
    "Port[\(dx),\(dy) \(type) exclusive=\(isExclusive)]"
  }
}
