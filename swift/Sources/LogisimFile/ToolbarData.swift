// logisim-evolved: a native Swift/macOS port of logisim-evolution.
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution),
// which is GPL-3.0-only. This port is a derivative work and is therefore GPL-3.0-only.
// SPDX-License-Identifier: GPL-3.0-only
//
// Port of com.cburch.logisim.file.ToolbarData: the ordered `<toolbar>` contents of a `.circ`,
// where a `nil` entry is a separator.

import Foundation
import LogisimKernel

/// `ToolbarData.ToolbarListener`.
public protocol ToolbarListener: AnyObject {
  func toolbarChanged()
}

/// The token returned by `ToolbarData.addToolAttributeListener`.
///
/// **Deviation in mechanism, forced by D5, and it is the safer shape.** Java keeps a
/// `EventSourceWeakSupport<AttributeListener>` and pushes the listener onto every tool's
/// attribute set; the sets hold it weakly too, so nobody owns it and the UI component that
/// created it is the real owner. In the port `AttributeSet.addAttributeListener` returns an
/// `AttributeSubscription` that must be retained or the registration lapses, so the ownership
/// has to be named. It is named here: the caller holds this token, the token holds the
/// listener strongly and one `AttributeSubscription` per tool, and dropping the token
/// unsubscribes from every tool at once. `ToolbarData` holds the token *weakly*, which is
/// exactly the lifetime Java's weak listener list gives.
public final class ToolAttributeSubscription {
  /// The listener itself, held strongly; this token is its owner.
  public let listener: AttributeListener

  /// One live registration per tool, keyed by tool identity (D4: reference identity, never
  /// structural equality).
  private var subscriptions: [ObjectIdentifier: AttributeSubscription] = [:]

  fileprivate init(listener: AttributeListener) {
    self.listener = listener
  }

  /// Java's `addAttributeListeners(tool)`, for one listener.
  ///
  /// Java re-adds unconditionally; `EventSourceWeakSupport.add` de-duplicates, so a tool that
  /// is already listened to does not get a second registration. Keying on tool identity gives
  /// the same result.
  fileprivate func subscribe(to tool: Tool) {
    guard let attributes = tool.attributeSet else { return }
    let key = ObjectIdentifier(tool)
    guard subscriptions[key] == nil else { return }
    subscriptions[key] = attributes.addAttributeListener(listener)
  }

  /// Java's `removeAttributeListeners(tool)`, for one listener.
  fileprivate func unsubscribe(from tool: Tool) {
    subscriptions.removeValue(forKey: ObjectIdentifier(tool))?.cancel()
  }

  /// Drop every registration this token holds.
  public func cancel() {
    for (_, subscription) in subscriptions { subscription.cancel() }
    subscriptions.removeAll()
  }

  deinit { cancel() }
}

/// `com.cburch.logisim.file.ToolbarData`.
///
/// Contents are `Tool?` because upstream stores a literal `null` for a separator and every
/// query, `getContents`, `get(int)`, `move`, `remove`, hands that null straight back. A
/// separate `.separator` case would read better and would change `getContents().get(i)` from
/// null to an object at ~30 call sites, so the null is kept.
public final class ToolbarData {

  private var contents: [Tool?] = []
  private let listeners = WeakListenerList<ToolbarListener>()
  private let toolListeners = WeakListenerList<ToolAttributeSubscription>()

  public init() {}

  // MARK: - Attribute listeners

  /// Java `addAttributeListeners(Tool)`.
  private func addAttributeListeners(_ tool: Tool) {
    for token in toolListeners.current() { token.subscribe(to: tool) }
  }

  /// Java `removeAttributeListeners(Tool)`.
  private func removeAttributeListeners(_ tool: Tool) {
    for token in toolListeners.current() { token.unsubscribe(from: tool) }
  }

  /// Java `addToolAttributeListener(AttributeListener)`.
  @discardableResult
  public func addToolAttributeListener(
    _ listener: AttributeListener
  ) -> ToolAttributeSubscription {
    let token = ToolAttributeSubscription(listener: listener)
    for tool in contents {
      guard let tool else { continue }
      token.subscribe(to: tool)
    }
    toolListeners.add(token)
    return token
  }

  /// Java `removeToolAttributeListener(AttributeListener)`.
  ///
  /// Takes the token rather than the listener, for the ownership reason spelled out on
  /// `ToolAttributeSubscription`. Simply releasing the token has the same effect.
  public func removeToolAttributeListener(_ token: ToolAttributeSubscription) {
    token.cancel()
    toolListeners.remove(token)
  }

  // MARK: - Toolbar listeners

  /// Java `addToolbarListener(ToolbarListener)`.
  public func addToolbarListener(_ listener: ToolbarListener) {
    listeners.add(listener)
  }

  /// Java `removeToolbarListener(ToolbarListener)`.
  public func removeToolbarListener(_ listener: ToolbarListener) {
    listeners.remove(listener)
  }

  /// Java `fireToolbarChanged()`.
  public func fireToolbarChanged() {
    for listener in listeners.current() { listener.toolbarChanged() }
  }

