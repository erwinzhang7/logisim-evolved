// LogisimUI: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// Value types the shell binds to. None of these are kernel types: D4 makes component
// identity *reference* identity and forbids synthesised Equatable on `Component`, which is
// exactly what a SwiftUI `List`/`Table` selection would demand. So the shell projects the
// model into opaque stable IDs and plain values, and the project layer maps them back.

import CoreGraphics
import Foundation

// MARK: - Identifiers

/// Opaque, stable, `Sendable`. The project layer mints these; typically from
/// `ObjectIdentifier` (D4) plus a generation counter so a recycled address cannot alias a
/// stale SwiftUI selection.
public struct ComponentID: Hashable, Sendable, Codable, CustomStringConvertible {
  public var rawValue: UInt64
  public init(rawValue: UInt64) { self.rawValue = rawValue }
  public var description: String { "component#\(rawValue)" }
}

public struct CircuitID: Hashable, Sendable, Codable, CustomStringConvertible {
  public var rawValue: UInt64
  public init(rawValue: UInt64) { self.rawValue = rawValue }
  public var description: String { "circuit#\(rawValue)" }
}

public struct LibraryID: Hashable, Sendable, Codable, CustomStringConvertible {
  public var rawValue: UInt64
  public init(rawValue: UInt64) { self.rawValue = rawValue }
  public var description: String { "library#\(rawValue)" }
}

public struct ToolID: Hashable, Sendable, Codable, CustomStringConvertible {
  public var rawValue: UInt64
  public init(rawValue: UInt64) { self.rawValue = rawValue }
  public var description: String { "tool#\(rawValue)" }
}

/// A `CircuitState` in the simulation tree: the top state or any subcircuit substate.
public struct SimStateID: Hashable, Sendable, Codable {
  public var rawValue: UInt64
  public init(rawValue: UInt64) { self.rawValue = rawValue }
}

/// D5: `AnyAttribute`'s raw `name`. Display names live up here, not in the kernel.
public struct AttributeKey: Hashable, Sendable, Codable {
  public var name: String
  public init(_ name: String) { self.name = name }
}

// MARK: - Explorer content

/// One entry in the Design sidebar. Mirrors upstream's `Toolbox`/`ProjectExplorer` tree
/// without inheriting its behaviour of showing every builtin library expanded by default.
public struct ToolItem: Identifiable, Hashable, Sendable {
  public var id: ToolID
  public var name: String
  /// SF Symbol name. The port draws tools with symbols at sidebar size and with the real
  /// component glyph in the drag image.
  public var symbolName: String
  /// Keyboard shortcut character upstream binds via `KeyboardToolSelection` / the toolbar
  /// data, e.g. "1"…"9" for the first nine toolbar tools.
  public var shortcutCharacter: Character?
  public var summary: String?
  /// D11 / D8: a tool we cannot instantiate (a `jar#` library, or an unresolved builtin).
  /// It is still listed, disabled, with the reason, never silently absent.
  public var unavailableReason: String?

  public var isAvailable: Bool { unavailableReason == nil }

  public init(
    id: ToolID, name: String, symbolName: String = "square.on.circle",
    shortcutCharacter: Character? = nil, summary: String? = nil,
    unavailableReason: String? = nil
  ) {
    self.id = id
    self.name = name
    self.symbolName = symbolName
    self.shortcutCharacter = shortcutCharacter
    self.summary = summary
    self.unavailableReason = unavailableReason
  }
}

public struct LibraryItem: Identifiable, Hashable, Sendable {
  public enum Origin: Sendable, Hashable {
    case builtin
    case loadedLogisimFile(URL?)
    /// D11: `desc="jar#file.jar#com.Foo"`. Permanently unsupported; listed so the user can
    /// see why their components are placeholders, and so D8 can round-trip them.
    case jar(String)
    case unresolved(String)
  }

  public var id: LibraryID
  public var name: String
  public var origin: Origin
  public var tools: [ToolItem]
  public var isRemovable: Bool

