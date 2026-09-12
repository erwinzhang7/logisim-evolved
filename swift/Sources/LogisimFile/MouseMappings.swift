// logisim-evolved: a native Swift/macOS port of logisim-evolution.
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution),
// which is GPL-3.0-only. This port is a derivative work and is therefore GPL-3.0-only.
// SPDX-License-Identifier: GPL-3.0-only
//
// Port of com.cburch.logisim.file.MouseMappings: the `<mappings>` section of a `.circ`, which
// binds a modifier mask to the tool a click with those modifiers invokes.

import Foundation
import LogisimKernel

/// `MouseMappings.MouseMappingsListener`.
public protocol MouseMappingsListener: AnyObject {
  func mouseMappingsChanged()
}

/// `com.cburch.logisim.file.MouseMappings`.
///
/// The key is `java.awt.event.MouseEvent.getModifiersEx()`, a 32-bit AWT mask. It is kept as a
/// raw `Int32` rather than being translated into an AppKit `NSEvent.ModifierFlags`, for two
/// independent reasons: the number is written verbatim into the file (`<tool map="…">`), so
/// byte-exact round-tripping requires it; and D9 keeps AppKit out of this layer. Translating a
/// mask to a macOS modifier convention is an M7 decision made at the point of use, not here.
public final class MouseMappings {

  /// Java's `HashMap<Integer, Tool>`. Insertion order is *not* preserved by a `HashMap`, and
  /// the writer sorts before emitting, so a Swift `Dictionary`'s equally arbitrary order is
  /// faithful.
  private var map: [Int32: Tool] = [:]

  /// Java's `List<MouseMappingsListener> listeners = new ArrayList<>()`: a **strong** list.
  ///
  /// **Deviation, deliberate.** Held weakly here. Upstream's list is strong *and*
  /// `removeMouseMappingsListener` is misimplemented (see below), so no listener it is ever
  /// handed can be released while the file is open: a closed project window stays alive
  /// through `Options → MouseMappings`. Java's GC eventually collects the whole island;
  /// ARC never would, which makes the literal translation a guaranteed leak (D3). For a live
  /// listener the observable behaviour is identical.
  private let listeners = WeakListenerList<MouseMappingsListener>()

  /// Java's one-entry lookup cache. `cacheMods` starts at 0 because that is Java's default for
  /// an `int` field, which is a latent bug; a first lookup of modifier mask 0 returns the
  /// null `cacheTool` regardless of the map. It is unobservable in practice (`getModifiersEx`
  /// always carries a button bit for a real click, and `setToolFor(0, …)` invalidates the
  /// cache before any mapping for 0 can exist), and it is preserved rather than repaired.
  private var cacheMods: Int32 = 0
  private var cacheTool: Tool?

  public init() {}

  // MARK: - Listeners

  /// Java `addMouseMappingsListener(MouseMappingsListener)`.
  public func addMouseMappingsListener(_ listener: MouseMappingsListener) {
    listeners.add(listener)
  }

  /// Java `removeMouseMappingsListener(MouseMappingsListener)`.
  ///
  /// **Bug preserved.** Upstream's body is `listeners.add(l)`: removing a listener registers
  /// it a second time. `WeakListenerList.add` de-duplicates, so the concrete effect here is
  /// that the call does nothing, which is also what upstream achieves for a listener that was
  /// already registered (`ArrayList.add` would append a duplicate and it would then be
  /// notified twice). The difference is confined to double notification of a listener that
  /// asked to be removed; no `.circ` file and no load path reaches it, and reproducing a
  /// double-dispatch bug in a weak list is not worth an unbounded listener list.
  public func removeMouseMappingsListener(_ listener: MouseMappingsListener) {
    listeners.add(listener)
  }

  private func fireMouseMappingsChanged() {
    for listener in listeners.current() { listener.mouseMappingsChanged() }
  }

  // MARK: - Queries

  /// Java `getMappedModifiers()`.
  public var mappedModifiers: Set<Int32> { Set(map.keys) }

  /// Java `getMappings()`.
  public var mappings: [Int32: Tool] { map }

  /// Java `getToolFor(int)`.
  public func toolFor(modifiers mods: Int32) -> Tool? {
    if mods == cacheMods { return cacheTool }
    let result = map[mods]
    cacheMods = mods
    cacheTool = result
    return result
  }

