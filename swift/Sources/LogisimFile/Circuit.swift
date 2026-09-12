// Circuit.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.circuit.Circuit),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only.
// SPDX-License-Identifier: GPL-3.0-only
//
// ── Scope: the inert netlist ────────────────────────────────────────────────────────────────
//
// M2 is placement records only. What a circuit is here: an ordered set of components, a set of
// wires, a static attribute set, a subcircuit factory, and the label rules that fire while a
// `.circ` file is being read. Nothing simulates and nothing draws.
//
// Deliberately absent, each because the thing it needs is a later milestone rather than because
// it was overlooked:
//
//   | upstream member                                    | needs                        | when |
//   |----------------------------------------------------|------------------------------|------|
//   | `getComponents(Location)`, `getExclusive`, | `CircuitPoints` connectivity | M3   |
//   | `getNonWires(Location)`, `getSplitCauses`, |                              |      |
//   | `getAllLocations`, `getWidth`, `getWires(Location)`,|                              |      |
//   | `getWireSet`, `isConnected`, `hasConflict`, |                              |      |
//   | `isDoubleMapped`, `getWidthIncompatibilityData`     |                              |      |
//   | `getLocker`, `EndChangedTransaction`               | `CircuitLocker` transactions | M3   |
//   | `doTestBench`, `TimeoutSimulation`                  | `Simulator`, `CircuitState`  | M3   |
//   | `draw`, `drawComponents`, `getBounds(Graphics)`, | AWT / `RenderScene` (D6, D9) | M6   |
//   | `getAllWithin(bds, g)`                              |                              |      |
//
// `getAllContaining(pt, g)` left that table on 2026-09-06 (board #84). It was listed as needing
// AWT, and it does not: the `Graphics` is only ever read for `FontMetrics`, so the port takes a
// metrics source instead. See `ComponentTextFieldMetrics` at the foot of this file; the seam is
// what keeps `LogisimFile` free of a measuring dependency while still answering the question.
//   | `getAppearance`, `recalcDefaultShape`               | `CircuitAppearance`          | M6   |
//   | `annotate`, `getAnnotationName`                     | `Reporter`, `AutoLabel`, | M7   |
//   |                                                    | `SetAttributeAction`, HDL    |      |
//   | `getNetList`, `getBoardMap`, `setBoardMap`, | FPGA `Netlist`, | later|
//   | `getMappableBoards`                                 | `MappableResourcesContainer` |      |
//   | `getSocSimulationManager`                           | SoC                          | later|
//
// The board-map *data* is not absent, because dropping it would break byte-exact round-tripping:
// `XmlWriter.java:299` re-emits a `<boardmap>` for every board a circuit carries. It is kept
// verbatim instead of parsed; see `absorbBoardMap`.
//
// The custom `<appear>` element is kept the same way and for the same reason; see
// `absorbAppearance` / `rawAppearance`. `CircuitAppearance` is an M6 canvas model, but a circuit
// whose `<a name="appearance" val="custom"/>` survives while its shapes do not is strictly worse
// off than either alternative, so the element itself is carried across the milestone gap.
//
// ── D3 ownership ────────────────────────────────────────────────────────────────────────────
//
// `Circuit` owns: its components, its wires, its static attribute set, its subcircuit factory,
// and the listener tokens it holds on both. Everything pointing the other way is weak or
// unowned: `file`, `circuitsUsingThis` (weak on *both* sides), `CircuitEvent.circuit`,
// `CircuitAttributes.source`, `CircuitSubcircuitFactory.source`.
//
// `circuitsUsingThis` is the one site D3 singles out as a trap: upstream's `WeakHashMap` keyed
// on a component. Translating it to `NSMapTable.weakToStrongObjects()` compiles and leaks
// everything, because the key is pinned by the very cycle the weak map exists to escape. Here
// both halves are weak and the eviction owner is explicit: `Circuit.removeComponent`, reached
// from `CircuitSubcircuitFactory.removeComponent`, plus a purge on every read.
//
// ── D13 ─────────────────────────────────────────────────────────────────────────────────────
//
// `AttributeSet.setValue` throws, and `Circuit` writes attributes on three paths a `.circ` file
// reaches: constructing the static set, clearing a duplicate label on add, and clearing a
// colliding label in `removeWrongLabels`. All three propagate, so the loader can report a file
// error instead of dying. The one place an error cannot propagate is inside a listener callback,
// where Java throws an unchecked exception out of `setValue` into the caller, see
// `recordListenerError`.

import Foundation
import LogisimKernel

/// The seam for `com.cburch.logisim.file.LogisimFile`, which `Circuit` uses only for
/// `getProjName()`. Written as a protocol for the same reason `CircuitReference` is: the real
/// `LogisimFile` is a separate port, and `Circuit` must not have to wait for it.
public protocol CircuitFileReference: AnyObject {
  var name: String { get }
}

/// `com.cburch.logisim.circuit.Circuit`, the inert half.
public final class Circuit {

  // MARK: - Stored state

  /// `staticAttrs`; the set `<circuit>`'s own `<a>` children serialise. Owned.
  public let staticAttributes: any AttributeSet

  /// `comps`: a `LinkedHashSet<Component>`: insertion-ordered, deduplicated by
  /// `Component.equals`, which for everything but `Wire` is reference identity (D4). Owned.
  private var componentOrder: [any Component] = []
  private var componentIdentities: Set<ObjectIdentifier> = []

  /// `wires`; the storage half of `CircuitWires`; see `CircuitWireStore` for what is and is not
  /// in it at this milestone.
  private var wireStore = CircuitWireStore()

  /// `clocks`; components whose factory is `Clock`, kept as a separate list so the simulator
  /// does not rescan. Populated through `ComponentFactory.isClock`.
  private var clockComponents: [any Component] = []

  /// `subcircuitFactory`. Owned; the factory's back edge to this circuit is `unowned`.
  private var subcircuitFactoryStorage: CircuitSubcircuitFactory!

  /// `logiFile`. D3: weak; the file owns its circuits.
  public weak var file: (any CircuitFileReference)?

  /// `isAnnotated`.
  public private(set) var isAnnotated = false

  /// The HDL type the label rules are evaluated under.
  ///
  /// D9: upstream calls `AppPreferences.HdlType.get()` from `Circuit.labelIdentity()`. The model
  /// may not read preferences, so this carries the shipped default (`VHDL`,
  /// `AppPreferences.java:556`) and the UI layer sets it when the user changes the preference.
  public var hdlType: String = CircuitLabelValidator.vhdlHdlType