  public var isResolved: Bool {
    switch origin {
    case .builtin, .loadedLogisimFile: return true
    case .jar, .unresolved: return false
    }
  }

  public init(
    id: LibraryID, name: String, origin: Origin, tools: [ToolItem], isRemovable: Bool = true
  ) {
    self.id = id
    self.name = name
    self.origin = origin
    self.tools = tools
    self.isRemovable = isRemovable
  }
}

public struct CircuitItem: Identifiable, Hashable, Sendable {
  public enum Kind: Sendable, Hashable {
    case circuit
    /// `vhdl` entities are first-class siblings of circuits in upstream's project tree.
    case vhdl
  }

  public var id: CircuitID
  public var name: String
  public var kind: Kind
  public var isMain: Bool
  public var componentCount: Int
  /// A circuit that failed to propagate: surfaced in the sidebar, not only in a dialog.
  public var errorSummary: String?

  public init(
    id: CircuitID, name: String, kind: Kind = .circuit, isMain: Bool = false,
    componentCount: Int = 0, errorSummary: String? = nil
  ) {
    self.id = id
    self.name = name
    self.kind = kind
    self.isMain = isMain
    self.componentCount = componentCount
    self.errorSummary = errorSummary
  }
}

/// One node of upstream's `SimulationTreeModel`: the live state hierarchy you descend to
/// poke inside a particular instance of a subcircuit.
public struct SimulationNode: Identifiable, Hashable, Sendable {
  public var id: SimStateID
  public var name: String
  public var circuitName: String
  public var children: [SimulationNode]
  public var isCurrent: Bool

  public init(
    id: SimStateID, name: String, circuitName: String, children: [SimulationNode] = [],
    isCurrent: Bool = false
  ) {
    self.id = id
    self.name = name
    self.circuitName = circuitName
    self.children = children
    self.isCurrent = isCurrent
  }
}

/// One slot in the document's toolbar. `ToolbarData` stores a separator as a `nil` entry
/// (`toolbarContents: [Tool?]`); modelled as a case here so the view cannot forget to handle it.
public enum ToolbarEntry: Sendable, Hashable, Identifiable {
  case tool(ToolItem)
  /// Position-carrying, because two separators in a row are distinct slots and an `Identifiable`
  /// list needs stable ids across a rebuild.
  case separator(Int)

  public var id: String {
    switch self {
    case .tool(let item): return "tool-\(item.id.rawValue)"
    case .separator(let index): return "sep-\(index)"
    }
  }

  public var item: ToolItem? {
    if case .tool(let item) = self { return item }
    return nil
  }
}

/// Everything the sidebar renders, in one immutable snapshot. Snapshotting rather than
/// live-querying is what lets the sidebar diff cheaply and animate insertions.
public struct ProjectOutline: Sendable, Equatable {
  public var circuits: [CircuitItem]
  public var libraries: [LibraryItem]
  public var simulationRoot: SimulationNode?
  /// The always-present editing tools (poke / select / wire / text / menu), which upstream
  /// puts in a floating `Toolbar` widget. Here they are window-toolbar items.
  public var editingTools: [ToolItem]

  /// The document's own toolbar, in file order, separators included.
  ///
  /// This is `<toolbar>` from the `.circ`, `Options.toolbarData`, and it is a different and
  /// much larger thing than `editingTools`. The default template's is 17 entries: the four canvas
  /// tools, then an input and an output Pin, then NOT/AND/OR/XOR/NAND/NOR, then D Flip-Flop and
  /// Register. `editingTools` is only `#Base`'s five, which is why the window showed five buttons
  /// where upstream shows a full palette.
  ///
  /// Kept separate rather than replacing `editingTools`, because the two answer different
  /// questions: `editingTools` is "which mode is the canvas in", a radio group, and this is "what
  /// can I place", a palette. Upstream conflates them into one `Toolbar` and that is why its
  /// selection highlight sits on gate buttons that are not modes.
  public var toolbarItems: [ToolbarEntry]

