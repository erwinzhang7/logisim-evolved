// XmlReader.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution),
// specifically `src/main/java/com/cburch/logisim/file/XmlReader.java`.
// Copyright by the Logisim-evolution developers. This translation is a derivative work and is
// therefore GPL-3.0-only. See LICENSE.md.
// SPDX-License-Identifier: GPL-3.0-only
//
// ── What this file is ───────────────────────────────────────────────────────────────────────
//
// The `.circ` reader: parse the XML, run every version-migration repair in order, then walk the
// tree building libraries, circuits and components. It is written against Foundation's
// `XMLDocument`/`XMLElement` because the migration passes mutate a *live* DOM, `insertBefore`,
// `removeChild`, `setAttribute`, moving a node between parents, and those shapes map onto
// Foundation one-for-one. The DOM vocabulary itself lives in `XmlDom.swift`, and the three
// places the two DOMs genuinely differ are documented there.
//
// ── D13 throughout ──────────────────────────────────────────────────────────────────────────
//
// Java has two error channels here and they mean different things:
//
//   * `XmlReaderException` is *checked* and means "record this and keep going"; a broken
//     component does not stop the rest of the file loading. Around ten call sites catch it,
//     append to `ReadContext.messages`, and continue. That is preserved exactly.
//   * Everything else, `IllegalArgumentException` from `AttributeSet.setValue`,
//     `IllegalArgumentException` from `LogisimVersion`, `NullPointerException` from a repair
//     on a structurally impossible file, is unchecked and aborts the load. Per D13 those
//     become Swift `throw`s rather than traps, which is why almost every method below is
//     `throws`: swallowing them would hide precisely the malformed-file errors the loader
//     exists to surface.
//
// ── The migration gates, and what is actually verified ──────────────────────────────────────
//
//   | gate            | covered by the 594-file corpus? |
//   |-----------------|---------------------------------|
//   | `< 2.3.0`       | yes: via a synthesised fixture that drops `source=` (see below) |
//   | `< 2.6.3`       | **NO. UNVERIFIED.** See `repairForWiringLibrary`. |
//   | `< 4.0.0` (pin) | yes, 463 files |
//   | `< 4.1.0-dev`   | yes |
//
// The `< 2.3.0` coverage works because a missing `source=` attribute parses to `0.0.0`, which
// is below both old gates *and* triggers the `== 0.0.0` early return, a genuinely reachable
// path, not a synthetic one.

import Foundation
import LogisimKernel

/// `com.cburch.logisim.file.XmlReader`.
///
/// Java constructs one per read (`new XmlReader(loader, file).readLibrary(is, proj)`) and keeps
/// `loader` and `srcFilePath` as instance state; that is reproduced. `XmlFileReader` at the
/// bottom of this file is the adaptor that satisfies `Loader`'s `LogisimFileReading` seam.
public final class XmlReader {

  /// `XmlReader.CircuitData`: the per-circuit scratch record shared with `XmlCircuitReader`.
  ///
  /// A class, not a struct: `XmlCircuitReader` mutates `appearance` on a record the caller
  /// still holds, and `buildDynamicAppearance` inserts into the list `loadAppearance` built.
  public final class CircuitData {
    public let circuitElement: XMLElement
    public let circuit: Circuit
    /// Components resolved during the first pass, keyed by the `<comp>` element that produced
    /// them. D4: keyed by DOM node identity, exactly as Java's `Map<Element, Component>` is.
    public var knownComponents: [ObjectIdentifier: any Component] = [:]
    /// Kept alongside the map because the key is an `ObjectIdentifier` and the elements must be
    /// held alive for those identities to stay valid and distinct.
    var knownComponentElements: [ObjectIdentifier: XMLElement] = [:]
    public var appearance: [AppearanceShape]?

    public init(circuitElement: XMLElement, circuit: Circuit) {
      self.circuitElement = circuitElement
      self.circuit = circuit
    }

    func knownComponent(for element: XMLElement) -> (any Component)? {
      knownComponents[ObjectIdentifier(element)]
    }

    func setKnownComponent(_ component: any Component, for element: XMLElement) {
      knownComponents[ObjectIdentifier(element)] = component
      knownComponentElements[ObjectIdentifier(element)] = element
    }
  }

  /// `XmlReader.ReadContext`: the per-load accumulator: the file being built, the version that
  /// produced it, the library handle table, and the running error list.
  public final class ReadContext {
    public let file: LogisimFile
    public var sourceVersion: LogisimVersion = LogisimVersion(0, 0, 0)
    /// Java's `HashMap<String, Library> libs`: `<lib name="3">` → the resolved library.
    public var libs: [String: Library] = [:]
    public private(set) var messages: [String] = []

    /// Java reaches these through the enclosing `XmlReader` instance; Swift nested classes have
    /// no implicit outer reference, so they are passed in. `loader` is unowned because the
    /// context never outlives the read.
    unowned let loader: Loader
    let srcFilePath: String?

    init(file: LogisimFile, loader: Loader, srcFilePath: String?) {
      self.file = file
      self.loader = loader
      self.srcFilePath = srcFilePath
    }

    /// Java: `addError(String, String)`.
    public func addError(_ message: String, _ context: String) {
      messages.append(message + " [" + context + "]")
    }

    /// Java: `addErrors(XmlReaderException, String)`.
    public func addErrors(_ exception: XmlReaderException, _ context: String) {
      for message in exception.messages {
        messages.append(message + " [" + context + "]")
      }
    }

    /// Java: `findLibrary(String)`.
    ///
    /// An empty or absent `lib=` means "this file's own circuits", so it resolves to the file
    /// itself, which is why `LogisimFile` must be a `Library`.
    public func findLibrary(_ libName: String?) throws -> Library {
      if StringUtil.isNullOrEmpty(libName) { return file }
      guard let result = libs[libName!] else {
        throw XmlReaderException(FileStrings.libMissingError(libName!))
      }
      return result
    }

    // MARK: initAttributeSet

    /// Java: `initAttributeSet(Element, AttributeSet, AttributeDefaultProvider, boolean, boolean)`.
    ///
    /// Two subtleties that a straightforward reading loses:
    ///
    /// * The `<a>` scan runs to completion **before** the `attrs == null` early return, and the
    ///   messages it collected are then thrown away. So a `<tool>` with no attribute set never
    ///   reports `attrNameMissingError` even when it should. Preserved.
    /// * The write loop re-fetches `attrs.getAttributes()` on every iteration and indexes by
    ///   position, because setting one attribute can change the *list*; a splitter grows and
    ///   shrinks its per-bit attributes as `fanout` and `incoming` are assigned. An
    ///   `for attr in attrs.attributes` translation reads a stale snapshot and drops the new
    ///   attributes silently.
    public func initAttributeSet(
      _ parent: XMLElement,
      _ attrs: (any AttributeSet)?,
      _ defaults: (any AttributeDefaultProvider)?,
      _ isHolyCross: Bool,
      _ isEvolution: Bool
    ) throws {
      var messages: [String]? = nil

      var attrsDefined: [String: String] = [:]
      for attrElt in XmlIterator.forChildElements(parent, "a") {
        if !attrElt.hasAttribute("name") {
          if messages == nil { messages = [] }
          messages?.append(FileStrings.attrNameMissingError)
        } else {
          let attrName = attrElt.getAttribute("name")
          var attrVal: String
          if attrElt.hasAttribute("val") {
            attrVal = attrElt.getAttribute("val")
            if attrName == "filePath" {
              // De-relativize the path against the directory the .circ itself came from.
              //
              // Deviation, deliberate: Java computes `srcFilePath.substring(0,
              // srcFilePath.lastIndexOf(File.separator))`, which throws
              // StringIndexOutOfBoundsException, aborting the whole load, when the path
              // contains no separator. `srcFilePath` is `File.getAbsolutePath()`, so on a real
              // load it always does; the crash is unreachable in practice and a crash is the
              // wrong answer for a path that somehow is not absolute (D13). An empty directory
              // is used instead, which makes `Paths.get("", val)` yield `val`: the same result
              // as having no source file at all.
              var dirPath = ""
              if let srcFilePath, let separator = srcFilePath.lastIndex(of: "/") {
                dirPath = String(srcFilePath[srcFilePath.startIndex..<separator])
              }
              attrVal = javaPathsGet(dirPath, attrVal)
            }
          } else {
            attrVal = attrElt.textContent
          }
          attrsDefined[attrName] = attrVal
        }
      }

      guard let attrs else { return }

      let ver = sourceVersion
      let setDefaults = defaults != nil && !defaults!.isAllDefaultValues(attrs, version: ver)

      var index = 0
      while true {
        let attrList = attrs.attributes
        if index >= attrList.count { break }
        let attr = attrList[index]
        let attrName = attr.name
        let attrVal = attrsDefined[attrName]

        if attrVal == nil {
          if attr === ProbeAttributes.probeAppearance {
            try attrs.setValue(ProbeAttributes.probeAppearance, StdAttr.appearClassic)
          } else if attr === StdAttr.appearance {
            if isHolyCross {
              try attrs.setValue(StdAttr.appearance, StdAttr.appearClassic)
            } else if isEvolution {
              try attrs.setValue(StdAttr.appearance, StdAttr.appearEvolution)
            } else {
              // Dead on the file-loading path: `toLogisimFile` initialises `isEvolutionFile`
              // to true and never clears it, so this branch is unreachable there. Ported
              // anyway because `XmlCircuitReader` threads the same flag through and a future
              // caller could pass false. Note Java would NPE here when `defaults` is null;
              // the optional chain makes that a no-op instead (D13; a crash is never the
              // right answer to file input).
              if let value = defaults?.defaultAttributeValue(attr, version: ver) {
                try attrs.setRawValue(attr, value)
              }
            }
          } else if setDefaults {
            if let value = defaults?.defaultAttributeValue(attr, version: ver) {
              try attrs.setRawValue(attr, value)
            }
          }
        } else {
          // Java wraps parse *and* setValue in `catch (NumberFormatException)`. Only `parse`
          // raises one; `setValue` raises `IllegalArgumentException`, which is not a subclass,
          // so it escapes and aborts the load. The split below preserves that exactly: a parse
          // failure becomes a recorded message, an `AttributeSetError` propagates.
          var parsed: AttributeValue?
          do {
            parsed = try attr.parseToAttributeValue(attrVal!)
          } catch {
            if messages == nil { messages = [] }
            messages?.append(FileStrings.attrValueInvalidError(attrVal!, attrName))
            parsed = nil
          }
          if let parsed {
            try attrs.setRawValue(attr, parsed)
          }
        }
        index += 1
      }

      if let messages {
        throw XmlReaderException(messages)
      }
    }

