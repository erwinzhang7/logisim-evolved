// Project.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.proj.Project),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only.
// SPDX-License-Identifier: GPL-3.0-only
//
// Ported from the **4.1.0** tree (D16).
//
// ── What `Project` owns ─────────────────────────────────────────────────────────────────────
//
// One open document: its `LogisimFile`, which circuit is being edited, the simulation state for
// each circuit, the current tool, and the undo/redo stacks. Everything the editing layer does
// goes through `doAction`, and everything the user can reverse is in `undoLog`.
//
// ── D3: this graph is cyclic in five places, and Java does not care ─────────────────────────
//
// | edge                                   | direction | here      | why                        |
// |----------------------------------------|-----------|-----------|----------------------------|
// | `Project` → `LogisimFile`              | owning    | strong    | the document owns its file |
// | `Circuit.file` → `LogisimFile`         | back edge | weak      | already so in LogisimFile  |
// | `Project` → root `CircuitState`s       | owning    | strong    | `allRootStates` is the list|
// | `CircuitState.project` → `Project`     | back edge | weak      | D3 names `proj` explicitly |
// | `Project.frame` → the window           | back edge | weak      | D3 names `Project.frame`   |
// | `ActionData.circuitState`              | duplicate | strong    | not a cycle: the project   |
// |                                        |           |           | already owns every root    |
// |                                        |           |           | state, so this only pins   |
// |                                        |           |           | what is pinned anyway      |
// | listener lists                         | back edge | weak      | `EventSourceWeakSupport`   |
//
// The one that would actually leak a whole document if it were strong is `frame`: a window
// retains its project, and a project that retained its window would keep the entire circuit
// graph, every component, every simulation state, alive for the life of the process after
// the user closes the tab. That is D3's motivating case, and it is why the type is `AnyObject`
// behind a `weak` here rather than a concrete window class.
//
// ── The undo model, and the upstream quirks preserved ───────────────────────────────────────
//
// The stacks are bounded at 64 entries each. Beyond that the oldest is discarded, so a long
// editing session cannot undo back to the start; that is upstream's behaviour and users depend
// on the memory ceiling it implies.
//
// Two things in here look like bugs and are ported as they are, because M7's pass condition is
// matching Java, not improving on it. Each is called out at its site:
//
//   1. The coalescing branch of `doAction` does not trim `undoLog` to `MAX_UNDO_SIZE`. It cannot
//      grow the log, so the omission is harmless, but it means the trim is not an invariant.
//   2. `redoLog` is cleared at the top of `doAction` *before* anything can throw, so a failed
//      edit destroys the redo stack.
//
// A third, `redoAction` incrementing `undoMods` unconditionally, where `undoAction` decrements
// it only for modifying actions, used to be on that list. It is gone, along with `undoMods`
// itself; see "Dirty state" below.
//
// ── DELIBERATE DIVERGENCE: what "dirty" means ───────────────────────────────────────────────
//
// Upstream answers "does this document differ from the last save?" with `undoMods > 0`, a net
// count of modifying actions on the undo stack, zeroed by `setFileAsClean()`. That predicate is
// wrong in four ways a user reaches from the GUI, and all four lose or misrepresent work because
// `LogisimFile.setDirty(false)` also disarms the crash-recovery sidecar:
//
//   * Save, then Undo. `setFileAsClean()` zeroed the count, so the undo takes it to -1 and
//     `ifgt` answers false. File > Save and File > Revert are greyed out, closing raises no
//     prompt, and no sidecar is written.
//   * Add, Undo, Redo from a clean document. `redoAction` never called `file.setDirty`, so the
//     project reported dirty while the file -- cleared by the undo one line earlier -- reported
//     clean. The autosave loop read the stale file flag and wrote nothing.
//   * Save, Undo, then a different edit. The count returns to 0: the document reports clean with
//     an unsaved circuit on the stack. No signed count can express this, which is why the fix is
//     not `undoMods != 0`.
//   * Edit > Clear Undo History. Upstream zeroes the count and publishes nothing, which makes the
//     project report saved because the user threw away history, not because bytes reached disk.
//
// What replaces it: every undo entry carries a serial, and the document's state is named by the
// serial of the topmost modifying entry on the undo stack. `setFileAsClean()` records that serial
// as the save point, and dirty means "the serial now differs from the one that was saved". Undo,
// redo, coalescing and history clearing all move the stack, so all four move the answer, and no
// arithmetic has to stay balanced for it to be right.
//
// This is a D18 second-arm divergence, not a drift. 4.1.0's bytecode, from the shipping jar:
//
//   isFileDirty(): 1: getfield undoMods:I / 4: ifgt 14 / 8: getfield forcedDirty:Z
//   redoAction(): 29: getfield undoMods:I / 32: iconst_1 / 33: iadd
//                     103: Action.doIt / 106..118: fireEvent(12)            (no setDirty)
//   discardAllEdits(): 16: putfield undoMods:I / 19..31: fireEvent(6)       (no setDirty)
//
// The save/dirty story is already a place this port declines to copy Java: `serialize()` is a
// pure read, a save is confirmed by reading the bytes back off the disk, and none of that is
// upstream (see `Document/SaveConfirmation.swift`). "Do not lie to the user about what is saved"
// wins over bytecode fidelity here, and `UndoRedoDirtyStateTests` pins every leg.

import Foundation
import LogisimFile

/// The seam for `com.cburch.logisim.circuit.CircuitState`.
///
/// `CircuitState` exists in `LogisimKernel/Propagation`, but it is generic over a `SimCircuit`
/// that `LogisimFile.Circuit` does not conform to yet; wiring those two together is M3's job,
/// not this slice's. Declaring what `Project` actually needs from a state keeps the undo stack
/// buildable and testable today, and means M3 supplies a conformance rather than editing this
/// file.
@MainActor
public protocol ProjectCircuitState: AnyObject {
  /// `getCircuit()`.
  var stateCircuit: Circuit { get }
  /// `getParentState()`: `nil` for a root state. Only root states go in `recentRootState`.
  var parentProjectState: (any ProjectCircuitState)? { get }
}

