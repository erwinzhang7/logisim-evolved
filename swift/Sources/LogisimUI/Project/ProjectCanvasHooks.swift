// ProjectCanvasHooks.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (the canvas half of `com.cburch.logisim.proj.Project.setTool`
// and `setCircuitState`), https://github.com/logisim-evolution/logisim-evolution. Copyright by
// the Logisim-evolution developers. This translation is a derivative work and is therefore
// GPL-3.0-only. See LICENSE.md.
// SPDX-License-Identifier: GPL-3.0-only
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// THE TWO HALVES OF `Project` THAT REACH INTO THE CANVAS.
//
// `Project.setTool` and `Project.setCircuitState` each reach through `frame.getCanvas()` and do
// selection work. `Project.swift` cannot: the selection is the canvas's, the canvas is the
// shell's, and `Project` deliberately holds both weakly and knows neither concretely. So the two
// bodies are routed through `Project.circuitSwitchHook` / `Project.toolChangeHook`, and this file
// is what fills them in.
//
// ── WHY `toolChangeHook` IS THE DATA-LOSS ONE ────────────────────────────────────────────────
//
// A *floating* component (`SelectionBase.lifted`) exists in exactly one place: the selection's
// `lifted` set. Not in the circuit, not on the undo stack. That is what a paste or a duplicate
// produces, and it stays floating until something anchors it.
//
// `setTool` is upstream's anchor point (`SelectionActions.anchorAll` → `doAction`). Without it,
// pasting and then picking another tool leaves the pasted components floating forever: and the
// very next `clear`/`deleteAllHelper` on the selection discards them. The user pasted something,
// clicked a tool, and their components are gone with nothing on the undo stack. That is why this
// one is a data-loss bug and not a cosmetic one.
//
// ── AND WHY `circuitSwitchHook` IS THE STALE-SELECTION ONE ───────────────────────────────────
//
// Switching circuits without dropping the selection leaves it holding components that are not in
// the circuit now on screen. Every subsequent selection-scoped edit, Delete, an attribute
// change, a move, is then applied to a circuit the user is not looking at.
//
// ── THE ONE ORDERING DEVIATION, STATED ───────────────────────────────────────────────────────
//
// Upstream's `setTool` calls `tool.select(canvas)` *after* the `tool` field is assigned; this
// hook runs entirely before it (`Project.swift:797`, deliberately, so `old` and `new` are both
// available in one call). It is observationally identical here: `select`/`deselect` are declared
// on `CanvasTool`, and none of the five implementations (`SelectTool`, `EditTool`, `AddTool`,
// `PokeTool`, `TextTool`) reads `canvas.project.tool`. Checked, rather than assumed, because if
// one ever does the difference would be silent.
// ═════════════════════════════════════════════════════════════════════════════════════════════

import Foundation
import LogisimFile

/// Installs the canvas-side bodies of `Project.setTool` and `Project.setCircuitState`.
///
/// Called from `LogisimFileProjectHostFactory.registerBuiltinLibrariesIfNeeded`, beside
/// `CircuitTransaction.wireRepair` and the appearance seams: that function is the one place in
/// the tree that installs process-global seams, and a reader looking for one should find them
/// all together.
public enum ProjectCanvasHooks {

  /// Idempotent by construction, both assignments overwrite, so a second call from a second
  /// host is harmless. It is still made exactly once, under the host factory's registration lock.
  @MainActor
  public static func install() {
    // `MainActor.assumeIsolated`, not a `Task { @MainActor in … }` hop, and the distinction is
    // load-bearing: upstream performs this work *inside* `setTool`, before the tool field moves,
    // so a listener reacting to `ACTION_SET_TOOL` already sees an anchored selection. Deferring
    // it would let one frame observe a floating selection under the new tool. `assumeIsolated` is
    // synchronous and stays on the calling thread; `Project.setTool` is `@MainActor`, so the
    // assumption is exactly the isolation the caller already has.
    //
    // `UncheckedSendableBox` carries the two `Tool?`s across the closure boundary. Nothing
    // crosses an isolation domain: see the box's own doc comment in `ToolSeams.swift`.
    Project.toolChangeHook = { project, old, new in
      let boxed = UncheckedSendableBox((project, old, new))
      MainActor.assumeIsolated {
        let (project, old, new) = boxed.value
        applyToolChange(project, from: old, to: new)
      }
    }

    Project.circuitSwitchHook = { project in
      MainActor.assumeIsolated { applyCircuitSwitch(project) }
    }
  }

