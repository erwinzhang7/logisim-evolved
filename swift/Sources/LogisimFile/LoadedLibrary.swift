// logisim-evolved: a native Swift/macOS port of logisim-evolution.
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution),
// which is GPL-3.0-only. This port is a derivative work and is therefore GPL-3.0-only.
// SPDX-License-Identifier: GPL-3.0-only
//
// Port of com.cburch.logisim.file.LoadedLibrary.

import Foundation
import LogisimKernel

/// `com.cburch.logisim.file.LoadedLibrary`: the indirection that lets an external library
/// (`file#…` or `jar#…`) be swapped underneath everything that already references it.
///
/// D3 ownership: a `LoadedLibrary` owns its `base` strongly (the base is a `LogisimFile` that
/// nothing else retains once the descriptor cache has gone weak), while `LibraryManager`
/// holds the `LoadedLibrary` weakly. There is no back edge from the base to the wrapper, so
/// the chain is acyclic.
public final class LoadedLibrary: Library, LibraryEventSource {
  /// Forwards the base's events on as our own, mirroring Java's inner `MyListener`. Held
  /// strongly here and weakly by the base's listener list, which is the same lifetime rule
  /// Java gets from `EventSourceWeakSupport` plus a strong field.
  private final class BaseForwarder: LibraryListener {
    unowned let owner: LoadedLibrary
    init(owner: LoadedLibrary) { self.owner = owner }
    func libraryChanged(_ event: LibraryEvent) { owner.fire(event) }
  }

  private var baseLibrary: Library
  private var dirtyFlag = false
  private var forwarder: BaseForwarder!
  private let listeners = WeakListenerList<LibraryListener>()

  init(base: Library) {
    // Java flattens nested wrappers: `while (base instanceof LoadedLibrary lib) base = lib.base`.
    var unwrapped = base
    while let wrapper = unwrapped as? LoadedLibrary { unwrapped = wrapper.baseLibrary }
    self.baseLibrary = unwrapped
    super.init()
    self.forwarder = BaseForwarder(owner: self)
    (self.baseLibrary as? LibraryEventSource)?.addLibraryListener(forwarder)
  }

  public var base: Library { baseLibrary }

  // MARK: Library forwarding

  public override var name: String { baseLibrary.name }
  public override var displayName: String { baseLibrary.displayName }
  public override var libraries: [Library] { baseLibrary.libraries }
  public override var tools: [Tool] { baseLibrary.tools }

  @discardableResult
  public override func removeLibrary(named name: String) -> Bool {
    baseLibrary.removeLibrary(named: name)
  }

  public override var isDirty: Bool { dirtyFlag || baseLibrary.isDirty }

  // MARK: LibraryEventSource

  public func addLibraryListener(_ listener: LibraryListener) { listeners.add(listener) }
  public func removeLibraryListener(_ listener: LibraryListener) { listeners.remove(listener) }

  private func fire(_ action: LibraryEventAction, _ data: LibraryEventData) {
    fire(LibraryEvent(source: self, action: action, data: data))
  }

  private func fire(_ event: LibraryEvent) {
    // Java re-sources an event that came from the base so listeners see this wrapper.
    let outgoing =
      event.source === self
      ? event
      : LibraryEvent(source: self, action: event.action, data: event.data)
    for listener in listeners.current() { listener.libraryChanged(outgoing) }
  }

  // MARK: Mutation

  /// Java's package-private `setBase`. Reached from `LibraryManager.reload` and
  /// `LibraryManager.fileSaved`.
  func setBase(_ value: Library) {
    (baseLibrary as? LibraryEventSource)?.removeLibraryListener(forwarder)
    let old = baseLibrary
    baseLibrary = value
    resolveChanges(from: old)
    (baseLibrary as? LibraryEventSource)?.addLibraryListener(forwarder)
  }

  func setDirty(_ value: Bool) {
    guard dirtyFlag != value else { return }
    dirtyFlag = value
    fire(.dirtyState, .dirty(isDirty))
  }