/// The seam for `com.cburch.logisim.circuit.Simulator`, restricted to what `Project` calls on it.
///
/// D7 rebuilt the tick scheduler and that work lives in `LogisimKernel/Simulation`; the
/// `Simulator` façade that owns it is M3. `Project` needs four things from it and no more.
@MainActor
public protocol ProjectSimulator: AnyObject {
  func setCircuitState(_ state: (any ProjectCircuitState)?)
  var tickFrequency: Double { get }
  func setTickFrequency(_ value: Double)
}

/// Creates root simulation states. `CircuitState.createRootState(proj, circuit)`.
///
/// Until one is installed `Project` runs with no states at all, which is exactly what a
/// headless scripted-edit run wants: `ActionData.circuitState` is `nil`, undo and redo skip
/// their `setCircuitState` restore, and every edit still reaches the netlist through its own
/// `CircuitChange`, which names its circuit explicitly. The saved `.circ` is unaffected.
///
/// **NOT-PORTED: deliberately unconformed, and this is not a seam.** The simulation is real
/// (see `SimulationEngine`), but its root `CircuitState`s are created *on the propagation
/// thread*: `SimulationHost` captures `Thread.current` as the thread `Propagator` asserts
/// against at 62 sites (D1), so a state built anywhere else installs an assertion every
/// subsequent propagation fails. This protocol and its sibling `ProjectCircuitState` are
/// `@MainActor`, so conforming to them would mean handing the main actor a reference to an
/// object it must never touch; the conformance would compile, and reading through it would be
/// a data race on the simulation engine.
///
/// So `LogisimFileProjectHost` leaves `circuitStateFactory` nil on purpose and drives the
/// engine directly, and `Project` takes the no-state path its own comments describe.
///
/// NOT-PORTED: no conformer, deliberately. Filling this in means first deciding how the
/// editing layer observes simulation state across the propagation-thread boundary: the same
/// decision as putting live values on the canvas, recorded as a gap in `SimulationEngine`'s
/// header. It is not work that has been forgotten.
@MainActor
public protocol ProjectCircuitStateFactory: AnyObject {
  func makeRootState(project: Project, circuit: Circuit) -> any ProjectCircuitState
}

/// `com.cburch.logisim.proj.Project`.
/// `@MainActor`: see `Tool.swift`'s header for the module-wide rule. Everything the user's
/// editing gestures reach is isolated, because Java confines all of it to the EDT and the
/// annotation is the compiler-checked version of that confinement. The transaction substrate
/// below this (`CircuitTransaction`, `CircuitLocker`, `CircuitMutator`, `CircuitChange`,
/// `ReplacementMap`) is deliberately *not*, because upstream takes real per-circuit locks there
/// precisely so a transaction can run off the EDT.
@MainActor
public final class Project {

  /// `MAX_UNDO_SIZE` / `MAX_REDO_SIZE`.
  public static let maxUndoSize = 64
  public static let maxRedoSize = 64

  /// `ActionData`: an undo entry, plus the editing context to restore before replaying it.
  ///
  /// The context is the reason undo works across circuits: undoing an edit made in a subcircuit
  /// switches back to that subcircuit first, so the user sees what is being reversed rather than
  /// watching an unrelated canvas not change.
  private struct ActionData {
    let circuitState: (any ProjectCircuitState)?
    /// `hdlModel`. The VHDL content editor's undo entries. Untyped here for the same reason
    /// `ProjectEventData.selection` is, the HDL model belongs to a later slice, and carried
    /// rather than dropped so the restore branch below is the real two-armed one.
    let hdlModel: AnyObject?
    let action: Action
    /// Which document state applying this entry produces. **Not upstream**; see the dirty-state
    /// divergence note in the header. Allocated when the entry is first pushed by `doAction` and
    /// carried unchanged across undo and redo: that is what makes redoing back to the save point
    /// clean rather than merely "one fewer modification than it was".
    ///
    /// A coalescing merge allocates a new one, because the merged pair leaves the model somewhere
    /// neither half did.
    let serial: Int
  }

  // MARK: - Stored state

  /// `file`. Owning; see the D3 table in the header.
  private var file: LogisimFile

  /// `hdlModel`.
  private var hdlModelRef: AnyObject?

  /// `circuitState`, the active simulation state.
  private var circuitStateRef: (any ProjectCircuitState)?

  /// `recentRootState`: most recent root state per circuit. D4: identity-keyed, circuit
  /// carried in the value, because `Circuit` has no `Hashable` and must not gain one.
  private var recentRootState: [ObjectIdentifier: any ProjectCircuitState] = [:]

  /// `allRootStates`: every root state, in display order. This is the owning list.
  private var allRootStates: [any ProjectCircuitState] = []

  /// `frame`. D3: **weak**, and the single most important weak edge in the app, see the header.
  public weak var frame: AnyObject?

  /// `tool`.
  public private(set) var tool: Tool?

  private var undoLog: [ActionData] = []
  private var redoLog: [ActionData] = []

  /// Replaces upstream's `undoMods`; see the header's divergence note.
  ///
  /// Monotonic and never reused, so a serial identifies one document state for the life of the
  /// project. Gaps are harmless: a throwing edit restores the stack before the error escapes but
  /// does not rewind this counter, because no user-visible state ever carries the skipped serial.
  private var nextActionSerial = 1

  /// The serial of the state the model was in at the last confirmed save (`setFileAsClean()`).
  private var savedStateSerial = 0

  /// The serial of the state an empty undo stack represents.
  ///
  /// Zero for a file just opened or created. It moves when the 64-entry trim drops an entry: that
  /// edit is still applied to the model, it has merely stopped being reversible, so "nothing left
  /// to undo" no longer means "the state the file loaded in".
  private var baseStateSerial = 0

  /// `forcedDirty`; set by edits that are not undoable but do change the file, e.g. a tick
  /// frequency change. Also the latch `discardAllEdits()` parks dirtiness in when it throws away
  /// the stack the save point was measured against.
  private var forcedDirty = false

  /// `startupScreen`: true for the empty project opened at launch, so it can be closed silently
  /// when a real file is opened.
  public private(set) var isStartupScreen = false

  private var projectListeners = WeakListeners<ProjectListener>()
  private var fileListeners = WeakListeners<LibraryListener>()
  private var circuitListeners = WeakListeners<CircuitListener>()

  /// `simulator`. Java constructs one eagerly; here it is injected, because the `Simulator`
  /// façade is M3's. `nil` means "no simulation attached", which a headless edit run wants.
  public var simulator: (any ProjectSimulator)?