  /// `Circuit.labelIdentity()`.
  public var labelIdentity: LabelIdentity {
    CircuitLabelValidator.labelIdentity(forHdlType: hdlType)
  }

  // MARK: Listeners

  /// `listeners`: `EventSourceWeakSupport`, i.e. weakly held. The caller keeps its listener
  /// alive; see `WeakListenerList`.
  private let listeners = WeakListenerList<CircuitListener>()

  /// `myComponentListener`. Owned by the circuit; its edge back is `unowned`.
  private var myComponentListener: CircuitComponentListener!

  /// Subscriptions taken on each added component, keyed by reference identity (D4).
  ///
  /// D3: `Component.addComponentListener` returns a token the *caller* must retain, and the
  /// component holds it weakly. Dropping the token here is exactly upstream's
  /// `removeComponentListener`.
  private var componentSubscriptions: [ObjectIdentifier: ComponentSubscription] = [:]

  /// The subscription on the static attribute set, standing in for `StaticListener`.
  private var staticAttributeSubscription: AttributeSubscription?
  private var staticAttributeListener: CircuitStaticAttributeListener!

  // MARK: Diagnostics

  /// Where the label rules report what upstream shows in an `OptionPane`.
  ///
  /// D9: the model must not raise dialogs, but the *decisions* those dialogs announce are model
  /// behaviour (a label gets cleared either way). Routing them through a reporter keeps the
  /// behaviour and moves only the presentation.
  public var diagnosticReporter: ((CircuitDiagnostic) -> Void)?

  /// The last error raised inside a listener callback.
  ///
  /// **Deviation, and why it is the least-bad one.** Java's listeners may throw unchecked
  /// exceptions, which propagate out of whatever called `setValue`: during load, into
  /// `XmlReader`, which records a file error. A Swift `AttributeListener` method cannot throw, so
  /// the error is recorded here and also handed to `diagnosticReporter`. It is surfaced, never
  /// swallowed, which is what D13 requires; it simply cannot be surfaced by unwinding.
  ///
  /// Every write that reaches this path is into a set that provably holds the attribute being
  /// written (the event that triggered it came from that same set), so it is unreachable in
  /// practice rather than merely unlikely.
  public private(set) var lastListenerError: Error?

  // MARK: Cross-circuit references

  /// `circuitsUsingThis`: the components elsewhere that instantiate this circuit, and the
  /// circuits they sit in. Both halves weak; see the file header.
  private struct UsageEntry {
    weak var component: AnyObject?
    weak var circuit: Circuit?
  }
  private var circuitsUsingThis: [UsageEntry] = []

  // MARK: Board maps

  private var boardMapOrder: [String] = []
  private var loadedMaps: [String: [String: CircuitMapInfo]] = [:]
  private var boardMapElementStore: [String: XMLElement] = [:]

  // MARK: Custom appearance

  /// The verbatim `<appear>` element, when the file carried one. See `absorbAppearance`.
  private var appearanceElementStore: XMLElement?

  // MARK: - Construction

  /// `Circuit(String, LogisimFile, Project)`.
  ///
  /// D13: `throws`, because `createBaseAttrs` and the `NAMED_CIRCUIT_BOX_FIXED_SIZE` write both
  /// go through `setValue`. `Project` does not come across; it is the editing layer (M7) and
  /// `Circuit` uses it only for `getCircuitState` (M3) and `setForcedDirty`.
  ///
  /// The two preference reads are parameters; see `CircuitAttributes`' header for why, and note
  /// the order is upstream's: `createBaseAttrs` writes the appearance and the name, and only then
  /// does the constructor write the fixed-size flag.
  public init(
    name: String,
    file: (any CircuitFileReference)? = nil,
    defaultAppearance: AttributeOption = CircuitAttributes.preferenceDefaultCircuitAppearance,
    namedCircuitBoxFixedSize: Bool = CircuitAttributes
      .preferenceDefaultNamedCircuitBoxFixedSize
  ) throws {
    self.staticAttributes = try CircuitAttributes.createBaseAttrs(
      name: name, defaultAppearance: defaultAppearance)
    self.file = file

    try staticAttributes.setValue(
      CircuitAttributes.namedCircuitBoxFixedSize, namedCircuitBoxFixedSize)

    self.subcircuitFactoryStorage = CircuitSubcircuitFactory(source: self)
    self.myComponentListener = CircuitComponentListener(circuit: self)
    self.staticAttributeListener = CircuitStaticAttributeListener(circuit: self)

    // Upstream attaches `StaticListener` inside `createBaseAttrs`, *after* the name is written,
    // so the initial name never fires an event. Same here.
    self.staticAttributeSubscription = staticAttributes.addAttributeListener(
      staticAttributeListener)
  }

  // MARK: - Access

  /// `getName()`.
  ///
  /// Java returns whatever `getValue(NAME_ATTR)` gives, which can be null; every caller then
  /// null-checks or does not. The port substitutes `""`, which is the value the attribute is
  /// initialised to anyway; the null case is only reachable by explicitly writing null.
  public var name: String {
    staticAttributes[CircuitAttributes.nameAttribute] ?? ""
  }

  /// `setName(String)`.
  public func setName(_ newName: String) throws {
    try staticAttributes.setValue(CircuitAttributes.nameAttribute, newName)
  }

  /// `getSubcircuitFactory()`.
  public var subcircuitFactory: any SubcircuitFactory { subcircuitFactoryStorage }

  /// `getProjName()`.
  public var projectName: String { file?.name ?? "" }

  /// `getNonWires()`: insertion-ordered, unlike upstream's `LinkedHashSet` only in that it is
  /// addressable by index.
  public var nonWires: [any Component] { componentOrder }

  /// `getWires()`.
  public var wires: [Wire] { wireStore.wires }

  /// `getClocks()`.
  public var clocks: [any Component] { clockComponents }

  /// `getComponents()`: upstream's unmodifiable union view, materialised. Components first,
  /// then wires, matching `CollectionUtil.createUnmodifiableSetUnion(comps, wires.getWires())`.
  public var components: [any Component] {
    var all: [any Component] = componentOrder
    all.append(contentsOf: wireStore.wires.map { $0 as any Component })
    return all
  }