  // MARK: - Mutation

  /// Java `addSeparator()`.
  public func addSeparator() {
    contents.append(nil)
    fireToolbarChanged()
  }

  /// Java `addSeparator(int)`.
  public func addSeparator(at position: Int) {
    contents.insert(nil, at: position)
    fireToolbarChanged()
  }

  /// Java `addTool(Tool)`.
  public func addTool(_ tool: Tool) {
    contents.append(tool)
    addAttributeListeners(tool)
    fireToolbarChanged()
  }

  /// Java `addTool(int, Tool)`.
  public func addTool(at position: Int, _ tool: Tool) {
    contents.insert(tool, at: position)
    addAttributeListeners(tool)
    fireToolbarChanged()
  }

  /// Java `move(int, int)`.
  @discardableResult
  public func move(from: Int, to: Int) -> Tool? {
    let moved = contents.remove(at: from)
    contents.insert(moved, at: to)
    fireToolbarChanged()
    return moved
  }

  /// Java `remove(int)`.
  @discardableResult
  public func remove(at position: Int) -> Tool? {
    let removed = contents.remove(at: position)
    if let removed { removeAttributeListeners(removed) }
    fireToolbarChanged()
    return removed
  }

  /// Java `copyFrom(ToolbarData, LogisimFile)`.
  ///
  /// D5/D13: `AttributeSets.copy` throws; an attribute the destination tool does not define,
  /// or one it has marked read-only, is reachable from a `.circ` whose `<toolbar>` names a
  /// tool whose library has changed shape. Java would raise `IllegalArgumentException` out of
  /// `setValue` and lose the file; here it surfaces as a file error.
  ///
  /// **Bug preserved:** upstream ends the loop body with `addAttributeListeners(toolCopy)`,
  /// the tool found in the *file's* library, although the tool actually placed on the toolbar
  /// is `dstTool`, which `addTool` has already subscribed. So every copy also attaches the
  /// toolbar's attribute listeners to the library's own tool, which is never on the toolbar.
  /// Reproduced rather than fixed: a listener that stopped receiving those events would be
  /// seeing behaviour no upstream build has ever produced.
  public func copyFrom(_ other: ToolbarData, file: LogisimFile) throws {
    if self === other { return }
    for tool in contents {
      guard let tool else { continue }
      removeAttributeListeners(tool)
    }
    contents.removeAll()
    for sourceTool in other.contents {
      guard let sourceTool else {
        addSeparator()
        continue
      }
      guard let toolCopy = file.findTool(sourceTool) else { continue }
      let destinationTool = toolCopy.cloneTool()
      // Java: `AttributeSets.copy(src, dst)`, which returns early for a null source and
      // would raise an NPE for a null destination. A `Tool` without an attribute set cannot
      // reach that NPE from any file, only `AddTool`s carry attributes and only `AddTool`s
      // are cloned into a toolbar, so the destination is guarded rather than crashed on.
      if let source = sourceTool.attributeSet, let destination = destinationTool.attributeSet {
        try AttributeSets.copy(from: source, to: destination)
      }
      addTool(destinationTool)
      addAttributeListeners(toolCopy)
    }
    fireToolbarChanged()
  }

  /// Java's package-private `replaceAll(Map<Tool, Tool>)`, called after a library reload.
  ///
  /// The map is keyed by `ObjectIdentifier` because D4 makes `Tool` identity reference
  /// identity; a `nil` value means the tool is gone from the reloaded library entirely, and
  /// the toolbar entry is deleted.
  func replaceAll(_ toolMap: [ObjectIdentifier: Tool?]) throws {
    var changed = false
    var index = 0
    while index < contents.count {
      guard let old = contents[index] else {
        index += 1
        continue
      }
      guard let replacement = toolMap[ObjectIdentifier(old)] else {
        index += 1
        continue
      }
      changed = true
      removeAttributeListeners(old)
      guard let newTool = replacement else {
        contents.remove(at: index)
        continue
      }
      let addedTool = newTool.cloneTool()
      addAttributeListeners(addedTool)
      if let destination = addedTool.attributeSet, let source = old.attributeSet {
        try LoadedLibrary.copyAttributes(to: destination, from: source)
      }
      contents[index] = addedTool
      index += 1
    }
    if changed { fireToolbarChanged() }
  }

  // MARK: - Queries

  /// Java `get(int)`.
  public func get(_ index: Int) -> Tool? { contents[index] }

  /// Java `getContents()`. Nulls are separators and are part of the contract.
  public var toolbarContents: [Tool?] { contents }

  /// Java `getFirstTool()`.
  public var firstTool: Tool? {
    for tool in contents where tool != nil { return tool }
    return nil
  }

  /// Java `size()`.
  public var count: Int { contents.count }

  /// Java's package-private `usesToolFromSource(Tool)`, consulted before a library is unloaded.
  func usesToolFromSource(_ query: Tool) -> Bool {
    for tool in contents {
      if let tool, tool.sharesSource(query) { return true }
    }
    return false
  }
}
