// ProjectOutlineBuilder.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.gui.generic.ProjectExplorer and the
// Toolbox model it renders), https://github.com/logisim-evolution/logisim-evolution. Copyright
// by the Logisim-evolution developers. This translation is a derivative work and is therefore
// GPL-3.0-only. See LICENSE.md.
// SPDX-License-Identifier: GPL-3.0-only
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── What this file is ───────────────────────────────────────────────────────────────────────
//
// The projection from a loaded `LogisimFile` to the value snapshot the sidebar binds to. It
// replaces `DemoProjectHost.buildOutline()`, which fabricated a plausible-looking twelve-library
// tree out of literals. Every entry here comes from the file: the circuit list is
// `LogisimFile.circuits`, the library list is `LogisimFile.libraries`, and each library's tools
// are that `Library`'s own `tools`.
//
// ── Why the projection exists at all (D4) ───────────────────────────────────────────────────
//
// `ProjectSeam.swift` states the reason: D4 makes component identity *reference* identity and
// forbids synthesised `Equatable`/`Hashable` on `Component` and `AttributeSet`, which is exactly
// what SwiftUI's `List` selection demands. So the model is projected to opaque `UInt64` handles
// and the mapping back lives in `ProjectHandles` below, owned by the host.
//
// ── The one thing that is *not* derived, and why ────────────────────────────────────────────
//
// SF Symbol names. Upstream draws each tool with the component's own icon, rendered by
// `paintIcon` at `AppPreferences.getIconSize()`; M6 deliberately did not port `paintIcon` (see
// objectives.md, M6, "Deliberately not painted"). Until it does, the sidebar needs *some* glyph,
// and a small name→symbol table is the honest stand-in: it is presentation, it names no
// behaviour, and a tool missing from the table gets a neutral symbol rather than being hidden.
// Nothing else in this file is invented.

import Foundation
import LogisimFile
import LogisimKernel

// MARK: - Handles

/// The two-way map between the shell's opaque IDs and the model objects behind them.
///
/// Rebuilt whenever the outline is rebuilt, which is what keeps a deleted circuit's ID from
/// resolving. Strong references throughout, and that closes no cycle: the file owns its
/// circuits, libraries and tools, the host owns the file, and none of them reaches back to the
/// host (D3's owning direction).
@MainActor
struct ProjectHandles {
  private(set) var circuits: [CircuitID: Circuit] = [:]
  private(set) var vhdl: [CircuitID: any VhdlContentReference] = [:]
  private(set) var libraries: [LibraryID: Library] = [:]
  private(set) var tools: [ToolID: Tool] = [:]
  /// The library each tool came from, so an `AddTool` can be placed with the right defaults and
  /// so an unresolved tool can name its library in the inspector notice.
  private(set) var toolLibrary: [ToolID: Library] = [:]

  mutating func record(circuit: Circuit) -> CircuitID {
    let id = ProjectHandles.circuitID(for: circuit)
    circuits[id] = circuit
    return id
  }

  mutating func record(vhdl content: any VhdlContentReference) -> CircuitID {
    let id = CircuitID(rawValue: ProjectHandles.handle(content))
    vhdl[id] = content
    return id
  }

  mutating func record(library: Library) -> LibraryID {
    let id = LibraryID(rawValue: ProjectHandles.handle(library))
    libraries[id] = library
    return id
  }

  mutating func record(tool: Tool, in library: Library?) -> ToolID {
    let id = ProjectHandles.toolID(for: tool)
    tools[id] = tool
    if let library { toolLibrary[id] = library }
    return id
  }

  /// D4: reference identity, projected to the reference's address; the same scheme
  /// `CircuitSceneSource.identity(of:)` uses for components, so a canvas hit and an explorer
  /// row agree on what a thing is called.
  static func handle(_ object: AnyObject) -> UInt64 {
    UInt64(UInt(bitPattern: ObjectIdentifier(object)))
  }

  static func circuitID(for circuit: Circuit) -> CircuitID {
    CircuitID(rawValue: handle(circuit))
  }

  static func toolID(for tool: Tool) -> ToolID {
    ToolID(rawValue: handle(tool))
  }
}

// MARK: - Builder

@MainActor
enum ProjectOutlineBuilder {

  /// Everything one walk of the file produces: the snapshot the sidebar renders, and the
  /// handle map that turns a row back into a model object.
  struct Result {
    var outline: ProjectOutline
    var handles: ProjectHandles
  }

