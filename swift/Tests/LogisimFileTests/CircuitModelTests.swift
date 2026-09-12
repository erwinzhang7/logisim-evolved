// CircuitModelTests.swift: part of logisim-evolved.
//
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
// SPDX-License-Identifier: GPL-3.0-only
//
// Covers the netlist model: Circuit, CircuitAttributes, the wire store, the label rules, and
// D8's unresolved-component round trip. Each assertion names the upstream behaviour it pins.

import Foundation
import LogisimKernel
import XCTest

@testable import LogisimFile

// MARK: - Test doubles

/// A minimal factory so the tests can place something that is not a wire.
private final class StubFactory: AbstractComponentFactory {
  private let identifier: String
  private let attributeTemplate: () -> any AttributeSet
  private let tunnel: Bool
  private let pin: Bool
  private let clock: Bool

  init(
    name: String,
    tunnel: Bool = false,
    pin: Bool = false,
    clock: Bool = false,
    attributes: @escaping () -> any AttributeSet = {
      AttributeSets.fixedSet([StdAttr.label.binding(""), StdAttr.facing.binding(.east)])
    }
  ) {
    self.identifier = name
    self.attributeTemplate = attributes
    self.tunnel = tunnel
    self.pin = pin
    self.clock = clock
    super.init()
  }

  override var name: String { identifier }
  override func createAttributeSet() -> any AttributeSet { attributeTemplate() }
  override var isTunnel: Bool { tunnel }
  override var isPin: Bool { pin }
  override var isClock: Bool { clock }

  override func createComponent(
    location: Location, attributes: any AttributeSet
  ) throws -> any Component {
    InstanceComponent(factory: self, location: location, attributes: attributes)
  }

  override func offsetBounds(_ attributes: any AttributeSet) -> Bounds {
    Bounds.create(0, 0, 10, 10)
  }
}

private final class RecordingCircuitListener: CircuitListener {
  var events: [(CircuitEventAction, CircuitEventData)] = []
  func circuitChanged(_ event: CircuitEvent) {
    events.append((event.action, event.data))
  }
  var actions: [CircuitEventAction] { events.map(\.0) }
}

private func makeComponent(
  _ factory: StubFactory, at location: Location, label: String = ""
) throws -> InstanceComponent {
  let attributes = factory.createAttributeSet()
  try attributes.setValue(StdAttr.label, label)
  let component = try factory.createComponent(location: location, attributes: attributes)
  return component as! InstanceComponent
}

private func location(_ x: Int, _ y: Int) -> Location {
  Location.create(x, y, hasToSnap: false)
}

// MARK: - Static attributes

final class CircuitAttributeTests: XCTestCase {

  /// `createBaseAttrs` writes the preference appearance and the name over `STATIC_DEFAULTS`.
  func testCreateBaseAttrsAppliesDefaultsThenOverrides() throws {
    let attributes = try CircuitAttributes.createBaseAttrs(name: "main")
    XCTAssertEqual(attributes[CircuitAttributes.nameAttribute], "main")
    XCTAssertEqual(attributes[CircuitAttributes.appearance], CircuitAttributes.appearEvolution)
    XCTAssertEqual(attributes[CircuitAttributes.circuitLabelAttribute], "")
    XCTAssertEqual(attributes[CircuitAttributes.circuitLabelFacingAttribute], .east)
    XCTAssertEqual(attributes[CircuitAttributes.simulationFrequency], -1)
    XCTAssertEqual(attributes[CircuitAttributes.downloadFrequency], -1)
    XCTAssertEqual(attributes[CircuitAttributes.downloadBoard], "")
    // `STATIC_DEFAULTS` says false; the Circuit constructor is what flips it, not this.
    XCTAssertEqual(attributes[CircuitAttributes.namedCircuitBoxFixedSize], false)
  }

  /// The asymmetry from `CircuitAttributes.java:44`: a new circuit gets EVOLUTION but the
  /// provider the writer compares against forces CLASSIC. Getting this "consistent" would stop
  /// `appearance=` being written for a fresh circuit.
  func testDefaultStaticProviderForcesClassicAppearance() throws {
    let provider = CircuitAttributes.defaultStaticAttributes
    let value = provider.defaultValue(
      of: CircuitAttributes.appearance, version: LogisimVersion(4, 1, 0))
    XCTAssertEqual(value, CircuitAttributes.appearClassic)

    let circuit = try Circuit(name: "c")
    XCTAssertEqual(
      circuit.staticAttributes[CircuitAttributes.appearance],
      CircuitAttributes.appearEvolution)
  }

