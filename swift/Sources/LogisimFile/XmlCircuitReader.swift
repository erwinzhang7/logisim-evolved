// XmlCircuitReader.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution),
// specifically `src/main/java/com/cburch/logisim/file/XmlCircuitReader.java`.
// Copyright by the Logisim-evolution developers. This translation is a derivative work and is
// therefore GPL-3.0-only. See LICENSE.md.
// SPDX-License-Identifier: GPL-3.0-only
//
// The second half of the reader: turning `<comp>` and `<wire>` elements into placed components
// once every circuit shell exists. Upstream this is a `CircuitTransaction`, run last by
// `XmlReader.toLogisimFile` so that a subcircuit reference can resolve to a circuit declared
// later in the file.
//
// The transaction machinery itself (`CircuitTransaction`, `CircuitMutator`, the per-circuit
// read/write locking) is M3 work; it exists to keep the simulator consistent while a circuit
// is edited, and nothing is simulating yet. `CircuitLoadMutator` below is the shape-preserving
// stand-in: the same `add(circuit, component)` call the Java makes, applied directly. When the
// real transaction lands, only that type changes.

import Foundation
import LogisimKernel

/// The `CircuitMutator` seam, reduced to the two operations the loader performs.
///
/// Upstream a mutator batches changes so the simulator can be told about them once; during a
/// load there is nothing to tell, which is why `XmlCircuitReader` is the one transaction that
/// runs before any `CircuitState` exists.
public final class CircuitLoadMutator {
  public init() {}

  /// Java: `CircuitMutator.add(Circuit, Component)` → `Circuit.mutatorAdd(Component)`.
  ///
  /// D13: `mutatorAdd` throws, it writes component labels and clears duplicates, and
  /// `setValue` throws, so this does too rather than swallowing a malformed-file error.
  public func add(_ circuit: Circuit, _ component: any Component) throws {
    try circuit.mutatorAdd(component)
  }
}

/// `com.cburch.logisim.file.XmlCircuitReader`.
public final class XmlCircuitReader {

  private static let contextFormat = "%@.%@"

  /// D3: the context owns the whole load and outlives this object, which is created and
  /// executed inside `toLogisimFile`. `unowned` keeps the edge from becoming a retain cycle
  /// through `CircuitData`.
  private unowned let reader: XmlReader.ReadContext

  private let circuitsData: [XmlReader.CircuitData]
  private let isHolyCross: Bool
  private let isEvolution: Bool

  public init(
    reader: XmlReader.ReadContext,
    circuitsData: [XmlReader.CircuitData],
    isHolyCross: Bool,
    isEvolution: Bool
  ) {
    self.reader = reader
    self.circuitsData = circuitsData
    self.isHolyCross = isHolyCross
    self.isEvolution = isEvolution
  }

  // MARK: - getComponent