  // MARK: - `setTool`

  /// `Project.setTool(Tool)`'s body, minus the field assignment and the event.
  ///
  /// ```java
  /// final var canvas = frame.getCanvas();
  /// if (old != null) old.deselect(canvas);
  /// final var selection = canvas.getSelection();
  /// if (selection != null && !selection.isEmpty()) {
  ///   if (value == null || !getOptions().getMouseMappings().containsSelectTool()) {
  ///     final var act = SelectionActions.anchorAll(selection);
  ///     if (act != null) doAction(act);
  ///   }
  /// }
  /// … tool = value;
  /// if (tool != null) tool.select(frame.getCanvas());
  /// ```
  ///
  /// Upstream dereferences `frame.getCanvas()` unconditionally and throws an NPE with no frame.
  /// D13 forbids reproducing that as a trap; with no canvas there is no selection to anchor and
  /// no tool to notify, so the whole body is skipped. That is also exactly the headless case,
  /// `logisim-cli` and every model-level test, where it must be a no-op.
  @MainActor
  static func applyToolChange(_ project: Project, from old: Tool?, to new: Tool?) {
    guard let canvas = project.canvas else { return }

    // `as?` because `select`/`deselect` are declared on `CanvasTool` (this module) while
    // `Project.tool` is typed as `LogisimFile.Tool`: the codec's type, which knows nothing about
    // canvases. A library tool that has no editing behaviour simply has nothing to notify, which
    // is the same no-op upstream's empty `Tool.select` base implementation is.
    (old as? any CanvasTool)?.deselect(canvas)

    let selection = canvas.selection
    if !selection.isEmpty {
      // Upstream's condition, kept verbatim including the part that looks backwards: the
      // selection is anchored when switching to NO tool, or when the file's mouse mappings do
      // NOT bind a Select Tool. The default template binds Poke and Menu only, so in practice
      // this fires on every tool change.
      if new == nil || !project.options.mouseMappings.containsSelectTool {
        // `nil` when nothing is floating: upstream's own null check, and what keeps an empty
        // "Drop" off the undo stack every time the user clicks a different tool.
        if let action = SelectionActions.anchorAll(selection) {
          do {
            try project.doAction(action)
          } catch {
            project.recordDiagnostic("could not anchor the selection on a tool change: \(error)")
          }
        }
      }
    }

    (new as? any CanvasTool)?.select(canvas)
  }

  // MARK: - `setCircuitState`

  /// The `if (circuitChanged)` canvas block of `Project.setCircuitState(CircuitState)`.
  ///
  /// ```java
  /// if (tool != null) tool.deselect(canvas);
  /// final var selection = canvas.getSelection();
  /// if (selection != null) {
  ///   final var act = SelectionActions.dropAll(selection);
  ///   if (act != null) doAction(act);
  /// }
  /// if (tool != null) tool.select(canvas);
  /// ```
  ///
  /// Note `dropAll` empties the selection in **both** of its arms: when something is floating it
  /// returns a `Drop` action that anchors it and deselects; when everything is already anchored
  /// it deselects immediately and returns `nil`, because there would be nothing to undo. So the
  /// post-condition, no selection pointing into the circuit being left, holds either way, and
  /// a caller that only handled the non-nil arm would be wrong.
  @MainActor
  static func applyCircuitSwitch(_ project: Project) {
    guard let canvas = project.canvas else { return }

    let tool = project.tool as? any CanvasTool
    tool?.deselect(canvas)

    do {
      if let action = try SelectionActions.dropAll(canvas.selection) {
        try project.doAction(action)
      }
    } catch {
      project.recordDiagnostic("could not drop the selection on a circuit switch: \(error)")
    }

    tool?.select(canvas)
  }
}