  /// The Circuit constructor overwrites `NAMED_CIRCUIT_BOX_FIXED_SIZE` with the preference,
  /// after `createBaseAttrs` has run.
  func testCircuitConstructorAppliesFixedSizePreference() throws {
    let circuit = try Circuit(name: "c")
    XCTAssertEqual(circuit.staticAttributes[CircuitAttributes.namedCircuitBoxFixedSize], true)

    let explicit = try Circuit(name: "c", namedCircuitBoxFixedSize: false)
    XCTAssertEqual(explicit.staticAttributes[CircuitAttributes.namedCircuitBoxFixedSize], false)
  }

  /// `isToSave` is false for every static attribute, so a subcircuit instance reading
  /// `circuit`/`clabel`/`appearance` never writes them a second time.
  func testInstanceSetDoesNotSaveStaticAttributes() throws {
    let circuit = try Circuit(name: "c")
    let attributes = CircuitAttributes(source: circuit)
    for attribute in CircuitAttributes.staticAttributes {
      XCTAssertFalse(attributes.isToSave(attribute), "\(attribute.name) must not be saved")
    }
    XCTAssertTrue(attributes.isToSave(StdAttr.facing))
    XCTAssertTrue(attributes.isToSave(StdAttr.label))
  }

  /// The forwarding branch: an instance answers static attributes out of the source circuit,
  /// including ones absent from `INSTANCE_ATTRS`.
  func testInstanceSetForwardsToStaticSet() throws {
    let circuit = try Circuit(name: "adder")
    let attributes = CircuitAttributes(source: circuit)

    XCTAssertEqual(attributes[CircuitAttributes.nameAttribute], "adder")
    // Not in INSTANCE_ATTRS, yet readable, upstream relies on this.
    XCTAssertFalse(attributes.containsAttribute(CircuitAttributes.downloadBoard))
    XCTAssertEqual(attributes[CircuitAttributes.downloadBoard], "")

    try attributes.setValue(CircuitAttributes.circuitLabelAttribute, "hello")
    XCTAssertEqual(circuit.staticAttributes[CircuitAttributes.circuitLabelAttribute], "hello")
  }

  /// Only `LABEL` reports an old value; everything else fires with `oldValue = null`.
  func testOnlyLabelFiresWithAnOldValue() throws {
    let circuit = try Circuit(name: "c")
    let attributes = CircuitAttributes(source: circuit)

    var oldValues: [String: AttributeValue?] = [:]
    let token = attributes.addAttributeListener(onValueChanged: { event in
      if let attribute = event.attribute {
        oldValues[attribute.name] = event.oldValue
      }
    })
    defer { token.cancel() }

    try attributes.setValue(StdAttr.label, "L1")
    try attributes.setValue(StdAttr.label, "L2")
    try attributes.setValue(StdAttr.facing, .north)

    XCTAssertEqual(oldValues["label"] ?? nil, .string("L1"))
    XCTAssertNil(oldValues["facing"] ?? nil)
  }

  /// Setting a value to what it already is must not fire at all.
  func testUnchangedValueDoesNotFire() throws {
    let circuit = try Circuit(name: "c")
    let attributes = CircuitAttributes(source: circuit)
    var fired = 0
    let token = attributes.addAttributeListener(onValueChanged: { _ in fired += 1 })
    defer { token.cancel() }

    try attributes.setValue(StdAttr.facing, .east)  // already east
    XCTAssertEqual(fired, 0)
    try attributes.setValue(StdAttr.facing, .west)
    XCTAssertEqual(fired, 1)
  }

  /// Only `NAME_ATTR` carries a read-only flag, and `setReadOnly` on anything else is ignored
  /// rather than throwing, unlike `AbstractAttributeSet`'s default.
  func testNameIsTheOnlyReadOnlyFlag() throws {
    let circuit = try Circuit(name: "c")
    let attributes = CircuitAttributes(source: circuit)
    XCTAssertFalse(attributes.isReadOnly(CircuitAttributes.nameAttribute))
    attributes.setReadOnly(CircuitAttributes.nameAttribute, true)
    XCTAssertTrue(attributes.isReadOnly(CircuitAttributes.nameAttribute))
    attributes.setReadOnly(StdAttr.label, true)
    XCTAssertFalse(attributes.isReadOnly(StdAttr.label))
  }

