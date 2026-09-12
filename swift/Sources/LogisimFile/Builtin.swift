// logisim-evolved: a native Swift/macOS port of logisim-evolution.
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution),
// which is GPL-3.0-only. This port is a derivative work and is therefore GPL-3.0-only.
// SPDX-License-Identifier: GPL-3.0-only
//
// Port of com.cburch.logisim.std.Builtin; the registry of the 14 libraries that ship inside
// the application and are referenced from `.circ` as `<lib desc="#Name">`.
//
// This file is load-bearing out of proportion to its size. Every corpus file declares twelve
// builtin libraries while instantiating components from two or three, and an unresolved
// `<lib>` declaration fails the whole load. So all fourteen must be registerable by their
// exact `desc` string now, long before their components exist.

import Foundation
import LogisimKernel

// MARK: - Tool providers

/// Where the component tranches (M4/M5) hand their tools to the builtin shells.
///
/// `Builtin` is instantiated per `Loader`, exactly as in Java, so tool lists cannot live on a
/// single shared instance. Registration is therefore global and keyed by library id; each
/// shell asks once, on first use, and caches the answer.
public enum BuiltinToolProviders {
  private static var providers: [String: () -> [Tool]] = [:]

  /// Bumped by every `register`, and compared by `BuiltinLibraryShell`'s cache.
  ///
  /// **Without it, registration order is a silent correctness requirement.** A shell caches its
  /// tool list on first access and never rebuilds; register a provider afterwards and nothing
  /// happens. That is exactly how `#Soc` failed: 20 assertions across `SocRegistrationTests`
  /// reporting components with no ends and zero bounds, passing in isolation and failing in a
  /// full `swift test`; because some earlier suite had touched the `#Soc` shell before
  /// `SocLibrary.registerBuiltinTools()` ran, freezing an empty list.
  ///
  /// The registering code already knew: its comment says "Must precede the first load". A
  /// constraint the code does not enforce is a defect waiting for a different call order, and the
  /// app is one background load away from the same failure.
  private static var generation: UInt64 = 0

  static var currentGeneration: UInt64 {
    lock.lock()
    defer { lock.unlock() }
    return generation
  }
  private static var namedProviders: [String: () -> [String: Tool]] = [:]

  // ── Why there is a lock here ────────────────────────────────────────────────────────────────
  //
  // These two dictionaries are process-global mutable state reachable from any thread, and this
  // module compiles in Swift 5 language mode (D1), so the compiler issues no diagnostic about
  // that at all.
  //
  // It is not theoretical. Adding one more suite that calls `StdLibraries.registerAll()` while
  // another suite was loading corpus files reproduced a hard crash:
  //
  //     *** Terminating app due to uncaught exception 'NSInvalidArgumentException',
  //     reason: '-[NSIndirectTaggedPointerString count]: unrecognized selector sent to
  //             instance 0x8000000000000000'
  //     … $sSD8_VariantV8setValue_6forKeyyq_n_xtF
  //     … BuiltinToolProviders.register(libraryId:provider:)
  //
  // ; a `Dictionary` whose storage was reallocated by one thread while another was writing into
  // it, surfacing as a garbage object receiving `count`. It killed the whole test binary rather
  // than failing a test, and it is a live hazard in the app too: nothing stops a background
  // load from racing a late `registerAll()`.
  //
  // `NSRecursiveLock` rather than an actor because every caller is synchronous and must stay so
  // ; the read path runs inside `BuiltinLibraryShell`'s lazy `tools` accessor, which the codec
  // calls while parsing. D1 names it, alongside `NSLock`, as a primitive the kernel is allowed.
  // Uncontended, it is a few nanoseconds on Apple silicon and registration happens a handful of
  // times per process, so this is not on any hot path.
  //
  // ── Why RECURSIVE, and why there is a `transaction` below ─────────────────────────────────
  //
  // A plain lock makes each individual write atomic, which is enough to stop the dictionary
  // corruption described above and NOT enough to make the registry correct. Two windows remain,
  // and both were observed:
  //
  //   1. `StdLibraries.registerAll()` performs about a dozen separate `register` calls. A reader
  //      running between them sees a REAL, PARTIAL registry. That is not a hypothetical: the
  //      suite failed with `I/O`, `TTL`, `Plexers` and `Input/Output-Extra` resolving 0 tools
  //      while `Gates`, `Wiring`, `Arithmetic`, `Memory` and `Base` resolved fine: exactly the
  //      registration list cut in half, which is what a half-finished `registerAll` looks like.
  //   2. `removeAll()` followed by re-registration leaves the registry EMPTY in between, and a
  //      concurrent reader legitimately resolves nothing at all.
  //
  // Neither is a memory race, so neither is caught by a lock around single writes, and both
  // present as "a component failed to resolve": indistinguishable from a genuinely missing
  // registration, which is the bug this registry exists to prevent.
  //
  // `transaction` closes both by letting a caller hold the lock across a GROUP of writes. It has
  // to be recursive because the body calls `register`, which takes the same lock.
  private static let lock = NSRecursiveLock()