    // MARK: Mouse mappings and toolbar

    /// Java: `initMouseMappings(Element, boolean, boolean)`.
    func initMouseMappings(_ elt: XMLElement, _ isHolyCross: Bool, _ isEvolution: Bool) throws {
      let map = file.options.mouseMappings
      for subElement in XmlIterator.forChildElements(elt, "tool") {
        var tool: Tool
        do {
          tool = try toTool(subElement)
        } catch let error as XmlReaderException {
          addErrors(error, "mapping")
          continue
        }

        let modsStr = subElement.getAttribute("map")
        if modsStr.isEmpty {
          loader.showError(FileStrings.mappingMissingError)
          continue
        }
        let mods: Int32
        do {
          mods = try InputEventUtil.fromString(modsStr)
        } catch {
          loader.showError(FileStrings.mappingBadError(modsStr))
          continue
        }

        tool = tool.cloneTool()
        do {
          try initAttributeSet(subElement, tool.attributeSet, tool, isHolyCross, isEvolution)
        } catch let error as XmlReaderException {
          addErrors(error, "mapping." + tool.name)
        }

        map.setToolFor(modifiers: mods, tool: tool)
      }
    }

    /// Java: `initToolbarData(Element, boolean, boolean)`.
    ///
    /// Note the two forced overrides at the end: a toolbar entry's saved appearance is
    /// discarded and replaced with the *current preference*, so the toolbar always shows the
    /// user's chosen style regardless of what the file said. That is upstream behaviour, and it
    /// is why `AppearancePreferences` exists in `XmlReaderSupport.swift`: D9 forbids the model
    /// reading `AppPreferences` directly.
    func initToolbarData(_ elt: XMLElement, _ isHolyCross: Bool, _ isEvolution: Bool) throws {
      let toolbar = file.options.toolbarData
      for subElement in XmlIterator.forChildElements(elt) {
        if subElement.tagName == "sep" {
          toolbar.addSeparator()
        } else if subElement.tagName == "tool" {
          var tool: Tool
          do {
            tool = try toTool(subElement)
          } catch let error as XmlReaderException {
            // D8: upstream drops the entry here and the user's toolbar layout is lost on save.
            // Keep the element instead; the error is still recorded, so a genuinely broken
            // reference is still reported, it just is not also destroyed.
            addErrors(error, "toolbar")
            toolbar.addTool(
              PreservedTool(name: subElement.getAttribute("name"), rawElement: subElement))
            continue
          }
          // ── Preserve only when there is something to preserve ────────────────────────────
          //
          // Resolving is not enough to round-trip: a tool that carries no attribute set reads
          // its `<a>` children into nothing, and upstream then writes a bare `<tool …/>`;
          // silently dropping whatever the user had configured. D8's answer is to keep the raw
          // element, and it is right *when the element carries attributes*.
          //
          // It is wrong when it does not, and that cost 79 files on the migration gate. A
          // preserved element is re-emitted verbatim, `lib=` handle included, and libraries are
          // renumbered from 0 on write. Any migration pass that inserts a library, the
          // `<4.0.0` repair adds `#FPArithmetic` at index 4, shifts every handle above it, so
          // the frozen one now names a different library. Measured: `<tool lib="8"
          // name="Poke Tool"/>` where the oracle writes `lib="9"`, on every toolbar entry of
          // every file whose `#Base` tools are still placeholders.
          //
          // With no `<a>` children the raw element holds nothing the resolved tool cannot
          // reproduce, so preserving it buys no fidelity and costs the handle. Fall through to
          // the normal path, which is what Java does unconditionally here: it clones, calls
          // `initAttributeSet` (a no-op against a null set) and adds the real tool.
          //
          // Note `attributeSet == nil` is the CORRECT state for most of `#Base`: Java's
          // `PokeTool`, `EditTool`, `MenuTool` and `WiringTool` all inherit
          // `Tool.getAttributeSet()`'s `null` (`EditTool` forwards to `SelectTool`, which does
          // not override it either). `TextTool` is the one that genuinely has a set.
          if tool.attributeSet == nil,
            !XmlIterator.forChildElements(subElement, "a").isEmpty
          {
            toolbar.addTool(
              PreservedTool(name: subElement.getAttribute("name"), rawElement: subElement))
            continue
          }
          tool = tool.cloneTool()
          do {
            try initAttributeSet(subElement, tool.attributeSet, tool, isHolyCross, isEvolution)
          } catch let error as XmlReaderException {
            addErrors(error, "toolbar." + tool.name)
          }
          if let attributeSet = tool.attributeSet {
            if attributeSet.containsAttribute(ProbeAttributes.probeAppearance) {
              try attributeSet.setValue(
                ProbeAttributes.probeAppearance, ProbeAttributes.defaultProbeAppearance)
            }
            if attributeSet.containsAttribute(StdAttr.appearance) {
              try attributeSet.setValue(
                StdAttr.appearance, AppearancePreferences.defaultAppearance)
            }
          }
          toolbar.addTool(tool)
        }
      }
    }

    // MARK: Components, maps and appearance

    /// Java: `loadKnownComponents(Element, boolean, boolean)`.
    ///
    /// The pre-pass that resolves every `<comp>` before any circuit is populated, so that
    /// `loadAppearance` can find the pins a custom appearance refers to. `XmlReaderException`
    /// is swallowed here without being recorded; the same element is retried in
    /// `buildCircuit`, which *does* record the failure, so an error is reported exactly once.
    ///
    /// ── A D8 placeholder must NOT be cached here, and the reason is an ordering one ─────────
    ///
    /// This runs **inside** the loop that creates the circuits (`case "circuit"` calls it in the
    /// same iteration that does `file.addCircuit`), so when the *first* `<circuit>` is
    /// pre-scanned only that one circuit exists in the file. Every `<comp>` in it that names a
    /// circuit declared further down, which is the normal layout, since `main` is written first
    /// and the blocks it instantiates come after, resolves to no tool at all.
    ///
    /// Upstream's `getComponent` throws `XmlReaderException` there, `loadKnownComponents`
    /// swallows it, nothing is recorded, and `buildCircuit` retries the element later with every
    /// circuit present. The retry is what makes it work.
    ///
    /// The port cannot rely on that, because D8 turns the same failure into a *successful*
    /// `UnresolvedComponent` instead of a throw. Cached, it would be handed straight back by
    /// `circData.knownComponent(for:)` and the retry would never happen, so a perfectly
    /// resolvable subcircuit would spend its whole life as an opaque placeholder: **no ends**,
    /// therefore invisible to `CircuitPoints`, therefore `WireRepair` merges wires straight
    /// through its ports, and it never propagates either.
    ///
    /// Measured on a corpus file whose `main` places a subcircuit and
    /// `HEX_DECODER` and is written before both: 19 of the file's 24 subcircuit placements
    /// registered with their factory and the 5 inside `main` registered with none.
    ///
    /// Skipping the placeholder costs nothing that D8 wants. A placeholder is never a `Pin`, so
    /// `loadAppearance` has no use for it, and if the element really is unresolvable then
    /// `buildCircuit`'s own `getComponent` mints an identical one a moment later.
    func loadKnownComponents(
      _ elt: XMLElement, into data: CircuitData, _ isHolyCross: Bool, _ isEvolution: Bool
    ) throws {
      for sub in XmlIterator.forChildElements(elt, "comp") {
        do {
          let component = try XmlCircuitReader.getComponent(
            sub, self, isHolyCross, isEvolution)
          if component is UnresolvedComponent { continue }
          data.setKnownComponent(component, for: sub)
        } catch is XmlReaderException {
          continue
        }
      }
    }