  public init(
    circuits: [CircuitItem] = [], libraries: [LibraryItem] = [],
    simulationRoot: SimulationNode? = nil, editingTools: [ToolItem] = [],
    toolbarItems: [ToolbarEntry] = []
  ) {
    self.circuits = circuits
    self.libraries = libraries
    self.simulationRoot = simulationRoot
    self.editingTools = editingTools
    self.toolbarItems = toolbarItems
  }

  public func tool(_ id: ToolID) -> ToolItem? {
    if let t = editingTools.first(where: { $0.id == id }) { return t }
    for library in libraries {
      if let t = library.tools.first(where: { $0.id == id }) { return t }
    }
    return nil
  }

  public func circuit(_ id: CircuitID) -> CircuitItem? {
    circuits.first { $0.id == id }
  }
}

// MARK: - Selection

/// What the inspector reflects. Upstream has four disjoint `AttrTableModel` subclasses
/// (`AttrTableCircuitModel`, `AttrTableComponentModel`, `AttrTableSelectionModel`,
/// `AttrTableToolModel`) selected by a chain of `instanceof` in `Frame.viewAttributes`;
/// this is that same set, made total by the compiler.
public enum EditorSelection: Sendable, Hashable {
  case nothing
  /// The circuit itself: its name, label font, appearance settings.
  case circuit(CircuitID)
  /// One or more placed components. Multi-selection edits the common attributes, which is
  /// what `SelectionAttributes` computes upstream.
  case components(Set<ComponentID>)
  /// A tool in the explorer: editing its attributes sets the defaults for the *next*
  /// placement.
  case tool(ToolID)

  public var componentIDs: Set<ComponentID> {
    if case .components(let ids) = self { return ids }
    return []
  }

  public var isEmpty: Bool {
    if case .nothing = self { return true }
    if case .components(let ids) = self { return ids.isEmpty }
    return false
  }
}

// MARK: - Inspector form

/// The concrete kinds D5's `AttributeValue` enum can hold, projected for editing. Keeping
/// this a closed enum means adding an attribute kind is a compile error in the editor
/// switch rather than a blank row at runtime.
public enum InspectorValue: Sendable, Hashable {
  case text(String)
  case multilineText(String)
  case integer(Int)
  case boundedInteger(Int, range: ClosedRange<Int>)
  case double(Double)
  case boolean(Bool)
  /// A closed set. `options` carries display strings so localisation stays in the UI layer
  /// (D5 explicitly leaves `toDisplayString` to us).
  case choice(selected: String, options: [InspectorChoice])
  case colour(RGBA)
  case font(name: String, size: Double, isBold: Bool, isItalic: Bool)
  case direction(CardinalDirection)
  /// D5's `.opaque(String)` and D8's unknown attributes: shown read-only with the raw
  /// string, so the user can see that the value exists and will survive a save.
  case opaque(String)
  /// Attributes whose value differs across a multi-selection.
  case mixed
}

public struct InspectorChoice: Sendable, Hashable, Identifiable {
  public var id: String { rawValue }
  public var rawValue: String
  public var displayName: String
  public var symbolName: String?

  public init(rawValue: String, displayName: String, symbolName: String? = nil) {
    self.rawValue = rawValue
    self.displayName = displayName
    self.symbolName = symbolName
  }
}

public enum CardinalDirection: String, Sendable, Hashable, CaseIterable, Codable {
  case east, west, north, south

  public var displayName: String {
    switch self {
    case .east: return "East"
    case .west: return "West"
    case .north: return "North"
    case .south: return "South"
    }
  }

  public var symbolName: String {
    switch self {
    case .east: return "arrow.right"
    case .west: return "arrow.left"
    case .north: return "arrow.up"
    case .south: return "arrow.down"
    }
  }
}

public struct InspectorRow: Identifiable, Sendable, Hashable {
  public var id: AttributeKey { key }
  public var key: AttributeKey
  public var displayName: String
  public var value: InspectorValue
  public var isEditable: Bool
  public var help: String?