  /// The factory for root simulation states. `nil` until M3 installs one; see
  /// `ProjectCircuitStateFactory`.
  public var circuitStateFactory: (any ProjectCircuitStateFactory)?

  /// `myListener`; the project's own `LibraryListener`. Owned by the project and holding an
  /// `unowned` edge back, so the weak listener list does not drop it immediately.
  private var myListener: ProjectLibraryListener!

  /// The circuit being edited when no simulation state exists.
  ///
  /// Upstream derives the current circuit purely from `circuitState.getCircuit()`, which is fine
  /// there because a state always exists. With the M3 seam unfilled a project would otherwise
  /// have no current circuit at all and every `CircuitMutation(proj.getCurrentCircuit())` call
  /// site would break, so the circuit is tracked directly and the state, when present, wins.
  private var currentCircuitRef: Circuit?

  // MARK: - Construction

  public init(file: LogisimFile) {
    self.file = file
    self.myListener = ProjectLibraryListener(project: self)
    addLibraryListener(myListener)
    setLogisimFile(file)
  }

  // MARK: - Accessors

  /// `getLogisimFile()`.
  public var logisimFile: LogisimFile { file }

  /// `getOptions()`.
  public var options: Options { file.options }

  /// `getCircuitState()`.
  public var circuitState: (any ProjectCircuitState)? { circuitStateRef }

  /// `getCurrentCircuit()`.
  public var currentCircuit: Circuit? { circuitStateRef?.stateCircuit ?? currentCircuitRef }

  /// `getCurrentHdl()`.
  public var currentHdlModel: AnyObject? { hdlModelRef }

  /// `getRootCircuitStates()`.
  public var rootCircuitStates: [any ProjectCircuitState] { allRootStates }

  // MARK: - Canvas reach-throughs
  //
  // Everything in this section arrived from `Tools/ToolSeams.swift`'s `ToolProject` and
  // `Selection/SelectionSeam.swift`'s `SelectionProject`, the two stand-ins the parallel M7
  // slices wrote for this class. Their doc comments came with them: each one records something
  // about upstream's behaviour that is easy to lose and expensive to rediscover.

  /// `getFrame().getCanvas()`.
  ///
  /// D3: **weak**, for the same reason `frame` is; the canvas is a view, the view retains its
  /// project, and a strong edge here would keep the entire circuit graph alive for the life of
  /// the process after the user closes the tab.
  public weak var canvas: (any ToolCanvas)?

  /// `getSelection()`; `frame.getCanvas().getSelection()` (`Project.java:397-402`).
  ///
  /// Note the direction: the **canvas** owns the selection and the project reaches through, which
  /// is why this is optional and why `Project` does not construct one. Upstream returns null both
  /// when there is no frame and when the frame has no canvas; both collapse to `nil` here.
  public var selection: Selection? { canvas?.selection }

  // `selectionActions` used to sit here: a computed property returning `SelectionActions.self`,
  // inherited from the `ToolProject` stand-in, which vended the factories as an object so a test
  // could fake them. It is gone. It was not actually injectable, a get-only computed metatype,
  // so it bought nothing, and Java calls these as plain statics (`SelectionActions.drop(...)`),
  // which is what the call sites now do.
  //
  // The note it carried is worth keeping, because it is a property of the factories and not of
  // how they are reached: **each returns `nil` in exactly the cases upstream's does**: a drop
  // with nothing to drop, a `dropAll` on an empty selection. Every caller must keep null-checking
  // it, and `Project.perform` does; that is what keeps empty no-op entries off the undo stack.

  /// `getDependencies()`; `Project.depends` (`Project.java:353`).
  ///
  /// Typed as the seam protocol because `com.cburch.logisim.proj.Dependencies` is not ported; see
  /// `CircuitDependencyGraph`. `nil` means "no dependency graph installed", and every caller
  /// treats that as permissive, which is the safe direction: it can let a subcircuit placement
  /// through that upstream would have refused, and never blocks one upstream allows.
  public var dependencies: (any CircuitDependencyGraph)?

  /// `getDependencies().canAdd(Circuit, Circuit)`, the subcircuit cycle check.
  public func canAddSubcircuit(_ subcircuit: Circuit, to circuit: Circuit) -> Bool {
    dependencies?.canAdd(circuit, subcircuit) ?? true
  }

  /// `getFrame().getCanvas().getCircuit()`.
  ///
  /// Upstream reads this separately from `getCurrentCircuit()` inside `Paste.doItFirstTime` and
  /// then uses it for the circularity check. They are the same circuit in every reachable state,
  /// but the two reads are kept distinct so the port does not quietly pick one.
  public var canvasCircuit: Circuit? { canvas?.circuit }

  /// `getLogisimFile().contains(Circuit)`: false for a circuit from a *loaded library*, which is
  /// read-only. Every tool checks this before its first mutation and reports `cannotModifyError`;
  /// skipping it would let a tool edit a library file in place.
  public func fileContains(_ circuit: Circuit) -> Bool {
    file.contains(circuit: circuit)
  }

  /// `new CircuitMutation(circuit)`.
  ///
  /// Two spellings existed in the stand-ins (`beginMutation(on:)` and `makeCircuitMutation(_:)`)
  /// and both are kept, because the optional-circuit form is the one `SelectionActions` needs;
  /// a paste with no destination circuit still has to produce a mutation object to hand back.
  public func beginMutation(on circuit: Circuit) -> CircuitMutation {
    CircuitMutation(circuit)
  }

  public func makeCircuitMutation(_ circuit: Circuit?) -> CircuitMutation {
    guard let circuit else { return CircuitMutation() }
    return CircuitMutation(circuit)
  }

  /// `getFrame().getCanvas().setErrorMessage(StringGetter)`; `nil` clears it.
  ///
  /// D9: the message is a plain value and its presentation belongs to the shell. The *decision*
  /// to raise one (a paste refused because it would make a circuit contain itself) is model
  /// behaviour and is kept.
  public func setErrorMessage(_ message: String?) {
    canvas?.setStatusMessage(message.map { .literal($0) })
  }

  /// `getFrame().viewComponentAttributes(Circuit, Component)`.
  ///
  /// Routed through a hook rather than a `Frame` seam: it is the only thing the tools ask a frame
  /// for, and one closure is cheaper than dragging the whole window type into this layer.
  public var viewComponentAttributesHook: ((Circuit, any Component) -> Void)?