  /// `copyInto` nulls `subcircInstance` and copies the five instance values.
  func testCopyDropsSubcircuitInstance() throws {
    let circuit = try Circuit(name: "c")
    let attributes = CircuitAttributes(source: circuit)
    let factory = StubFactory(name: "Stub")
    let component = try makeComponent(factory, at: location(0, 0))
    attributes.setSubcircuit(component)
    try attributes.setValue(StdAttr.label, "keepme")

    let copy = attributes.copy() as! CircuitAttributes
    XCTAssertNil(copy.subcircuitInstance)
    XCTAssertEqual(copy[StdAttr.label], "keepme")
    XCTAssertNotNil(attributes.subcircuitInstance)
  }

  /// `copyStaticAttributes` copies the eight it names, and deliberately not `labelloc`.
  func testCopyStaticAttributes() throws {
    let source = try CircuitAttributes.createBaseAttrs(name: "src")
    try source.setValue(CircuitAttributes.circuitLabelAttribute, "L")
    try source.setValue(CircuitAttributes.downloadBoard, "board")
    let destination = try CircuitAttributes.createBaseAttrs(name: "dst")

    try CircuitAttributes.copyStaticAttributes(from: source, to: destination)

    XCTAssertEqual(destination[CircuitAttributes.circuitLabelAttribute], "L")
    XCTAssertEqual(destination[CircuitAttributes.downloadBoard], "board")
    // The name is NOT in the copy list, so it survives untouched.
    XCTAssertEqual(destination[CircuitAttributes.nameAttribute], "dst")
  }
}

// MARK: - Circuit

final class CircuitTests: XCTestCase {

  func testNameAndSetNameFireCheckThenSet() throws {
    let circuit = try Circuit(name: "old")
    let listener = RecordingCircuitListener()
    circuit.addCircuitListener(listener)

    try circuit.setName("new")

    XCTAssertEqual(circuit.name, "new")
    XCTAssertEqual(listener.actions, [.checkName, .setName])
  }

  /// The empty-name branch of `StaticListener`: rejected *and reverted*, then the revert
  /// re-enters the listener and fires `ACTION_SET_NAME` for the restored name.
  func testEmptyNameIsRevertedAndReported() throws {
    let circuit = try Circuit(name: "keep")
    var diagnostics: [String] = []
    circuit.diagnosticReporter = { diagnostic in
      if case .emptyCircuitName = diagnostic { diagnostics.append("empty") }
    }
    let listener = RecordingCircuitListener()
    circuit.addCircuitListener(listener)

    try circuit.setName("")

    XCTAssertEqual(circuit.name, "keep")
    XCTAssertEqual(diagnostics, ["empty"])
    // The revert path fires check+set for the restored name, then the outer `revert` fires
    // ACTION_SET_NAME once more, exactly as the Java recursion does.
    XCTAssertEqual(listener.actions, [.checkName, .setName, .setName])
  }

  /// Renaming onto an existing pin label is rejected and reverted.
  func testRenameCollidingWithPinLabelIsReverted() throws {
    let circuit = try Circuit(name: "circ")
    let pinFactory = StubFactory(name: "Pin", pin: true)
    let pin = try makeComponent(pinFactory, at: location(0, 0), label: "carry")
    try circuit.mutatorAdd(pin)

    var reported: String?
    circuit.diagnosticReporter = { diagnostic in
      if case .circuitNameMatchesPinLabel(let name) = diagnostic { reported = name }
    }

    try circuit.setName("CARRY")  // matches case-insensitively under the VHDL default

    XCTAssertEqual(circuit.name, "circ")
    XCTAssertEqual(reported, "CARRY")
  }

