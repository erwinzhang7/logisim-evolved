// TextField.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.comp.{TextField, TextFieldEvent,
// TextFieldListener}), https://github.com/logisim-evolution/logisim-evolution. Copyright by the
// Logisim-evolution developers. This translation is a derivative work and is therefore
// GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── WHY THE `comp` PACKAGE SPLITS ACROSS TWO MODULES HERE, AND WHERE THE LINE IS ─────────────
//
// Upstream keeps four classes together in `com.cburch.logisim.comp`: `TextField`,
// `TextFieldCaret`, `TextFieldEvent` and `TextFieldListener`. Three of the four are pure model:
// a string, a position, an alignment, and a change notification. The fourth, `TextFieldCaret`,
// *draws*: a yellow edit box, a dark-grey border, a blue selection band, a blinking rule
// (`TextFieldCaret.java:80-113`), and it implements `com.cburch.logisim.tools.Caret`, which in
// this port is declared in `LogisimUI` because its whole vocabulary, `ToolMouseEvent`,
// `ToolKeyEvent`, `ToolOverlayItem`, `RenderScene`, is the tool layer's.
//
// D9 says a lower module must not acquire a UI dependency to keep a package together. So the
// split is: **the model half is here, the caret half is `LogisimUI/Tools/TextFieldCaret.swift`.**
// This file is `import`-clean of AppKit and SwiftUI; the only thing it needs beyond `LogisimFile`
// is `LogisimRender`'s `TextMeasurer`, which is a measurement protocol with no drawing surface
// behind it and which 113 files in this module already depend on.
//
// The one consequence worth stating: `TextField.getBounds(Graphics)` becomes
// `bounds(measurer:)`. Upstream reaches a live `Graphics` for its `FontMetrics`; there is no
// `Graphics` in this port at all (D6), so the metrics arrive as a parameter. Every caller has a
// measurer already; `LogisimUI` uses the same `CoreTextMeasurer` the canvas renders with, so
// the box a caret hit-tests against is the box the user sees.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

// MARK: - TextFieldEvent / TextFieldListener

/// `com.cburch.logisim.comp.TextFieldEvent`; a Java `record`.
///
/// Upstream's field names are `getTextField` / `getOldText` / `getText`, spelled that way to keep
/// bean-style call sites compiling after the class became a record; its own comment calls that
/// "silly". The Swift names are the ones the record actually means.
public struct TextFieldEvent {
  public let field: TextField
  public let oldText: String
  public let text: String

  public init(field: TextField, oldText: String, text: String) {
    self.field = field
    self.oldText = oldText
    self.text = text
  }
}

/// `com.cburch.logisim.comp.TextFieldListener`.
public protocol TextFieldListener: AnyObject {
  func textChanged(_ event: TextFieldEvent)
}

// MARK: - TextField

/// `com.cburch.logisim.comp.TextField`: a string with a place to sit and an alignment.
///
/// Not a view and not a control: it holds the text, the anchor point and the two alignments, and
/// it notifies when the text changes. Upstream's `draw(Graphics)` is not ported; D6 puts drawing
/// behind `RenderScene`, and the only thing that ever drew a `TextField` was
/// `InstanceTextField.draw`, whose job `InstancePainter.drawLabel()` already does from the
/// attribute set.
///
/// **D3: the listener list is weak, where Java's `LinkedList` is strong.** Upstream relies on the
/// GC to collect a `TextField` whose caret was abandoned; the two hold each other
/// (`TextFieldCaret` keeps `field`, `field.listeners` keeps the caret) and only `stopEditing` /
/// `cancelEditing` break the cycle. Under ARC that is a leak on every abandoned edit. Here the
/// caret owns the field and the field refers back weakly, so an abandoned edit collects when the
/// tool drops the caret. The invariant that makes this safe is stated once: **whoever registers a
/// listener must keep it alive**; `TextFieldCaret` holds its `InstanceTextField` strongly for
/// exactly this reason.
public final class TextField {

  private struct WeakListener {
    weak var listener: (any TextFieldListener)?
  }

  /// `getX()` / `getY()`.
  public private(set) var x: Int
  public private(set) var y: Int

  /// `getHAlign()` / `getVAlign()`. Upstream's `int` constants are `GraphicsUtil.H_*`/`V_*`,
  /// which are exactly `HAlign.rawValue` / `VAlign.rawValue` here.
  public private(set) var halign: HAlign
  public private(set) var valign: VAlign

