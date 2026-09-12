// StdLibraries.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.Builtin),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// WHAT THIS FILE IS, AND WHY IT HAS NO DIRECT JAVA COUNTERPART
//
// Upstream, `com.cburch.logisim.std.Builtin` simply constructs every builtin library:
//
//     libraries = Arrays.asList(new BaseLibrary(), new GatesLibrary(), new WiringLibrary(), …);
//
// It can do that because Java has one flat classpath. This port does not: `LogisimFile` owns the
// `.circ` codec and must stay able to load a file without the component library existing at all,
// which is what makes the headless differential harness possible. So the dependency runs
// `LogisimStd → LogisimFile`, and `LogisimFile` cannot name a single component.
//
// `BuiltinToolProviders` is the inversion: `LogisimFile` declares a registry keyed by library id,
// and whoever links the component library fills it in. THIS FILE IS THAT FILL-IN, and calling
// `registerAll()` is the one thing that turns a `<lib desc="#Gates">` in a file into real tools.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// WHY IT EXISTS AS A SEPARATE FILE
//
// Six agents ported these families in parallel, and each was told to report a seam it could not
// own rather than reach across into a shared file. `GatesLibrary.registerBuiltinTools()` says so
// explicitly: "installing the call is the integrator's … the one place it belongs is a
// module-startup file this task does not own."
//
// They were right to leave it, and the gap is exactly the failure mode this project keeps
// hitting: every half built correctly and nothing owning the join. Without this file the seven
// libraries exist, expose correct tool lists, and are unreachable; `BuiltinToolProviders`
// answers `[]` for every id, so every `<comp>` in every file resolves to nothing.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// ORDERING AND TIMING
//
// `BuiltinToolProviders.register` replaces any earlier provider for the same id, and a
// `BuiltinLibraryShell` materialises its tools once per registry *generation*, then caches. So
// this must run BEFORE any file is loaded. Registration order between libraries does not matter
// , the registry is keyed by id, not ordered, but the order *within* a library's `tools` array
// does, because it is the order the UI presents them in and the order upstream declares.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// WHY THE PROVIDERS HAND OUT PROTOTYPES INSTEAD OF CONSTRUCTING A LIBRARY PER CALL
//
// This used to read `register(libraryId: Builtin.memoryId) { MemoryLibrary().tools }`, and that
// one word, `MemoryLibrary()`, was a defect, because the closure runs more than once. Every
// `register` bumps `BuiltinToolProviders.generation`, `BuiltinLibraryShell` re-materialises when
// it moves, and a fresh `MemoryLibrary` builds a fresh `Register()`. So a second
// `registerAll()`, from the other executable, or from any of the six suites that call it,
// silently replaced every component factory in the process.
//
// `AddTool.sharesSource` is `factory === other.factory` and nothing else, and `XmlReader` stores
// *clones* of library tools in the toolbar and the mouse mappings. Re-mint the factories under a
// loaded document and every one of those clones is orphaned: the palette can no longer say which
// library a button came from, and `XmlWriter.fromTool`, which resolves a tool to its library
// through `sharesSource`, fails the save with `tool '…' not found`. It presented as
// `ComponentPaletteTests` failing about one run in two with `(source → nil) != nil`, on whichever
// suites happened to interleave.
//
// Upstream has no such hazard and does not need a counter to avoid it: every builtin factory is
// a `public static final FACTORY` singleton (`Pin.FACTORY`, `AndGate.FACTORY`, …), and the
// families that route through `FactoryDescription` get the same guarantee from the other side;
// `DESCRIPTIONS` is a `private static final` array and each entry caches the factory it loads
// (`FactoryDescription.getFactory`). Factory identity is therefore process-stable *by
// construction*, whatever order anything is registered in.
//
// `BuiltinFactoryPrototypes` below is that guarantee, expressed once for the eleven families
// whose Swift ports construct their factories inline (`AddTool(factory: Register())`) rather
// than from a singleton. Gates and Wiring already use singletons and are included anyway, so the
// invariant is uniform and a future family cannot opt out of it by accident.
//
// ── WHAT THIS DELIBERATELY DOES *NOT* DO ────────────────────────────────────────────────────
//
//   * It does not touch the generation counter. Read its header in `Builtin.swift`: without it a
//     shell caches on first access and a later `register` becomes a silent no-op, which is
//     exactly how `#Soc` failed with 20 assertions green under `--filter` and red in a full run.
//     Late registration still works; it simply no longer changes what a factory *is*.
//   * It does not share the `Tool` objects. `fresh` clones them, so each `Builtin`, one per
//     `Loader`, as upstream, still gets its own `AddTool`s with their own attribute sets, which
//     is what `GatesLibrary`'s and `MemoryLibrary`'s constructors do upstream. Only the factory,
//     the thing identity is actually compared on, is shared.
//   * It does not change what happens when a provider is genuinely REPLACED. `register` called
//     twice for one id still installs the second closure and still bumps the generation; if that
//     closure is a *different* provider it legitimately supplies different tools. What no longer
//     happens is the same provider yielding different factories on its second call.

