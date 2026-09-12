// SocSimulationManager.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.soc.data.SocSimulationManager),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// One instance per `Circuit` (Java: `Circuit.getSocSimulationManager()`), tracking every SoC bus
// declared in that circuit by bus id and routing every `initializeTransaction` call to the right
// `SocBusFabric`. This is the "shared SocBusStateInfo-style helper" the task brief calls out.
//
// ── Not ported: the bus-picker dialog ────────────────────────────────────────────────────────
//
// `getGuiBusId()` pops a `JOptionPane` list of bus display names and returns the chosen id; it
// exists only so `SocBusSelectAttribute.getCellEditor`'s click handler (a `JLabel` in the
// attribute table) can let the user pick a bus interactively. That is a property-editor UI flow
// end to end (D9); this module exposes `busChoices` (id → display name) so the UI layer can
// build its own picker and then call `reRegisterSlaveSniffer`/mutate the component's `SocBusInfo`
// exactly as upstream's click handler did.
//
// ── Seam: `SOC_BUS_SELECT` needs a live `AttributeSet` at construction ──────────────────────────
//
// Java makes `SOC_BUS_SELECT` a `static final Attribute<SocBusInfo>` on this class specifically
// so every peripheral's `*Attributes` class can share one identity for it (attribute identity is
// how `AttributeSet.getValue`/`setValue` dispatch: see D4's note on `Component`/`AttributeSet`
// equality). Preserved verbatim: it lives here, not on each peripheral, and every peripheral
// `*Attributes.swift` file references `SocSimulationManager.SOC_BUS_SELECT` by identity.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimStd

/// `SocSimulationManager.SocBusSelectAttribute`'s payload plus the `<a>` codec; the shared
/// "which bus is this peripheral wired to" attribute every peripheral in this module exposes.
/// `parse`/`toStandardString` mirror Java's `new SocBusInfo(value)` / `value.getBusId()`.
///
/// ═══════════════════════════════════════════════════════════════════════════════════════════
/// `encode`/`decode` MUST PRESERVE OBJECT IDENTITY, and the string form silently did not
///
/// `SocBusInfo` is a `final class` for a documented reason (its own header): Java mutates it in
/// place, and `SocSimulationManager.registerComponent` reaches the live one through this
/// attribute to call `setSocSimulationManager(this, c)`. `AttributeSet.getValue` is
/// `rawValue(attr).flatMap(attr.decode)`, so with `encode → .string(busId)` /
/// `decode → SocBusInfo(id)` every read handed back a **brand-new object**. All eight
/// peripherals' `rawValue` already return their live `SocBusInfo`; the codec threw it away one
/// line later.
///
/// The consequence is total and silent. `registerComponent` attached the manager and the
/// component to a temporary that was discarded on the next line, so for every SoC peripheral
/// in every circuit:
///
///   * `SocBusInfo.simulationManager` and `.component` stayed `nil` forever;
///   * `SocMemoryState.getRegPropagateState()`, `manager.data(for: comp)`, therefore always
///     answered `nil`, and `performReadAction` fell through to its `rand.nextInt()` branch;
///   * `slaveName` answered `"BUG: Unknown"`;
///   * `handleTransaction` called `setTransactionResponder(nil)`.
///
/// So the memory could not store or return a single byte, and nothing failed: a read produced
/// a plausible random word, which is exactly the "silently-succeeding failed read produces a
/// plausible wrong program run" failure `SocBusTransaction`'s own header warns about.
///
/// `.object` is safe for the writer specifically because `XmlWriter.addAttributeSetContent`'s
/// default test is **doubled**: `dflt != value && defaultText != newValue`. Two distinct boxes
/// always differ, but their `toStandardString` is the bus id, so a peripheral at the default
/// (empty) id still writes no `<a>`. Measured, not assumed: the corpus SoC-block probe stays at
/// 139/139 across this change.
///
/// `decode` still accepts `.string` because that is exactly Java's `parse(String)`; a bus id
/// arriving as text from a `.circ` really does mint a new `SocBusInfo`.
private func makeSocBusSelectAttribute() -> Attribute<SocBusInfo> {
  Attribute(
    name: "SocBusSelection",
    codec: AttributeCodec(
      parse: { SocBusInfo($0) },
      toStandardString: { $0.busId },
      encode: { .object(AttributeObjectBox($0)) },
      decode: { value in
        switch value {
        case .object(let box): return box.object as? SocBusInfo
        case .string(let id): return SocBusInfo(id)
        default: return nil
        }
      }))
}

