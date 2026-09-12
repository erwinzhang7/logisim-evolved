// EditBridge; the ORACLE for M7's edit-parity gate.
//
// Applies a scripted sequence of editing gestures to a .circ file using logisim-evolution 4.1.0's
// own tools, actions and writer, and saves the result. The Swift port applies the same script
// through its own editor and the two files are compared byte for byte
// (`tools/difftest/editparity.py`, `swift/Tests/LogisimUITests/EditParityTests.swift`).
//
// ── WHY THIS SHAPE ──────────────────────────────────────────────────────────────────────────
//
// Every other gate in this project drives the jar's own model from a small harness rather than
// re-deriving what the jar "should" produce: `CircBridge` for the codec, `ValueBridge`/`BusBridge`
// for M1, `RomBridge` for memory. This is the same idea for editing, and it has one extra
// constraint the others do not: **the point is to reproduce what the GUI would write**, so the
// harness has to go through `Tool.mousePressed`/`mouseReleased` and `Project.doAction`, not
// through `Circuit.add`. A harness that pokes the model would agree with a Swift port that also
// poked the model, and both could be wrong about editing in exactly the same way.
//
// ── DRIVING THE REAL TOOLS HEADLESSLY: WHAT IT COST ─────────────────────────────────────────
//
// Five obstacles, each solved as narrowly as possible, and each one stated because it is a place
// where the oracle is not literally the shipping code path. **The invariant across all five is
// that every byte of logisim bytecode this runs is 4.1.0's own**: nothing here compiles a patched
// copy of a logisim class ahead of the jar. What is fabricated is a `Frame` and a `Canvas`
// subclass whose overridden methods answer with the real objects the GUI would have answered with:
//
//  1. `Canvas` is a `JPanel`, not a `Window`, so it constructs fine under `-Djava.awt.headless=1`.
//     `Canvas.MyListener` is NOT usable, `mouseDragged` reaches `proj.getFrame().getZoomModel()`
//     and `mousePressed` reaches the viewport's zoom button, so this harness dispatches to the
//     tool directly, which is the same three calls `MyListener` makes (`Canvas.java:791-899`),
//     minus the zoom/scroll bookkeeping that cannot exist without a frame. Zoom is 1.0 whenever
//     `canvasPane == null` (`Canvas.getZoomFactor`), so event coordinates ARE circuit
//     coordinates here, exactly as they are in the GUI at 100 %.
//
//  2. `Project.getSelection()` is `frame.getCanvas().getSelection()` and returns null with no
//     frame; `SelectTool` would then NPE on its first line. `HeadlessProject` below overrides
//     that ONE accessor to return the canvas's own selection, which is precisely what the real
//     implementation returns. Nothing else about `Project` is replaced: `doAction`, the undo and
//     redo logs, `CircuitTransaction` and the whole action layer are the jar's.
//
//  3. `AddTool.mouseReleased` ends with `proj.setTool(determineNext(proj))`, and `setTool` also
//     dereferences the frame. `determineNext` returns null when `AppPreferences.ADD_AFTER` is
//     `unchanged`, so the harness pins that preference: see `MemoryPreferences` for how, and
//     note the consequence for the script language: **after `add`, nothing is selected.** A
//     script that wants to move what it just placed must select it first. The Swift side pins the
//     matching `AddTool.switchesToEditToolAfterAdding = false`. This is the one deliberate
//     configuration difference from the shipping default, and it is symmetric.
//
//  4. `Canvas.getGraphics()` RETURNS NULL, AND THE TEXT TOOL DOES NOT USE THE ONE IT IS HANDED.
//     Every `Tool.mousePressed`/`mouseReleased` here is given the bridge's real `Graphics` (see
//     `graphics` below), but `TextTool.mousePressed` builds a `ComponentUserEvent(canvas, x, y)`
//     and `InstanceTextField.getTextCaret` then takes its metrics from
//     `event.getCanvas().getGraphics()` (`InstanceTextField.java:101-102`): the canvas, not the
//     argument. A `JPanel` that was never added to a displayable window answers null there, and
//     `field.getBounds(null)` dies in `Graphics.getFontMetrics`. Measured, before the fix:
//
//         tool add:Register / toolattr label A / click 200 200        -> OK
//         ... + tool text / click 230 192
//             -> FAIL NullPointerException: Cannot invoke
//                "java.awt.Graphics.getFontMetrics(java.awt.Font)" because "g" is null
//
//     `HeadlessCanvas` below overrides `getGraphics()` to hand back a `create()` of the same
//     `BufferedImage` context every other tool call already gets. A fresh child context per call,
//     not the shared one, because that is `java.awt.Component.getGraphics()`'s contract; callers
//     are entitled to `dispose()` what they are given, and `TextFieldCaret` keeps its copy for the
//     lifetime of the edit. The alternative, making the canvas displayable, is not available:
//     `java.awt.Window`'s constructor calls `GraphicsEnvironment.checkHeadless()`.
//
//  5. THE FABRICATED `Frame` HAS A NULL `attrTable`, AND THE TEXT TOOL CALLS INTO IT.
//     `TextTool.mousePressed` calls `proj.getFrame().viewComponentAttributes(circ, comp)` on all
//     three of its arms (`TextTool.java:272`, `:287`, `:305`), and `HeadlessFrame` is built by
//     `Unsafe.allocateInstance`, so every inherited field, `attrTable` among them, is null.
//     Measured, before the fix, with the click on EMPTY canvas so that obstacle 4 cannot be what
//     fires:
//
//         tool add:Register / click 200 200 / tool text / click 900 900
//             -> FAIL NullPointerException: Cannot invoke
//                "AttrTable.setAttrTableModel(AttrTableModel)" because "this.attrTable" is null
//
//     `HeadlessFrame` overrides it, keeping the one effect that is not a Swing widget; the method
//     itself argues line by line what is kept and what is dropped. **Only this one method needs
//     it.** A later upstream adds `TextTool.refreshEditMenu` ->
//     `frame.computeEditMenuEnabled()` on every mouse and key event, which would be a second
//     null-field crash; 4.1.0's `TextTool` has no such call and 4.1.0's `Frame` has no such
//     method (`javap` on the jar confirms both). Recorded because the checked-out `src/` tree in
//     this repository is upstream master, not the port target: reading `TextTool.java` from it
//     produces an override that does not compile, which is how this was caught.
//
// Declared IN `com.cburch.logisim.file` for the same reason `CircBridge` is: 4.1.0's
// `LogisimFile.write` overloads are all package-private (D17).
//
// ── PROTOCOL ────────────────────────────────────────────────────────────────────────────────
//
// One request per stdin line, one reply per request, so a whole gate run costs one JVM:
//
//   PING                                     -> PONG
//   <script>\t<seed>\t<out>                  -> OK\t<script>   |   FAIL\t<script>\t<why>
//
// ── SCRIPT LANGUAGE ─────────────────────────────────────────────────────────────────────────
//
// Tab-separated, one operation per line; `#` comments and blank lines ignored. Tabs rather than
// spaces because factory names contain spaces ("AND Gate", "D Flip-Flop") and a quoting rule
// would be a parser on both sides.
//
//   tool     <spec>                 select|wiring|edit|poke|text|menu, or  add:<Factory Name>
//   toolattr <attr> <value>         set an attribute on the CURRENT tool's own attribute set,
//                                   i.e. what the palette's attribute table edits before a place
//   click    <x> <y>                press then release at (x,y) with the current tool
//   drag     <x0> <y0> <x1> <y1>    press at (x0,y0), drag to (x1,y1), release there
//   key      delete|backspace|return   a key press delivered to the current tool
//   type     <text>                 the characters of <text>, typed one at a time
//   setattr  <x> <y> <attr> <value> attribute-table edit on the component ANCHORED at (x,y)
//   undo
//   redo
//
// `type` and `key return` are what make the Text Tool driveable, and their shapes are AWT's, not
// conveniences. A real keystroke on a character is TWO events, `keyPressed` with a `VK_` code and
// no char, then `keyTyped` with the char and `VK_UNDEFINED`, and `TextFieldCaret` reads the first
// for navigation and editing keys and the second for insertion, so a `type` that skipped
// `keyPressed` would be driving half the class. `key return` sends only `keyPressed`
// (`VK_ENTER` -> `normalKeyPressed` -> `stopEditing`, `TextFieldCaret.java:273-280`): AWT would
// also deliver a `'\n'` `keyTyped`, but by then `TextTool.caret` is null and it is a no-op, and
// the Swift side's `canvasHandleKey` suppresses the newline replay for exactly that reason. The
// two drivers therefore deliver the same events in the same order.
//
// **`type` does not reposition the caret and no operation exists to.** Where the caret lands on a
// click is `GraphicsUtil.getTextPosition(g, ...)`, i.e. a function of font metrics, and AWT's and
// CoreText's do not have to agree to the character. A script that typed straight into a clicked
// caret would be gating the two platforms' text measurement rather than the editor. Clear the
// field first, `key backspace` x n then `key delete` x n leaves the field empty with the caret at
// 0 from ANY starting position, and the rest of the script is metric-independent. What the click
// still gates, and this is the point of it, is whether the label's box is where 4.1.0 puts it: a
// miss does not silently type in the wrong place, it falls through `TextTool`'s third arm and
// creates a free-standing `Text` annotation, which is a whole extra `<comp>` in the saved file.
//
// Components are addressed by their anchor `Location`, which is stable, unambiguous and written
// into the file, so the same line means the same thing on both sides.
//
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
package com.cburch.logisim.file;

