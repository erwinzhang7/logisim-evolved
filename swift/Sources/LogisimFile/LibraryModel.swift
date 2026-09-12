// logisim-evolved: a native Swift/macOS port of logisim-evolution.
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution),
// which is GPL-3.0-only. This port is a derivative work and is therefore GPL-3.0-only.
// SPDX-License-Identifier: GPL-3.0-only
//
// Port of the library/tool vocabulary the file package is written against:
//   com.cburch.logisim.tools.Library, com.cburch.logisim.tools.Tool,
//   com.cburch.logisim.tools.AddTool, com.cburch.logisim.comp.ComponentFactory,
//   com.cburch.logisim.file.LibraryEvent / LibraryListener / LibraryEventSource.
//
// Only the surface that file loading and library resolution actually touch is ported here.
// The interactive halves of `Tool` and `AddTool` (cursor, mouse/key handling, ghost drawing,
// `Transferable`, `AppPreferences` listeners) are M6/M7 work and are deliberately absent;
// every one of them is AWT- or preference-bound, and D9 keeps both out of this layer.

import Foundation
import LogisimKernel

// MARK: - Component factories

// `com.cburch.logisim.comp.ComponentFactory` is declared in `ComponentFactory.swift`, alongside
// `AbstractComponentFactory` and `AttributeDefaultProvider`, as part of the netlist-model port.
// Library resolution only needs `name`, `displayName` and `createAttributeSet()` from it; the
// rest of that protocol (createComponent, getOffsetBounds, getFeature, the `instanceof`
// stand-ins) exists for `Circuit` and the component tranches at M4/M5.

/// The seam for `com.cburch.logisim.circuit.Circuit`.
///
/// `Circuit` itself is not part of this task and is not defined here; the file layer only ever
/// needs a circuit's name and the factory that places it as a subcircuit. Whatever the ported
/// `Circuit` turns out to be, it conforms to this and slots in unchanged.
public protocol CircuitReference: AnyObject {
  var name: String { get }
  var subcircuitFactory: any SubcircuitFactory { get }
}

/// `com.cburch.logisim.circuit.SubcircuitFactory`.
///
/// D3: `Circuit` owns its `SubcircuitFactory`, so the back edge here must be `unowned` in the
/// conforming type. In Java this pair is an unconditional strong 2-cycle on every circuit in
/// every open file; the GC absorbs it and ARC would not.
public protocol SubcircuitFactory: ComponentFactory {
  var subcircuit: any CircuitReference { get }
}

/// The seam for `com.cburch.logisim.vhdl.base.VhdlContent` / `VhdlEntity`. Same reasoning as
/// `CircuitReference`: the file layer needs the name and the tool, nothing else.
public protocol VhdlContentReference: AnyObject {
  var name: String { get }
}

/// `com.cburch.logisim.vhdl.base.VhdlEntity`.
public protocol VhdlEntityFactory: ComponentFactory {
  var content: any VhdlContentReference { get }
}

// MARK: - Tool

/// `com.cburch.logisim.tools.Tool`.
///
/// Java derives `getName()` reflectively from a `public static final String _ID` field
/// (`LibraryUtil.getName`), falling back to the simple class name. Swift has no equivalent
/// reflection over static fields, so the identity is declared as an overridable type
/// property. The observable contract, a stable string that `.circ` references by name, is
/// identical.
open class Tool {
  open class var toolId: String { "Tool" }

  public init() {}

  /// Java `getName()`.
  open var name: String { Self.toolId }

  /// Java `getDisplayName()`. Localised upstream; raw here, per D5's note on display strings.
  open var displayName: String { name }

  /// Java `getDescription()`.
  open var toolDescription: String { "" }

  /// Java `getAttributeSet()`, which returns null for tools that have none.
  open var attributeSet: (any AttributeSet)? { nil }

  /// Java `cloneTool()`; the base class returns `this`, and only `AddTool` really copies.
  open func cloneTool() -> Tool { self }

  /// Java `sharesSource(Tool)`; reference identity in the base class. Used by
  /// `ToolbarData.usesToolFromSource` and `MouseMappings.usesToolFromSource` to decide
  /// whether unloading a library would strand a toolbar button or a mouse binding.
  open func sharesSource(_ other: Tool) -> Bool { self === other }
}

extension Tool: CustomStringConvertible {
  public var description: String { name }
}

