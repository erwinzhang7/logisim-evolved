// GatesLibrary.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.gates.GatesLibrary),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── Why this file is load-bearing ───────────────────────────────────────────────────────────
//
// A `.circ` names a component by `<comp lib="N" name="AND Gate">`, where `N` indexes a
// `<lib desc="#Gates">` declaration. Resolution is by **string**, against the names the tools in
// this list publish. A typo in any of the thirteen names below does not fail loudly; it makes
// exactly one component silently unresolvable in every file that uses it, which is D8's opaque
// round-trip path rather than an error. So the names are transcribed from the Java constructor
// arguments and must not be "tidied": `"AND Gate"` keeps its space and its capitals,
// `"Odd Parity"` is two words, `"NOT Gate"` is not `"Not Gate"`.
//
// ── `FactoryDescription` is not ported ──────────────────────────────────────────────────────
//
// Unlike `IoLibrary` / `WiringLibrary` / `MemoryLibrary`, `GatesLibrary` never used
// `FactoryDescription` in the first place; every one of its thirteen entries is already an
// eager `new AddTool(X.FACTORY)`. So this list is a direct transcription, in upstream's order,
// which is also the order the component palette shows.
//
// `cachedTools` is memoized for the identity reason the other library files document:
// `AddTool.sharesSource` and `Library.contains`/`indexOf` compare factories by reference (D4).
//
// ── What did not come across ────────────────────────────────────────────────────────────────
//
//   * `getDisplayName()`'s localisation (`S.get("gatesLibrary")`); D5/D9's precedent;
//     the string itself DOES come across; it lives with the library's identity in
//     `LogisimFile/Builtin.swift`'s `BuiltinLibraryShell` table, because that shell, not
//     this class, is the `Library` object the loader hands to the app. This class is
//     registered only as a tool provider.

import Foundation
import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.std.gates.GatesLibrary`.
public final class GatesLibrary: Library {

  /// `GatesLibrary._ID`. Do NOT change: `.circ` files reference it via `<lib desc="#Gates">`.
  public override class var libraryId: String { "Gates" }

  private lazy var cachedTools: [Tool] = [
    AddTool(factory: NotGate.factory),
    AddTool(factory: Buffer.factory),
    AddTool(factory: AndGate.factory),
    AddTool(factory: OrGate.factory),
    AddTool(factory: NandGate.factory),
    AddTool(factory: NorGate.factory),
    AddTool(factory: XorGate.factory),
    AddTool(factory: XnorGate.factory),
    AddTool(factory: OddParityGate.factory),
    AddTool(factory: EvenParityGate.factory),
    // The two `ControlledBuffer` singletons: one class, two registered factories, whose names
    // ("Controlled Buffer" / "Controlled Inverter") come from the constructor rather than an
    // `_ID` constant.
    AddTool(factory: ControlledBuffer.factoryBuffer),
    AddTool(factory: ControlledBuffer.factoryInverter),
    AddTool(factory: Pla.factory),
  ]

  public override var tools: [Tool] { cachedTools }

  /// Hands this library's tool list to `LogisimFile`'s builtin seam.
  ///
  /// `Builtin` does not construct `GatesLibrary`: it constructs a
  /// `BuiltinLibraryShell(id: "Gates")` and asks `BuiltinToolProviders` for the tools on first
  /// use, because `Builtin` lives in `LogisimFile`, one module *below* this one, and cannot name
  /// a component type. Nothing calls `register` yet, so until it does, `#Gates` resolves to an
  /// empty shell and every gate in every `.circ` is still unresolvable; the components exist
  /// but nothing can find them.
  ///
  /// This is the "builtin tools" seam; installing the call is the integrator's, not this
  /// slice's, because the one place it belongs is a module-startup file this task does not own.
  /// A fresh `GatesLibrary` per call matches `Builtin` being per-`Loader` upstream, and the
  /// shell caches the result, so the closure runs once per shell.
  public static func registerBuiltinTools() {
    BuiltinToolProviders.register(libraryId: Builtin.gatesId) { GatesLibrary().tools }
  }
}