import com.cburch.logisim.circuit.Circuit;
import com.cburch.logisim.comp.Component;
import com.cburch.logisim.data.Attribute;
import com.cburch.logisim.data.AttributeSet;
import com.cburch.logisim.gui.main.Canvas;
import com.cburch.logisim.gui.main.EditBridgeAttrTable;
import com.cburch.logisim.gui.main.Frame;
import com.cburch.logisim.gui.main.Selection;
import com.cburch.logisim.proj.Project;
import com.cburch.logisim.tools.AddTool;
import com.cburch.logisim.tools.Library;
import com.cburch.logisim.tools.Tool;
import java.awt.Graphics;
import java.awt.event.KeyEvent;
import java.awt.event.MouseEvent;
import java.awt.image.BufferedImage;
import java.io.BufferedReader;
import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.io.PrintStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.List;

public final class EditBridge {

  // ── The headless Project ──────────────────────────────────────────────────────────────────

  /**
   * `Project` with its two frame-dereferencing accessors answered from a canvas instead.
   *
   * <p>`getSelection()` returns exactly what the real one returns, `frame.getCanvas()
   * .getSelection()`, with the frame hop removed. `getFrame()` already returns null in the base
   * class when unset, and every caller of it on the editing paths used here is an `OptionPane`
   * parent, which `Main.headless` turns into a log line.
   */
  static final class HeadlessProject extends Project {
    private Canvas canvas;
    private Frame frame;

