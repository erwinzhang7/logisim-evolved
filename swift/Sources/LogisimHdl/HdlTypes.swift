// HdlTypes: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// `com/cburch/logisim/fpga/hdlgenerator/HdlTypes.java`. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore licensed GPL-3.0-only.
// See LICENSE.md.
//
// Named enum/array types a generator's module body can declare (VHDL `type ... is (...)` /
// Verilog `typedef enum`, and their array equivalents), plus the wires that use them.

/// `com.cburch.logisim.fpga.hdlgenerator.HdlTypes`.
public final class HdlTypes {
  private protocol HdlType {
    func typeDefinition() -> String
    var typeName: String { get }
  }

  private final class HdlEnum: HdlType {
    private var entries: [String] = []
    let typeName: String

    init(_ name: String) { typeName = name }

    /// `HdlEnum.add(String)`: insertion-sorted, matching Java's manual insertion loop.
    func add(_ entry: String) {
      for index in entries.indices where entries[index] > entry {
        entries.insert(entry, at: index)
        return
      }
      entries.append(entry)
    }

    func typeDefinition() -> String {
      var contents = ""
      if Hdl.isVhdl() {
        contents += LineBuffer.formatVhdl("{{type}} {{1}} {{is}} (", typeName)
      } else {
        contents += "typedef enum { "
      }
      contents += entries.joined(separator: ", ")
      contents += Hdl.isVhdl() ? ");" : "} \(typeName);"
      return contents
    }
  }

  private final class HdlArray: HdlType {
    let typeName: String
    private let genericBitWidth: String?
    private let bitWidth: Int
    private let nrOfEntries: Int

    init(name: String, genericBitWidth: String, nrOfEntries: Int) {
      typeName = name
      self.genericBitWidth = genericBitWidth
      bitWidth = -1
      self.nrOfEntries = nrOfEntries
    }

    init(name: String, nrOfBits: Int, nrOfEntries: Int) {
      typeName = name
      genericBitWidth = nil
      bitWidth = nrOfBits
      self.nrOfEntries = nrOfEntries
    }

    func typeDefinition() -> String {
      var contents = ""
      if Hdl.isVhdl() {
        contents += LineBuffer.formatVhdl(
          "{{type}} {{1}} {{is}} {{array}} ( {{2}} {{downto}} 0 ) {{of}} ", typeName, nrOfEntries)
        if genericBitWidth == nil && bitWidth == 1 {
          contents += "std_logic;"
        } else {
          contents += "std_logic_vector( "
          contents += genericBitWidth == nil ? "\(bitWidth - 1)" : "\(genericBitWidth!) - 1"
          // Important: the leading space is required, matching upstream.
          contents += LineBuffer.formatVhdl(" {{downto}} 0);")
        }
      } else {
        contents += "typedef logic ["
        contents += genericBitWidth == nil ? "\(bitWidth - 1)" : "\(genericBitWidth!) - 1"
        contents += ":0] \(typeName) [\(nrOfEntries):0];"
      }
      return contents
    }
  }

  private var types: [Int: HdlType] = [:]
  private var wires: [String: Int] = [:]

  /// The identifiers in the order they were first `put`, which is what `typeDefinitions()`
  /// needs to reproduce `java.util.HashMap`'s iteration order. Java's `put` on an existing key
  /// replaces the value and leaves the entry where it is, so a re-`put` must not re-append.
  private var typeInsertionOrder: [Int] = []

  public init() {}

  private func rememberType(_ identifier: Int) {
    if types[identifier] == nil { typeInsertionOrder.append(identifier) }
  }

  @discardableResult
  public func addEnum(_ identifier: Int, _ name: String) -> HdlTypes {
    rememberType(identifier)
    types[identifier] = HdlEnum(name)
    return self
  }

  /// A generator adding an entry to an enum it never declared is a construction-time bug in
  /// that generator, not something a `.circ` file reaches: traps (D13).
  @discardableResult
  public func addEnumEntry(_ identifier: Int, _ entry: String) -> HdlTypes {
    guard let hdlEnum = types[identifier] as? HdlEnum else {
      preconditionFailure("Enum type not contained in array")
    }
    hdlEnum.add(entry)
    return self
  }

  @discardableResult
  public func addArray(
    _ identifier: Int, _ name: String, genericBitWidth: String, nrOfEntries: Int
  ) -> HdlTypes {
    rememberType(identifier)
    types[identifier] = HdlArray(name: name, genericBitWidth: genericBitWidth, nrOfEntries: nrOfEntries)
    return self
  }

  @discardableResult
  public func addArray(_ identifier: Int, _ name: String, nrOfBits: Int, nrOfEntries: Int)
    -> HdlTypes
  {
    rememberType(identifier)
    types[identifier] = HdlArray(name: name, nrOfBits: nrOfBits, nrOfEntries: nrOfEntries)
    return self
  }

  @discardableResult
  public func addWire(_ name: String, typeIdentifier: Int) -> HdlTypes {
    wires[name] = typeIdentifier
    return self
  }

  public var nrOfTypes: Int { types.count }

  /// `HdlTypes.getTypeDefinitions()`.
  ///
  /// Java iterates `myTypes.keySet()` on a `HashMap<Integer, HdlType>`, so the emitted order is
  /// **bucket order**, not insertion or sorted order. Iterating a Swift `Dictionary` instead is
  /// not merely a different fixed order; it is arbitrary, and observed to differ between two
  /// otherwise identical cases in one run, which is why the memory suite had to compare these
  /// lines as a sorted set rather than a sequence.
  ///
  /// `Integer.hashCode()` is the value itself, and every caller in the tree uses small negative
  /// identifiers, so for the ids -1, -2, -3 this lands in buckets 0, 1, 2 and the order is
  /// deterministically -1, -2, -3. `JavaHashSet.order` computes that rather than hard-coding it,
  /// so an identifier outside that set still orders correctly.
  ///
  /// Reached only by RAM with byte enables at a data width that is neither <= 8 nor a multiple
  /// of 8, which is exactly why an arbitrary order survived this long.
  public func typeDefinitions() -> [String] {
    let defs = LineBuffer.getHdlBuffer()
    for identifier in JavaHashSet.order(typeInsertionOrder, hashCode: { $0 }) {
      guard let type = types[identifier] else { continue }
      defs.add(type.typeDefinition())
    }
    return defs.getWithIndent()
  }

  /// A wire declared against a type identifier that was never registered is a
  /// construction-time bug in the generator: traps (D13).
  public func getTypedWires() -> [String: String] {
    var contents: [String: String] = [:]
    for (wire, typeId) in wires {
      guard let type = types[typeId] else {
        preconditionFailure("Enum or array type not contained in array")
      }
      contents[wire] = type.typeName
    }
    return contents
  }

  public func clear() {
    types.removeAll()
    wires.removeAll()
    typeInsertionOrder.removeAll()
  }
}