    /// Java: `loadMap(Element, String, Circuit)`: one `<boardmap>` element.
    ///
    /// Upstream hands the parsed map to the FPGA `MappableResourcesContainer` and nothing else
    /// keeps the source XML. `Circuit.addLoadedMap` additionally takes the `<mc>` children
    /// verbatim: upstream *re-generates* them on save from FPGA data-model code well outside
    /// M2, and M2's pass condition is byte-exact round-tripping, so the elements have to
    /// survive. The parsed map is still the authority; the verbatim half is what the FPGA
    /// tranche later replaces.
    @discardableResult
    func loadMap(_ board: XMLElement, _ boardName: String, _ circ: Circuit)
      -> [String: CircuitMapInfo]
    {
      var map: [String: CircuitMapInfo] = [:]
      for cmap in XmlIterator.forChildElements(board, "mc") {
        let key = cmap.getAttribute("key")
        if StringUtil.isNullOrEmpty(key) { continue }
        if cmap.hasAttribute("open") {
          map[key] = CircuitMapInfo()
        } else if cmap.hasAttribute("vconst") {
          guard let value = javaParseInt64(cmap.getAttribute("vconst")) else { continue }
          map[key] = CircuitMapInfo(constant: value)
        } else if cmap.hasAttribute("valx") && cmap.hasAttribute("valy")
          && cmap.hasAttribute("valw") && cmap.hasAttribute("valh")
        {
          // Backward compatibility branch, kept including its use of parseUnsignedInt: a
          // coordinate above 2^31 wraps to a negative int rather than being rejected.
          guard let x = javaParseUnsignedInt32(cmap.getAttribute("valx")),
            let y = javaParseUnsignedInt32(cmap.getAttribute("valy")),
            let w = javaParseUnsignedInt32(cmap.getAttribute("valw")),
            let h = javaParseUnsignedInt32(cmap.getAttribute("valh"))
          else {
            continue
          }
          map[key] = CircuitMapInfo(rect: BoardRectangle(x: x, y: y, width: w, height: h))
        } else if let info = MapComponent.mapInfo(from: cmap) {
          map[key] = info
        }
      }
      // Java's guard, kept: a `<boardmap>` whose every `<mc>` failed to parse is dropped
      // entirely, and the writer then has no board to emit either, so the round trip stays
      // consistent rather than resurrecting an element the reader rejected.
      if !map.isEmpty {
        circ.addLoadedMap(boardName, map, rawElement: board)
      }
      return map
    }

    /// Java: `loadAppearance(Element, CircuitData, String)`; the **static** shapes only.
    ///
    /// Dynamic shapes (`visible-*`) are deliberately left for `XmlCircuitReader`, because they
    /// name components that do not exist until the whole circuit tree has been built.
    ///
    /// With no appearance handler installed the method returns without touching `circData` and
    /// without recording anything; see `CircuitAppearanceReader` for why "silently skip" is
    /// the right degradation rather than "report every shape as unknown".
    ///
    /// **D8 first, before any of that.** "Silently skip" is only defensible for the *parse*; it
    /// is not defensible for the element. `CircuitAppearanceReader.handler` is nil at this
    /// milestone and nothing installs one (the `CanvasModel` it needs is M6, D6), so returning
    /// here without keeping the element destroys every custom circuit appearance on a plain
    /// open-and-save: and destroys it in the worst possible way, because
    /// `<a name="appearance" val="custom"/>` is an ordinary attribute that round-trips fine. The
    /// saved file then advertises an appearance whose shapes are gone. Measured: 87 of the 539
    /// canonical corpus files fail the round-trip gate on exactly this.
    ///
    /// So the element is absorbed verbatim into the circuit first, unconditionally, exactly as
    /// `<boardmap>` is by `loadMap` → `Circuit.addLoadedMap(_:_:rawElement:)`. `XmlWriter`
    /// re-emits it through `Circuit.rawAppearance` only when no live
    /// `CircuitAppearanceWriter.handler` claims the circuit, so installing the M6 model later
    /// takes precedence automatically and this call becomes dead weight rather than a conflict.
    /// It is absorbed even when a handler *is* installed: the stored copy is unread in that case,
    /// and making the preservation conditional on the absence of a handler is the kind of
    /// asymmetry that stops being true the moment one half is wired up.
    func loadAppearance(_ appearElt: XMLElement, _ circData: CircuitData, _ context: String) {
      circData.circuit.absorbAppearance(appearElt)

      guard let handler = CircuitAppearanceReader.handler else { return }

      var pins: [AnyObject] = []
      for component in circData.knownComponents.values where component.factory.isPin {
        pins.append(handler.pinInfo(location: component.location, component: component))
      }

      var shapes: [AppearanceShape] = []
      for sub in XmlIterator.forChildElements(appearElt) {
        if sub.tagName.hasPrefix("visible-") { continue }
        do {
          if let shape = try handler.createShape(sub, pins: pins, circuit: nil) {
            shapes.append(shape)
          } else {
            addError(
              FileStrings.fileAppearanceNotFound(sub.tagName), context + "." + sub.tagName)
          }
        } catch {
          addError(FileStrings.fileAppearanceError(sub.tagName), context + "." + sub.tagName)
        }
      }
      if !shapes.isEmpty {
        if circData.appearance == nil {
          circData.appearance = shapes
        } else {
          circData.appearance?.append(contentsOf: shapes)
        }
      }
    }

    // MARK: VHDL

    /// D8 for `<vhdl>`. No upstream counterpart.
    ///
    /// The `<vhdl>` element is a whole VHDL entity: the user's own source text, typically
    /// hundreds of lines of it, which exists nowhere else in the project. Upstream drops the
    /// element whenever `VhdlContent.parse` returns null; this port takes that branch for *every*
    /// `<vhdl>` element, because `VhdlContentReader.handler` is nil and the VHDL subsystem sits
    /// in the parity backlog. Two corpus files carry four and one entity respectively, and both
    /// lose all of it on a plain open-and-save.
    ///
    /// The element is therefore kept verbatim, the same treatment `<boardmap>` and `<appear>`
    /// get, and `XmlWriter.fromLogisimFile` re-emits it through `VhdlContentPreserving`.
    ///
    /// **Why it has to go through `LogisimFileSeams.makeVhdlEntity`.** The writer's only route to
    /// a `<vhdl>` element is `LogisimFile.vhdlContents`, which is derived; it filters
    /// `addToolList` for tools whose factory is a `VhdlEntityFactory`. There is no public way to
    /// put a tool into that list except `addVhdlContent`, and that is a no-op unless the seam is
    /// installed. So the reader installs a *preserving* maker, and only when the slot is still
    /// empty: whenever the real VHDL port (M5) installs one first, this never fires and the
    /// parsed path is used instead. The alternative would be a second raw-element store on
    /// `LogisimFile` itself, which is a file this agent does not own.
    func preserveVhdlEntity(_ element: XMLElement, name: String) {
      if LogisimFileSeams.makeVhdlEntity == nil {
        LogisimFileSeams.makeVhdlEntity = { PreservedVhdlEntityFactory(content: $0) }
      }
      guard let content = PreservedVhdlContent(name: name, element: element) else { return }
      file.addVhdlContent(content)
    }

    // MARK: Libraries

    /// Java: `toLibrary(Element, boolean, boolean)`.
    ///
    /// D8 addition, marked as such: when the descriptor resolves to a `MissingLibrary` the
    /// `<lib>` element's children are absorbed verbatim so the declaration and every component
    /// that references it survive load → save. Upstream returns null here and the components
    /// are permanently lost on the next save.
    func toLibrary(_ elt: XMLElement, _ isHolyCross: Bool, _ isEvolution: Bool) throws
      -> Library?
    {
      if !elt.hasAttribute("name") {
        loader.showError(FileStrings.libNameMissingError)
        return nil
      }
      if !elt.hasAttribute("desc") {
        loader.showError(FileStrings.libDescMissingError)
        return nil
      }
      let name = elt.getAttribute("name")
      let desc = elt.getAttribute("desc")
      let ret = loader.loadLibrary(desc: desc)
      libs[name] = ret

      if let missing = ret as? MissingLibrary {
        missing.absorb(libraryElement: elt)
        return missing
      }

      for subElt in XmlIterator.forChildElements(elt, "tool") {
        if !subElt.hasAttribute("name") {
          loader.showError(FileStrings.toolNameMissingError)
        } else {
          let toolStr = subElt.getAttribute("name")
          // Resolving is not enough; the tool must also be able to CARRY the attributes.
          // A builtin shell's tools exist by name but have no attribute set until M4/M5, so
          // `initAttributeSet` would discard the values and the writer's
          // `guard let attributes = tool.attributeSet` would then emit nothing at all.
          if let tool = ret.tool(named: toolStr), tool.attributeSet != nil {
            do {
              try initAttributeSet(subElt, tool.attributeSet, tool, isHolyCross, isEvolution)
            } catch let error as XmlReaderException {
              addErrors(error, "lib." + name + "." + toolStr)
            }
          } else if !XmlIterator.forChildElements(subElt, "a").isEmpty {
            // D8 for tools. Upstream drops an unresolvable `<tool>` here and loses its
            // configuration on save; a builtin shell hits this for every tool until the
            // component library lands at M4/M5. Keep the element so the writer can re-emit it
            // unchanged rather than shipping a bare `<lib …/>`.
            //
            // Only when it carries `<a>` children, for the reason spelled out in
            // `initToolbarData`: with none there is nothing to preserve, and re-emitting the
            // raw element then merely reproduces a `<tool>` block Java would not have written
            // at all; `XmlWriter.fromLibrary` appends a library's `<tool>` child only if
            // `addAttributeSetContent` gave it at least one `<a>`.
            ret.absorbUnresolvedTool(subElt)
          }
        }
      }
      return ret
    }

    // MARK: The main walk