/// `com.cburch.logisim.soc.data.SocSimulationManager`.
public final class SocSimulationManager: SocBusMasterInterface {

  /// `SocSimulationManager.SOC_BUS_SELECT`. See file header for why identity matters here.
  public static let socBusSelect: Attribute<SocBusInfo> = makeSocBusSelectAttribute()

  private var busses: [String: SocBusFabric] = [:]
  /// `toBeChecked`: components whose bus attribute names a bus id not yet registered (the bus
  /// component can be placed after its slaves), rechecked on every subsequent registration.
  private var toBeChecked: [any Component] = []

  public init() {}

  /// `getSocBusDisplayString(String)`, minus the `StdAttr.LABEL`/location fallback the caller
  /// already has via `SocSupport.componentName`; kept as the pure "which name does this id
  /// currently resolve to" lookup Java's method actually was underneath the `null`-handling.
  public func displayString(for busId: String?) -> String? {
    guard let busId, !busId.isEmpty, let fabric = busses[busId], let comp = fabric.component else {
      return nil
    }
    return SocSupport.componentName(comp)
  }

  /// The picker data the UI's bus-select control needs: replaces `getGuiBusId()`'s
  /// `JOptionPane` (see file header). Display name → bus id, only for busses with a live
  /// component (Java's `nrOfSocBusses()` / `hasSocBusses()` counts the same set).
  public var busChoices: [String: String] {
    var result: [String: String] = [:]
    for (id, fabric) in busses where fabric.component != nil {
      if let name = displayString(for: id) {
        result[name] = id
      }
    }
    return result
  }

  /// `registerComponent(Component)`.
  @discardableResult
  public func registerComponent(_ component: any Component) -> Bool {
    guard let factory = component.factory as? any SocInstanceFactory else { return false }
    // `if (fact.isSocUnknown()) return false;`: a flagless SoC factory registers nothing.
    guard !factory.isSocUnknown else { return false }
    if factory.isSocBus {
      if let busInfo = component.attributeSet.getValue(SocBusAttributes.socBusId) {
        register(bus: busInfo.busId, component: component)
        busInfo.attach(to: self, component: component)
      }
    }
    if component.attributeSet.containsAttribute(Self.socBusSelect) {
      component.attributeSet.getValue(Self.socBusSelect)?.attach(to: self, component: component)
      if factory.isSocSlave || factory.isSocSniffer {
        toBeChecked.append(component)
        drainPendingOnRegistration()
      }
    }
    // Any additional `SocBusInfo`-valued attribute (DMA's dedicated source/destination bus
    // selects) also needs the manager attached, even though it does not drive slave/sniffer
    // registration: mirrors Java's trailing loop over `getAttributes()`.
    for attribute in component.attributeSet.attributes where attribute !== Self.socBusSelect {
      if let busAttribute = attribute as? Attribute<SocBusInfo>,
        let info = component.attributeSet.getValue(busAttribute)
      {
        info.attach(to: self, component: component)
      }
    }
    return true
  }

