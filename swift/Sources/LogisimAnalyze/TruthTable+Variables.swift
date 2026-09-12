//
//  TruthTable+Variables.swift: part of logisim-evolved.
//
//  Derived from logisim-evolution, specifically `TruthTable.MyListener` in
//  `src/main/java/com/cburch/logisim/analyze/model/TruthTable.java`. GPL-3.0-only.
//  See LICENSE.md.
//
//  Adding, removing, moving or resizing a variable reshapes both the visible row partition
//  and every allocated output column. Java does it with bit-twiddling on the row indices
//  rather than by recomputing the table, and that is worth keeping: at MAX_INPUTS = 20 a
//  column is a million cells and the difference is an index remap versus a re-evaluation.
//

extension TruthTable: VariableListListener {
  /// Java: `MyListener.listChanged(VariableListEvent)`.
  public func listChanged(_ event: VariableListEvent) {
    if event.source === model.inputs {
      inputsChanged(event)
      for col in columns.indices {
        guard let column = columns[col] else { continue }
        columns[col] = inputsChangedForOutput(column, event)
      }
      fireRowsChanged()
    } else {
      outputsChanged(event)
    }
    fireStructureChanged(event)
  }

  /// Java: `MyListener.outputsChanged(VariableListEvent)`.
  private func outputsChanged(_ event: VariableListEvent) {
    let action = event.type
    if action == .allReplaced {
      initColumns()
      return
    }
    guard let v = event.variable else { return }
    switch action {
    case .add:
      guard let bitIndex = event.bitIndex else { return }
      for b in stride(from: v.width - 1, through: 0, by: -1) {
        columns.insert(nil, at: bitIndex - b)  // lazily created
      }
    case .move:
      guard let delta = event.bitIndex else { return }
      let newIndex = outputIndex(of: v.bitName(0))
      if delta > 0 {
        for b in 0..<v.width {
          let column = columns.remove(at: newIndex - delta - b)
          columns.insert(column, at: newIndex - b)
        }
      } else if delta < 0 {
        for b in stride(from: v.width - 1, through: 0, by: -1) {
          let column = columns.remove(at: newIndex - delta - b)
          columns.insert(column, at: newIndex - b)
        }
      }
    case .remove:
      guard let bitIndex = event.bitIndex else { return }
      for b in 0..<v.width { columns.remove(at: bitIndex - b) }
    case .replace:
      guard let bitIndex = event.bitIndex, let index = event.index else { return }
      let newVar = outputVariable(index)
      var lost = v.width - newVar.width
      let pos = bitIndex + 1 - v.width
      while lost > 0 {
        columns.remove(at: pos)
        lost -= 1
      }
      while lost < 0 {
        columns.insert(nil, at: pos)  // lazily created
        lost += 1
      }
    case .allReplaced:
      break
    }
  }

  /// Java: `MyListener.inputsChanged(VariableListEvent)`.
  private func inputsChanged(_ event: VariableListEvent) {
    let action = event.type
    if action == .allReplaced {
      initRows()
      return
    }
    guard let v = event.variable else { return }
    switch action {
    case .add:
      guard let bitIndex = event.bitIndex else { return }
      var oldCount = inputColumnCount - v.width
      for b in stride(from: v.width - 1, through: 0, by: -1) {
        addInput(bitIndex - b, oldCount)
        oldCount += 1
      }
    case .remove:
      guard let bitIndex = event.bitIndex else { return }
      var oldCount = inputColumnCount + v.width
      for b in 0..<v.width {
        removeInput(bitIndex - b, oldCount)
        oldCount -= 1
      }
    case .move:
      guard let delta = event.bitIndex else { return }
      let newIndex = inputIndex(of: v.bitName(0))
      if delta > 0 {
        for b in 0..<v.width { moveInput(newIndex - delta - b, newIndex - b) }
      } else if delta < 0 {
        for b in stride(from: v.width - 1, through: 0, by: -1) {
          moveInput(newIndex - delta - b, newIndex - b)
        }
      }
    case .replace:
      guard let bitIndex = event.bitIndex, let index = event.index else { return }
      let newVar = inputVariable(index)
      var lost = v.width - newVar.width
      var oldCount = inputColumnCount + lost
      let pos = bitIndex + 1 - v.width
      while lost > 0 {
        removeInput(pos, oldCount)
        oldCount -= 1
        lost -= 1
      }
      while lost < 0 {
        addInput(pos, oldCount)
        oldCount += 1
        lost += 1
      }
    case .allReplaced:
      break
    }
  }