  /// Java: `getComponent(Element, XmlReader.ReadContext, boolean, boolean)`.
  ///
  /// Resolves the `lib`/`name` pair to a factory, builds its attribute set from the `<a>`
  /// children, and places it at `loc`.
  ///
  /// D13 note on the two throw channels: an `XmlReaderException` here means "this one component
  /// is broken, record it and carry on", and both callers do exactly that. Anything else:
  /// notably `AttributeSetError` out of `initAttributeSet`, or a factory refusing to build from
  /// the attributes it was handed; is the Swift form of an unchecked Java exception and aborts
  /// the load, which is what upstream does too.
  static func getComponent(
    _ elt: XMLElement,
    _ reader: XmlReader.ReadContext,
    _ isHolyCross: Bool,
    _ isEvolution: Bool
  ) throws -> any Component {

    // Determine the factory that creates this element.
    let name = elt.getAttribute("name")
    if StringUtil.isNullOrEmpty(name) {
      throw XmlReaderException(FileStrings.compNameMissingError)
    }

    let libName = elt.getAttribute("lib")
    let lib = try reader.findLibrary(libName)

    // 4.1.0 is `lib.getTool(name)`; a flat scan of *this* library's own tool list
    // (`Library.java:61-68`). `ReadContext.findTool` is main's recursive descent into
    // sub-libraries and is one of the main-only behaviours D16 forbids: 4.1.0's `XmlReader`
    // contains no `findTool` at all. Calling it here would resolve a component that the oracle
    // leaves unresolved, which changes what gets written back. `toTool` still uses the recursive
    // helper; that call site is in `XmlReader.swift` and is not this file's to change.
    let tool = lib.tool(named: name)

    // ── D8, the reader's half ────────────────────────────────────────────────────────────────
    //
    // Upstream falls straight through to the `instanceof AddTool` test below and throws, and
    // both callers respond by dropping the component: permanently, since the next save simply
    // does not write it. Measured on 4.1.0: 14 components in, 13 out, with nothing in the saved
    // file recording the loss.
    //
    // The port routes those elements to `UnresolvedComponent` instead, which keeps the `<comp>`
    // verbatim for `XmlWriter.fromComponent` to re-emit. Without this branch the `<lib>` half of
    // D8 (`MissingLibrary`) makes things *worse* rather than better: the declaration and its
    // `<tool>` children survive while every component using them is deleted, so the saved file
    // is internally inconsistent.
    if let preserved = try unresolvedComponent(elt, name: name, libName: libName, lib: lib, tool: tool)
    {
      return preserved
    }

    // ── D8, the `<vhdl>` half ────────────────────────────────────────────────────────────────
    //
    // The tool DID resolve, `PreservedVhdlEntityFactory` answers to the entity's own name, just
    // as `VhdlEntity` does, but the entity behind it was never parsed, because the
    // `VhdlContentLoading` seam has no handler installed. So the placement takes the same verbatim
    // path an unresolved `<comp>` takes, reusing the tool's factory rather than minting one.
    //
    // **Reusing it is the point, not an optimisation.** `FileStatistics` counts by factory
    // identity and lists only those counts whose factory belongs to some tool
    // (`FileStatistics.sortCounts`), so a per-placement factory is both invisible to the listing
    // and split across instances. Sharing the tool's factory is what makes `-tty stats` agree
    // with the jar on a file that places a VHDL entity.
    //
    // It is checked here rather than inside `unresolvedComponent` because that helper's guard is
    // "did this fail to resolve?", and this case is the opposite: it resolved, to a carrier.
    if let addTool = tool as? AddTool,
      let vhdlCarrier = addTool.factory as? PreservedVhdlEntityFactory
    {
      return try preservedPlacement(elt, name: name, factory: vhdlCarrier)
    }

    guard let addTool = tool as? AddTool else {
      let message =
        StringUtil.isNullOrEmpty(libName)
        ? FileStrings.compUnknownError(name)
        : FileStrings.compAbsentError(name, libName)
      throw XmlReaderException(message)
    }
    let source = addTool.factory

    // Determine attributes.
    let locStr = elt.getAttribute("loc")
    let attrs = source.createAttributeSet()
    var defaults: (any AttributeDefaultProvider)? = source

    if isHolyCross && source.name == RamComponent.id {
      // Holy Cross builds default RAM to line enables rather than byte enables, and suppress
      // the default provider entirely so nothing else is back-filled.
      //
      // Deviation in mechanism, not behaviour: upstream downcasts to `RamAttributes` and calls
      // `updateAttributes()` to rebuild the attribute list after the write. `RamAttributes` is
      // M5; the attribute is reached by its serialised name here, and rebuilding the list on
      // write is the ported set's own responsibility (`AttributeSet.attributesMayAlsoBeChanged`
      // is the port's expression of that contract). Reachable only from a `source="…-HC"` file.
      if let enables = attrs.attribute(named: RamComponent.enablesAttributeName) {
        try attrs.setRawValue(enables, .option(RamComponent.useLineEnables))
      }
      defaults = nil
    }

    try reader.initAttributeSet(elt, attrs, defaults, isHolyCross, isEvolution)

    if let vhdl = source as? any VhdlEntityFactory {
      initLegacyVhdlAppearance(elt, reader, vhdl)
    }

    // Create the component, if the location is known.
    if StringUtil.isNullOrEmpty(locStr) {
      throw XmlReaderException(FileStrings.compLocMissingError(source.name))
    }
    let location: Location
    do {
      location = try Location.parse(locStr)
    } catch {
      // Java catches `NumberFormatException` from `Location.parse` only; the port's parse
      // throws exactly one error type, so the mapping is one-for-one.
      throw XmlReaderException(FileStrings.compLocInvalidError(source.name, locStr))
    }
    return try source.createComponent(location: location, attributes: attrs)
  }