  /// `removeComponent(Component)`.
  ///
  /// The `isSocBus` branch was missing here and is not cosmetic. Java clears the fabric's
  /// component pointer the moment the bus is deleted; without it the fabric keeps answering
  /// `component != nil` until ARC happens to release the component, so `hasSocBusses`,
  /// `socBusCount` and `initializeTransaction`'s "is this bus real" guard all read the deleted
  /// bus as live for an indeterminate window. That is exactly the class of nondeterminism D3's
  /// "each weak site needs an explicit eviction owner" corollary exists to prevent.
  @discardableResult
  public func removeComponent(_ component: any Component) -> Bool {
    guard let factory = component.factory as? any SocInstanceFactory else { return false }
    guard !factory.isSocUnknown else { return false }
    if factory.isSocBus,
      let busInfo = component.attributeSet.getValue(SocBusAttributes.socBusId),
      let fabric = busses[busInfo.busId]
    {
      fabric.component = nil
    }
    if factory.isSocSlave || factory.isSocSniffer,
      let info = component.attributeSet.getValue(Self.socBusSelect)
    {
      reRegisterSlaveSniffer(oldBusId: info.busId, newBusId: nil, component: component)
    }
    return true
  }

  /// `nrOfSocBusses()`.
  public var socBusCount: Int { busses.values.filter { $0.component != nil }.count }
  /// `hasSocBusses()`.
  public var hasSocBusses: Bool { socBusCount != 0 }

  public func busFabric(_ busId: String) -> SocBusFabric? { busses[busId] }

  /// `reRegisterSlaveSniffer(String, String, Component)`.
  public func reRegisterSlaveSniffer(
    oldBusId: String?, newBusId: String?, component: any Component
  ) {
    guard let factory = component.factory as? any SocInstanceFactory else { return }
    if let oldBusId, let fabric = busses[oldBusId] {
      if factory.isSocSlave, let slave = factory.slaveInterface(component.attributeSet) {
        fabric.removeSlave(slave)
      }
      if factory.isSocSniffer, let sniffer = factory.snifferInterface(component.attributeSet) {
        fabric.removeSniffer(sniffer)
      }
    }
    if let newBusId, let fabric = busses[newBusId] {
      if factory.isSocSlave, let slave = factory.slaveInterface(component.attributeSet) {
        fabric.registerSlave(slave)
      }
      if factory.isSocSniffer, let sniffer = factory.snifferInterface(component.attributeSet) {
        fabric.registerSniffer(sniffer)
      }
    }
    toBeChecked.removeAll { $0 === component }
  }

  /// `getdata(Component)`.
  public func data(for component: any Component) -> AnyObject? {
    circuitState?.socComponentData(for: component)
  }

  /// `getState(Component)`.
  public func instanceState(for component: any Component) -> (any InstanceState)? {
    circuitState?.socInstanceState(for: component)
  }

  private weak var circuitState: (any SocCircuitStateToken)?

  /// `initializeTransaction(SocBusTransaction, String, CircuitState)`.
  ///
  /// `traceLog` is supplied by the caller (a bus component's own instance data) since this
  /// module does not own per-component `InstanceData` storage; see `SocBusFabric`'s header.
  /// `SocBusMasterInterface`'s requirement. A defaulted extra parameter does not satisfy a
  /// protocol requirement in Swift, so the three-argument form is spelled out separately rather
  /// than folded into the `traceLog` overload below.
  public func initializeTransaction(
    _ transaction: SocBusTransaction, busId: String, circuitState: (any SocCircuitStateToken)?
  ) {
    initializeTransaction(
      transaction, busId: busId, circuitState: circuitState, traceLog: nil)
  }

  public func initializeTransaction(
    _ transaction: SocBusTransaction, busId: String,
    circuitState: (any SocCircuitStateToken)?,
    traceLog: (() -> SocBusTraceLog?)?
  ) {
    // Java assigns unconditionally, `state = cState;`, including when `cState` is null, which
    // is a supported argument (see `SocProcessorInterface`'s note). Assigning only when non-nil
    // would leave a stale state behind and silently address the next peripheral read at the
    // wrong circuit instance.
    self.circuitState = circuitState
    guard let fabric = busses[busId], fabric.component != nil else {
      transaction.setError(.noSocBusConnected)
      return
    }
    drainPendingOnTransaction()
    fabric.initializeTransaction(transaction, traceLog: traceLog?())
  }


  // MARK: - Internals

  private func register(bus busId: String, component: any Component) {
    if let existing = busses[busId] {
      existing.component = component
    } else {
      busses[busId] = SocBusFabric(component: component)
    }
  }

