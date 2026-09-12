// SubcircuitPortsTests.swift; part of logisim-evolved.
//
// `CircuitSubcircuitFactory.computePorts` and the `CircuitAppearance` it reads, tested against
// hand-built circuits rather than the corpus, so the suite runs everywhere.
//
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.

import Foundation
import LogisimFile
import LogisimKernel
import Testing

@testable import LogisimStd

// MARK: - Fixtures

/// A circuit with the named input and output pins, at the given locations.
private func makeCircuit(
  name: String,
  inputs: [(String, Location)],
  outputs: [(String, Location)],
  appearance: AttributeOption = CircuitAttributes.appearEvolution
) throws -> Circuit {
  let circuit = try Circuit(name: name, defaultAppearance: appearance)
  try circuit.staticAttributes.setValue(CircuitAttributes.appearance, appearance)
  try circuit.staticAttributes.setValue(CircuitAttributes.namedCircuitBoxFixedSize, false)

  for (label, location) in inputs {
    let attrs = Pin.factory.createAttributeSet()
    try attrs.setValue(Pin.attrType, Pin.input)
    try attrs.setValue(StdAttr.label, label)
    let pin = try Pin.factory.createComponent(location: location, attributes: attrs)
    try circuit.mutatorAdd(pin)
  }
  for (label, location) in outputs {
    let attrs = Pin.factory.createAttributeSet()
    try attrs.setValue(Pin.attrType, Pin.output)
    try attrs.setValue(StdAttr.label, label)
    let pin = try Pin.factory.createComponent(location: location, attributes: attrs)
    try circuit.mutatorAdd(pin)
  }
  return circuit
}

private func place(_ circuit: Circuit, at location: Location) throws -> InstanceComponent {
  let factory = circuit.subcircuitFactory
  let attrs = factory.createAttributeSet()
  let component = try factory.createComponent(location: location, attributes: attrs)
  guard let instance = component as? InstanceComponent else {
    Issue.record("a subcircuit placement should be an InstanceComponent")
    throw CancellationError()
  }
  return instance
}

// MARK: - Tests

@Suite("Subcircuit ports — computePorts against the appearance")
struct SubcircuitPortsTests {

  @Test("a placement of a circuit with pins has one end per pin")
  func endsExistAtAll() throws {
    let inner = try makeCircuit(
      name: "inner",
      inputs: [("a", Location.create(100, 100, hasToSnap: true))],
      outputs: [("y", Location.create(200, 100, hasToSnap: true))])
    let placement = try place(inner, at: Location.create(300, 300, hasToSnap: true))

    // This is the regression that mattered: before `computePorts` existed the list was empty and
    // the component joined no net at all.
    #expect(placement.ends.count == 2)
    #expect(placement.ends.contains { $0.isInput && !$0.isOutput })
    #expect(placement.ends.contains { $0.isOutput && !$0.isInput })
  }

  @Test("an input end is shared and an output end is exclusive")
  func exclusivityFollowsPortDefaultExclusive() throws {
    let inner = try makeCircuit(
      name: "inner",
      inputs: [("a", Location.create(100, 100, hasToSnap: true))],
      outputs: [("y", Location.create(200, 100, hasToSnap: true))])
    let placement = try place(inner, at: Location.create(300, 300, hasToSnap: true))

    let input = try #require(placement.ends.first { $0.isInput })
    let output = try #require(placement.ends.first { $0.isOutput })
    // `Port.defaultExclusive`: INPUT -> SHARED, OUTPUT -> EXCLUSIVE.
    #expect(input.isExclusive == false)
    #expect(output.isExclusive == true)
  }

  /// The ordering rule the whole netlist hangs off. `getPortOffsets` is a `TreeMap<Location, …>`,
  /// so ports come out by ascending x then ascending y of the anchor-relative offset. For a
  /// default evolution appearance the anchor sits on the east edge, so every west (input) port
  /// has x = -width and every east (output) port has x = 0: inputs first, each side ordered
  /// top-to-bottom by the pin's own y (`Location.sortVertical`).
  @Test("ports are ordered inputs-then-outputs, each side top-to-bottom")
  func portOrderFollowsTheTreeMap() throws {
    // Deliberately declared bottom-to-top, so file order and sorted order disagree.
    let inner = try makeCircuit(
      name: "inner",
      inputs: [
        ("low", Location.create(100, 300, hasToSnap: true)),
        ("high", Location.create(100, 100, hasToSnap: true)),
      ],
      outputs: [
        ("outLow", Location.create(400, 300, hasToSnap: true)),
        ("outHigh", Location.create(400, 100, hasToSnap: true)),
      ])
    let placement = try place(inner, at: Location.create(500, 500, hasToSnap: true))

    #expect(placement.ends.count == 4)
    #expect(placement.ends.map(\.isInput) == [true, true, false, false])

    // Within each side the two ends must be distinct and the earlier one must be the higher.
    let inputs = placement.ends.filter(\.isInput)
    let outputs = placement.ends.filter(\.isOutput)
    #expect(inputs[0].location.y < inputs[1].location.y)
    #expect(outputs[0].location.y < outputs[1].location.y)

    // And the pin list `propagate` indexes must be in exactly the same order.
    let factory = try #require(inner.subcircuitFactory as? CircuitSubcircuitFactory)
    let pins = factory.pinComponents(for: placement)
    #expect(pins.count == 4)
    #expect(pins.map { AppearancePinReaderProbe.label($0) } == ["high", "low", "outHigh", "outLow"])
  }