  /// `contains(Component)`.
  ///
  /// Note the two different equalities, both upstream's: components match by reference identity
  /// (D4), wires by endpoints (`Wire` is the one component with structural equality).
  public func contains(_ component: any Component) -> Bool {
    if componentIdentities.contains(ObjectIdentifier(component)) { return true }
    if let wire = component as? Wire { return wireStore.contains(wire) }
    return false
  }

  /// `getAllContaining(Location)`.
  public func allContaining(_ point: Location) -> [any Component] {
    components.filter { $0.contains(point) }
  }

  /// `getAllContaining(Location, Graphics)` (`Circuit.java:524-530`).
  ///
  /// The *other* predicate; see `ComponentTextFieldMetrics` for why there are two, why the
  /// difference is not cosmetic, and why the second argument is a metrics source rather than a
  /// `Graphics`.
  public func allContaining(
    _ point: Location, metrics: any ComponentTextFieldMetrics
  ) -> [any Component] {
    components.filter { metrics.contains($0, point) }
  }

  /// `getAllWithin(Bounds)`.
  public func allWithin(_ bounds: Bounds) -> [any Component] {
    components.filter { bounds.contains($0.bounds) }
  }

  /// `getBounds()`.
  ///
  /// Bug-for-bug: the union with the wire box is skipped whenever the wire box has a zero
  /// dimension: including the legitimate case of a circuit whose only wires are collinear, which
  /// `recomputeBounds` gives a 1-thick box, so in practice this only skips the genuinely empty
  /// one. With no components at all the wire box is returned directly, zero dimension or not.
  public var bounds: Bounds {
    let wireBounds = wireStore.wireBounds
    guard let first = componentOrder.first else { return wireBounds }

    let firstBounds = first.bounds
    var xMin = firstBounds.x
    var yMin = firstBounds.y
    var xMax = wrap32(xMin &+ firstBounds.width)
    var yMax = wrap32(yMin &+ firstBounds.height)
    for component in componentOrder.dropFirst() {
      let box = component.bounds
      let x0 = box.x
      let x1 = wrap32(x0 &+ box.width)
      let y0 = box.y
      let y1 = wrap32(y0 &+ box.height)
      if x0 < xMin { xMin = x0 }
      if x1 > xMax { xMax = x1 }
      if y0 < yMin { yMin = y0 }
      if y1 > yMax { yMax = y1 }
    }
    let componentBounds = Bounds.create(
      xMin, yMin, wrap32(xMax &- xMin), wrap32(yMax &- yMin))
    return (wireBounds.width == 0 || wireBounds.height == 0)
      ? componentBounds
      : componentBounds.add(wireBounds)
  }

  /// `getWireBusWidthPos(Wire)`; `BUS_WIDTH_POS_NONE` when the wire has no stored position.
  public func getWireBusWidthPos(_ wire: Wire) -> AttributeOption {
    wireStore.busWidthPosition(of: wire)
  }

  /// Swift-shaped spelling of `getWireBusWidthPos`. Both exist so a call site can read either
  /// as the Java it came from or as ordinary Swift; they are the same lookup.
  public func busWidthPosition(of wire: Wire) -> AttributeOption {
    getWireBusWidthPos(wire)
  }

  /// `setWireBusWidthPos(Wire, AttributeOption)`: sets, then invalidates the wire.
  public func setWireBusWidthPos(_ wire: Wire, _ position: AttributeOption?) {
    wireStore.setBusWidthPosition(position, of: wire)
    fireEvent(.invalidate, .component(wire))
  }

  /// Swift-shaped spelling of `setWireBusWidthPos`, for call sites that read better with the
  /// wire second. Identical behaviour; both exist so neither the Java name nor the Swift one has
  /// to be the loser.
  public func setBusWidthPosition(_ position: AttributeOption?, of wire: Wire) {
    setWireBusWidthPos(wire, position)
  }

  // MARK: - Tick, download frequency and board

  /// `getTickFrequency()` / `setTickFrequency(double)`.
  ///
  /// The `proj.setForcedDirty()` upstream performs on change is the editing layer (M7); the
  /// guard that precedes it, only mark dirty when the *previous* frequency was positive, is
  /// preserved in `tickFrequencyChangeMarksDirty` so M7 does not have to rediscover it.
  public var tickFrequency: Double {
    staticAttributes[CircuitAttributes.simulationFrequency] ?? -1
  }

  /// True when upstream would have called `proj.setForcedDirty()` for this change.
  public private(set) var tickFrequencyChangeMarksDirty = false

  public func setTickFrequency(_ value: Double) throws {
    let current = tickFrequency
    guard value != current else { return }
    try staticAttributes.setValue(CircuitAttributes.simulationFrequency, value)
    tickFrequencyChangeMarksDirty = current > 0
  }

  /// `getDownloadFrequency()` / `setDownloadFrequency(double)`.
  public var downloadFrequency: Double {
    staticAttributes[CircuitAttributes.downloadFrequency] ?? -1
  }

  public func setDownloadFrequency(_ value: Double) throws {
    guard value != downloadFrequency else { return }
    try staticAttributes.setValue(CircuitAttributes.downloadFrequency, value)
  }

  /// `getDownloadBoard()` / `setDownloadBoard(String)`.
  public var downloadBoard: String {
    staticAttributes[CircuitAttributes.downloadBoard] ?? ""
  }

  public func setDownloadBoard(_ board: String) throws {
    guard board != downloadBoard else { return }
    try staticAttributes.setValue(CircuitAttributes.downloadBoard, board)
  }

  // MARK: - Board maps

  /// `addLoadedMap(String, Map<String, CircuitMapInfo>)`.
  ///
  /// `rawElement` has no upstream counterpart and is the reason board maps survive a round trip
  /// at this milestone. Upstream re-*generates* each `<mc>` from `MapComponent.getMapElement` /
  /// `getComplexMap`, which is FPGA data-model code well outside M2, so the element is kept
  /// verbatim and re-emitted by `boardMapElement(forBoard:)`. M2's pass condition
  /// is byte-exact round-tripping and `XmlWriter.java:299` writes one `<boardmap>` per board, so
  /// without this every file carrying one would fail the gate.
  ///
  /// The parsed map is kept too, and is the authority for `getMapInfo`; that is the Java-faithful
  /// model, and the FPGA tranche replaces the verbatim half rather than the parsed one.
  ///
  /// Copies are detached because the source document is released once the load finishes and
  /// Foundation's DOM nodes do not outlive their document safely; the same precaution
  /// `MissingLibrary.absorb` takes.
  public func addLoadedMap(
    _ boardName: String,
    _ map: [String: CircuitMapInfo],
    rawElement: XMLElement? = nil
  ) {
    if loadedMaps[boardName] == nil && boardMapElementStore[boardName] == nil {
      boardMapOrder.append(boardName)
    }
    loadedMaps[boardName] = map
    if let rawElement, let duplicate = rawElement.copy() as? XMLElement {
      duplicate.detach()
      boardMapElementStore[boardName] = duplicate
    }
  }