  /// D8's `<comp>` half. No upstream counterpart; this is the branch that exists so an element
  /// the codec cannot interpret survives load → save unchanged instead of being deleted.
  ///
  /// Returns `nil` when the element resolves normally, so the caller carries on into the ordinary
  /// `AddTool` path. Three conditions send it here, and **resolution alone is not sufficient**:
  ///
  /// 1. the library is a `MissingLibrary`: `#Risc-V`, `#MIPS Tools`, `#Yosys Components` and
  ///    every `jar#` descriptor (D11, a permanent gap);
  /// 2. the tool is a `MissingTool`; the same case reached from the tool side, since a
  ///    `MissingLibrary` mints one on demand for any name asked of it;
  /// 3. **the tool has no attribute set.** This is the one a "did it resolve?" test misses. A
  ///    `BuiltinPlaceholderTool` and every tool of a `BuiltinLibraryShell` resolve perfectly well
  ///    by name and carry no `AttributeSet` until the component tranches land at M4/M5, so the
  ///    `<a>` children would be read into nothing and the writer would emit a bare `<comp/>`,
  ///    losing every attribute while appearing to succeed. `Library.absorbUnresolvedTool` guards
  ///    the identical hole on the `<tool>` side, for the identical reason.
  ///
  /// The attribute set built here is a convenience for the model, not the serialisation
  /// authority: `absorb(componentElement:)` keeps the element itself, and that is what the writer
  /// re-emits. A nameless `<a>` is therefore skipped rather than reported; it is still written
  /// back out verbatim, because it never left the element.
  private static func unresolvedComponent(
    _ elt: XMLElement,
    name: String,
    libName: String,
    lib: Library,
    tool: Tool?
  ) throws -> (any Component)? {
    let missingLibrary = lib as? MissingLibrary
    var carriesAttributes = false
    if let tool, tool.attributeSet != nil { carriesAttributes = true }
    guard missingLibrary != nil || tool is MissingTool || !carriesAttributes else { return nil }

    let factory = UnresolvedComponentFactory(
      name: name,
      sourceLibraryReference: StringUtil.isNullOrEmpty(libName) ? nil : libName,
      missingLibrary: missingLibrary,
      // The library `findLibrary` resolved, not just the handle that named it. The writer needs
      // the object, because the handle it re-emits has to be the library's *new* index, see
      // `UnresolvedComponentFactory.sourceLibrary`.
      sourceLibrary: lib)

    // Deliberately no `reader.addError`. Upstream records one because it is about to destroy the
    // component; here it is preserved, so an error line would be describing a loss that no longer
    // happens. It would also be pure noise in the current port state, where *every* builtin
    // component takes this path until M4/M5 land. The `<lib>` half is silent for the same reason.
    return try preservedPlacement(elt, name: name, factory: factory)
  }

  /// Builds the verbatim `UnresolvedComponent` both D8 `<comp>` paths return.
  ///
  /// `factory` is supplied rather than made here because the two callers differ on exactly that:
  /// an unresolved `<comp>` gets a fresh `UnresolvedComponentFactory` (there is no tool to share
  /// one with), while a placement of an unparsed `<vhdl>` entity reuses the `AddTool`'s
  /// `PreservedVhdlEntityFactory` so that all placements of one entity are one factory, which is
  /// what `FileStatistics` counts by.
  private static func preservedPlacement(
    _ elt: XMLElement, name: String, factory: any ComponentFactory
  ) throws -> any Component {
    let attrs = OpaqueAttributeSet()
    for attrElt in XmlIterator.forChildElements(elt, "a") where attrElt.hasAttribute("name") {
      // Read exactly as `initAttributeSet` reads, minus the parsing and minus the `filePath`
      // de-relativization: an unresolved component's text is never interpreted, and rewriting a
      // path inside it would break the byte-exact guarantee that is the whole point.
      let attrName = attrElt.getAttribute("name")
      let attrValue =
        attrElt.hasAttribute("val") ? attrElt.getAttribute("val") : attrElt.textContent
      attrs.setOpaqueValue(attrValue, forName: attrName)
    }

    // Location is still required, and the two errors still match upstream's text. A `<comp>`
    // with no parseable `loc` is malformed by any reading, there is nowhere to put it, and
    // `Component.location` is not optional, so this is the one case D8 cannot rescue. The
    // messages name the element's own `name` attribute, which is what upstream would have
    // passed as `source.getName()` had the factory resolved.
    let locStr = elt.getAttribute("loc")
    if StringUtil.isNullOrEmpty(locStr) {
      throw XmlReaderException(FileStrings.compLocMissingError(name))
    }
    let location: Location
    do {
      location = try Location.parse(locStr)
    } catch {
      throw XmlReaderException(FileStrings.compLocInvalidError(name, locStr))
    }

    let component = UnresolvedComponent(
      factory: factory, location: location, attributes: attrs)
    component.absorb(componentElement: elt)
    return component
  }