  public func viewComponentAttributes(_ circuit: Circuit, _ component: any Component) {
    viewComponentAttributesHook?(circuit, component)
  }

  /// `getLogisimFile().getLibrary(BaseLibrary._ID).getTool(EditTool._ID)`, resolved for the
  /// caller. `nil` when the base library is absent, which upstream also tolerates.
  ///
  /// **What this returns today is a `BuiltinPlaceholderTool`, not an `EditTool`.** `BaseLibrary`
  /// lives in `LogisimStd`, which cannot name the six tools, they are here, above it, so its
  /// tool list is placeholders keyed by `_ID` and its own header says so. Installing the real
  /// ones is the "builtin tools" half of the unwired-handler-seams task, and it is not this
  /// slice's file to do.
  ///
  /// The consequence is bounded and fails safe rather than silently:
  /// `CanvasToolController.upgrade(_:)` answers `nil` for a placeholder, so
  /// `setActiveTool(fromLibrary:)` returns false and leaves the working tool selected. `AddTool`'s
  /// switch-back-after-placing and `selectEditTool()` therefore do nothing yet, instead of
  /// swapping in an inert tool that swallows every subsequent click.
  public var editTool: Tool? {
    file.library(named: "Base")?.tool(named: EditTool.toolId)
  }

  /// `LayoutEditHandler.selectSelectTool(Project)`: switch the active tool to the Edit tool,
  /// which both Paste and Select All do before touching the selection.
  public func selectEditTool() {
    guard let editTool else { return }
    setTool(editTool)
  }

  /// `getCircuitState(Circuit)`: the state to simulate `circuit` in, created on demand.
  public func circuitState(for circuit: Circuit) -> (any ProjectCircuitState)? {
    if let current = circuitStateRef, current.stateCircuit === circuit { return current }
    let key = ObjectIdentifier(circuit)
    if let existing = recentRootState[key] { return existing }
    guard let created = circuitStateFactory?.makeRootState(project: self, circuit: circuit) else {
      return nil
    }
    recentRootState[key] = created
    allRootStates.append(created)
    return created
  }

  // MARK: - Undo / redo

  /// `getLastAction()`.
  ///
  /// Callers compare it by **identity**, and that is what makes the
  /// backspace-undoes-my-last-placement shortcut in `CanvasAddTool` and `WiringTool` safe: each
  /// keeps a weak reference to the action it pushed and only undoes when the action still on top
  /// of the stack is that same object. Compare by value and the shortcut would undo a
  /// structurally identical edit somebody else made in between.
  public var lastAction: Action? { undoLog.last?.action }

  /// `getLastRedoAction()`.
  public var lastRedoAction: Action? { redoLog.last?.action }

  /// `getCanRedo()`.
  public var canRedo: Bool { !redoLog.isEmpty }

  public var canUndo: Bool { !undoLog.isEmpty }

  /// `getUndoActions()` / `getRedoActions()`: newest first, which is the order the Edit menu's
  /// history submenu lists them in.
  public var undoActions: [Action] { undoLog.reversed().map(\.action) }
  public var redoActions: [Action] { redoLog.reversed().map(\.action) }

  /// The serial of the state the model is in right now: the topmost modifying entry on the undo
  /// stack, or `baseStateSerial` if there is none.
  ///
  /// The `isModification` filter keeps a Copy -- a show-only action -- from naming a document
  /// state of its own. A linear scan of at most 64 entries, run once per edit and once per menu
  /// enablement query; caching it incrementally is precisely the bookkeeping whose failure to
  /// stay balanced this replaces.
  private var appliedStateSerial: Int {
    undoLog.last { $0.action.isModification }?.serial ?? baseStateSerial
  }

  /// `isFileDirty()`. **Diverges from upstream's `undoMods > 0 || forcedDirty`**; see the header.
  /// "The document differs from the state that was last confirmed on disk", asked once here and
  /// pushed everywhere else by `publishDirtyState()`.
  public var isFileDirty: Bool { appliedStateSerial != savedStateSerial || forcedDirty }

  /// `doAction(Action)`; the single entry point for every undoable edit.
  ///
  /// The coalescing branch is the reason `Action` is a reference type. `act.shouldAppendTo` is
  /// asked of the incoming action about the one already on the stack, and every implementation
  /// answers with an identity comparison (see `Action.swift`'s header). When it says yes, the
  /// top entry is popped, the two are merged with `append`, and the merged action is pushed,
  /// so a drag that emits fifty move actions leaves exactly one entry behind.
  ///
  /// Note what is *not* skipped on the merge path: `act.doIt` still runs. `append` records that
  /// the two actions belong together; it does not apply the second one. Getting that backwards
  /// produces a drag whose first sample is applied and whose remaining travel is not.
  /// Taken around every action, so an edit issued by a tool serialises against the propagation
  /// thread exactly as one issued through `LogisimFileProjectHost` already does.
  ///
  /// This exists because the two edit paths did not agree. The host wraps every mutation in
  /// `performOnModel { … }`, which takes `SimulationEngine.modelLock`; the tools mutate through
  /// `doAction` deep inside `mouseReleased`, and that path took no lock at all. Routing the live
  /// canvas through the tool layer without this would have introduced a data race against the
  /// propagation thread: silently, in the shipping app, with no oracle to catch it.
  ///
  /// A closure rather than a lock reference because `Project` is in the slice that must not know
  /// about `SimulationEngine`. `nil` means unguarded, which is what every headless test and the
  /// CLI want: there is no propagation thread to race with.
  ///
  /// The lock the host installs must be recursive; its own `performOnModel` nesting is legal and
  /// has to stay so. Note `SelectTool.commitMove` blocks on the connector thread while holding it;
  /// the connector thread never takes `modelLock`, so there is no cycle, and upstream has the same
  /// shape (the EDT blocks on the connector).
  public var modelGuard: ((() throws -> Void) throws -> Void)?

  public func doAction(_ action: Action?) throws {
    guard let modelGuard else { return try performAction(action) }
    try modelGuard { try self.performAction(action) }
  }