    HeadlessProject(LogisimFile file) {
      super(file);
    }

    void attach(Canvas value) {
      canvas = value;
      frame = HeadlessFrame.of(value);
    }

    @Override
    public Selection getSelection() {
      return canvas == null ? null : canvas.getSelection();
    }

    @Override
    public Frame getFrame() {
      return frame;
    }
  }

  /**
   * A `Frame` that answers `getCanvas()` and nothing else.
   *
   * <p>**Why a frame is needed at all, having gone to such lengths to avoid one.**
   * `SelectTool.setState`, a *private* method, called on every state transition of the
   * select/move gesture, is `proj.getFrame().getCanvas().setCursor(getCursor())`
   * (`SelectTool.java:632-637`). There is no override point: it is private, it is on the path of
   * every press and release, and it runs before any of the interesting work. So `SelectTool`, and
   * therefore `EditTool`, cannot be driven at all without `getFrame()` returning something.
   *
   * <p>**Why this and not a one-line patch to `SelectTool`.** The alternative was to compile a
   * copy of 4.1.0's `SelectTool` with that line neutered and put it ahead of the jar on the
   * classpath. That would make the oracle a *modified* logisim, and every subsequent divergence
   * would carry an asterisk. This way every byte of logisim bytecode that runs is 4.1.0's own;
   * the only fabricated thing is a frame whose single reachable method returns the real canvas.
   *
   * <p>**Why `allocateInstance`.** `Frame extends LFrame.MainWindow extends JFrame`, and
   * `java.awt.Frame`'s constructor calls `GraphicsEnvironment.checkHeadless()`, so no constructor
   * can run under `-Djava.awt.headless=true`. `Unsafe.allocateInstance` produces the object
   * without running one. Every inherited field is therefore null/zero, which is exactly why the
   * class overrides the one method that gets called and why the audit below matters.
   *
   * <p>**AUDIT OF WHAT ELSE COULD BE CALLED ON IT: re-derived for the Text Tool, 2026-09-06.**
   * The previous version of this audit listed four dereferences and concluded that
   * `viewComponentAttributes` was never reached. That was true of the ten scripts that predated
   * the Text Tool and is FALSE now; a stale audit is worse than none, because the next reader
   * trusts it. What follows covers every tool the script language can select, `add:*`, `wiring`,
   * `edit`, `poke`, `text`, `menu`, on the press/drag/release/key paths this bridge dispatches.
   *
   * <p>**Read against `~/Developer/logisim/upstream-java-4.1.0`, not this repository's `src/`.**
   * That distinction cost a compile error and is worth the sentence: the checked-out `src/` tree
   * here is upstream master, where `TextTool` gained a `refreshEditMenu` that calls
   * `Frame.computeEditMenuEnabled()` on every mouse and key event. Audited from that tree, this
   * list has a fifth entry and `HeadlessFrame` needs a second override, which does not compile,
   * because 4.1.0's `Frame` has no such method. D16 names the reference tree; obeying it is what
   * makes the count below five rather than six.
   *
   * <p>`proj.getFrame()` is dereferenced in exactly five places on those paths:
   *
   * <ol>
   *   <li>`SelectTool.setState` -> `getCanvas().setCursor(...)` (`SelectTool.java:632-637`).
   *       `getCanvas()` is overridden below and returns the real canvas; `setCursor` on an
   *       undisplayed JPanel is a field write.
   *   <li>`TextTool.mousePressed` -> `viewComponentAttributes(circ, comp)`, on all three arms
   *       (`TextTool.java:272`, `:287`, `:305`). **Reached by every `tool text` + `click`.**
   *       Overridden below.
   *   <li>`Canvas.MyListener.circuitChanged`, ACTION_REMOVE and ACTION_CLEAR arms
   *       (`Canvas.java:995-1001`), guarded by `painter.getHaloedComponent()`. **This entry is why
   *       the old audit's conclusion was safe and is no longer:** the guard was dead because
   *       nothing set the halo, and `viewComponentAttributes` below now does, as the real `Frame`
   *       does. It calls `viewComponentAttributes(null, null)`, which the override handles by
   *       clearing the halo; the same thing the GUI does when a haloed component is deleted.
   *   <li>`Canvas.MyListener.projectChanged`, ACTION_SET_CURRENT arm (`Canvas.java:1067-1069`),
   *       same guard. Unreachable for a different reason: nothing here changes the current
   *       circuit, and the script language has no operation that could.
   *   <li>`Canvas.MyListener.mouseDragged`/`mousePressed` (`Canvas.java:688`, `:794`) reach
   *       `getZoomControl()`/`getZoomModel()`. Unreachable: this bridge dispatches to the tool
   *       directly and never installs a real AWT event on the canvas. See the header.
   * </ol>
   *
   * <p>Two more that a grep finds and that the script language cannot reach:
   * `SelectionActions:518` is inside `Paste`, and `Canvas.java:489`
   * (`getRegTabContent().writeValuesToLabels()`) is on the simulation-tick path.
   *
   * <p>**What this audit now covers, stated so the next reader knows its edges:** the nine
   * operations `tool`, `toolattr`, `click`, `drag`, `key`, `type`, `setattr`, `undo` and `redo`,
   * over the five selectable base tools plus `add:*`. It does NOT cover clipboard operations, circuit
   * switching, simulation ticks or the appearance editor; none of which the script language can
   * express. Adding an operation for any of them means re-deriving this list.
   */
  public static class HeadlessFrame extends Frame {
    private static final long serialVersionUID = 1L;
    private static final java.util.Map<HeadlessFrame, Canvas> CANVASES =
        new java.util.IdentityHashMap<>();

