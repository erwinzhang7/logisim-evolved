// HdlGeneratorLookup: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// this is the three `ComponentFactory` methods the netlist and the DRC call:
// `getHDLGenerator(AttributeSet)`, `isHDLSupportedComponent(AttributeSet)` and
// `getHDLName(AttributeSet)` (`com/cburch/logisim/comp/ComponentFactory.java:70-76`,
// defaults in `AbstractComponentFactory.java:96-116`). Copyright by the Logisim-evolution
// developers. GPL-3.0-only. See LICENSE.md.
//
// ══ WHY A LOOKUP OBJECT AND NOT THREE MORE `ComponentFactory` MEMBERS ═══════════════════════
//
// Upstream puts these on `ComponentFactory`, so every one of the ~200 builtin factories answers
// for itself. `ComponentFactory` lives in `LogisimFile`, and the factories live in `LogisimStd`
// , and `Package.swift` records why `LogisimStd` does not depend on `LogisimHdl` yet: the
// per-component HDL generators were stripped during the M4/M5 component port and come back
// afterwards. Adding `getHDLGenerator` to `ComponentFactory` today would require
// `LogisimFile` to name `HdlGeneratorFactory`, i.e. `LogisimFile` -> `LogisimHdl`, which
// permanently forbids the `LogisimStd` -> `LogisimHdl` edge those generators will need.
//
// So the mapping lives here, on the HDL side of the boundary, as data rather than as a protocol
// requirement. When a component family's generator lands it registers itself; nothing above
// this module has to change shape, and no protocol sits in the tree with no conformer.
//
// **This is deliberately not a protocol.** A protocol with no conformer is the exact defect
// class `tools/seamcheck.py` exists to catch; a registry with a real default is reachable from
// the first line of code that uses it.
//
// ── What "empty" means today, precisely ─────────────────────────────────────────────────────
//
// With no registrations, `generator(for:)` answers `nil` for every component. That is the same
// answer `AbstractComponentFactory.getHDLGenerator` gives for any factory that never set
// `myHDLGenerator`, which upstream treats as "not synthesizable", excluding the component from
// `Netlist.myComponents` (`Netlist.java:1000-1006`). So an unregistered port builds a netlist
// containing the *wires, splitters, pins, clocks and subcircuits* correctly and no ordinary
// gates. `synthesizableOverride` exists so tests and the netlist gate can say "treat everything
// as synthesizable" and exercise the full connection graph without inventing generators.

import LogisimFile
import LogisimKernel

/// The per-factory HDL facts `Netlist` and the DRC need, keyed by
/// `ComponentFactory.name`: the same string `.circ` files use, and the only stable identity a
/// factory has across modules.
public final class HdlGeneratorLookup {

  /// The process-wide lookup. Mirrors `Reporter.shared`'s shape, and like it is plain mutable
  /// state because `LogisimHdl` is a D1 (Swift 5 language mode, no Concurrency) module.
  public static let shared = HdlGeneratorLookup()

  /// What a registration supplies for one factory.
  public struct Registration {
    /// `ComponentFactory.getHDLGenerator(AttributeSet)`.
    public var generator: (any AttributeSet) -> (any HdlGeneratorFactory)?
    /// `ComponentFactory.getHDLName(AttributeSet)`. Defaults to upstream's
    /// `CorrectLabel.getCorrectLabel(getName())` when omitted.
    public var hdlName: ((any AttributeSet) -> String)?
    /// `attrs.getValue(StdAttr.MAPINFO)`; see `mapInformation(for:)` below. `nil` means the
    /// factory does not declare the attribute at all, which is a different answer from a
    /// registration that returns a container with zero bubbles.
    public var mapInformation: ((any AttributeSet) -> ComponentMapInformationContainer)?

    public init(
      generator: @escaping (any AttributeSet) -> (any HdlGeneratorFactory)?,
      hdlName: ((any AttributeSet) -> String)? = nil,
      mapInformation: ((any AttributeSet) -> ComponentMapInformationContainer)? = nil
    ) {
      self.generator = generator
      self.hdlName = hdlName
      self.mapInformation = mapInformation
    }
  }

  private var registrations: [String: Registration] = [:]

  /// Factory names that upstream *has* an HDL generator for, even though this port does not
  /// carry the generator yet.
  ///
  /// `Netlist` decides membership of `normalComponents` with
  /// `getHDLGenerator(attrs) != null`: a question about the design, not about this port's
  /// progress. Answering it "no" for everything would silently drop every gate from the netlist
  /// and make the connection graph untestable, so the answer is supplied as data:
  /// `tools/hdlbridge/netlist-4.1.0.oracle` carries a `SYNTH <factory> <0|1>` line per factory,
  /// taken from the jar, and the netlist gate loads it.
  ///
  /// It does **not** invent HDL text; `generator(for:)` still answers `nil`, so nothing can be
  /// emitted for such a component. It only decides whether the component is in the graph.
  public var upstreamGeneratorFactoryNames: Set<String> = []