  public init(
    key: AttributeKey, displayName: String, value: InspectorValue, isEditable: Bool = true,
    help: String? = nil
  ) {
    self.key = key
    self.displayName = displayName
    self.value = value
    self.isEditable = isEditable
    self.help = help
  }
}

public struct InspectorSection: Identifiable, Sendable, Hashable {
  public var id: String { title }
  public var title: String
  public var rows: [InspectorRow]
  public var isInitiallyExpanded: Bool

  public init(title: String, rows: [InspectorRow], isInitiallyExpanded: Bool = true) {
    self.title = title
    self.rows = rows
    self.isInitiallyExpanded = isInitiallyExpanded
  }
}

public struct InspectorForm: Sendable, Equatable {
  public var title: String
  public var subtitle: String?
  public var symbolName: String
  public var sections: [InspectorSection]
  /// Shown as a warning strip above the form. Used for D8 placeholders ("this component's
  /// library is missing; its attributes are preserved verbatim and cannot be edited").
  public var notice: String?

  public init(
    title: String, subtitle: String? = nil, symbolName: String = "slider.horizontal.3",
    sections: [InspectorSection] = [], notice: String? = nil
  ) {
    self.title = title
    self.subtitle = subtitle
    self.symbolName = symbolName
    self.sections = sections
    self.notice = notice
  }

  public static let empty = InspectorForm(title: "No Selection", symbolName: "cursorarrow")
  public var isEmpty: Bool { sections.allSatisfy { $0.rows.isEmpty } }
}

/// One edit, addressed by selection rather than by object, so it is safely replayable and
/// can be coalesced into a single undoable action for a multi-selection.
public struct AttributeEdit: Sendable, Hashable {
  public var target: EditorSelection
  public var key: AttributeKey
  public var newValue: InspectorValue

  public init(target: EditorSelection, key: AttributeKey, newValue: InspectorValue) {
    self.target = target
    self.key = key
    self.newValue = newValue
  }
}

// MARK: - Simulation

/// D7 in the UI. Upstream's `TickCounter` reports the *requested* frequency whenever it
/// cannot compute a real one, which hides the very drift D7 measures. Everything here is
/// what actually happened; `achievedTickHz` is optional precisely so "we don't know yet"
/// is distinguishable from "we are on target".
public struct SimulationStatus: Sendable, Equatable {
  public var isAutoPropagating: Bool
  public var isTicking: Bool
  public var requestedTickHz: Double
  public var achievedTickHz: Double?
  public var tickJitterSeconds: Double?
  /// Set when the scheduler cannot keep up. D7: "say so when the target cannot be met."
  public var isFallingBehind: Bool
  public var canStep: Bool
  /// D13: a propagation exception the kernel caught and recorded, rather than a crash.
  public var errorMessage: String?
  public var oscillationDetected: Bool
  public var currentStateName: String?
  public var canAscendState: Bool

  public init(
    isAutoPropagating: Bool = true, isTicking: Bool = false, requestedTickHz: Double = 1,
    achievedTickHz: Double? = nil, tickJitterSeconds: Double? = nil,
    isFallingBehind: Bool = false, canStep: Bool = true, errorMessage: String? = nil,
    oscillationDetected: Bool = false, currentStateName: String? = nil,
    canAscendState: Bool = false
  ) {
    self.isAutoPropagating = isAutoPropagating
    self.isTicking = isTicking
    self.requestedTickHz = requestedTickHz
    self.achievedTickHz = achievedTickHz
    self.tickJitterSeconds = tickJitterSeconds
    self.isFallingBehind = isFallingBehind
    self.canStep = canStep
    self.errorMessage = errorMessage
    self.oscillationDetected = oscillationDetected
    self.currentStateName = currentStateName
    self.canAscendState = canAscendState
  }

  /// `MenuSimulate.SUPPORTED_TICK_FREQUENCIES`.
  public static let supportedTickFrequencies: [Double] = [
    4096, 2048, 1024, 512, 256, 128, 64, 32, 16, 8, 4, 2, 1,
    0.5, 0.25, 0.125, 0.0625,
  ]