  func testMutatorAddAndRemove() throws {
    let circuit = try Circuit(name: "c")
    let factory = StubFactory(name: "Stub")
    let component = try makeComponent(factory, at: location(10, 20))

    let listener = RecordingCircuitListener()
    circuit.addCircuitListener(listener)

    try circuit.mutatorAdd(component)
    XCTAssertEqual(circuit.nonWires.count, 1)
    XCTAssertTrue(circuit.contains(component))

    // A second add of the same object is a no-op and fires nothing.
    try circuit.mutatorAdd(component)
    XCTAssertEqual(circuit.nonWires.count, 1)
    XCTAssertEqual(listener.actions, [.add])

    circuit.mutatorRemove(component)
    XCTAssertEqual(circuit.nonWires.count, 0)
    XCTAssertFalse(circuit.contains(component))
    XCTAssertEqual(listener.actions, [.add, .remove])
  }

  /// A degenerate wire is dropped silently, and no event is fired; both early returns.
  func testDegenerateWireIsIgnored() throws {
    let circuit = try Circuit(name: "c")
    let listener = RecordingCircuitListener()
    circuit.addCircuitListener(listener)

    let point = location(50, 50)
    try circuit.mutatorAdd(Wire.create(point, point))

    XCTAssertEqual(circuit.wires.count, 0)
    XCTAssertEqual(listener.actions, [])
  }

  /// Wires dedup structurally, which is what makes a duplicated `<wire>` element a no-op.
  func testDuplicateWireIsIgnored() throws {
    let circuit = try Circuit(name: "c")
    let listener = RecordingCircuitListener()
    circuit.addCircuitListener(listener)

    try circuit.mutatorAdd(Wire.create(location(0, 0), location(30, 0)))
    // A distinct object with the same endpoints, and the reversed spelling of the same segment.
    try circuit.mutatorAdd(Wire.create(location(0, 0), location(30, 0)))
    try circuit.mutatorAdd(Wire.create(location(30, 0), location(0, 0)))

    XCTAssertEqual(circuit.wires.count, 1)
    XCTAssertEqual(listener.actions, [.add])
  }

  /// `mutatorAdd` clears a label that duplicates one already in the circuit.
  func testDuplicateLabelIsClearedOnAdd() throws {
    let circuit = try Circuit(name: "c")
    let factory = StubFactory(name: "Stub")

    let first = try makeComponent(factory, at: location(0, 0), label: "reg")
    try circuit.mutatorAdd(first)
    let second = try makeComponent(factory, at: location(50, 0), label: "REG")
    try circuit.mutatorAdd(second)

    XCTAssertEqual(first.attributeSet[StdAttr.label], "reg")
    XCTAssertEqual(second.attributeSet[StdAttr.label], "")
  }

  /// v4.1.0's circuit-name collision rule, which is asymmetric on purpose: the name is inserted
  /// into the label set *raw* while the lookup uppercases, so the collision only fires when the
  /// circuit name is already uppercase.
  ///
  /// This is the case where upstream `main` and v4.1.0 disagree, and where following `main` would
  /// blank a label the 4.1.0 oracle keeps. See `Circuit.clearDuplicateLabel`.
  func testCircuitNameCollisionFollowsThe410Rule() throws {
    let factory = StubFactory(name: "Stub")

    // Lowercase circuit name: "counter" != "COUNTER", so the label survives.
    let lower = try Circuit(name: "counter")
    let kept = try makeComponent(factory, at: location(0, 0), label: "Counter")
    try lower.mutatorAdd(kept)
    XCTAssertEqual(kept.attributeSet[StdAttr.label], "Counter")

    // Uppercase circuit name: the raw insertion matches the uppercased lookup, so it is cleared.
    let upper = try Circuit(name: "COUNTER")
    let cleared = try makeComponent(factory, at: location(0, 0), label: "Counter")
    try upper.mutatorAdd(cleared)
    XCTAssertEqual(cleared.attributeSet[StdAttr.label], "")

    // And an exact lowercase match is cleared too, since "counter".uppercased() == "COUNTER"
    // is not the test; the raw name "counter" is in the set and the lookup is "COUNTER".
    // So this one survives as well, which is the same asymmetry seen from the other side.
    let exact = try Circuit(name: "counter")
    let alsoKept = try makeComponent(factory, at: location(0, 0), label: "counter")
    try exact.mutatorAdd(alsoKept)
    XCTAssertEqual(alsoKept.attributeSet[StdAttr.label], "counter")
  }

