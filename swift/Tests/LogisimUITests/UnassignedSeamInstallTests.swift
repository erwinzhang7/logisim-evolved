// LogisimUITests: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// BOARD #64; THE SIX SEAMS THAT WERE READ AND NEVER ASSIGNED.
//
// Five of the six are covered here by tests that FAIL when their own install line is deleted from
// `LogisimFileProjectHostFactory.installProcessSeams`, and each was checked that way (red-probed)
// rather than assumed. The sixth, `AnalyzeSyntaxChecker.hdlKeywordCheck`, is a stated exception
// with its reasoning and its measurements in section 6 at the bottom of this file; read that
// rather than assuming it was forgotten.
//
// **"The seam is non-nil" is not one of those tests.** `WireRepairSeamTests`' header records the
// case: the obvious assertion was green against exactly the installation worth rejecting. So each
// test below drives the seam's *behaviour*; a floating component that must land in the circuit,
// a selection that must be emptied, characters that must reach a writer, a tone that must reach
// a sink, a component object that must be rebuilt. Each was also red-probed against a
// PLAUSIBLE-BUT-WRONG install (`{ }`, `{ _ in }`, a no-op sink), not only against a missing one.
//
// `.serialized`, and the reason is not caution: several of these touch process-global state
// (`TtyStdoutSink.shared`, `Buzzer.audioSinkFactory`'s product, `LoadedLibrary.replacementHandler`
// and the weak host registry it walks), and swift-testing runs `@Test`s in parallel by default.
// ═════════════════════════════════════════════════════════════════════════════════════════════

import Foundation
import LogisimFile
import LogisimHdl
import LogisimKernel
import LogisimStd
import Testing

@testable import LogisimUI

@Suite("Board #64 — the six unassigned seams", .serialized)
struct UnassignedSeamInstallTests {