    /// Java: `toLogisimFile(Element, Project)`.
    func toLogisimFile(_ elt: XMLElement, _ project: AnyObject?) throws {
      // Determine the version that produced this file.
      let versionString = elt.getAttribute("source")
      var isHolyCrossFile = false
      // Upstream declares this `var isEvolutionFile = true` and the only assignment to it sets
      // it to `true` again, so it is a constant. Preserved as one, with the note, because two
      // branches below read it and would otherwise look live.
      let isEvolutionFile = true
      if versionString.isEmpty {
        sourceVersion = BuildInfo.version
      } else {
        sourceVersion = try LogisimVersion.fromString(versionString)
        isHolyCrossFile = versionString.hasSuffix("-HC")
      }

      if sourceVersion.compare(to: LogisimVersion(2, 7, 2)) < 0 {
        // Upstream pops a modal warning dialog here. D9 keeps AppKit out of this layer, so the
        // same text goes to the loader's message channel; a UI can render it however it likes.
        loader.ui.showMessage(FileStrings.oldFileFormatWarning)
      }

      // First, load the sublibraries.
      var libsToAddAfter: [Library] = []
      var baseLibsToEnable: Set<String> = []
      for o in XmlIterator.forChildElements(elt, "lib") {
        let lib = try toLibrary(o, isHolyCrossFile, isEvolutionFile)
        if let loadedLib = lib as? LoadedLibrary, loadedLib.base is LogisimFile {
          libsToAddAfter.append(loadedLib)
          continue
        }
        if let lib {
          file.addLibrary(lib)
        }
      }
      // Post-process the `.circ`-backed libraries.
      for logiLib in libsToAddAfter {
        // First cleanup step: remove unused libraries from the loaded library.
        LibraryManager.removeUnusedLibraries(logiLib)
        // Second cleanup step: promote base libraries.
        baseLibsToEnable.formUnion(LibraryManager.usedBaseLibraries(logiLib))
      }
      // Promote the non-visible base libraries to top level.
      let builtinLibraries = LibraryManager.builtinNames(loader)
      for lib in libsToAddAfter {
        let libName = lib.name
        if baseLibsToEnable.contains(libName) || !builtinLibraries.contains(libName) {
          baseLibsToEnable.remove(libName)
        }
      }
      // Remove the promoted base libraries from the loaded library, then add it.
      for newLib in libsToAddAfter {
        LibraryManager.removeBaseLibraries(newLib, baseLibraries: baseLibsToEnable)
        file.addLibrary(newLib)
      }

      // Second, create the circuits, empty for now, and the VHDL entities.
      var circuitsData: [CircuitData] = []
      for circElt in XmlIterator.forChildElements(elt) {
        switch circElt.tagName {
        case "vhdl":
          let name = circElt.getAttribute("name")
          if name.isEmpty {
            addError(FileStrings.circNameMissingError, "C??")
          }
          let vhdl = circElt.textContent
          guard let handler = VhdlContentReader.handler else {
            // D8. `VhdlContentReader.handler` is nil at this milestone and nothing installs one,
            // so upstream's own "parse returned null → drop the element" path is taken for
            // *every* `<vhdl>` in every file, and the user's VHDL source is gone from the next
            // save. Keep it verbatim instead; see `preserveVhdlEntity`.
            preserveVhdlEntity(circElt, name: name)
            continue
          }
          guard let contents = handler.parse(name: name, source: vhdl, file: file) else {
            // Same reasoning with a handler installed: a source it cannot parse is still the
            // user's text, and dropping it is still permanent.
            preserveVhdlEntity(circElt, name: name)
            continue
          }
          if circElt.hasAttribute("appearance") {
            let raw = circElt.getAttribute("appearance")
            do {
              handler.setAppearance(try StdAttr.appearance.parse(raw), on: contents)
            } catch {
              addError(
                FileStrings.attrValueInvalidError(raw, StdAttr.appearance.name), "vhdl." + name)
            }
          }
          handler.add(contents, to: file)

        case "circuit":
          let name = circElt.getAttribute("name")
          if name.isEmpty {
            addError(FileStrings.circNameMissingError, "C??")
          }
          // `Circuit.init` throws (it writes its own static attributes, and `setValue`
          // throws), and it takes no `Project`; the port's `Circuit` needs one only for
          // simulator wiring, which is M3.
          let circData = CircuitData(
            circuitElement: circElt,
            circuit: try Circuit(name: name, file: file))
          file.addCircuit(circData.circuit)
          try loadKnownComponents(circElt, into: circData, isHolyCrossFile, isEvolutionFile)
          for appearElt in XmlIterator.forChildElements(circElt, "appear") {
            loadAppearance(appearElt, circData, name + ".appear")
          }
          for boardMap in XmlIterator.forChildElements(circElt, "boardmap") {
            let boardName = boardMap.getAttribute("boardname")
            if StringUtil.isNullOrEmpty(boardName) { continue }
            loadMap(boardMap, boardName, circData.circuit)
          }
          circuitsData.append(circData)

        default:
          break
        }
      }

      // Third, process the other child elements.
      for subElt in XmlIterator.forChildElements(elt) {
        let name = subElt.tagName
        switch name {
        case "circuit", "vhdl", "lib":
          break  // Done earlier.
        case "options":
          do {
            try initAttributeSet(
              subElt, file.options.attributeSet, nil, isHolyCrossFile, isEvolutionFile)
          } catch let error as XmlReaderException {
            addErrors(error, "options")
          }
        case "mappings":
          try initMouseMappings(subElt, isHolyCrossFile, isEvolutionFile)
        case "toolbar":
          try initToolbarData(subElt, isHolyCrossFile, isEvolutionFile)
        case "main":
          let main = subElt.getAttribute("name")
          if let circ = file.circuit(named: main) {
            file.setMainCircuit(circ)
          }
        case "message":
          file.addMessage(subElt.getAttribute("value"))
        default:
          // Java throws `IllegalArgumentException("Invalid node in logisim file: " + name)`,
          // which is unchecked and aborts the load. D13 makes it a throw rather than a trap.
          throw LoadFailedError("Invalid node in logisim file: \(name)")
        }
      }

      // Fourth, run the transaction that populates every circuit.
      let builder = XmlCircuitReader(
        reader: self,
        circuitsData: circuitsData,
        isHolyCross: isHolyCrossFile,
        isEvolution: isEvolutionFile)
      try builder.execute()
    }

    // MARK: Tool lookup

    // ── D16: there is deliberately no `findTool(Library, String)` here ─────────────────────────
    //
    // 4.2.0-dev added a `ReadContext.findTool` that descends depth-first into sub-libraries and
    // rerouted both `toTool` and `XmlCircuitReader.getComponent` through it. **4.1.0's
    // `XmlReader` contains no `findTool` at all**: `toTool` is a bare `lib.getTool(name)`
    // (`XmlReader.java:553`) and `getComponent` is a bare `lib.getTool(name)`
    // (`XmlCircuitReader.java:87`): each a flat scan of that one library's own `getTools()`
    // list (`Library.java:61-68`).
    //
    // The difference is observable, and it was measured against the shipped 4.1.0 jar rather
    // than reasoned about. `LogisimFile` *is* a `Library` whose sub-libraries are the twelve
    // builtin shells, so a `<tool>` carrying no `lib=` attribute resolves *through* the file
    // into `#Base` under the recursive form and fails under the flat one. Given a `<mappings>`
    // entry `<tool map="Button2" name="Menu Tool"/>`:
    //
    //   | | result |
    //   |---|---|
    //   | 4.1.0 (`CircBridge`) | logs `Tool not found in library [mapping]`, **drops the entry** |
    //   | recursive `findTool` | keeps it, and writes `<tool lib="7" map="Button2" …/>` |
    //
    // Dropping is upstream's own data loss and standing rule 4 keeps it: D8 covers `<comp>` and
    // `<lib>`, not mouse mappings, and inventing a `lib=` handle the input never had is a
    // *silent* divergence from the oracle, not a preserved unknown.
    //
    // The helper is deleted rather than left unused, because it was `public`: a later call site
    // could pick it up without anyone noticing which upstream version it came from. When M6
    // makes nested libraries loadable and genuinely needs a recursive lookup, it must come back
    // as a deliberate divergence recorded here, not be inherited by accident.

    /// Java: `toTool(Element)` (`XmlReader.java:547-558`).
    ///
    /// `lib.tool(named:)` is `Library.getTool`, flat; see the note above for why this is not a
    /// recursive lookup and what it measurably costs to make it one.
    public func toTool(_ elt: XMLElement) throws -> Tool {
      let lib = try findLibrary(elt.getAttribute("lib"))
      let name = elt.getAttribute("name")
      if name.isEmpty {
        throw XmlReaderException(FileStrings.toolNameMissing)
      }
      guard let tool = lib.tool(named: name) else {
        throw XmlReaderException(FileStrings.toolNotFound)
      }
      return tool
    }
  }

  // MARK: - Instance state

  let loader: Loader
  /// Path of the source file. Used to make `filePath` attributes absolute so the system does
  /// not look for referenced files in whatever the process's working directory happens to be.
  let srcFilePath: String?

  /// Java: `XmlReader(Loader, File)`.
  public init(loader: Loader, file: URL?) {
    self.loader = loader
    self.srcFilePath = file.map { $0.absoluteURL.path }
  }

  // MARK: - Label repair (runs on every load)

  /// Java: `applyValidLabels(Element, String, String, Map<String,String>)`.
  ///
  /// The four `RuntimeException`s upstream throws for null/empty arguments are impossible to
  /// reach from Swift's type system (non-optional `String`), so only the "empty string" and
  /// "unknown node type" cases survive, and both are programmer errors no file can provoke,
  /// which is why they stay traps under D13's carve-out.
  public static func applyValidLabels(
    _ root: XMLElement, _ nodeType: String, _ attrType: String,
    _ validLabels: [String: String]
  ) {
    precondition(!nodeType.isEmpty, "Empty string is not a valid value of 'nodeType'.")
    precondition(!attrType.isEmpty, "Empty string is not a valid value of 'attrType'.")
    switch nodeType {
    case "circuit": replaceCircuitNodes(root, attrType, validLabels)
    case "comp": replaceCompNodes(root, validLabels)
    default: preconditionFailure("Invalid node type requested: \(nodeType)")
    }
  }

