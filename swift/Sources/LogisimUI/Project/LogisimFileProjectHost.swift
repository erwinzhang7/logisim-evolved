// LogisimFileProjectHost.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.proj.Project as the window sees it, plus
// the parts of gui/main/Frame that translate model state into what the explorer, the attribute
// table and the simulate menu show), https://github.com/logisim-evolution/logisim-evolution.
// Copyright by the Logisim-evolution developers. This translation is a derivative work and is
// therefore GPL-3.0-only. See LICENSE.md.
// SPDX-License-Identifier: GPL-3.0-only
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// THE REAL PROJECT HOST.
//
// This replaces `DemoProjectHost`. That object was the executable specification of
// `ProjectHost`, every member implemented the way the real one should be, with fake data behind
// it, and it did its job: the shell was launchable and clickable before either the codec or the
// renderer had landed. What it was not was a project. It fabricated a twelve-library outline out
// of literals, a four-circuit list out of literals, an attribute table out of literals with an
// override dictionary behind it, and a simulation status that set `achievedTickHz =
// requestedTickHz`, which is precisely the `TickCounter` behaviour D7 exists to eliminate.
//
// Everything here comes from a loaded `LogisimFile`:
//
//   • the explorer     : `LogisimFile.circuits`, `.vhdlContents`, `.libraries` and each
//                         library's own `tools` (`ProjectOutlineBuilder`)
//   • the canvas       ; the host owns the file and hands the selected `Circuit` to
//                         `CircuitCanvasSurface.setCircuit(_:)`, the entry point the canvas
//                         author left for exactly this
//   • the inspector    : the selected component's real `AttributeSet`, edited through
//                         `CircuitMutation` so it lands on the undo stack
//                         (`InspectorProjection`)
//   • undo / redo      : the ported `Project`'s `Action`/`JoinedAction` stack, with
//                         `shouldAppendTo` coalescing
//   • simulation       : the D7 phase-anchored clock driving the real propagation core
//                         (`SimulationEngine`)
//   • save             : the real `XmlWriter`, through `LogisimFile.write`
//
// ── D3: the back edges, and why each is weak ────────────────────────────────────────────────
//
// | edge                              | here     | why                                        |
// |-----------------------------------|----------|--------------------------------------------|
// | host → `LogisimFile`              | strong   | the document owns its file                 |
// | host → `Project`                  | strong   | the window owns one open project           |
// | host → `SimulationEngine`         | strong   | and the engine owns the clock              |
// | host → `CircuitCanvasSurface`     | **weak** | `EditorModel` owns the surface it was      |
// |                                   |          | vended; a strong edge here plus the        |
// |                                   |          | model's own `let surface` would pin the    |
// |                                   |          | whole render scene for the process's life  |
// | `Project.frame` / `.canvas`       | **weak** | already so in `Project`; not re-taken here |
// | observers (shell → host)          | token    | `ProjectObservation` holds the closure, |
// |                                   |          | the host holds the token weakly: dropping |
// |                                   |          | the token unsubscribes                     |
// | circuit/attribute listeners       | token    | same shape; `WeakListenerList` upstream    |
//
// The engine's callback runs the other way (engine → host) and is a closure capturing `self`
// **weakly**, because the engine outlives nothing but is retained by the host: a strong capture
// would be an unconditional cycle on every open document.
// ═════════════════════════════════════════════════════════════════════════════════════════════

import AppKit
import CoreGraphics
import Foundation
import LogisimAnalyze
@preconcurrency import LogisimFile
import LogisimHdl
import LogisimHdlWiring
import LogisimKernel
import LogisimSoc
import LogisimStd
@preconcurrency import LogisimVhdl
import UniformTypeIdentifiers

// MARK: - Factory

/// The real `ProjectHostFactory`. Installed by the app at launch through
/// `LogisimUI.install(projectHostFactory:)`, and used directly by the tests.
@MainActor
public final class LogisimFileProjectHostFactory: ProjectHostFactory {

  public init() {}

  /// `StdLibraries.registerAll()` materialises each `BuiltinLibraryShell`'s tool list on first
  /// use and caches it, so it must run before the first load and exactly once.
  ///
  /// `#Soc` is the one registration `StdLibraries.registerAll()` genuinely cannot make: its
  /// factories live in `LogisimSoc`, which depends on `LogisimStd`, so *that* arrow cannot point
  /// back. It is made here instead, by the layer above both.
  ///
  /// ── THIS COMMENT USED TO SAY THE APP "CANNOT BE MADE TO" MAKE THE CALL. IT WAS RIGHT, THEN ──
  ///
  /// The old text read: "the app executable must do the same, and cannot be made to from inside
  /// `LogisimUI`, which does not link `LogisimSoc`. Until it does, a `#Soc` component loads as a
  /// D8 placeholder: visible and round-tripped, but not itself." That was an accurate
  /// description of a live defect, and it stayed accurate for a milestone, because a `cannot`
  /// reads as settled and nobody re-tests it. The `Text` painter went missing the same way.
  ///
  /// The reason expired on 2026-09-06 when `LogisimUI` gained the `LogisimSoc` edge, and the
  /// prediction was correct in every particular right up to that moment. Measured on a four
  /// component `.circ` opened through `openProject`, the app's own entry point, with the edge
  /// present but this line absent:
  ///
  /// ```
  /// components: 4 × UnresolvedComponent (SocBus, Socmem, SocPio, Rv32im)
  /// ends: 0 each        → nothing can be wired to them
  /// bounds: empty         → nothing can hit-test them
  /// unresolvedTargets: [0, 1, 2, 3]  → the canvas draws the D8 dashed box over all four
  /// paintedComponents: 0 of 4        prims: 0
  /// explorer tools: 0 of 8 under "System On a Chip"
  /// SocBus fabric: none          → a memory read falls through to rand.nextInt()
  /// ```
  ///
  /// `SocRegistrationTests` is that measurement, kept. Deleting the call below restores every
  /// line of it.
  private static var librariesRegistered = false

  /// Held for the WHOLE of `registerBuiltinLibrariesIfNeeded`, not just around the flag.
  ///
  /// **The flag used to be set BEFORE the work, and that is a publish-before-initialise race.**
  /// Thread A passed the guard, set `librariesRegistered = true`, and began registering; thread B
  /// saw `true`, returned immediately, and went on to load a `.circ` while `#Soc` was still
  /// unregistered, so every SoC component came back as a D8 `UnresolvedComponent`.
  ///
  /// It is invisible to a single-threaded run, which is why `SocRegistrationTests` was 8/8 under
  /// `--filter` and failed with sixteen issues in a full `swift test`: Swift Testing runs suites
  /// in parallel, and two of them calling `makeEmptyProject()` at once is all it takes.
  ///
  /// `NSRecursiveLock` because `StdLibraries.registerAll()` can reach back through a library's
  /// lazy tool list into this path; a plain `NSLock` would deadlock on that rather than racing.
  private static let registrationLock = NSRecursiveLock()

  static func registerBuiltinLibrariesIfNeeded() {
    registrationLock.lock()
    defer { registrationLock.unlock() }
    // Checked INSIDE the lock, and set at the END: a second caller now blocks until registration
    // has actually finished rather than being told it is done while it is still running.
    guard !librariesRegistered else { return }
    StdLibraries.registerAll()

    // The eight `com.cburch.logisim.soc.*` factories, the same call `logisim-cli/main.swift`
    // makes at its own startup. **A registration living in one executable's startup is a
    // registration the other executable silently lacks**; that is why these two lists must stay
    // in step, and it is exactly how this one came to be missing for a milestone.
    //
    // Must precede the first load: a `BuiltinLibraryShell` materialises its tool list once, on
    // first use, and caches it thereafter. `Builtin` already declares a shell for `Soc`, so
    // without this the `<lib desc="#Soc">` *resolves* and every `<tool>` under it does not,
    // which is why the failure presents as D8 placeholders rather than as a missing library.
    SocLibrary.registerBuiltinTools()

    // The 40 per-component HDL generators. Same rule as the two above and the same shape one
    // layer up: the bindings need both `LogisimStd` and `LogisimHdl`, neither may depend on the
    // other, so `LogisimHdlWiring` sits above both and whoever links a runtime makes the call.
    //
    // An unpopulated `HdlGeneratorLookup` answers `nil` for every component and would present as
    // "nothing in this design is synthesizable" rather than as an error.
    BuiltinHdlWiring.installBuiltins()

    // Every pure seam assignment, in one function so a caller can install the joins without
    // also performing the once-per-process registrations. See `installProcessSeams`.
    installProcessSeams()

    // Last, so nothing can observe a half-registered process. See `registrationLock`.
    librariesRegistered = true
  }