    /** Never executed; `allocateInstance` skips it. Present only so this compiles. */
    private HeadlessFrame() {
      super(null);
    }

    @Override
    public Canvas getCanvas() {
      synchronized (CANVASES) {
        return CANVASES.get(this);
      }
    }

    /**
     * `Frame.viewComponentAttributes(Circuit, Component)` (`Frame.java:663-669`), minus the two
     * things that are Swing widgets and cannot exist here.
     *
     * <p>The real body is `setAttrTableModel(comp == null ? null : new AttrTableComponentModel(
     * project, circ, comp))`, and `setAttrTableModel` (`Frame.java:587-604`) does exactly three
     * things: `attrTable.setAttrTableModel(value)`; `toolbox`/`layoutToolbarModel.setHaloedTool`;
     * and `layoutCanvas.setHaloedComponent(circ, comp)`. The first two are a `JTable` and two
     * toolbar models: nothing but presentation, and null here, which is what the measured NPE in
     * obstacle 5 was. The third is a field on the canvas's `CanvasPainter` and is the ONE effect
     * that outlives the call, so it is the one this reproduces, against the real canvas.
     *
     * <p>**Constructing the `AttrTableComponentModel` is deliberately dropped, and that was
     * checked rather than assumed.** Its constructor (`AttrTableComponentModel.java:28-34`) only
     * fills a row list; the attribute listener is registered in
     * `AttributeSetTableModel.addAttrTableModelListener` (`:69-74`), which only the real
     * `AttrTable` calls. So building one and throwing it away is observably identical to not
     * building it, and skipping it keeps this override honest about what it does.
     *
     * <p>Reproducing the halo is not cosmetic bookkeeping: it is what makes audit entry 4 above
     * live, so the oracle takes the same branch through `Canvas.MyListener.circuitChanged` that
     * the GUI does when a haloed component is deleted.
     */
    @Override
    public void viewComponentAttributes(
        com.cburch.logisim.circuit.Circuit circ, Component comp) {
      final var canvas = getCanvas();
      if (canvas == null) return;
      // Package-private on Canvas, so it goes through the same-package shim.
      EditBridgeAttrTable.setHaloedComponent(canvas, comp == null ? null : circ, comp);
    }