import Foundation
import LogisimFile
import LogisimKernel

/// One `Library` instance per builtin family, built once and never again.
///
/// This port's stand-in for upstream's `public static final FACTORY` fields: the *factories* a
/// family publishes are fixed for the life of the process, so `AddTool.sharesSource`,
/// `Library.contains` and `Library.indexOf`, all three of which are reference comparisons (D4)
/// , give the same answer no matter when they are asked.
///
/// ── Why the tool ARRAY is stored, and not the library ────────────────────────────────────────
///
/// Every library type memoises its own list in a `private lazy var cachedTools`, and a `lazy var`
/// is not thread-safe: two shells materialising on two threads would race its one-time
/// initialisation. Storing `[Tool]` forces that work to happen inside the static's own
/// `swift_once`, which *is* thread-safe, and leaves nothing mutable behind. The arrays are read
/// and never written afterwards, `fresh` copies rather than handing them out, so concurrent
/// readers are safe without a lock. The construction itself is lazy, nothing is built until a
/// shell first asks, so `registerAll()` stays as cheap as it was.
///
/// ── Why `#Base` is absent ───────────────────────────────────────────────────────────────────
///
/// It does not have the defect and pinning it here would introduce a different one. `#Base` is
/// served by `LogisimFile.BaseLibrary`, not by a `BuiltinLibraryShell`: it reads the provider
/// once in its own `init` and never re-materialises, so a generation bump cannot reach it. Its
/// only factory-bearing tool is `AddTool(Text.factory)`, over a singleton, so `sharesSource`
/// already holds. Meanwhile its `TextTool` and its four placeholders are `cloneTool()`-returns-
/// `self` objects that upstream constructs fresh per `BaseLibrary`; sharing them across
/// `Loader`s would make editing one document's Text-tool font edit the other's.
enum BuiltinFactoryPrototypes {
  static let gates: [Tool] = GatesLibrary().tools
  static let wiring: [Tool] = WiringLibrary().tools
  static let arithmetic: [Tool] = ArithmeticLibrary().tools
  static let memory: [Tool] = MemoryLibrary().tools
  static let io: [Tool] = IoLibrary().tools
  static let ttl: [Tool] = TtlLibrary().tools
  static let plexers: [Tool] = PlexersLibrary().tools
  static let extraIo: [Tool] = ExtraIoLibrary().tools
  static let fpArithmetic: [Tool] = FpArithmeticLibrary().tools
  static let tcl: [Tool] = TclLibrary().tools
  static let hdl: [Tool] = HdlLibrary().tools
  static let bfh: [Tool] = BfhLibrary().tools

  /// A new tool list over the *same* factories: upstream's `new AddTool(Pin.FACTORY)`.
  ///
  /// `cloneTool()` rather than a hand-rolled `AddTool(cloning:)` because `DescribedAddTool`
  /// overrides it to carry its library-supplied display name across. Copying through the
  /// superclass instead would silently downgrade every TTL and I/O entry to its factory's own
  /// name; the palette and the toolbar would then disagree about what one tool is called.
  static func fresh(_ prototypes: [Tool]) -> [Tool] { prototypes.map { $0.cloneTool() } }
}

/// Installs every builtin component library into `LogisimFile`'s registry.
public enum StdLibraries {
  private static let registrationLock = NSLock()