  /// Tunnels are exempt on both sides; duplicate tunnel labels are the whole point of tunnels.
  func testTunnelLabelsAreNotDeduplicated() throws {
    let circuit = try Circuit(name: "c")
    let tunnelFactory = StubFactory(name: "Tunnel", tunnel: true)

    let first = try makeComponent(tunnelFactory, at: location(0, 0), label: "clk")
    try circuit.mutatorAdd(first)
    let second = try makeComponent(tunnelFactory, at: location(50, 0), label: "clk")
    try circuit.mutatorAdd(second)

    XCTAssertEqual(first.attributeSet[StdAttr.label], "clk")
    XCTAssertEqual(second.attributeSet[StdAttr.label], "clk")
  }

  /// `removeWrongLabels`: adding a component blanks any label equal to that component's
  /// *factory name*.
  func testRemoveWrongLabelsClearsLabelsMatchingFactoryName() throws {
    let circuit = try Circuit(name: "c")
    let stub = StubFactory(name: "Stub")
    let labelled = try makeComponent(stub, at: location(0, 0), label: "gadget")
    try circuit.mutatorAdd(labelled)

    var reported: String?
    circuit.diagnosticReporter = { diagnostic in
      if case .labelCollision(let name) = diagnostic { reported = name }
    }

    let gadgetFactory = StubFactory(name: "gadget")
    try circuit.mutatorAdd(try makeComponent(gadgetFactory, at: location(50, 0)))

    XCTAssertEqual(labelled.attributeSet[StdAttr.label], "")
    XCTAssertEqual(reported, "gadget")
  }

  func testClocksAreTracked() throws {
    let circuit = try Circuit(name: "c")
    let clockFactory = StubFactory(name: "Clock", clock: true)
    let clock = try makeComponent(clockFactory, at: location(0, 0))
    try circuit.mutatorAdd(clock)
    XCTAssertEqual(circuit.clocks.count, 1)
    circuit.mutatorRemove(clock)
    XCTAssertEqual(circuit.clocks.count, 0)
  }

  func testMutatorClearEmptiesEverythingAndReportsOldComponents() throws {
    let circuit = try Circuit(name: "c")
    let factory = StubFactory(name: "Stub")
    try circuit.mutatorAdd(try makeComponent(factory, at: location(0, 0)))
    try circuit.mutatorAdd(Wire.create(location(0, 0), location(30, 0)))

    let listener = RecordingCircuitListener()
    circuit.addCircuitListener(listener)
    circuit.mutatorClear()

    XCTAssertEqual(circuit.nonWires.count, 0)
    XCTAssertEqual(circuit.wires.count, 0)
    guard case .components(let old)? = listener.events.first?.1 else {
      return XCTFail("ACTION_CLEAR must carry the old component set")
    }
    XCTAssertEqual(old.count, 1)  // comps only; wires are not in `oldComps` upstream either
  }

  /// `getBounds()` unions the component box with the wire box, skipping the wire box when it has
  /// a zero dimension.
  func testBounds() throws {
    let circuit = try Circuit(name: "c")
    XCTAssertEqual(circuit.bounds, Bounds.empty)

    try circuit.mutatorAdd(Wire.create(location(0, 0), location(30, 0)))
    // recomputeBounds adds 1 to both dimensions.
    XCTAssertEqual(circuit.bounds, Bounds.create(0, 0, 31, 1))

    let factory = StubFactory(name: "Stub")
    try circuit.mutatorAdd(try makeComponent(factory, at: location(100, 100)))
    XCTAssertEqual(circuit.bounds, Bounds.create(0, 0, 110, 110))
  }

  func testAllContainingAndAllWithin() throws {
    let circuit = try Circuit(name: "c")
    let factory = StubFactory(name: "Stub")
    let component = try makeComponent(factory, at: location(10, 10))
    try circuit.mutatorAdd(component)

    XCTAssertEqual(circuit.allContaining(location(15, 15)).count, 1)
    XCTAssertEqual(circuit.allContaining(location(500, 500)).count, 0)
    XCTAssertEqual(circuit.allWithin(Bounds.create(0, 0, 100, 100)).count, 1)
    XCTAssertEqual(circuit.allWithin(Bounds.create(0, 0, 5, 5)).count, 0)
  }

