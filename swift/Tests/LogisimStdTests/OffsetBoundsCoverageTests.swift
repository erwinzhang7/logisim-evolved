// OffsetBoundsCoverageTests.swift; part of logisim-evolved.
//
// Task #18. `getOffsetBounds(AttributeSet)` is gate-visible geometry, not a drawing detail:
// `XmlCircuitReader.buildCircuit` keys its overlap detector on a component's bounds, so a
// factory that answers `Bounds.EMPTY_BOUNDS` collapses every placement of that factory onto
// one key and all but the first are silently dropped on load.
//
// This suite is the standing guard for that. It walks every tool the builtin libraries expose
// and asserts the factory reports a non-empty box for its own default attribute set. It is a
// coverage assertion, not a value assertion; the exact rectangles are checked against the
// Java arithmetic in `OffsetBoundsGeometryTests`.
//
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.

import Foundation
import LogisimFile
import LogisimKernel
import Testing

@testable import LogisimStd

/// Every builtin library, with the id it registers under.
private func allBuiltinLibraries() -> [(String, Library)] {
  [
    (Builtin.baseId, LogisimStd.BaseLibrary()),
    (Builtin.gatesId, GatesLibrary()),
    (Builtin.wiringId, WiringLibrary()),
    (Builtin.arithmeticId, ArithmeticLibrary()),
    (Builtin.memoryId, MemoryLibrary()),
    (Builtin.ioId, IoLibrary()),
    (Builtin.ttlId, TtlLibrary()),
    (Builtin.plexersId, PlexersLibrary()),
  ]
}

/// `(library id, factory)` for every placeable component in the builtin set.
func allBuiltinFactories() -> [(String, any ComponentFactory)] {
  var out: [(String, any ComponentFactory)] = []
  for (id, library) in allBuiltinLibraries() {
    for tool in library.tools {
      guard let add = tool as? AddTool else { continue }
      out.append((id, add.factory))
    }
  }
  return out
}

@Suite("task #18 — every builtin factory reports real offset bounds")
struct OffsetBoundsCoverageTests {

  @Test("no builtin factory answers Bounds.empty for its default attribute set")
  func noEmptyBounds() {
    var empty: [String] = []
    for (id, factory) in allBuiltinFactories() {
      let bounds = factory.offsetBounds(factory.createAttributeSet())
      if bounds.width == 0 || bounds.height == 0 {
        empty.append("\(id):\(factory.name)")
      }
    }
    #expect(empty.isEmpty, "factories with empty offset bounds: \(empty.sorted())")
  }

  @Test("the builtin set is actually populated")
  func setIsNotEmpty() {
    #expect(allBuiltinFactories().count > 100)
  }
}
