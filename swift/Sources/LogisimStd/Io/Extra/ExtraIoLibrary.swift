// ExtraIoLibrary.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.io.extra.ExtraIoLibrary),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── `ProgrammableGenerator` is ported but deliberately not registered ──────────────────────────
//
// Upstream's own comment: `// new AddTool(ProgrammableGenerator.FACTORY), /* TODO: Broken
// component, fix */`; the factory exists and is fully wired (attributes, ports, propagate) but
// is commented out of the tool list, so no `.circ` file can place a fresh one and the palette
// never shows it. Preserved exactly: `ProgrammableGenerator.swift` ports the class in full (a
// `.circ` file from a build where it *was* registered, or a hand-edited file, must still load
// and simulate identically), but `tools` below does not list it, matching upstream's dead entry.
//
// ── `FactoryDescription` is not ported ───────────────────────────────────────────────────────
//
// See `IoLibrary.swift`'s note: factories are built eagerly and once, matching upstream's own
// lazy-but-cached `tools` field.

import Foundation
import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.std.io.extra.ExtraIoLibrary`.
public final class ExtraIoLibrary: Library {

  /// `ExtraIoLibrary._ID`.
  public override class var libraryId: String { "Input/Output-Extra" }

  private lazy var cachedTools: [Tool] = [
    AddTool(factory: Switch()),
    AddTool(factory: Buzzer()),
    AddTool(factory: Slider()),
    AddTool(factory: DigitalOscilloscope()),
    AddTool(factory: PlaRom()),
    // `ProgrammableGenerator` is intentionally absent, see the file header.
  ]

  public override var tools: [Tool] { cachedTools }
}