  /// Bus-width positions default to NONE, round-trip, and `NONE` clears the entry, which is
  /// what makes the writer omit the attribute.
  func testWireBusWidthPosition() throws {
    let circuit = try Circuit(name: "c")
    let wire = Wire.create(location(0, 0), location(30, 0))
    try circuit.mutatorAdd(wire)

    XCTAssertEqual(circuit.getWireBusWidthPos(wire), Wire.busWidthPositionNone)
    XCTAssertNil(circuit.savedWireBusWidthPos(wire))

    circuit.setWireBusWidthPos(wire, Wire.busWidthPositionCenter)
    XCTAssertEqual(circuit.getWireBusWidthPos(wire), Wire.busWidthPositionCenter)
    XCTAssertEqual(circuit.savedWireBusWidthPos(wire), Wire.busWidthPositionCenter)

    circuit.setWireBusWidthPos(wire, Wire.busWidthPositionNone)
    XCTAssertNil(circuit.savedWireBusWidthPos(wire))
  }

  /// `setTickFrequency` only marks the project dirty when the *previous* value was positive.
  func testTickFrequencyDirtyRule() throws {
    let circuit = try Circuit(name: "c")
    XCTAssertEqual(circuit.tickFrequency, -1)

    try circuit.setTickFrequency(10)
    XCTAssertFalse(circuit.tickFrequencyChangeMarksDirty)  // previous was -1

    try circuit.setTickFrequency(20)
    XCTAssertTrue(circuit.tickFrequencyChangeMarksDirty)
    XCTAssertEqual(circuit.tickFrequency, 20)
  }

  /// D3: `circuitsUsingThis` must not keep the using circuit alive.
  func testCircuitsUsingThisIsWeakOnBothSides() throws {
    let child = try Circuit(name: "child")
    XCTAssertEqual(child.circuitsUsingThisCircuit.count, 0)

    try autoreleasepool {
      let parent = try Circuit(name: "parent")
      let component = try child.subcircuitFactory.createComponent(
        location: location(0, 0), attributes: child.subcircuitFactory.createAttributeSet())
      try parent.mutatorAdd(component)
      XCTAssertEqual(child.circuitsUsingThisCircuit.count, 1)
    }

    // The parent is gone; the entry must be purged rather than resurrecting it.
    XCTAssertEqual(child.circuitsUsingThisCircuit.count, 0)
  }

  /// Removing the placement evicts the usage entry; the explicit eviction owner D3 requires.
  func testRemovingSubcircuitComponentEvictsUsage() throws {
    let child = try Circuit(name: "child")
    let parent = try Circuit(name: "parent")
    let component = try child.subcircuitFactory.createComponent(
      location: location(0, 0), attributes: child.subcircuitFactory.createAttributeSet())
    try parent.mutatorAdd(component)
    XCTAssertEqual(child.circuitsUsingThisCircuit.count, 1)

    parent.mutatorRemove(component)
    XCTAssertEqual(child.circuitsUsingThisCircuit.count, 0)
  }

  /// The factory's name tracks the circuit's, which is what `<comp name="…">` writes.
  func testSubcircuitFactoryTracksCircuitName() throws {
    let circuit = try Circuit(name: "alu")
    XCTAssertEqual(circuit.subcircuitFactory.name, "alu")
    try circuit.setName("alu2")
    XCTAssertEqual(circuit.subcircuitFactory.name, "alu2")
    XCTAssertTrue(circuit.subcircuitFactory.subcircuit === circuit)
  }
}

// MARK: - Label validation

final class CircuitLabelValidatorTests: XCTestCase {

  func testLabelsMatchFollowsIdentity() {
    XCTAssertTrue(CircuitLabelValidator.labelsMatch("abc", "ABC", .hdlCompatible))
    XCTAssertFalse(CircuitLabelValidator.labelsMatch("abc", "ABC", .caseSensitive))
    XCTAssertTrue(CircuitLabelValidator.labelsMatch("abc", "abc", .caseSensitive))
  }

  /// Java's `equalsIgnoreCase` uses *simple* case mapping, so `ß` does not equal `SS`. A
  /// Foundation case-insensitive compare or a `uppercased()` round trip would answer otherwise.
  func testEqualsIgnoreCaseUsesSimpleMapping() {
    XCTAssertFalse(CircuitLabelValidator.javaEqualsIgnoreCase("ß", "SS"))
    XCTAssertTrue(CircuitLabelValidator.javaEqualsIgnoreCase("straße", "STRAßE"))
    XCTAssertFalse(CircuitLabelValidator.javaEqualsIgnoreCase("ab", "abc"))
  }