  /// - Parameters:
  ///   - file: the loaded document.
  ///   - simulationRoot: the live state tree, when a simulation is attached. `nil` while
  ///     nothing is simulating, which the Simulate sidebar renders as "not running" rather
  ///     than as an invented tree.
  static func build(
    file: LogisimFile,
    simulationRoot: SimulationNode? = nil
  ) -> Result {
    var handles = ProjectHandles()

    // ── Circuits ─────────────────────────────────────────────────────────────────────────
    //
    // `LogisimFile.circuits` is derived from the *tool* list in tool order, which is the order
    // upstream's explorer shows and the order `moveCircuitUp`/`Down` rearranges. Reading it
    // rather than an internal array is what keeps the sidebar and the saved file in agreement.
    let main = file.mainCircuit
    var circuitItems: [CircuitItem] = file.circuits.map { circuit in
      let id = handles.record(circuit: circuit)
      return CircuitItem(
        id: id,
        name: circuit.name,
        kind: .circuit,
        isMain: circuit === main,
        componentCount: circuit.components.count)
    }

    // VHDL entities are siblings of circuits in upstream's project tree, not a separate
    // section, so they are appended to the same list with `kind: .vhdl`.
    circuitItems += file.vhdlContents.map { content in
      let id = handles.record(vhdl: content)
      return CircuitItem(id: id, name: content.name, kind: .vhdl, componentCount: 0)
    }

    // ── Libraries ────────────────────────────────────────────────────────────────────────
    //
    // `#Base` is `setHidden()` in the file model exactly as upstream hides it, and its five
    // entries are the canvas tools, which belong in the toolbar rather than in the palette.
    // They are pulled out separately below.
    var libraryItems: [LibraryItem] = []
    for library in file.libraries where !library.isHidden {
      libraryItems.append(libraryItem(for: library, handles: &handles))
    }

    // ── The always-present editing tools ─────────────────────────────────────────────────
    let editing = editingTools(in: file, handles: &handles)
    let toolbar = toolbarItems(in: file, handles: &handles)

    return Result(
      outline: ProjectOutline(
        circuits: circuitItems,
        libraries: libraryItems,
        simulationRoot: simulationRoot,
        editingTools: editing,
        toolbarItems: toolbar),
      handles: handles)
  }

  /// The document's own `<toolbar>`, in file order.
  ///
  /// `Options.toolbarData` was parsed, stored and read by nothing: the window rendered
  /// `editingTools` -- `#Base`'s five -- so it showed five buttons where upstream shows the
  /// default template's seventeen. Reported from the running app as "less tools than
  /// logisim-evolution", which it was.
  ///
  /// The tools here are the SAME objects as the library entries, not copies, so `handles.record`
  /// hands back the id already assigned and selecting a gate on the toolbar highlights the same
  /// gate in the explorer. That identity is load-bearing elsewhere too -- `AddTool.sharesSource`
  /// and `XmlWriter.fromTool` both compare on it.
  private static func toolbarItems(
    in file: LogisimFile, handles: inout ProjectHandles
  ) -> [ToolbarEntry] {
    var entries: [ToolbarEntry] = []
    for (index, tool) in file.options.toolbarData.toolbarContents.enumerated() {
      guard let tool else {
        entries.append(.separator(index))
        continue
      }
      // The owning library is needed for the symbol table's lookup, which is keyed on
      // (tool id, library name) -- "Pin" means something different in #Wiring than in a
      // user library.
      // `sharesSource`, not `===`. Every `<toolbar>` entry is a CLONE, `XmlReader` calls
      // `cloneTool()` on each one, which `ComponentPaletteTests.paletteToolsAreClonesThatShareSource`
      // already pins, so reference identity never matched here and `owner` was **always nil** for
      // a palette tool. That fell through to `inLibrary: ""`, missed the per-library symbol table,
      // and handed every palette entry the global fallback glyph; it is why the palette's D
      // Flip-Flop drew `square.on.circle`. `AddTool.sharesSource` compares factories
      // (`LibraryModel.swift:136`), which is exactly the "same tool, different instance" question
      // being asked.
      let owner = file.libraries.first { $0.tools.contains { $0.sharesSource(tool) } }
      entries.append(
        .tool(
          ToolItem(
            id: handles.record(tool: tool, in: owner ?? file.library(named: Builtin.baseId)),
            name: ToolSymbols.editingDisplayName(forToolNamed: tool.name) ?? tool.displayName,
            symbolName: ToolSymbols.symbol(forToolNamed: tool.name, inLibrary: owner?.name ?? ""),
            shortcutCharacter: nil,
            summary: ToolSymbols.editingSummary(forToolNamed: tool.name))))
    }
    return entries
  }

  // MARK: Libraries