/// `com.cburch.logisim.tools.AddTool`; the tool that places one component factory.
///
/// D4: identity is reference identity. `AddTool` is a class and is never made `Equatable`;
/// `LogisimFile.findTool`, `ToolbarData.replaceAll` and `MouseMappings.replaceAll` all key on
/// it by identity, exactly as the Java does.
open class AddTool: Tool {
  public let factory: any ComponentFactory
  private let attrs: any AttributeSet

  public init(factory: any ComponentFactory) {
    self.factory = factory
    self.attrs = factory.createAttributeSet()
    super.init()
  }

  /// Java's private copy constructor, reached through `cloneTool()`.
  public init(cloning base: AddTool) {
    self.factory = base.factory
    self.attrs = base.attrs.copy()
    super.init()
  }

  open override var name: String { factory.name }
  open override var displayName: String { factory.displayName }
  open override var attributeSet: (any AttributeSet)? { attrs }
  open override func cloneTool() -> Tool { AddTool(cloning: self) }

  /// Java `AddTool.sharesSource(Tool)`.
  ///
  /// **Load-bearing for the writer, and not optional.** `XmlReader` stores *clones* of library
  /// tools in the toolbar and the mouse mappings, and `XmlWriter.fromTool` resolves a tool back
  /// to its library through `libraryContains`, which is written on `sharesSource`. Inheriting
  /// `Tool`'s reference-identity answer would make every cloned toolbar button unresolvable, so
  /// saving any file with a toolbar would report `tool `…' not found` and fail.
  ///
  /// Upstream's version is three-way: `sourceLoadAttempted && o.sourceLoadAttempted` compares
  /// factories, otherwise it compares `FactoryDescription`s. `FactoryDescription` is the lazy
  /// JAR-loading machinery that D11 does not bring across, and this port builds its factory
  /// eagerly, so `sourceLoadAttempted` is permanently true and only the first branch is
  /// reachable.
  open override func sharesSource(_ other: Tool) -> Bool {
    guard let other = other as? AddTool else { return false }
    return factory === other.factory
  }
}

// MARK: - Library

/// `com.cburch.logisim.tools.Library`.
open class Library {
  private var hiddenFlag = false

  /// `<tool>` children of this library's `<lib>` element that did not resolve to a real `Tool`.
  ///
  /// D8 applies to tools as well as components. A builtin shell resolves, so it never becomes a
  /// `MissingLibrary`, which has its own verbatim path, but its tool list is empty until the
  /// component library lands at M4/M5, so `tool(named:)` returns nil for every `<tool>` the file
  /// carries. Without this the reader silently drops the configuration and the writer emits a
  /// bare `<lib …/>`, which is precisely the diff the round-trip gate reports.
  ///
  /// Keeping the elements verbatim means the round trip is lossless *now*, and each entry simply
  /// stops being used as its tool becomes real. Nothing here needs revisiting at M4/M5.
  public private(set) var unresolvedToolElements: [XMLElement] = []

  /// Retain a `<tool>` element whose tool could not be resolved. Detached copies, so later
  /// mutation of the source document cannot reach into stored state.
  public func absorbUnresolvedTool(_ element: XMLElement) {
    guard let duplicate = element.copy() as? XMLElement else { return }
    duplicate.detach()
    unresolvedToolElements.append(duplicate)
  }

  public func clearUnresolvedTools() { unresolvedToolElements.removeAll() }

  public init() {}

  /// The library's `_ID`: the string a `<lib desc="#Name">` resolves against. See the note on
  /// `Tool.toolId` for why this is a type property rather than reflection.
  open class var libraryId: String { "Library" }

  /// Java `getName()`.
  open var name: String { Self.libraryId }

  /// Java `getDisplayName()`, which defaults to `getName()`.
  open var displayName: String { name }

  /// Java `getLibraries()`.
  open var libraries: [Library] { [] }

  /// Java `getTools()`.
  open var tools: [Tool] { [] }

  /// Java `getLibrary(String)`.
  open func library(named name: String) -> Library? {
    libraries.first { $0.name == name }
  }

  /// Java `getTool(String)`.
  open func tool(named name: String) -> Tool? {
    tools.first { $0.name == name }
  }

  /// Java `removeLibrary(String)`: false in the base class.
  @discardableResult
  open func removeLibrary(named name: String) -> Bool { false }

  /// Java `contains(ComponentFactory)`.
  open func contains(_ query: any ComponentFactory) -> Bool { indexOf(query) >= 0 }

  /// Java `containsFromSource(Tool)`.
  open func containsFromSource(_ query: Tool) -> Bool {
    tools.contains { $0.sharesSource(query) }
  }