  private func performAction(_ action: Action?) throws {
    guard let action else { return }
    isStartupScreen = false
    // Quirk 3 (see header): upstream clears the redo stack before `doIt` can throw, so a failed
    // edit costs the user their redo history. Preserved.
    redoLog.removeAll()

    if let last = undoLog.last?.action, action.shouldAppendTo(last) {
      let firstData = undoLog.removeLast()
      let first = firstData.action

      let merged = first.append(action)
      if let merged {
        // A new serial, not `firstData.serial`: the merged pair leaves the model somewhere the
        // first half alone did not, so a save taken between the two samples must still show as
        // outstanding. `nil` means the append annihilated the pair and the entry is dropped
        // entirely; the state below it is then the state the model is in.
        undoLog.append(
          ActionData(
            circuitState: circuitStateRef, hdlModel: hdlModelRef, action: merged,
            serial: takeActionSerial()))
      }

      fireEvent(ProjectEvent(action: .actionStart, project: self, data: .action(action)))
      do {
        try action.doIt(self)
      } catch {
        if merged != nil { undoLog.removeLast() }
        undoLog.append(firstData)
        publishDirtyState()
        throw error
      }
      publishDirtyState()
      fireEvent(ProjectEvent(action: .actionComplete, project: self, data: .action(action)))
      fireEvent(
        ProjectEvent(
          action: .actionMerge, project: self, oldData: .action(first),
          data: merged.map { ProjectEventData.action($0) } ?? .none))
      // Quirk 2 (see header): no `maxUndoSize` trim on this path. The log cannot have grown,
      // one entry out, at most one back in, so it is harmless, but it is not an invariant.
      return
    }

    undoLog.append(
      ActionData(
        circuitState: circuitStateRef, hdlModel: hdlModelRef, action: action,
        serial: takeActionSerial()))
    fireEvent(ProjectEvent(action: .actionStart, project: self, data: .action(action)))
    do {
      try action.doIt(self)
    } catch {
      undoLog.removeLast()
      publishDirtyState()
      throw error
    }
    while undoLog.count > Project.maxUndoSize {
      let dropped = undoLog.removeFirst()
      // The edit stays applied; only its reverse is gone. So the state an empty stack stands for
      // moves up to it -- see `baseStateSerial`.
      if dropped.action.isModification { baseStateSerial = dropped.serial }
    }
    publishDirtyState()
    fireEvent(ProjectEvent(action: .actionComplete, project: self, data: .action(action)))
  }

  /// `doAction(Action)` from a context that cannot throw, which is every `CanvasTool` mouse and
  /// key handler, because AWT's listener methods do not throw either.
  ///
  /// D13's rule is that a catchable Java exception becomes a Swift `throw`. It does not say every
  /// caller can propagate one, and these cannot: `mousePressed` is a protocol requirement driven
  /// by an `NSEvent`. Upstream's equivalent failure escapes into the EDT's uncaught-exception
  /// handler and the visible effect is that the edit silently does not happen. Here it lands in
  /// `pendingDiagnostics`, which is what D17's headless rule does with every other non-fatal
  /// problem: same visible effect, but the failure is recoverable and recorded rather than lost.
  ///
  /// **The closure form is deliberate.** Constructing a selection action can throw as well as
  /// performing it, `SelectionActions.drop` reaches `Selection.remove`, so building and
  /// performing have to sit inside the same `do`. Returning `nil` is how the `SelectionActions`
  /// factories say "nothing to do", and it must stay a no-op: pushing an empty entry is what
  /// `Action.append` returning `nil` exists to prevent.
  /// Returns whether the edit went through. Discardable, because most callers have nothing to do
  /// either way, but two do, and they are why it is returned at all: `CanvasAddTool` and
  /// `WiringTool` record the action they just pushed so Backspace can undo *that* one, and in
  /// Java the exception skips that assignment. Ignoring the result here would leave the tool
  /// claiming an edit it did not make.
  @discardableResult
  public func perform(_ makeAction: () throws -> Action?) -> Bool {
    do {
      try doAction(try makeAction())
      return true
    } catch {
      pendingDiagnostics.append("edit failed: \(error)")
      return false
    }
  }

  /// `undoAction()` from a context that cannot throw. Same reasoning as `perform`.
  public func undoActionReportingFailure() {
    do {
      try undoAction()
    } catch {
      pendingDiagnostics.append("undo failed: \(error)")
    }
  }

  /// `undoAction()`.
  public func undoAction() throws {
    guard let data = undoLog.last else { return }
    redoLog.append(data)
    while redoLog.count > Project.maxRedoSize {
      redoLog.removeFirst()
    }
    undoLog.removeLast()

    restoreEditingContext(state: data.circuitState, hdlModel: data.hdlModel)

    let action = data.action
    fireEvent(ProjectEvent(action: .undoStart, project: self, data: .action(action)))
    try action.undo(self)
    publishDirtyState()
    fireEvent(ProjectEvent(action: .undoComplete, project: self, data: .action(action)))
  }

  /// `redoAction()`.
  ///
  /// The entry keeps its original serial, which is the whole point: redoing back to the state that
  /// was saved is clean, not "one modification further along than the save".
  public func redoAction() throws {
    guard let data = redoLog.last else { return }
    undoLog.append(data)
    redoLog.removeLast()

    restoreEditingContext(state: data.circuitState, hdlModel: data.hdlModel)

    let action = data.action
    fireEvent(ProjectEvent(action: .redoStart, project: self, data: .action(action)))
    // `doIt` again, not a separate `redo`, which is why `CircuitAction.doIt` re-captures its
    // reverse transaction on every call rather than assuming it runs once.
    do {
      try action.doIt(self)
    } catch {
      undoLog.removeLast()
      redoLog.append(data)
      publishDirtyState()
      throw error
    }
    // NOT UPSTREAM, and the reason path 2 of the release blocker existed: 4.1.0's `redoAction`
    // ends at `fireEvent(12)` with no `file.setDirty` anywhere in it (bytecode in the header).
    // The undo that preceded the redo had already pushed `false` down, so without this the file
    // stays marked clean, silently disarming `isAutosaveDirty` and the sidecar with it.
    publishDirtyState()
    fireEvent(ProjectEvent(action: .redoComplete, project: self, data: .action(action)))
  }