  /// Java's `resolveChanges(Library old)`: diff the old and new contents and tell everyone
  /// what moved, then rewrite every placed component and every bound tool to the replacements.
  ///
  /// Upstream's `replaceAll(compMap, toolMap)` walks `Projects.getOpenProjects()` and reaches
  /// into each project's current tool and current circuit. That is Project-layer state which D9
  /// keeps out of the file layer, so the mapping is computed here and handed to
  /// `replacementHandler`.
  ///
  /// **The handler was unassigned for four milestones**; this method built the whole map on
  /// every reload and dropped it, so "reload library" updated the library and its listeners and
  /// left every already-placed component bound to the file that had just been replaced. Closed
  /// by `LibraryReplacementApply` (board #64); the note that used to sit here saying the Project
  /// layer "installs a handler at M7" is exactly the kind of forward promise that stops being
  /// re-read once it is written.
  private func resolveChanges(from old: Library) {
    guard !listeners.isEmpty else { return }

    if baseLibrary.displayName != old.displayName {
      fire(.setName, .name(baseLibrary.displayName))
    }

    let newLibraryIds = Set(baseLibrary.libraries.map(ObjectIdentifier.init))
    for library in old.libraries where !newLibraryIds.contains(ObjectIdentifier(library)) {
      fire(.removeLibrary, .library(library))
    }
    let oldLibraryIds = Set(old.libraries.map(ObjectIdentifier.init))
    for library in baseLibrary.libraries where !oldLibraryIds.contains(ObjectIdentifier(library)) {
      fire(.addLibrary, .library(library))
    }

    var factoryMap: [ObjectIdentifier: (any ComponentFactory)?] = [:]
    var toolMap: [ObjectIdentifier: Tool?] = [:]
    var mappedNewTools = Set<ObjectIdentifier>()

    for oldTool in old.tools {
      let newTool = baseLibrary.tool(named: oldTool.name)
      toolMap[ObjectIdentifier(oldTool)] = newTool
      if let newTool { mappedNewTools.insert(ObjectIdentifier(newTool)) }
      if let oldAdd = oldTool as? AddTool {
        if let newAdd = newTool as? AddTool {
          factoryMap[ObjectIdentifier(oldAdd.factory)] = newAdd.factory
        } else {
          factoryMap[ObjectIdentifier(oldAdd.factory)] = .some(nil)
        }
      }
    }

    LoadedLibrary.replacementHandler?(
      LibraryReplacement(factories: factoryMap, tools: toolMap))

    // Upstream computes `new HashSet<>(old.getTools())` minus `toolMap.keySet()` and fires
    // REMOVE_TOOL for the remainder, but every old tool was just put into `toolMap`, so the
    // remainder is always empty and the event never fires. Preserved as dead code rather than
    // "fixed": a listener that suddenly started receiving REMOVE_TOOL on reload would be
    // seeing behaviour no upstream build has ever produced.

    for newTool in baseLibrary.tools
    where !mappedNewTools.contains(ObjectIdentifier(newTool)) {
      fire(.addTool, .tool(newTool))
    }
  }

  /// Installed by the Project layer to perform upstream's cross-project component rewrite.
  ///
  /// Left `nil` a milestone longer than intended: `resolveChanges` built the whole map and handed
  /// it to nobody, so reloading a library updated the library and its listeners and left every
  /// already-placed component pointing at a factory from the file that had just been replaced.
  /// See `LibraryReplacementApply` in `LogisimUI` for the conformer, and `replaceAll(in:)` just
  /// below for the half that has to happen down here.
  nonisolated(unsafe) public static var replacementHandler: ((LibraryReplacement) -> Void)?

  // MARK: Attribute copying

  /// Java's `LoadedLibrary.copyAttributes(dest, src)`, used by `ToolbarData.replaceAll` and
  /// `MouseMappings.replaceAll`.
  ///
  /// D5/D13: `setValue` throws (an absent or read-only attribute is reachable from a `.circ`
  /// file), so this throws too rather than swallowing the error. Copying goes through the
  /// storage form so neither side has to recover the attribute's static type.
  public static func copyAttributes(
    to destination: any AttributeSet, from source: any AttributeSet
  ) throws {
    for destinationAttribute in destination.attributes {
      guard let sourceAttribute = source.attribute(named: destinationAttribute.name) else {
        continue
      }
      try destination.setRawValue(destinationAttribute, source.rawValue(sourceAttribute))
    }
  }
}

/// The old→new mapping computed by a library reload, keyed by reference identity (D4).
public struct LibraryReplacement {
  /// Old factory identity → replacement, or nil when the factory is gone entirely.
  public let factories: [ObjectIdentifier: (any ComponentFactory)?]
  /// Old tool identity → replacement, or nil when the tool is gone entirely.
  public let tools: [ObjectIdentifier: Tool?]

  public init(
    factories: [ObjectIdentifier: (any ComponentFactory)?], tools: [ObjectIdentifier: Tool?]
  ) {
    self.factories = factories
    self.tools = tools
  }

  /// The two lines of `LoadedLibrary.replaceAll(LogisimFile, compMap, toolMap)` that cannot be
  /// written outside this module:
  ///
  /// ```java
  /// file.getOptions().getToolbarData().replaceAll(toolMap);
  /// file.getOptions().getMouseMappings().replaceAll(toolMap);
  /// ```
  ///
  /// Both `replaceAll`s are module-internal here, so the handler in `LogisimUI` cannot reach
  /// them; the third line of upstream's method, the per-circuit component rewrite, needs
  /// `CircuitMutation`, which lives above this module, and stays there.
  ///
  /// D13: both throw, because rebinding a toolbar entry writes attributes. A reload that cannot
  /// rebind one entry must not abandon the rest of the rewrite, so the failures are collected
  /// and returned rather than propagated; the caller decides what to do with them, and the
  /// component rewrite still runs.
  @discardableResult
  public func replaceAll(in file: LogisimFile) -> [any Error] {
    var failures: [any Error] = []
    do { try file.options.toolbarData.replaceAll(tools) } catch { failures.append(error) }
    do { try file.options.mouseMappings.replaceAll(tools) } catch { failures.append(error) }
    return failures
  }
}