    static Frame of(Canvas canvas) {
      try {
        final var field = Class.forName("sun.misc.Unsafe").getDeclaredField("theUnsafe");
        field.setAccessible(true);
        final var unsafe = (sun.misc.Unsafe) field.get(null);
        final var frame = (HeadlessFrame) unsafe.allocateInstance(HeadlessFrame.class);
        synchronized (CANVASES) {
          CANVASES.put(frame, canvas);
        }
        return frame;
      } catch (Exception e) {
        // REFUSE rather than degrade. A null frame here does not disable the move gesture, it
        // makes it throw halfway through `setState` with the tool's state already advanced, which
        // would look like a port divergence and be a harness bug.
        throw new IllegalStateException("cannot fabricate a headless Frame: " + e, e);
      }
    }
  }

  /**
   * The real `Canvas`, with `getGraphics()` answered from a `BufferedImage` instead of from a peer
   * that headlessness forbids. See the header, obstacle 4.
   *
   * <p>**Why a subclass and not a patched `Canvas`.** Same reason as `HeadlessFrame`: every byte
   * of logisim bytecode stays 4.1.0's. `Canvas` is a public non-final `JPanel` subclass with a
   * public `Canvas(Project)` constructor, so this needs no reflection at all: one override of a
   * method `java.awt.Component` already declares public.
   *
   * <p>**Why `create()` and not the context itself.** `java.awt.Component.getGraphics()` returns a
   * fresh `Graphics` on every call and the caller owns it; `Graphics.dispose()` on a shared
   * context would poison every later call. `TextFieldCaret` holds the one it is given for the
   * whole edit (`TextFieldCaret.java:36`, `:44`), and `InstanceTextField.draw` disposes the copy
   * it makes, so both behaviours have to work.
   *
   * <p>**What this changes elsewhere, because it is not only the Text Tool that asks.** `Canvas`
   * calls `getGraphics()` in five other places (`:242`, `:283`, `:570`, `:592`), all of
   * them the `(g != null) ? circuit.getBounds(g) : circuit.getBounds()` pattern inside
   * `center`/`computeSize`/`recomputeSize`. Those now take the measured branch, which is what the
   * GUI takes. The result feeds `setPreferredSize` and the scroll bars and touches no model state
   * , but "cannot affect the file" is an argument, and this project's rule is to measure: all
   * thirteen pre-existing baselines were regenerated with this change in place and are
   * byte-identical to the ones committed before it.
   */
  public static final class HeadlessCanvas extends Canvas {
    private static final long serialVersionUID = 1L;
    private final Graphics context;

    HeadlessCanvas(Project proj, Graphics context) {
      super(proj);
      this.context = context;
    }

    @Override
    public Graphics getGraphics() {
      return context == null ? null : context.create();
    }
  }

  // ── One scripted session ──────────────────────────────────────────────────────────────────

  private final Loader loader;
  private final LogisimFile file;
  private final HeadlessProject project;
  private final Canvas canvas;
  private final Graphics graphics;
  private Tool tool;