  /// `undoUpTo(Action)` / `redoUpTo(Action)`; used by the Edit menu's history submenu, which
  /// lets the user click an entry several deep.
  ///
  /// The loop condition is upstream's and is deliberately identity-based: it stops when the
  /// action that just moved across is the target *object*. Two structurally identical edits are
  /// two different targets, which is the behaviour a history list needs.
  public func undo(upTo target: Action) throws {
    var lastUndone: Action?
    while lastUndone !== target && !undoLog.isEmpty {
      try undoAction()
      if let last = redoLog.last { lastUndone = last.action }
    }
  }

  public func redo(upTo target: Action) throws {
    var lastRedone: Action?
    while lastRedone !== target && !redoLog.isEmpty {
      try redoAction()
      if let last = undoLog.last { lastRedone = last.action }
    }
  }

  /// `discardAllEdits()`; Edit > Clear Undo History.
  ///
  /// The save point is a mark on the stack, so throwing the stack away destroys the only record
  /// of whether the model still matches the disk. Upstream sets `undoMods = 0`, which asserts
  /// "saved" (and its missing `file.setDirty` then leaves the file's own flag contradicting it).
  /// Forgetting how to undo an edit does not write it to disk, so the answer is latched into
  /// `forcedDirty` before the stacks go and the empty-stack state is rebased to the current model.
  public func discardAllEdits() {
    let wasDirty = isFileDirty
    let currentSerial = appliedStateSerial
    undoLog.removeAll()
    redoLog.removeAll()
    baseStateSerial = currentSerial
    savedStateSerial = currentSerial
    forcedDirty = wasDirty
    publishDirtyState()
    fireEvent(ProjectEvent(action: .actionComplete, project: self, data: .none))
  }

  /// The `if (data.circuitState != null) … else if (data.hdlModel != null) …` pair that both
  /// `undoAction` and `redoAction` open with.
  private func restoreEditingContext(state: (any ProjectCircuitState)?, hdlModel: AnyObject?) {
    if let state {
      setCircuitState(state)
    } else if let hdlModel {
      setCurrentHdlModel(hdlModel)
    }
  }

  // MARK: - Dirty state
  //
  // -- ONE DEFINITION, ONE PUBLISHER ---------------------------------------------------------
  //
  // "The document differs from the state last confirmed on disk" is defined exactly once, by
  // `isFileDirty` above. `LogisimFile.dirtyFlag` is not a second definition; it is a cache of
  // this one, pushed down because `LogisimFile` compiles below `LogisimUI` and cannot read upward
  // (D9), and `LogisimFile.isAutosaveDirty` is armed by the same push.
  //
  // A cache maintained by convention is worse than no cache: every reader below this layer, the
  // autosave loop included, silently gets a stale answer, and that was path 2 of the release
  // blocker. So the invariant is:
  //
  //   every path that can change `isFileDirty` ends in `publishDirtyState()`.
  //
  // The paths are the two branches of `performAction`, `undoAction`, `redoAction`,
  // `discardAllEdits`, `setFileAsClean`, `setFileAsDirty`, `setForcedDirty` and `setLogisimFile`.
  // `DirtyStateMirrorTests.everyMutatorPublishesTheDirtyState` walks the reachable ones and
  // asserts `file.isDirty == project.isFileDirty` after each, because a convention nothing checks
  // is how this broke in the first place.

  private func takeActionSerial() -> Int {
    defer { nextActionSerial += 1 }
    return nextActionSerial
  }

  /// Push the single definition down to the file. The only writer of `LogisimFile.dirtyFlag` in
  /// this layer; see the section header.
  private func publishDirtyState() {
    file.setDirty(isFileDirty)
  }

  /// `setFileAsClean()`. Called after a save whose bytes have been confirmed on disk: see
  /// `SaveConfirming.confirmSaveSucceeded()`, which is where the port puts upstream's
  /// `ProjectActions.doSave` offset 39.
  ///
  /// Records the state the model is in as the save point rather than zeroing a count. Everything
  /// still on the undo stack stays undoable, and undoing past this point correctly reports
  /// unsaved work again, which upstream's `ifgt` cannot.
  public func setFileAsClean() {
    savedStateSerial = appliedStateSerial
    forcedDirty = false
    publishDirtyState()
  }

  /// `setFileAsDirty()`.
  ///
  /// Upstream writes `file.setDirty(true)` directly here, but no 4.1.0 caller reaches it. Routing
  /// the public API through `setForcedDirty()` keeps `LogisimFile` a mirror of the one dirty
  /// predicate instead of creating a second, contradictory source of truth.
  public func setFileAsDirty() {
    setForcedDirty()
  }

  /// `setForcedDirty()`.
  public func setForcedDirty() {
    forcedDirty = true
    publishDirtyState()
  }

  public func setStartupScreen(_ value: Bool) {
    isStartupScreen = value
  }

  // MARK: - Current circuit and file

  /// `setCircuitState(CircuitState)`.
  public func setCircuitState(_ value: (any ProjectCircuitState)?) {
    guard let value, circuitStateRef !== value else { return }

    let old = circuitStateRef
    let oldHdl = hdlModelRef
    let oldActive: ProjectEventData =
      oldHdl != nil ? .none : (old.map { ProjectEventData.circuitState($0) } ?? .none)
    let oldCircuit = old?.stateCircuit
    let newCircuit = value.stateCircuit
    let circuitChanged = old == nil || oldCircuit !== newCircuit

    if circuitChanged {
      // Upstream deselects the tool, drops the canvas selection through
      // `SelectionActions.dropAll`, and reselects. That is the selection slice's territory and
      // is routed through this hook so switching circuits does not silently leave a selection
      // pointing at components in a circuit that is no longer on screen.
      Project.circuitSwitchHook?(self)
      if let oldCircuit {
        for listener in circuitListeners.current() {
          oldCircuit.removeCircuitListener(listener)
        }
      }
    }

    hdlModelRef = nil
    circuitStateRef = value
    currentCircuitRef = newCircuit
    if value.parentProjectState == nil {
      recentRootState[ObjectIdentifier(newCircuit)] = value
    }
    simulator?.setCircuitState(value)

    if circuitChanged {
      fireEvent(
        ProjectEvent(
          action: .setCurrent, project: self, oldData: oldActive, data: .circuit(newCircuit)))
      for listener in circuitListeners.current() {
        newCircuit.addCircuitListener(listener)
      }
      // The circuit's stored tick frequency wins over the simulator's on first visit, and the
      // simulator's is written back into a circuit that has none. The `< 0` test is the "not
      // set" sentinel; `Circuit.tickFrequency` returns -1 for an absent attribute.
      if let simulator {
        let circuitFrequency = newCircuit.tickFrequency
        let simulatorFrequency = simulator.tickFrequency
        if circuitFrequency < 0 {
          // D13: `setTickFrequency` writes an attribute and therefore throws. A rejected write
          // here is not worth failing a circuit switch over, the frequency simply stays unset
          // , so it is recorded rather than propagated.
          do {
            try newCircuit.setTickFrequency(simulatorFrequency)
          } catch {
            pendingDiagnostics.append("could not adopt tick frequency: \(error)")
          }
        } else if circuitFrequency != simulatorFrequency {
          simulator.setTickFrequency(circuitFrequency)
        }
      }
      oldCircuit?.displayChanged()
      newCircuit.displayChanged()
    }
    fireEvent(
      ProjectEvent(
        action: .setState, project: self,
        oldData: old.map { ProjectEventData.circuitState($0) } ?? .none,
        data: .circuitState(circuitStateRef)))
  }