  /// Java: `initLegacyVhdlAppearance(Element, ReadContext, VhdlEntity)`.
  ///
  /// Old files stored a VHDL entity's appearance on the *component* rather than on the content.
  /// Note the `return` after the first `appearance` attribute; later ones are ignored even if
  /// the first was unparseable.
  private static func initLegacyVhdlAppearance(
    _ elt: XMLElement, _ reader: XmlReader.ReadContext, _ vhdl: any VhdlEntityFactory
  ) {
    for attrElt in XmlIterator.forChildElements(elt, "a") {
      guard StdAttr.appearance.name == attrElt.getAttribute("name") else { continue }
      let attrValue =
        attrElt.hasAttribute("val") ? attrElt.getAttribute("val") : attrElt.textContent
      do {
        let parsed = try StdAttr.appearance.parse(attrValue)
        VhdlContentReader.handler?.setAppearance(parsed, on: vhdl.content)
      } catch {
        reader.addError(
          FileStrings.attrValueInvalidError(attrValue, StdAttr.appearance.name),
          "vhdl." + vhdl.content.name)
      }
      return
    }
  }

  // MARK: - Wires

  /// Java: `addWire(Circuit, CircuitMutator, Element)`.
  ///
  /// Zero-length wires are dropped rather than reported: a `<wire from="(10,10)"
  /// to="(10,10)"/>` is silently discarded, which is upstream behaviour and matters for
  /// round-tripping: such a wire does not come back on save.
  func addWire(_ dest: Circuit, _ mutator: CircuitLoadMutator, _ elt: XMLElement) throws {
    let pt0: Location
    let fromStr = elt.getAttribute("from")
    if fromStr.isEmpty {
      throw XmlReaderException(FileStrings.wireStartMissingError)
    }
    do {
      pt0 = try Location.parse(fromStr)
    } catch {
      throw XmlReaderException(FileStrings.wireStartInvalidError)
    }

    let pt1: Location
    let toStr = elt.getAttribute("to")
    if toStr.isEmpty {
      throw XmlReaderException(FileStrings.wireEndMissingError)
    }
    do {
      pt1 = try Location.parse(toStr)
    } catch {
      throw XmlReaderException(FileStrings.wireEndInvalidError)
    }

    if pt0 != pt1 {
      // Avoid zero-length wires.
      let wire = Wire.create(pt0, pt1)
      try mutator.add(dest, wire)
      if elt.hasAttribute("buswidthpos") {
        let posStr = elt.getAttribute("buswidthpos")
        // Java: `Wire.BUS_WIDTH_POS_ATTR.parse(posStr)` returns null for an unknown option and
        // the result is null-checked. The port's option parser throws instead, so the failure
        // is caught and the attribute skipped: same outcome, and it stays out of the message
        // list exactly as upstream keeps it out.
        if let option = try? Wire.busWidthPositionAttribute.parse(posStr) {
          dest.setWireBusWidthPos(wire, option)
        }
      }
    }
  }

  // MARK: - buildCircuit

