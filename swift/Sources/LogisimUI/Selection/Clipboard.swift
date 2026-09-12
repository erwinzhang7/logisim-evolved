// Clipboard.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.gui.main.Clipboard),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// ── What is on the clipboard ────────────────────────────────────────────────────────────────
//
// Not a serialised blob and not the selected components; **fresh components built from cloned
// attribute sets**, at the same locations. Copying is `factory.createComponent(loc,
// attrs.clone())` per component, which is precisely the same construction path `XmlCircuitReader`
// takes when it loads a `<comp>`: same factory, same attribute values, same location. That is
// what "round-trips through the same serialisation the file format uses" means in practice here;
// there is no second code path that could drift from the loader's.
//
// The consequence worth stating plainly: because the attributes are cloned at *copy* time, later
// edits to the original do not follow the clipboard, and pasting twice yields two independent
// components. The one exception is RAM/ROM, whose attribute sets are shared rather than cloned by
// `SelectionBase.copyComponents`, but that is the *paste* path, not this one; the copy taken
// here always clones. Upstream is asymmetric in exactly that way and it is reproduced.
//
// ── Scope: this is the layout clipboard ─────────────────────────────────────────────────────
//
// Upstream has three unrelated things called `Clipboard`: this one (`gui.main`, circuit
// components), `gui.appear.Clipboard` (appearance-editor shapes), and the AWT system clipboard
// used by the hex editor and text fields. Only this one is in scope; the name is kept because
// every reference in `SelectionActions` and `LayoutEditHandler` uses it unqualified.
//
// ── A macOS note, deliberately not acted on ─────────────────────────────────────────────────
//
// This is a private in-process clipboard: it does not touch `NSPasteboard`, so components cannot
// be pasted between two running copies of the app. That is upstream's behaviour, and changing it
// is a real feature (it needs a pasteboard type, a serialisation, and a library-resolution story
// for the receiving process) rather than a porting detail, so it is left alone here and left
// visible rather than quietly half-implemented.

import Foundation
import LogisimFile
import LogisimKernel

/// Notified when the clipboard's contents change. Upstream uses `PropertyChangeWeakSupport` with
/// a `"contents"` property name; there is exactly one property, so the name does not come across.
///
/// D3: held weakly, like every other listener list in the port.
@MainActor
public protocol ClipboardListener: AnyObject {
  func clipboardContentsChanged()
}

/// `com.cburch.logisim.gui.main.Clipboard`.
@MainActor
public final class Clipboard {

  /// `components`: the copies, not the originals.
  public let components: [any Component]

  /// `oldAttrs`; the attribute set the attribute table was showing when the copy was taken,
  /// if it belonged to one of the copied components.
  public private(set) var oldAttributeSet: (any AttributeSet)?

  /// `newAttrs`: the clone that replaced it in the copy.
  public private(set) var newAttributeSet: (any AttributeSet)?

  /// `Clipboard(Selection, AttributeSet)`.
  ///
  /// D13: `throws`, because `createComponent` does. A component whose attribute set cannot
  /// produce a component is reachable from a malformed file that loaded far enough to be
  /// selected, and upstream's copy would throw an unchecked exception the frame reports.
  ///
  /// Upstream's comment on this constructor is worth keeping: *"Now the tunnels' labels are not
  /// cleared except if it is requested to."* Earlier versions blanked tunnel labels on copy,
  /// which broke the one component whose label is its network identity. Nothing here clears any
  /// label, and that absence is the behaviour.
  public init(copying selection: Selection, viewing viewAttributes: (any AttributeSet)?) throws {
    var copies: [any Component] = []
    var oldAttrs: (any AttributeSet)?
    var newAttrs: (any AttributeSet)?

    for base in selection.components {
      let baseAttrs = base.attributeSet
      let copyAttrs = baseAttrs.copy()

      let copy = try base.factory.createComponent(
        location: base.location, attributes: copyAttrs)
      copies.append(copy)
      // Reference identity, exactly as upstream's `==` on attribute sets is: D4 forbids
      // structural equality on `AttributeSet` for this reason.
      if baseAttrs === viewAttributes {
        oldAttrs = baseAttrs
        newAttrs = copyAttrs
      }
    }

    self.components = copies
    self.oldAttributeSet = oldAttrs
    self.newAttributeSet = newAttrs
  }

  /// `setOldAttributeSet(AttributeSet)`.
  func setOldAttributeSet(_ value: (any AttributeSet)?) {
    oldAttributeSet = value
  }

  // MARK: - The static half

  /// `current`.
  ///
  /// A process-global mutable slot is what upstream has and what the undo actions need: `Copy`
  /// and `Cut` stash the *previous* clipboard so undo can put it back, which only makes sense
  /// against a single shared slot. `@MainActor` isolation is what makes that safe here.
  private static var current: Clipboard?

  private static let listeners = WeakClipboardListenerList()

  /// `Clipboard.get()`.
  public static func get() -> Clipboard? { current }

  /// `Clipboard.isEmpty()`: null *or* empty, which is why paste is disabled after a copy of
  /// nothing rather than pasting nothing.
  public static var isEmpty: Bool { current?.components.isEmpty ?? true }

  /// `Clipboard.set(Clipboard)`. Fires even when the value is unchanged, as upstream's
  /// `firePropertyChange` does.
  public static func set(_ value: Clipboard?) {
    current = value
    for listener in listeners.current() { listener.clipboardContentsChanged() }
  }

  /// `Clipboard.set(Selection, AttributeSet)`.
  public static func set(
    copying selection: Selection, viewing viewAttributes: (any AttributeSet)?
  ) throws {
    set(try Clipboard(copying: selection, viewing: viewAttributes))
  }

  /// `addPropertyChangeListener` / `removePropertyChangeListener`.
  public static func addListener(_ listener: any ClipboardListener) { listeners.add(listener) }
  public static func removeListener(_ listener: any ClipboardListener) {
    listeners.remove(listener)
  }

  /// Drops the clipboard and its listeners. No upstream counterpart, upstream's statics live as
  /// long as the JVM, but a process-global that a test cannot reset makes every clipboard test
  /// order-dependent, which is the class of flakiness this port cannot afford in a byte-exact
  /// gate.
  static func resetForTesting() {
    current = nil
    listeners.removeAll()
  }
}

/// D3: the clipboard outlives every window, so a strong listener list here would pin a closed
/// frame forever. Held weakly, caller owns the listener.
@MainActor
final class WeakClipboardListenerList {
  private final class Box {
    weak var value: AnyObject?
    init(_ value: AnyObject) { self.value = value }
  }

  private var boxes: [Box] = []

  func add(_ listener: any ClipboardListener) {
    purge()
    let object = listener as AnyObject
    guard !boxes.contains(where: { $0.value === object }) else { return }
    boxes.append(Box(object))
  }

  func remove(_ listener: any ClipboardListener) {
    let object = listener as AnyObject
    boxes.removeAll { $0.value == nil || $0.value === object }
  }

  func removeAll() { boxes.removeAll() }

  func current() -> [any ClipboardListener] {
    purge()
    return boxes.compactMap { $0.value as? any ClipboardListener }
  }

  private func purge() {
    boxes.removeAll { $0.value == nil }
  }
}