  /// `addLoadedMap` for a reader that has the `<mc>` children rather than the whole
  /// `<boardmap>`. They are wrapped in a fresh `<boardmap boardname="…">` so the two entry
  /// points store the same shape and the writer has one thing to re-emit.
  public func addLoadedMap(
    _ boardName: String,
    _ map: [String: CircuitMapInfo],
    rawElements: [XMLElement]
  ) {
    guard !rawElements.isEmpty else {
      addLoadedMap(boardName, map)
      return
    }
    let wrapper = XMLElement(name: "boardmap")
    wrapper.addAttribute(
      XMLNode.attribute(withName: "boardname", stringValue: boardName) as! XMLNode)
    for element in rawElements {
      guard let duplicate = element.copy() as? XMLElement else { continue }
      duplicate.detach()
      wrapper.addChild(duplicate)
    }
    addLoadedMap(boardName, map, rawElement: wrapper)
  }

  /// `getMapInfo(String)`.
  ///
  /// Upstream consults `myMappableResources` first and falls back to `loadedMaps`; the
  /// `MappableResourcesContainer` half is live FPGA-mapping state that only exists once the user
  /// opens the mapping dialog, so at this milestone only the loaded half can be populated and the
  /// fallback is the whole method.
  public func getMapInfo(_ boardName: String) -> [String: CircuitMapInfo] {
    loadedMaps[boardName] ?? [:]
  }

  /// `getBoardMapNamestoSave()`. Upstream returns a `HashSet`; this preserves read order, which
  /// `XmlWriter.sort` normalises anyway.
  public var boardMapNamesToSave: [String] { boardMapOrder }

  /// The verbatim `<boardmap>` element read for a board, or nil when the reader supplied only
  /// the parsed map, in which case that board cannot yet be written back. See `absorbBoardMap`.
  public func boardMapElement(forBoard boardName: String) -> XMLElement? {
    boardMapElementStore[boardName]
  }

  /// The verbatim `<mc>` children of that element, for a writer that assembles `<boardmap>`
  /// itself rather than re-emitting it whole.
  public func rawBoardMapElements(forBoard boardName: String) -> [XMLElement] {
    guard let element = boardMapElementStore[boardName] else { return [] }
    return (element.children ?? []).compactMap { $0 as? XMLElement }
  }

  /// Alias of `rawBoardMapElements(forBoard:)`.
  public func rawBoardMapEntries(forBoard boardName: String) -> [XMLElement] {
    rawBoardMapElements(forBoard: boardName)
  }

  /// Records a whole `<boardmap>` element, keeping its `<mc>` children verbatim.
  ///
  /// The reader's other entry point. `addLoadedMap` stores the *parsed* `CircuitMapInfo` map,
  /// which is Java's model and is what `getMapInfo` answers; this stores the elements the writer
  /// re-emits, because `MapComponent.getMapElement`, the code that would regenerate them, is
  /// FPGA-tranche work. Calling both for the same board is expected and they do not conflict.
  ///
  /// A `<boardmap>` with no `boardname` is ignored, matching the reader's own guard.
  public func absorbBoardMap(_ element: XMLElement) {
    guard let boardName = element.attribute(forName: "boardname")?.stringValue,
      !boardName.isEmpty
    else { return }
    guard let duplicate = element.copy() as? XMLElement else { return }
    duplicate.detach()
    if loadedMaps[boardName] == nil && boardMapElementStore[boardName] == nil {
      boardMapOrder.append(boardName)
    }
    boardMapElementStore[boardName] = duplicate
  }

  // MARK: - Custom appearance

  /// The verbatim `<appear>` element read for this circuit, or `nil` when the file carried none.
  ///
  /// Upstream's model here is `CircuitAppearance`, a live `CanvasModel` of `AbstractCanvasObject`s
  /// that `XmlWriter.java` re-*generates* through `CircuitAppearance.toSvgElement`. That whole
  /// layer is M6 (D6), and a circuit that declares `<a name="appearance" val="custom"/>` while
  /// having no `<appear>` to go with it is not a circuit upstream can produce, so dropping the
  /// element is a data loss the attribute then advertises.
  ///
  /// This is the same treatment `<boardmap>` gets, and for the same reason: the element is kept
  /// byte-for-byte rather than parsed, because the code that would regenerate it belongs to a
  /// later milestone, and M2's pass condition is byte-exact round-tripping.
  ///
  /// Read by the writer; written by the reader through `absorbAppearance(_:)`.
  public var rawAppearance: XMLElement? { appearanceElementStore }

  /// Records the `<appear>` element verbatim.
  ///
  /// The counterpart of `absorbBoardMap(_:)`, down to the detached copy: the source document is
  /// released once the load finishes and Foundation's DOM nodes do not outlive their document
  /// safely.
  ///
  /// Upstream reads `<appear>` twice: `XmlReader.loadAppearance` for the *dynamic* elements
  /// (`DynamicElement`s bound to components, `XmlReader.java`) and
  /// `XmlCircuitReader.buildDynamicAppearance` for the static shapes. Neither survives at this
  /// milestone, so both callers may hand the same element here; the last one wins and the stored
  /// copy is identical either way. A circuit has at most one `<appear>`, which is why this is a
  /// single slot rather than the keyed store board maps need.
  public func absorbAppearance(_ element: XMLElement) {
    guard let duplicate = element.copy() as? XMLElement else { return }
    duplicate.detach()
    appearanceElementStore = duplicate
  }

  /// Forgets the stored `<appear>`. Exists so a future `CircuitAppearance` (M6) has an explicit
  /// way to take ownership once it can regenerate the element, rather than leaving a stale copy
  /// to be emitted alongside a live model.
  public func clearRawAppearance() {
    appearanceElementStore = nil
  }

  // MARK: - Circuits using this one

  /// `getCircuitsUsingThis()`. Purges cleared entries as it reads; the explicit eviction D3
  /// requires of every weak-collection site.
  public var circuitsUsingThisCircuit: [Circuit] {
    purgeUsageEntries()
    return circuitsUsingThis.compactMap(\.circuit)
  }

