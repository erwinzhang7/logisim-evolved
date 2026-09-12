// LogisimUI: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// ============================================================================
// LIQUID GLASS, IN ONE PLACE.
//
// Every call into the macOS 26 Liquid Glass API in this module goes through this
// file. That is deliberate: the material APIs are new, and concentrating them here
// means the shell's *structure* never depends on them. If a surface has to fall back
// to a `Material`, exactly one file changes.
//
// Where glass is used and where it is not:
//   - Chrome that floats OVER content (canvas HUDs, the zoom control, the simulation
//     status pill, the breadcrumb) gets glass. That is what the material is for.
//   - The sidebar and inspector get the system's own sidebar/inspector treatment,
//     which is already Liquid Glass on macOS 26. We do NOT hand-roll glass there;
//     stacking a second glass layer on a glass container is exactly the mistake that
//     makes a Mac app look like a skin.
//   - The canvas itself is opaque. Schematic legibility beats material.
// ============================================================================

import SwiftUI

/// A floating control cluster that sits above the canvas.
///
/// Upstream puts the zoom control in a fixed panel under the attribute table
/// (`Frame.java:161-163`), permanently consuming sidebar height whether or not you are
/// zooming. Here it floats over the canvas, where the thing it controls actually is.
struct CanvasHUD<Content: View>: View {
  var content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    content
      .font(.system(size: 12, weight: .medium))
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .glassEffect(.regular, in: .capsule)
  }
}

extension View {
  /// Glass on an arbitrary rounded rectangle; used for the error banner and the
  /// breadcrumb, which are wider than a capsule reads well at.
  func glassPanel(cornerRadius: CGFloat = 12) -> some View {
    self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
  }

  /// A tinted glass panel, for the states that must be noticed: a recorded propagation
  /// error (D13) or a scheduler that cannot hit its tick rate (D7).
  func glassPanel(cornerRadius: CGFloat = 12, tint: Color) -> some View {
    self.glassEffect(.regular.tint(tint), in: .rect(cornerRadius: cornerRadius))
  }
}