  /// Every **pure seam assignment** this runtime makes; the closures and handlers that lower
  /// layers declare and cannot fill in themselves.
  ///
  /// Split out of `registerBuiltinLibrariesIfNeeded` so the two kinds of work can be told apart
  /// and asked for separately. What is left in that function *registers*: it mints factories and
  /// materialises tool lists, it must happen exactly once, and running it twice is board #67.
  /// What is in here is idempotent assignment and nothing else.
  ///
  /// The distinction is not cosmetic. `syntaxCheckerMatchesTheJavaOracle` needs to measure the
  /// closure the application installs into `AnalyzeSyntaxChecker.hdlKeywordCheck`, and calling
  /// `registerBuiltinLibrariesIfNeeded` to get it would set `librariesRegistered` from a suite
  /// that has no business doing so: after which any LATER caller's registration is a silent
  /// no-op. Measured: doing exactly that turned three `VhdlAdaptorTests` cases red in a full
  /// `swift test` (`vhdlContents` empty, `file.tool(named:)` nil, `offsetBounds` a 0×0 sentinel)
  /// while every one stayed green under `--filter`, because `LogisimFileTests` wipes
  /// `LogisimFileSeams` process-wide and the once-only guard meant the seams could never come
  /// back.
  ///
  /// Under the same lock, so a caller cannot observe a half-installed set.
  static func installProcessSeams() {
    registrationLock.lock()
    defer { registrationLock.unlock() }

    // `CircuitTransaction.wireRepair`; board #22. Called once in `CircuitTransaction.execute`
    // and, until now, assigned NOWHERE in Sources or Tests, so the editor never repaired wires.
    //
    // **The user-visible consequence: drop a component onto a wire and it was not connected.**
    // `CircuitPoints.add(Wire)` records only `getEnd0()`/`getEnd1()`, so a segment drawn *through*
    // a port is not connected to it until `doSplits` cuts it there. The same cause produced the
    // last four M3 simulation failures and the unexplained `2.7.2__case-432.circ` netlist divergence, both
    // closed when the load path stopped gating this pass behind an environment variable.
    //
    // Routed through the mutator, NOT applied directly. The tempting one-liner is
    // `{ circuit, _ in WireRepair(circuit: circuit).run() }` and it is wrong: `run()` edits the
    // circuit straight through `mutatorAdd`/`mutatorRemove`, which is right for the load path it
    // was written for and would mean an editor repair never enters the `ReplacementMap`, so
    // undo would leave the cuts behind.
    CircuitTransaction.wireRepair = { circuit, mutator in
      // MODULE-QUALIFIED: `WireRepair` here would resolve to `LogisimUI`'s PROTOCOL -- the
      // "can this component absorb a loose wire end" feature -- not `LogisimFile`'s repair pass.
      // Two unrelated upstream classes share the name (`com.cburch.logisim.circuit.WireRepair`
      // and `com.cburch.logisim.tools.WireRepair`), and `ToolFeatures.swift` already records that
      // they cannot live in one module for exactly this reason. And `LogisimFile.WireRepair`
      // does NOT disambiguate it: `LogisimFile` is a class as well as a module, so Swift reads that
      // as a member lookup. Hence the exported alias. Third same-name ambiguity to bite today.
      try CircuitWireRepairPass(circuit: circuit).run { replacements in
        let map = ReplacementMap()
        for (wire, pieces) in replacements {
          try map.remove(wire)
          for piece in pieces { try map.add(piece) }
        }
        try mutator.replace(circuit, map)
      }
    }

    // The two appearance seams; board #25. Same shape as `wireRepair` above and installed
    // beside it deliberately: all three are `CircuitTransaction.execute`'s hooks and a reader
    // looking for one should find the others without grepping.
    //
    // Both resolve to `CircuitSubcircuitFactory.refreshPortsAfterSourceChanged()`, which is this
    // port's `PortManager.updatePorts`: `appearance.invalidate()` to drop the cached layout,
    // then `computePorts` over every live placement.
    //
    // ── WHICH HALF WAS ACTUALLY BROKEN, MEASURED ────────────────────────────────────────────
    //
    // `appearanceRecompute` fixes a live defect and `appearanceHook` does not, and it is worth
    // being precise about which is which because the obvious guess is backwards.
    //
    // `CircuitMutatorImpl.setForCircuit` queues a recompute for two attributes. `nameAttribute`
    // already had a route home, `CircuitStaticAttributeListener` fires `.setName`,
    // `observeSource` handles it, so a rename redrew correctly before this line existed.
    // `namedCircuitBoxFixedSize` had none: its event, `.changeDefaultBoxAppearance`, is declared
    // in `CircuitEvent` and handled in `observeSource` and **fired nowhere in Sources or Tests**.
    // Toggling it moved the drawn box, because `offsetBounds` reads the attribute live, and left
    // the placement's ends at the old box's edge: measured as a west port 150px inside its own
    // box, ends `[(230,300),(300,300)]` against an oracle's `[(80,300),(300,300)]`.
    //
    // `appearanceHook` is upstream's `CircuitPins.transactionCompleted(repl)`. For an editor edit
    // it is redundant: `mutatorAdd`/`mutatorRemove` fire `.add`/`.remove` and `observeSource`
    // has already recomputed by the time `run` returns. It is installed because it is upstream's
    // guarantee and because the incremental listeners are what could regress: not because it
    // repairs anything visible today. `AppearanceRecomputeSeamTests` states that in a test.
    CircuitTransaction.appearanceHook = { circuit, _ in
      (circuit.subcircuitFactory as? CircuitSubcircuitFactory)?.refreshPortsAfterSourceChanged()
    }
    CircuitTransaction.appearanceRecompute = { circuit in
      (circuit.subcircuitFactory as? CircuitSubcircuitFactory)?.refreshPortsAfterSourceChanged()
    }

    // ── `CircuitTransaction.transactionDone`: the fourth of `execute()`'s hooks ─────────────
    //
    // Installed beside its three siblings, permanently, because upstream delivers the
    // `ReplacementMap` **after every transaction** and the port used to deliver it at one call
    // site. `Selection(Project, Canvas)` registers `myListener` with `Project.addCircuitListener`
    // (4.1.0 bytecode offset 48) and that list is consulted by every `TRANSACTION_DONE`, so the
    // move path, the redo path, wire repair, paste and delete are all covered by one
    // registration and anything added later is covered without being noticed.
    //
    // **Why the previous, scoped install was not enough**, and this is measured, not argued.
    // `SelectTool.commitMove` wrapped the seam around its own `project.perform`. `Project
    // .redoAction` re-executes the cached `xnForward` (`SelectionActions
    // .SelectedComponentsAction.redo`), which is nowhere near `commitMove`, so after
    // place → drag → undo → redo the circuit held `Pin @ (160,100)` and the selection held
    // `Pin @ (100,100)`: the highlight painted over empty canvas, and a press there dragged a
    // phantom and committed it as an add (1 → 2). The delete/undo/redo version of the same hole
    // resurrected a deleted component into an empty circuit (0 → 1). Scoping the install around
    // `redoAction` as well would have been whack-a-mole; there is one list upstream, so there is
    // one install here.
    //
    // **Why a registry and not an assignment per canvas.** The slot is a single closure, so a
    // canvas that assigned it would either clobber its neighbour or chain onto it. Chaining is
    // what `commitMove` did and it is right for a scoped call and wrong for a permanent one: a
    // long test run builds thousands of canvases, so the chain becomes O(n) per transaction and
    // every link retains the selection it closed over. `CircuitTransactionObservers` holds weak
    // entries instead and is bounded by the number of live selections.
    //
    // `assumeIsolated`, and the same reasoning as `LoadedLibrary.replacementHandler` below: the
    // seam is `@Sendable` because `CircuitTransaction` has no isolation, every caller of
    // `execute()` in this tree is on the main actor (the load path uses `CircuitLoadMutator` and
    // never reaches here), and the delivery MUST be synchronous; a deferred hop would let the
    // canvas paint one frame with the pre-transaction selection, which is the "preview in
    // completely wrong places" symptom this whole change exists to remove.
    // `onMainActor`, NOT `MainActor.assumeIsolated`. This landed as `assumeIsolated` and would
    // have been the module's FOURTH independent rediscovery of the same mistake: the helper 1,450
    // lines below says so in as many words, and `ToolListenerIsolationTests` exists only because
    // this exact defect had to be fixed in `PokeTool`, `TextTool` and `EditTool`.
    //
    // Why it matters HERE specifically, where the three sibling seams get away with being
    // isolation-agnostic: `Project.swift:112-117` records that the transaction substrate
    // (`CircuitTransaction`, `CircuitLocker`, `CircuitMutator`, `CircuitChange`, `ReplacementMap`)
    // is deliberately NOT `@MainActor` **because upstream takes real per-circuit locks there
    // precisely so a transaction can run off the EDT**. `execute()` is a nonisolated method on a
    // nonisolated open class. While this slot was nil outside a scoped main-actor window, an
    // off-main `execute()` was harmless; installing an assertion here makes it fatal.
    //
    // And fatal is literal. `assumeIsolated` off the main thread traps the whole process with
    // `EXC_BREAKPOINT` and **no test failure is reported, because the test binary dies with it**:
    // measured on this very closure: with the seam parked, an off-main `execute()` passes; with it
    // installed, `swiftpm-testing-helper` exits on signal 5 having reported zero tests.
    //
    // `onMainActor` satisfies the synchronous requirement that motivated the assertion: its fast
    // path checks a `DispatchSpecificKey` marker and calls straight through when genuinely on the
    // main queue, so a main-actor transaction still delivers before the next frame. Only an
    // off-main transaction defers, and an off-main transaction cannot be delivered synchronously
    // to a `@MainActor` selection anyway, so the choice there is between a hop and a crash.
    CircuitTransaction.transactionDone = { result in
      let boxed = UncheckedSendableBox(result)
      onMainActor { CircuitTransactionObservers.broadcast(boxed.value) }
    }

    // `<vhdl>` parsing, the same cross-module shape: `LogisimFile` owns the codec seams,
    // `LogisimVhdl` owns the model, and neither lower layer may depend on the other, so the
    // shipping runtime is the one place that sees both. The `guard` keeps D8 intact; a `<vhdl>`
    // element that will not parse still round-trips verbatim rather than being dropped.
    //
    // RESTORED 2026-09-06 with the lost-placement defect fixed. It was withdrawn because a
    // fixture placing one entity twice loaded as three components instead of four. The cause was
    // NOT this installation and not `mutatorAdd`: `VhdlEntityAdaptor` inherited
    // `AbstractComponentFactory.offsetBounds`, which returns the `Bounds.empty` SENTINEL, and
    // `Bounds.empty.translate` returns itself: so every placement, at any location, reported the
    // identical zero-area bounds and `buildCircuit`'s exact-overlap map collapsed them. See
    // `VhdlEntityAdaptor.offsetBounds`.
    LogisimFileSeams.makeVhdlEntity = { content in
      guard let content = content as? VhdlContent else {
        return PreservedVhdlEntityFactory(content: content)
      }
      return VhdlEntityAdaptor(content: content)
    }
    // ── ASSIGNED ONLY ONCE, unlike the closure above, and the difference is allocation ───────
    //
    // `installProcessSeams` runs on EVERY host construction by design; that is what makes the
    // seams above survive a `LogisimFileSeams.removeAll()`. Re-asserting a closure is free. This
    // line is not: `VhdlContent.create` builds a **new** `VhdlContent` and fills its template
    // every call (VhdlContent.swift:169-175), so an unconditional assignment swaps the
    // process-global handler for a fresh object while other suites may be mid-load holding the
    // previous one. Under the lock, so not a data race: object identity churning beneath
    // concurrent readers, which is the same shape as board #67.
    //
    // Measured in an integration worktree, full `swift test`, no corpus: 0 failures of this
    // family in 3 runs on `swift-port`, 3 in 6 with this branch: surfacing as
    // `LibraryDropDivergenceTests` once and `StatsVhdlEntityTests` twice, two faces of one
    // order-dependent flake.
    //
    // And the restore this was protecting never applied to it: `LogisimFileSeams.removeAll()`
    // clears `makeVhdlEntity` and `projectNameInUse` only, and NOTHING in Sources or Tests ever
    // clears `VhdlContentReader.handler`. The nil-check keeps the restore path honest if that
    // ever changes, without paying for it on every call.
    if VhdlContentReader.handler == nil {
      VhdlContentReader.handler = VhdlContent.create(name: "VHDL")
    }

    // ── Board #64: six seams that were READ and never ASSIGNED ─────────────────────────────
    //
    // Same rule as everything above: a seam whose join lives nowhere is not a seam, it is a
    // feature that is switched off. Installed here because this function is the only place in
    // the tree that installs a process-global seam, so all of them are findable at once.

    // `Project.toolChangeHook` and `Project.circuitSwitchHook`; the canvas halves of
    // `Project.setTool` and `setCircuitState`. The first is data-loss-shaped: without it a
    // pasted, still-floating selection is never anchored, and the next `clear` discards it with
    // nothing on the undo stack. See `ProjectCanvasHooks`.
    ProjectCanvasHooks.install()

    // `Buzzer.audioSinkFactory`; a placed Buzzer computes its waveform and throws it away.
    // `nil` is the CORRECT default (board #25 hoisted AVFoundation out of `LogisimStd` and it
    // must stay out), so the sink is a `LogisimUI` type and the JOIN is made here, in the one
    // process that has a UI to make noise in.
    Buzzer.audioSinkFactory = { BuzzerAudioEngineSink() }

    // `Tty.sendFromTtyHook`; upstream's `TtyInterface.sendFromTty` is a plain static, so in
    // Java it is always available and the `sendStdout` flag alone decides whether a character
    // leaves the process. Here it is a hook that defaulted to nil, which is the right default for
    // a component test but leaves the flag inert everywhere. See `TtyStdoutSink` for what is and
    // is not reachable today.
    Tty.sendFromTtyHook = { TtyStdoutSink.shared.write($0) }

    // ── Board #75: the two remaining platform seams `LogisimStd` declares and cannot fill ─────

    // `Tty.textMeasurer`: upstream sizes a TTY's box from a live `charWidth('W')` on
    // `DEFAULT_FONT`; `Tty.columnWidth` reads this and `Tty.offsetBounds` multiplies it by the
    // column count. Unassigned, it fell back to `Tty.COL_WIDTH`, so the box asserted a constant
    // instead of measuring the font actually resolved. **That constant is 7 and the jar's
    // `charWidth('W')` is also 7**, so this install does NOT change any width today; read
    // `TtyCharWidthMeasurer`'s header before "simplifying" either half, because the obvious
    // measurer (`CoreTextMeasurer`) truncates where `FontMetrics.charWidth` rounds and turns
    // `OffsetBoundsOracleTests` from 0 mismatches to 9.
    //
    // `TextMeasurer` is platform-free (`LogisimRender`) but the CoreText half is not
    // (`LogisimRenderBackend`), so the join is here for the same D9 reason the buzzer's is. See
    // `TtyTextMeasurer` for why it is a shared `static let` rather than a fresh instance on each
    // call of this function.
    //
    // Assigned inline, beside its four siblings. It could not be until 2026-09-06: unlike them,
    // `Tty.textMeasurer` was not declared `nonisolated(unsafe)`, so writing it from this Swift 6
    // module was a hard compile error, which is *why* it was never installed. The declaration
    // now carries it and the `@preconcurrency` shim that stood here has been deleted.
    Tty.textMeasurer = TtyTextMeasurer.shared

    // `TelnetServer.transportFactory`: upstream's `new ServerSocket(port)`, hoisted out of
    // `LogisimStd` when board #25's sweep took `import Network` with it. Assigned in Tests only,
    // so the suite was green and the product was unwired: a Telnet component in the shipped app
    // took the documented headless branch, "the model runs, nothing listens", and never opened
    // a socket, whatever port the user configured.
    //
    // `throws`, and that is upstream's shape too: `new ServerSocket` throws `IOException` on a
    // port already in use, `Telnet.getData` rethrows, and `Simulator` reports it as a circuit
    // error. `TelnetNetworkTransport.init` blocks until the listener is ready or has failed for
    // exactly that reason: see its header for the threading argument.
    //
    // Same story as `textMeasurer` above: the declaration was missing `nonisolated(unsafe)`, so
    // this assignment could not be written here at all.
    TelnetServer.transportFactory = { port in
      try TelnetNetworkTransport(port: port)
    }

    // `LoadedLibrary.replacementHandler`: a library reload computes a full old→new map of
    // factories and tools and hands it to nobody, so every already-placed component keeps
    // pointing at the factory from the file that was just replaced. See `LibraryReplacementApply`.
    // `assumeIsolated` for the same reason `ProjectLibraryListener.libraryChanged` uses it:
    // `LoadedLibrary` compiles below the Swift-6 line (D1) so its hook cannot be declared
    // isolated, and the rewrite must happen synchronously inside `setBase`; a deferred hop would
    // let the explorer paint one frame against the new library with the old components still
    // placed.
    LoadedLibrary.replacementHandler = { replacement in
      let boxed = UncheckedSendableBox(replacement)
      MainActor.assumeIsolated { LibraryReplacementApply.apply(boxed.value) }
    }

    // `AnalyzeSyntaxChecker.hdlKeywordCheck`: a DOCUMENTED divergence rather than an oversight:
    // unset, the CSV importer accepts a variable named `signal` or `wire` that upstream rejects.
    // `CorrectLabel` lives in `LogisimHdl`, which `LogisimAnalyze` must not depend on, so the
    // join belongs to whoever links both. The types line up exactly, `HdlLanguage` is a
    // `String`-raw-valued enum whose cases are the two strings `AnalyzeSyntaxChecker:83` compares
    // , so no adapter is needed, only the explicit `LogisimUI -> LogisimHdl` edge in
    // `Package.swift` (LogisimUI reached LogisimHdl only transitively, through LogisimHdlWiring).
    AnalyzeSyntaxChecker.hdlKeywordCheck = { CorrectLabel.hdlCorrectLabel($0)?.rawValue }

  }