  /// `Circuit.removeComponent(Component)`; the misleadingly named method that only evicts from
  /// `circuitsUsingThis`. It removes nothing from the circuit; `mutatorRemove` does that.
  public func removeComponent(_ component: any Component) {
    circuitsUsingThis.removeAll { $0.component == nil || $0.component === component }
  }

  fileprivate func registerCircuitUsing(component: any Component, in circuit: Circuit) {
    purgeUsageEntries()
    circuitsUsingThis.removeAll { $0.component === component }
    circuitsUsingThis.append(UsageEntry(component: component, circuit: circuit))
  }

  private func purgeUsageEntries() {
    circuitsUsingThis.removeAll { $0.component == nil || $0.circuit == nil }
  }

  // MARK: - Annotation level

  /// `clearAnnotationLevel()`, minus the `myNetList.clear()` the FPGA netlist needs.
  public func clearAnnotationLevel() {
    isAnnotated = false
    for component in componentOrder {
      if let sub = component.factory as? any SubcircuitFactory,
        let subCircuit = sub.subcircuit as? Circuit
      {
        subCircuit.clearAnnotationLevel()
      }
    }
  }

  // MARK: - Events

  /// `addCircuitListener` / `removeCircuitListener`.
  public func addCircuitListener(_ listener: CircuitListener) { listeners.add(listener) }
  public func removeCircuitListener(_ listener: CircuitListener) { listeners.remove(listener) }

  /// `fireEvent(int, Object)`.
  public func fireEvent(_ action: CircuitEventAction, _ data: CircuitEventData) {
    let event = CircuitEvent(action: action, circuit: self, data: data)
    for listener in listeners.current() {
      listener.circuitChanged(event)
    }
  }

  /// `displayChanged()`.
  public func displayChanged() { fireEvent(.displayChange, .none) }

  fileprivate func report(_ diagnostic: CircuitDiagnostic) {
    diagnosticReporter?(diagnostic)
  }

  fileprivate func recordListenerError(_ error: Error) {
    lastListenerError = error
    diagnosticReporter?(.listenerError(error))
  }

  /// `MyComponentListener.endChanged`'s `isAnnotated = false`. A separate method because
  /// `isAnnotated` is `private(set)`, which the listener, a different type, cannot reach.
  fileprivate func clearAnnotationFlagForEndChange() {
    isAnnotated = false
  }

  // MARK: - Mutation

  /// `mutatorAdd(Component)`.
  ///
  /// D13: `throws`, because the duplicate-label clearing writes an attribute and that write can
  /// fail on a component whose set rejects `label`. That path runs *during load*, which is
  /// exactly the case D13 exists for.
  ///
  /// Three early returns are upstream's and each skips both `removeWrongLabels` and the
  /// `ACTION_ADD` event: a degenerate wire (both endpoints equal), a duplicate wire, and a
  /// duplicate component.
  ///
  /// `wires.add(c)` for a non-wire, which registers the component's ends with `CircuitPoints`
  /// and classifies tunnels, pull resistors and splitters, is M3 connectivity and is not called.
  /// Nothing in the inert model reads what it would have written.
  public func mutatorAdd(_ component: any Component) throws {
    isAnnotated = false

    if let wire = component as? Wire {
      if wire.end0 == wire.end1 { return }
      guard wireStore.add(wire) else { return }
    } else {
      guard componentIdentities.insert(ObjectIdentifier(component)).inserted else { return }
      componentOrder.append(component)

      try clearDuplicateLabel(on: component)

      let factory = component.factory
      if factory.isClock {
        clockComponents.append(component)
      } else if let sub = factory as? any SubcircuitFactory,
        let subCircuit = sub.subcircuit as? Circuit
      {
        subCircuit.registerCircuitUsing(component: component, in: self)
      }
      // Upstream also calls `Rom.closeHexFrame(c)` (a UI window, M5) and
      // `VhdlEntity.addCircuitUsing(c, this)` (M5's VHDL entity, whose usage map is the exact
      // analogue of `circuitsUsingThis` and will be wired the same way).

      if let token = component.addComponentListener(myComponentListener) {
        componentSubscriptions[ObjectIdentifier(component)] = token
      }
    }

    // Outside the branch upstream too, so a wire triggers this with the factory name "Wire".
    try removeWrongLabels(component.factory.name)
    fireEvent(.add, .component(component))
  }

  /// The duplicate-label block inside `mutatorAdd`.
  ///
  /// Note the scan runs over `comps` *after* `c` has been inserted, and skips `c` by identity,
  /// so a component never collides with itself. Tunnels are exempt on both sides of the
  /// comparison, since a tunnel's label is its network name and duplicates are the point.
  ///
  /// ── This follows **v4.1.0**, not upstream `main`, and the difference is observable ─────────
  ///
  /// v4.1.0 builds a set of `label.toUpperCase()` and then adds the circuit's name **raw**:
  ///
  /// ```java
  /// if (StringUtil.isNotEmpty(label)) labels.add(label.toUpperCase());
  /// /* we also have to check for the entity name */
  /// if (getName() != null && !getName().isEmpty()) labels.add(getName()); // not uppercased
  /// if (StringUtil.isNotEmpty(label) && labels.contains(label.toUpperCase())) …
  /// ```
  ///
  /// The lookup uppercases but that one insertion does not, so a label collides with the circuit
  /// name **only when the circuit name is already entirely uppercase**. A circuit named `counter`
  /// keeps a component labelled `Counter`; a circuit named `COUNTER` clears it.
  ///
  /// `main` rewrote this into an explicit `labelsMatch(getName(), label, …)`, making the
  /// comparison case-insensitive in both directions. That is a *behaviour change*, not a
  /// refactor: it clears labels 4.1.0 keeps.
  ///
  /// D0 targets 4.1.0 and the differential oracle is the shipped 4.1.0 jar, so the 4.1.0 rule is
  /// the one reproduced. Porting `main`'s version instead would silently blank labels on load and
  /// diverge from the oracle on the very first file with a lowercase circuit name: a load→save
  /// data change, which is the worst class of round-trip bug.
  private func clearDuplicateLabel(on component: any Component) throws {
    let attributes = component.attributeSet
    guard attributes.containsAttribute(StdAttr.label), !component.factory.isTunnel else { return }

    var labels: Set<String> = []
    for other in componentOrder {
      if other === component || other.factory.isTunnel { continue }
      guard other.attributeSet.containsAttribute(StdAttr.label) else { continue }
      let label = other.attributeSet[StdAttr.label] ?? ""
      if !label.isEmpty {
        labels.insert(label.uppercased())
      }
    }
    // Raw, exactly as v4.1.0 inserts it. See the doc comment.
    let circuitName = name
    if !circuitName.isEmpty { labels.insert(circuitName) }

    let label = attributes[StdAttr.label] ?? ""
    guard !label.isEmpty else { return }
    if labels.contains(label.uppercased()) {
      try attributes.setValue(StdAttr.label, "")
    }
  }

