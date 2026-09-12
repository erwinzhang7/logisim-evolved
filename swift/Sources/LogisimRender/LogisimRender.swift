// LogisimRender: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// THE PURE HALF OF THE DRAWING API (D6). No platform import lives in this target: no
// CoreGraphics, no CoreText, no AppKit, no SwiftUI. It depends on LogisimKernel alone.
//
//   `SceneBuilder` is the API every `paintInstance` port is written against, 75 of them;
//   `RenderScene`
//   is its immutable output; `ScenePrimitive` is the record every backend consumes. Geometry is
//   plain `Double`/`Int`, never `CGFloat`, never `CGPoint`, precisely so this target can be
//   built, tested and diffed with no window server and no graphics stack present.
//
// WHY THIS IS A SEPARATE TARGET FROM LogisimRenderBackend
//
//   D9 requires LogisimStd to stay platform-free, and D6 requires LogisimStd to depend on the
//   drawing API so components can emit primitives. Those two only reconcile if the drawing API
//   is split: LogisimStd depends on THIS target, and never on the rasteriser. When the two
//   halves shared one module the dependency was real but unenforceable: `import LogisimRender`
//   from a component dragged CoreGraphics into the headless CLI and into every component test,
//   and nothing but review stopped a component from reaching for a `CGContext`.
//
//   Now it is enforced by the compiler: `CGContext` is not a name this target can spell.
//
//   It is also what lets Metal replace the CoreGraphics backend at M9 (D6) without touching a
//   single one of the component draw implementations; they are compiled against a module
//   that has never heard of either API.
//
// The one-line version of D6: component code emits typed primitives against a colour *slot*,
// never a colour and never a context. Geometry is immutable; the whole per-frame delta is a
// flat `[PaletteIndex]`.

public enum LogisimRenderModule {
  public static let name = "LogisimRender"
}