  /// Java: `buildCircuit(CircuitData, CircuitMutator)`.
  private func buildCircuit(_ circData: XmlReader.CircuitData, _ mutator: CircuitLoadMutator)
    throws
  {
    let element = circData.circuitElement
    let dest = circData.circuit

    do {
      // The `circuitnamedbox` attribute is checked for backwards compatibility.
      var hasNamedBox = false
      var hasNamedBoxFixedSize = false
      var hasAppearAttr = false
      for attrElt in XmlIterator.forChildElements(circData.circuitElement, "a")
      where attrElt.hasAttribute("name") {
        let name = attrElt.getAttribute("name")
        hasNamedBox = hasNamedBox || name == "circuitnamedbox"
        hasAppearAttr = hasAppearAttr || name == "appearance"
        hasNamedBoxFixedSize = hasNamedBoxFixedSize || name == "circuitnamedboxfixedsize"
      }
      try reader.initAttributeSet(
        circData.circuitElement, dest.staticAttributes, nil, isHolyCross, isEvolution)

      // Java: `circData.circuitElement.hasChildNodes()`. That is *any* child node, including a
      // whitespace text node, which Java's parser keeps and Foundation's discards. An element
      // with children is therefore the only case where the two DOMs could disagree, and they
      // cannot here: a `<circuit>` that pretty-printer whitespace alone would make "non-empty"
      // is written by no version of Logisim, since a circuit always carries at least its
      // `<a name="circuit">` attribute element.
      if !XmlIterator.forChildElements(circData.circuitElement).isEmpty {
        if hasNamedBox {
          // This situation is clear: it is an older logisim-evolution file.
          let appear =
            (circData.appearance?.isEmpty == false)
            ? CircuitAttributes.appearCustom : StdAttr.appearEvolution
          try dest.staticAttributes.setValue(CircuitAttributes.appearanceAttribute, appear)
        } else if !hasAppearAttr {
          // Two possibilities: a Holy Cross file, or a logisim-evolution file predating named
          // circuit boxes. Upstream's comment says "let's ask the user"; it does not, and
          // neither do we.
          var appear = StdAttr.appearClassic
          if circData.appearance?.isEmpty == false {
            appear = CircuitAttributes.appearCustom
          } else if isHolyCross {
            appear = StdAttr.appearFpga
          }
          try dest.staticAttributes.setValue(CircuitAttributes.appearanceAttribute, appear)
        }
        // `XmlCircuitReader.java:187-189`, verbatim including the value. `false` is NOT a
        // duplicate of `STATIC_DEFAULTS`' `false` and must not be "reconciled" with
        // `AppPreferences.NAMED_CIRCUIT_BOXES_FIXED_SIZE`'s `true`: `Circuit.java:253-255` has
        // already overwritten the static default with that preference by the time this runs, so
        // this write is what pins a pre-attribute file back to variable-width boxes. Writing
        // `true` here instead costs 213 canonical round-trip failures; every such file gains an
        // `<a name="circuitnamedboxfixedsize" val="true"/>` the jar does not emit. See the
        // `namedCircuitBoxFixedSize` doc comment in `CircuitAttributes` for all four values.
        if !hasNamedBoxFixedSize {
          try dest.staticAttributes.setValue(
            CircuitAttributes.namedCircuitBoxFixedSize, false)
        }
      }
    } catch let error as XmlReaderException {
      reader.addErrors(error, circData.circuit.name + ".static")
    }

    // D4: keyed by `Bounds`, which is a value type; this map is genuinely structural, unlike
    // every component-keyed collection in the simulator.
    var componentsAt: [Bounds: any Component] = [:]
    var overlapComponents: [any Component] = []

    for subElement in XmlIterator.forChildElements(element) {
      let subEltName = subElement.tagName
      if subEltName == "comp" {
        do {
          let comp: any Component
          if let known = circData.knownComponent(for: subElement) {
            comp = known
          } else {
            comp = try XmlCircuitReader.getComponent(
              subElement, reader, isHolyCross, isEvolution)
          }

          // Filter out empty text boxes.
          if comp.factory.name == TextComponent.id, isEmptyTextBox(comp) {
            continue
          }

          // D8: an unresolved component has no geometry; `UnresolvedComponent.bounds` is
          // `Bounds.empty` on purpose, because inventing one would put a placeholder into
          // `Circuit.bounds` and change what a saved viewport looks like. That makes *every*
          // unresolved component share the same key, so the overlap test below would report all
          // but the first as duplicates, and the nudge loop that follows skips anything with a
          // zero-area box; deleting them. That is precisely the data loss D8 exists to prevent,
          // reintroduced through the back door. Overlap detection is meaningless without
          // geometry, so these bypass it and are added directly.
          if comp is UnresolvedComponent {
            try mutator.add(dest, comp)
            continue
          }

          let bds = comp.bounds
          if let conflict = componentsAt[bds] {
            // Upstream's message names the *conflicting* component's location twice; the
            // second argument is `comp.getFactory().getName() + conflict.getLocation()`, not
            // `comp.getLocation()`. Preserved: the text ends up in the error list a
            // differential run compares byte for byte.
            let message = FileStrings.fileComponentOverlapError(
              conflict.factory.name + String(describing: conflict.location),
              comp.factory.name + String(describing: conflict.location))
            reader.addError(message, circData.circuit.name)
            overlapComponents.append(comp)
          } else {
            try mutator.add(dest, comp)
            componentsAt[bds] = comp
          }
        } catch let error as XmlReaderException {
          let context =
            circData.circuit.name + "." + XmlCircuitReader.toComponentString(subElement)
          reader.addErrors(error, context)
        }
      } else if subEltName == "wire" {
        do {
          try addWire(dest, mutator, subElement)
        } catch let error as XmlReaderException {
          let context = circData.circuit.name + "." + XmlCircuitReader.toWireString(subElement)
          reader.addErrors(error, context)
        }
      }
    }

    // Nudge each exactly-overlapping component clear of the one that got there first.
    for original in overlapComponents {
      let bds = original.bounds
      if bds.height == 0 || bds.width == 0 {
        // Ignore empty boxes.
        continue
      }
      var d = 0
      repeat {
        d += 10
      } while componentsAt[bds.translate(d, d)] != nil && d < 100_000
      let loc = original.location.translate(d, d)
      let attrs = original.attributeSet.copy()
      let moved = try original.factory.createComponent(location: loc, attributes: attrs)
      componentsAt[moved.bounds] = moved
      try mutator.add(dest, moved)
    }
  }