  /// Perform several registry mutations as one atomic step.
  ///
  /// Readers block for the duration, so no one can observe a half-built registry. Use it for any
  /// sequence that is only meaningful complete: `StdLibraries.registerAll()`, and any test that
  /// clears the registry and puts it back.
  ///
  /// Do **not** invoke a provider closure inside the body. Providers build a whole library and
  /// can re-enter this registry; the lock is recursive so that would not deadlock, but it would
  /// hold every reader for the duration of a library construction.
  public static func transaction<T>(_ body: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try body()
  }

  /// Install the tool list for a builtin library. Calling this twice for the same id replaces
  /// the earlier provider; shells re-materialise on the next generation, so a replacement is
  /// seen, but register before any file is loaded all the same.
  ///
  /// ── THE ONE CONTRACT A PROVIDER MUST HONOUR: STABLE FACTORY IDENTITY ────────────────────────
  ///
  /// **`provider` is called many times and must return the same `ComponentFactory` objects every
  /// time.** It is called once per shell per generation, and every `register`, including one for
  /// an unrelated library, moves the generation. A closure of the shape
  /// `{ MemoryLibrary().tools }` therefore hands out a NEW `Register()` on its second call, and
  /// that is a defect, not an inefficiency: `AddTool.sharesSource` is `factory === other.factory`,
  /// `Library.contains`/`indexOf` are the same comparison (D4), and `XmlReader` stores *clones* of
  /// library tools in the toolbar and the mouse mappings. Re-mint the factories under a loaded
  /// document and every clone is orphaned; the palette cannot name the library a button came
  /// from, and `XmlWriter.fromTool` fails the save with `tool '…' not found`. It presented as
  /// `ComponentPaletteTests` failing about one run in two, on whichever suites interleaved.
  ///
  /// Upstream cannot have the problem: every builtin factory is a `public static final FACTORY`
  /// singleton, and the `FactoryDescription` families cache theirs in a `private static final`
  /// array. `LogisimStd`'s `BuiltinFactoryPrototypes` reproduces that guarantee for the eleven
  /// families whose Swift ports construct factories inline, and any new provider, `#Soc`'s
  /// included, owes the same. The tool OBJECTS may be fresh per call (upstream builds a new
  /// `AddTool` per `Library` instance); the factories may not.
  public static func register(libraryId: String, provider: @escaping () -> [Tool]) {
    lock.lock()
    defer { lock.unlock() }
    providers[libraryId] = provider
    generation &+= 1
  }

  public static func tools(forLibraryId id: String) -> [Tool] {
    lock.lock()
    let provider = providers[id]
    lock.unlock()
    // Deliberately called OUTSIDE the lock. A provider closure builds a whole library's
    // factories and can itself reach back into this registry; holding a non-recursive lock
    // across it would deadlock.
    return provider?() ?? []
  }

  // ── The second channel: tools a library answers by name but does NOT publish ──────────────
  //
  // `BaseLibrary` holds `textAdder`, an `AddTool(Text.FACTORY)` reachable only through
  // `getTool(String)`. Upstream's own comment on that branch is "needed by XmlCircuitReader":
  // `<comp lib="0" name="Text">` resolves through exactly this object, so it is the whole
  // reason a text annotation can be placed at all. It is deliberately absent from `getTools()`,
  // and putting it there instead would publish six tools where 4.1.0 publishes five and make
  // `XmlWriter.fromLibrary` emit a `<tool name="Text">` element the oracle never writes.
  //
  // The single-`[Tool]` channel above cannot express that, which is why `LogisimStd`'s own
  // `BaseLibrary` header records the seam as unwired and lists "extend `BuiltinToolProviders`
  // with a second, optional named-tools channel" as the preferred fix. This is that channel.