  /// File ▸ New.
  ///
  /// Upstream's `ProjectActions.doNew` *opens the default template*; `LogisimFile.createNew` is
  /// a bare file with no libraries at all, and a document with no libraries cannot save a
  /// component (`XmlWriter.fromTool` cannot resolve its factory). See
  /// `NewProjectTemplate.swift`. The fallback below is that bare file, and is reachable only if
  /// the template itself fails to parse: a build defect, not user input, so it is reported and
  /// survived rather than trapped.
  public func makeEmptyProject() throws -> any ProjectHost {
    Self.registerBuiltinLibrariesIfNeeded()
    let loader = Loader()
    do {
      if let file = try loader.openLogisimFile(data: NewProjectTemplate.data) {
        return LogisimFileProjectHost(file: file, loader: loader, fileURL: nil, issues: [])
      }
      throw ProjectHostError.notImplemented("the new-project template produced no project")
    } catch {
      let file = try LogisimFile.createNew(loader: loader)
      return LogisimFileProjectHost(
        file: file, loader: loader, fileURL: nil,
        issues: [
          UserFacingIssue(
            severity: .warning,
            title: "The new-project template could not be loaded",
            detail: "\(error)\n\nAn empty project was created instead. It declares no "
              + "libraries, so components cannot be placed until one is loaded.")
        ])
    }
  }

  public func openProject(data: Data, url: URL?, contentType: UTType) throws -> any ProjectHost {
    Self.registerBuiltinLibrariesIfNeeded()
    let loader = Loader()
    var issues: [UserFacingIssue] = []

    // Both failure shapes are real and neither may leave a blank window: `openLogisimFile(data:)`
    // **throws** on a malformed document and **returns nil** on one it declines. An earlier
    // version of the canvas-side loader handled only the throw, and a declined file left the
    // canvas empty with no explanation.
    let file: LogisimFile
    do {
      if let loaded = try loader.openLogisimFile(data: data) {
        file = loaded
      } else {
        throw ProjectHostError.notImplemented("the file parsed but contained no project")
      }
    } catch {
      // Opening an unreadable document must not fail the whole open: the user gets an empty
      // project and a message saying what happened and that their bytes were not touched.
      let empty = try LogisimFile.createNew(loader: loader)
      issues.append(
        UserFacingIssue(
          severity: .failure,
          title: "Could not read this file",
          detail: "\(error)\n\nA new empty project was opened instead. The file on disk has "
            + "not been modified."))
      return LogisimFileProjectHost(file: empty, loader: loader, fileURL: url, issues: issues)
    }

    issues.append(contentsOf: LogisimFileProjectHost.loadIssues(for: file))
    issues.append(contentsOf: LogisimFileProjectHost.loaderIssues(from: loader))
    return LogisimFileProjectHost(file: file, loader: loader, fileURL: url, issues: issues)
  }

  public var readableContentTypes: [UTType] { LogisimDocumentType.readable }
  public var writableContentTypes: [UTType] { [LogisimDocumentType.circuit] }
}

// MARK: - Host

@MainActor
final class LogisimFileProjectHost: ProjectHost, CanvasInteractionHandler, SaveConfirming {

  // MARK: Owned model

  let file: LogisimFile
  private let loader: Loader
  let project: Project
  /// Internal rather than private so the verification suite can assert against the *real*
  /// clock; that `setTickFrequency` moved `SimulationClock.ticksPerSecond` and that a tick
  /// actually advanced `Propagator.tickCount`. A test that could only observe the projected
  /// `SimulationStatus` would pass against a host that faked it, which is exactly what the
  /// object this replaces did.
  let engine: SimulationEngine

  // MARK: Projected state

  private(set) var fileURL: URL?
  private(set) var outline = ProjectOutline()
  private(set) var currentCircuit: CircuitID?
  private(set) var activeTool: ToolID?
  private(set) var selection: EditorSelection = .nothing
  private(set) var simulation = SimulationStatus()

  var displayName: String { file.name }
  var isDirty: Bool { project.isFileDirty }

  var undoStatus: UndoStatus {
    UndoStatus(
      undoStack: project.undoActions.map(\.name),
      redoStack: project.redoActions.map(\.name))
  }

  // MARK: Internal wiring

  private(set) var handles = ProjectHandles()
  /// The editing layer. Built in `makeRenderSurface()` because it needs the surface; `nil` until
  /// then, which is the state every headless test and the CLI stay in.
  private(set) var editorCanvas: CircuitEditorCanvas?
  private var selectionMirror: (any SelectionListener)?
  /// The circuit the canvas is showing. Strong: the file owns it, and this is a second reference
  /// to something already owned, which pins nothing extra.
  private(set) var currentCircuitObject: Circuit?
  /// `ComponentID` → the component, for the inspector and for reveal-in-canvas. Rebuilt whenever
  /// the circuit changes structurally, so a deleted component's ID stops resolving.
  private var componentsByID: [ComponentID: any Component] = [:]

  /// D3: **weak**. `EditorModel` holds the surface it was vended; see the table in the header.
  private weak var surface: CircuitCanvasSurface?

  private var observers: [UUID: @MainActor (ProjectChange) -> Void] = [:]
  private var pendingIssues: [UserFacingIssue] = []

  /// The circuit-change subscription. `Circuit` keeps listeners in a `WeakListenerList`, so an
  /// unstored registration is a subscription that silently stops firing; the project's
  /// most-repeated defect. Storing it here is what keeps it alive.
  private var circuitListener: CircuitListenerClosure?
  private var simulatorAdapter: HostSimulatorAdapter?

  /// Java's `Circuit.socSim` field, which this port cannot reproduce as a stored property: a
  /// Swift extension adds no storage, and `Circuit` lives in `LogisimFile`, below `LogisimSoc`.
  /// `SocCircuitBinder` is the port's answer, it listens to `.add`/`.remove`/`.clear` and
  /// reproduces upstream's three `registerComponent`/`removeComponent` calls exactly, and it is
  /// explicitly session-scoped, so **someone has to own one**. The project host is that owner:
  /// one binder per open document, released with the document, which is the lifetime Java gets
  /// for free from the field.
  ///
  /// Internal rather than private for the same reason `engine` is: the verification suite has to
  /// be able to assert against the *real* fabric. Until this line existed, `SocCircuitBinder`
  /// was constructed by nothing outside `LogisimSocTests`; seam #17 was closed in the model and
  /// still unreachable from every runtime, which is the same shape as the seam it closed.
  let socBinder = SocCircuitBinder()

  // MARK: - Construction

  /// `com.cburch.logisim.proj.Projects.getOpenProjects()`, in miniature.
  ///
  /// Upstream keeps a static list of open projects, maintained by a window listener, and exactly
  /// one thing reads it: `LoadedLibrary.replaceAll`, which has to rewrite every open document
  /// when a library is reloaded underneath it. Nothing else in this port needs it, so this is a
  /// weak registry of live hosts rather than a port of `Projects` and its eight AWT listeners.
  ///
  /// **Weak**, and that is not an optimisation: a strong static list would keep every document
  /// the user ever opened, its file, its circuits, its simulation states, alive for the life of
  /// the process, which is the leak D3's whole table exists to prevent.
  private static var openHosts: [WeakHostRef] = []

  private struct WeakHostRef {
    weak var host: LogisimFileProjectHost?
  }

  /// The live hosts, compacted. Reading is also what prunes, so the array cannot grow without
  /// bound across a long session of opening and closing documents.
  static var liveHosts: [LogisimFileProjectHost] {
    openHosts.removeAll { $0.host == nil }
    return openHosts.compactMap(\.host)
  }

  init(file: LogisimFile, loader: Loader, fileURL: URL?, issues: [UserFacingIssue]) {
    self.file = file
    self.loader = loader
    self.fileURL = fileURL
    self.project = Project(file: file)
    self.engine = SimulationEngine(file: file)
    self.pendingIssues = issues

    let adapter = HostSimulatorAdapter(engine: engine)
    simulatorAdapter = adapter
    project.simulator = adapter

    // The two edit paths now take the same lock. `performOnModel` guards every mutation the host
    // issues; without this, an edit issued by a *tool*, which reaches `Project.doAction` from
    // inside `mouseReleased`, would race the propagation thread. See `Project.modelGuard`.
    //
    // Captured `[engine]`, not `[weak self]`: the guard's whole job is to hold this lock, and a
    // guard that silently became a no-op because the host was deallocating is a data race that
    // only appears under teardown. `Project` holds the closure and the host holds `Project`, so
    // the engine outlives every call.
    project.modelGuard = { [engine] body in
      engine.modelLock.lock()
      defer { engine.modelLock.unlock() }
      try body()
    }

    engine.setObserver { [weak self] snapshot in
      // D1/D3: the engine calls this from the propagation thread, hopped to the main actor by
      // `SimulationEngine.mutateSnapshot`. Weak, because the host owns the engine.
      self?.simulationDidChange(snapshot)
    }

    // Before anything adopts a circuit: `attach(to:)` BACKFILLS, registering every component the
    // circuit already holds in `nonWires` order, which is `mutatorAdd` order, so a file that
    // places a slave before its bus produces exactly the pending-list state a sequential load
    // would have. Attaching after the first edit instead would silently miss everything the file
    // brought with it.
    attachSocBindings()

    rebuildOutline()
    // `Project.setLogisimFile` already selected the main circuit; mirror it here so the canvas,
    // the explorer and the simulation all start pointed at the same thing.
    if let main = project.currentCircuit ?? file.mainCircuit ?? file.circuits.first {
      adopt(circuit: main)
      // Again, because `simulationTree()` needs a current circuit and the first pass ran before
      // there was one. Cheap, and the alternative is a Simulate sidebar that is empty until the
      // user touches something.
      rebuildOutline()
    }
    activeTool = outline.editingTools.first?.id
    if let tool = activeTool.flatMap({ handles.tools[$0] }) {
      project.setTool(tool)
    }
    simulation = engine.snapshot.status

    // Last, and after everything above: the registry is read by `LibraryReplacementApply`, which
    // rewrites this host's circuits, so publishing a half-constructed host would be the same
    // publish-before-initialise shape `registrationLock` exists to prevent.
    Self.openHosts.removeAll { $0.host == nil }
    Self.openHosts.append(WeakHostRef(host: self))
  }

