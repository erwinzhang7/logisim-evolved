// LogisimUITests: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// DOES A MOVE PREVIEW ACTUALLY HIDE THE ORIGINALS?
//
// `ToolOverlay` carries a `hidden` set, and it was carried and dropped: `setToolOverlay` stored
// it into `CircuitSceneView.hiddenComponentIDs` and nothing read that property. A drag therefore
// drew the ghost AND the unmoved original, both at full strength.
//
// The reason it stayed unnoticed is worth stating, because it is the shape of most of the twenty
// seams found in this port: everything on the path existed and had a plausible name.
// `ToolOverlay.hidden` was populated, `setToolOverlay` was called, `hiddenComponentIDs` was
// assigned, and the field was even documented. Only the last hop, the walker consulting it,
// was missing, and no test in the suite could tell.
//
// So these assert on PRIMITIVE COUNTS out of the scene walker, not on the field's value. A test
// that reads back `hiddenComponentIDs` would have passed against the broken version.
// ═════════════════════════════════════════════════════════════════════════════════════════════

import CoreGraphics
import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender
import LogisimStd
import Testing

@testable import LogisimUI

/// A local copy of `CanvasDrawsTests`' fixture, which is `private` to that file. Copied rather
/// than shared: these tests need a known component ORDER to assert that group tags do not
/// renumber, and pulling the fixture into a common file would let a future edit there change
/// what "the first drawable component" means here without any signal.
@MainActor
private func hiddenFixture() throws -> Circuit {
  StdLibraries.registerAll()
  let circuit = try Circuit(name: "hidden-gate")

  func place(_ factory: any ComponentFactory, _ x: Int, _ y: Int) throws {
    let attributes = factory.createAttributeSet()
    try circuit.mutatorAdd(
      factory.createComponent(
        location: Location.create(x, y, hasToSnap: false), attributes: attributes))
  }

  try place(AndGate.factory, 120, 100)
  try place(OrGate.factory, 120, 180)
  try place(NotGate.factory, 220, 100)

  try circuit.mutatorAdd(
    Wire.create(
      Location.create(400, 300, hasToSnap: false), Location.create(500, 300, hasToSnap: false)))

  return circuit
}

@Suite("Canvas hidden components")
struct CanvasHiddenComponentTests {

  @Test("hiding a component removes its geometry, and only its geometry")
  @MainActor
  func hidingRemovesGeometry() throws {
    let circuit = try hiddenFixture()
    let appearance = CanvasAppearance()

    let full = CircuitSceneSource.build(circuit: circuit, appearance: appearance)
    let victim = try #require(circuit.components.first { !($0 is Wire) })
    let victimID = CircuitSceneSource.identity(of: victim)

    let culled = CircuitSceneSource.build(
      circuit: circuit, appearance: appearance, hidden: [victimID])

    // Strictly fewer primitives: the component drew something, and it stopped.
    #expect(culled.scene.primitives.count < full.scene.primitives.count)
    #expect(culled.paintedComponentCount == full.paintedComponentCount - 1)

    // Everything else still drew. This is the half a naive `hidden` implementation gets wrong by
    // rebuilding the scene from the surviving components and renumbering the group tags.
    #expect(culled.components.count == full.components.count)
    #expect(culled.targets.count == full.targets.count)
  }

  @Test("group tags do not renumber, so hit-testing still resolves the right component")
  @MainActor
  func tagsDoNotRenumber() throws {
    let circuit = try hiddenFixture()
    let appearance = CanvasAppearance()
    let components = circuit.components

    // Hide the FIRST drawable component. If suppression packed the tags down, every component
    // after it would shift by one and this is where that shows.
    let firstIndex = try #require(components.firstIndex { !($0 is Wire) })
    let hidden = CircuitSceneSource.identity(of: components[firstIndex])

    let culled = CircuitSceneSource.build(
      circuit: circuit, appearance: appearance, hidden: [hidden])

    // `targets` is index-aligned with `components` and carries the identity the tag maps to.
    for (index, component) in culled.components.enumerated() {
      #expect(culled.targets[index].id == CircuitSceneSource.identity(of: component))
    }

    // And the hidden one's tag is simply absent from the scene rather than reused.
    let liveTags = Set(culled.scene.groups.map(\.tag))
    #expect(!liveTags.contains(UInt64(firstIndex + 1)))
    if firstIndex + 1 < components.count, !(components[firstIndex + 1] is Wire) {
      #expect(liveTags.contains(UInt64(firstIndex + 2)))
    }
  }

  @Test("hiding nothing is byte-identical to not passing a hidden set")
  @MainActor
  func emptyHiddenSetChangesNothing() throws {
    let circuit = try hiddenFixture()
    let appearance = CanvasAppearance()

    let plain = CircuitSceneSource.build(circuit: circuit, appearance: appearance)
    let empty = CircuitSceneSource.build(circuit: circuit, appearance: appearance, hidden: [])

    #expect(plain.scene.primitives.count == empty.scene.primitives.count)
    #expect(plain.paintedComponentCount == empty.paintedComponentCount)
    #expect(plain.contentBounds == empty.contentBounds)
  }

  @Test("the geometry key moves when the hidden set moves, and not otherwise")
  @MainActor
  func geometryKeyTracksHiddenSet() throws {
    let circuit = try hiddenFixture()
    let appearance = CanvasAppearance()
    let victim = CircuitSceneSource.identity(of: try #require(circuit.components.first))

    let a = CircuitSceneGeometryKey(circuit: circuit, revision: 1, appearance: appearance)
    let b = CircuitSceneGeometryKey(
      circuit: circuit, revision: 1, appearance: appearance, hidden: [victim])
    let c = CircuitSceneGeometryKey(
      circuit: circuit, revision: 1, appearance: appearance, hidden: [victim])

    // Without this the originals stay drawn for the whole drag: `rebuild(force: false)` compares
    // the key, finds it unchanged, and returns before touching the scene.
    #expect(a != b)
    #expect(b == c)
  }
}