  /// Install tools a builtin library answers from `tool(named:)` while keeping them out of
  /// `tools`. Keyed by the name the `.circ` references, which for `Text` is `"Text"`: the
  /// component factory's `_ID`, not the `"Text Tool"` of the toolbar entry.
  public static func register(
    libraryId: String, namedToolProvider: @escaping () -> [String: Tool]
  ) {
    lock.lock()
    defer { lock.unlock() }
    namedProviders[libraryId] = namedToolProvider
    // Both register paths bump it. `BaseLibrary`'s named lookup feeds the same shells, so a
    // named-provider registration that did not invalidate would reintroduce the identical bug
    // through the other door.
    generation &+= 1
  }

  public static func namedTools(forLibraryId id: String) -> [String: Tool] {
    lock.lock()
    let provider = namedProviders[id]
    lock.unlock()
    return provider?() ?? [:]
  }

  /// Test-support: forget every registration.
  ///
  /// Prefer `withRegistryCleared`; see its header for why a bare clear is nearly always wrong.
  public static func removeAll() {
    lock.lock()
    defer { lock.unlock() }
    providers.removeAll()
    namedProviders.removeAll()
    // Both `register` paths bump this and so must the clear: a shell that materialised its tools
    // before the clear would otherwise keep serving them, so `removeAll()` would be invisible to
    // exactly the consumers it is supposed to affect.
    generation &+= 1
  }

  /// Test-support: run `body` against an empty registry, then restore **exactly** what was there.
  ///
  /// ── WHY A BARE `removeAll()` + MANUAL RESTORE IS THE WRONG SHAPE ──────────────────────────
  ///
  /// The registry is process-global and every test target links into ONE binary, so a clear in
  /// any module clears it for all of them. A test can only put back what its own module can
  /// *import*, and that is strictly less than what was registered: `LogisimStdTests` restored
  /// with `StdLibraries.registerAll()` + `StdLibrariesExtra.registerAll()`, which cannot name
  /// `#Soc` because `LogisimStd` cannot import `LogisimSoc`. So the clear was permanent for that
  /// one library, and `LogisimUI`'s registration guard is one-shot; nothing ever put it back.
  ///
  /// The visible result was a SoC component loading as a D8 placeholder in a full `swift test`
  /// and resolving fine under `--filter`: the signature of shared state, not of a defect in
  /// either test. Holding the lock across the window (which that test already did) fixes the
  /// *concurrent* reader and does nothing about the loss, because the loss outlives the window.
  ///
  /// Snapshot/restore has neither problem: it is exact regardless of which module calls it, and
  /// no reader observes the empty window.
  /// Holds the registry steady across `body`, so no `register` from another thread can land in
  /// the middle of a multi-step operation that must see one consistent answer throughout.
  ///
  /// ── The flake this closes (board #83), and why four other explanations were wrong ─────────
  ///
  /// `tools(forLibraryId:)` answers `provider?() ?? []`, so a builtin library resolves to a shell
  /// with **no tools at all** until something calls `StdLibraries.registerAll()`. That is not a
  /// locking bug: `register` and the reader both take `lock`, and `withRegistryCleared` holds it
  /// across its whole body, so nobody ever observes a half-cleared registry. It is an **ordering**
  /// one, and it is board #34's family.
  ///
  /// `LogisimStdTests` calls `registerAll()` from inside test bodies. `LogisimFileTests` runs
  /// concurrently in the same process and does not link `LogisimStd`, so a round trip there sees
  /// `#Wiring` with no `Pin` tool *before* that call and with one *after*. A test that round-trips
  /// twice and compares the bytes therefore compares one file written without a `<tool name="Pin">`
  /// block against one written with it: and fails, on a registration it has nothing to do with.
  ///
  /// Measured directly: instrumenting the writer printed `NO PIN TOOL IN #Wiring` for the first
  /// six loads of a failing run and a real `classic` value for the seventh.
  ///
  /// `lock` is an `NSRecursiveLock`, which is what makes this usable: `body` will itself call
  /// `tools(forLibraryId:)`, which takes the same lock on the same thread and re-enters happily,
  /// while a `register` from any other thread blocks until `body` is done.
  ///
  /// **This pins the registry, it does not populate it.** A caller that runs before any
  /// registration still sees empty libraries: consistently empty, for the whole body, which is
  /// the property a fixed-point comparison actually needs.
  public static func withRegistryPinned<T>(_ body: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try body()
  }