  func testLabelKey() {
    XCTAssertEqual(CircuitLabelValidator.labelKey("aBc", .hdlCompatible), "ABC")
    XCTAssertEqual(CircuitLabelValidator.labelKey("aBc", .caseSensitive), "aBc")
  }

  func testLabelIdentityForHdlType() {
    XCTAssertEqual(CircuitLabelValidator.labelIdentity(forHdlType: "VHDL"), .hdlCompatible)
    XCTAssertEqual(CircuitLabelValidator.labelIdentity(forHdlType: "Verilog"), .caseSensitive)
  }

  /// A tunnel's label is always acceptable: the very first line of `isCorrectLabel`.
  func testTunnelLabelsAreAlwaysCorrect() throws {
    let tunnel = StubFactory(name: "Tunnel", tunnel: true)
    XCTAssertTrue(
      Circuit.isCorrectLabel(
        circuitName: "anything", name: "anything", components: [], me: nil, factory: tunnel))
  }

  /// A pin labelled with the circuit's own name is rejected.
  func testPinLabelEqualToCircuitNameIsRejected() throws {
    let pin = StubFactory(name: "Pin", pin: true)
    var reported = false
    let ok = Circuit.isCorrectLabel(
      circuitName: "adder", name: "ADDER", components: [], me: nil, factory: pin,
      reporter: { diagnostic in
        if case .componentLabelEqualsCircuitName = diagnostic { reported = true }
      })
    XCTAssertFalse(ok)
    XCTAssertTrue(reported)
  }

  /// A label equal to some component's *type* name is rejected.
  func testLabelMatchingAComponentTypeNameIsRejected() throws {
    let stub = StubFactory(name: "Stub")
    let component = try makeComponent(stub, at: location(0, 0))
    XCTAssertFalse(
      Circuit.isCorrectLabel(
        circuitName: "c", name: "stub", components: [component], me: nil, factory: stub))
  }

  /// A component never collides with itself: the `me` comparison is reference identity.
  func testComponentDoesNotCollideWithItself() throws {
    let stub = StubFactory(name: "Stub")
    let component = try makeComponent(stub, at: location(0, 0), label: "reg")
    XCTAssertTrue(
      Circuit.isCorrectLabel(
        circuitName: "c", name: "reg", components: [component],
        me: component.attributeSet, factory: stub))
    // A different component with the same label does collide.
    let other = try makeComponent(stub, at: location(50, 0), label: "reg")
    XCTAssertFalse(
      Circuit.isCorrectLabel(
        circuitName: "c", name: "reg", components: [component],
        me: other.attributeSet, factory: stub))
  }
}

// MARK: - Wire store

final class CircuitWireStoreTests: XCTestCase {

  func testBoundsAreRecomputedAfterABorderRemoval() {
    let store = CircuitWireStore()
    store.add(Wire.create(location(0, 0), location(100, 0)))
    store.add(Wire.create(location(0, 0), location(0, 100)))
    XCTAssertEqual(store.wireBounds, Bounds.create(0, 0, 101, 101))

    store.remove(Wire.create(location(0, 0), location(100, 0)))
    XCTAssertEqual(store.wireBounds, Bounds.create(0, 0, 1, 101))
  }

  /// Bug-for-bug: an interior removal leaves the cached box too large, because upstream only
  /// invalidates when an endpoint sat within 2 units of the border.
  func testInteriorRemovalLeavesTheCachedBoxTooLarge() {
    let store = CircuitWireStore()
    store.add(Wire.create(location(0, 0), location(100, 0)))
    store.add(Wire.create(location(0, 0), location(0, 100)))
    store.add(Wire.create(location(50, 50), location(60, 50)))
    XCTAssertEqual(store.wireBounds, Bounds.create(0, 0, 101, 101))

    store.remove(Wire.create(location(50, 50), location(60, 50)))
    XCTAssertEqual(store.wireBounds, Bounds.create(0, 0, 101, 101))
  }

  func testEmptyStoreReportsEmptyBounds() {
    XCTAssertEqual(CircuitWireStore().wireBounds, Bounds.empty)
  }
}

// MARK: - D8

final class UnresolvedComponentTests: XCTestCase {