  /// Java: `cleanupToolsLabel(Element)`: blank every `<a name="label">` inside a `<tool>`.
  private static func cleanupToolsLabel(_ root: XMLElement) {
    for toolElt in XmlIterator.forChildElements(root, "tool") {
      for attrElt in XmlIterator.forChildElements(toolElt, "a") {
        if attrElt.hasAttribute("name"), attrElt.getAttribute("name") == "label" {
          attrElt.setAttribute("val", "")
        }
      }
    }
  }

  /// Java: `ensureLogisimCompatibility(Element)`.
  ///
  /// Runs on **every** load, not just old files: circuit names, circuit labels and component
  /// labels are rewritten to valid VHDL identifiers, and stray labels in `<toolbar>`/`<lib>`
  /// tools are blanked.
  ///
  /// For a modern file every label is already valid, `validLabels` comes back empty, and each
  /// `replace*` returns immediately, so the pass is a no-op and byte-exact round-tripping is
  /// unaffected. For a file that *does* contain an invalid label the rewrite appends a random
  /// UUID fragment and is therefore **not reproducible run to run**; that is upstream's
  /// behaviour, and `labelSuffixProvider` exists so a test or a differential harness can pin it.
  @discardableResult
  public static func ensureLogisimCompatibility(_ elt: XMLElement) -> XMLElement {
    var validLabels = findValidLabels(elt, "circuit", "name")
    applyValidLabels(elt, "circuit", "name", validLabels)
    validLabels = findValidLabels(elt, "circuit", "label")
    applyValidLabels(elt, "circuit", "label", validLabels)
    validLabels = findValidLabels(elt, "comp", "label")
    applyValidLabels(elt, "comp", "label", validLabels)
    // In old, buggy Logisim versions labels were incorrectly stored in toolbar and lib
    // components too. If so, clean them up.
    fixInvalidToolbarLib(elt)
    return elt
  }

  /// Java: `findLibraryUses(ArrayList<Element>, String, Iterable<Element>)`.
  private static func findLibraryUses(
    _ dest: inout [XMLElement], _ label: String, _ candidates: [XMLElement]
  ) {
    for elt in candidates where elt.getAttribute("lib") == label {
      dest.append(elt)
    }
  }

  /// Java: `findValidLabels(Element, String, String)`.
  ///
  /// Returns only the labels that need changing; an all-valid file yields an empty map, which
  /// every consumer treats as "do nothing".
  public static func findValidLabels(
    _ root: XMLElement, _ nodeType: String, _ attrType: String
  ) -> [String: String] {
    precondition(!nodeType.isEmpty, "Empty string is not a valid value of 'nodeType'.")
    precondition(!attrType.isEmpty, "Empty string is not a valid value of 'attrType'.")

    var validLabels: [String: String] = [:]
    for label in getXMLLabels(root, nodeType, attrType) {
      if validLabels[label] == nil, VhdlLabels.labelVHDLInvalid(label) {
        validLabels[label] = generateValidVHDLLabel(label)
      }
    }
    return validLabels
  }

  /// Java: `fixInvalidToolbarLib(Element)`.
  private static func fixInvalidToolbarLib(_ root: XMLElement) {
    // Iterate on toolbars; though there should be only one.
    for toolbarElt in XmlIterator.forChildElements(root, "toolbar") {
      cleanupToolsLabel(toolbarElt)
    }
    // Iterate on libs.
    for libsElt in XmlIterator.forChildElements(root, "lib") {
      cleanupToolsLabel(libsElt)
    }
  }

  /// Supplies the 8-character suffix appended to a repaired label.
  ///
  /// Java: `UUID.randomUUID().toString().substring(0, 8)`. Kept injectable because the result
  /// leaks into the saved file, so a byte-comparison gate cannot run against a random one.
  public static var labelSuffixProvider: () -> String = {
    String(UUID().uuidString.lowercased().prefix(8))
  }

  /// Java: `generateValidVHDLLabel(String)`.
  public static func generateValidVHDLLabel(_ initialLabel: String) -> String {
    generateValidVHDLLabel(initialLabel, labelSuffixProvider())
  }

  /// Java: `generateValidVHDLLabel(String, String)`.
  ///
  /// Every regex here is ASCII-only in Java (`\W` is `[^a-zA-Z0-9_]`, not its Unicode
  /// counterpart) and every `.`/`$` stops at a line terminator, so all of them are expanded by
  /// hand. Handing them to `NSRegularExpression` would quietly accept accented letters as word
  /// characters and change what a repaired label looks like.
  public static func generateValidVHDLLabel(_ rawLabel: String, _ suffix: String) -> String {
    // Trim first: if trimming is the only change, no suffix is appended.
    let initialLabel = javaTrim(rawLabel)

    var label = initialLabel
    if label.isEmpty {
      label = "L_"
    }

    // `label.replaceAll("[!~]", "NOT_")`
    label = label.replacingOccurrences(of: "!", with: "NOT_")
      .replacingOccurrences(of: "~", with: "NOT_")

    // `if (!label.matches("^[A-Za-z].*$")) label = "L_" + label;`
    //
    // `matches()` anchors both ends and `.` never crosses a line terminator, so the predicate
    // is exactly "starts with an ASCII letter AND contains no line terminator".
    let startsWithLetter =
      label.unicodeScalars.first.map(isAsciiLetterScalar) == true
      && !label.unicodeScalars.contains(where: isJavaLineTerminatorScalar)
    if !startsWithLetter {
      label = "L_" + label
    }

    // `label.replaceAll("\\W", "_")`: one underscore per non-word character.
    label = String(
      String.UnicodeScalarView(
        label.unicodeScalars.map { isJavaWordScalar($0) ? $0 : Unicode.Scalar(0x5F)! }))

    // `label.replaceAll("_+", "_")`
    label = collapseUnderscoreRuns(label)

    if label.hasSuffix("_") {
      label = String(label.dropLast())
    }

    if label != initialLabel {
      // Concatenate a unique id if the string has been altered, then replace the UUID's
      // dashes with underscores.
      label = label + "_" + suffix
      label = label.replacingOccurrences(of: "-", with: "_")
    }

    return label
  }

  private static func collapseUnderscoreRuns(_ text: String) -> String {
    var out = String.UnicodeScalarView()
    var previousWasUnderscore = false
    for scalar in text.unicodeScalars {
      let isUnderscore = scalar.value == 0x5F
      if isUnderscore && previousWasUnderscore { continue }
      out.append(scalar)
      previousWasUnderscore = isUnderscore
    }
    return String(out)
  }

  /// Java: `getXMLLabels(Element, String, String)`.
  public static func getXMLLabels(
    _ root: XMLElement, _ nodeType: String, _ attrType: String
  ) -> [String] {
    precondition(!nodeType.isEmpty, "Empty string is not a valid value of 'nodeType'.")
    precondition(!attrType.isEmpty, "Empty string is not a valid value of 'attrType'.")

    var attrValuesList: [String] = []
    switch nodeType {
    case "circuit": inspectCircuitNodes(root, attrType, &attrValuesList)
    case "comp": inspectCompNodes(root, &attrValuesList)
    default: preconditionFailure("Invalid node type requested: \(nodeType)")
    }
    return attrValuesList
  }

  /// Java: `inspectCircuitNodes(Element, String, List<String>)`.
  private static func inspectCircuitNodes(
    _ root: XMLElement, _ attrType: String, _ attrValuesList: inout [String]
  ) {
    switch attrType {
    case "name":
      for circElt in XmlIterator.forChildElements(root, "circuit") {
        attrValuesList.append(circElt.getAttribute("name"))
      }
    case "label":
      for circElt in XmlIterator.forChildElements(root, "circuit") {
        for attrElt in XmlIterator.forChildElements(circElt, "a") {
          if attrElt.hasAttribute("name"), attrElt.getAttribute("name") == "label" {
            let label = attrElt.getAttribute("val")
            if !label.isEmpty { attrValuesList.append(label) }
          }
        }
      }
    default:
      preconditionFailure(
        "Invalid attribute type requested: \(attrType) for node type: circuit")
    }
  }

  /// Java: `inspectCompNodes(Element, List<String>)`.
  ///
  /// Only components that *have* a `lib` attribute are considered: one without is a subcircuit
  /// reference, whose "label" is the circuit's own name and is handled by the circuit pass.
  private static func inspectCompNodes(_ root: XMLElement, _ attrValuesList: inout [String]) {
    precondition(attrValuesList.isEmpty, "The 'attrValuesList' must be empty.")
    for circElt in XmlIterator.forChildElements(root, "circuit") {
      for compElt in XmlIterator.forChildElements(circElt, "comp") where compElt.hasAttribute("lib") {
        for attrElt in XmlIterator.forChildElements(compElt, "a") {
          if attrElt.hasAttribute("name"), attrElt.getAttribute("name") == "label" {
            let label = attrElt.getAttribute("val")
            if !label.isEmpty { attrValuesList.append(label) }
          }
        }
      }
    }
  }

  /// Java: `XmlReader.labelVHDLInvalid(String)`.
  ///
  /// Note this is a *second, different* implementation from `VhdlContent.labelVHDLInvalid`:
  /// it omits the keyword check. Upstream never calls it, `findValidLabels` uses
  /// `VhdlContent`'s version, but it is public API and is ported so the two do not silently
  /// merge. Use `VhdlLabels.labelVHDLInvalid` for the behaviour the reader actually has.
  public static func labelVHDLInvalid(_ label: String) -> Bool {
    !VhdlLabels.isAsciiIdentifier(label) || label.hasSuffix("_") || label.contains("__")
  }