  public static func withRegistryCleared<T>(_ body: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }

    let savedProviders = providers
    let savedNamedProviders = namedProviders
    // Registered second, so it runs FIRST (defers are LIFO): i.e. still under the lock.
    defer {
      providers = savedProviders
      namedProviders = savedNamedProviders
      generation &+= 1
    }

    providers.removeAll()
    namedProviders.removeAll()
    generation &+= 1
    return try body()
  }
}

// MARK: - Base tool ids

/// The `_ID` of every tool `#Base` names, in one place that is not itself called `BaseLibrary`.
///
/// `BaseLibrary` is declared in **both** `LogisimFile` and `LogisimStd`, the second is the
/// fuller port, kept alongside until the two are reconciled, and `LogisimFile` is also the
/// module name, so a caller that imports both cannot write `LogisimFile.BaseLibrary.pokeToolId`
/// to disambiguate: the qualifier resolves to the *class*, not the module. These constants give
/// such a caller an unambiguous name instead of a magic string.
public enum BaseToolIds {
  /// `com.cburch.logisim.tools.PokeTool._ID`.
  public static let poke = "Poke Tool"
  /// `com.cburch.logisim.tools.EditTool._ID`.
  public static let edit = "Edit Tool"
  /// `com.cburch.logisim.tools.WiringTool._ID`.
  public static let wiring = "Wiring Tool"
  /// `com.cburch.logisim.tools.TextTool._ID`: the tool, not the factory.
  public static let textTool = "Text Tool"
  /// `com.cburch.logisim.tools.MenuTool._ID`.
  public static let menu = "Menu Tool"
  /// `com.cburch.logisim.tools.SelectTool._ID`. Not published by `getTools()`.
  public static let select = "Select Tool"
  /// `com.cburch.logisim.std.base.Text._ID`, the component factory.
  public static let textFactory = "Text"
}

// MARK: - Shells

/// A builtin library whose identity is fixed and whose tool list is supplied later.
///
/// Upstream each of these is a distinct `Library` subclass in `com.cburch.logisim.std.*`
/// carrying both the identity and the component list. The identity half is what file loading
/// needs and is reproduced exactly; the component half is M4/M5 and arrives through
/// `BuiltinToolProviders`.
open class BuiltinLibraryShell: Library {
  private let identifier: String
  private let display: String
  private var materialisedTools: [Tool]?
  /// The `BuiltinToolProviders` generation `materialisedTools` was built at. See that counter.
  private var materialisedAt: UInt64 = .max

  public init(id: String, displayName: String, hidden: Bool = false) {
    self.identifier = id
    self.display = displayName
    super.init()
    if hidden { setHidden() }
  }

  public override var name: String { identifier }
  public override var displayName: String { display }

  /// Caches, but re-materialises when a provider has been registered since.
  ///
  /// Upstream caches unconditionally and gets away with it because every library is registered
  /// before any file is opened. This port registers `#Soc` and the HDL generators from whichever
  /// executable links them, so "before the first load" is a convention rather than a guarantee:
  /// and a cache that outlives a registration turns a late `register` into a silent no-op.
  public override var tools: [Tool] {
    let generation = BuiltinToolProviders.currentGeneration
    if let materialisedTools, materialisedAt == generation { return materialisedTools }
    let produced = BuiltinToolProviders.tools(forLibraryId: identifier)
    materialisedTools = produced
    materialisedAt = generation
    return produced
  }
}