  /// Java `containsSelectTool()`.
  ///
  /// Upstream tests `tool instanceof SelectTool`. `SelectTool` is an M7 editing tool that does
  /// not exist yet, so the test is by `_ID`, which is the same string the file stores. When
  /// the real class lands this becomes an `as?` and the behaviour does not change.
  public var containsSelectTool: Bool {
    map.values.contains { $0.name == BaseLibrary.selectToolId }
  }

  /// Java's package-private `usesToolFromSource(Tool)`: actually `public` upstream, consulted
  /// by `LogisimFile.getUnloadLibraryMessage` before a library is unloaded.
  public func usesToolFromSource(_ query: Tool) -> Bool {
    map.values.contains { $0.sharesSource(query) }
  }

  // MARK: - Mutation

  /// Java `setToolFor(int, Tool)`.
  public func setToolFor(modifiers mods: Int32, tool: Tool?) {
    if mods == cacheMods { cacheMods = -1 }
    guard let tool else {
      if map.removeValue(forKey: mods) != nil { fireMouseMappingsChanged() }
      return
    }
    let old = map.updateValue(tool, forKey: mods)
    // Java compares with `!=` on references, so replacing a mapping with the very same tool
    // object fires nothing. D4: reference identity, not structural equality.
    if old !== tool { fireMouseMappingsChanged() }
  }

  /// Java `copyFrom(MouseMappings, LogisimFile)`.
  ///
  /// D5/D13: `AttributeSets.copy` throws, so this does too, see `ToolbarData.copyFrom`.
  public func copyFrom(_ other: MouseMappings, file: LogisimFile) throws {
    if self === other { return }
    cacheMods = -1
    map.removeAll()
    for (mods, sourceTool) in other.map {
      guard let found = file.findTool(sourceTool) else { continue }
      let destinationTool = found.cloneTool()
      if let source = sourceTool.attributeSet, let destination = destinationTool.attributeSet {
        try AttributeSets.copy(from: source, to: destination)
      }
      map[mods] = destinationTool
    }
    fireMouseMappingsChanged()
  }

  /// Java's package-private `replaceAll(Map<Tool, Tool>)`, called after a library reload.
  ///
  /// The map is keyed by `ObjectIdentifier` because D4 makes `Tool` identity reference
  /// identity, and a `nil` value means the tool is gone from the reloaded library.
  ///
  /// **Two upstream bugs are preserved verbatim.**
  ///
  /// 1. `searchFor = (tool instanceof AddTool addTool) ? addTool.getFactory() : tool`, and the
  ///    map handed in by `LoadedLibrary.resolveChanges` is a `Map<Tool, Tool>`. A
  ///    `ComponentFactory` is never `equals` to a `Tool`, so `containsKey` is *always* false
  ///    for an `AddTool` binding: a mouse mapping onto a placed component is never updated by
  ///    a reload. Since every mapping written by the toolbar UI is an `AddTool` or one of the
  ///    `Base` tools, this makes the method very nearly a no-op.
  /// 2. `replaceInMap`'s deletion branch is `map.remove(searchFor)`, passing a tool (or a
  ///    factory) where a modifier mask is expected. On a `HashMap<Integer, Tool>` that returns
  ///    null and changes nothing, so a binding whose tool has vanished is **not** removed, it
  ///    keeps pointing at the stale tool, while `changed` is still set and listeners are told
  ///    something happened.
  ///
  /// Neither is reachable from loading a `.circ`; both are reachable from the interactive
  /// "reload library" command, which is why they are reproduced rather than repaired.
  func replaceAll(_ toolMap: [ObjectIdentifier: Tool?]) throws {
    var changed = false
    for (key, tool) in map {
      if tool is AddTool {
        // Bug 1: upstream searches the tool map under the factory and finds nothing.
        continue
      }
      guard let replacement = toolMap[ObjectIdentifier(tool)] else { continue }
      changed = true
      guard let newTool = replacement else {
        // Bug 2: upstream's `map.remove(searchFor)` uses the wrong key space and removes
        // nothing, so the stale binding survives.
        continue
      }
      let clone = newTool.cloneTool()
      if let destination = clone.attributeSet, let source = tool.attributeSet {
        try LoadedLibrary.copyAttributes(to: destination, from: source)
      }
      map[key] = clone
    }
    if changed { fireMouseMappingsChanged() }
  }
}
