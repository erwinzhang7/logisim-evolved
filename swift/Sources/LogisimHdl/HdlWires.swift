// HdlWires: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// `com/cburch/logisim/fpga/hdlgenerator/HdlWires.java`. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore licensed GPL-3.0-only.
// See LICENSE.md.
//
// The internal signal declarations (`wire`/`reg` in Verilog, unqualified signals in VHDL) a
// generator's module body needs, keyed by name.

/// `com.cburch.logisim.fpga.hdlgenerator.HdlWires`.
public final class HdlWires {
  private enum Kind: Equatable {
    case wire
    case register
  }

  private struct Wire {
    let kind: Kind
    let name: String
    let nrOfBits: Int
  }

  private var wires: [Wire] = []

  public init() {}

  @discardableResult
  public func addWire(_ name: String, _ nrOfBits: Int) -> HdlWires {
    wires.append(Wire(kind: .wire, name: name, nrOfBits: nrOfBits))
    return self
  }

  @discardableResult
  public func addRegister(_ name: String, _ nrOfBits: Int) -> HdlWires {
    wires.append(Wire(kind: .register, name: name, nrOfBits: nrOfBits))
    return self
  }

  @discardableResult
  public func addAllWires(_ newWires: [String: Int]) -> HdlWires {
    for (name, nrOfBits) in newWires {
      wires.append(Wire(kind: .wire, name: name, nrOfBits: nrOfBits))
    }
    return self
  }

  public func wireKeySet() -> [String] {
    wires.filter { $0.kind == .wire }.map(\.name)
  }

  public func registerKeySet() -> [String] {
    wires.filter { $0.kind == .register }.map(\.name)
  }

  /// `HdlWires.get(String)`.
  ///
  /// A generator asking about a wire it never declared is a bug in that generator's own
  /// construction code, not something a `.circ` file can trigger; traps rather than throws
  /// (D13).
  public func get(_ wireName: String) -> Int {
    guard let wire = wires.first(where: { $0.name == wireName }) else {
      preconditionFailure("Wire or register '\(wireName)' not contained in structure")
    }
    return wire.nrOfBits
  }

  public func removeWires() {
    wires.removeAll()
  }
}