  private EditBridge(File seed) throws Exception {
    loader = new Loader(null);
    file = loader.openLogisimFile(seed);
    if (file == null) throw new IllegalStateException("seed did not load: " + seed);
    project = new HeadlessProject(file);
    // `ProjectActions.updatecircs(LogisimFile, Project)` (`ProjectActions.java:247-256`), which
    // `doOpen` runs on every opened file and which is `private static`, so it is copied rather
    // than called. It is not optional: `Circuit.mutatorRemove` and `mutatorClear` call
    // `proj.getCircuitState(this)` on the circuit's OWN `proj` field, which the loader leaves
    // null. Without this, every delete in 4.1.0 NPEs: verified, that is exactly what happened.
    updateCircuitProjects(file, project);
    // A real Graphics, not null. `Component.getBounds(Graphics)` measures label text through it,
    // and the placement path checks `bds.getX() < 0` before committing, so handing the tools a
    // null Graphics would change which placements are refused. Built BEFORE the canvas because
    // the canvas hands it back from `getGraphics()`, see `HeadlessCanvas` and obstacle 4.
    graphics = new BufferedImage(64, 64, BufferedImage.TYPE_INT_ARGB).createGraphics();
    canvas = new HeadlessCanvas(project, graphics);
    project.attach(canvas);
    tool = findTool("edit");
  }

  private Circuit circuit() {
    return project.getCurrentCircuit();
  }

  /** Verbatim `ProjectActions.updatecircs`, which is private static. */
  private static void updateCircuitProjects(LogisimFile lib, Project proj) {
    for (final var circ : lib.getCircuits()) {
      circ.setProject(proj);
    }
    for (final var sub : lib.getLibraries()) {
      if (sub instanceof LoadedLibrary loaded && loaded.getBase() instanceof LogisimFile nested) {
        updateCircuitProjects(nested, proj);
      }
    }
  }

  // ── Tool lookup ───────────────────────────────────────────────────────────────────────────

  // `select` is deliberately absent. `SelectTool` is NOT a tool anyone can pick: `BaseLibrary`
  // exposes Poke, Edit, Wiring, Text and Menu, and keeps its `SelectTool` private inside the
  // `EditTool` it hands out (`std/base/BaseLibrary.java:37-51`). The user-facing gesture for
  // "select something and drag it" is the **Edit Tool**, which routes each press to its select or
  // wiring half from what is under the cursor. Offering a `select` spec would let a script drive
  // a tool the GUI cannot reach, which is the opposite of what this gate is for.
  private static final String[][] BASE_TOOLS = {
    {"wiring", "Wiring Tool"},
    {"edit", "Edit Tool"},
    {"poke", "Poke Tool"},
    {"text", "Text Tool"},
    {"menu", "Menu Tool"},
  };

  private Tool findTool(String spec) {
    if (spec.startsWith("add:")) {
      final var wanted = spec.substring(4);
      final var found = findAddTool(file, wanted);
      if (found == null) throw new IllegalArgumentException("no AddTool for factory " + wanted);
      return found;
    }
    for (final var pair : BASE_TOOLS) {
      if (pair[0].equals(spec)) {
        final var found = findNamedTool(file, pair[1]);
        if (found == null) throw new IllegalArgumentException("no tool named " + pair[1]);
        return found;
      }
    }
    throw new IllegalArgumentException("unknown tool spec " + spec);
  }

  /** Depth-first over the library tree, so the tool is the library's OWN shared instance. */
  private static Tool findNamedTool(Library lib, String name) {
    for (final var t : lib.getTools()) {
      if (name.equals(t.getName())) return t;
    }
    for (final var sub : lib.getLibraries()) {
      final var found = findNamedTool(sub, name);
      if (found != null) return found;
    }
    return null;
  }

  private static AddTool findAddTool(Library lib, String factoryName) {
    for (final var t : lib.getTools()) {
      if (t instanceof AddTool add) {
        final var f = add.getFactory();
        if (f != null && factoryName.equals(f.getName())) return add;
      }
    }
    for (final var sub : lib.getLibraries()) {
      final var found = findAddTool(sub, factoryName);
      if (found != null) return found;
    }
    return null;
  }

  // ── Gestures ──────────────────────────────────────────────────────────────────────────────
  //
  // `Canvas.MyListener` minus the frame-bound bookkeeping: press, (drag), release, on the one
  // tool that took the press, which is what `dragTool` is (`Canvas.java:843-890`).