  public static func tickFrequencyLabel(_ hz: Double) -> String {
    if hz >= 1000 {
      let k = (hz / 100).rounded() / 10
      return k == k.rounded() ? "\(Int(k)) kHz" : String(format: "%.1f kHz", k)
    }
    if abs(hz - hz.rounded()) < 0.0001 { return "\(Int(hz.rounded())) Hz" }
    return String(format: "%g Hz", hz)
  }
}

public enum SimulationCommand: Sendable, Hashable {
  case toggleAutoPropagate
  case reset
  case step
  case tickHalf
  case tickFull
  case toggleTicking
  case setTickFrequency(Double)
  case enterState(SimStateID)
  case ascendState
  case enableVhdlSimulation(Bool)
  case generateVhdlSimulationFiles
}

// MARK: - Undo

public struct UndoStatus: Sendable, Equatable {
  /// Most recent first. Upstream shows these as Edit ▸ Undo History / Redo History
  /// submenus (`MenuEdit.java:204-240`); on macOS they belong in a popover off the toolbar.
  public var undoStack: [String]
  public var redoStack: [String]

  public init(undoStack: [String] = [], redoStack: [String] = []) {
    self.undoStack = undoStack
    self.redoStack = redoStack
  }

  public var canUndo: Bool { !undoStack.isEmpty }
  public var canRedo: Bool { !redoStack.isEmpty }
  public var undoName: String? { undoStack.first }
  public var redoName: String? { redoStack.first }
}

// MARK: - Project commands

/// The complete menu/command inventory taken from `LogisimMenuBar`, `MenuFile`, `MenuEdit`,
/// `MenuProject`, `MenuSimulate`, `MenuHelp` and `Popups` in 4.1.0. It is an enum so that
/// nothing can be silently dropped: adding a case forces every dispatcher to handle it, and
/// the set below is auditable against the Java in one screen.
///
/// Excluded deliberately, with reasons: `fileQuit`, `filePreferences` and `helpAbout` are
/// standard macOS application-menu items that the system provides (upstream conditionally
/// adds them itself on non-Mac: `MenuFile.java:85,89`); `loadJarLibrary` is present but
/// permanently reports the D11 gap rather than being absent.
public enum ProjectCommand: Sendable, Hashable {
  // File
  case newProject
  case openProject
  case mergeProject
  case closeProject
  case save
  case saveAs
  case revert
  case exportProject
  case extractRunProject
  case exportImage
  case print

  // Edit
  case undo
  case redo
  case clearUndoHistory
  case cut
  case copy
  case paste
  case delete
  case duplicate
  case selectAll
  case deselectAll
  case raise
  case lower
  case raiseToTop
  case lowerToBottom
  case addControlPoint
  case removeControlPoint
  case rotateSelection(quarterTurns: Int)
  case mirrorSelectionHorizontally
  case mirrorSelectionVertically

  // Project / circuit
  case addCircuit
  case addVhdlEntity
  case importVhdl
  case removeCircuit(CircuitID)
  case renameCircuit(CircuitID, String)
  case setMainCircuit(CircuitID)
  case moveCircuitUp(CircuitID)
  case moveCircuitDown(CircuitID)
  case setCurrentCircuit(CircuitID)
  case editLayout
  case editAppearance
  case toggleLayoutAppearance
  case revertAppearance
  case analyzeCircuit
  case circuitStatistics
  case projectOptions

  // Libraries
  case loadBuiltinLibrary
  case loadLogisimLibrary
  case loadJarLibrary
  case unloadLibrary(LibraryID)
  case reloadLibrary(LibraryID)

  // Tools
  case selectTool(ToolID)
  case revealComponent(ComponentID)

  // Windows upstream opens as separate frames; on macOS these are auxiliary windows
  // managed by the standard Window menu.
  case openLogWindow
  case openTestWindow
  case openChronogram
  case openAssemblyWindow
  case openFpgaWindow

  // Help
  case openUserGuide
  case openLibraryReference
  case openTutorial
  case openProjectWebsite
  case showLicence
}
