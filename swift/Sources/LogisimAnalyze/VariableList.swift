//
//  VariableList.swift: part of logisim-evolved.
//
//  Derived from logisim-evolution, specifically
//  `src/main/java/com/cburch/logisim/analyze/model/VariableList.java`,
//  `.../VariableListEvent.java` and `.../VariableListListener.java`. GPL-3.0-only.
//  See LICENSE.md.
//

/// Java: `com.cburch.logisim.analyze.model.VariableListEvent`.
public struct VariableListEvent {
  /// Java: the five `VariableListEvent` int constants.
  public enum Kind: Int, Sendable {
    case allReplaced = 0
    case add = 1
    case remove = 2
    case move = 3
    case replace = 4
  }

  /// Java: `getSource()`. Weak; the listener is normally owned by the same `AnalyzerModel`
  /// that owns the list, and D3 says every back-edge in a cycle is weak.
  public weak var source: VariableList?
  public let type: Kind
  public let variable: Var?
  /// Java: `getIndex()`: for `MOVE` this is the *delta*, not an index.
  public let index: Int?
  /// Java: `getBitIndex()`, for `MOVE` this is the bit delta.
  public let bitIndex: Int?

  public init(
    source: VariableList?, type: Kind, variable: Var? = nil, index: Int? = nil,
    bitIndex: Int? = nil
  ) {
    self.source = source
    self.type = type
    self.variable = variable
    self.index = index
    self.bitIndex = bitIndex
  }
}

/// Java: `com.cburch.logisim.analyze.model.VariableListListener`.
public protocol VariableListListener: AnyObject {
  func listChanged(_ event: VariableListEvent)
}

/// Java: `com.cburch.logisim.analyze.model.VariableList`: the ordered inputs (or outputs) of
/// the analyzed circuit, kept in two parallel views: the `Var`s and their expanded bit names.
///
/// Listeners are held **weakly** (D3). Upstream holds them in a plain `ArrayList`, which under
/// ARC would pin `TruthTable` and `OutputExpressions`, both of which point back at the model
/// that owns this list, and leak the whole analyzer. The owner keeps its listeners alive;
/// this list does not.
public final class VariableList {
  private var listeners: [WeakListenerBox<AnyObject>] = []
  private let maxSize: Int
  private var data: [Var] = []
  private var names: [String] = []
  /// Java: `others`: companion lists consulted by `containsDuplicate`. Weak for the same
  /// reason as the listeners: inputs and outputs are companions of each other.
  private var others: [WeakListenerBox<VariableList>] = []

  public init(maxSize: Int) {
    self.maxSize = maxSize
  }

  /// Java: `vars`: the unmodifiable view of the variables.
  public var vars: [Var] { data }
  /// Java: `bits` / `getNames()`: one entry per bit, most significant first within each var.
  public var bits: [String] { names }
  /// Java: `getMaximumSize()`.
  public var maximumSize: Int { maxSize }

  /// Java: `addCompanion(VariableList)`.
  public func addCompanion(_ varList: VariableList) {
    others.append(WeakListenerBox(varList))
  }

  /// Java: `containsDuplicate(VariableList, Var, String)`; is `name` already taken by some
  /// variable other than `oldVar`, here or in a companion list?
  public func containsDuplicate(_ list: VariableList?, _ oldVar: Var?, _ name: String) -> Bool {
    var found = false
    for other in vars where !found {
      // Java compares `other != oldVar` by reference; `Var` is a value type here, so this is
      // structural. The two agree for every call site; `oldVar` is always an element of the
      // list, and a list never holds two equal `Var`s (equal name *and* width) anyway.
      if other != oldVar && name == other.name {
        found = true
        break
      }
    }
    for box in others where !found {
      guard let l = box.value else { continue }
      if l === list { continue }
      found = found || l.containsDuplicate(list, oldVar, name)
    }
    return found
  }

  /// Java: `add(Var)`.
  public func add(_ variable: Var) throws {
    if data.count + variable.width > maxSize {
      throw AnalyzeError.maximumSizeExceeded(maximum: maxSize)
    }
    let index = data.count
    data.append(variable)
    for bit in variable { names.append(bit) }
    let bitIndex = names.count - 1
    fireEvent(.add, variable, index, bitIndex)
  }