  // ── The two drain loops are NOT the same loop, and merging them was a real divergence ───────
  //
  // Java re-checks the pending slave/sniffer list in two places, and the bodies differ where it
  // matters. This port had one shared helper, which reads like a tidy de-duplication of
  // "upstream's duplicated loop body" and is not: `initializeTransaction`'s copy has an *else*
  // branch the registration copy does not have, and it is the branch that mutates the component.
  //
  // | | `registerComponent` (`:140-155`) | `initializeTransaction` (`:252-269`) |
  // |---|---|---|
  // | bus id resolves | register slave/sniffer, drop from pending | register slave/sniffer |
  // | id is empty | drop from pending | blank the id, write it back |
  // | id names a bus that does not exist | **keep pending**, the bus may be placed later | **blank the id and write it back** |
  // | end of iteration | none | drop everything from pending |
  //
  // The third row is observable in a saved file: a peripheral whose `SocBusSelection` names a
  // bus that is not there has that attribute rewritten to `""` by the first transaction anyone
  // initiates, and the merged version never rewrote it. The fourth row is observable in
  // behaviour: after any transaction, upstream's pending list is empty, so a bus placed *after*
  // a transaction has already run does not retroactively adopt its slaves.
  //
  // Both are ported literally below, as two functions, with the divergence in the names.

  /// The loop inside `registerComponent` (`SocSimulationManager.java:140-155`). A component
  /// whose bus id names a bus that has not been placed yet **stays pending**, which is the whole
  /// reason the list exists: a `.circ` may place slaves before their bus.
  private func drainPendingOnRegistration() {
    var stillPending: [any Component] = []
    for component in toBeChecked {
      guard let factory = component.factory as? any SocInstanceFactory,
        let info = component.attributeSet.getValue(Self.socBusSelect)
      else { continue }
      let id = info.busId
      if !id.isEmpty, let fabric = busses[id] {
        attach(component: component, factory: factory, to: fabric)
      } else if id.isEmpty {
        // Java: `if (id == null || id.isEmpty()) iter.remove();`: dropped, nothing else.
      } else {
        stillPending.append(component)
      }
    }
    toBeChecked = stillPending
  }

  /// The loop inside `initializeTransaction` (`SocSimulationManager.java:252-269`). Every entry
  /// is removed unconditionally (`iter.remove()` sits outside the `if`), and an entry naming an
  /// unknown bus has its `SocBusSelection` **blanked and written back** to the component.
  ///
  /// D13: the write-back goes through `AttributeSet.setValue`, which throws. Java's
  /// `setValue` here cannot fail (the attribute was just proven present by
  /// `containsAttribute`), so a failure is not a user-reachable path, but this runs during
  /// propagation, where a trap would kill the process and lose unsaved work, so the error is
  /// swallowed rather than raised: leaving the stale id is strictly better than crashing, and
  /// it is what the pre-fix code did on every path anyway.
  private func drainPendingOnTransaction() {
    for component in toBeChecked {
      guard let factory = component.factory as? any SocInstanceFactory,
        component.attributeSet.containsAttribute(Self.socBusSelect),
        let info = component.attributeSet.getValue(Self.socBusSelect)
      else { continue }
      let id = info.busId
      if !id.isEmpty, let fabric = busses[id] {
        attach(component: component, factory: factory, to: fabric)
      } else {
        info.busId = ""
        try? component.attributeSet.setValue(Self.socBusSelect, info)
      }
    }
    toBeChecked.removeAll()
  }

  /// The shared body of both loops: register this component's slave and/or sniffer face on
  /// `fabric`, whichever it has.
  private func attach(
    component: any Component, factory: any SocInstanceFactory, to fabric: SocBusFabric
  ) {
    if factory.isSocSlave, let slave = factory.slaveInterface(component.attributeSet) {
      fabric.registerSlave(slave)
    }
    if factory.isSocSniffer, let sniffer = factory.snifferInterface(component.attributeSet) {
      fabric.registerSniffer(sniffer)
    }
  }
}