/// `com.cburch.logisim.std.base.BaseLibrary`.
///
/// Modelled separately from the other thirteen for two reasons that show up during load:
/// it is `setHidden()`, and its `getTool(String)` answers "Text" out of an `AddTool` that is
/// deliberately *not* in `getTools()`; a special case XmlCircuitReader depends on for
/// `<comp lib="0" name="Text">`.
///
/// The five tool names are reproduced now because the toolbar and mouse-mapping sections of
/// every file reference them, and because the `<2.3.0` migration repair rewrites the toolbar
/// from `Poke, Select, Wiring, Text` to `Poke, Edit, Text` by name. Note `Select Tool` is
/// absent from the list upstream too: it is owned by `EditTool`, not published separately.
///
/// ── D16: five tools, not six ────────────────────────────────────────────────────────────────
///
/// An earlier revision published a sixth tool, `Image`, and answered it from `tool(named:)`.
/// That is **main's** `BaseLibrary`. `com.cburch.logisim.std.base` in v4.1.0 contains exactly
/// `BaseLibrary.java`, `Text.java` and `TextAttributes.java`; `Image.java`,
/// `ImageAttributes.java` and `ImageSourceAttribute.java` are 4.2.0-dev additions. 4.1.0's
/// constructor builds `Poke, Edit, Wiring, Text, Menu` and its `getTool` special-cases
/// `Text._ID` alone. Publishing a tool the target version does not have would make a
/// `<tool name="Image">` resolve here instead of failing the way the oracle fails, and would
/// put a sixth entry into any list derived from `getTools()`.
public final class BaseLibrary: Library {
  public override class var libraryId: String { "Base" }

  /// Java's `textAdder`: reachable through `getTool`, absent from `getTools`.
  private let textAdder: Tool
  private let toolList: [Tool]

  public override init() {
    let provided = BuiltinToolProviders.tools(forLibraryId: BaseLibrary.libraryId)
    // The named-tools channel, whose only member upstream is `textAdder`. Falling back to the
    // published list keeps the older single-channel registration working: nothing is worse off
    // if a caller has not wired the second one yet.
    let named = BuiltinToolProviders.namedTools(forLibraryId: BaseLibrary.libraryId)
    if provided.isEmpty {
      self.toolList = [
        BuiltinPlaceholderTool(id: BaseLibrary.pokeToolId),
        BuiltinPlaceholderTool(id: BaseLibrary.editToolId),
        BuiltinPlaceholderTool(id: BaseLibrary.wiringToolId),
        BuiltinPlaceholderTool(id: BaseLibrary.textToolButtonId),
        BuiltinPlaceholderTool(id: BaseLibrary.menuToolId),
      ]
    } else {
      self.toolList = provided
    }
    self.textAdder =
      named[BaseLibrary.textToolId]
      ?? provided.first { $0.name == BaseLibrary.textToolId }
      ?? BuiltinPlaceholderTool(id: BaseLibrary.textToolId)
    super.init()
    setHidden()
  }

  // Upstream `_ID`s. Do not change: they are how `.circ` names these tools.
  public static let pokeToolId = BaseToolIds.poke
  public static let editToolId = BaseToolIds.edit
  public static let wiringToolId = BaseToolIds.wiring
  public static let textToolButtonId = BaseToolIds.textTool
  public static let menuToolId = BaseToolIds.menu
  /// `com.cburch.logisim.tools.SelectTool._ID`. Not published by `getTools()`; named here
  /// because the pre-2.3.0 toolbar repair matches on it.
  public static let selectToolId = BaseToolIds.select
  /// `com.cburch.logisim.std.base.Text._ID`: the component factory, not the Text *Tool*.
  public static let textToolId = BaseToolIds.textFactory

  public override var displayName: String { "Base" }
  public override var tools: [Tool] { toolList }

  /// 4.1.0's `getTool(String)`: `super.getTool(name)`, then `Text._ID` and nothing else. The
  /// `Image` branch that used to follow was main's, see the type comment.
  public override func tool(named name: String) -> Tool? {
    if let found = super.tool(named: name) { return found }
    if name == BaseLibrary.textToolId { return textAdder }
    return nil
  }