  private MouseEvent mouse(int id, int x, int y) {
    return new MouseEvent(
        canvas, id, System.currentTimeMillis(), 0, x, y, 1, false, MouseEvent.BUTTON1);
  }

  private void click(int x, int y) {
    tool.mousePressed(canvas, graphics, mouse(MouseEvent.MOUSE_PRESSED, x, y));
    tool.mouseReleased(canvas, graphics, mouse(MouseEvent.MOUSE_RELEASED, x, y));
  }

  private void drag(int x0, int y0, int x1, int y1) {
    tool.mousePressed(canvas, graphics, mouse(MouseEvent.MOUSE_PRESSED, x0, y0));
    tool.mouseDragged(canvas, graphics, mouse(MouseEvent.MOUSE_DRAGGED, x1, y1));
    tool.mouseReleased(canvas, graphics, mouse(MouseEvent.MOUSE_RELEASED, x1, y1));
  }

  private void key(String name) {
    // `return` carries `'\n'` as its char because that is what AWT puts on a real VK_ENTER press,
    // and `TextFieldCaret` is one `keyTyped` away from reading it. The other two are editing keys
    // with no character, hence CHAR_UNDEFINED, again AWT's own shape.
    final char character =
        switch (name) {
          case "return" -> '\n';
          default -> KeyEvent.CHAR_UNDEFINED;
        };
    final int code =
        switch (name) {
          case "delete" -> KeyEvent.VK_DELETE;
          case "backspace" -> KeyEvent.VK_BACK_SPACE;
          case "return" -> KeyEvent.VK_ENTER;
          default -> throw new IllegalArgumentException("unknown key " + name);
        };
    tool.keyPressed(canvas, keyEvent(KeyEvent.KEY_PRESSED, code, character));
  }

  /**
   * `type <text>`: one character at a time, each as AWT's pressed/typed pair.
   *
   * <p>`KeyEvent.getExtendedKeyCodeForChar` is what gives the press its `VK_` code, and it is the
   * same function AWT's own `KeyEvent(char)` convenience uses. It matters for correctness, not
   * tidiness: `TextFieldCaret.normalKeyPressed` switches on the code, so a press that carried
   * `VK_UNDEFINED` for every character would be indistinguishable from one that carried
   * `VK_BACK_SPACE`, and the class's own dispatch would never be exercised.
   *
   * <p>The typed event carries `VK_UNDEFINED` and the character, which is AWT's invariant for
   * `KEY_TYPED` and which `TextFieldCaret.keyTyped` relies on (`:318-329`: it reads `getKeyChar`
   * and nothing else).
   */
  private void type(String text) {
    for (var i = 0; i < text.length(); i++) {
      final var character = text.charAt(i);
      tool.keyPressed(
          canvas,
          keyEvent(
              KeyEvent.KEY_PRESSED,
              KeyEvent.getExtendedKeyCodeForChar(character),
              KeyEvent.CHAR_UNDEFINED));
      tool.keyTyped(canvas, keyEvent(KeyEvent.KEY_TYPED, KeyEvent.VK_UNDEFINED, character));
    }
  }

  private KeyEvent keyEvent(int id, int code, char character) {
    return new KeyEvent(canvas, id, System.currentTimeMillis(), 0, code, character);
  }

  // ── Attribute edits ───────────────────────────────────────────────────────────────────────

  private static Attribute<?> attributeNamed(AttributeSet attrs, String name) {
    if (attrs == null) return null;
    for (final var a : attrs.getAttributes()) {
      if (name.equals(a.getName())) return a;
    }
    return null;
  }

  private Component componentAnchoredAt(int x, int y) {
    for (final var comp : circuit().getNonWires()) {
      final var loc = comp.getLocation();
      if (loc != null && loc.getX() == x && loc.getY() == y) return comp;
    }
    throw new IllegalArgumentException("no component anchored at (" + x + "," + y + ")");
  }

  @SuppressWarnings({"unchecked", "rawtypes"})
  private void setToolAttribute(String name, String value) {
    final var attrs = tool.getAttributeSet();
    final var attr = attributeNamed(attrs, name);
    if (attr == null) throw new IllegalArgumentException("tool has no attribute " + name);
    attrs.setValue((Attribute) attr, attr.parse(value));
  }

