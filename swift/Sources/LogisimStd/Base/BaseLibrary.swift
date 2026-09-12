// BaseLibrary.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.base.BaseLibrary),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ══ READ THIS FIRST: there is a second `BaseLibrary` in this program ═════════════════════════
//
// `LogisimFile/Builtin.swift` already declares `public final class BaseLibrary`, a placeholder
// version of this same Java class written so that `<lib desc="#Base">` could resolve at M2,
// long before any component existed. It reproduces the identity half correctly: `setHidden()`,
// the five tool `_ID`s, and the `getTool("Text")` special case, but its `textAdder` and its
// five tools are all `BuiltinPlaceholderTool`s: names with no factory behind them. That is why
// `<comp lib="0" name="Text">` still cannot be *placed* today, only named.
//
// This file is the real thing: the same class, with a live `AddTool(Text.factory)`. It follows
// the module's existing precedent, where `WiringLibrary`, `IoLibrary` and `MemoryLibrary` each
// exist here as full ports alongside a `BuiltinLibraryShell` of the same id in `Builtin.swift`,
// and the two are reconciled when the builtin-tools seam is wired up.
//
// **Exactly one of the two must survive**, and the reconciliation is not free, because
// `Builtin.swift`'s seam cannot express what this class needs. `BuiltinToolProviders` hands a
// shell a single `[Tool]`, and `LogisimFile.BaseLibrary` then picks its `textAdder` out of that
// same list by name. Upstream's `Text` adder is deliberately **not** in `getTools()`, it is
// reachable only through `getTool(String)`, so satisfying the seam by putting it in the list
// would publish six tools where 4.1.0 publishes five, and would make `XmlWriter` emit a
// `<tool name="Text">` element under `<lib desc="#Base">` that the Java writer never emits
// (`XmlWriter` iterates `library.tools`). That is a byte-level divergence in a saved file, so it
// is not an acceptable shortcut.
//
// The integrator's options, in preference order:
//
//   1. Delete `LogisimFile.BaseLibrary` and have `Builtin` hold *this* class. Cleanest, but it
//      inverts the module dependency (`LogisimFile` cannot import `LogisimStd`), so it needs a
//      registration hook rather than a direct reference.
//   2. Extend `BuiltinToolProviders` with a second, optional "named tools not in `getTools()`"
//      channel, register `Text` through it, and keep the shell. Smallest change; keeps the
//      byte-exact tool list.
//
// Until one of those lands this class is inert, nothing constructs it, and
// `LogisimFile.BaseLibrary` remains what `Builtin` uses. That is stated plainly rather than
// papered over, because a `.circ` carrying a text annotation loads either way and only *fails*
// at the point where the component is placed.
//
// ── The five interactive tools are placeholders here too ─────────────────────────────────────
//
// `PokeTool`, `EditTool`, `WiringTool`, `TextTool`, `MenuTool` and `SelectTool` are canvas
// interaction handlers: cursors, mouse and key events, ghost drawing. All of that is AWT-bound
// upstream and M6/M7 here, and D9 keeps it out of this module entirely. `Tool` carries nothing
// but a name at this stage, so the list below is built from `BuiltinPlaceholderTool`, which is
// precisely what a `<toolbar>` or `<mappings>` reference needs to resolve. Note `SelectTool` is
// absent from `getTools()` upstream as well, `EditTool` owns it and it is never published
// separately, but its `_ID` is named below because the pre-2.3.0 toolbar repair matches on it.
//
// ── What did not come across ─────────────────────────────────────────────────────────────────
//
//   * `getDisplayName()`'s localisation (`S.get("baseLibrary")`); D5/D9's precedent;
//     the string itself DOES come across; it lives with the library's identity in
//     `LogisimFile/Builtin.swift`'s `BuiltinLibraryShell` table, because that shell, not
//     this class, is the `Library` object the loader hands to the app. This class is
//     registered only as a tool provider.

import Foundation
import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.std.base.BaseLibrary`.
///
/// See the file header before using this type: `LogisimFile.BaseLibrary` is a second, competing
/// declaration of the same Java class, and it is the one `Builtin` currently instantiates.
public final class BaseLibrary: Library {

  /// `BaseLibrary._ID`. Do not change: `.circ` files reference it via `<lib desc="#Base">`.
  public override class var libraryId: String { "Base" }

  // Upstream `_ID`s of the tools this library publishes. Do not change: they are how a
  // `<toolbar>` / `<mappings>` entry names each tool.
  /// `com.cburch.logisim.tools.PokeTool._ID`.
  public static let pokeToolId = "Poke Tool"
  /// `com.cburch.logisim.tools.EditTool._ID`.
  public static let editToolId = "Edit Tool"
  /// `com.cburch.logisim.tools.WiringTool._ID`.
  public static let wiringToolId = "Wiring Tool"
  /// `com.cburch.logisim.tools.TextTool._ID`: the *tool*, not `Text._ID` the component factory.
  public static let textToolId = "Text Tool"
  /// `com.cburch.logisim.tools.MenuTool._ID`.
  public static let menuToolId = "Menu Tool"
  /// `com.cburch.logisim.tools.SelectTool._ID`. Not published by `tools`; named because the
  /// pre-2.3.0 toolbar repair matches on it.
  public static let selectToolId = "Select Tool"

  /// Java's `textAdder` field: an `AddTool` reachable through `tool(named:)` and deliberately
  /// absent from `tools`. Upstream's comment on the `getTool` branch is "needed by
  /// XmlCircuitReader": that reader resolves `<comp lib="0" name="Text">` through exactly this
  /// object, so it is the whole reason `Text` can be placed at all.
  private let textAdder: Tool = AddTool(factory: Text.factory)

  /// Java's `tools` field, built once in the constructor. See the file header for why these are
  /// placeholders and why `SelectTool` is not among them.
  private let toolList: [Tool] = [
    BuiltinPlaceholderTool(id: BaseLibrary.pokeToolId),
    // Upstream constructs `new EditTool(selectTool, wiring)`, i.e. the edit tool wraps the
    // select and wiring tools rather than the library publishing them side by side.
    BuiltinPlaceholderTool(id: BaseLibrary.editToolId),
    BuiltinPlaceholderTool(id: BaseLibrary.wiringToolId),
    BuiltinPlaceholderTool(id: BaseLibrary.textToolId),
    BuiltinPlaceholderTool(id: BaseLibrary.menuToolId),
  ]

  public override init() {
    super.init()
    setHidden()
  }

  public override var tools: [Tool] { toolList }

  /// `BaseLibrary.contains(ComponentFactory)`: `super.contains(query) || query instanceof Text`.
  ///
  /// The `instanceof` arm is load-bearing and cannot be reached through `indexOf`, because
  /// `Text.FACTORY`'s `AddTool` is not in `tools`. `XmlWriter` asks a library whether it owns a
  /// component's factory in order to write the right `lib=` index, so dropping this arm would
  /// make every text annotation unattributable to a library.
  ///
  /// D4: reference identity, matching `indexOf`'s own `===`.
  public override func contains(_ query: any ComponentFactory) -> Bool {
    if super.contains(query) { return true }
    return query is Text
  }

  /// `BaseLibrary.getTool(String)`: `super.getTool(name)`, then `Text._ID` and nothing else.
  ///
  /// D16: 4.2.0-dev adds an `Image` branch here. 4.1.0 has none, and publishing one would let a
  /// `<tool name="Image">` resolve where the oracle fails. See `Builtin.swift`'s note.
  public override func tool(named name: String) -> Tool? {
    if let found = super.tool(named: name) { return found }
    if name == Text.id { return textAdder }
    return nil
  }
}