  /// `BaseLibrary.contains(ComponentFactory)`: `super.contains(query) || query instanceof Text`.
  ///
  /// The second arm cannot be reached through `indexOf`, because `textAdder` is deliberately
  /// absent from `tools`. `XmlWriter.findLibrary` asks a library whether it owns a component's
  /// factory in order to write the right `lib=` handle, so without it every `<comp name="Text">`
  /// is unattributable and `fromComponent` drops it.
  ///
  /// Expressed as identity against `textAdder`'s own factory rather than as a type test: this
  /// module cannot name `com.cburch.logisim.std.base.Text`, and the factory is a singleton, so
  /// the two are the same question. D4: reference identity, matching `indexOf`'s own `===`.
  public override func contains(_ query: any ComponentFactory) -> Bool {
    if super.contains(query) { return true }
    if let adder = textAdder as? AddTool, adder.factory === query { return true }
    return false
  }
}

// MARK: - TextTool

/// `com.cburch.logisim.tools.TextTool`, reduced to the half the `.circ` codec depends on.
///
/// It exists here, rather than with the interactive tools at M7, because **it is the only tool
/// in `#Base` that has an attribute set**, and that single fact decides bytes in every saved
/// file. Upstream:
///
/// ```java
/// attrs = Text.FACTORY.createAttributeSet(); // TextTool.java:137
/// public AttributeSet getAttributeSet() { return attrs; }
/// public Object getDefaultAttributeValue(Attribute<?> attr, LogisimVersion ver) {
///   return Text.FACTORY.getDefaultAttributeValue(attr, ver); // TextTool.java:141
/// }
/// ```
///
/// Both halves are load-bearing and neither is optional:
///
/// * Without the attribute set the reader has nowhere to put `<a name="font" …/>`, so D8 keeps
///   the raw element and re-emits it with its stale `lib=` handle and every attribute it
///   arrived with: including the three the oracle suppresses.
/// * Without the defaults `Tool.getDefaultAttributeValue`'s `null` makes
///   `addAttributeSetContent` write **every** attribute, since its first write condition is
///   `dflt == null`. The oracle writes `font` alone, because `TextAttributes`' default font is
///   `StdAttr.DEFAULT_LABEL_FONT`, SansSerif **bold 16**, while the value in a legacy file is
///   SansSerif plain 12. `text`, `halign`, `valign` and `color` all match their defaults and are
///   dropped. Getting this wrong is invisible in a canonical round trip, where the input already
///   carries whatever the writer emits, and shows up only against a legacy source.
///
/// `cloneTool()` is not overridden, matching upstream: `Tool.cloneTool()` returns `this`, so the
/// toolbar entry and the `<lib>` entry are the *same object* and always agree. That is directly
/// visible in the corpus, across 539 baselines the `<toolbar>` Text Tool and the `<lib
/// desc="#Base">` Text Tool carry an identical attribute list in every single file.
public final class TextTool: Tool {
  public override class var toolId: String { BaseLibrary.textToolButtonId }

  /// `Text.FACTORY`. Held so `defaultAttributeValue` can forward to it, exactly as upstream's
  /// override does.
  public let textFactory: any ComponentFactory
  private let attrs: any AttributeSet

  public init(textFactory: any ComponentFactory) {
    self.textFactory = textFactory
    self.attrs = textFactory.createAttributeSet()
    super.init()
  }

  public override var attributeSet: (any AttributeSet)? { attrs }
}

/// Stand-in for a builtin tool whose real implementation lands with its component tranche.
///
/// It carries the correct `_ID` and nothing else, which is exactly what resolving a `<lib>`
/// declaration and a `<toolbar>`/`<mappings>` reference requires.
public final class BuiltinPlaceholderTool: Tool {
  private let identifier: String

  public init(id: String) {
    self.identifier = id
    super.init()
  }

  public override var name: String { identifier }
}

// MARK: - Builtin

/// `com.cburch.logisim.std.Builtin`.
///
/// One instance per `Loader`, matching upstream (`Loader` holds `private final Builtin
/// builtin = new Builtin()`), which is why two loaders never share library object identity.
public final class Builtin: Library {
  public override class var libraryId: String { "Builtin" }

  private let libs: [Library]