  deinit {
    // The engine's clock owns a thread; its own `deinit` stops it, and the engine is released
    // with the host. Stated so the absence of an explicit teardown here is a decision.
  }

  // MARK: - Load-time issues

  /// D8/D11 in the UI from the first frame: a library we could not resolve is *kept*, listed,
  /// disabled and round-tripped. Upstream drops it and its components silently, permanently, on
  /// the next save: measured in `decisions.md`, D8.
  /// Whatever the `Loader` itself reported while reading, which is otherwise dropped on the
  /// floor; part of board #88.
  ///
  /// ── What this does and does not fix, measured rather than assumed ────────────────────────
  ///
  /// `HeadlessLoaderUI` *records* into arrays and the app never read them, so every
  /// `loader.showError` during a load was swallowed. There are eleven call sites in
  /// `LibraryManager` alone (`:362`–`:462`): a malformed `file#` descriptor, a builtin that is
  /// not registered, a `.jar` library, and the generic load failure.
  ///
  /// **It is NOT the case that the app reported nothing before.** `loadIssues` above already
  /// detects `MissingLibrary` instances and tells the user by name that libraries could not be
  /// resolved and that their components are preserved, which is more than upstream does, since
  /// upstream drops them. That was checked before writing this, because #87 was withdrawn the
  /// same day for exactly the opposite mistake: a correct observation ("the array is never
  /// drained") carrying a wrong consequence ("therefore the user is told nothing").
  ///
  /// So this closes a real hole, the loader's own diagnostics, which name *why* a descriptor
  /// failed, without the two reports duplicating: one is "which libraries are missing", the
  /// other is "what went wrong while reading them".
  ///
  /// Still open on #88, and deliberately not attempted here: `LoaderUI.chooseFile`, upstream's
  /// "please locate this library" repair loop. `HeadlessLoaderUI` cancels it, which turns into
  /// `fileLoadCanceledError`. That needs a real conformer with an `NSOpenPanel` and is a separate
  /// piece of work.
  static func loaderIssues(from loader: Loader) -> [UserFacingIssue] {
    guard let recorder = loader.ui as? HeadlessLoaderUI else { return [] }
    return recorder.errors.map {
      UserFacingIssue(severity: .warning, title: "While reading this file", detail: $0)
    }
  }

  /// Whether any OTHER circuit in the file places `circuit` as a subcircuit; the question
  /// `Dependencies.canRemove` answers upstream. See the `.removeCircuit` arm of `canPerform`.
  private func circuitIsPlacedElsewhere(_ circuit: Circuit) -> Bool {
    for other in file.circuits where other !== circuit {
      for component in other.nonWires {
        if let factory = component.factory as? any SubcircuitFactory,
          factory.subcircuit as? Circuit === circuit
        {
          return true
        }
      }
    }
    return false
  }

  static func loadIssues(for file: LogisimFile) -> [UserFacingIssue] {
    var issues: [UserFacingIssue] = []
    let missing = file.libraries.compactMap { $0 as? MissingLibrary }
    if !missing.isEmpty {
      let names = missing.map(\.descriptorText).joined(separator: ", ")
      issues.append(
        UserFacingIssue(
          severity: .warning,
          title: missing.count == 1
            ? "1 library could not be resolved" : "\(missing.count) libraries could not be resolved",
          detail: "\(names). Components from these libraries are preserved exactly as loaded "
            + "and will be written back unchanged when you save. Upstream drops them."))
    }
    if let message = file.takeMessage() {
      issues.append(
        UserFacingIssue(severity: .info, title: "While opening this file", detail: message))
    }
    return issues
  }

  // MARK: - SoC bindings

  /// Gives every circuit in the file a `SocSimulationManager`, matching Java, where the field is
  /// created in `Circuit`'s constructor and there is therefore no such thing as a circuit without
  /// one.
  ///
  /// Every circuit, not just the visible one, because a SoC design is routinely a subcircuit and
  /// `SocSimulationManager` is per-`Circuit` upstream too. Idempotent by `attach`'s contract, so
  /// re-running it after a structural change costs a dictionary lookup and cannot double-register
  /// a slave on its fabric.
  private func attachSocBindings() {
    for circuit in file.circuits { socBinder.attach(to: circuit) }
  }

  // MARK: - Outline

  private func rebuildOutline() {
    let result = ProjectOutlineBuilder.build(file: file, simulationRoot: simulationTree())
    outline = result.outline
    handles = result.handles
  }

  /// The live state hierarchy the Simulate sidebar shows.
  ///
  /// One node, for the circuit being simulated. Upstream's `SimulationTreeModel` descends into
  /// every subcircuit *instance*, which needs the substate tree: and that lives on the
  /// propagation thread behind `SimulationEngine.currentState`, which the main actor must not
  /// read. Showing the root honestly is better than showing an invented tree; descending is the
  /// same piece of work as putting live values on the canvas, and is recorded in
  /// `SimulationEngine`'s header as the gap it is.
  private func simulationTree() -> SimulationNode? {
    guard let circuit = currentCircuitObject else { return nil }
    return SimulationNode(
      id: SimStateID(rawValue: ProjectHandles.handle(circuit)),
      name: circuit.name,
      circuitName: circuit.name,
      isCurrent: true)
  }

  // MARK: - Current circuit

  /// Point everything, project, canvas, simulation, component index, at one circuit.
  private func adopt(circuit: Circuit) {
    guard currentCircuitObject !== circuit else { return }

    project.setCurrentCircuit(circuit)
    currentCircuitObject = circuit
    currentCircuit = ProjectHandles.circuitID(for: circuit)

    // The circuit's stored tick frequency wins on first visit; a circuit with none adopts the
    // simulator's. This is `Project.setCircuitState`'s rule, applied here because that method's
    // frequency branch only runs when a `ProjectCircuitState` exists, and none does until M3
    // installs a `circuitStateFactory` (see `Project.circuitStateFactory`).
    let circuitFrequency = circuit.tickFrequency
    if circuitFrequency < 0 {
      // D13: writing an attribute throws. A rejected write is not worth failing a circuit
      // switch over, the frequency simply stays unset, so it is recorded, not propagated.
      do {
        try circuit.setTickFrequency(engine.tickFrequency)
      } catch {
        pendingIssues.append(
          UserFacingIssue(
            severity: .info, title: "Could not store the tick frequency",
            detail: InspectorProjection.message(from: error)))
      }
    } else if circuitFrequency != engine.tickFrequency {
      engine.setTickFrequency(circuitFrequency)
    }

    // `setCircuit` is the entry point `CircuitCanvasSurface` was written to expose for exactly
    // this. Nothing else in the shell may hand the canvas a circuit.
    surface?.setCircuit(circuit)

    observeCircuit(circuit)
    rebuildComponentIndex()
    engine.post(.setCircuit(UncheckedSendableBox(circuit)))
  }

  /// Track structural edits so the component index, the explorer counts and the inspector stay
  /// in step with the netlist.
  private func observeCircuit(_ circuit: Circuit) {
    if let existing = circuitListener {
      for candidate in file.circuits { candidate.removeCircuitListener(existing) }
    }
    // ── Circuit events arrive from BOTH threads, and only one of them is main ────────────────
    //
    // This closure originally called `MainActor.assumeIsolated` directly. That is an assertion,
    // not a hop: it traps the process if the caller is not already on the main actor. It held
    // for as long as the only thing firing circuit events was a user edit.
    //
    // It stopped holding the moment subcircuit propagation landed.
    // `SubcircuitPropagation.substate` creates a substate during propagation, which calls
    // `InstanceComponent.fireInvalidated()` -> `ComponentListenerRegistry` -> `Circuit.fireEvent`
    // -> this closure: on the SIMULATION thread. `swift_task_checkIsolated` then trapped with
    // EXC_BREAKPOINT and took the whole test binary down.
    //
    // Neither side was wrong. D1 puts the kernel outside Swift Concurrency and keeps
    // `propagate()` synchronous, so the propagator has no main actor to hop to and correctly
    // fires its listeners inline; the host is `@MainActor` and correctly refuses to touch UI
    // projections off it. Nothing owned the join; the ninth time this project has produced
    // exactly that shape, and the first where the two halves were merged in the same sitting.
    //
    // So the listener hops instead of asserting. A propagation-thread event is delivered
    // asynchronously, which is also the right semantics: the propagator must not block on the
    // main queue, and it holds locks the UI has no business waiting behind.
    // `@Sendable` is load-bearing, and its absence is why the first two attempts at this failed.
    //
    // A non-`Sendable` closure literal written inside a `@MainActor` method INHERITS main-actor
    // isolation. The trap therefore fired on ENTRY to this closure, before a single line of its
    // body ran, which is why adding a hop inside it changed nothing, and why the crash stack
    // shows `closure #1 in observeCircuit` calling `swift_task_isCurrentExecutor` directly with
    // no frame of mine in between. I read that stack twice as "my hop is wrong" before noticing
    // there was no hop frame in it at all.
    //
    // `@Sendable` opts the closure out of isolation inference, so the kernel may call it from the
    // propagation thread, which is the actual contract, D1, and `onMainActor` below is then
    // reached and does the hopping. Capturing `self` weakly stays legal because a `@MainActor`
    // class is `Sendable`.
    let listener = CircuitListenerClosure { @Sendable [weak self] event in
      switch event.action {
      case .add, .remove, .clear, .invalidate, .transactionDone:
        onMainActor { self?.circuitDidChange() }
      case .setName:
        onMainActor { self?.circuitWasRenamed() }
      case .checkName, .displayChange, .changeDefaultBoxAppearance:
        break
      }
    }
    circuitListener = listener
    circuit.addCircuitListener(listener)
  }

  private func circuitDidChange() {
    rebuildComponentIndex()
    rebuildOutline()
    pruneSelection()
    notify([.geometry, .outline, .attributes])
    if engine.snapshot.isAutoPropagating { engine.post(.propagate) }
  }

  private func circuitWasRenamed() {
    rebuildOutline()
    notify([.outline, .attributes])
  }

  private func rebuildComponentIndex() {
    componentsByID.removeAll(keepingCapacity: true)
    guard let circuit = currentCircuitObject else { return }
    for component in circuit.components {
      componentsByID[CircuitSceneSource.identity(of: component)] = component
    }
  }

  /// Drop selected IDs whose component is gone. A selection pointing at a deleted component is
  /// how an inspector comes to show a form for something that no longer exists.
  private func pruneSelection() {
    guard case .components(let ids) = selection else { return }
    let live = ids.filter { componentsByID[$0] != nil }
    if live.count != ids.count {
      selection = live.isEmpty ? .nothing : .components(live)
      surface?.setSelection(live, haloed: live.first)
      notify([.selection])
    }
  }

  // MARK: - Selection & inspection

  func setSelection(_ selection: EditorSelection) {
    guard selection != self.selection else { return }
    self.selection = selection
    surface?.setSelection(selection.componentIDs, haloed: selection.componentIDs.first)
    notify([.selection, .attributes])
  }