  /// Factory names for which upstream's `isHDLSupportedComponent(attrs)` is `true`.
  ///
  /// **Not the same predicate as the one above, and the difference is load-bearing.**
  /// `AbstractComponentFactory` derives it from the generator, but `Text` overrides it to `true`
  /// while its generator stays `null` (`std/base/Text.java:124`), so a text annotation *passes*
  /// the DRC and is then *excluded* from the netlist. Collapsing the two predicates makes every
  /// annotated circuit in the corpus fail DRC. Supplied as data from the same oracle, as
  /// `SUPP <factory> <0|1>` lines.
  public var upstreamSupportedFactoryNames: Set<String> = []

  /// Blanket form of the above: treat every non-structural component as having a generator.
  /// Coarser than `upstreamGeneratorFactoryNames` and wrong in the same way upstream would be
  /// wrong, a `Text` annotation has no generator and must not appear in `normalComponents`,
  /// so prefer the name set. Kept for callers that only need "is this circuit connected".
  public var treatAllComponentsAsSynthesizable = false

  public init() {}

  /// Register (or replace) the HDL facts for one factory name.
  public func register(factoryName: String, _ registration: Registration) {
    registrations[factoryName] = registration
  }

  /// Set only the `mapInformation` field for one factory, leaving any generator registration
  /// already installed for it alone.
  ///
  /// The two halves are installed by different callers, `registerAllBuiltins` for the
  /// generators, the FPGA map bindings for these, and in either order. A full
  /// `register(factoryName:_:)` from the second caller would silently clobber the first's work,
  /// which is the same shape as the registry defects this project has hit before.
  public func registerMapInformation(
    factoryName: String,
    _ build: @escaping (any AttributeSet) -> ComponentMapInformationContainer
  ) {
    if var existing = registrations[factoryName] {
      existing.mapInformation = build
      registrations[factoryName] = existing
    } else {
      registrations[factoryName] = Registration(generator: { _ in nil }, mapInformation: build)
    }
  }

  /// Every factory name currently registered.
  ///
  /// Exists so a caller can ASSERT the registry was populated rather than trusting it. An empty
  /// registry is a perfectly legal state that answers `nil` for every component; indistinguishable
  /// from "this design has no synthesizable parts", which is how these 40 registrations sat
  /// unreachable with nothing complaining. `registerAllBuiltins` returns its installed names for
  /// the same reason; this is the query form, for code that did not make the call itself.
  public var registeredFactoryNames: Set<String> { Set(registrations.keys) }

  /// Drop every registration. Test hook; also what a future `StdLibraries.registerAll()`
  /// equivalent would call before re-registering.
  public func removeAll() {
    registrations.removeAll()
    upstreamGeneratorFactoryNames.removeAll()
    upstreamSupportedFactoryNames.removeAll()
    treatAllComponentsAsSynthesizable = false
  }

  /// Whether `Netlist` should treat this component as one that produces HDL: the port's answer
  /// to `getHDLGenerator(attrs) != null`, which is what upstream keys netlist membership on.
  public func hasGenerator(for component: any Component) -> Bool {
    if generator(for: component) != nil { return true }
    if upstreamGeneratorFactoryNames.contains(component.factory.name) { return true }
    return treatAllComponentsAsSynthesizable && !isStructural(component)
  }

  /// `comp.getFactory().getHDLGenerator(comp.getAttributeSet())`.
  public func generator(for component: any Component) -> (any HdlGeneratorFactory)? {
    guard let registration = registrations[component.factory.name] else { return nil }
    return registration.generator(component.attributeSet)
  }

  /// `comp.getFactory().isHDLSupportedComponent(comp.getAttributeSet())`.
  ///
  /// `AbstractComponentFactory`'s default is `getHDLGenerator(attrs) != null`; the few factories
  /// that override it (`Pin`, `Splitter`, `Tunnel`, ... via the wiring library) return `true`
  /// unconditionally, which is why those are special-cased below rather than requiring a
  /// registration.
  public func isSupported(_ component: any Component) -> Bool {
    if isStructural(component) { return true }
    if upstreamSupportedFactoryNames.contains(component.factory.name) { return true }
    return hasGenerator(for: component)
  }

  /// The components upstream handles in `Netlist` itself rather than through a generator: wires,
  /// splitters, tunnels, pins, clocks, probes, and subcircuits.
  public func isStructural(_ component: any Component) -> Bool {
    let factory = component.factory
    if factory.isPin || NetlistFactoryNames.isClock(factory) || factory.isTunnel { return true }
    if factory is any SubcircuitFactory { return true }
    if let wireComponent = component as? any WireComponent {
      switch wireComponent.wireRole {
      case .wire, .splitter, .tunnel, .pullResistor: return true
      case .plain: break
      }
    }
    return factory.name == NetlistFactoryNames.probe
  }

  // MARK: - FPGA bubbles

