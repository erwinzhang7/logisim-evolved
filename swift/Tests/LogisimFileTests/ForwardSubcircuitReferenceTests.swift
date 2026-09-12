// ForwardSubcircuitReferenceTests.swift: part of logisim-evolved.
//
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
// SPDX-License-Identifier: GPL-3.0-only
//
// A `<comp>` may name a circuit declared LATER in the same file, and that is the normal layout
// rather than an edge case: `main` is written first and the blocks it instantiates come after
// it. `XmlReader`'s component pre-pass runs *inside* the loop that creates the circuits, so at
// the moment the first `<circuit>` is scanned no later circuit exists yet and the reference
// resolves to nothing at all.
//
// Upstream throws `XmlReaderException` there, records nothing, and lets `buildCircuit` retry
// the element once every circuit is present. D8 turns the same failure into a *successful*
// `UnresolvedComponent`, so without care the placeholder is cached as the known component and
// the retry never happens.
//
// The consequence is silent and severe, which is why these are here rather than left to the
// differential rig: a placeholder has **no ends**. It is invisible to `CircuitPoints`, so
// `WireRepair` merges wires straight through the ports it should have had, and it never
// propagates. Nothing about the saved file looks wrong, D8 re-emits the element verbatim,
// so a byte-comparison of the components alone passes while the connectivity is gone.
//
// These tests need no component library: a circuit with no `Pin` still resolves to a real
// subcircuit placement, and "is it a placeholder?" is the whole question.

import Foundation
import Testing

@testable import LogisimFile

/// `main` is declared FIRST and instantiates `block`, which is declared second.
private let forwardReference = """
  <?xml version="1.0" encoding="UTF-8" standalone="no"?>
  <project source="3.6.1" version="1.0">
    <lib desc="#Wiring" name="0"/>
    <lib desc="#Base" name="1"/>
    <main name="main"/>
    <circuit name="main">
      <comp loc="(100,100)" name="block"/>
    </circuit>
    <circuit name="block">
    </circuit>
  </project>
  """

/// The same file with the declarations swapped, so the reference is backward. This is the case
/// that always worked, and it is here as the control: without it a test that merely asserted
/// "resolves" could pass for the wrong reason.
private let backwardReference = """
  <?xml version="1.0" encoding="UTF-8" standalone="no"?>
  <project source="3.6.1" version="1.0">
    <lib desc="#Wiring" name="0"/>
    <lib desc="#Base" name="1"/>
    <main name="main"/>
    <circuit name="block">
    </circuit>
    <circuit name="top">
      <comp loc="(100,100)" name="block"/>
    </circuit>
  </project>
  """

private func load(_ xml: String) throws -> LogisimFile {
  let file = try Loader().openLogisimFile(data: Data(xml.utf8))
  return try #require(file)
}

private func circuit(_ file: LogisimFile, _ name: String) throws -> Circuit {
  try #require(file.circuits.first { $0.name == name })
}

@Test func aSubcircuitDeclaredAfterItsUseStillResolves() throws {
  let file = try load(forwardReference)
  let placed = try #require(try circuit(file, "main").nonWires.first)
  #expect(
    !(placed is UnresolvedComponent),
    "a forward reference became a D8 placeholder; the pre-pass cached it and buildCircuit never retried it")
  #expect(placed.factory is CircuitSubcircuitFactory)
  #expect(placed.factory.name == "block")
}

@Test func aSubcircuitDeclaredBeforeItsUseStillResolves() throws {
  let file = try load(backwardReference)
  let placed = try #require(try circuit(file, "top").nonWires.first)
  #expect(!(placed is UnresolvedComponent))
  #expect(placed.factory is CircuitSubcircuitFactory)
}

/// The placement has to reach the factory's own list, because that list is what the port
/// refresh walks. Registering with the wrong factory, or not at all, leaves the ports empty
/// with nothing to notice it, which is exactly how this defect stayed invisible.
@Test func aForwardReferencedPlacementRegistersWithItsSourceFactory() throws {
  let file = try load(forwardReference)
  let block = try circuit(file, "block")
  let factory = try #require(block.subcircuitFactory as? CircuitSubcircuitFactory)
  let placed = try #require(try circuit(file, "main").nonWires.first)
  #expect(factory.pinComponents(for: try #require(placed as? InstanceComponent)).isEmpty)
  // `block` has no Pin, so there are no ports, but the placement must still be the *same*
  // object the factory knows about, which is what makes a later refresh able to reach it.
  #expect(placed.factory === factory)
}

/// D8 must still fire for something genuinely unresolvable, or this fix would have bought
/// forward references at the cost of the guarantee D8 exists to provide.
@Test func agenuinelyUnknownComponentIsStillPreserved() throws {
  let xml = """
    <?xml version="1.0" encoding="UTF-8" standalone="no"?>
    <project source="3.6.1" version="1.0">
      <lib desc="#Wiring" name="0"/>
      <lib desc="#Risc-V" name="1"/>
      <lib desc="#Base" name="2"/>
      <main name="main"/>
      <circuit name="main">
        <comp lib="1" loc="(100,100)" name="RV32IM"/>
      </circuit>
    </project>
    """
  let file = try load(xml)
  let placed = try #require(try circuit(file, "main").nonWires.first)
  #expect(placed is UnresolvedComponent, "D8 no longer preserves an unresolvable component")
}