  @SuppressWarnings({"unchecked", "rawtypes"})
  private void setComponentAttribute(int x, int y, String name, String value) throws Exception {
    final var comp = componentAnchoredAt(x, y);
    final var attr = attributeNamed(comp.getAttributeSet(), name);
    if (attr == null) {
      throw new IllegalArgumentException(
          comp.getFactory().getName() + " has no attribute " + name);
    }
    // The real attribute-table model, constructed through a same-package shim: it is what the
    // GUI edits through, and it does more than `SetAttributeAction.set`; it records
    // `attributesMayAlsoBeChanged` into the action so an undo restores them too.
    EditBridgeAttrTable.setValue(project, circuit(), comp, (Attribute) attr, attr.parse(value));
  }

  // ── The interpreter ───────────────────────────────────────────────────────────────────────

  private void apply(List<String[]> ops) throws Exception {
    for (final var op : ops) {
      switch (op[0]) {
        case "tool" -> tool = findTool(op[1]);
        case "toolattr" -> setToolAttribute(op[1], op[2]);
        case "click" -> click(Integer.parseInt(op[1]), Integer.parseInt(op[2]));
        case "drag" -> drag(
            Integer.parseInt(op[1]), Integer.parseInt(op[2]),
            Integer.parseInt(op[3]), Integer.parseInt(op[4]));
        case "key" -> key(op[1]);
        case "type" -> type(op[1]);
        case "setattr" -> setComponentAttribute(
            Integer.parseInt(op[1]), Integer.parseInt(op[2]), op[3], op[4]);
        case "undo" -> project.undoAction();
        case "redo" -> project.redoAction();
        default -> throw new IllegalArgumentException("unknown op " + op[0]);
      }
    }
  }

  private void save(File dest) throws Exception {
    try (OutputStream os = new FileOutputStream(dest)) {
      file.write(os, loader, dest, null);
    }
  }

  private static List<String[]> parse(File script) throws Exception {
    final var ops = new ArrayList<String[]>();
    for (final var raw : Files.readAllLines(script.toPath(), StandardCharsets.UTF_8)) {
      final var line = raw.strip();
      if (line.isEmpty() || line.startsWith("#")) continue;
      ops.add(line.split("\t"));
    }
    return ops;
  }

  // ── main ──────────────────────────────────────────────────────────────────────────────────

  private static String oneLine(String s) {
    return s == null ? "" : s.replace('\n', ' ').replace('\r', ' ').replace('\t', ' ');
  }

  public static void main(String[] args) throws Exception {
    // D17: turns every OptionPane into a log line instead of a modal dialog nobody can click.
    com.cburch.logisim.Main.headless = true;
    // See the header, obstacle 3. Written into the in-memory preferences tree installed by
    // `-Djava.util.prefs.PreferencesFactory`, so nothing touches the developer's real settings.
    com.cburch.logisim.prefs.AppPreferences.ADD_AFTER.set(
        com.cburch.logisim.prefs.AppPreferences.ADD_AFTER_UNCHANGED);

    final var in = new BufferedReader(new InputStreamReader(System.in, StandardCharsets.UTF_8));
    final PrintStream out = new PrintStream(System.out, true, StandardCharsets.UTF_8);

    String line;
    while ((line = in.readLine()) != null) {
      line = line.strip();
      if (line.isEmpty()) continue;
      if (line.equals("PING")) {
        out.println("PONG");
        continue;
      }
      final var parts = line.split("\t");
      if (parts.length != 3) {
        out.println("FAIL\t" + oneLine(line) + "\tbad-line (expected script<TAB>seed<TAB>out)");
        continue;
      }
      try {
        // A fresh Loader, LogisimFile, Project and Canvas per script. Sharing any of them would
        // let one script's library resolution, tool attributes or undo log leak into the next,
        // which is the exact order dependence that makes a baseline irreproducible.
        final var session = new EditBridge(new File(parts[1]));
        session.apply(parse(new File(parts[0])));
        session.save(new File(parts[2]));
        out.println("OK\t" + parts[0]);
      } catch (Throwable t) {
        out.println(
            "FAIL\t" + parts[0] + "\t" + t.getClass().getSimpleName() + ": "
                + oneLine(t.getMessage()));
      }
    }

    // Loading a LogisimFile starts AWT's non-daemon EDT; without this the JVM hangs at exit,
    // which looks exactly like a blocking dialog and is not one (CircBridge's header, verbatim).
    out.flush();
    System.exit(0);
  }
}