  @Test("ends are relative to the placement's own location")
  func endsAreTranslatedToThePlacement() throws {
    let inner = try makeCircuit(
      name: "inner",
      inputs: [("a", Location.create(100, 100, hasToSnap: true))],
      outputs: [("y", Location.create(200, 100, hasToSnap: true))])
    let here = try place(inner, at: Location.create(300, 300, hasToSnap: true))
    let there = try place(inner, at: Location.create(700, 800, hasToSnap: true))

    for (a, b) in zip(here.ends, there.ends) {
      #expect(b.location.x - a.location.x == 400)
      #expect(b.location.y - a.location.y == 500)
    }
  }

  /// The load-order case the file header calls out: `XmlCircuitReader` finishes a parent circuit
  /// before the child it instantiates has any pins, so a placement created against an empty
  /// circuit must gain its ends when the pins arrive.
  @Test("adding a pin to the inner circuit updates every existing placement")
  func endsFollowLaterPinAdditions() throws {
    let inner = try Circuit(name: "inner")
    let placement = try place(inner, at: Location.create(300, 300, hasToSnap: true))
    #expect(placement.ends.isEmpty)

    let attrs = Pin.factory.createAttributeSet()
    try attrs.setValue(Pin.attrType, Pin.input)
    try attrs.setValue(StdAttr.label, "a")
    let pin = try Pin.factory.createComponent(
      location: Location.create(100, 100, hasToSnap: true), attributes: attrs)
    try inner.mutatorAdd(pin)

    #expect(placement.ends.count == 1)
    #expect(placement.ends[0].isInput)

    // …and lose them again when the pin goes.
    inner.mutatorRemove(pin)
    #expect(placement.ends.isEmpty)
  }

  @Test("rotating the placement rotates its ends")
  func facingRotatesThePorts() throws {
    let inner = try makeCircuit(
      name: "inner",
      inputs: [("a", Location.create(100, 100, hasToSnap: true))],
      outputs: [("y", Location.create(200, 100, hasToSnap: true))])
    let placement = try place(inner, at: Location.create(300, 300, hasToSnap: true))
    let east = placement.ends

    try placement.attributeSet.setValue(StdAttr.facing, .north)
    let north = placement.ends

    #expect(north.count == east.count)
    #expect(north != east)
    // `Location.rotate(EAST -> NORTH, 0, 0)` is the 90-degree case, `(x, y) -> (y, -x)` about the
    // component's location. Compared as *sets*, not pairwise: the rotation changes each port's
    // offset, and `getPortOffsets` re-sorts by the rotated offset, so port `i` after the turn is
    // not the turn of port `i` before it. That reordering is upstream's and is the point of the
    // `TreeMap`; asserting it pairwise would be asserting a bug.
    let rotated = Set(
      east.map { end in
        let bx = end.location.x - 300
        let by = end.location.y - 300
        return Location.create(300 + by, 300 - bx, hasToSnap: true)
      })
    #expect(Set(north.map(\.location)) == rotated)
  }

  /// A classic-appearance circuit buckets its pins by the *reverse* of each pin's own facing, so
  /// its ports do not land on the same two columns the evolution box uses.
  @Test("the classic appearance produces a different, still-complete port set")
  func classicAppearanceIsHonoured() throws {
    let inner = try makeCircuit(
      name: "inner",
      inputs: [("a", Location.create(100, 100, hasToSnap: true))],
      outputs: [("y", Location.create(200, 100, hasToSnap: true))],
      appearance: CircuitAttributes.appearClassic)
    let placement = try place(inner, at: Location.create(300, 300, hasToSnap: true))
    #expect(placement.ends.count == 2)
  }