  func inspectorForm(for selection: EditorSelection) -> InspectorForm {
    switch selection {
    case .nothing:
      return .empty

    case .circuit(let id):
      guard let circuit = handles.circuits[id] else {
        // A VHDL entity has no `AttributeSet` in this port yet; saying so beats an empty form.
        if let content = handles.vhdl[id] {
          return InspectorForm(
            title: content.name, subtitle: "VHDL Entity", symbolName: "doc.plaintext",
            notice: "The VHDL entity editor is not wired into the inspector yet.")
        }
        return .empty
      }
      return InspectorForm(
        title: circuit.name,
        subtitle: "Circuit",
        symbolName: "square.grid.3x3.topleft.filled",
        sections: [
          InspectorSection(
            title: "Circuit", rows: InspectorProjection.rows(of: circuit.staticAttributes))
        ])

    case .tool(let id):
      guard let tool = handles.tools[id] else { return .empty }
      let library = handles.toolLibrary[id]
      let attributes = tool.attributeSet
      let rows = attributes.map { InspectorProjection.rows(of: $0) } ?? []
      return InspectorForm(
        title: tool.displayName,
        subtitle: rows.isEmpty ? "Tool" : "Defaults for new components",
        symbolName: ToolSymbols.symbol(
          forToolNamed: tool.name, inLibrary: library?.name ?? ""),
        sections: rows.isEmpty ? [] : [InspectorSection(title: "Defaults", rows: rows)],
        notice: outline.tool(id)?.unavailableReason)

    case .components(let ids):
      return componentForm(ids)
    }
  }

  private func componentForm(_ ids: Set<ComponentID>) -> InspectorForm {
    let components = ids.compactMap { componentsByID[$0] }
    guard let first = components.first else { return .empty }

    if components.count > 1 {
      // `SelectionAttributes` upstream: the intersection, with differing values shown as the
      // multi-value marker rather than as an empty cell that silently overwrites everything.
      return InspectorForm(
        title: "\(components.count) Components",
        subtitle: "Common attributes",
        symbolName: "square.on.square",
        sections: [
          InspectorSection(
            title: "Shared",
            rows: InspectorProjection.commonRows(of: components.map(\.attributeSet)))
        ])
    }

    let kind = CircuitSceneSource.classify(first)
    let isPlaceholder = kind == .unresolvedPlaceholder
    return InspectorForm(
      title: CircuitSceneSource.displayName(of: first, kind: kind),
      subtitle: first.factory.name,
      symbolName: ToolSymbols.symbol(forToolNamed: first.factory.name, inLibrary: ""),
      sections: [
        InspectorSection(title: "Attributes", rows: InspectorProjection.rows(of: first.attributeSet))
      ],
      notice: isPlaceholder
        ? "This component comes from a library that could not be resolved. Its attributes are "
          + "preserved verbatim and are written back unchanged when you save (D8)."
        : nil)
  }

  // MARK: - Attribute editing

  /// Every attribute edit goes through `CircuitMutation` and therefore onto the undo stack.
  ///
  /// D13 twice over: `AttributeSet.setValue` throws, so `InspectorProjection.encode` refuses a
  /// value the attribute will not take and this method propagates that refusal to the pane
  /// rather than swallowing it; and `Project.doAction` throws, so a mutation the transaction
  /// layer rejects is reported the same way. Upstream catches both and reverts the cell with no
  /// explanation.
  func apply(_ edit: AttributeEdit) throws {
    switch edit.target {
    case .nothing:
      return

    case .components(let ids):
      let components = ids.compactMap { componentsByID[$0] }
      guard !components.isEmpty, let circuit = currentCircuitObject else { return }
      let mutation = project.beginMutation(on: circuit)
      var touched = 0
      for component in components {
        guard let attribute = component.attributeSet.attribute(named: edit.key.name) else {
          continue
        }
        if component.attributeSet.isReadOnly(attribute) {
          throw ProjectHostError.readOnly(edit.key)
        }
        let value = try InspectorProjection.encode(
          edit.newValue, for: attribute,
          stored: component.attributeSet.rawValue(attribute))
        mutation.set(component, attribute, value)
        touched += 1
      }
      guard touched > 0 else {
        throw ProjectHostError.invalidValue(
          edit.key, "no selected component defines this attribute")
      }
      try performOnModel {
        try project.doAction(
          mutation.toAction(
            "Change \(InspectorProjection.displayName(for: edit.key.name))"))
      }
      rebuildComponentIndex()
      notify([.attributes, .dirtyState, .undoStack, .geometry])

    case .circuit(let id):
      guard let circuit = handles.circuits[id],
        let attribute = circuit.staticAttributes.attribute(named: edit.key.name)
      else { return }
      if circuit.staticAttributes.isReadOnly(attribute) {
        throw ProjectHostError.readOnly(edit.key)
      }
      let value = try InspectorProjection.encode(
        edit.newValue, for: attribute, stored: circuit.staticAttributes.rawValue(attribute))
      let mutation = project.beginMutation(on: circuit)
      mutation.setForCircuit(attribute, value)
      try performOnModel {
        try project.doAction(
          mutation.toAction(
            "Change \(InspectorProjection.displayName(for: edit.key.name))"))
      }
      rebuildOutline()
      notify([.attributes, .outline, .dirtyState, .undoStack])

    case .tool(let id):
      // `AttrTableToolModel.setValueRequested` writes the tool's attribute set directly and does
      // **not** create an undo entry: a tool's attributes are the defaults for the *next*
      // placement, not a property of the document. Preserved, including the absence of undo.
      guard let tool = handles.tools[id], let attributes = tool.attributeSet,
        let attribute = attributes.attribute(named: edit.key.name)
      else { return }
      if attributes.isReadOnly(attribute) { throw ProjectHostError.readOnly(edit.key) }
      let value = try InspectorProjection.encode(
        edit.newValue, for: attribute, stored: attributes.rawValue(attribute))
      do {
        try attributes.setRawValue(attribute, value)
      } catch {
        throw ProjectHostError.invalidValue(
          edit.key, InspectorProjection.message(from: error))
      }
      notify([.attributes])
    }
  }

  /// Run a model mutation with the simulation's model lock held.
  ///
  /// The propagation thread reads `Circuit` while this thread writes it. Upstream answers the
  /// same problem with `CircuitLocker`, taken by `CircuitTransaction` precisely so a transaction
  /// can run off the EDT; `SimulationEngine.modelLock` is that in miniature. Uncontended it is
  /// two atomics.
  private func performOnModel<T>(_ body: () throws -> T) rethrows -> T {
    engine.modelLock.lock()
    defer { engine.modelLock.unlock() }
    return try body()
  }

  func bounds(of component: ComponentID) -> CGRect? {
    guard let object = componentsByID[component] else { return nil }
    return CircuitSceneSource.worldBounds(
      of: object, kind: CircuitSceneSource.classify(object))
  }

  // MARK: - Simulation

  private func simulationDidChange(_ snapshot: SimulationSnapshot) {
    // The canvas first, and outside the status guard. A propagation that changes a wire from 0 to
    // 1 changes no field of `SimulationStatus` at all, so gating the repaint on the status would
    // leave the schematic frozen for every edit-and-settle and every poke; i.e. for everything
    // the user actually does. See `CircuitSceneGeometryKey.simulationRevision`.
    surface?.setSimulationRevision(snapshot.propagationCount)

    let status = snapshot.status
    guard status != simulation else { return }
    simulation = status
    notify(.simulation)
  }

  func perform(_ command: SimulationCommand) {
    switch command {
    case .toggleAutoPropagate:
      engine.setAutoPropagating(!simulation.isAutoPropagating)

    case .reset:
      engine.post(.reset)

    case .step:
      engine.post(.step)

    case .tickHalf:
      engine.post(.tick(count: 1))

    case .tickFull:
      // A full clock cycle is two half-cycles; upstream's `MenuSimulate` "Tick Once" is
      // `Simulator.tick(2)`.
      engine.post(.tick(count: 2))

    case .toggleTicking:
      engine.setTicking(!simulation.isTicking)

    case .setTickFrequency(let hz):
      // **D7's control surface.** Straight to the phase-anchored clock; there is no `Timer`
      // anywhere on this path. The circuit stores the rate too, as upstream does, so reopening
      // the file restores it.
      //
      // Board #95 audited eight `setForcedDirty()` arms and made six of them undoable. This is
      // one of the two it deliberately did **not**, and the reason is upstream's, not a gap:
      // `MenuSimulate.TickFrequencyChoice.actionPerformed:466-470` is
      // `currentSim.setTickFrequency(freq)` and nothing else: no `proj.doAction`, no `Action`
      // subclass. Simulation state is not a document edit, so a forced dirty flag with no undo
      // entry is the honest encoding of it. `.toggleTicking` above is the other, for the same
      // reason; it does not even dirty the file.
      engine.setTickFrequency(hz)
      if let circuit = currentCircuitObject {
        do {
          try circuit.setTickFrequency(engine.tickFrequency)
          project.setForcedDirty()
        } catch {
          pendingIssues.append(
            UserFacingIssue(
              severity: .warning, title: "Could not store the tick frequency",
              detail: InspectorProjection.message(from: error)))
        }
      }

    case .enterState, .ascendState:
      // Descending into a subcircuit instance needs the substate tree, which lives on the
      // propagation thread. See `simulationTree()`.
      pendingIssues.append(
        UserFacingIssue(
          severity: .info,
          title: "Simulation state tree not available yet",
          detail: "Descending into a subcircuit instance needs the live substate tree, which "
            + "the simulation owns on its own thread. The root state is simulated correctly."))

    case .enableVhdlSimulation, .generateVhdlSimulationFiles:
      pendingIssues.append(
        UserFacingIssue(
          severity: .info, title: "VHDL co-simulation is not available",
          detail: "It requires QuestaSim/ModelSim, which have never shipped for macOS (D11)."))
    }
    notify(.simulation)
  }

  // MARK: - Commands

  func canPerform(_ command: ProjectCommand) -> Bool {
    switch command {
    case .undo: return project.canUndo
    case .redo: return project.canRedo
    case .clearUndoHistory: return project.canUndo || project.canRedo
    case .cut, .copy, .delete, .duplicate, .raise, .lower, .raiseToTop, .lowerToBottom,
      .rotateSelection, .mirrorSelectionHorizontally, .mirrorSelectionVertically:
      return !selection.isEmpty
    case .deselectAll: return !selection.isEmpty
    case .selectAll: return !componentsByID.isEmpty
    case .addControlPoint, .removeControlPoint: return false
    case .save, .revert: return isDirty
    case .removeCircuit(let id):
      guard file.circuitCount > 1, let circuit = handles.circuits[id] else { return false }
      // `Dependencies.canRemove`: board #94. Upstream refuses to remove a circuit another
      // circuit PLACES (`ProjectCircuitActions.java:233`, `circuitRemoveUsedError`), and it does
      // so HERE, at the project layer: `LogisimFile.removeCircuit` guards only the last circuit,
      // in upstream (`LogisimFile.java:604-607`) exactly as in this port. Putting this in the
      // model would have been a divergence: checked before writing it.
      //
      // Measured consequence of not having it, in `RemoveUsedCircuitTests`: removal succeeded,
      // and the next save DROPPED every placement of the removed circuit. `XmlWriter` resolves a
      // placed component back to a library, fails, calls `loader.showError` and `return nil`
      // (`XmlWriter.swift:1483-1489`), so the element is simply not written and the user's work
      // is gone from the file. That is reachable by an ordinary click.
      //
      // An on-demand scan rather than upstream's incrementally-maintained `Dependencies` graph:
      // this runs once per menu validation over a file with a handful of circuits, and a cache
      // that can go stale is how a guard silently stops guarding.
      return !circuitIsPlacedElsewhere(circuit)
    case .setMainCircuit(let id):
      guard let circuit = handles.circuits[id] else { return false }
      return circuit !== file.mainCircuit
    case .setCurrentCircuit(let id):
      return handles.circuits[id] != nil || handles.vhdl[id] != nil
    case .loadBuiltinLibrary, .loadLogisimLibrary:
      // `MenuProject` in 4.1.0 enables both as soon as a `Project` exists; its listener calls
      // `ProjectLibraryActions.doLoadBuiltinLibrary` / `doLoadLogisimLibrary`, which open a
      // chooser and finish by constructing `LogisimFileActions.LoadLibraries`. That action is
      // upstream's undoable unit: it removes duplicates, checks conforming libraries and tool-name
      // collisions, promotes used base libraries, and replays all of it on redo.
      //
      // This port has the low-level loader (`Loader.loadLogisimLibrary`) but not the chooser and
      // not `LoadLibraries` (see that file's tail comment). Reporting "not implemented yet" after
      // a click is the inert lie the command audit exists to find; enabling a non-undoable direct
      // load would be a half port. Until the upstream-shaped action lands, the honest state is a
      // disabled item with a bypass error that names the missing unit.
      return false
    // D11, permanently: no `ZipClassLoader`, no `Class.forName`, no reflective instantiation.
    case .loadJarLibrary: return false
    case .revertAppearance: return false
    case .unloadLibrary(let id): return handles.libraries[id] != nil
    case .reloadLibrary(let id):
      // `Popups$LibraryPopup`'s constructor, disassembled from the 4.1.0 jar:
      //
      //     reload.setEnabled(canUnload && lib instanceof LoadedLibrary);
      //
      // Two conditions, and both are reproduced. `canUnload` is the flag `Popups.forLibrary`
      // is called with, which is true only for a library the *file* holds; `handles.libraries`
      // is built from `file.libraries` (`ProjectOutlineBuilder:150`) and from nothing else, so
      // the subscript being non-nil IS that condition. The `LoadedLibrary` test is the one that
      // matters for behaviour: a built-in has no descriptor to re-read, so
      // `LibraryManager.reload` would fall straight into its `unknownLibraryFileError` branch
      // and the only observable effect of the click would be an error. Upstream greys the item
      // instead, and so does this.
      guard let library = handles.libraries[id] else { return false }
      return library is LoadedLibrary
    default: return true
    }
  }