  /// `mutatorRemove(Component)`.
  ///
  /// D13: not `throws`, because upstream's body writes no attributes. `proj.getCircuitState(this)`
  /// is M3, so `removeComponent` is passed `nil`; every stock factory ignores the argument
  /// (`AbstractComponentFactory` calls itself a "dummy factory"), and the ones that do not are
  /// M5 memory/IO components.
  public func mutatorRemove(_ component: any Component) {
    isAnnotated = false

    if let wire = component as? Wire {
      wireStore.remove(wire)
    } else {
      componentIdentities.remove(ObjectIdentifier(component))
      if let index = componentOrder.firstIndex(where: { $0 === component }) {
        componentOrder.remove(at: index)
      }
      let factory = component.factory
      factory.removeComponent(from: self, component: component, state: nil)
      if factory.isClock {
        if let index = clockComponents.firstIndex(where: { $0 === component }) {
          clockComponents.remove(at: index)
        }
      }
      // `DynamicElementProvider.removeDynamicElements` is appearance-side (M6).
      componentSubscriptions.removeValue(forKey: ObjectIdentifier(component))
    }
    fireEvent(.remove, .component(component))
  }

  /// `mutatorClear()`.
  ///
  /// Upstream replaces the whole `CircuitWires` object, which also discards the bus-width
  /// positions and the bounds cache; `removeAll()` does the same. The event carries the old
  /// component set, so listeners can undo against it.
  public func mutatorClear() {
    let oldComponents = componentOrder
    componentOrder = []
    componentIdentities = []
    wireStore.removeAll()
    clockComponents.removeAll()
    componentSubscriptions.removeAll()
    isAnnotated = false

    for component in oldComponents {
      component.factory.removeComponent(from: self, component: component, state: nil)
    }
    fireEvent(.clear, .components(oldComponents))
  }

  /// `removeWrongLabels(String)`.
  ///
  /// Clears the label of every component whose label matches the *factory name* just added, so
  /// placing an `AND` gate blanks the label of anything labelled "and". Wires are skipped because
  /// "Wire" is a reserved keyword and wires carry no label, which is upstream's own comment.
  ///
  /// D13: `throws`. The dialog upstream shows becomes a `.labelCollision` diagnostic.
  @discardableResult
  public func removeWrongLabels(_ label: String) throws -> Bool {
    var changed = false
    let identity = labelIdentity
    for component in componentOrder {
      let attributes = component.attributeSet
      guard attributes.containsAttribute(StdAttr.label) else { continue }
      let componentLabel = attributes[StdAttr.label] ?? ""
      if CircuitLabelValidator.labelsMatch(label, componentLabel, identity) {
        try attributes.setValue(StdAttr.label, "")
        changed = true
      }
    }
    if changed { report(.labelCollision(label)) }
    return changed
  }

  // MARK: - Label validation

  /// `isCorrectLabel(String, String, Set<Component>, AttributeSet, ComponentFactory,
  /// LabelIdentity, Boolean)`.
  ///
  /// `showDialog` becomes a reporter, so the decision is unchanged and only the presentation
  /// moves out of the model (D9). Passing `nil` is upstream's `showDialog = false`.
  public static func isCorrectLabel(
    circuitName: String?,
    name: String,
    components: [any Component],
    me: (any AttributeSet)?,
    factory: any ComponentFactory,
    labelIdentity identity: LabelIdentity = .hdlCompatible,
    reporter: ((CircuitDiagnostic) -> Void)? = nil
  ) -> Bool {
    if factory.isTunnel { return true }
    if let circuitName, !circuitName.isEmpty,
      CircuitLabelValidator.labelsMatch(circuitName, name, identity), factory.isPin
    {
      reporter?(.componentLabelEqualsCircuitName(name))
      return false
    }
    return !(isExistingLabel(
      name: name, me: me, components: components, identity: identity, reporter: reporter)
      || isComponentName(
        name: name, components: components, identity: identity, reporter: reporter))
  }

  /// `isComponentName(...)`; a label may not be the *name of a component type*.
  private static func isComponentName(
    name: String,
    components: [any Component],
    identity: LabelIdentity,
    reporter: ((CircuitDiagnostic) -> Void)?
  ) -> Bool {
    if name.isEmpty { return false }
    for component in components {
      if CircuitLabelValidator.labelsMatch(component.factory.name, name, identity) {
        reporter?(.labelIsComponentName(name))
        return true
      }
    }
    return false
  }

  /// `isExistingLabel(...)`.
  ///
  /// `!comp.getAttributeSet().equals(me)` is reference identity: `AttributeSet` overrides
  /// neither `equals` nor `hashCode`, which D4 also requires of the port. So this is `!==`, and
  /// making it structural would let a component collide with itself.
  private static func isExistingLabel(
    name: String,
    me: (any AttributeSet)?,
    components: [any Component],
    identity: LabelIdentity,
    reporter: ((CircuitDiagnostic) -> Void)?
  ) -> Bool {
    if name.isEmpty { return false }
    for component in components {
      let attributes = component.attributeSet
      guard !(attributes === me), !component.factory.isTunnel else { continue }
      // Java reads `getValue(LABEL)` unguarded once `containsAttribute` passes, so a set that
      // contains the attribute but holds null would NPE there; `?? ""` is the same answer the
      // absent branch already gives.
      let label = attributes.containsAttribute(StdAttr.label)
        ? (attributes[StdAttr.label] ?? "") : ""
      if CircuitLabelValidator.labelsMatch(label, name, identity) {
        reporter?(.labelAlreadyUsed(name))
        return true
      }
    }
    return false
  }