  @MainActor
  private func makeHost() throws -> LogisimFileProjectHost {
    try #require(
      try LogisimFileProjectHostFactory().makeEmptyProject() as? LogisimFileProjectHost)
  }

  /// A host with its editing layer built. `makeRenderSurface()` is what constructs
  /// `CircuitEditorCanvas` and assigns `project.canvas`; without it the two `Project` hooks below
  /// correctly do nothing, which is the headless case.
  @MainActor
  private func makeHostWithCanvas() throws -> (LogisimFileProjectHost, CircuitEditorCanvas) {
    let host = try makeHost()
    _ = host.makeRenderSurface()
    return (host, try #require(host.editorCanvas))
  }

  @MainActor
  private func placePin(in circuit: Circuit, at x: Int, _ y: Int, label: String) throws
    -> any Component
  {
    let attributes = Pin.factory.createAttributeSet()
    try attributes.setValue(StdAttr.label, label)
    let pin = try Pin.factory.createComponent(
      location: Location.create(x, y, hasToSnap: false), attributes: attributes)
    try circuit.mutatorAdd(pin)
    return pin
  }

  // MARK: - 1. `Project.toolChangeHook`

  /// The data-loss one.
  ///
  /// A duplicated component is *floating*: it lives in `Selection.lifted` and nowhere else: not
  /// in the circuit, not on the undo stack. `Project.setTool` is upstream's anchor point
  /// (`SelectionActions.anchorAll` → `doAction`). With the hook unassigned the copy stays
  /// floating forever and the next `clear`/`deleteAllHelper` discards it silently.
  ///
  /// So the assertion is on the CIRCUIT, not on the selection: the duplicate has to be in it.
  @Test("picking another tool anchors a floating selection into the circuit")
  @MainActor
  func toolChangeAnchorsFloatingComponents() throws {
    let (host, canvas) = try makeHostWithCanvas()
    let project = host.project
    let circuit = try #require(host.currentCircuitObject)

    let original = try placePin(in: circuit, at: 100, 100, label: "anchor-me")
    canvas.selection.add(original)

    // The real path a user takes to get a floating component: Edit ▸ Duplicate.
    try project.doAction(SelectionActions.duplicate(canvas.selection))
    #expect(
      canvas.selection.floatingComponents.count == 1,
      "the duplicate should be floating; got \(canvas.selection.floatingComponents.count)")
    let beforeAnchor = circuit.nonWires.count

    // Upstream's condition is `value == null || !mouseMappings.containsSelectTool()`. The default
    // template binds Poke and Menu only, so either arm fires; `nil` is used because it is the
    // arm that holds whatever a file's `<mappings>` say.
    project.setTool(nil)

    #expect(
      circuit.nonWires.count == beforeAnchor + 1,
      """
      the floating duplicate was NOT anchored: \(circuit.nonWires.count) components, was \
      \(beforeAnchor). Project.toolChangeHook is not reaching SelectionActions.anchorAll, and \
      the copy exists only in Selection.lifted — it is lost on the next selection change.
      """)
    #expect(
      canvas.selection.floatingComponents.isEmpty,
      "anchoring must empty the floating set, not merely add to the circuit")

    // And it went through `doAction`, so the user can take it back. An install that called
    // `dropAll(xn)` directly would satisfy everything above and leave nothing to undo.
    #expect(project.canUndo)
    try project.undoAction()
    #expect(circuit.nonWires.count == beforeAnchor, "the anchor was not undoable")
  }

  /// The other half of upstream's condition, and the reason `anchorAll` returns `nil`: switching
  /// tools with nothing floating must not push an empty "Drop" onto the undo stack every time.
  @Test("a tool change with nothing floating leaves the undo stack alone")
  @MainActor
  func toolChangeWithNothingFloatingIsNotUndoable() throws {
    let (host, canvas) = try makeHostWithCanvas()
    let project = host.project
    let circuit = try #require(host.currentCircuitObject)

    let pin = try placePin(in: circuit, at: 140, 100, label: "already-anchored")
    canvas.selection.add(pin)
    let undoDepth = project.undoActions.count

    project.setTool(nil)

    #expect(project.undoActions.count == undoDepth)
  }

  // MARK: - 2. `Project.circuitSwitchHook`

  /// Switching circuits must not leave the selection holding components from the circuit the user
  /// just left; every subsequent selection-scoped edit would be applied off-screen.
  ///
  /// Note this drives `setCurrentCircuit`, not `setCircuitState`. That is deliberate: the app
  /// leaves `circuitStateFactory` nil (root `CircuitState`s must be built on the propagation
  /// thread), so `setCurrentCircuit`'s no-state branch is the ONLY route a real circuit switch
  /// takes. A test that went through `setCircuitState` would pass against a build the
  /// application never calls.
  @Test("switching circuits drops the selection, and anchors what was floating first")
  @MainActor
  func circuitSwitchDropsTheSelection() throws {
    let (host, canvas) = try makeHostWithCanvas()
    let project = host.project
    let first = try #require(host.currentCircuitObject)

    let second = try Circuit(name: "second", file: host.file)
    host.file.addCircuit(second)

    let anchored = try placePin(in: first, at: 100, 100, label: "anchored")
    canvas.selection.add(anchored)
    try project.doAction(SelectionActions.duplicate(canvas.selection))
    #expect(canvas.selection.floatingComponents.count == 1)
    let beforeSwitch = first.nonWires.count

    project.setCurrentCircuit(second)

    #expect(
      canvas.selection.isEmpty,
      """
      the selection still holds \(canvas.selection.components.count) component(s) after a circuit \
      switch. Project.circuitSwitchHook is not reaching SelectionActions.dropAll, so Delete or an \
      attribute edit now applies to a circuit that is not on screen.
      """)
    #expect(
      first.nonWires.count == beforeSwitch + 1,
      """
      the floating component was dropped rather than ANCHORED. dropAll must hand it back to the \
      circuit it was lifted from; discarding it is the data-loss arm.
      """)
  }

  // MARK: - 3. `Tty.sendFromTtyHook`

  /// A `Tty` whose `sendStdout` flag is set must emit its characters.
  ///
  /// Upstream's `TtyInterface.sendFromTty` is a plain `static`, so in Java the writer is always
  /// present and only the flag decides. Here it was a hook defaulting to `nil`, so the flag was
  /// inert: the component emitted nothing whatever it was told.
  @Test("a TTY set to write stdout emits its characters, and tracks the last newline")
  @MainActor
  func ttyStdoutHookIsInstalled() throws {
    _ = try makeHost()

    let collected = Collector()
    let previous = TtyStdoutSink.shared.redirect(to: { collected.append($0) })
    defer { TtyStdoutSink.shared.redirect(to: previous) }

    let state = Tty.State(rows: 4, cols: 16)
    state.setSendStdout(true)
    for character in "hi\n" { try state.add(character) }

    #expect(
      collected.text == "hi\n",
      """
      the TTY emitted \(collected.text.debugDescription) instead of "hi\\n". \
      Tty.sendFromTtyHook is unassigned, so TtyState.add's `if sendStdout` branch calls nothing.
      """)
    // `lastIsNewline`, which is the whole reason this is a type and not an inline closure:
    // `ensureLineTerminated` reads it after a `-tty` run so the shell prompt does not land
    // mid-line.
    #expect(TtyStdoutSink.shared.isAtLineStart)
    TtyStdoutSink.shared.ensureLineTerminated()
    #expect(collected.text == "hi\n", "ensureLineTerminated must not double the newline")

    try state.add("x")
    #expect(TtyStdoutSink.shared.isAtLineStart == false)
    TtyStdoutSink.shared.ensureLineTerminated()
    #expect(collected.text == "hi\nx\n")
  }

  /// The flag still gates it. A hook that wrote unconditionally would break every headless
  /// component test, which is what `nil` was protecting.
  @Test("a TTY that was never told to write stdout still emits nothing")
  @MainActor
  func ttyWithoutTheFlagStaysSilent() throws {
    _ = try makeHost()

    let collected = Collector()
    let previous = TtyStdoutSink.shared.redirect(to: { collected.append($0) })
    defer { TtyStdoutSink.shared.redirect(to: previous) }

    let state = Tty.State(rows: 4, cols: 16)
    for character in "hi\n" { try state.add(character) }

    #expect(collected.text.isEmpty)
  }

  // MARK: - 4. `Buzzer.audioSinkFactory`

  /// A placed Buzzer computed its waveform byte-for-byte correctly and threw it away.
  ///
  /// The weak assertion, the factory is non-nil, is satisfied by
  /// `Buzzer.audioSinkFactory = { NoOpSink() }`, so it is not the test. What is: the factory
  /// produces the real `BuzzerAudioEngineSink`, that sink takes a tone and holds it, and it
  /// either started an engine or says why it could not. "Silent" and "silently broken" have to
  /// stay distinguishable, because a CI box with no output device is a legitimate case.
  @Test("the buzzer's audio sink is installed and accepts a tone")
  @MainActor
  func buzzerAudioSinkIsInstalled() throws {
    _ = try makeHost()

    let factory = try #require(
      Buzzer.audioSinkFactory,
      """
      Buzzer.audioSinkFactory is unassigned: a placed Buzzer computes its waveform and discards \
      it, so the component is silent in the app.
      """)
    let sink = try #require(
      factory() as? BuzzerAudioEngineSink,
      "the factory produced something other than the real sink")

    // Silence at a real sample rate: audible nothing, and the buffer geometry a Buzzer actually
    // produces (4 bytes per frame, interleaved stereo).
    let tone = BuzzerTone(sampleRate: 44100, pcm: [UInt8](repeating: 0, count: 4 * 64))
    sink.loop(tone)

    #expect(sink.currentTone == tone, "the sink did not take the tone")
    #expect(
      sink.isRunning || sink.lastFailure != nil,
      "the sink neither started nor recorded why it could not — that is a silent no-op")

    sink.stop()
    #expect(sink.currentTone == nil, "stop() must release the tone, as Clip.close() does")
  }

  /// The one part of the sink that can be checked exactly with no audio device: upstream's
  /// interleaved 16-bit little-endian buffer, as deinterleaved Float32.
  @Test("the PCM conversion is exact, including the most negative sample")
  func buzzerPcmConversionIsExact() {
    // Frame 0: left = +1 (0x0001), right = -1 (0xFFFF).
    // Frame 1: left = Int16.min (0x8000), right = Int16.max (0x7FFF).
    let tone = BuzzerTone(
      sampleRate: 44100,
      pcm: [0x01, 0x00, 0xFF, 0xFF, 0x00, 0x80, 0xFF, 0x7F])
    let (left, right) = BuzzerAudioEngineSink.frames(from: tone)

    let expectedLeft: [Float] = [Float(1) / 32768, Float(-1)]
    let expectedRight: [Float] = [Float(-1) / 32768, Float(32767) / 32768]
    #expect(left == expectedLeft)
    #expect(right == expectedRight)
  }

  // MARK: - 5. `LoadedLibrary.replacementHandler`

  /// A library reload built a complete old→new map of factories and tools and handed it to
  /// nobody, so every already-placed component kept pointing at a factory belonging to the file
  /// that had just been replaced.
  ///
  /// Driven through the handler directly rather than through `LibraryManager.reload`, because
  /// what is under test is the JOIN, that something receives the map and rewrites the placed
  /// components, and `resolveChanges` producing the map correctly is already exercised where it
  /// is computed.
  @Test("a library replacement rebuilds the components placed from it")
  @MainActor
  func libraryReplacementRewritesPlacedComponents() throws {
    let host = try makeHost()
    let circuit = try #require(host.currentCircuitObject)
    let original = try placePin(in: circuit, at: 100, 100, label: "survives-a-reload")

    let handler = try #require(
      LoadedLibrary.replacementHandler,
      """
      LoadedLibrary.replacementHandler is unassigned: reloading a library leaves every placed \
      component bound to the factory from the file that was just replaced.
      """)

    // The identity arm: the factory is unchanged, so the rewrite is observable only as the
    // component object being REBUILT: remove plus re-add, with attributes copied across. A
    // handler that quietly did nothing would leave the same object in place and pass every
    // count-based assertion.
    handler(
      LibraryReplacement(
        factories: [ObjectIdentifier(Pin.factory): Pin.factory], tools: [:]))

    #expect(LibraryReplacementApply.lastFailures.isEmpty)
    #expect(circuit.nonWires.count == 1, "the rewrite changed how many components there are")
    let rebuilt = try #require(circuit.nonWires.first)
    #expect(
      rebuilt !== original,
      """
      the component was not rebuilt. LoadedLibrary.replacementHandler is doing nothing, so a \
      reloaded library's components keep painting, propagating and saving from the OLD definition.
      """)
    #expect(rebuilt.location == original.location)
    #expect(
      rebuilt.attributeSet[StdAttr.label] == "survives-a-reload",
      "createAttributes must copy the old attribute values onto a fresh set from the new factory")
  }

  /// Upstream's `if (factory != null)`: a factory that is gone from the reloaded library takes
  /// its components with it rather than leaving them bound to a dead definition.
  @Test("a factory removed by the reload takes its components out of the circuit")
  @MainActor
  func libraryReplacementRemovesVanishedFactories() throws {
    let host = try makeHost()
    let circuit = try #require(host.currentCircuitObject)
    _ = try placePin(in: circuit, at: 100, 100, label: "gone")
    let handler = try #require(LoadedLibrary.replacementHandler)

    // `updateValue(nil, forKey:)`, not a subscript assignment: assigning a `nil` value through
    // the subscript REMOVES the key, which is the difference between "this factory is gone" and
    // "this factory was not part of the reload".
    var factories: [ObjectIdentifier: (any ComponentFactory)?] = [:]
    factories.updateValue(nil, forKey: ObjectIdentifier(Pin.factory))
    handler(LibraryReplacement(factories: factories, tools: [:]))

    #expect(circuit.nonWires.isEmpty)
  }

  // MARK: - 6. `AnalyzeSyntaxChecker.hdlKeywordCheck`
  //
  // ── READ THIS BEFORE TRUSTING THE TEST BELOW ────────────────────────────────────────────────
  //
  // This is the ONE seam of the six whose *install-presence* is not pinned by a test, and saying
  // so is more useful than a test that only looks like one.
  //
  // The seam is a process-global that `LogisimAnalyzeTests.syntaxCheckerMatchesTheJavaOracle`
  // DELIBERATELY rewrites: it installs a stub, asserts, then writes `nil` and asserts the
  // documented more-permissive behaviour, and leaves it `nil`. Its own header says both halves
  // are one test on purpose, because two writers of one global race. Any assertion here of the
  // form "after registration the seam is non-nil" is a third writer's reader, and would fail
  // whenever it landed after that test.
  //
  // The obvious fix, put the phase inside that test, which needs `LogisimAnalyzeTests` to link
  // `LogisimUI`, was implemented, red-probed and then WITHDRAWN, because it destabilised the
  // suite. Measured on this machine, full `swift test`, no `LOGISIM_CORPUS`:
  //
  //     with the dependency: 1, 2 and 3 issues over three runs (VhdlAdaptorTests,
  //                              StatsVhdlEntityTests, LibraryDropDivergenceTests; all
  //                              green under --filter)
  //     without it: 1 issue over two runs, and 1 over two baseline runs
  //                              (ValueGoldenTests, which fails without the corpus)
  //
  // The extra failures are not new defects: `LogisimFileTests` wipes `LogisimFileSeams`
  // process-wide while `LogisimUITests` installs into it, and which suite wins is scheduling.
  // Linking one more target shifted the schedule. That cross-target global-state race is a real
  // problem and it belongs on the board, not inside a workaround here.
  //
  // What IS pinned below: the closure the host installs answers exactly what the jar answers.
  // That is the half that could be silently wrong: a keyword list that disagrees, or an
  // `HdlLanguage` whose raw values stop matching the two strings `AnalyzeSyntaxChecker:83`
  // compares. The half that is NOT pinned, that the line exists in
  // `installProcessSeams`, is covered deterministically by `tools/deadseam.py`, which reports
  // `hdlKeywordCheck` as READ-but-never-ASSIGNED the moment it is deleted.

  /// The install is `{ CorrectLabel.hdlCorrectLabel($0)?.rawValue }` and nothing else, so this
  /// spells the same expression and checks it against the rows `AnalyzeFileGolden.syntaxErrors`
  /// captured from the shipped 4.1.0 jar.
  ///
  /// `"VHDL"` and `"Verilog"` are not decoration: they are the two literals
  /// `AnalyzeSyntaxChecker` compares the returned flavour against to pick its message key, so a
  /// rename of either `HdlLanguage` case's raw value silently turns every VHDL keyword into a
  /// Verilog one.
  @Test("the closure the host installs answers what the jar answers")
  func hdlKeywordCheckClosureMatchesTheJar() {
    let check: (String) -> String? = { CorrectLabel.hdlCorrectLabel($0)?.rawValue }

    for keyword in ["in", "out", "entity", "signal", "begin"] {
      #expect(check(keyword) == "VHDL", "\(keyword) should be a VHDL keyword")
    }
    for keyword in ["module", "wire", "reg", "always"] {
      #expect(check(keyword) == "Verilog", "\(keyword) should be a Verilog keyword")
    }
    for name in ["a", "abc", "A1", "a_b", "counter"] {
      #expect(check(name) == nil, "\(name) is not a keyword in either language")
    }
    // `hdlCorrectLabel` lowercases before the VHDL lookup and does not before the Verilog one:
    // upstream's asymmetry, and the reason this is checked rather than assumed symmetric.
    #expect(check("SIGNAL") == "VHDL")
    #expect(check("") == nil)
  }
}

/// A `Sendable` string accumulator for the TTY writer, which is `@Sendable` because
/// `Tty.State.add` runs on the propagation thread (D1).
private final class Collector: @unchecked Sendable {
  private let lock = NSLock()
  private var storage = ""
  func append(_ text: String) { lock.withLock { storage += text } }
  var text: String { lock.withLock { storage } }
}