  func perform(_ command: ProjectCommand) throws {
    switch command {
    case .undo:
      try performOnModel { try project.undoAction() }
      afterUndoStackChanged()

    case .redo:
      try performOnModel { try project.redoAction() }
      afterUndoStackChanged()

    case .clearUndoHistory:
      project.discardAllEdits()
      notify(.undoStack)

    case .setCurrentCircuit(let id):
      guard let circuit = handles.circuits[id] else {
        throw ProjectHostError.notImplemented("editing a VHDL entity")
      }
      adopt(circuit: circuit)
      setSelection(.circuit(id))
      rebuildOutline()
      notify([.currentCircuit, .geometry, .outline, .simulation])

    case .selectTool(let id):
      guard let tool = handles.tools[id] else { return }
      activeTool = id
      project.setTool(tool)
      // And the tool layer, which is what actually receives the clicks. Without this the toolbar
      // highlight moved and the canvas kept using the previous tool -- the two halves of "select
      // a tool" agreeing on the model and disagreeing on the input.
      editorCanvas?.controller.setActiveTool(fromLibrary: tool)
      notify(.activeTool)

    case .deselectAll:
      setSelection(.nothing)

    case .selectAll:
      setSelection(.components(Set(componentsByID.keys)))

    case .delete, .cut:
      let ids = selection.componentIDs
      let components = ids.compactMap { componentsByID[$0] }
      guard !components.isEmpty, let circuit = currentCircuitObject else { return }
      let mutation = project.beginMutation(on: circuit)
      mutation.removeAll(components)
      try performOnModel {
        try project.doAction(mutation.toAction(command == .cut ? "Cut" : "Delete"))
      }
      setSelection(.nothing)
      rebuildComponentIndex()
      notify([.geometry, .dirtyState, .undoStack, .outline])

    case .addCircuit:
      // Board #95. This arm used to read: "the file-level action family is not ported. Done
      // directly and marked dirty, which is honest about it not being undoable." It is ported
      // now, `LogisimFileActions.swift`, and this and the five arms below route through it,
      // so Cmd-Z reverses a structural edit exactly as it reverses a canvas edit.
      let name = uniqueCircuitName(base: "circuit")
      let circuit = try Circuit(name: name, file: file)
      try performOnModel {
        try project.doAction(
          LogisimFileActions.addCircuit(
            circuit,
            // Java gets the SoC manager from `Circuit`'s constructor; here the owner of the
            // binder has to do it, or a SoC component placed in a circuit created after the file
            // was opened registers with nothing and reads noise. It now has to happen on *redo*
            // too, which is why it moved from this line into the action.
            onAdded: { [weak self] in self?.socBinder.attach(to: $0) },
            onRemoved: { [weak self] in self?.socBinder.detach(from: $0) }))
      }
      afterFileStructureChanged(adopting: circuit)

    case .removeCircuit(let id):
      guard let circuit = handles.circuits[id] else { return }
      try performOnModel {
        try project.doAction(
          LogisimFileActions.removeCircuit(
            circuit,
            // The binder prunes deallocated circuits on its own, but a removed circuit is not
            // necessarily deallocated, the undo stack or a still-open canvas may hold it, and
            // until it is, its manager and the whole `SocBusFabric`/`SocMemoryMap` graph stay
            // alive. Board #95 makes that comment *more* true, because the action now deliberately
            // holds the circuit: eviction therefore has to be tied to the moment membership
            // changes rather than to this call site, and `onRemoved`/`onAdded` are those moments.
            onAdded: { [weak self] in self?.socBinder.attach(to: $0) },
            onRemoved: { [weak self] in self?.socBinder.detach(from: $0) }))
      }
      afterFileStructureChanged()

    case .renameCircuit(let id, let name):
      guard let circuit = handles.circuits[id] else { return }
      // An empty name has to be refused HERE and not only in the menu that sends this command.
      // `circuitNameConflicts` returns false for "": faithfully, since upstream's `isNameInUse`
      // does the same, so without this the mutation is applied, `CircuitStaticAttributeListener`
      // reverts it and calls `circuit.report(.emptyCircuitName)`, and that report goes nowhere
      // because nothing installs `Circuit.diagnosticReporter` (board #99). Nothing throws, the
      // name does not change, and a "Rename Circuit" entry still lands on the undo stack for an
      // edit that did not happen. Whitespace is trimmed rather than syntax-checked: upstream kills
      // "   " one line later in `SyntaxChecker`, which D9 excludes from this port, so trimming
      // preserves 4.1.0's accepted SET rather than its line of code.
      if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        throw ProjectHostError.invalidValue(AttributeKey("circuit"), "a circuit needs a name")
      }
      if file.circuitNameConflicts(name, changed: circuit) {
        // Deliberately neutral about WHAT holds the name. `circuitNameConflicts` matches any tool
        // in any loaded library as well as another circuit, so "another circuit is already called
        // ‘Pin’" was simply false for the library case. Upstream's `circuitNameExists` is neutral
        // for the same reason: "This name is already in use in your project…".
        throw ProjectHostError.invalidValue(
          AttributeKey("circuit"), "the name ‘\(name)’ is already in use in this project")
      }
      // The one member of board #95's six that needs no new action class. A circuit's name *is*
      // an attribute (`CircuitAttributes.NAME_ATTR`), and `CircuitMutation.setForCircuit` already
      // logs its old value for undo, which is exactly how upstream renames, through
      // `AttrTableCircuitModel.setValueRequested:44` rather than through `LogisimFileActions`.
      // `Circuit.setName` is `staticAttributes.setValue(nameAttribute:)`, so the validation and
      // the pin-label revert in `CircuitAttributes` run identically on this path.
      //
      // The undo label diverges, deliberately. Upstream's is `changeCircuitAttrAction`:
      // "Change Circuit"; because it has no rename *command*, only an attribute cell. This port
      // has `ProjectCommand.renameCircuit`, and "Undo Change Circuit" after invoking something
      // called Rename reads as a different edit. D9: the label is presentation.
      let mutation = project.beginMutation(on: circuit)
      mutation.setForCircuit(CircuitAttributes.nameAttribute, name)
      do {
        try performOnModel { try project.doAction(mutation.toAction("Rename Circuit")) }
      } catch {
        throw ProjectHostError.invalidValue(
          AttributeKey("circuit"), InspectorProjection.message(from: error))
      }
      rebuildOutline()
      notify([.outline, .attributes, .dirtyState, .undoStack])

    case .setMainCircuit(let id):
      guard let circuit = handles.circuits[id] else { return }
      try performOnModel { try project.doAction(LogisimFileActions.setMainCircuit(circuit)) }
      afterFileStructureChanged()

    case .moveCircuitUp(let id), .moveCircuitDown(let id):
      guard let circuit = handles.circuits[id],
        let tool = file.addTool(for: circuit)
      else { return }
      let index = file.indexOfCircuit(circuit)
      guard index >= 0 else { return }
      let delta = { if case .moveCircuitUp = command { return -1 } else { return 1 } }()
      let target = index + delta
      guard target >= 0, target < file.circuitCount else { return }
      try performOnModel { try project.doAction(LogisimFileActions.moveCircuit(tool, to: target)) }
      afterFileStructureChanged()

    case .unloadLibrary(let id):
      guard let library = handles.libraries[id] else { return }
      if let message = file.unloadLibraryMessage(library) {
        throw ProjectHostError.invalidValue(AttributeKey("library"), message)
      }
      // NOTE (board #95): unloading is undoable and **loading is not**; the load path predates
      // this family and upstream's `LogisimFileActions.LoadLibraries` is not ported. That is the
      // half-undoable shape this board exists to remove, one size smaller. See the tail of
      // `LogisimFileActions.swift`.
      try performOnModel { try project.doAction(LogisimFileActions.unloadLibrary(library)) }
      afterFileStructureChanged()

    case .reloadLibrary(let id):
      // `Popups$LibraryPopup.actionPerformed`, disassembled from the 4.1.0 jar, is two lines:
      //
      //     proj.getLogisimFile().getLoader().reload((LoadedLibrary) lib);
      //
      // and there is **no `proj.doAction`** anywhere in that method. So reloading is deliberately
      // not undoable upstream, and it is not undoable here either. That is worth stating because
      // board #95 made undoability the rule for the structural commands and this is the one
      // library operation that is genuinely outside it: `unloadLibrary` above pushes an action
      // and this does not. The reason the distinction holds up is that a reload has no inverse to
      // record; the old contents came from a file on disk that has already changed, so "undo"
      // could only mean re-reading it again, which is the same command.
      guard let library = handles.libraries[id] else { return }
      guard let loaded = library as? LoadedLibrary else {
        // Reachable even though `canPerform` says no: the explorer's Reload Library item carries
        // no `.disabled` modifier, so a click on a built-in still arrives here. D13; say what is
        // wrong rather than no-op, and never trap.
        throw ProjectHostError.unsupportedCommand(
          "‘\(library.displayName)’ is built in, so there is no file to re-read. Reloading "
            + "applies to a library loaded from a .circ file")
      }
      // The diagnostics are the point of the reset/drain pair. `LibraryManager.reload` reports
      // every failure through `loader.showError` and returns void, a missing file, a malformed
      // one, a JAR descriptor, so without draining, a reload that silently failed would be
      // indistinguishable from one that worked. `reset()` first, because the recorder accumulates
      // for the lifetime of the loader and the errors from the original *open* are already on
      // screen; re-reporting them here would blame this click for them.
      (loader.ui as? HeadlessLoaderUI)?.reset()
      loader.reload(loaded)
      pendingIssues.append(contentsOf: Self.loaderIssues(from: loader))
      // `LoadedLibrary.setBase` → `resolveChanges` → `LoadedLibrary.replacementHandler` →
      // `LibraryReplacementApply` has already rewritten every placed component to the new
      // factories, synchronously, inside `loader.reload` above (board #64, installed in
      // `installProcessSeams`). What is left is telling the shell: the component index still maps
      // ids to the objects that were swapped, the outline still lists the old tool set, and the
      // inspector is projecting an attribute set that may belong to a replaced factory.
      //
      // `pruneSelection` last, and it is load-bearing rather than defensive: a replaced component
      // is a NEW object, so its `ComponentID`, reference identity, D4, changes, and a selection
      // held across the reload would name components the index no longer has. It notifies
      // `.selection` itself when it drops any, which is why that flag is not in the set below.
      rebuildComponentIndex()
      rebuildOutline()
      pruneSelection()
      notify([.outline, .geometry, .attributes])

    case .loadBuiltinLibrary:
      throw ProjectHostError.unsupportedCommand(
        "Load Built-in Library needs the built-in library chooser and the undoable "
          + "LogisimFileActions.LoadLibraries action, which are not ported yet")

    case .loadLogisimLibrary:
      throw ProjectHostError.unsupportedCommand(
        "Load Logisim Library needs the .circ file importer and the undoable "
          + "LogisimFileActions.LoadLibraries action, which are not ported yet")

    case .loadJarLibrary:
      throw ProjectHostError.unsupportedCommand(
        "JAR libraries load Java classes at runtime, which has no ahead-of-time Swift "
          + "equivalent (D11). Components from one are preserved verbatim instead of dropped")

    case .exportImage:
      guard surface != nil else {
        throw ProjectHostError.notImplemented("exportImage")
      }
      let job = exportImageJob()
      guard !job.circuits.isEmpty else {
        pendingIssues.append(
          UserFacingIssue(
            severity: .info,
            title: "No circuits to export",
            detail: "There are no non-empty circuits in this project."))
        notify([])
        return
      }
      _ = try CircuitExportImageCommand.run(job: job)

    default:
      // Everything else is a real feature owned by another milestone. Reporting it as
      // unimplemented is honest; silently doing nothing is how a shell rots.
      throw ProjectHostError.notImplemented("\(command)")
    }
  }

  private func afterUndoStackChanged() {
    // Board #95: an undo can now remove the circuit being edited (undoing an "add circuit") or
    // put a removed one back. Reconciling *here* rather than inside the actions is deliberate;
    // `Project.undoAction` restores its own editing context from `ActionData` and the host has to
    // agree with the model afterwards no matter which action ran, including a `JoinedAction` that
    // mixes a structural edit with canvas edits.
    let switched = adoptFallbackIfCurrentCircuitLeftTheFile()
    rebuildComponentIndex()
    rebuildOutline()
    pruneSelection()
    var changes: ProjectChange = [.undoStack, .attributes, .geometry, .dirtyState, .outline]
    if switched { changes.formUnion([.currentCircuit, .simulation]) }
    notify(changes)
    if engine.snapshot.isAutoPropagating { engine.post(.propagate) }
  }

  /// Post-edit bookkeeping shared by the five structural command arms (board #95).
  ///
  /// The arms used to inline `project.setForcedDirty(); rebuildOutline(); notify(...)`. They no
  /// longer force anything dirty: `Project.doAction` derives dirtiness from the undo-stack state,
  /// which is what makes undoing back to the last saved state mark the file clean again, and a
  /// forced flag would have made that unreachable for exactly the six operations this board is
  /// about.
  ///
  /// `adopting` is the "the edit created the thing you should now be looking at" case, which is
  /// only `addCircuit`.
  private func afterFileStructureChanged(adopting circuit: Circuit? = nil) {
    var changes: ProjectChange = [.outline, .dirtyState, .undoStack]
    if let circuit {
      rebuildOutline()
      adopt(circuit: circuit)
      changes.formUnion([.currentCircuit, .geometry, .simulation])
    } else {
      if adoptFallbackIfCurrentCircuitLeftTheFile() {
        changes.formUnion([.currentCircuit, .geometry, .simulation])
      }
      rebuildOutline()
    }
    notify(changes)
  }

  /// If the circuit on the canvas is no longer in the file, move to one that is.
  ///
  /// Returns whether it switched, so the caller can decide whether `.currentCircuit` is worth
  /// notifying; `afterUndoStackChanged` runs after *every* undo, and unconditionally claiming the
  /// current circuit changed would make the canvas rebuild on every Cmd-Z.
  ///
  /// `file.contains(circuit:)` is reference identity (D4), which is the only test that works here:
  /// a re-added circuit is the same object, and a *different* circuit with the same name is not
  /// the one being edited.
  @discardableResult
  private func adoptFallbackIfCurrentCircuitLeftTheFile() -> Bool {
    guard let current = currentCircuitObject, !file.contains(circuit: current) else { return false }
    guard let fallback = file.mainCircuit ?? file.circuits.first else { return false }
    // `adopt` early-returns when its argument is already the current circuit, and this method
    // originally cleared `currentCircuitObject` first to defeat that. **That line was dead**, and
    // a red probe proved it: removing it reddened nothing, because the guard above establishes
    // that `current` is *not* in the file while `fallback` is by construction, so the two can
    // never be the same object and the early return is unreachable from here. Recorded rather
    // than left in, because a defensive-looking no-op reads as a guard and invites the next
    // reader to preserve it.
    adopt(circuit: fallback)
    return true
  }

  private func uniqueCircuitName(base: String) -> String {
    var index = 1
    var candidate = "\(base)_\(index)"
    while file.circuitNameConflicts(candidate, changed: nil) {
      index += 1
      candidate = "\(base)_\(index)"
    }
    return candidate
  }

  // MARK: - Canvas

  /// Builds the pure export job before `NSSavePanel` appears. The default selected circuit
  /// matches `CircuitJList(project, true)`: filter out empty circuits, then select the current
  /// circuit if it is still present in that filtered list.
  private func exportImageJob() -> ExportImageJob {
    let current = currentCircuitObject
    let appearance = CanvasAppearance()
    let circuits = file.circuits.compactMap { circuit -> ExportImageCircuit? in
      guard circuit.bounds != Bounds.empty, circuit.bounds.width > 0, circuit.bounds.height > 0
      else { return nil }
      return ExportImageCircuit(
        name: circuit.name,
        isSelectedByDefault: circuit === current,
        renderImage: { settings in
          try CircuitExportImage.export(
            circuit: circuit,
            settings: settings,
            appearance: appearance)
        })
    }
    return ExportImageJob(settings: ExportImageSettings(), circuits: circuits)
  }

  /// Builds one page per circuit, in the file's own order, which is the order the explorer
  /// shows and the order `LogisimFile.circuits` returns, so a printout matches the sidebar.
  ///
  /// The scene is built here rather than in the shell because building it needs the `Circuit`,
  /// and handing a `Circuit` across `ProjectHost` is the one thing that seam forbids
  /// (`ProjectSeam.swift:8`). What crosses is a `RenderScene`.
  func printablePages(appearance: CanvasAppearance, printerView: Bool) -> [PrintableCircuit] {
    file.circuits.map { circuit in
      PrintableCircuit(
        name: circuit.name,
        scene: CircuitPrintScene.build(
          circuit: circuit, appearance: appearance, printView: printerView))
    }
  }

  func makeRenderSurface() -> any CircuitRenderSurface {
    let made = CircuitCanvasSurface()
    surface = made
    if let circuit = currentCircuitObject {
      made.setCircuit(circuit)
      made.setSelection(selection.componentIDs, haloed: selection.componentIDs.first)
    }

    // The editing layer, attached to the surface the shell is about to display. Until this line
    // existed `CircuitEditorCanvas` was constructed only by tests, and the app ran on the ad-hoc
    // click/marquee handler below, which could select and rubber-band and nothing else, and whose
    // `canvasHandleKey` returned `false` unconditionally, so Delete did nothing in the app.
    // The window onto the running simulation, shared by the canvas (which pokes through it) and
    // the surface (which paints through it). One object, so both see the same lock.
    let access = EngineSimulationAccess(engine: engine)
    made.simulationAccess = access

    let canvas = CircuitEditorCanvas(
      project: project, surface: made, circuit: currentCircuitObject,
      initialTool: SelectTool(), simulation: access)
    editorCanvas = canvas

    // Put the controller on whatever tool the explorer already considers active, so the very first
    // click after opening a document goes to the right tool rather than to the constructor's
    // default. Silent otherwise: `activeTool` is set during `rebuildOutline` in `init`, long
    // before any surface exists.
    if let id = activeTool, let tool = handles.tools[id] {
      canvas.controller.setActiveTool(fromLibrary: tool)
    }

    // ── The selection join ────────────────────────────────────────────────────────────────
    //
    // There are two selection models and they are both real. The tool layer's `Selection` holds
    // component objects and is what `SelectTool` mutates; the host's `EditorSelection` holds
    // `ComponentID`s and is what the inspector and `CircuitSceneView` read. Neither can simply
    // replace the other: the tools need object identity (D4), the SwiftUI shell needs something
    // `Sendable` and `Hashable`.
    //
    // So the tool layer is the writer and the host mirrors it. One direction only, deliberately:
    // adding a host -> tool edge as well would make an ordinary click a cycle, and the obvious
    // guard for that (a re-entrancy flag) is the kind of thing that works until two selections
    // change in one gesture.
    let mirror = SelectionMirror { [weak self] ids in
      guard let self else { return }
      self.setSelection(ids.isEmpty ? .nothing : .components(ids))
    }
    selectionMirror = mirror
    canvas.selection.addListener(mirror)

    return made
  }

  /// Forwards the tool layer's selection to the host's. Held by the host because
  /// `SelectionBase.listeners` is a weak list; an unheld mirror is collected and the two models
  /// silently drift apart, which looks exactly like a selection bug in the tools.
  private final class SelectionMirror: SelectionListener {
    private let onChange: (Set<ComponentID>) -> Void
    init(onChange: @escaping (Set<ComponentID>) -> Void) { self.onChange = onChange }
    func selectionChanged(_ selection: SelectionBase) {
      onChange(Set(selection.components.map { CircuitSceneSource.identity(of: $0) }))
    }
  }

  /// The host stays the handler and ROUTES, rather than handing the controller over directly.
  ///
  /// That looked like an unnecessary indirection and is not: `canvasDropTool` receives a `ToolID`,
  /// and `CanvasToolController.canvasDropTool` **ignores its `tool` argument entirely**; it
  /// synthesises a press/release with whatever tool is already active. Only the host can resolve
  /// a `ToolID` (`handles.tools` is its), so returning the controller here would have made every
  /// explorer drag-and-drop place the previously-selected component instead of the dropped one.
  /// Caught by reading `performDragOperation`, which does not select the tool before dropping.
  var interactionHandler: (any CanvasInteractionHandler)? { self }

  // ── Pointer handling ────────────────────────────────────────────────────────────────────
  //
  // Click-to-select and marquee, against the real components of the real circuit. This is
  // deliberately **not** `CanvasToolController`: that class is the intended long-term owner of
  // canvas input, and it needs a `ToolCanvas`, which needs a `Selection`: both of which belong
  // to the Tools and Selection slices rather than to this one. Wiring it is a join across three
  // slices' files, and doing it from here would mean writing into files this slice does not own.
  // Recorded as the next step rather than half-done.

  func canvasHandlePointer(_ event: CanvasPointerEvent) {
    editorCanvas?.controller.canvasHandlePointer(event)
  }

  func canvasHandleKey(_ event: CanvasKeyEvent) -> Bool {
    editorCanvas?.controller.canvasHandleKey(event) ?? false
  }
  /// Placing a component dragged out of the explorer.
  ///
  /// The `ToolID` is resolved here and made active BEFORE the gesture runs, because the
  /// controller's drop replays a press/release with `activeTool` and has no registry of its own.
  /// The placement itself is then the tool layer's real `AddTool` path, ghost, `Connector`
  /// reroute, undo entry, rather than the direct `CircuitMutation` this used to do, which built
  /// the component correctly and skipped everything else a placement is supposed to run.
  func canvasDropTool(_ tool: ToolID, atWorldPoint point: CGPoint) {
    guard let controller = editorCanvas?.controller, let resolved = handles.tools[tool] else {
      return
    }
    guard controller.setActiveTool(fromLibrary: resolved) else {
      // Not drivable. Says so rather than dropping the gesture on the floor: before the base-tool
      // table landed this was the normal outcome for five of the tools and produced no signal at
      // all (board #21).
      pendingIssues.append(
        UserFacingIssue(
          severity: .warning, title: "Could not place ‘\(resolved.displayName)’",
          detail: "This tool has no editing behaviour in this build, so it cannot be placed by "
            + "dragging it onto the canvas."))
      notify([])
      return
    }
    activeTool = tool
    project.setTool(resolved)
    controller.canvasDropTool(tool, atWorldPoint: point)
    rebuildComponentIndex()
    notify([.geometry, .dirtyState, .undoStack, .outline, .activeTool])
  }

  /// The active tool's own cursor, rather than a switch over three tool ids that silently
  /// answered `.arrow` for the other 159.
  func canvasCursor(atWorldPoint point: CGPoint) -> NSCursor {
    editorCanvas?.controller.canvasCursor(atWorldPoint: point) ?? .arrow
  }

  /// The right-click menu, which is upstream's `MenuTool`. Routed like every other input: the
  /// controller owns the tool, the host only forwards.
  func canvasContextMenu(atWorldPoint point: CGPoint) -> NSMenu? {
    editorCanvas?.controller.canvasContextMenu(atWorldPoint: point)
  }

  // MARK: - Persistence

  /// The real writer. `XmlWriter` through `LogisimFile.write`, which is the same path the
  /// round-trip gate drives 539 canonical files through; not the placeholder XML comment the
  /// stand-in emitted.
  ///
  /// `LogisimFile.write` returns `nil` on failure *and* reports through `showError`, which is a
  /// deliberate improvement on upstream: `LogisimFile.write` there is `void` and swallows every
  /// failure into `loader.showError`, so the caller cannot tell a written file from an unwritten
  /// one: the direct cause of the zero-length-file recovery dance in `Loader.save`. Here it is
  /// a `throw` the document machinery reports.
  ///
  /// **This is a pure read.** It used to end with `project.setFileAsClean()`, which marked the
  /// document clean at the moment the bytes were *produced* rather than the moment they were
  /// *stored*; board #89. A read-only volume then left a document that reported itself saved
  /// with nothing on disk to show for it. The flag now moves in `confirmSaveSucceeded()`,
  /// which is upstream's ordering: `ProjectActions.doSave` calls `setFileAsClean()` at bytecode
  /// offset 39, inside the branch `ifeq 42` guards on `Loader.save` having returned true. See
  /// the header of `Document/SaveConfirmation.swift` for the disassembly.
  func serialize() throws -> Data {
    guard let data = performOnModel({ file.write(loader: loader) }) else {
      throw ProjectHostError.notImplemented("writing this document")
    }
    pendingSave = PendingSave(
      fingerprint: SaveVerification.fingerprint(data),
      undoDepth: project.undoActions.count,
      redoDepth: project.redoActions.count)
    return data
  }

  /// What `serialize()` handed out and has not yet heard back about.
  struct PendingSave {
    let fingerprint: Int
    /// The undo/redo stack depths when the bytes were taken. If either has moved by the time
    /// the write is confirmed, the model is no longer what was written, so the document must
    /// stay dirty, see `confirmSaveSucceeded()`.
    let undoDepth: Int
    let redoDepth: Int
  }

  private(set) var pendingSave: PendingSave?

  var hasPendingSave: Bool { pendingSave != nil }

  /// Upstream `doSave` offset 39; reached only on a true return from `Loader.save`.
  ///
  /// The stack-depth guard has no counterpart upstream and does not need one: Java's `doSave`
  /// runs to completion on the EDT, so no edit can land between producing the bytes and
  /// storing them. Here `fileWrapper(snapshot:configuration:)` runs off the main thread and
  /// the write lands after it, so an edit made in that window would be silently swallowed by
  /// `setFileAsClean()` -- it records the model's current undo-stack state as the saved state.
  /// Refusing to clear in that case keeps the document dirty, which costs the user one redundant
  /// save and cannot cost them an edit.
  func confirmSaveSucceeded() {
    guard let pending = pendingSave else { return }
    pendingSave = nil
    guard
      pending.undoDepth == project.undoActions.count,
      pending.redoDepth == project.redoActions.count
    else { return }
    project.setFileAsClean()
    notify([.dirtyState])
  }

  /// Upstream `doSave`'s `ifeq 42`: the branch that steps over `setFileAsClean()`.
  func confirmSaveFailed() {
    pendingSave = nil
  }

  /// The URL this document now lives at.
  ///
  /// `fileURL` was assigned once in `init` and never again, so it went stale on the first Save
  /// As or title-bar rename: the second half of board #89. `DocumentGroup` hands the live URL
  /// to the scene on every body evaluation and `DocumentRoot` forwards it here, so the host and
  /// `CircuitDocument.currentURL` now agree instead of drifting apart.
  ///
  /// This is *not* routed into `Loader.setMainFile`: that is what makes library descriptors
  /// relative, it is not reachable from this module, and changing it as a side effect of a
  /// rename would rewrite paths in a file the user did not ask to have rewritten. See the note
  /// at `CircuitDocument.attachedHost`.
  func documentMoved(to url: URL?) {
    guard fileURL != url else { return }
    fileURL = url
    // `.dirtyState` is the change `EditorModel.pull` re-reads `fileURL` and `displayName` on
    // (`EditorModel.swift:143-147`), so without this the model keeps the old URL until the next
    // edit, which is the same staleness one level up.
    notify([.dirtyState])
  }

  // MARK: - Observation

  func addObserver(_ observer: @escaping @MainActor (ProjectChange) -> Void) -> ProjectObservation
  {
    let id = UUID()
    observers[id] = observer
    return ProjectObservation { [weak self] in
      // D3: the token holds the closure, the host holds the token weakly. Dropping the token
      // unsubscribes; there is no host → shell strong edge.
      Task { @MainActor in self?.observers[id] = nil }
    }
  }

  func drainPendingIssues() -> [UserFacingIssue] {
    defer { pendingIssues.removeAll() }
    return pendingIssues
  }

  private func notify(_ change: ProjectChange) {
    for observer in observers.values { observer(change) }
  }
}

