// HdlPorts: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// `com/cburch/logisim/fpga/hdlgenerator/HdlPorts.java`. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore licensed GPL-3.0-only.
// See LICENSE.md.
//
// The entity/module port list a generator declares, keyed by name: direction, width (fixed,
// generic-parameter, or "one bit unless the component attribute says otherwise"), and how it
// wires up: to a component pin, to a fixed constant, or to the global clock tree.
//
// `HdlPortDirection` replaces Java's `com.cburch.logisim.instance.Port.INPUT`/`OUTPUT`/
// `INOUT`/`CLOCK` string constants (that type is owned by a module this task does not touch);
// the raw values match Java's exactly, so a future `Port` bridges in with a one-line mapping.

import LogisimKernel

/// `com.cburch.logisim.instance.Port`'s direction constants, as this module needs them.
public enum HdlPortDirection: String, Hashable, Sendable {
  case input = "input"
  case output = "output"
  case inout_ = "inout"
  /// Not a distinct HDL direction; `HdlPorts.add` folds this to `.input` and sets the port's
  /// `isClock` flag, exactly as upstream's `PortInfo` does.
  case clock = "clock"
}

/// `com.cburch.logisim.fpga.hdlgenerator.HdlPorts`.
public final class HdlPorts {
  public static let clock = "clock"
  public static let tick = "tick"
  public static let pullDown = "fixed_pull_down"
  public static let pullUp = "fixed_pull_up"

  private struct PortInfo {
    let portType: HdlPortDirection
    let name: String
    let nrOfBits: Int
    /// `-1` for a fixed-mapped port, matching upstream's sentinel.
    let componentPinId: Int
    let fixedMap: String?
    let singlePinException: Bool
    let bitWidthAttribute: AnyAttribute?
    let pullToZero: Bool
    var isClock: Bool = false
  }

  private var ports: [PortInfo] = []

  public init() {}

  @discardableResult
  public func add(_ type: HdlPortDirection, _ name: String, nrOfBits: Int, fixedMap: String)
    -> HdlPorts
  {
    let realType: HdlPortDirection = type == .clock ? .input : type
    var port = PortInfo(
      portType: realType, name: name, nrOfBits: nrOfBits, componentPinId: -1, fixedMap: fixedMap,
      singlePinException: false, bitWidthAttribute: nil, pullToZero: true)
    port.isClock = type == .clock
    ports.append(port)
    return self
  }

  @discardableResult
  public func add(_ type: HdlPortDirection, _ name: String, nrOfBits: Int, componentPinId: Int)
    -> HdlPorts
  {
    let realType: HdlPortDirection = type == .clock ? .input : type
    var port = PortInfo(
      portType: realType, name: name, nrOfBits: nrOfBits, componentPinId: componentPinId,
      fixedMap: nil, singlePinException: false, bitWidthAttribute: nil, pullToZero: true)
    port.isClock = type == .clock
    ports.append(port)
    return self
  }

  @discardableResult
  public func add(
    _ type: HdlPortDirection, _ name: String, nrOfBits: Int, componentPinId: Int, pullToZero: Bool
  ) -> HdlPorts {
    let realType: HdlPortDirection = type == .clock ? .input : type
    var port = PortInfo(
      portType: realType, name: name, nrOfBits: nrOfBits, componentPinId: componentPinId,
      fixedMap: nil, singlePinException: false, bitWidthAttribute: nil, pullToZero: pullToZero)
    port.isClock = type == .clock
    ports.append(port)
    return self
  }

  @discardableResult
  public func add(
    _ type: HdlPortDirection, _ name: String, nrOfBits: Int, componentPinId: Int,
    bitWidthAttribute: AnyAttribute
  ) -> HdlPorts {
    let realType: HdlPortDirection = type == .clock ? .input : type
    var port = PortInfo(
      portType: realType, name: name, nrOfBits: nrOfBits, componentPinId: componentPinId,
      fixedMap: nil, singlePinException: true, bitWidthAttribute: bitWidthAttribute,
      pullToZero: true)
    port.isClock = type == .clock
    ports.append(port)
    return self
  }

  public var isEmpty: Bool { ports.isEmpty }

  public func keySet() -> [String] { keySet(nil) }

  public func keySet(_ type: HdlPortDirection?) -> [String] {
    ports.filter { type == nil || $0.portType == type }.map(\.name)
  }

  /// A generator asking about a port name it never declared, or an attribute-driven port whose
  /// declared attribute is absent from the actual component, is a construction-time bug in that
  /// generator, not something a `.circ` file can trigger, so both trap (D13).
  public func get(_ name: String, attrs: any AttributeSet) -> Int {
    guard let port = ports.first(where: { $0.name == name }) else {
      preconditionFailure("port '\(name)' not contained in structure")
    }
    return nrOfBits(for: port, attrs: attrs)
  }

  private func nrOfBits(for port: PortInfo, attrs: any AttributeSet) -> Int {
    guard port.singlePinException else { return port.nrOfBits }
    guard let attribute = port.bitWidthAttribute, attrs.containsAttribute(attribute) else {
      preconditionFailure("Bitwidth attribute not found")
    }
    let nrOfBits: Int
    switch attrs.rawValue(attribute) {
    case .bitWidth(let width): nrOfBits = Int(width)
    case .integer(let value): nrOfBits = Int(value)
    default:
      preconditionFailure("Attribute is not of type Bitwidth or Integer")
    }
    return nrOfBits == 1 ? 1 : (port.nrOfBits != 0 ? port.nrOfBits : nrOfBits)
  }

  public func isFixedMapped(_ name: String) -> Bool {
    guard let port = ports.first(where: { $0.name == name }) else {
      preconditionFailure("port '\(name)' not contained in structure")
    }
    return port.componentPinId < 0
  }

  public func getFixedMap(_ name: String) -> String {
    guard let port = ports.first(where: { $0.name == name }), port.componentPinId < 0,
      let fixedMap = port.fixedMap
    else {
      preconditionFailure("port '\(name)' not contained in structure or not fixed mapped")
    }
    return fixedMap
  }

  public func getComponentPortId(_ name: String) -> Int {
    guard let port = ports.first(where: { $0.name == name }) else {
      preconditionFailure("port '\(name)' not contained in structure")
    }
    return port.componentPinId
  }

  public func removePorts() {
    ports.removeAll()
  }

  public func doPullDownOnFloat(_ name: String) -> Bool {
    guard let port = ports.first(where: { $0.name == name }) else {
      preconditionFailure("port '\(name)' not contained in structure")
    }
    return port.pullToZero
  }

  public func contains(_ name: String) -> Bool {
    ports.contains { $0.name == name }
  }

  public func isClock(_ name: String) -> Bool {
    guard let port = ports.first(where: { $0.name == name }) else {
      preconditionFailure("port '\(name)' not contained in structure")
    }
    return port.isClock
  }

  public func getTickName(_ name: String) -> String {
    guard let port = ports.first(where: { $0.name == name }) else {
      preconditionFailure("port '\(name)' not contained in structure")
    }
    return Self.getTickName(port.nrOfBits)
  }

  public static func getTickName(_ id: Int) -> String { id == 1 ? tick : "\(tick)\(id)" }
  public static func getClockName(_ id: Int) -> String { id == 1 ? clock : "\(clock)\(id)" }
}