  /// Java: `replaceCircuitNodes(Element, String, Map<String,String>)`.
  private static func replaceCircuitNodes(
    _ root: XMLElement, _ attrType: String, _ validLabels: [String: String]
  ) {
    if validLabels.isEmpty {
      // Particular case: all the labels were good.
      return
    }
    switch attrType {
    case "name":
      // Both the circuit name and every reference to it must change: the `<a name="circuit">`
      // attribute of a subcircuit's static attributes, and the `<comp name=…>` of every
      // placement of it.
      for circElt in XmlIterator.forChildElements(root, "circuit") {
        let name = circElt.getAttribute("name")
        if let replacement = validLabels[name] {
          circElt.setAttribute("name", replacement)
          for attrElt in XmlIterator.forChildElements(circElt, "a") {
            if attrElt.hasAttribute("name"), attrElt.getAttribute("name") == "circuit" {
              attrElt.setAttribute("val", replacement)
            }
          }
        }
        // Now the comp part. Circuits are components without a `lib`.
        for compElt in XmlIterator.forChildElements(circElt, "comp")
        where !compElt.hasAttribute("lib") {
          if compElt.hasAttribute("name") {
            let compName = compElt.getAttribute("name")
            if let replacement = validLabels[compName] {
              compElt.setAttribute("name", replacement)
            }
          }
        }
      }
    case "label":
      for circElt in XmlIterator.forChildElements(root, "circuit") {
        for attrElt in XmlIterator.forChildElements(circElt, "a") {
          if attrElt.hasAttribute("name"), attrElt.getAttribute("name") == "label" {
            if let replacement = validLabels[attrElt.getAttribute("val")] {
              attrElt.setAttribute("val", replacement)
            }
          }
        }
      }
    default:
      preconditionFailure(
        "Invalid attribute type requested: \(attrType) for node type: circuit")
    }
  }

  /// Java: `replaceCompNodes(Element, Map<String,String>)`.
  private static func replaceCompNodes(_ root: XMLElement, _ validLabels: [String: String]) {
    if validLabels.isEmpty { return }
    for circElt in XmlIterator.forChildElements(root, "circuit") {
      for compElt in XmlIterator.forChildElements(circElt, "comp") where compElt.hasAttribute("lib") {
        for attrElt in XmlIterator.forChildElements(compElt, "a") {
          if attrElt.hasAttribute("name"), attrElt.getAttribute("name") == "label" {
            if let replacement = validLabels[attrElt.getAttribute("val")] {
              attrElt.setAttribute("val", replacement)
            }
          }
        }
      }
    }
  }

  // MARK: - considerRepairs: the migration passes

  /// Java: `addToLabelMap(HashMap, String, String, String)`.
  ///
  /// A no-op unless *both* labels are known, which is how upstream skips the half of
  /// `repairForWiringLibrary` that does not apply. Java joins the tool names with `";"` and
  /// splits them again; the array is passed directly here.
  private func addToLabelMap(
    _ labelMap: inout [String: String], _ srcLabel: String?, _ dstLabel: String?,
    _ toolNames: [String]
  ) {
    guard let srcLabel, let dstLabel else { return }
    for tool in toolNames {
      labelMap[srcLabel + ":" + tool] = dstLabel
    }
  }

  /// Java: `considerRepairs(Document, Element)`: every migration pass, in order.
  ///
  /// The order is not incidental and must not be rearranged:
  ///
  /// 1. `< 2.3.0` toolbar repair (Select+Wiring → Edit).
  /// 2. `< 2.6.3` circuit `label*` attribute rename, then the wiring-library split, then the
  ///    Legacy-library deletion. The wiring repair runs *first* because it renames `#Base` to
  ///    `#Wiring` and the legacy repair then walks a tree that already has the new names.
  /// 3. The pre-4.0.0 Pin attribute consolidation, which is **not gated on a version at all**;
  ///    it runs on every file, and is a no-op for a file that already uses `type`/`behavior`.
  /// 4. `== 0.0.0` returns early, skipping only the float repair.
  /// 5. `< 4.1.0-dev` float-library split.
  ///
  /// Step 4 is the subtle one. A missing or unparseable `source=` yields `0.0.0`, which is
  /// below both old gates, so those repairs *do* run, and then takes the early return, so the
  /// float repair does not. Upstream's comment is "prevents the following repairs to be applied
  /// when you open the program", i.e. it is aimed at the blank in-memory file the app starts
  /// with; the side effect on `source=`-less files on disk is real and is exercised by the
  /// synthesised `<2.3.0` fixture.
  func considerRepairs(_ document: XMLDocument, _ root: XMLElement) throws {
    let version = try LogisimVersion.fromString(root.getAttribute("source"))

    if version.compare(to: LogisimVersion(2, 3, 0)) < 0 {
      // This file was saved before an Edit tool existed. Most likely we should replace the
      // Select and Wiring tools in the toolbar with the Edit tool instead.
      for toolbar in XmlIterator.forChildElements(root, "toolbar") {
        var wiring: XMLElement?
        var select: XMLElement?
        var edit: XMLElement?
        for elt in XmlIterator.forChildElements(toolbar, "tool") {
          let eltName = elt.getAttribute("name")
          if StringUtil.isNotEmpty(eltName) {
            if eltName == BaseLibrary.selectToolId { select = elt }
            if eltName == BaseLibrary.wiringToolId { wiring = elt }
            if eltName == BaseLibrary.editToolId { edit = elt }
          }
        }
        if let select, let wiring, edit == nil {
          select.setAttribute("name", BaseLibrary.editToolId)
          toolbar.removeChild(wiring)
        }
      }
    }

    if version.compare(to: LogisimVersion(2, 6, 3)) < 0 {
      // ── UNVERIFIED PATH ──────────────────────────────────────────────────────────────────
      // No file older than 2.6.3 exists in the 594-file corpus, and the gate cannot be covered
      // by output comparison: the repair removes the `#Legacy` library, but an unresolvable
      // library is ALSO silently dropped by the loader, so both paths produce byte-identical
      // output. Verified deterministically over three runs. The only signal separating them is
      // a log line, which is too fragile to gate on.
      //
      // (An earlier note here claimed the repair "corrupts a modern-structured file", measured
      // from `source=2.6.0` hanging while `3.6.1` was clean. That was wrong: those two versions
      // straddle the 2.7.2 threshold that pops a modal "Old file format" dialog, so the hang was
      // the dialog and the comparison never touched the gate under test.) This
      // block is a careful reading of the Java, not a tested one. Do not claim migration
      // fidelity for `< 2.6.3` until a genuinely old-structured file is found.
      for circElt in XmlIterator.forChildElements(root, "circuit") {
        for attrElt in XmlIterator.forChildElements(circElt, "a") {
          let name = attrElt.getAttribute("name")
          if StringUtil.startsWith(name, "label") {
            attrElt.setAttribute("name", "c" + name)
          }
        }
      }

      try repairForWiringLibrary(document, root)
      repairForLegacyLibrary(document, root)
    }

    // Before version 4.0.0, Pin components had attributes:
    //   output=true|false
    //   tristate=true|false
    //   pull=up|down (or missing)
    // These are now consolidated into two attributes:
    //   type=input|output
    //   behavior=simple|tristate|pullup|pulldown
    //
    // Note this pass is ungated: upstream runs it on every file, and it is idempotent because
    // a converted file no longer has the three obsolete attributes to match on.
    let wiringLibName = XmlReader.findLibNameByDesc(root, "#Wiring")
    for compElt in XmlIterator.forDescendantElements(root, "comp") {
      convertObsoletePinAttributes(document, compElt, wiringLibName)
    }
    for toolElt in XmlIterator.forDescendantElements(root, "tool") {
      convertObsoletePinAttributes(document, toolElt, wiringLibName)
    }

    // Prevents the following repairs from being applied when you open the program.
    if version.compare(to: LogisimVersion(0, 0, 0)) == 0 { return }

    if version.compare(to: LogisimVersion(4, 1, 0, "dev")) < 0 {
      repairFloatLibrary(document, root)
    }
  }

  /// Java: `convertObsoletePinAttributes(Document, Element, String)`.
  ///
  /// `wiringLibName` is null when the file declares no `#Wiring` library, and Java's guard
  /// `!lib.equals(wiringLibName)` is then trivially true, so nothing converts: including for a
  /// `<comp>` with no `lib` at all. Reproduced through the optional rather than by comparing
  /// against `""`, which would wrongly match every subcircuit placement.
  private func convertObsoletePinAttributes(
    _ document: XMLDocument, _ elt: XMLElement, _ wiringLibName: String?
  ) {
    let lib = elt.getAttribute("lib")
    let name = elt.getAttribute("name")
    guard name == "Pin", let wiringLibName, lib == wiringLibName else { return }

    var output: String?
    var tristate: String?
    var pull: String?
    var type: String?
    var behavior: String?
    var bad: [XMLElement] = []

    for attrElt in XmlIterator.forChildElements(elt, "a") {
      let aname = attrElt.getAttribute("name")
      let aval = attrElt.getAttribute("val")
      if javaEqualsIgnoreCase("output", aname) {
        output = aval
        bad.append(attrElt)
      } else if javaEqualsIgnoreCase("tristate", aname) {
        tristate = aval
        bad.append(attrElt)
      } else if javaEqualsIgnoreCase("pull", aname) {
        pull = aval
        bad.append(attrElt)
      } else if javaEqualsIgnoreCase("type", aname) {
        type = aval
      } else if javaEqualsIgnoreCase("behavior", aname) {
        behavior = aval
      }
    }
    for badElement in bad {
      elt.removeChild(badElement)
    }
    if type == nil, let output {
      XmlReader.appendChildAttribute(
        document, elt, "type", javaEqualsIgnoreCase("true", output) ? "output" : "input")
    }
    if behavior == nil {
      if let pull, javaEqualsIgnoreCase("up", pull) {
        XmlReader.appendChildAttribute(document, elt, "behavior", "pullup")
      } else if let pull, javaEqualsIgnoreCase("down", pull) {
        XmlReader.appendChildAttribute(document, elt, "behavior", "pulldown")
      } else if let tristate, javaEqualsIgnoreCase("true", tristate) {
        XmlReader.appendChildAttribute(document, elt, "behavior", "tristate")
      }
    }
  }