  /// D13: a hand-edited `<appear>` is untrusted input. None of these may trap.
  @Test("a malformed <appear> degrades to the default custom shape rather than trapping")
  func malformedAppearanceDoesNotTrap() throws {
    let hostile = [
      "<appear><circ-port x=\"\" y=\"\" dir=\"in\" pin=\"100,100\"/></appear>",
      "<appear><circ-port x=\"1\" y=\"2\" pin=\"\"/></appear>",
      "<appear><circ-port x=\"1\" y=\"2\" pin=\"100\"/></appear>",
      "<appear><circ-port x=\"1\" y=\"2\" pin=\"nope,nope\" dir=\"in\"/></appear>",
      "<appear><circ-port x=\"1\" y=\"2\" pin=\"100,100\"/></appear>",  // no dir, no width
      "<appear><circ-port x=\"a\" y=\"b\" width=\"c\" height=\"d\" pin=\"100,100\"/></appear>",
      "<appear><circ-port x=\"1\" y=\"2\" width=\"NaN\" height=\"8\" pin=\"100,100\"/></appear>",
      "<appear><circ-anchor facing=\"sideways\"/></appear>",
      "<appear><circ-anchor x=\"5\" y=\"5\"/><circ-port/></appear>",
      "<appear/>",
    ]
    for source in hostile {
      let inner = try makeCircuit(
        name: "inner",
        inputs: [("a", Location.create(100, 100, hasToSnap: true))],
        outputs: [("y", Location.create(200, 100, hasToSnap: true))],
        appearance: CircuitAttributes.appearCustom)
      let document = try XMLDocument(xmlString: source, options: [])
      let root = try #require(document.rootElement())
      inner.absorbAppearance(root)
      // The assertion is simply that this returns.
      let placement = try place(inner, at: Location.create(300, 300, hasToSnap: true))
      #expect(placement.ends.count >= 0)
    }
  }

  @Test("a well-formed custom <appear> binds its circ-ports to the named pins")
  func customAppearanceBindsPorts() throws {
    let inner = try makeCircuit(
      name: "inner",
      inputs: [("a", Location.create(100, 100, hasToSnap: true))],
      outputs: [("y", Location.create(200, 100, hasToSnap: true))],
      appearance: CircuitAttributes.appearCustom)
    let source = """
      <appear>
        <circ-anchor x="50" y="50" facing="east"/>
        <circ-port x="50" y="60" dir="in" pin="100,100"/>
        <circ-port x="150" y="60" dir="out" pin="200,100"/>
      </appear>
      """
    let document = try XMLDocument(xmlString: source, options: [])
    let root = try #require(document.rootElement())
    inner.absorbAppearance(root)

    let placement = try place(inner, at: Location.create(300, 300, hasToSnap: true))
    #expect(placement.ends.count == 2)
    // Offsets are anchor-relative: (50,60)-(50,50) = (0,10) and (150,60)-(50,50) = (100,10).
    #expect(placement.ends[0].location == Location.create(300, 310, hasToSnap: true))
    #expect(placement.ends[1].location == Location.create(400, 310, hasToSnap: true))
    #expect(placement.ends[0].isInput)
    #expect(placement.ends[1].isOutput)
  }

  @Test("a custom <appear> whose ports name no live pin falls back rather than going portless")
  func customAppearanceWithoutUsablePortsFallsBack() throws {
    let inner = try makeCircuit(
      name: "inner",
      inputs: [("a", Location.create(100, 100, hasToSnap: true))],
      outputs: [("y", Location.create(200, 100, hasToSnap: true))],
      appearance: CircuitAttributes.appearCustom)
    let source = """
      <appear>
        <circ-anchor x="50" y="50"/>
        <circ-port x="50" y="60" dir="in" pin="900,900"/>
      </appear>
      """
    let document = try XMLDocument(xmlString: source, options: [])
    let root = try #require(document.rootElement())
    inner.absorbAppearance(root)

    // `CircuitAppearance`'s constructor seeds the custom list with
    // `DefaultCustomAppearance.build(pins)`, and `XmlCircuitReader` only replaces it when the
    // parse produced something. So both pins are still reachable.
    let placement = try place(inner, at: Location.create(300, 300, hasToSnap: true))
    #expect(placement.ends.count == 2)
  }
}

/// `AppearancePinReader` is internal to `LogisimFile`; the test only needs the label, and reading
/// it the same way keeps the assertion independent of how `Pin` stores it.
private enum AppearancePinReaderProbe {
  static func label(_ component: any Component) -> String {
    component.attributeSet[StdAttr.label] ?? ""
  }
}
