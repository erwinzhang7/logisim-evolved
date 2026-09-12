// UndoAction.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// com/cburch/draw/undo/UndoAction.java. Copyright by the Logisim-evolution developers. This
// translation is a derivative work and is therefore licensed GPL-3.0-only. See LICENSE.md.
//
// The full `draw/actions/*` package (`ModelAddAction`, `ModelMoveHandleAction`, etc.; the
// concrete `UndoAction`s a canvas tool constructs) is not ported here: those classes exist to
// be driven by `draw/canvas`/`draw/tools` (Swing, explicitly out of scope: M6/M7), and every
// one of them is a thin adapter over the `CanvasModel` mutating methods this module already
// exposes (`addObjects`, `translateObjects`, `setAttributeValues`, …). The framework itself,
// this one three-method interface, is genuinely self-contained and is ported in full, per the
// task.

/// `com.cburch.draw.undo.UndoAction`.
public protocol UndoAction: AnyObject {
  func doIt()
  var name: String { get }
  func undo()
}