  /// `getFont()` / `setFont(Font)`. `nil` is upstream's "use the graphics context's font".
  public var font: FontSpec?

  /// `getText()`. Written only through `setText`, so the notification cannot be skipped.
  public private(set) var text: String = ""

  private var listeners: [WeakListener] = []

  public init(x: Int, y: Int, halign: HAlign, valign: VAlign, font: FontSpec? = nil) {
    self.x = x
    self.y = y
    self.halign = halign
    self.valign = valign
    self.font = font
  }

  // MARK: Listeners

  /// `addTextFieldListener(TextFieldListener)`.
  public func addTextFieldListener(_ listener: any TextFieldListener) {
    listeners.append(WeakListener(listener: listener))
  }

  /// `removeTextFieldListener(TextFieldListener)`.
  public func removeTextFieldListener(_ listener: any TextFieldListener) {
    listeners.removeAll { $0.listener == nil || $0.listener === listener }
  }

  /// `fireTextChanged(TextFieldEvent)`. Upstream copies the list first
  /// (`new ArrayList<>(listeners)`) because a listener may unregister from inside the callback;
  /// `TextFieldCaret.textChanged` does not, but `InstanceTextField` writes an attribute, which
  /// can reach back here. The snapshot is kept for the same reason.
  public func fireTextChanged(_ event: TextFieldEvent) {
    for entry in listeners {
      entry.listener?.textChanged(event)
    }
  }

  // MARK: Modification

  /// `setText(String)`; fires only on a real change, which is what keeps `stopEditing` from
  /// writing an attribute the user did not touch.
  public func setText(_ value: String) {
    guard value != text else { return }
    let event = TextFieldEvent(field: self, oldText: text, text: value)
    text = value
    fireTextChanged(event)
  }

  /// `setLocation(int, int, int, int)`: the four-argument form, which is the one
  /// `InstanceTextField.updateField` calls.
  ///
  /// NOT PORTED: `setLocation(int, int)`, `setAlign(int, int)`, `setHorzAlign(int)`,
  /// `setVertAlign(int)`. All four are upstream's, all four have zero callers in 4.1.0 outside
  /// the four-argument form above, and an unreachable public setter on a mutable model object is
  /// exactly the surface a later reader wires something to by accident.
  public func setLocation(x: Int, y: Int, halign: HAlign, valign: VAlign) {
    self.x = x
    self.y = y
    self.halign = halign
    self.valign = valign
  }

  // MARK: Geometry

  /// The `SceneFont` this field's text is measured and drawn in.
  ///
  /// `nil` `font` means "whatever the context has"; there is no ambient context here, so the
  /// fallback is `StdAttr.DEFAULT_LABEL_FONT`, which is what every caller that leaves the font
  /// nil would have inherited from `InstanceTextField.createField`.
  public func sceneFont() -> SceneFont {
    InstancePainter.sceneFont(font ?? StdAttr.defaultLabelFont)
  }

  /// `TextField.getBounds(Graphics)` (`TextField.java:86-113`), transcribed including the
  /// integer divisions.
  ///
  /// **Note this is NOT `GraphicsUtil.getTextBounds`,** even though the alignment switch looks
  /// the same. `getTextBounds` uses `TextMetrics.height` (ascent + descent + **leading**) and
  /// offsets by it; this uses `ascent + descent` and anchors at `y - ascent`. The two differ by
  /// the leading, and `TextFieldCaret.getBounds` deliberately unions *both* before expanding by
  /// 3, so getting either wrong silently shrinks the region a click has to land in to keep an
  /// open caret alive.
  public func bounds(measurer: any TextMeasurer) -> Bounds {
    let font = sceneFont()
    let metrics = measurer.metrics(for: font)
    let width = text.isEmpty ? 0 : measurer.width(of: text, font: font)
    let ascent = metrics.ascent
    let descent = metrics.descent

    var bx = x
    var by = y
    switch halign {
    case .center: bx -= width / 2
    case .right: bx -= width
    case .left: break
    }
    switch valign {
    case .top: by += ascent
    case .center: by += ascent / 2
    case .centerOverall: by += (ascent - descent) / 2
    case .bottom: by -= descent
    case .baseline: break
    }
    return Bounds.create(bx, by - ascent, width, ascent + descent)
  }
}