  private static func libraryItem(
    for library: Library, handles: inout ProjectHandles
  ) -> LibraryItem {
    let id = handles.record(library: library)
    let origin = self.origin(of: library)
    let unavailable = unavailableReason(for: library)

    var tools: [ToolItem] = library.tools.map { tool in
      ToolItem(
        id: handles.record(tool: tool, in: library),
        name: tool.displayName,
        symbolName: ToolSymbols.symbol(forToolNamed: tool.name, inLibrary: library.name),
        summary: tool.toolDescription.isEmpty ? nil : tool.toolDescription,
        unavailableReason: unavailable)
    }

    // D8: a `<lib>` that resolved to nothing still has to be *listed with a reason*. A missing
    // library whose file carried no `<tool>` children has an empty tool list, and an empty row
    // in the sidebar reads as "there is nothing here", which is the exact impression upstream
    // gives by dropping it. One explanatory entry says otherwise.
    if tools.isEmpty, let unavailable {
      tools = [
        ToolItem(
          id: ToolID(rawValue: ProjectHandles.handle(library)),
          name: "Unavailable",
          symbolName: "questionmark.square.dashed",
          unavailableReason: unavailable)
      ]
    }

    return LibraryItem(
      id: id,
      name: library.displayName,
      origin: origin,
      tools: tools,
      // Upstream lets any library declared in the file be unloaded; the builtin shells the
      // file happens to declare are no exception (`MenuProject` → "Unload Libraries…").
      isRemovable: true)
  }

  private static func origin(of library: Library) -> LibraryItem.Origin {
    if let missing = library as? MissingLibrary {
      switch missing.reason {
      case .jarUnsupported(let file, let className):
        return .jar("\(file)#\(className)")
      default:
        return .unresolved(missing.descriptorText)
      }
    }
    if let loaded = library as? LoadedLibrary {
      // The URL a loaded `.circ` library came from is the loader's business and is not
      // reachable from the library object, so the origin records "a loaded Logisim file"
      // without inventing a path.
      _ = loaded
      return .loadedLogisimFile(nil)
    }
    return .builtin
  }

  /// The sentence the sidebar and the inspector show for a tool that cannot be placed.
  ///
  /// `nil` for a library that resolved; every one of its tools is usable.
  private static func unavailableReason(for library: Library) -> String? {
    guard let missing = library as? MissingLibrary else { return nil }
    switch missing.reason {
    case .builtinUnavailable(let name):
      return "‘\(name)’ is not a built-in library in this build. Components using it are "
        + "preserved exactly as loaded and written back unchanged when you save (D8)."
    case .jarUnsupported(let file, let className):
      return "JAR libraries load Java classes at runtime and cannot be supported in a native "
        + "build (\(file), \(className)). The components are preserved verbatim."
    case .fileUnavailable(let path, let detail):
      return "The library file ‘\(path)’ could not be read: \(detail)"
    case .unrecognizedType(let text):
      return "‘\(text)’ is not a library descriptor this build understands."
    case .malformedDescriptor:
      return "The library descriptor in this file is malformed."
    }
  }

  // MARK: Editing tools

  /// The canvas tools, taken from the file's own `#Base` library.
  ///
  /// Upstream keeps these in a floating `Toolbar` widget above the canvas (`Frame.java:146`);
  /// here they are window-toolbar items. They come from the file rather than from a literal
  /// list because `Project.editTool` resolves the Edit tool through exactly this library
  /// (`getLibrary(BaseLibrary._ID).getTool(EditTool._ID)`), so the two must agree on the same
  /// objects or selecting a tool in the toolbar and asking the project for it would produce
  /// two different tools.
  ///
  /// **What these are today.** `#Base`'s tool list is `BuiltinPlaceholderTool`s keyed by `_ID`
  /// : see `Project.editTool`'s note. They carry the right names and identities, which is what
  /// the toolbar and the `.circ` codec need, and `CanvasToolController.upgrade(_:)` answers
  /// `nil` for them, so selecting one leaves the working tool in place instead of swapping in
  /// something inert. Installing the real six is the "builtin tools" half of the unwired
  /// handler-seams task and is not this file's to do.
  private static func editingTools(
    in file: LogisimFile, handles: inout ProjectHandles
  ) -> [ToolItem] {
    guard let base = file.library(named: Builtin.baseId) else { return [] }
    let shortcuts: [Character] = ["1", "2", "3", "4", "5", "6"]
    return base.tools.enumerated().map { index, tool in
      ToolItem(
        id: handles.record(tool: tool, in: base),
        name: ToolSymbols.editingDisplayName(forToolNamed: tool.name) ?? tool.displayName,
        symbolName: ToolSymbols.symbol(forToolNamed: tool.name, inLibrary: base.name),
        shortcutCharacter: index < shortcuts.count ? shortcuts[index] : nil,
        summary: ToolSymbols.editingSummary(forToolNamed: tool.name))
    }
  }
}