  /// Java: `appendChildAttribute(Document, Element, String, String)`.
  ///
  /// The `Document` argument has no counterpart in Foundation, nodes are not bound to a
  /// document until inserted, and is kept only so the call shape matches upstream.
  private static func appendChildAttribute(
    _ document: XMLDocument, _ elt: XMLElement, _ name: String, _ val: String
  ) {
    let attr = XMLElement.createElement("a", attributes: [("name", name), ("val", val)])
    elt.appendChild(attr)
  }

  /// Java: `relocateTools(Element, Element, HashMap<String,String>)`.
  ///
  /// Moves the `<tool>` children named in `labelMap` from `src` to `dest`. The `src == dest`
  /// guard is load-bearing: when the file had a `#Base` library, `wiringElt` *is* `oldBaseElt`
  /// renamed, so the second `relocateTools(oldBaseElt, wiringElt, …)` call returns immediately
  /// and the wiring tools correctly stay put in the element that is now `#Wiring`.
  private func relocateTools(
    _ src: XMLElement?, _ dest: XMLElement?, _ labelMap: [String: String]
  ) {
    guard let src, src !== dest else { return }
    let srcLabel = src.getAttribute("name")

    var toRemove: [XMLElement] = []
    for elt in XmlIterator.forChildElements(src, "tool") {
      let name = elt.getAttribute("name")
      if labelMap[srcLabel + ":" + name] != nil {
        toRemove.append(elt)
      }
    }
    for elt in toRemove {
      src.removeChild(elt)
      dest?.appendChild(elt)
    }
  }

  /// Java: `repairForLegacyLibrary(Document, Element)`.
  ///
  /// `#Legacy` no longer exists, so the declaration is deleted along with **every component and
  /// tool that referenced it**; that data loss is the documented purpose of the repair, and a
  /// `<message>` element is appended so the user is told.
  ///
  /// Two details worth stating because both look like bugs and both are load-bearing:
  ///
  /// * `root.removeChild(legacyElt)` happens *before* the descendant search, so `<tool>`
  ///   elements nested inside the `#Legacy` declaration are already detached and correctly not
  ///   matched a second time.
  /// * If the `#Legacy` element has no `name` attribute, `legacyLabel` is `""`, and
  ///   `findLibraryUses` then matches every `<comp>` with no `lib` attribute, i.e. **every
  ///   subcircuit placement in the file**, and deletes them. Preserved verbatim; a `#Legacy`
  ///   declaration without a name has never been observed in a real file.
  private func repairForLegacyLibrary(_ document: XMLDocument, _ root: XMLElement) {
    var legacyElt: XMLElement?
    var legacyLabel: String = ""
    for libElt in XmlIterator.forChildElements(root, "lib") {
      if libElt.getAttribute("desc") == "#Legacy" {
        legacyElt = libElt
        legacyLabel = libElt.getAttribute("name")
      }
    }

    guard let legacyElt else { return }
    root.removeChild(legacyElt)

    var toRemove: [XMLElement] = []
    XmlReader.findLibraryUses(
      &toRemove, legacyLabel, XmlIterator.forDescendantElements(root, "comp"))
    let componentsRemoved = !toRemove.isEmpty
    XmlReader.findLibraryUses(
      &toRemove, legacyLabel, XmlIterator.forDescendantElements(root, "tool"))
    for elt in toRemove {
      // Java: `elt.getParentNode().removeChild(elt)`. `detach()` is the same operation without
      // needing to name the parent, and is safe for a node whose parent has already gone.
      elt.detach()
    }
    if componentsRemoved {
      let elt = XMLElement.createElement(
        "message", attributes: [("value", FileStrings.legacyLibraryRemovedMessage)])
      root.appendChild(elt)
    }
  }

  /// Java: `repairForWiringLibrary(Document, Element)`.
  ///
  /// Before 2.6.3 there was one `#Base` library holding both the editing tools and the wiring
  /// components. This splits it: the existing element is *renamed* to `#Wiring` and a fresh
  /// `#Base` is inserted after the last library, with the editing tools relocated into it.
  /// Every `<comp>`/`<tool>` referring to a moved tool has its `lib=` handle rewritten.
  ///
  /// **UNVERIFIED**: see the note at the `< 2.6.3` gate in `considerRepairs`.
  ///
  /// D13: Java dereferences `lastLibElt` unconditionally, so a pre-2.6.3 file with no `<lib>`
  /// elements at all NPEs out of the load. That is file-triggerable, so it throws here instead
  /// of trapping.
  private func repairForWiringLibrary(_ document: XMLDocument, _ root: XMLElement) throws {
    var oldBaseElt: XMLElement?
    var oldBaseLabel: String?
    var gatesElt: XMLElement?
    var gatesLabel: String?
    var maxLabel = -1
    var lastLibElt: XMLElement?

    for libElt in XmlIterator.forChildElements(root, "lib") {
      let desc = libElt.getAttribute("desc")
      let label = libElt.getAttribute("name")

      switch desc {
      case "#Base":
        oldBaseElt = libElt
        oldBaseLabel = label
      case "#Wiring":
        // Wiring library already in file. This shouldn't happen, but if somehow it does, we
        // don't want to add it again.
        return
      case "#Gates":
        gatesElt = libElt
        gatesLabel = label
      default:
        break
      }

      lastLibElt = libElt
      // Java: `Integer.parseInt(label)` inside a swallowed `catch (NumberFormatException)`.
      if let thisLabel = javaParseInt32(label), thisLabel > maxLabel {
        maxLabel = thisLabel
      }
    }

    guard let lastLibElt else {
      throw LoadFailedError(
        "pre-2.6.3 file declares no libraries; the wiring-library repair cannot run")
    }

    // Java's `"" + (maxLabel + 1)` on a 32-bit int.
    let nextLabel = String(wrap32(maxLabel &+ 1))

    let wiringElt: XMLElement
    let wiringLabel: String
    let newBaseElt: XMLElement?
    let newBaseLabel: String?

    if let oldBaseElt {
      wiringLabel = oldBaseLabel ?? ""
      wiringElt = oldBaseElt
      wiringElt.setAttribute("desc", "#Wiring")

      newBaseLabel = nextLabel
      let created = XMLElement.createElement(
        "lib", attributes: [("desc", "#Base"), ("name", nextLabel)])
      newBaseElt = created
      root.insertBefore(created, lastLibElt.nextSibling)
    } else {
      wiringLabel = nextLabel
      wiringElt = XMLElement.createElement(
        "lib", attributes: [("desc", "#Wiring"), ("name", nextLabel)])
      root.insertBefore(wiringElt, lastLibElt.nextSibling)

      newBaseLabel = nil
      newBaseElt = nil
    }

    var labelMap: [String: String] = [:]
    // The editing tools move to the new `#Base`.
    addToLabelMap(
      &labelMap, oldBaseLabel, newBaseLabel,
      [
        BaseLibrary.pokeToolId,
        BaseLibrary.editToolId,
        BaseLibrary.selectToolId,
        BaseLibrary.wiringToolId,
        BaseLibrary.textToolButtonId,
        BaseLibrary.menuToolId,
        TextComponent.id,
      ])
    // The wiring components stay in the element that is now `#Wiring`.
    addToLabelMap(
      &labelMap, oldBaseLabel, wiringLabel,
      [
        "Splitter",
        "Pin",
        "Probe",
        "Tunnel",
        "Clock",
        "Pull Resistor",
        "Bit Extender",
      ])
    // Constant moves out of `#Gates` and into `#Wiring`.
    addToLabelMap(&labelMap, gatesLabel, wiringLabel, ["Constant"])

    relocateTools(oldBaseElt, newBaseElt, labelMap)
    relocateTools(oldBaseElt, wiringElt, labelMap)
    relocateTools(gatesElt, wiringElt, labelMap)
    XmlReader.updateFromLabelMap(XmlIterator.forDescendantElements(root, "comp"), labelMap)
    XmlReader.updateFromLabelMap(XmlIterator.forDescendantElements(root, "tool"), labelMap)
  }