  /// `setCurrentCircuit(Circuit)`.
  public func setCurrentCircuit(_ circuit: Circuit) {
    let key = ObjectIdentifier(circuit)
    if let existing = recentRootState[key] {
      setCircuitState(existing)
      return
    }
    if let created = circuitStateFactory?.makeRootState(project: self, circuit: circuit) {
      recentRootState[key] = created
      allRootStates.append(created)
      setCircuitState(created)
      return
    }
    // No state factory installed (pre-M3, or headless). Track the circuit directly and emit the
    // same `ACTION_SET_CURRENT` the state path would, so listeners behave identically.
    guard currentCircuitRef !== circuit else { return }
    let oldCircuit = currentCircuitRef
    // `circuitSwitchHook` fires HERE TOO, and that is not belt-and-braces; it is the only place
    // it can fire in the shipping app.
    //
    // Upstream has one route: `setCurrentCircuit` calls `setCircuitState` (`Project.java:550`),
    // so the canvas work happens on every circuit change. This port cannot, because
    // `circuitStateFactory` is deliberately left nil (see its doc comment; root `CircuitState`s
    // must be built on the propagation thread), so `setCircuitState` is unreachable from
    // `LogisimFileProjectHost` and every real circuit switch lands on this fallback branch.
    // Installing the hook and leaving this branch alone would have produced a seam that is
    // assigned, non-nil, testable through `setCircuitState`, and *never actually called by the
    // application*; the exact shape this project has shipped several times.
    //
    // Before the tool loses its canvas and before `currentCircuitRef` moves, so the drop lands
    // in the circuit the selection actually belongs to.
    Project.circuitSwitchHook?(self)
    if let oldCircuit {
      for listener in circuitListeners.current() {
        oldCircuit.removeCircuitListener(listener)
      }
    }
    currentCircuitRef = circuit
    hdlModelRef = nil
    for listener in circuitListeners.current() {
      circuit.addCircuitListener(listener)
    }
    fireEvent(
      ProjectEvent(
        action: .setCurrent, project: self,
        oldData: oldCircuit.map { ProjectEventData.circuit($0) } ?? .none,
        data: .circuit(circuit)))
    oldCircuit?.displayChanged()
    circuit.displayChanged()
  }

  /// `setCurrentHdlModel(HdlModel)`.
  public func setCurrentHdlModel(_ hdl: AnyObject) {
    guard hdlModelRef !== hdl else { return }
    setTool(nil)
    let old = circuitStateRef
    let oldCircuit = old?.stateCircuit ?? currentCircuitRef
    if let oldCircuit {
      for listener in circuitListeners.current() {
        oldCircuit.removeCircuitListener(listener)
      }
    }
    circuitStateRef = nil
    currentCircuitRef = nil
    hdlModelRef = hdl
    if old != nil { simulator?.setCircuitState(nil) }

    fireEvent(ProjectEvent(action: .setCurrent, project: self, data: .none))
    if old != nil {
      fireEvent(
        ProjectEvent(
          action: .setState, project: self,
          oldData: .circuitState(old), data: .circuitState(nil)))
    }
    oldCircuit?.displayChanged()
  }

  /// `setLogisimFile(LogisimFile)`.
  ///
  /// Note the undo stack is cleared: entries name circuits belonging to the old file, and
  /// replaying one against the new file would mutate a circuit that is no longer in the
  /// document. That clearing is also what licenses `CircuitChange.circuit` being `unowned`;
  /// no undo entry can outlive the file whose circuits it names.
  public func setLogisimFile(_ value: LogisimFile) {
    let old: LogisimFile? = file
    if let old, old !== value {
      for listener in fileListeners.current() {
        old.removeLibraryListener(listener)
      }
    }

    file = value
    recentRootState.removeAll()
    allRootStates.removeAll()
    circuitStateRef = nil
    currentCircuitRef = nil
    undoLog.removeAll()
    redoLog.removeAll()
    baseStateSerial = 0
    savedStateSerial = 0
    forcedDirty = false

    fireEvent(
      ProjectEvent(
        action: .setFile, project: self,
        oldData: old.map { ProjectEventData.file($0) } ?? .none, data: .file(value)))

    if let main = value.mainCircuit {
      setCurrentCircuit(main)
    }
    for listener in fileListeners.current() {
      value.addLibraryListener(listener)
    }
    // Upstream's comment: "toggle it so that everybody hears the file is fresh".
    value.setDirty(true)
    value.setDirty(false)
  }

  // MARK: - Tool

  /// `setTool(Tool)`.
  ///
  /// The anchoring step, committing a floating selection before the tool changes, belongs to
  /// the selection slice and is routed through `toolChangeHook` for the same reason
  /// `circuitSwitchHook` exists: dropping it silently would leave pasted components floating and
  /// unanchored when the user picks another tool, which is a data-loss-shaped bug rather than a
  /// cosmetic one.
  public func setTool(_ value: Tool?) {
    guard tool !== value else { return }
    let old = tool
    Project.toolChangeHook?(self, old, value)
    isStartupScreen = false
    tool = value
    fireEvent(
      ProjectEvent(
        action: .setTool, project: self,
        oldData: old.map { ProjectEventData.tool($0) } ?? .none,
        data: value.map { ProjectEventData.tool($0) } ?? .none))
  }

  // MARK: - Listeners