  /// `netlistComponent`'s `StdAttr.MAPINFO` constructor branch
  /// (`netlistComponent.java:40-55`), which is what declares how many board-facing *bubbles* a
  /// component contributes.
  ///
  /// **Why this is injected rather than read off the attribute set.** Upstream stores a live
  /// `ComponentMapInformationContainer` in `StdAttr.MAPINFO`, built by nine
  /// `com.cburch.logisim.std.io` factories (`Button`, `Led`, `RgbLed`, `SevenSegment`,
  /// `HexDigit`, `DipSwitch`, `PortIo`, `DotMatrixBase`, `ReptarLocalBus`). That container type
  /// lives *here*, in `LogisimHdl`, and `LogisimStd` does not depend on this module, so it
  /// cannot construct one, and this module must never depend on `LogisimStd`, because the
  /// per-component generators need the edge the other way and the pair would close a cycle.
  ///
  /// So the mapping arrives as data, exactly like `upstreamGeneratorFactoryNames` above and for
  /// the same reason. Each container is a pure function of the component's attributes upstream,
  /// a `7-Segment Display` is 7 or 8 output bubbles by `ATTR_DP`, a `DipSwitch` one input bubble
  /// per switch, so a closure over the attribute set reproduces it exactly.
  ///
  /// The `Pin` branch needs no registration: `ComponentFactory.isPin` already exists in
  /// `LogisimFile` and `Pin` overrides it.
  public func mapInformation(for component: any Component) -> ComponentMapInformationContainer? {
    // Upstream clones, because the container it took out of the attribute set is shared with the
    // live component and `constructHierarchyTree`'s callers mutate it.
    if let build = registrations[component.factory.name]?.mapInformation {
      return build(component.attributeSet).cloned()
    }
    guard component.factory.isPin, let end = component.ends.first else { return nil }
    let bits = end.width.width
    if end.isInput && end.isOutput {
      return ComponentMapInformationContainer(inputPorts: 0, outputPorts: 0, inOutPorts: bits)
    }
    if end.isInput {
      return ComponentMapInformationContainer(inputPorts: 0, outputPorts: bits, inOutPorts: 0)
    }
    return ComponentMapInformationContainer(inputPorts: bits, outputPorts: 0, inOutPorts: 0)
  }

  /// `comp.getAttributeSet().containsAttribute(StdAttr.MAPINFO)`: a *declaration* test, not a
  /// value test, and `Netlist.generateNetlist` uses it as one of the three ways a component
  /// earns a place in the netlist (`Netlist.java:1002`).
  ///
  /// Every factory that declares `MAPINFO` in 4.1.0 also has an HDL generator, so on this corpus
  /// the clause is inert, but it is upstream's condition, and a factory could lose its
  /// generator without losing its bubbles.
  public func declaresMapInformation(_ component: any Component) -> Bool {
    registrations[component.factory.name]?.mapInformation != nil
  }

  /// `comp.getFactory().getHDLName(comp.getAttributeSet())`.
  public func hdlName(for component: any Component) -> String {
    if let override = registrations[component.factory.name]?.hdlName {
      return override(component.attributeSet)
    }
    return CorrectLabel.correctLabel(component.factory.name)
  }
}

/// The factory names `Netlist` tests for by `instanceof` upstream and that
/// `ComponentFactory` exposes no *working* predicate for.
///
/// `isTunnel` and `isPin` exist as `ComponentFactory` members
/// (`ComponentFactory.swift`, "instanceof stand-ins") and `Tunnel`/`Pin` do override them;
/// splitter-ness is answered by `WireComponentRole.splitter` in `LogisimKernel`. Two do not
/// work out of the box:
///
///   * **`Probe`** has no predicate at all, by design; upstream's `instanceof Probe` has no
///     stand-in in `ComponentFactory`.
///   * **`isClock` exists but nothing overrides it.** `ComponentFactory.isClock` defaults to
///     `false` and `LogisimStd/Wiring/Clock.swift` never overrides it, so today it answers
///     `false` for a real `Clock`. That is a `LogisimStd` gap, not an HDL one, and it is
///     load-bearing beyond this module: `Circuit.clocks` is populated from the same predicate
///     (`Circuit.swift:622`, `:714`), so it is empty for every circuit too. **Reported for the
///     `LogisimStd` owner; not fixed here, because this task does not own that file.** Until it
///     is, matching by name keeps the clock tree correct: and once `Clock` overrides
///     `isClock`, `isClock(_:)` below keeps working unchanged.
///
/// Matching by name is safe for exactly these two: the string is `Probe._ID` / `Clock._ID`, it
/// is what `.circ` files carry, and it cannot be changed without breaking every saved file.
public enum NetlistFactoryNames {
  /// `com.cburch.logisim.std.wiring.Probe._ID`.
  public static let probe = "Probe"

  /// `com.cburch.logisim.std.wiring.Clock._ID`.
  public static let clock = "Clock"

  /// `comp.getFactory() instanceof Clock`.
  public static func isClock(_ factory: any ComponentFactory) -> Bool {
    factory.isClock || factory.name == clock
  }
}