  /// Registers all builtin libraries. Idempotent, and safe to call more than once, though it
  /// must happen before the first file load; see the note on caching above.
  ///
  /// **Every caller that loads a `.circ` must call this**, including `logisim-cli`. A caller that
  /// forgets does not crash: it silently loads files whose components all fail to resolve, which
  /// looks like a corrupt file rather than a missing call.
  public static func registerAll() {
    registrationLock.lock()
    defer { registrationLock.unlock() }

    // One transaction, not a dozen separate writes.
    //
    // `registrationLock` alone only stops two *registrars* from interleaving. It does nothing
    // about a READER, which takes `BuiltinToolProviders`' own lock and can therefore run between
    // any two `register` calls below and observe a real, partial registry. That is not
    // theoretical: the suite failed with I/O, TTL, Plexers and Input/Output-Extra resolving 0
    // tools while Gates, Wiring, Arithmetic, Memory and Base resolved fine; the list cut
    // exactly in half. A component that fails to resolve looks identical to one that was never
    // registered, which is precisely the failure this registry exists to prevent.
    BuiltinToolProviders.transaction {
      registerAllLocked()
    }
  }

  /// The body of `registerAll`, run inside `BuiltinToolProviders.transaction`.
  private static func registerAllLocked() {
    // The `<appear>` seam. Not a tool provider, but the same kind of join and the same timing
    // contract, it must be installed before the first file is loaded, so it is installed from
    // the file that exists to own exactly these joins. Both halves go in together; see
    // `CircuitAppearanceSeam` for why neither is useful alone.
    CircuitAppearanceSeam.install()

    // Each closure hands out a fresh tool list over the ONE prototype library for that id. See
    // `BuiltinFactoryPrototypes` above for why constructing the library inside the closure was a
    // defect rather than a style choice.
    registerBase()
    let prototypes = BuiltinFactoryPrototypes.self
    BuiltinToolProviders.register(libraryId: Builtin.gatesId) { prototypes.fresh(prototypes.gates) }
    BuiltinToolProviders.register(libraryId: Builtin.wiringId) {
      prototypes.fresh(prototypes.wiring)
    }
    BuiltinToolProviders.register(libraryId: Builtin.arithmeticId) {
      prototypes.fresh(prototypes.arithmetic)
    }
    BuiltinToolProviders.register(libraryId: Builtin.memoryId) {
      prototypes.fresh(prototypes.memory)
    }
    BuiltinToolProviders.register(libraryId: Builtin.ioId) { prototypes.fresh(prototypes.io) }
    BuiltinToolProviders.register(libraryId: Builtin.ttlId) { prototypes.fresh(prototypes.ttl) }

    BuiltinToolProviders.register(libraryId: Builtin.plexersId) {
      prototypes.fresh(prototypes.plexers)
    }
    BuiltinToolProviders.register(libraryId: Builtin.extraIoId) {
      prototypes.fresh(prototypes.extraIo)
    }
    BuiltinToolProviders.register(libraryId: Builtin.fpArithmeticId) {
      prototypes.fresh(prototypes.fpArithmetic)
    }

    // `#TCL`, `#HDL-IP` and `#BFH-Praktika`.
    StdLibrariesExtra.registerAll()

    // `#Soc` is the one registration this function genuinely CANNOT make: its factories are
    // `com.cburch.logisim.soc.*`, they live in `LogisimSoc`, and `LogisimSoc` depends on
    // `LogisimStd`, so the arrow cannot point back. Whoever links an executable calls
    // `SocLibrary.registerBuiltinTools()`; `logisim-cli` does, and the app must too.
  }

  /// `#Base`, wired to the real `Text` factory.
  ///
  /// Two registrations, because upstream's `BaseLibrary` has two channels and the codec uses
  /// both. `getTools()` is the toolbar list; `getTool("Text")` additionally answers with
  /// `AddTool(Text.FACTORY)`, which upstream deliberately keeps *out* of `getTools()`. A
  /// `<comp lib="0" name="Text">` resolves through the second channel only.
  ///
  /// The four non-text entries stay placeholders: Poke, Edit, Wiring and Menu are canvas tools,
  /// and the codec needs only their names to round-trip a toolbar. `Select Tool` is absent here
  /// exactly as upstream; `EditTool` owns it and it is never published separately.
  private static func registerBase() {
    BuiltinToolProviders.register(libraryId: Builtin.baseId) {
      [
        BuiltinPlaceholderTool(id: BaseToolIds.poke),
        BuiltinPlaceholderTool(id: BaseToolIds.edit),
        BuiltinPlaceholderTool(id: BaseToolIds.wiring),
        TextTool(textFactory: Text.factory),
        BuiltinPlaceholderTool(id: BaseToolIds.menu),
      ]
    }
    BuiltinToolProviders.register(
      libraryId: Builtin.baseId,
      namedToolProvider: { [BaseToolIds.textFactory: AddTool(factory: Text.factory)] })

  }
}