  /// The whole point of `OpaqueAttributeSet`: an unknown attribute name is accepted, not
  /// rejected, and its text survives untouched.
  func testOpaqueAttributesRoundTripVerbatim() throws {
    let set = OpaqueAttributeSet(bindings: [
      (name: "baud", value: "  9600  "),
      (name: "parity", value: "none"),
    ])
    let bindings = set.opaqueBindings
    XCTAssertEqual(bindings.map(\.name), ["baud", "parity"])
    XCTAssertEqual(bindings.map(\.value), ["  9600  ", "none"])

    // Whitespace is preserved; `forOpaque` is the one codec that does not scrub.
    guard let attribute = set.attribute(named: "baud") else {
      return XCTFail("attribute must be discoverable by name")
    }
    XCTAssertEqual(attribute.standardString(for: .opaque("  9600  ")), "  9600  ")
    XCTAssertTrue(set.containsAttribute(attribute))
  }

  /// Assigning a name the set has never seen creates it rather than throwing: the deliberate
  /// divergence from `FixedAttributeSet`.
  func testOpaqueSetAcceptsUnknownAttributes() throws {
    let set = OpaqueAttributeSet()
    let attribute = Attributes.forOpaque("whatever")
    try set.setRawValue(attribute, .opaque("x"))
    XCTAssertEqual(set.rawValue(attribute), .opaque("x"))
    XCTAssertEqual(set.attributes.count, 1)
  }

  /// An unresolved component is a real member of the circuit, it is ordered, counted and
  /// found by `contains`, while being inert everywhere else.
  func testUnresolvedComponentLivesInTheCircuit() throws {
    let circuit = try Circuit(name: "c")
    let factory = UnresolvedComponentFactory(name: "UART", sourceLibraryReference: "6")
    let attributes = factory.createAttributeSet() as! OpaqueAttributeSet
    attributes.setOpaqueValue("9600", forName: "baud")
    let component = try factory.createComponent(
      location: location(120, 40), attributes: attributes)

    try circuit.mutatorAdd(component)

    XCTAssertEqual(circuit.nonWires.count, 1)
    XCTAssertTrue(circuit.contains(component))
    XCTAssertEqual(component.factory.name, "UART")
    XCTAssertEqual(component.bounds, Bounds.empty)
    XCTAssertTrue(component.ends.isEmpty)
    XCTAssertFalse(component.contains(location(120, 40)))
  }

  /// The `<comp>` element is kept verbatim and detached, so it survives the source document.
  func testRawElementIsCopiedAndDetached() throws {
    let document = XMLDocument(rootElement: XMLElement(name: "circuit"))
    let element = XMLElement(name: "comp")
    element.addAttribute(XMLNode.attribute(withName: "lib", stringValue: "6") as! XMLNode)
    element.addAttribute(XMLNode.attribute(withName: "name", stringValue: "UART") as! XMLNode)
    document.rootElement()?.addChild(element)

    let factory = UnresolvedComponentFactory(name: "UART")
    let component = UnresolvedComponent(
      factory: factory, location: location(0, 0), attributes: OpaqueAttributeSet())
    component.absorb(componentElement: element)

    guard let raw = component.rawElement else { return XCTFail("element must be kept") }
    XCTAssertNil(raw.parent)
    XCTAssertEqual(raw.attribute(forName: "name")?.stringValue, "UART")
    XCTAssertEqual(raw.attribute(forName: "lib")?.stringValue, "6")
  }

  /// Nothing about an unresolved component is ever treated as "at its default", so the writer
  /// re-emits every attribute it read.
  func testNoAttributeIsEverAtItsDefault() {
    let factory = UnresolvedComponentFactory(name: "UART")
    XCTAssertNil(
      factory.defaultAttributeValue(
        Attributes.forOpaque("baud"), version: LogisimVersion(4, 1, 0)))
  }

  /// An unresolved component sets none of the `instanceof` capability flags, so the label rules,
  /// the clock list and the subcircuit-usage map all skip it.
  func testUnresolvedFactoryHasNoCapabilities() {
    let factory = UnresolvedComponentFactory(name: "UART")
    XCTAssertFalse(factory.isTunnel)
    XCTAssertFalse(factory.isPin)
    XCTAssertFalse(factory.isClock)
    XCTAssertNil(factory as? any SubcircuitFactory)
  }
}