// MARK: - Symbols

/// Presentation only. See the file header for why this table exists and what will replace it.
enum ToolSymbols {

  /// Keyed on the tool's `_ID`, the stable string `.circ` references, never on a display
  /// name, which is localised upstream and would make the table locale-dependent.
  private static let byToolId: [String: String] = [
    // #Base, the canvas tools.
    BaseToolIds.poke: "hand.point.up.left",
    BaseToolIds.edit: "cursorarrow",
    BaseToolIds.select: "cursorarrow",
    BaseToolIds.wiring: "line.diagonal",
    BaseToolIds.textTool: "textformat",
    BaseToolIds.menu: "ellipsis.circle",
    BaseToolIds.textFactory: "textformat",

    // #Wiring
    "Pin": "circle.and.line.horizontal",
    "Probe": "waveform.path",
    "Tunnel": "arrow.triangle.branch",
    "Pull Resistor": "bolt.horizontal",
    "Clock": "clock",
    "Constant": "number",
    "Splitter": "arrow.triangle.branch",
    "Bit Extender": "arrow.left.and.right",
    "Power": "bolt.fill",
    "Ground": "arrow.down.to.line",
    "Transistor": "triangle",
    "Transmission Gate": "square.on.square.dashed",

    // #Gates
    "NOT Gate": "circle.slash",
    "Buffer": "triangle",
    "AND Gate": "capsule",
    "OR Gate": "shield",
    "NAND Gate": "capsule.portrait",
    "NOR Gate": "shield.lefthalf.filled",
    "XOR Gate": "xmark.circle",
    "XNOR Gate": "xmark.shield",
    "Odd Parity": "1.circle",
    "Even Parity": "2.circle",
    "Controlled Buffer": "triangle.righthalf.filled",
    "Controlled Inverter": "triangle.lefthalf.filled",
  ]

  private static let byLibraryId: [String: String] = [
    Builtin.baseId: "cursorarrow",
    Builtin.wiringId: "point.topleft.down.curvedto.point.bottomright.up",
    Builtin.gatesId: "capsule",
    Builtin.plexersId: "arrow.triangle.merge",
    Builtin.arithmeticId: "plus.forwardslash.minus",
    Builtin.fpArithmeticId: "function",
    Builtin.memoryId: "memorychip",
    Builtin.ioId: "lightbulb",
    Builtin.extraIoId: "square.grid.3x3",
    Builtin.ttlId: "cpu",
    Builtin.hdlId: "doc.text",
    Builtin.tclId: "terminal",
    Builtin.bfhId: "seven.square",
    Builtin.socId: "cpu",
  ]

  static func symbol(forToolNamed name: String, inLibrary library: String) -> String {
    if let exact = byToolId[name] { return exact }
    if let byLibrary = byLibraryId[library] { return byLibrary }
    return "square.on.circle"
  }

  /// The toolbar labels upstream uses for the five `#Base` entries. The tool's own `_ID` reads
  /// "Poke Tool"/"Edit Tool"; the button says "Poke"/"Select".
  static func editingDisplayName(forToolNamed name: String) -> String? {
    switch name {
    case BaseToolIds.poke: return "Poke"
    case BaseToolIds.edit: return "Select"
    case BaseToolIds.select: return "Select"
    case BaseToolIds.wiring: return "Wire"
    case BaseToolIds.textTool: return "Text"
    case BaseToolIds.menu: return "Menu"
    default: return nil
    }
  }

  /// The sentence a hover over one of `#Base`'s tools shows.
  ///
  /// **This is the only place that still has the `_ID`.** By the time a `ToolItem` exists its
  /// `name` has been through `editingDisplayName` above, and that mapping is lossy: `EditTool._ID`
  /// and `SelectTool._ID` both come out "Select", and 4.1.0 gives those two *different*
  /// descriptions. So the resolution happens here and the answer travels on `ToolItem.summary`;
  /// the views read it back through `ToolButtonToolTips.text(for:)` and never re-derive it.
  ///
  /// The table itself is `ToolButtonToolTips.upstreamBaseDescriptions`, which carries the jar
  /// citation. It used to be six sentences invented by this port ("Change input values while the
  /// simulation runs.", "Draw wires between component ports.", …); they are replaced by 4.1.0's
  /// own `tools.properties` strings so that the port, the manual and 4.1.0 agree on the wording.
  static func editingSummary(forToolNamed name: String) -> String? {
    ToolButtonToolTips.upstreamDescription(forToolNamed: name)
  }
}