  /// `comp.getAttributeSet().getValue(Text.ATTR_TEXT).isEmpty()`, reached by attribute name
  /// because `com.cburch.logisim.std.base.Text` is M4 work. See `TextComponent`.
  private func isEmptyTextBox(_ comp: any Component) -> Bool {
    guard let attribute = comp.attributeSet.attribute(named: TextComponent.textAttributeName),
      let raw = comp.attributeSet.rawValue(attribute),
      let text = attribute.standardString(for: raw)
    else {
      // An absent value is `""` in Java, whose `isEmpty()` is true. A `Text` component whose
      // factory does not define the attribute cannot occur.
      return true
    }
    return text.isEmpty
  }

  // MARK: - Dynamic appearance

  /// Java: `buildDynamicAppearance(CircuitData)`.
  ///
  /// The `visible-*` shapes, resolved only now because each one names a component that had to
  /// exist first. Note `layer` counts **every** child of every `<appear>` element, not just the
  /// dynamic ones, so it is the index the shape occupied in the original document, which is
  /// what lets a dynamic shape be re-inserted at its original depth among the static ones.
  private func buildDynamicAppearance(_ circData: XmlReader.CircuitData) {
    guard let handler = CircuitAppearanceReader.handler else { return }

    let dest = circData.circuit
    var shapes: [AppearanceShape] = []
    var layers: [Int] = []
    var layer = -1
    for appearElt in XmlIterator.forChildElements(circData.circuitElement, "appear") {
      for sub in XmlIterator.forChildElements(appearElt) {
        layer += 1
        // Dynamic shapes are handled here; static ones are already done.
        if !sub.tagName.hasPrefix("visible-") { continue }
        do {
          if let shape = try handler.createShape(sub, pins: nil, circuit: dest) {
            shapes.append(shape)
            layers.append(layer)
          } else {
            reader.addError(
              FileStrings.fileAppearanceNotFound(sub.tagName),
              circData.circuit.name + "." + sub.tagName)
          }
        } catch {
          reader.addError(
            FileStrings.fileAppearanceError(sub.tagName),
            circData.circuit.name + "." + sub.tagName)
        }
      }
    }

    if !shapes.isEmpty {
      if circData.appearance == nil {
        circData.appearance = shapes
      } else {
        // Java: `circData.appearance.add(layers.get(i), shapes.get(i))`: a positional insert,
        // and each insert shifts the indices of everything after it. Reproduced literally,
        // including the fact that an out-of-range layer would throw
        // IndexOutOfBoundsException; the index is clamped instead, because a layer beyond the
        // current list length is reachable from a hand-edited file and aborting the load over
        // a drawing detail is the wrong trade (D13).
        for shapeId in shapes.indices {
          let index = min(max(0, layers[shapeId]), circData.appearance?.count ?? 0)
          circData.appearance?.insert(shapes[shapeId], at: index)
        }
      }
    }
    if let appearance = circData.appearance, !appearance.isEmpty {
      handler.setAppearance(appearance, for: dest)
    }
  }