  /// `Circuit.isInput(Component)`: a package helper, kept because M3's wiring code calls it.
  ///
  /// Bug-for-bug: the name is backwards. It returns true when end 0 is *not* input-only, i.e.
  /// when the component drives that end.
  public static func isInput(_ component: any Component) -> Bool {
    component.end(at: 0).type != EndType.inputOnly
  }
}

// MARK: - The two-argument `contains`

/// The `Graphics` argument of `Component.contains(Location, Graphics)`, reduced to the one thing
/// either caller uses it for.
///
/// ── WHY THERE ARE TWO `contains` PREDICATES UPSTREAM, AND WHAT THE SECOND ONE BUYS ──────────
///
/// `InstanceComponent` declares both (`InstanceComponent.java:216-226`):
///
/// ```java
/// public boolean contains(Location pt)
/// public boolean contains(Location pt, Graphics g) {
///   final var field = textField;
///   return (field != null && field.getBounds(g).contains(pt)) ? true : contains(pt);
/// }
/// ```
///
/// The two-argument one is true for a point inside the component's **label box** even when that
/// box is nowhere near the body, which is the normal case, because the default label placement
/// for most factories is above the body (`bds.y - 3`, `H_CENTER`) and therefore entirely outside
/// `getBounds()`. `TextTool.mousePressed` looks components up through it (`TextTool.java:282`,
/// and the selection scan at `:267`), and it is the only reason clicking a label edits that
/// label instead of dropping a stray `Text` annotation on the sheet.
///
/// ── WHY A METRICS SOURCE AND NOT A `Graphics` ───────────────────────────────────────────────
///
/// There is no `Graphics` in this port at all (D6); upstream reaches one purely for its
/// `FontMetrics`, because `TextField.getBounds(Graphics)` needs an ascent, a descent and a
/// string width. `LogisimRender.TextMeasurer` is that, and `TextField.bounds(measurer:)` already
/// takes one.
///
/// **`LogisimFile` cannot name `TextMeasurer`**; it depends on `LogisimKernel` and `LogisimDraw`
/// and on nothing that draws or measures, and widening that edge to make one method compile is
/// exactly what D9 forbids. So the dependency is inverted into this one-method seam: the module
/// that *does* own both a measurer and the components with text fields (`LogisimStd`, via
/// `StdComponentTextFieldMetrics`) supplies the answer, and `Circuit` only asks. The same shape
/// `SelectionCircuitQueries` uses, and for the same reason.
///
/// Which measurer is not a free choice: it must be the one the label was *drawn* with, or the box
/// a click is tested against is not the box the user sees. `InstanceTextField.canvasMeasurer` is
/// already that one, `textCaret` hit-tests with it, so `LogisimUI` passes it here too.
///
/// ── WHY THE PREDICATE HANGS HERE AND NOT ON `Component` ─────────────────────────────────────
///
/// Upstream declares both overloads on `Component` (`Component.java:27`) and has exactly three
/// implementors of the two-argument one: checked, not assumed:
///
///   * `Wire.java:129-131`: `return contains(pt);`
///   * `AbstractComponent.java:26-30`: `getBounds(g).contains(pt, 1)`, and its own
///     `getBounds(Graphics)` (`:40-43`) is `return getBounds()`, so this too is the one-argument
///     answer. `Splitter` and `std.io.Video` are the only components that reach it.
///   * `InstanceComponent.java:223-226`; the one that differs.
///
/// So the second overload is the same predicate as the first everywhere except on a component
/// with a text field. Adding it to this port's `Component` protocol would oblige four conformers
/// to answer a question that has meaning for one, *and* the one that has an answer needs a
/// measurer to give it, which is the type `LogisimFile` cannot name. The fork therefore lives on
/// the seam: the module that owns both supplies it, everything else falls through the default
/// below, which is upstream's own trivial arm.
///
/// Nothing here is class-constrained: the conformer is a value carrying a measurer.
public protocol ComponentTextFieldMetrics {
  /// `Component.contains(Location, Graphics)`.
  ///
  /// The default implementation is upstream's own `contains(pt, g) { return contains(pt); }`;
  /// the answer for every component that has no text field, and therefore the correct answer for
  /// a `Wire` or a placement record whatever the conformer is.
  func contains(_ component: any Component, _ point: Location) -> Bool
}

extension ComponentTextFieldMetrics {
  public func contains(_ component: any Component, _ point: Location) -> Bool {
    component.contains(point)
  }
}

// MARK: - Seam conformances

extension Circuit: CircuitReference {}

/// `XmlWriter`'s view of a circuit. Every member is an existing accessor under the name the
/// writer's protocol gives it; nothing new is computed here.
extension Circuit: CircuitSaving {
  public var savedName: String { name }
  public var savedStaticAttributes: any AttributeSet { staticAttributes }
  public var savedWires: [Wire] { wires }
  public var savedNonWires: [any Component] { nonWires }

  /// The writer wants `nil` where Java returns null. Java's `getWireBusWidthPos` never returns
  /// null, it defaults to `BUS_WIDTH_POS_NONE`, and the writer then skips `NONE`, so mapping
  /// `NONE` to `nil` here is the same test written once instead of twice.
  public func savedWireBusWidthPos(_ wire: Wire) -> AttributeOption? {
    let position = getWireBusWidthPos(wire)
    return position == Wire.busWidthPositionNone ? nil : position
  }
}

/// `XmlWriter`'s view of the board maps. See `addLoadedMap` for why the `<mc>` elements are
/// re-emitted verbatim rather than regenerated.
extension Circuit: CircuitBoardMapSaving {
  public var savedBoardMapNames: [String] { boardMapNamesToSave }

  public func savedBoardMapElements(forBoard board: String) -> [XMLElement] {
    rawBoardMapEntries(forBoard: board)
  }
}

/// `XmlWriter`'s view of the preserved `<appear>` element: the exact counterpart of
/// `CircuitBoardMapSaving` above, declared here for the same reason: the storage lives on
/// `Circuit`, so the conformance does too.
///
/// `appearanceElement` is the protocol's spelling of `rawAppearance`. Two names for one slot is
/// deliberate rather than sloppy: `rawAppearance`/`absorbAppearance(_:)` is the model's own API
/// and matches `rawBoardMapElements`/`absorbBoardMap(_:)`, while `appearanceElement` is the name
/// `XmlWriter` chose for its protocol. When `CircuitAppearanceWriter.handler` is installed at M6
/// this whole extension goes away and `rawAppearance` stays.
extension Circuit: CircuitAppearancePreserving {
  public var appearanceElement: XMLElement? { rawAppearance }
}