  public func addProjectListener(_ listener: ProjectListener) {
    projectListeners.add(listener)
  }

  public func removeProjectListener(_ listener: ProjectListener) {
    projectListeners.remove(listener)
  }

  public func addLibraryListener(_ listener: LibraryListener) {
    fileListeners.add(listener)
    file.addLibraryListener(listener)
  }

  public func removeLibraryListener(_ listener: LibraryListener) {
    fileListeners.remove(listener)
    file.removeLibraryListener(listener)
  }

  /// `addCircuitListener(CircuitListener)`: registered with the project *and* forwarded to the
  /// circuit currently being edited, so a listener follows the user from circuit to circuit
  /// without re-registering.
  public func addCircuitListener(_ listener: CircuitListener) {
    circuitListeners.add(listener)
    currentCircuit?.addCircuitListener(listener)
  }

  public func removeCircuitListener(_ listener: CircuitListener) {
    circuitListeners.remove(listener)
    currentCircuit?.removeCircuitListener(listener)
  }

  /// `repaintCanvas()`: for changes that alter only what is drawn, so they must not enter the
  /// undo log.
  public func repaintCanvas() {
    fireEvent(ProjectEvent(action: .repaintRequest, project: self, data: .none))
  }

  private func fireEvent(_ event: ProjectEvent) {
    for listener in projectListeners.current() {
      listener.projectChanged(event)
    }
  }

  /// Non-fatal problems worth surfacing; D17's headless rule in miniature: the model records
  /// them, the shell decides whether to show them, and a `logisim-cli` run with no shell simply
  /// leaves them in the list.
  public private(set) var pendingDiagnostics: [String] = []

  public func drainDiagnostics() -> [String] {
    defer { pendingDiagnostics = [] }
    return pendingDiagnostics
  }

  /// Record a non-fatal problem raised by one of the installed hooks below.
  ///
  /// Module-internal: the two hooks run inside `setTool`/`setCurrentCircuit`, neither of which
  /// throws upstream, so an error out of `doAction` has nowhere to go. It is recorded rather than
  /// swallowed, for the same reason the tick-frequency write above is.
  func recordDiagnostic(_ message: String) {
    pendingDiagnostics.append(message)
  }

  // MARK: - Hooks into slices this one does not own

  /// `Frame.getCanvas()`'s side of `setCircuitState`: deselect the tool, drop the selection,
  /// reselect.
  public static var circuitSwitchHook: (@Sendable (Project) -> Void)? {
    get { hooks.withLock { $0.circuitSwitch } }
    set { hooks.withLock { $0.circuitSwitch = newValue } }
  }

  /// `setTool`'s selection anchoring, plus `Tool.select`/`deselect`.
  public static var toolChangeHook: (@Sendable (Project, Tool?, Tool?) -> Void)? {
    get { hooks.withLock { $0.toolChange } }
    set { hooks.withLock { $0.toolChange = newValue } }
  }

  private struct Hooks {
    var circuitSwitch: (@Sendable (Project) -> Void)?
    var toolChange: (@Sendable (Project, Tool?, Tool?) -> Void)?
  }

  /// Lock-guarded rather than a bare `static var`, which Swift 6 rejects as global mutable
  /// state. These are installed once at startup, so the lock is never contended; it exists to
  /// make the safety claim checkable rather than asserted.
  private static let hooks = LockedBox(Hooks())
}

/// `Project.MyListener`'s `LibraryListener` half.
///
/// The `Selection.Listener` half, forwarding `ACTION_SELECTION`, needs the canvas selection
/// type and belongs to the selection slice; it is not stubbed here because there is nothing for
/// it to listen to yet.
private final class ProjectLibraryListener: LibraryListener {
  /// D3: **unowned**. The project owns this listener (it must, or the weak listener list would
  /// drop it immediately), so the edge back has to be non-owning or every project leaks.
  private unowned let project: Project

  init(project: Project) {
    self.project = project
  }

  /// `nonisolated` because `LibraryListener` is declared in `LogisimFile`, which compiles below
  /// the Swift-6 line (D1) and therefore cannot declare an isolated requirement.
  ///
  /// `assumeIsolated` rather than a `Task { @MainActor in … }` hop, and the distinction matters:
  /// upstream fires this synchronously on the EDT from inside `LogisimFile.removeLibrary`, and
  /// the handler's whole job is to react *before* the removal is observable; dropping a tool
  /// that came from the library being unloaded, or leaving the current circuit before it is
  /// deleted. Deferring it to a later turn would let the canvas paint one frame holding a tool
  /// whose library is gone. `assumeIsolated` stays on the calling thread, so the ordering is
  /// preserved; the assumption it makes is exactly the EDT confinement Java relies on, and this
  /// port's `@MainActor` boundary is the checked version of.
  /// `UncheckedSendableBox` carries `event` across the `assumeIsolated` closure, which the
  /// compiler otherwise reads as sending a non-`Sendable` value between isolation domains.
  /// Nothing actually crosses a domain: `assumeIsolated` is synchronous and stays on the calling
  /// thread. See the box's own doc comment in `ToolSeams.swift`; it exists to make that claim
  /// out loud rather than reach for `@unchecked` at the use site.
  nonisolated func libraryChanged(_ event: LibraryEvent) {
    let boxedEvent = UncheckedSendableBox(event)
    let boxedSelf = UncheckedSendableBox(self)
    MainActor.assumeIsolated { boxedSelf.value.handle(boxedEvent.value) }
  }

  @MainActor
  private func handle(_ event: LibraryEvent) {
    switch event.action {
    case .removeLibrary:
      // A library being unloaded strands any tool that came from it.
      if let tool = project.tool, case .library(let unloaded) = event.data,
        unloaded.containsFromSource(tool)
      {
        project.setTool(nil)
      }
    case .removeTool:
      // Deleting a circuit while looking at it: fall back to the main circuit, or the whole
      // editing surface would be pointing at a circuit no longer in the file.
      guard case .tool(let removed) = event.data,
        let addTool = removed as? AddTool,
        let subcircuitFactory = addTool.factory as? any SubcircuitFactory,
        let subcircuit = subcircuitFactory.subcircuit as? Circuit,
        subcircuit === project.currentCircuit,
        let main = project.logisimFile.mainCircuit
      else { return }
      project.setCurrentCircuit(main)
    default:
      break
    }
  }
}
