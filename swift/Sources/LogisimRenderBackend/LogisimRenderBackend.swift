// LogisimRenderBackend: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// THE RASTERISER HALF OF THE DRAWING API (D6). This is where the platform lives: CoreGraphics
// and CoreText are imported here and nowhere below. It depends on LogisimRender (the pure
// scene) and turns a `RenderScene` into pixels.
//
//   `SceneRenderer`      the backend seam. `CoreGraphicsSceneRenderer` is today's conformer;
//                        D6 puts a Metal one behind this same protocol at M9.
//   `RenderViewport`     the scene -> device mapping, including backing scale.
//   `GridSnap`           reproduces Java2D's pixelisation so the image diff can be exact.
//   `CoreTextCache`      shaped-`CTLine` cache; D6's answer to upstream re-shaping every label
//                        every frame (`GraphicsUtil.java:166-167`, `:201`).
//   `SceneBitmap`        a rasterised result, for headless comparison.
//
// The arrow points one way and the compiler now enforces it: this target imports LogisimRender,
// LogisimRender cannot import this one, and LogisimStd links only LogisimRender. That is the
// D9 property, the component library and the headless CLI never acquire CoreGraphics, turned
// from a review convention into a build error.
//
// Adding a Metal backend at M9 means adding a second `SceneRenderer` conformer, either here or
// in a sibling target that also depends on LogisimRender. It does not mean touching any of the
// the component draw implementations.

public enum LogisimRenderBackendModule {
  public static let name = "LogisimRenderBackend"
}