extension Circuit: CustomStringConvertible {
  /// `toString()` returns the name attribute.
  public var description: String { name }
}

// MARK: - Diagnostics

/// The things upstream announces with an `OptionPane` from inside the model.
///
/// D9 keeps dialogs out of this layer, but the events themselves are model behaviour and a
/// differential test wants to assert *which* rule fired. Each case names the upstream string key
/// it replaces.
public enum CircuitDiagnostic {
  /// `ComponentLabelEqualCircuitName`: a pin's label equals the circuit's own name.
  case componentLabelEqualsCircuitName(String)
  /// `ComponentLabelNameError`: a label collides with a component *type* name.
  case labelIsComponentName(String)
  /// `UsedLabelNameError`; a label is already in use in this circuit.
  case labelAlreadyUsed(String)
  /// `ComponentLabelCollisionError`: `removeWrongLabels` cleared at least one label.
  case labelCollision(String)
  /// `EmptyNameError`; a circuit rename to the empty string was rejected and reverted.
  case emptyCircuitName
  /// `CircuitSameInputOutputLabel`; a rename was rejected because a pin already has that label.
  case circuitNameMatchesPinLabel(String)
  /// See `Circuit.lastListenerError`: an error that Java would have thrown out of a listener.
  case listenerError(Error)
}

// MARK: - Circuit's own component listener

/// `Circuit.MyComponentListener`.
///
/// D3: owned by the circuit, with an `unowned` edge back. The circuit also retains the
/// subscription tokens, so the lifetime is entirely the circuit's.
final class CircuitComponentListener: ComponentListener {
  private unowned let circuit: Circuit

  init(circuit: Circuit) {
    self.circuit = circuit
  }

  func componentInvalidated(_ event: ComponentEvent) {
    circuit.fireEvent(.invalidate, .component(event.source))
  }

  /// `endChanged(ComponentEvent)`.
  ///
  /// Upstream computes the removed/added end maps and runs an `EndChangedTransaction` that
  /// updates `CircuitWires`' connectivity points. Both the transaction system and the points are
  /// M3. What survives is the part the inert model can honour: clearing the annotation flag and
  /// firing `ACTION_INVALIDATE`, which is what every non-simulation listener actually consumes.
  func endChanged(_ event: ComponentEvent) {
    circuit.clearAnnotationFlagForEndChange()
    circuit.fireEvent(.invalidate, .component(event.source))
  }

  /// `labelChanged(ComponentEvent)`.
  ///
  /// The rule: if the new label is not acceptable, revert to the old one, and if the *old* one
  /// is not acceptable either, blank it. Note the second `isCorrectLabel` call passes
  /// `showDialog = false`, so only the first failure is announced.
  func labelChanged(_ event: ComponentEvent) {
    guard let attributeEvent = event.data as? AttributeEvent else { return }
    guard let attribute = attributeEvent.attribute as? Attribute<String> else { return }
    guard let newLabel = attributeEvent.value(as: attribute) else { return }
    let oldLabel = attributeEvent.oldValue(as: attribute) ?? ""

    let source = attributeEvent.source
    let components = circuit.nonWires
    let identity = circuit.labelIdentity

    if !Circuit.isCorrectLabel(
      circuitName: circuit.name,
      name: newLabel,
      components: components,
      me: source,
      factory: event.source.factory,
      labelIdentity: identity,
      reporter: circuit.diagnosticReporter)
    {
      let replacement = Circuit.isCorrectLabel(
        circuitName: circuit.name,
        name: oldLabel,
        components: components,
        me: source,
        factory: event.source.factory,
        labelIdentity: identity,
        reporter: nil) ? oldLabel : ""
      do {
        try source.setValue(attribute, replacement)
      } catch {
        circuit.recordListenerError(error)
      }
    }
  }
}

// MARK: - Circuit's own static-attribute listener

/// `CircuitAttributes.StaticListener`.
///
/// What came across: the name-change guard, the empty-name rejection *and its revert*, the
/// pin-label collision rejection and revert, and the `ACTION_CHECK_NAME` / `ACTION_SET_NAME`
/// pair. Reverting is model behaviour, not presentation, so it is kept even though the dialog
/// that accompanies it is not.
///
/// What did not: `SyntaxChecker.isVariableNameAcceptableForCurrentHdl`, which reads
/// `AppPreferences.HdlType` (D9) and raises its own dialog. A name that is legal here but not a
/// legal VHDL identifier is therefore accepted where upstream would revert it. Recorded rather
/// than faked; the check belongs with the HDL layer that defines it.
///
/// Note the recursion upstream relies on: a revert is itself a `setValue`, which re-enters this
/// listener with the names swapped and falls through to the success branch, firing
/// `ACTION_CHECK_NAME` and `ACTION_SET_NAME` for the restored name.
final class CircuitStaticAttributeListener: AttributeListener {
  private unowned let circuit: Circuit

  init(circuit: Circuit) {
    self.circuit = circuit
  }

  func attributeValueChanged(_ event: AttributeEvent) {
    guard let attribute = event.attribute, attribute === CircuitAttributes.nameAttribute else {
      return
    }
    let newName = event.value(as: CircuitAttributes.nameAttribute) ?? ""
    // Upstream's literal placeholder for a null old value. It exists so the `equals` below is
    // false, which makes a first-ever assignment take the success path.
    let oldName = event.oldValue(as: CircuitAttributes.nameAttribute) ?? "ThisShouldNotHappen"
    guard newName != oldName else { return }

    if newName.isEmpty {
      circuit.report(.emptyCircuitName)
      revert(to: oldName, on: event.source)
      return
    }

    let identity = circuit.labelIdentity
    for component in circuit.nonWires where component.factory.isPin {
      let label = component.attributeSet[StdAttr.label] ?? ""
      if !label.isEmpty, CircuitLabelValidator.labelsMatch(label, newName, identity) {
        circuit.report(.circuitNameMatchesPinLabel(newName))
        revert(to: oldName, on: event.source)
        return
      }
    }

    circuit.fireEvent(.checkName, .name(oldName))
    circuit.fireEvent(.setName, .name(newName))
  }

  private func revert(to oldName: String, on source: any AttributeSet) {
    do {
      try source.setValue(CircuitAttributes.nameAttribute, oldName)
    } catch {
      circuit.recordListenerError(error)
      return
    }
    circuit.fireEvent(.setName, .name(oldName))
  }
}