  /// Java: `repairFloatLibrary(Document, Element)`.
  ///
  /// 4.1.0 split the floating-point components out of `#Arithmetic` into a new
  /// `#FPArithmetic` library named `float`. Every `FP*` tool and `IntToFP` moves across, and
  /// every placed component of those types is repointed.
  ///
  /// **Upstream's operator precedence bug is preserved.** The condition reads
  ///
  /// ```java
  /// if (libName.equals(arithmeticLib.getAttribute("name")) && compName.startsWith("FP")
  ///     || compName.equals("IntToFP"))
  /// ```
  ///
  /// which Java parses as `(A && B) || C`. So a component named exactly `IntToFP` gets
  /// `lib="float"` **regardless of which library it came from**: including a user's own
  /// `.circ` library. Fixing it would change what a saved file looks like relative to the Java
  /// oracle the migration gate compares against, so it stays.
  ///
  /// Note also that the new `<lib>` element is inserted even when no tool moves into it, and
  /// that the component rewrite walks only direct `<comp>` children of direct `<circuit>`
  /// children; an `IntToFP` nested deeper is not touched.
  private func repairFloatLibrary(_ document: XMLDocument, _ root: XMLElement) {
    var arithmeticLib: XMLElement?
    var nextSibling: XMLNode?
    for lib in XmlIterator.forChildElements(root, "lib") {
      if lib.getAttribute("desc") == "#Arithmetic" {
        arithmeticLib = lib
        nextSibling = lib.nextSibling
        break
      }
    }

    guard let arithmeticLib else { return }

    let floatLib = XMLElement.createElement(
      "lib", attributes: [("desc", "#FPArithmetic"), ("name", "float")])

    var toolsToMove: [XMLElement] = []
    for tool in XmlIterator.forChildElements(arithmeticLib, "tool") {
      let toolName = tool.getAttribute("name")
      if toolName.hasPrefix("FP") || toolName == "IntToFP" {
        toolsToMove.append(tool)
      }
    }

    for tool in toolsToMove {
      arithmeticLib.removeChild(tool)
      floatLib.appendChild(tool)
    }

    if let nextSibling {
      root.insertBefore(floatLib, nextSibling)
    } else {
      root.appendChild(floatLib)
    }

    for circuit in XmlIterator.forChildElements(root, "circuit") {
      for comp in XmlIterator.forChildElements(circuit, "comp") {
        let libName = comp.getAttribute("lib")
        let compName = comp.getAttribute("name")

        if (libName == arithmeticLib.getAttribute("name") && compName.hasPrefix("FP"))
          || compName == "IntToFP"
        {
          comp.setAttribute("lib", "float")
        }
      }
    }
  }

  /// Java: `updateFromLabelMap(Iterable<Element>, HashMap<String,String>)`.
  private static func updateFromLabelMap(
    _ elts: [XMLElement], _ labelMap: [String: String]
  ) {
    for elt in elts {
      let oldLib = elt.getAttribute("lib")
      let name = elt.getAttribute("name")
      if let newLib = labelMap[oldLib + ":" + name] {
        elt.setAttribute("lib", newLib)
      }
    }
  }

  /// Java: `findLibNameByDesc(Element, String)`.
  ///
  /// Returns the **first** match in document order, unlike `repairForLegacyLibrary`'s scan
  /// which keeps the last. The difference only shows for a file declaring the same descriptor
  /// twice, which is malformed but not rejected.
  private static func findLibNameByDesc(_ root: XMLElement, _ libdesc: String) -> String? {
    for libElt in XmlIterator.forChildElements(root, "lib") where libElt.getAttribute("desc") == libdesc {
      return libElt.getAttribute("name")
    }
    return nil
  }

  // MARK: - Entry point

  /// Java: `loadXmlFrom(InputStream)`.
  ///
  /// Upstream builds a "hardened" `DocumentBuilderFactory`: namespace-aware, with
  /// `FEATURE_SECURE_PROCESSING` and external entity resolution disabled; because a `.circ`
  /// is untrusted input and an XXE would otherwise read arbitrary files.
  /// `.nodeLoadExternalEntitiesNever` is Foundation's equivalent of the whole hardening set.
  static func loadXmlFrom(_ data: Data) throws -> XMLDocument {
    try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])
  }

  /// Java: `readLibrary(InputStream, Project)`.
  public func readLibrary(_ data: Data, project: AnyObject? = nil) throws -> LogisimFile {
    let doc = try XmlReader.loadXmlFrom(data)
    guard let documentElement = doc.rootElement() else {
      throw LoadFailedError(FileStrings.xmlFormatError("document has no root element"))
    }
    let elt = XmlReader.ensureLogisimCompatibility(documentElement)

    try considerRepairs(doc, elt)
    // Java: `new LogisimFile((Loader) loader)`: the bare constructor, with no default circuit
    // and no default libraries. That is `createEmpty`, not `createNew`.
    let file = LogisimFile.createEmpty(loader: loader)
    let context = ReadContext(file: file, loader: loader, srcFilePath: srcFilePath)

    try context.toLogisimFile(elt, project)

    if file.circuitCount == 0 {
      file.addCircuit(try Circuit(name: "main", file: file))
    }
    if !context.messages.isEmpty {
      loader.showError(context.messages.joined(separator: "\n"))
    }
    return file
  }
}

// MARK: - D8: preserved `<vhdl>` entities

/// A `<vhdl>` entity the codec cannot interpret, kept verbatim so it survives load → save.
///
/// The VHDL counterpart of `UnresolvedComponent` and `MissingLibrary`: the element is the
/// authority, `name` exists only so the model can answer ordinary questions about it, and nothing
/// here pretends to be a parsed entity. `VhdlContentPreserving` is what `XmlWriter` looks for.
///
/// The stored element is a detached copy, for the same reason every other absorb site takes one:
/// the source document is released once the load finishes and Foundation's DOM nodes do not
/// outlive their document safely.
public final class PreservedVhdlContent: VhdlContentReference, VhdlContentPreserving {
  public let name: String
  public let rawElement: XMLElement?

  /// Fails only when the element cannot be copied, which is the same guard
  /// `Circuit.absorbAppearance` and `UnresolvedComponent.absorb` use. Without a copy there is
  /// nothing to write back, and a content object that cannot be written is worse than none; the
  /// writer would throw `vhdlContentCannotBeSaved` and fail the whole save.
  public init?(name: String, element: XMLElement) {
    guard let duplicate = element.copy() as? XMLElement else { return nil }
    duplicate.detach()
    self.name = name
    self.rawElement = duplicate
  }
}

/// The `VhdlEntityFactory` that carries a `PreservedVhdlContent` into `LogisimFile.addToolList`.
///
/// **It answers to the entity's own name, exactly as `VhdlEntity` does** (`VhdlEntity.getName()`
/// returns `content.getName()`). `LogisimFile` is itself a `Library`, so that is what makes a
/// `<comp name="Sigmoid_Activation_Function">` with no `lib=` resolve through
/// `LogisimFile.tool(named:)`; the same lookup upstream's placement takes.
///
/// **The earlier design prefixed the name to keep such placements unresolvable, and that was the
/// bug.** The reasoning was sound about the hazard and wrong about the remedy: an `AddTool` whose
/// factory hands back `AttributeSets.empty` *would* swallow every `<a>` on the placement and write
/// the component back bare. The fix is to give this factory an attribute set that accepts them,
/// `OpaqueAttributeSet`, the one `UnresolvedComponentFactory` already uses, not to make the tool
/// invisible. Invisibility cost real fidelity in three places:
///
/// * every placement minted its *own* `UnresolvedComponentFactory`, so N instances of one entity
///   counted as N distinct factories where upstream has one;
/// * `FileStatistics.sortCounts` finds a row only when the count's factory is some tool's factory,
///   so the entity had no row at all and **both** totals were short by its placement count. That
///   is the entire `3.7.2__case-278.circ::main` divergence in `statsgate.py`;
/// * `LogisimFile.vhdlContent(named:)`, which matches on `factory.name`, as Java's
///   `getVhdlContent` does, could never find a preserved entity.
///
/// `XmlCircuitReader` still routes the placement down D8's verbatim path (see
/// `preservedVhdlPlacement`), so nothing here is asked to interpret VHDL: `createComponent`
/// produces an `UnresolvedComponent` carrying the `<comp>` element itself, and the writer re-emits
/// what it read. This is a carrier for an entity the codec cannot parse, and it says so by
/// resolving to something inert rather than by hiding.
///
/// When the `VhdlContentLoading` seam is finally installed, a real `VhdlEntity` registers under
/// this same name and takes over; nothing that resolves through the name has to change.
public final class PreservedVhdlEntityFactory: AbstractComponentFactory, VhdlEntityFactory {
  public let content: any VhdlContentReference

  public init(content: any VhdlContentReference) {
    self.content = content
    super.init(requiresLabel: false, requiresGlobalClock: false)
  }

  /// `VhdlEntity.getName()`.
  public override var name: String { content.name }

  /// `VhdlEntity.getDisplayGetter()`, which is `constantGetter(content.getName())`: the same
  /// string, and the one `-tty stats` prints in its third column.
  public override var displayName: String { content.name }

  /// Opaque, not empty: the placement's `<a>` children have to land somewhere the model can read
  /// them back, and no attribute of an unparsed entity has a known type. Same set, same reasoning
  /// as `UnresolvedComponentFactory`.
  public override func createAttributeSet() -> any AttributeSet { OpaqueAttributeSet() }

  public override func createComponent(
    location: Location, attributes: any AttributeSet
  ) throws -> any Component {
    UnresolvedComponent(factory: self, location: location, attributes: attributes)
  }

  /// Empty, and honestly so; the entity's port list was never parsed, so its shape is unknown.
  /// Matches `UnresolvedComponentFactory.offsetBounds`.
  public override func offsetBounds(_ attributes: any AttributeSet) -> Bounds { Bounds.empty }

  /// Always nil, exactly as `UnresolvedComponentFactory` does: nothing about a preserved element
  /// is ever treated as omissible-because-default.
  public override func defaultAttributeValue(
    _ attribute: AnyAttribute, version: LogisimVersion
  ) -> AttributeValue? {
    nil
  }
}

/// The adaptor that plugs `XmlReader` into `Loader`'s `LogisimFileReading` seam.
///
/// Java constructs a fresh `XmlReader` per read; that is what happens here too. The seam has no
/// `Project` parameter because nothing below the Project layer has one: `Circuit` accepts nil,
/// exactly as it does for a library loaded as a dependency rather than opened as a project.
public final class XmlFileReader: LogisimFileReading {
  public init() {}

  public func readLibrary(_ data: Data, loader: Loader, sourceFile: URL?) throws -> LogisimFile {
    try XmlReader(loader: loader, file: sourceFile).readLibrary(data, project: nil)
  }
}