  // MARK: - Transaction

  /// Java: `CircuitTransaction.execute()` → `run(mutator)`.
  ///
  /// The two passes are separate and ordered: every circuit is populated before any dynamic
  /// appearance is resolved, because a dynamic shape in circuit A can refer to a component in
  /// circuit B.
  func execute() throws {
    let mutator = CircuitLoadMutator()
    for circuitData in circuitsData {
      try buildCircuit(circuitData, mutator)
    }
    for circuitData in circuitsData {
      buildDynamicAppearance(circuitData)
    }

    // ══ RE-DERIVE EVERY SUBCIRCUIT'S PORTS BEFORE REPAIRING WIRES ═════════════════════════
    //
    //     final var modified = mutator.getModifiedCircuits();
    //     for (final var circuit : modified) {
    //       final var repl = mutator.getReplacementMap(circuit);
    //       if (repl != null) {
    //         final var pins = circuit.getAppearance().getCircuitPins();
    //         pins.transactionCompleted(repl);
    //       }
    //     }
    //                                                ; CircuitTransaction.java:47-61
    //
    // Upstream's own comment on that block says it "needs to happen before wires are repaired
    // because it could lead to some wires being split", and this is the ordering `execute()`
    // has always claimed to follow.
    //
    // It is load-bearing, not bookkeeping. A `<comp name="ALU"/>` placed in `main` is created
    // while the `ALU` circuit is still empty whenever `ALU` is written after `main`, which is
    // the usual layout, since the top-level circuit comes first. `computePorts` then sees no
    // `Pin`, produces no ends, and the placement is invisible to `CircuitPoints`, so
    // `WireRepair` merges wires straight through the point where a port belongs.
    //
    // One pass is enough, and the direction matters: a circuit's ports come from its own
    // `Pin`s, never from the blocks placed inside it, so refreshing every circuit's placements
    // once cannot leave a second generation stale. That is why upstream also does it once.
    for circuitData in circuitsData {
      if let factory = circuitData.circuit.subcircuitFactory as? CircuitSubcircuitFactory {
        factory.refreshPortsAfterSourceChanged()
      }
    }

    // ══ THE WIRE-REPAIR PASS: PORTED, CORRECT, AND OFF BY ONE LINE IN ANOTHER MODULE ══════
    //
    //     for (final var circuit : modified) { new WireRepair(circuit).run(mutator); }
    //                                                       : CircuitTransaction.java:63-68
    //
    // `CircuitTransaction.execute()` repairs wires after EVERY transaction, and loading a file
    // is a transaction, so the wire set upstream saves is not the wire set it read. It is
    // ported, faithfully, in `WireRepair.swift`, and the call would go exactly here: after the
    // appearance pass, matching upstream's own ordering comment ("this needs to happen before
    // wires are repaired because it could lead to some wires being split").
    //
    // MEASURED, ALL FOUR WAYS, 2026-09-05:
    //
    //   repair off, before the fixes below     canonical 539 / 0    migration 434 / 105
    //   repair on, before the fixes below     canonical 488 / 51   migration 412 / 127
    //   repair on, with them                  canonical 519 / 20   migration 440 /  99
    //   repair on, + the ROM fix named below  canonical 539 / 0    migration 456 /  83
    //
    // So the pass is CORRECT and worth **+22 migration at zero canonical cost**. It is off only
    // because the last line of that table needs a one-line change in `LogisimStd`, which this
    // branch does not own. The pass itself was already proven on an isolated fixture, one 8-bit
    // west-facing splitter across three wires, byte-identical to the 4.1.0 oracle, and by
    // `WireRepairTests`.
    //
    // What was wrong is its INPUT: `WireRepair` asks the circuit where things connect, and that
    // answer is only as good as every component's `ends`. Three defects poisoned it. Two are
    // fixed above and were in this module after all, not in `LogisimStd` as previously recorded:
    //
    //   * a `<comp>` naming a circuit declared LATER in the file was cached as an
    //     `UnresolvedComponent` by `loadKnownComponents` and never retried, so it had no ends
    //     and wires merged straight through its ports, see the note on `loadKnownComponents`;
    //   * subcircuit ports were computed while the source circuit was still empty and never
    //     re-derived, see the port-refresh pass above.
    //
    // ── THE ONE REMAINING BLOCKER, and it is one line ────────────────────────────────────────
    //
    // `LogisimStd/Memory/RamAppearance.swift`, in `ports(_:)`:
    //
    //     let xpos = offsetBounds(attrs).width          // ← 250 for a non-classic ROM
    //
    // Upstream passes the *instance's* width, not `RamAppearance`'s own:
    //
    //     ps[getDataOutIndex(i, attrs)] =
    //         getDataOutPort(i, attrs, instance.getBounds().getWidth());
    //                                              : RamAppearance.java:183
    //
    // and for a ROM that resolves through `Rom.getOffsetBounds`, which is `SymbolWidth + 40` in
    // BOTH branches (`Rom.java:166-173`); always 240, whereas `RamAppearance.getBounds` uses
    // `SymbolWidth + xoffset` = 250 in the non-classic branch. `Rom.offsetBounds` is ported
    // correctly; only the `xpos` handed to `dataOutPort` comes from the wrong one.
    //
    // Every ROM therefore carries its data-out port 10 units too far right, `doSplits` cuts the
    // wire under it at the wrong x, and that alone accounted for **all 20** canonical
    // regressions: 50 ROM placements, verified by dumping ends from the 4.1.0 jar and from this
    // port and diffing them per circuit. Example, `3.3.0__case-515.circ` circuit `main`:
    //
    //     java   ROM loc=(850,360) bounds=240x220 ends=(850,370) (1090,420)
    //     swift  ROM loc=(850,360)                ends=(850,370) (1100,420)
    //
    // Fix: give `ports` the factory's width (`Rom`/`Ram` each pass their own
    // `offsetBounds(attributes).width`), then delete the environment check below and this note.
    //
    // The ROM defect described above is fixed (`RamAppearance.ports` now takes the factory's own
    // `offsetBounds(attributes).width`, so `xpos` is 240 for a ROM and 250 for a RAM, as in Java),
    // so the environment gate that stood here has served its purpose and is gone. `WireRepair`
    // runs unconditionally, as it does in 4.1.0.
    for circuitData in circuitsData {
      WireRepair(circuit: circuitData.circuit).run()
    }
  }

  // MARK: - Error context

  /// Java: `toComponentString(Element)`: `"%s(%s)"` of name and loc.
  private static func toComponentString(_ elt: XMLElement) -> String {
    "\(elt.getAttribute("name"))(\(elt.getAttribute("loc")))"
  }

  /// Java: `toWireString(Element)`: `"w%s-%s"` of from and to.
  private static func toWireString(_ elt: XMLElement) -> String {
    "w\(elt.getAttribute("from"))-\(elt.getAttribute("to"))"
  }
}

/// `com.cburch.logisim.std.memory.Ram` / `Mem`, reduced to the three tokens the Holy Cross
/// fixup in `getComponent` names. Same rationale as `TextComponent` in `XmlReaderSupport.swift`:
/// the real classes are M5, and a `.circ` token is a stabler hook than an object identity that
/// does not exist yet.
public enum RamComponent {
  /// `Ram._ID`.
  public static let id = "RAM"
  /// `Mem.ENABLES_ATTR.getName()`.
  public static let enablesAttributeName = "enables"
  /// `Mem.USELINEENABLES`.
  public static let useLineEnables = AttributeOption(name: "line")
  /// `Mem.USEBYTEENABLES`.
  public static let useByteEnables = AttributeOption(name: "byte")
}