  /// Java: `move(Var, int)`.
  public func move(_ variable: Var, _ delta: Int) throws {
    guard let index = data.firstIndex(of: variable) else {
      throw AnalyzeError.noSuchVariable(variable.description)
    }
    guard let bitIndex = names.firstIndex(of: variable.bitName(0)) else {
      throw AnalyzeError.noSuchVariable(variable.description)
    }
    let newIndex = index + delta
    // Java raises two different messages here; see `AnalyzeError.cannotMove`.
    if newIndex < 0 {
      throw AnalyzeError.cannotMove(index: index, delta: delta, size: nil)
    }
    if newIndex > data.count - 1 {
      throw AnalyzeError.cannotMove(index: index, delta: delta, size: data.count)
    }
    if index == newIndex { return }
    data.remove(at: index)
    data.insert(variable, at: newIndex)
    names.removeSubrange((bitIndex + 1 - variable.width)...(bitIndex))
    var i = newIndex == 0 ? 0 : (1 + names.firstIndex(of: data[newIndex - 1].bitName(0))!)
    for bit in variable {
      names.insert(bit, at: i)
      i += 1
    }
    let bitDelta = names.firstIndex(of: variable.bitName(0))! - bitIndex
    // Java overloads the two fields here: `index` carries the delta and `bitIndex` the
    // bit delta. The TruthTable listener depends on it.
    fireEvent(.move, variable, delta, bitDelta)
  }

  /// Java: `remove(Var)`.
  public func remove(_ variable: Var) throws {
    guard let index = data.firstIndex(of: variable) else {
      throw AnalyzeError.noSuchVariable(variable.description)
    }
    guard let bitIndex = names.firstIndex(of: variable.bitName(0)) else {
      throw AnalyzeError.noSuchVariable(variable.description)
    }
    data.remove(at: index)
    names.removeSubrange((bitIndex + 1 - variable.width)...(bitIndex))
    fireEvent(.remove, variable, index, bitIndex)
  }

  /// Java: `replace(Var, Var)`.
  public func replace(_ oldVar: Var, _ newVar: Var) throws {
    guard let index = data.firstIndex(of: oldVar) else {
      throw AnalyzeError.noSuchVariable(oldVar.description)
    }
    guard let bitIndex = names.firstIndex(of: oldVar.bitName(0)) else {
      throw AnalyzeError.noSuchVariable(oldVar.description)
    }
    if oldVar == newVar { return }
    data[index] = newVar
    names.removeSubrange((bitIndex + 1 - oldVar.width)...(bitIndex))
    var i = bitIndex + 1 - oldVar.width
    for bit in newVar {
      names.insert(bit, at: i)
      i += 1
    }
    fireEvent(.replace, oldVar, index, bitIndex)
  }

  /// Java: `setAll(List<Var>)`.
  public func setAll(_ values: [Var]) throws {
    let total = values.reduce(0) { $0 + $1.width }
    if total > maxSize { throw AnalyzeError.maximumSizeExceeded(maximum: maxSize) }
    data = values
    names.removeAll()
    for variable in values {
      for bit in variable { names.append(bit) }
    }
    fireEvent(.allReplaced, nil, nil, nil)
  }

  // MARK: - Listeners

  public func addVariableListListener(_ l: VariableListListener) {
    listeners.append(WeakListenerBox(l))
  }

  public func removeVariableListListener(_ l: VariableListListener) {
    listeners.removeAll { $0.value === l || $0.value == nil }
  }

  private func fireEvent(_ type: VariableListEvent.Kind, _ variable: Var?, _ index: Int?, _ bitIndex: Int?) {
    listeners.removeAll { $0.value == nil }
    if listeners.isEmpty { return }
    let event = VariableListEvent(
      source: self, type: type, variable: variable, index: index, bitIndex: bitIndex)
    for box in listeners {
      (box.value as? VariableListListener)?.listChanged(event)
    }
  }
}

/// A weak reference in a value slot, so listener lists do not own their listeners (D3).
struct WeakListenerBox<T: AnyObject> {
  weak var value: T?
  init(_ value: T?) { self.value = value }
}
