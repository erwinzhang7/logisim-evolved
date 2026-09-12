// MemoryLibrary.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.memory.MemoryLibrary),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── `FactoryDescription` is not ported ───────────────────────────────────────────────────────
//
// Same reasoning as `IoLibrary.swift`: upstream defers factory construction through
// `FactoryDescription` (the lazy/reflective machinery behind JAR-loaded libraries, D11); this
// port always holds a live `ComponentFactory`, so the library just builds every factory once,
// eagerly. `cachedTools` is memoized for the same identity reason `IoLibrary` documents:
// `AddTool.sharesSource` and `Library.tool(named:)` compare factories by reference (D4), so a
// freshly-rebuilt array on every access would hand out non-`===`-matching factories.
//
// ── Components from sibling slices ───────────────────────────────────────────────────────────
//
// `DFlipFlop`, `TFlipFlop`, `JKFlipFlop`, `SRFlipFlop`, `Register`, `Counter`, `ShiftRegister`
// and `Random` are ported by this module's flip-flop/register/counter/shift-register/random
// slice; `Ram` and `Rom` by its `Mem`/`MemContents`/`MemState` slice. This file references all
// eight by name only; it does not compile until those land, which is expected under this task's
// file-ownership split.
//
// ── `DualRam` ────────────────────────────────────────────────────────────────────────────────
//
// Upstream's `DESCRIPTIONS` has an eleventh entry, `DualRam.class`. `DualRam`/`DualRamAppearance`
// /`DualRamAttributes`/`DualRamState` are a self-contained second RAM implementation with their
// own appearance renderer, named neither in this slice's remit ("RamAppearance, MemMenu,
// MemPoker, and remaining memory/*.java") nor unambiguously in the `Mem`/`Ram`/`Rom` slice's
// ("Mem/MemContents/MemContentsSub/MemState/Ram/Rom": six specific files, not "every RAM-shaped
// component"). Resolved under this same task's "remaining memory/*.java, not named by either
// slice" clause once the ambiguity was flagged; see the final report. Ported alongside this file.
//
// ── What did not come across ─────────────────────────────────────────────────────────────────
//
//   * `getDisplayName()`'s localisation (`S.get("memoryLibrary")`); D5/D9's precedent;
//     the string itself DOES come across; it lives with the library's identity in
//     `LogisimFile/Builtin.swift`'s `BuiltinLibraryShell` table, because that shell, not
//     this class, is the `Library` object the loader hands to the app. This class is
//     registered only as a tool provider.
//   * The `.gif` icon filenames threaded through `FactoryDescription`, M6/paint (D6).

import Foundation
import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.std.memory.MemoryLibrary`.
public final class MemoryLibrary: Library {

  /// `MemoryLibrary._ID`.
  public override class var libraryId: String { "Memory" }

  private lazy var cachedTools: [Tool] = [
    AddTool(factory: DFlipFlop()),
    AddTool(factory: TFlipFlop()),
    AddTool(factory: JKFlipFlop()),
    AddTool(factory: SRFlipFlop()),
    AddTool(factory: Register()),
    AddTool(factory: Counter()),
    AddTool(factory: ShiftRegister()),
    AddTool(factory: Random()),
    AddTool(factory: Ram()),
    AddTool(factory: Rom()),
    AddTool(factory: DualRam()),
  ]

  public override var tools: [Tool] { cachedTools }
}