  public override init() {
    // Order is upstream's, and it is observable: `getLibrary(name)` is a linear search and
    // `LibraryManager.getBuildinNames` returns them in this sequence.
    //
    // The `displayName`s are the SECOND column and are not decoration: these shells, not the
    // `Library` subclasses in `LogisimStd`, which are registered only as tool providers, are
    // the objects the explorer sidebar renders as its group headers, and `--tty stats` prints
    // one per row. They are `Library.getDisplayName()`, which upstream overrides per library
    // and which is NOT the `_ID` below: five of these fourteen differ, and every one of the
    // five was wrong here. Measured against the jar by `tools/valuebridge/NameBridge.java`
    // (output committed at `tools/valuebridge/names-4.1.0.tsv`); pinned by
    // `LogisimStdTests/DisplayNameOracleTests.libraryDisplayNames`, which walks all fifteen
    // rows including this class's own "Built-In".
    libs = [
      BaseLibrary(),
      BuiltinLibraryShell(id: Builtin.gatesId, displayName: "Gates"),
      BuiltinLibraryShell(id: Builtin.wiringId, displayName: "Wiring"),
      BuiltinLibraryShell(id: Builtin.plexersId, displayName: "Plexers"),
      BuiltinLibraryShell(id: Builtin.arithmeticId, displayName: "Arithmetic"),
      BuiltinLibraryShell(id: Builtin.fpArithmeticId, displayName: "Floating Point Arithmetic"),
      BuiltinLibraryShell(id: Builtin.memoryId, displayName: "Memory"),
      BuiltinLibraryShell(id: Builtin.ioId, displayName: "Input/Output"),
      BuiltinLibraryShell(id: Builtin.ttlId, displayName: "TTL"),
      BuiltinLibraryShell(id: Builtin.hdlId, displayName: "HDL-IP"),
      BuiltinLibraryShell(id: Builtin.tclId, displayName: "TCL"),
      BuiltinLibraryShell(id: Builtin.bfhId, displayName: "BFH mega functions"),
      BuiltinLibraryShell(id: Builtin.extraIoId, displayName: "Input/Output Extra"),
      BuiltinLibraryShell(id: Builtin.socId, displayName: "System On a Chip"),
    ]
    super.init()
  }

  // The fourteen upstream `_ID`s, verbatim. A `.circ` descriptor is "#" + one of these, so a
  // single wrong character here fails an entire file with a "built-in library is not
  // available" error that looks like a file-format bug.
  public static let baseId = BaseLibrary.libraryId          // "Base"
  public static let gatesId = "Gates"
  public static let wiringId = "Wiring"
  public static let plexersId = "Plexers"
  public static let arithmeticId = "Arithmetic"
  public static let fpArithmeticId = "FPArithmetic"
  public static let memoryId = "Memory"
  public static let ioId = "I/O"
  public static let ttlId = "TTL"
  public static let hdlId = "HDL-IP"
  public static let tclId = "TCL"
  public static let bfhId = "BFH-Praktika"
  public static let extraIoId = "Input/Output-Extra"
  public static let socId = "Soc"

  /// Every builtin id, in upstream order. `"#" + id` is the file descriptor.
  public static let allLibraryIds: [String] = [
    baseId, gatesId, wiringId, plexersId, arithmeticId, fpArithmeticId, memoryId, ioId,
    ttlId, hdlId, tclId, bfhId, extraIoId, socId,
  ]

  /// Every builtin descriptor, in upstream order.
  public static let allDescriptors: [String] = allLibraryIds.map { "#" + $0 }

  public override var displayName: String { "Built-In" }
  public override var libraries: [Library] { libs }
  public override var tools: [Tool] { [] }

  /// Java `getLibrary(String)`; `Loader.loadLibrary` calls this for a `#Name` descriptor and
  /// treats nil as "built-in library not available in this version".
  public override func library(named name: String) -> Library? {
    libs.first { $0.name == name }
  }

  /// Java `LibraryManager.getBuildinNames(Loader)`.
  public var libraryNames: Set<String> { Set(libs.map(\.name)) }

  /// Identity test used by `LibraryManager.getDescriptor`, which asks
  /// `loader.getBuiltin().getLibraries().contains(lib)`. D4: reference identity, never
  /// structural equality.
  public func containsLibrary(_ query: Library) -> Bool {
    libs.contains { $0 === query }
  }
}
