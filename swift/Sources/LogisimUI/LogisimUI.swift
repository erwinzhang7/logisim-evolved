// LogisimUI: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// ============================================================================
// MODULE MAP.
//
//   App/        the `App`, its scenes, the document, and the menu bar.
//   Editor/     one window: its state (`EditorModel`), its layout, its toolbar.
//   Sidebar/    the explorer: circuits, libraries, simulation states.
//   Inspector/  the trailing property pane.
//   Canvas/     the AppKit seam the renderer plugs into, plus the floating HUD.
//   Preferences/ the `Settings` scene and its observable model.
//   Seams/      the two protocols this module needs from other teams.
//   Support/    palette resolution and glass styling.
//   Project/    the real, `LogisimFile`-backed `ProjectHost`, its outline and inspector
//               projections, and the simulation engine that drives the D7 clock.
//
// `Demo/` is gone. It held `DemoProjectHost`, a stand-in that implemented every member of
// `ProjectHost` correctly against fabricated data so the shell was launchable and clickable
// before either the codec or the renderer had landed. It did that job. `Project/` now covers
// everything it demonstrated, including the D8/D11 unresolved-library reporting, which was the
// one thing the stand-in modelled faithfully, so it was deleted rather than left beside the
// real one.
//
// The shell depends on exactly two things declared in `Seams/`:
//
//   `CircuitRenderSurface` : implemented in `Canvas/` over `LogisimRender`. Vends an `NSView`,
//                             accepts a viewport and an appearance, answers hit tests, draws.
//   `ProjectHost` / `ProjectHostFactory`
//                           : implemented in `Project/` over `LogisimFile`. Projects the model
//                             into value snapshots, accepts commands, serialises to `Data`.
//
// The *views* still import neither: everything above `Seams/` binds to value snapshots and
// opaque IDs, never to a `Circuit`, a `Component` or an `AttributeSet`. That is what D4 forces
// (component identity is reference identity, and synthesised `Equatable` on `Component` is
// forbidden, which is exactly what a SwiftUI `List` selection would demand) and it is why the
// inspector and the sidebar are previewable and testable with no model behind them.
// ============================================================================

public enum LogisimUIModule {
  public static let name = "LogisimUI"

  /// Called once at launch, before any window exists, to replace the stand-in host with
  /// the real codec-backed one. See `ProjectHostFactoryRegistry`.
  @MainActor
  public static func install(projectHostFactory: any ProjectHostFactory) {
    ProjectHostFactoryRegistry.shared.factory = projectHostFactory
  }
}
