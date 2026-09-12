// SocLibrary.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.soc.Soc),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// WHY THIS FILE MATTERS OUT OF PROPORTION TO ITS SIZE
//
// `LogisimSoc` had 73 files and no `Library` class listing any of them, so nothing could reach
// them by name. That is not inert. `Builtin` declares a `BuiltinLibraryShell(id: "Soc")`, so a
// `<lib desc="#Soc">` *resolves*, and then every `<tool>` under it fails to resolve and takes
// D8's verbatim path, which re-emits exactly what the file said. Lossless, and wrong: Java
// resolves the tool, absorbs the attribute, finds it equal to the factory default, and drops
// the element. Measured on the corpus: 155 of 539 files carry a non-empty `<lib desc="#Soc">`
// (seven `<tool>` blocks, `SocBusSelection`/`SocBusIdentifier`), and 147 of them differ from
// the oracle in nothing else.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// THE `_ID` STRINGS ARE THE INTERFACE
//
// Upstream builds this list through `FactoryDescription`, which resolves each entry's name
// reflectively from the class's `public static final String _ID`. There is no reflection here,
// so every id is transcribed as a `static let` on the factory and referenced from there. They
// are NOT tidy: the memory component is `"Socmem"` (lower-case m, no separator) and the JTAG
// UART is `"SocJtagUart"` while its Java class is `JtagUart`. A single wrong character does not
// error; it makes one tool silently unresolvable in every file that names it.
//
// `FactoryDescription` itself is not ported, for the reason `GatesLibrary.swift` already
// records: it is the lazy JAR-loading machinery D11 does not bring across, and this port builds
// its factories eagerly. The observable difference is nil; `FactoryDescription.getTools`
// produces exactly the `AddTool(new X())` list built below, in the same order.
//
// ── That "nil" is now MEASURED, and it is the reason these stay plain `AddTool`s ─────────────
//
// It is not nil in general, and assuming so would be wrong. `AddTool.getDisplayName()` is
// `desc == null ? factory.getDisplayName() : desc.getDisplayName()` (`AddTool.java:309`), and
// upstream routinely hands the description a *different* bundle key than the factory hands its
// own constructor: measured, that splits 66 of the 173 builtin tools into two live strings,
// which is why `LogisimStd/Instance/FactoryDescription.swift` exists at all.
//
// `#Soc` is not one of them. All eight entries in `Soc.DESCRIPTIONS` pass the SAME key the
// factory's own constructor passes (`S.getter("SocBusComponent")` in both `Soc.java:41` and
// `SocBus.java:50`, and so on for all eight), so `names-4.1.0.tsv` lines 181-188 have column 4
// equal to column 5 on every row. A plain `AddTool` forwarding to the factory therefore gives
// the string upstream gives, and `DescribedAddTool` here would add a second copy of the same
// literal for nothing. `DisplayNameSocOracleTests` checks the two columns independently against
// the jar's own output, so if that ever stops being true it fails rather than passing quietly.
//
// The one thing genuinely dropped with the descriptions is the palette ICON (`"Rv32im.gif"`,
// `"Nios2.gif"`); the other six declare none. That belongs to the icon backlog, not here.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// REGISTRATION, AND THE MODULE-BOUNDARY PROBLEM THE INTEGRATOR MUST SETTLE
//
// `registerBuiltinTools()` below is the call that turns `<lib desc="#Soc">` into real tools.
// **It cannot be made from `LogisimStd`.** `LogisimSoc` depends on `LogisimStd` (for
// `Port`/`StdAttr`/`InstanceFactoryBase`), so the arrow cannot point back; and `logisim-cli`
// links `LogisimKernel`/`LogisimFile`/`LogisimStd` only, so nothing in the CLI's link graph can
// see this file at all. `StdLibraries.registerAll()` therefore cannot reach `#Soc` the way it
// reaches `#Gates`.
//
// Two edits close it, and both are outside this file's ownership:
//   1. `Package.swift`: add `"LogisimSoc"` to the `logisim-cli` target's `dependencies`.
//   2. the CLI/app startup; call `SocLibrary.registerBuiltinTools()` alongside
//      `StdLibraries.registerAll()`.
// Both are recorded in the hand-off notes. Until they land, `#Soc` stays on D8's verbatim path.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimStd

/// The eight `#Soc` component factories, built once and never again.
///
/// `LogisimStd`'s `BuiltinFactoryPrototypes` (in `StdLibraries.swift`) is the same guarantee for
/// the eleven families it owns, and its header carries the full account. The short version, and
/// the reason this enum exists rather than a `SocLibrary()` inside the provider closure:
///
/// `BuiltinToolProviders.tools(forLibraryId:)` invokes the registered closure on **every** call,
/// and `BuiltinLibraryShell` re-invokes it whenever the registry's generation counter moves,
/// which every `register`, for any library, does. `{ SocLibrary().tools }` therefore minted a
/// brand-new `Rv32imRiscV()`/`SocBus()`/… on each call. `AddTool.sharesSource` is
/// `factory === other.factory` and nothing else, `Library.contains`/`indexOf` are the same
/// comparison (D4), and `XmlReader` stores *clones* of library tools in the toolbar and the mouse
/// mappings, so every `.circ` with a SoC component on its toolbar was orphaned the moment
/// anything registered anything: the palette could not name the library a button came from, and
/// `XmlWriter.fromTool` fails such a save with `tool '…' not found`.
///
/// Upstream cannot have the problem. `Soc.DESCRIPTIONS` is a `private static final` array and
/// each `FactoryDescription` caches the factory it reflectively loads, so factory identity is
/// process-stable by construction, whatever order anything is registered in.
///
/// ── WHAT THIS DELIBERATELY DOES *NOT* DO ────────────────────────────────────────────────────
///
///   * It does not share the `Tool` objects. `fresh()` clones them, so each `Builtin`, one per
///     `Loader`, as upstream, still gets its own `AddTool`s with their own attribute sets, which
///     is what `GatesLibrary`'s and `MemoryLibrary`'s constructors do upstream. Sharing them
///     would make configuring a toolbar button edit the palette entry. Only the factory, the
///     thing identity is actually compared on, is shared.
///   * It does not stop `SocLibrary` being constructed per-`Loader`. That part of the old comment
///     was right; it was only wrong about the factory riding along with it.
///
/// The array is stored rather than the library because every library type memoises its list in a
/// `private lazy var`, and a `lazy var` is not thread-safe: two shells materialising on two
/// threads would race its one-time initialisation. A `static let` runs inside `swift_once`, which
/// is, and leaves nothing mutable behind: `fresh()` copies rather than handing the array out.
enum SocFactoryPrototypes {
  /// `Soc.DESCRIPTIONS`, in upstream's order, which is the order the component palette shows
  /// and, more to the point here, the order `XmlWriter.fromLibrary` walks when deciding which
  /// `<tool>` elements a `<lib desc="#Soc">` needs, so the order is observable in saved output.
  static let tools: [Tool] = [
    AddTool(factory: Rv32imRiscV()),
    AddTool(factory: Nios2()),
    AddTool(factory: SocBus()),
    AddTool(factory: SocMemory()),
    AddTool(factory: SocPio()),
    AddTool(factory: SocVga()),
    AddTool(factory: SocDma()),
    AddTool(factory: JtagUart()),
  ]

  /// A new tool list over the *same* factories: upstream's `new AddTool(Rv32imRiscV.FACTORY)`.
  static func fresh() -> [Tool] { tools.map { $0.cloneTool() } }
}

/// `com.cburch.logisim.soc.Soc`.
public final class SocLibrary: Library {

  /// `Soc._ID`. Do NOT change: `.circ` files reference it via `<lib desc="#Soc">`.
  public override class var libraryId: String { "Soc" }

  /// `DESCRIPTIONS`, in upstream's order, which is the order the component palette shows and,
  /// more to the point here, the order `XmlWriter.fromLibrary` walks when deciding which
  /// `<tool>` elements a `<lib desc="#Soc">` needs.
  ///
  /// Memoised for the identity reason every other library file in this port records: `AddTool
  /// .sharesSource` and `Library.contains`/`indexOf` compare factories by reference (D4), so a
  /// list rebuilt per access would make a toolbar entry unresolvable against its own library.
  ///
  /// Memoising the *instance's* list is necessary and was never sufficient; it only holds
  /// identity steady within one `SocLibrary`. The factories come from `SocFactoryPrototypes` so
  /// that it holds across instances too; read that enum's header for the failure it closes.
  private lazy var cachedTools: [Tool] = SocFactoryPrototypes.fresh()

  public override var tools: [Tool] { cachedTools }

  /// `getDisplayName()` = `S.get("socLibrary")` (`Soc.java:52`).
  ///
  /// The comment that stood here said display strings "are not localised in this port, and
  /// `Library.displayName` falls back to `name`". The fallback is real, but relying on it was a
  /// defect, not a deferral: `Library.displayName` defaults to `name`, so this answered "Soc"
  /// where 4.1.0 answers "System On a Chip". D5/D9 drop *localisation*, not the string; the
  /// port's single source of truth is the English string as a literal at the same site
  /// upstream calls `S.get`, exactly as `InstanceFactory`'s `displayName:` argument is.
  ///
  /// Measured, not transcribed: `names-4.1.0.tsv` line 180 is
  /// `LIB \t Builtin \t Soc \t System On a Chip`. `Builtin.swift`'s `BuiltinLibraryShell`, the
  /// object the explorer actually renders, since this class only supplies the tool list through
  /// `BuiltinToolProviders`, already carries the same string, so the two now agree; they did
  /// not before, and whichever of the two a future caller reached would have decided the answer.
  public override var displayName: String { "System On a Chip" }

  /// Hands this library's tool list to `LogisimFile`'s builtin seam.
  ///
  /// Each call hands out a fresh tool list over the ONE prototype factory set. Must be called
  /// before the first `.circ` load; see `StdLibraries.swift` on registration timing.
  ///
  /// The comment that stood here said "a fresh `SocLibrary` per call matches `Builtin` being
  /// per-`Loader` upstream, and `BuiltinLibraryShell` caches the result, so the closure runs once
  /// per shell". Both halves of that were wrong in the way that matters. `BuiltinLibraryShell`
  /// caches per *generation*, not for good, every `register`, for any library, moves the counter
  /// and re-runs this closure, and `BuiltinToolProviders.tools(forLibraryId:)` does not cache at
  /// all. And per-`Loader` is the right shape for the `Library` and its `AddTool`s, not for the
  /// factory: upstream's are process-stable by construction. See `SocFactoryPrototypes`.
  public static func registerBuiltinTools() {
    BuiltinToolProviders.register(libraryId: Builtin.socId) { SocFactoryPrototypes.fresh() }
  }
}