// MARK: - Memory contents (the hex editor's way in)

/// `Mem.getHexFrame(Project, Instance, CircuitState)`, split at the seam.
///
/// This extension is **in this file on purpose**: `componentsByID` is `private`, and Swift's
/// `private` is file-scoped, so an extension here can read it and one anywhere else cannot. That
/// is exactly the property wanted; the map of live components is the host's business and the
/// only thing that leaves is `EditableMemory`, a value plus one live `MemContents`.
///
/// See `Hex/MemoryContentsSeam.swift` for the citations: which of 4.1.0's two `getHexFrame`
/// bodies each memory family uses, why a RAM's words are out of reach from this actor, and why a
/// ROM edit is undoable and a RAM edit is not.
extension LogisimFileProjectHost: MemoryContentsProviding {

  func editableMemory(for component: ComponentID) -> EditableMemory? {
    guard let object = componentsByID[component] else { return nil }
    // `RomAttributes.getHexFrame(contents, proj, instance)`; the contents come from the
    // attribute set, so no `CircuitState` is involved and this is a legal main-actor read.
    guard let contents = object.attributeSet.getValue(Rom.contentsAttr) else { return nil }
    // `RomAttributes.register(contents, proj)`: passing the project is what installs the
    // undo-recording `RomContentsListener`, and it is done for ROMs and for nothing else.
    return EditableMemory(contents: contents, project: project, title: Self.memoryTitle(object))
  }