  /// Java `indexOf(ComponentFactory)`. Note the index counts *all* tools, not just `AddTool`s,
  /// which is upstream's behaviour and is what `Library.contains` is built on.
  open func indexOf(_ query: any ComponentFactory) -> Int {
    var index = -1
    for tool in tools {
      index += 1
      if let addTool = tool as? AddTool, addTool.factory === query { return index }
    }
    return -1
  }

  open var isDirty: Bool { false }

  public var isHidden: Bool { hiddenFlag }

  public func setHidden() { hiddenFlag = true }
}

extension Library: CustomStringConvertible {
  public var description: String { name }
}

// MARK: - Library events

/// `com.cburch.logisim.file.LibraryEvent`'s action constants, as a real enum. The raw values
/// are upstream's `int`s so a log or a test can compare them directly.
public enum LibraryEventAction: Int {
  case addTool = 0
  case removeTool = 1
  case moveTool = 2
  case addLibrary = 3
  case removeLibrary = 4
  case setMain = 5
  case setName = 6
  case dirtyState = 7
}

/// `com.cburch.logisim.file.LibraryEvent`.
///
/// Java's `getData()` is `Object`; the payload is a `Tool`, a `Library`, a `Circuit`, a
/// `String` or a `Boolean` depending on the action, so this stays a closed enum rather than
/// `Any`; every consumer then has to handle every shape.
public enum LibraryEventData {
  case none
  case tool(Tool)
  case library(Library)
  case circuit(any CircuitReference)
  case name(String)
  case dirty(Bool)
}

public struct LibraryEvent {
  /// D3: an event must not keep its source alive. Listeners are invoked synchronously inside
  /// the source's own method, so the source is always live for the duration of the call.
  public unowned let source: Library
  public let action: LibraryEventAction
  public let data: LibraryEventData

  public init(source: Library, action: LibraryEventAction, data: LibraryEventData) {
    self.source = source
    self.action = action
    self.data = data
  }
}

public protocol LibraryListener: AnyObject {
  func libraryChanged(_ event: LibraryEvent)
}

/// `com.cburch.logisim.file.LibraryEventSource`.
public protocol LibraryEventSource: AnyObject {
  func addLibraryListener(_ listener: LibraryListener)
  func removeLibraryListener(_ listener: LibraryListener)
}

/// `com.cburch.logisim.util.EventSourceWeakSupport`, which holds listeners through
/// `WeakReference` and prunes cleared entries as it iterates.
///
/// D3 forbids the mechanical `NSMapTable.weakToStrongObjects()` translation of Java's weak
/// collections, because under ARC those keys stay pinned by the very cycles they exist to
/// escape. Here the eviction owner is explicit: `purge()` runs on every add and every
/// iteration, and listener counts are in the tens, so the linear scan is free.
/// The element type is deliberately *unconstrained*, with the weak reference held as
/// `AnyObject`. Writing `<Listener: AnyObject>` looks tighter and does not compile at the one
/// place it is needed: `WeakListenerList<LibraryListener>` passes the **existential**
/// `any LibraryListener`, and an existential does not satisfy an `AnyObject` requirement even
/// when its protocol is class-bound. Every call site passes a class-bound protocol, so the
/// downcast in `current()` always succeeds; a non-class type would simply never survive the
/// weak box, which is a misuse no `.circ` file can provoke.
final class WeakListenerList<Listener> {
  private final class Box {
    weak var value: AnyObject?
    init(_ value: AnyObject) { self.value = value }
  }

  // Registration/removal can overlap delivery (e.g. the simulation wrapper and
  // the canvas both subscribe to a Circuit). Own the array here, not at call sites.
  // current() releases this lock before any listener callback is invoked.
  private let lock = NSLock()
  private var boxes: [Box] = []

  var isEmpty: Bool {
    lock.lock()
    defer { lock.unlock() }
    purge()
    return boxes.isEmpty
  }

  func add(_ listener: Listener) {
    lock.lock()
    defer { lock.unlock() }
    purge()
    let object = listener as AnyObject
    guard !boxes.contains(where: { $0.value === object }) else { return }
    boxes.append(Box(object))
  }

  func remove(_ listener: Listener) {
    lock.lock()
    defer { lock.unlock() }
    let object = listener as AnyObject
    boxes.removeAll { $0.value == nil || $0.value === object }
  }

  /// Snapshot before dispatch: a listener is allowed to unsubscribe from inside its own
  /// callback, exactly as it may in Java.
  func current() -> [Listener] {
    lock.lock()
    defer { lock.unlock() }
    purge()
    return boxes.compactMap { $0.value as? Listener }
  }

  private func purge() {
    boxes.removeAll { $0.value == nil }
  }
}