  /// Java: `MyListener.moveInput(int, int)`.
  private func moveInput(_ oldIndexIn: Int, _ newIndexIn: Int) {
    let inputs = inputColumnCount
    let oldIndex = inputs - 1 - oldIndexIn
    let newIndex = inputs - 1 - newIndexIn
    let allMask = (1 << inputs) - 1
    let sameMask =
      allMask
      ^ ((1 << (1 + Swift.max(oldIndex, newIndex))) - 1)
      ^ ((1 << Swift.min(oldIndex, newIndex)) - 1)  // bits that don't change
    let moveMask = 1 << oldIndex  // bit that moves
    let moveDist = abs(newIndex - oldIndex)
    let moveLeft = newIndex > oldIndex
    let blockMask = allMask ^ sameMask ^ moveMask  // bits that move by one
    var ret: [Row] = []
    ret.reserveCapacity(rows.count)
    for row in rows {
      let i = row.baseIndex
      let dc = row.dcMask
      let idx0: Int
      let dc0: Int
      if moveLeft {
        idx0 = (i & sameMask) | ((i & moveMask) << moveDist) | ((i & blockMask) >> 1)
        dc0 = (dc & sameMask) | ((dc & moveMask) << moveDist) | ((dc & blockMask) >> 1)
      } else {
        idx0 = (i & sameMask) | ((i & moveMask) >> moveDist) | ((i & blockMask) << 1)
        dc0 = (dc & sameMask) | ((dc & moveMask) >> moveDist) | ((dc & blockMask) << 1)
      }
      ret.append(Row(idx: idx0, numInputs: inputs, mask: dc0))
    }
    ret.sort { $0.baseIndex < $1.baseIndex }
    rows = ret
  }

  /// Java: `MyListener.addInput(int, int)`: every visible row splits in two.
  private func addInput(_ index: Int, _ oldCount: Int) {
    var ret: [Row] = []
    ret.reserveCapacity(2 * rows.count)
    for row in rows {
      let i = row.baseIndex
      let dc = row.dcMask
      let b = 1 << (oldCount - index)  // _0001000
      let mask = b - 1  // _0000111
      let idx0 = ((i & ~mask) << 1) | (i & mask)  // xxxx0yyy
      let dc0 = ((dc & ~mask) << 1) | (dc & mask)  // wwww0zzz
      ret.append(Row(idx: idx0, numInputs: oldCount + 1, mask: dc0))  // xxxx0yyy
      ret.append(Row(idx: idx0 | b, numInputs: oldCount + 1, mask: dc0))  // xxxx1yyy
    }
    ret.sort { $0.baseIndex < $1.baseIndex }
    rows = ret
  }

  /// Java: `MyListener.removeInput(int, int)`; force the column to don't-care, then drop it.
  private func removeInput(_ index: Int, _ oldCount: Int) {
    let b = 1 << (oldCount - 1 - index)  // _0001000
    var changed = [Bool](repeating: false, count: columns.count)
    // Java walks by index (not by iterator) to avoid a ConcurrentModificationException,
    // re-reading `rows.size()` each pass because `setDontCare` shrinks the list.
    var i = 0
    while i < rows.count {
      let r = rows[i]
      if r.inputs[index] != .dontCare {
        do {
          // `force: true`, so this can only fail on the "failed row merge" invariant.
          try setDontCare(r, b, force: true, changed: &changed)
        } catch let error as AnalyzeError {
          // Java lets the IllegalStateException escape a Swing listener callback, where it
          // lands on the EDT's default handler and the table is left half-reshaped. A Swift
          // protocol method cannot throw here either, so it is recorded on the table rather
          // than dropped silently.
          structuralFailure = error
        } catch {
          structuralFailure = .rowStructure("\(error)")
        }
      }
      i += 1
    }
    let mask = b - 1  // _0000111
    var ret: [Row] = []
    ret.reserveCapacity(rows.count)
    for r in rows {
      let i = r.baseIndex
      let dc = r.dcMask
      let idx0 = ((i >> 1) & ~mask) | (i & mask)  // __xxxyyy
      let dc0 = ((dc >> 1) & ~mask) | (dc & mask)  // wwww0zzz
      ret.append(Row(idx: idx0, numInputs: oldCount - 1, mask: dc0))
    }
    ret.sort { $0.baseIndex < $1.baseIndex }
    rows = ret
  }