  func memoryUnreachableReason(for component: ComponentID) -> String? {
    guard let object = componentsByID[component] else { return nil }
    guard object.factory is Mem else { return nil }
    if object.attributeSet.getValue(Rom.contentsAttr) != nil { return nil }
    // A RAM or a DualRam. `Ram.getHexFrame` reads `instance.getData(circState)`; this port's
    // `CircuitState` is propagation-thread-owned. Say so rather than opening an editor over a
    // buffer that is attached to nothing.
    return
      "\(object.factory.displayName) keeps its contents in the running simulation, which this "
      + "build cannot reach from the editor yet. A ROM's contents can be edited."
  }

  var liveMemoryIdentities: Set<ObjectIdentifier> {
    var live: Set<ObjectIdentifier> = []
    for object in componentsByID.values {
      if let contents = object.attributeSet.getValue(Rom.contentsAttr) {
        live.insert(ObjectIdentifier(contents))
      }
    }
    return live
  }

  /// `HexFrame`'s title suffix. The label if the user gave one, that is what identifies a
  /// particular ROM in a circuit with several, otherwise the factory's display name.
  private static func memoryTitle(_ object: any Component) -> String {
    let label = object.attributeSet.getValue(StdAttr.label) ?? ""
    return label.isEmpty ? object.factory.displayName : label
  }
}

// MARK: - Simulator adapter

/// `Project`'s view of the simulator (`ProjectSimulator`), forwarded to the engine.
///
/// D3: **unowned**. The host owns both the project and the engine, and the project holds this
/// adapter, so an owning edge back to the engine would make the pair uncollectable.
@MainActor
private final class HostSimulatorAdapter: ProjectSimulator {
  private unowned let engine: SimulationEngine

  init(engine: SimulationEngine) {
    self.engine = engine
  }

  /// Only reachable once M3 installs a `ProjectCircuitStateFactory`; until then `Project` runs
  /// its no-state path and the host drives the engine directly (`adopt(circuit:)`).
  func setCircuitState(_ state: (any ProjectCircuitState)?) {}

  var tickFrequency: Double { engine.tickFrequency }

  func setTickFrequency(_ value: Double) { engine.setTickFrequency(value) }
}

// ── Delivering a kernel callback onto the main actor ────────────────────────────────────────
//
// Deliberately a nonisolated free function, not a method: every caller is a kernel listener
// closure running on whatever thread the propagator happens to be on, so there is no actor to
// inherit and a `@MainActor` method could not be called from one without the same trap it
// exists to avoid.
//
// The `Thread.isMainThread` fast path matters for correctness, not speed. A user edit fires this
// synchronously from the main actor while a `CircuitMutation` is in progress, and bouncing that
// through `DispatchQueue.main.async` would reorder it after the mutation completes; the
// explorer and inspector would then rebuild from a circuit that had already moved on. Only an
// off-main event, which cannot be delivered synchronously at all, is deferred.
// Deliberately `internal`, not `private`: this is the module's THIRD independent rediscovery of
// the same rule; `LogController.onMain` and `SimulationEngine.mutateSnapshot` each wrote their
// own, each with a comment saying it is not `assumeIsolated` because the propagation thread gets
// here. Two of those were written correctly and one listener was still missed, which is the
// argument for one shared spelling rather than a fourth copy. `CircuitCanvasSurface`'s relay
// calls this one.
//
// ── `Thread.isMainThread` is NOT a test for main-actor isolation ────────────────────────────
//
// The obvious spelling, `if Thread.isMainThread { MainActor.assumeIsolated … }`, is what
// `LogController.onMain` and `SimulationEngine.mutateSnapshot` both use, and it is what this
// function used first. It is still wrong, and it still crashed after the hop was added.
//
// `assumeIsolated` does not check the thread. It calls `dispatch_assert_queue(main_queue)`, so
// it demands the **main dispatch queue**, and being on the main thread is a strictly weaker
// condition. swift-testing runs test bodies on task executors that can land on the main thread
// without being the main queue, and a headless `SimulationHost` captures `Thread.current` at
// init: so in a test, propagation runs on the main thread, `isMainThread` answers true, and
// `assumeIsolated` trapped anyway with EXC_BREAKPOINT. Twelve suites died that way.
//
// So the fast path asks the question it actually needs answered, by marking the main queue and
// looking for that marker. Non-nil means genuinely on the main queue, where `assumeIsolated`
// holds; anything else, a propagation thread, or a task executor merely borrowing the main
// thread, takes the async hop.
//
// The fast path is kept rather than always hopping because a user edit fires this synchronously
// from the main queue while a `CircuitMutation` is in progress, and deferring it would rebuild
// the explorer and inspector from a circuit that had already moved on.
private let mainQueueMarker = DispatchSpecificKey<UInt8>()
private let markMainQueue: Void = {
  DispatchQueue.main.setSpecific(key: mainQueueMarker, value: 1)
}()

func onMainActor(_ body: @escaping @MainActor () -> Void) {
  _ = markMainQueue
  if DispatchQueue.getSpecific(key: mainQueueMarker) != nil {
    MainActor.assumeIsolated { body() }
  } else {
    DispatchQueue.main.async { MainActor.assumeIsolated { body() } }
  }
}
