// A same-package shim so the oracle can drive 4.1.0's REAL attribute-table model, and reach the
// one non-widget effect of `Frame.setAttrTableModel`.
//
// `AttrTableComponentModel` and its constructor are package-private in
// `com.cburch.logisim.gui.main`. Its `setValueRequested` is the whole editor path for "change an
// attribute of the selected component": it builds a `SetAttributeAction`, folds in every attribute
// that `attributesMayAlsoBeChanged` reports (recorded at its CURRENT value, so undo restores it),
// and pushes the action through `Project.doAction`.
//
// Re-implementing those twelve lines in the harness was the alternative and was rejected: the
// `attributesMayAlsoBeChanged` fold is invisible in the saved file but visible after an `undo`,
// and a harness that quietly dropped it would make the Swift side look wrong for doing the right
// thing. Ten lines of shim buys the real class.
//
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
package com.cburch.logisim.gui.main;

import com.cburch.logisim.circuit.Circuit;
import com.cburch.logisim.comp.Component;
import com.cburch.logisim.data.Attribute;
import com.cburch.logisim.proj.Project;

public final class EditBridgeAttrTable {

  private EditBridgeAttrTable() {}

  public static void setValue(
      Project project, Circuit circuit, Component component,
      Attribute<Object> attribute, Object value) throws Exception {
    new AttrTableComponentModel(project, circuit, component).setValueRequested(attribute, value);
  }

  /**
   * `Canvas.setHaloedComponent(Circuit, Component)` (`Canvas.java:730-732`), which is
   * package-private.
   *
   * <p>The real `Frame.setAttrTableModel` does three things and two of them are Swing widgets that
   * cannot exist headlessly (`EditBridge.HeadlessFrame.viewComponentAttributes` argues that
   * line by line). This is the third: a field on the canvas's `CanvasPainter`, and the only one
   * with an effect that outlives the call: `Canvas.MyListener.circuitChanged` branches on it
   * (`Canvas.java:1106`, `:1111`). Without this hop the oracle would take the not-haloed branch
   * where the GUI takes the haloed one.
   */
  public static void setHaloedComponent(Canvas canvas, Circuit circuit, Component component) {
    canvas.setHaloedComponent(circuit, component);
  }
}