  /// Java: `MyListener.inputsChangedForOutput(Entry[], VariableListEvent)`.
  private func inputsChangedForOutput(_ columnIn: [Entry], _ event: VariableListEvent) -> [Entry] {
    var column = columnIn
    let action = event.type
    guard let v = event.variable else { return column }
    switch action {
    case .add:
      guard let bitIndex = event.bitIndex else { return column }
      var oldCount = inputColumnCount - v.width
      for b in stride(from: v.width - 1, through: 0, by: -1) {
        column = addInputForOutput(column, bitIndex - b, oldCount)
        oldCount += 1
      }
    case .remove:
      guard let bitIndex = event.bitIndex else { return column }
      var oldCount = inputColumnCount + v.width
      for b in 0..<v.width {
        column = removeInputForOutput(column, bitIndex - b, oldCount)
        oldCount -= 1
      }
    case .move:
      guard let delta = event.bitIndex else { return column }
      let newIndex = inputIndex(of: v.bitName(0))
      if delta > 0 {
        for b in 0..<v.width {
          column = moveInputForOutput(column, newIndex - delta - b, newIndex - b)
        }
      } else if delta < 0 {
        for b in stride(from: v.width - 1, through: 0, by: -1) {
          column = moveInputForOutput(column, newIndex - delta - b, newIndex - b)
        }
      }
    case .replace:
      guard let bitIndex = event.bitIndex, let index = event.index else { return column }
      let newVar = inputVariable(index)
      var lost = v.width - newVar.width
      var oldCount = inputColumnCount + lost
      let pos = bitIndex + 1 - v.width
      while lost > 0 {
        column = removeInputForOutput(column, pos, oldCount)
        oldCount -= 1
        lost -= 1
      }
      while lost < 0 {
        column = addInputForOutput(column, pos, oldCount)
        oldCount += 1
        lost += 1
      }
    case .allReplaced:
      break
    }
    return column
  }

  /// Java: `MyListener.moveInputForOutput(Entry[], int, int)`.
  private func moveInputForOutput(_ old: [Entry], _ oldIndexIn: Int, _ newIndexIn: Int) -> [Entry] {
    let inputs = inputColumnCount
    let oldIndex = inputs - 1 - oldIndexIn
    let newIndex = inputs - 1 - newIndexIn
    var ret = [Entry](repeating: TruthTable.defaultEntry, count: old.count)
    let sameMask =
      (old.count - 1)
      ^ ((1 << (1 + Swift.max(oldIndex, newIndex))) - 1)
      ^ ((1 << Swift.min(oldIndex, newIndex)) - 1)
    let moveMask = 1 << oldIndex
    let moveDist = abs(newIndex - oldIndex)
    let moveLeft = newIndex > oldIndex
    let blockMask = (old.count - 1) ^ sameMask ^ moveMask
    for i in old.indices {
      let j: Int
      if moveLeft {
        j = (i & sameMask) | ((i & moveMask) << moveDist) | ((i & blockMask) >> 1)
      } else {
        j = (i & sameMask) | ((i & moveMask) >> moveDist) | ((i & blockMask) << 1)
      }
      ret[j] = old[i]
    }
    return ret
  }

  /// Java: `MyListener.removeInputForOutput(Entry[], int, int)`: two cells collapse to one,
  /// and disagreeing cells become don't-care.
  private func removeInputForOutput(_ old: [Entry], _ index: Int, _ oldCount: Int) -> [Entry] {
    var ret = [Entry](repeating: TruthTable.defaultEntry, count: old.count / 2)
    var j = 0
    let mask = 1 << (oldCount - 1 - index)
    for i in old.indices where (i & mask) == 0 {
      let e0 = old[i]
      let e1 = old[i | mask]
      ret[j] = (e0 == e1 ? e0 : .dontCare)
      j += 1
    }
    return ret
  }

  /// Java: `MyListener.addInputForOutput(Entry[], int, int)`, each cell duplicates.
  private func addInputForOutput(_ old: [Entry], _ index: Int, _ oldCount: Int) -> [Entry] {
    var ret = [Entry](repeating: TruthTable.defaultEntry, count: 2 * old.count)
    let b = 1 << (oldCount - index)  // _0001000
    let mask = b - 1  // _0000111
    for i in old.indices {
      ret[((i & ~mask) << 1) | (i & mask)] = old[i]  // xxxx0yyy
      ret[((i & ~mask) << 1) | b | (i & mask)] = old[i]  // xxxx1yyy
    }
    return ret
  }
}
