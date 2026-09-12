// PlexersLibrary.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.plexers.PlexersLibrary: the `Library`
// half: `_ID`, `getTools`, `DESCRIPTIONS`), https://github.com/logisim-evolution/logisim-evolution.
// Copyright by the Logisim-evolution developers. This translation is a derivative work and is
// therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── Why this file is separate from `PlexersLibraryAttributes.swift` ──────────────────────────
//
// Upstream's `PlexersLibrary` is one class doing two unrelated jobs: it holds the attribute and
// constant declarations the five components share (`ATTR_SELECT`, `ATTR_DISABLED`, `DELAY`,
// `contains`, `drawTrapezoid`) *and* it is the `Library` that publishes those components as
// tools. The component slice ported the first half as `PlexersLibraryAttributes` and explicitly
// left the second; "`PlexersLibrary` the `Library` … belongs to the library-registration
// workflow". This is that half. Splitting is what every other family here does (compare
// `ArithmeticLibrary` against `Arith/`), and it keeps the shared constants importable without
// dragging the tool list, and therefore all five factories, into anything that only wants
// `PlexersLibraryAttributes.delay`.
//
// ── `FactoryDescription` is not ported ───────────────────────────────────────────────────────
//
// Same reasoning as `ArithmeticLibrary`/`MemoryLibrary`/`IoLibrary`: upstream routes its five
// tools through `FactoryDescription`, the lazy/reflective machinery behind JAR-loaded libraries
// (D11), only so each icon and factory class loads on first toolbar use. This port always holds
// a live `ComponentFactory`, so `DESCRIPTIONS` collapses into a flat `AddTool(factory:)` list in
// upstream's declaration order, and that order is load-bearing, since it is the order the UI
// presents the tools in.
//
// `cachedTools` is memoized for the identity reason `MemoryLibrary` documents: `AddTool
// .sharesSource` and `Library.indexOf` compare factories by reference (D4), so rebuilding the
// array on each access would hand out a fresh, non-`===`-matching `AddTool` every read.
//
// ── The `_ID` strings are the file format ────────────────────────────────────────────────────
//
// `"Plexers"` here, and each factory's `id` below, are what a `.circ` names in
// `<lib desc="#Plexers">` / `<comp lib="2" name="Multiplexer">`. A typo does not error; the
// component simply fails to resolve and falls through to D8's opaque-placeholder path, which
// looks to a user like a corrupt file. Each of the five is asserted against its Java `_ID` in
// the table below, and the factories carry the same string as `static let id`:
//
//     Multiplexer      "Multiplexer"       Multiplexer.java:_ID
//     Demultiplexer    "Demultiplexer"     Demultiplexer.java:_ID
//     Decoder          "Decoder"           Decoder.java:_ID
//     PriorityEncoder  "Priority Encoder"  PriorityEncoder.java:_ID  ← note the space
//     BitSelector      "BitSelector"       BitSelector.java:_ID      ← note the *absence* of one
//
// The last two are the trap: upstream is inconsistent about the space, and "PriorityEncoder" or
// "Bit Selector" would each silently fail to load real files.
//
// ── What did not come across ─────────────────────────────────────────────────────────────────
//
//   * `getDisplayName()`'s localisation (`S.get("plexerLibrary")`); D5/D9 precedent;
//     the string itself DOES come across; it lives with the library's identity in
//     `LogisimFile/Builtin.swift`'s `BuiltinLibraryShell` table, because that shell, not
//     this class, is the `Library` object the loader hands to the app. This class is
//     registered only as a tool provider.
//   * `drawTrapezoid(Graphics, …)`; takes a `java.awt.Graphics`, so it is D6/M6 rendering and
//     cannot live in this module under D9. It is the only member of upstream's class that is
//     ported nowhere yet; `contains` (its hit-test counterpart) is in
//     `PlexersLibraryAttributes`.
//   * The `.gif` icon filenames threaded through `FactoryDescription`, M6 (D6).

import Foundation
import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.std.plexers.PlexersLibrary`.
public final class PlexersLibrary: Library {

  /// `PlexersLibrary._ID`. Do not change: `.circ` files reference it via
  /// `<lib desc="#Plexers">`.
  public override class var libraryId: String { "Plexers" }

  private lazy var cachedTools: [Tool] = [
    // Upstream's `DESCRIPTIONS`, in order, resolved eagerly instead of through
    // `FactoryDescription`.
    AddTool(factory: Multiplexer()),
    AddTool(factory: Demultiplexer()),
    AddTool(factory: Decoder()),
    AddTool(factory: PriorityEncoder()),
    AddTool(factory: BitSelector()),
  ]

  public override var tools: [Tool] { cachedTools }
}
