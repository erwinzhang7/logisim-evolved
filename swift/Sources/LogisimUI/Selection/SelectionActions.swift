// SelectionActions.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.gui.main.SelectionActions),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// ── Why every action keeps its transaction instead of recomputing ───────────────────────────
//
// `SelectedComponentsAction` stores the `CircuitMutation` it executed (`xnForward`) and the
// reverse transaction the execution handed back (`xnReverse`). Redo replays the stored forward
// transaction; undo replays the stored reverse one. Neither recomputes anything.
//
// That is the property M7's byte-exact gate depends on. A redo that re-derived the mutation would
// re-run `copyComponents`' offset search against a circuit that has changed since, and could
// legitimately choose a different offset: producing a visually identical circuit with different
// saved coordinates, which the gate counts as a failure. The first execution is the only one that
// decides anything.
//
// ── Undo coalescing ─────────────────────────────────────────────────────────────────────────
//
// `Anchor`, `Drop` and `Translate` each override `shouldAppendTo` with the same test: unwrap a
// `JoinedAction` to its last action, and append if that action was a `Paste` or a `Duplicate`
// whose *after* snapshot equals this action's *before* snapshot. In words: if nothing has
// happened to the selection since the paste, the nudge that follows is part of the paste. This is
// why the actions are classes compared by identity and type rather than values (objectives.md,
// M7: "identity-compared → actions are classes").
//
// ── D9 / D17: the two dialogs on the paste path ─────────────────────────────────────────────
//
// `getReplacementMap` raises two Swing dialogs: a three-way question per unresolvable factory,
// and a summary listing everything that had to be dropped. Both are *decisions that change the
// model*, so the decision stays here and only the presentation moves out, through
// `PasteConflictResolver`. D17's headless mode then works the way it does for every other dialog
// in the port: no resolver attached means the default answer, and the summary becomes a report.

import Foundation
import LogisimFile
import LogisimKernel

// MARK: - The paste-conflict seam

/// The answer to upstream's `pasteCloneQuery` dialog: "the destination has a component named X,
/// but it is not the same component you copied; what should I do?"
public enum PasteConflictResolution: Sendable {
  /// `pasteCloneReplace`: use the destination's same-named factory. Upstream's default button.
  case replace
  /// `pasteCloneIgnore`: drop this component from the paste.
  case ignore
  /// `pasteCloneCancel`, abandon the whole paste.
  case cancel
}

/// How the paste path asks its questions and reports what it had to drop.
///
/// **This is the case that exposes shortcuts**, and it is worth being explicit about what it is.
/// Pasting into the *same* circuit never reaches any of this: every factory resolves to itself.
/// Pasting into a different file does, and there are three outcomes upstream distinguishes and a
/// shortcut would not:
///
///   * The destination has the identical factory object → paste it unchanged.
///   * The destination has a *different* factory with the same name, the same builtin
///     re-instantiated in another file, or a same-named subcircuit, → upstream asks. Answering
///     `.replace` rebuilds the component against the destination's factory **with a clone of the
///     original attributes**, so the paste keeps its settings; `.ignore` drops it.
///   * The destination has nothing by that name → the component is dropped and *named* in a
///     summary. Silently dropping it is exactly the data loss D8 exists to prevent elsewhere.
///
/// The one shortcut upstream itself takes is worth knowing: a same-named factory of the same
/// *class* is accepted without asking, unless it is a subcircuit or a VHDL entity; those two are
/// user-defined, so a name match means nothing.
@MainActor
public protocol PasteConflictResolver: AnyObject {
  /// `OptionPane.showOptionDialog(... pasteCloneQuery ...)`. The argument is the factory's
  /// `getName()`, which is what upstream interpolates into the message.
  func resolveClone(factoryName: String) -> PasteConflictResolution

  /// `OptionPane.showMessageDialog(... pasteDropTitle ...)`; the components that could not be
  /// resolved at all, already grouped and sorted the way upstream formats them.
  func reportDropped(_ summary: PasteDropSummary)
}

/// The body of upstream's `pasteDropMessage` dialog, as data.
///
/// Kept structured rather than pre-rendered so the shell can present it as a list; `lines`
/// carries upstream's own `max(3, min(7, lines))` sizing hint, which is the only thing the raw
/// string was carrying that the structure would otherwise lose.
public struct PasteDropSummary: Sendable, Equatable {
  /// One entry per distinct display name, in the order upstream's sort produces, with the count
  /// it renders as `Name × N`.
  public struct Entry: Sendable, Equatable {
    public let displayName: String
    public let count: Int
  }

  public let entries: [Entry]
  /// Upstream's `JTextArea` row count: `max(3, min(7, lines))`.
  public let preferredLineCount: Int
}

/// The default answers when nothing is attached: `.replace`, which is the button upstream focuses
/// (`opts[0]`), and a dropped-component report that goes nowhere.
///
/// D17: this is what makes the paste path runnable headlessly. Upstream's equivalent is
/// `Main.headless` turning every `OptionPane` into a log line.
@MainActor
public final class DefaultPasteConflictResolver: PasteConflictResolver {
  public init() {}
  public func resolveClone(factoryName: String) -> PasteConflictResolution { .replace }
  public func reportDropped(_ summary: PasteDropSummary) {}
}

// MARK: - SelectionActions

/// `com.cburch.logisim.gui.main.SelectionActions`: a namespace of factory functions, exactly as
/// upstream's private-constructor class is.
///
/// Every `getName()` returns the upstream string *key* rather than a localised string. D5 puts
/// display strings in the UI layer, and the undo menu item is the only consumer.
@MainActor
public enum SelectionActions {

  /// Where the paste path asks its questions. Assign at app start; the default answers headlessly.
  public static var pasteConflictResolver: any PasteConflictResolver =
    DefaultPasteConflictResolver()

  // MARK: Factory functions

  /// `anchorAll(Selection)`: anchors every floating component, keeping it selected.
  ///
  /// `nil` when there is nothing floating, which is upstream's null and is what stops an empty
  /// "Drop" appearing on the undo stack.
  public static func anchorAll(_ selection: Selection) -> Action? {
    let count = selection.floatingComponents.count
    return count == 0 ? nil : Anchor(selection: selection, numAnchor: count)
  }

  /// `clear(Selection)`, Delete.
  public static func clear(_ selection: Selection) -> Action {
    Delete(selection: selection)
  }

  /// `copy(Selection)`.
  public static func copy(_ selection: Selection) -> Action {
    Copy(selection: selection)
  }

  /// `cut(Selection)`.
  public static func cut(_ selection: Selection) -> Action {
    Cut(selection: selection)
  }

  /// `drop(Selection, Collection<Component>)`.
  ///
  /// Anchors the floating members of `comps` and merely deselects the anchored ones. When *every*
  /// listed component is already anchored there is nothing to undo, so the deselection is
  /// performed immediately and `nil` is returned rather than pushing a no-op onto the stack.
  ///
  /// D13: `throws` because `Selection.remove` does: though not on this path, where every
  /// component handed to it is anchored by construction.
  public static func drop(
    _ selection: Selection, _ comps: [any Component]
  ) throws -> Action? {
    let floating = ComponentSet(selection.floatingComponents)
    let anchored = ComponentSet(selection.anchoredComponents)
    var toDrop: [any Component] = []
    var toIgnore: [any Component] = []
    for comp in comps {
      if floating.contains(comp) {
        toDrop.append(comp)
      } else if anchored.contains(comp) {
        toDrop.append(comp)
        toIgnore.append(comp)
      }
    }
    if toDrop.count == toIgnore.count {
      for comp in toIgnore { try selection.remove(comp, using: nil) }
      return nil
    }
    return Drop(selection: selection, toDrop: toDrop, numDrops: toDrop.count - toIgnore.count)
  }

  /// `dropAll(Selection)`.
  public static func dropAll(_ selection: Selection) throws -> Action? {
    try drop(selection, selection.components)
  }

  /// `duplicate(Selection)`.
  public static func duplicate(_ selection: Selection) -> Action {
    Duplicate(selection: selection)
  }

  /// `translate(Selection, int, int, ReplacementMap)`; the move action. `replacements` carries
  /// the wire reroute `tools/move` computes in the background; `nil` is upstream's null.
  public static func translate(
    _ selection: Selection, dx: Int, dy: Int,
    replacements: ReplacementMap? = nil
  ) -> Action {
    Translate(selection: selection, dx: dx, dy: dy, replacements: replacements)
  }

  /// `pasteMaybe(Project, Selection)`.
  ///
  /// Bug-for-bug, with the trap defused. Upstream builds the replacement map, which returns
  /// `null` when the user cancels, and then unconditionally constructs a `Paste` with it, whose
  /// `computeAdditions` immediately dereferences it. A cancelled paste therefore throws a
  /// `NullPointerException` out of the event dispatch thread upstream; the visible effect is that
  /// nothing happens.
  ///
  /// D13 forbids reproducing that as a trap, so the cancellation is carried as `nil` and the
  /// action performs nothing: the same visible effect, without taking the process down. The
  /// name is kept as `pasteMaybe` because the "maybe" is upstream's own acknowledgement that this
  /// can decline.
  public static func pasteMaybe(
    _ project: Project, _ selection: Selection
  ) throws -> Action {
    let replacements = try replacementMap(for: project)
    return Paste(selection: selection, componentReplacements: replacements)
  }

  // MARK: Factory resolution for paste

  /// `findComponentFactory(ComponentFactory, ArrayList<Library>, boolean)`.
  ///
  /// Walks the destination file and its libraries for an `AddTool` whose name matches. With
  /// `acceptNameMatch: false` it returns only an *exact* factory match, or a same-named factory
  /// of the same concrete class that is neither a subcircuit nor a VHDL entity; those two are
  /// user-defined, so a name match proves nothing about them. With `acceptNameMatch: true` any
  /// name match will do, and that result is what the user is asked about.
  ///
  /// `fact.getClass() == factory.getClass()` becomes a comparison of the two factories' dynamic
  /// types. Swift's `type(of:)` on an existential yields the dynamic type, so this is the same
  /// test; note it is deliberately *not* `is`, because a subclass must not match its base.
  static func findComponentFactory(
    _ factory: any ComponentFactory, in libraries: [Library], acceptNameMatch: Bool
  ) -> (any ComponentFactory)? {
    let name = factory.name
    for lib in libraries {
      for tool in lib.tools {
        guard let addTool = tool as? AddTool, name == addTool.name else { continue }
        let candidate = addTool.factory
        if acceptNameMatch || candidate === factory {
          return candidate
        } else if ObjectIdentifier(type(of: candidate)) == ObjectIdentifier(type(of: factory)),
          !(candidate is any SubcircuitFactory), !(candidate is any VhdlEntityFactory)
        {
          return candidate
        }
      }
    }
    return nil
  }

  /// `getReplacementMap(Project)`.
  ///
  /// Returns a map from clipboard component to its stand-in in the destination file:
  ///
  ///   * absent  → paste the component as it is,
  ///   * present and `nil` → drop the component,
  ///   * present and non-nil → paste the replacement instead.
  ///
  /// `nil` for the whole map means the user cancelled. Wires and `Text` components never appear:
  /// wires have no factory to resolve and `Text` is always available.
  static func replacementMap(
    for project: Project
  ) throws -> [SelectionComponentKey: (any Component)?]? {
    var replMap: [SelectionComponentKey: (any Component)?] = [:]

    let file = project.logisimFile
    var libraries: [Library] = [file]
    libraries.append(contentsOf: file.libraries)

    var dropped: [String] = []
    guard let clip = Clipboard.get() else { return replMap }
    let comps = clip.components
    // Keyed by the factory's identity, as upstream's `HashMap<ComponentFactory, …>` is: the
    // answer to "what did the user say about this factory" must be reused for every component
    // that shares it, so the question is asked once.
    var factoryReplacements: [ObjectIdentifier: (any ComponentFactory)?] = [:]

    for comp in comps {
      if comp is Wire { continue }

      let compFactory = comp.factory
      if SelectionFactoryTests.isTextFactory(compFactory) { continue }

      var copyFactory = findComponentFactory(compFactory, in: libraries, acceptNameMatch: false)
      let factoryKey = ObjectIdentifier(compFactory)
      // `containsKey`, not "the value is non-nil": a remembered `.ignore` answer is stored as a
      // nil *value*, and re-asking would be a second dialog for the same factory.
      if let remembered = factoryReplacements[factoryKey] {
        copyFactory = remembered
      } else if copyFactory == nil {
        let candidate = findComponentFactory(compFactory, in: libraries, acceptNameMatch: true)
        if candidate == nil {
          dropped.append(compFactory.displayName)
        } else {
          switch pasteConflictResolver.resolveClone(factoryName: compFactory.name) {
          case .replace: copyFactory = candidate
          case .ignore: copyFactory = nil
          case .cancel: return nil
          }
          // `updateValue`, not subscript assignment: assigning a nil `Value?` through the
          // subscript *removes* the key, which would turn a remembered `.ignore` back into an
          // unanswered question.
          factoryReplacements.updateValue(copyFactory, forKey: factoryKey)
        }
      }

      if let copyFactory {
        if copyFactory !== compFactory {
          let copyLoc = comp.location
          let copyAttrs = comp.attributeSet.copy()
          let copy = try copyFactory.createComponent(location: copyLoc, attributes: copyAttrs)
          replMap.updateValue(copy, forKey: SelectionComponentKey(comp))
        }
      } else {
        // Present with a nil value: "drop this one". Distinct from absent, which means "paste it
        // unchanged", see `computeAdditions`.
        replMap.updateValue(nil, forKey: SelectionComponentKey(comp))
      }
    }

    if !dropped.isEmpty {
      pasteConflictResolver.reportDropped(summarise(dropped: dropped))
    }

    return replMap
  }

  /// The grouping upstream performs while assembling `pasteDropMessage`.
  ///
  /// Sort, then run-length encode adjacent equal names into `Name × N`. The `lines` counter and
  /// its `max(3, min(7, …))` clamp are upstream's `JTextArea` sizing and are carried through
  /// because they are the only thing the flat string encoded that a list would drop.
  ///
  /// Note upstream's loop runs to `i <= size` and compares against `""` on the last pass, which
  /// is how the final group gets emitted; the same structure is kept so the counts match exactly
  /// on the edge case of a name that is genuinely the empty string.
  static func summarise(dropped: [String]) -> PasteDropSummary {
    var names = dropped
    names.sort()
    guard !names.isEmpty else { return PasteDropSummary(entries: [], preferredLineCount: 3) }
    var entries: [PasteDropSummary.Entry] = []
    var curName = names[0]
    var curCount = 1
    var lines = 1
    for i in 1...names.count {
      let nextName = i == names.count ? "" : names[i]
      if nextName == curName {
        curCount += 1
      } else {
        lines += 1
        entries.append(PasteDropSummary.Entry(displayName: curName, count: curCount))
        curName = nextName
        curCount = 1
      }
    }
    return PasteDropSummary(entries: entries, preferredLineCount: max(3, min(7, lines)))
  }

  // MARK: - The action base class

  /// `SelectionActions.SelectedComponentsAction`.
  ///
  /// The first `doIt` performs the edit and records both directions; every later `doIt` is a redo
  /// and replays the recorded forward transaction. See the file header for why that distinction
  /// is load-bearing rather than an optimisation.
  @MainActor
  public class SelectedComponentsAction: Action {
    var xnForward: CircuitTransaction?
    var xnReverse: CircuitTransaction?
    private var hasDoneFirstTime = false

    /// `getName()` is abstract upstream. Every concrete action overrides it; the empty string is
    /// the inert answer rather than a trap, because an unnamed undo menu item is a cosmetic bug
    /// and D13 reserves trapping for invariants a caller cannot violate.
    public override var name: String { "" }

    /// Re-declared rather than left to `Action`'s own default so the shape is visible at the
    /// class every selection action derives from. `Copy` really does answer differently, and
    /// when this was a protocol the redeclaration was *required*; a protocol-extension default
    /// is statically dispatched, so overriding it in a conformer does not take effect at an
    /// `any ProjectAction` call site. Now that `Action` is a class the override works either
    /// way; the note is kept because that failure mode is silent.
    public override var isModification: Bool { true }

    /// Same note as `isModification`.
    public override func shouldAppendTo(_ other: Action) -> Bool { false }

    public override func doIt(_ project: Project) throws {
      if hasDoneFirstTime {
        try redo(project)
      } else {
        try doItFirstTime(project)
        hasDoneFirstTime = true
      }
    }

    /// Abstract upstream. D13 leaves this trapping: it is an unimplemented-subclass error, which
    /// is the "genuine programmer error no user input can reach" category the audit kept.
    func doItFirstTime(_ project: Project) throws {
      fatalError("SelectedComponentsAction subclasses must override doItFirstTime")
    }

    public override func undo(_ project: Project) throws {
      try xnReverse?.execute()
    }

    func redo(_ project: Project) throws {
      try xnForward?.execute()
    }
  }

  // MARK: - Anchor

  /// `SelectionActions.Anchor`: "drop" in the menus, anchoring floating components in place.
  final class Anchor: SelectedComponentsAction {
    private let selection: Selection
    private let numAnchor: Int
    fileprivate let before: SelectionSave

    init(selection: Selection, numAnchor: Int) {
      self.selection = selection
      self.before = SelectionSave.create(selection)
      self.numAnchor = numAnchor
      super.init()
    }

    override func doItFirstTime(_ project: Project) throws {
      let circuit = project.currentCircuit
      let xn = project.makeCircuitMutation(circuit)
      selection.dropAll(xn)
      xnForward = xn
      let result = try xn.execute()
      xnReverse = try result.reverseTransaction()
    }

    override var name: String {
      numAnchor == 1 ? "dropComponentAction" : "dropComponentsAction"
    }

    override func shouldAppendTo(_ other: Action) -> Bool {
      SelectionActions.appendsOntoPasteOrDuplicate(other, before: before)
    }
  }

  // MARK: - Copy

  /// `SelectionActions.Copy`.
  ///
  /// The only action that is not a modification, so it does not dirty the file, but it *is* on
  /// the undo stack, because undoing a copy has to put the previous clipboard back.
  final class Copy: SelectedComponentsAction {
    private let selection: Selection
    private var oldClip: Clipboard?
    private var newClip: Clipboard?

    init(selection: Selection) {
      self.selection = selection
      super.init()
    }

    override func doItFirstTime(_ project: Project) throws {
      oldClip = Clipboard.get()
      try Clipboard.set(copying: selection, viewing: selection.attributeSet)
      newClip = Clipboard.get()
    }

    override var name: String { "copySelectionAction" }

    override var isModification: Bool { false }

    override func undo(_ project: Project) throws {
      Clipboard.set(oldClip)
    }

    override func redo(_ project: Project) throws {
      Clipboard.set(newClip)
    }
  }

  // MARK: - Cut

  /// `SelectionActions.Cut`: a copy and a delete, kept as two objects so undo can reverse them
  /// in the right order: the delete first, then the clipboard.
  final class Cut: SelectedComponentsAction {
    private let selection: Selection
    private let second: SelectedComponentsAction
    private var oldClip: Clipboard?
    private var newClip: Clipboard?

    init(selection: Selection) {
      self.selection = selection
      self.second = Delete(selection: selection)
      super.init()
    }

    override func doItFirstTime(_ project: Project) throws {
      oldClip = Clipboard.get()
      try Clipboard.set(copying: selection, viewing: selection.attributeSet)
      newClip = Clipboard.get()
      try second.doIt(project)
    }

    override var name: String { "cutSelectionAction" }

    override func undo(_ project: Project) throws {
      try second.undo(project)
      Clipboard.set(oldClip)
    }

    override func redo(_ project: Project) throws {
      Clipboard.set(newClip)
      // `doIt`, not `redo`: the nested Delete has its own first-time flag, and on the first redo
      // of a Cut the Delete has already run once, so this lands on its `redo`.
      try second.doIt(project)
    }
  }

  // MARK: - Delete

  /// `SelectionActions.Delete`.
  final class Delete: SelectedComponentsAction {
    private let selection: Selection

    init(selection: Selection) {
      self.selection = selection
      super.init()
    }

    override func doItFirstTime(_ project: Project) throws {
      let circuit = project.currentCircuit
      let xn = project.makeCircuitMutation(circuit)
      selection.deleteAllHelper(xn)
      xnForward = xn
      let result = try xn.execute()
      xnReverse = try result.reverseTransaction()
    }

    override var name: String { "deleteSelectionAction" }
  }

  // MARK: - Drop

  /// `SelectionActions.Drop`.
  final class Drop: SelectedComponentsAction {
    private let selection: Selection
    private let drops: [any Component]
    private let numDrops: Int
    fileprivate let before: SelectionSave

    init(selection: Selection, toDrop: [any Component], numDrops: Int) {
      self.selection = selection
      self.drops = toDrop
      self.numDrops = numDrops
      self.before = SelectionSave.create(selection)
      super.init()
    }

    override func doItFirstTime(_ project: Project) throws {
      let circuit = project.currentCircuit
      let xn = project.makeCircuitMutation(circuit)
      for comp in drops { try selection.remove(comp, using: xn) }
      xnForward = xn
      let result = try xn.execute()
      xnReverse = try result.reverseTransaction()
    }

    override var name: String {
      numDrops == 1 ? "dropComponentAction" : "dropComponentsAction"
    }

    override func shouldAppendTo(_ other: Action) -> Bool {
      SelectionActions.appendsOntoPasteOrDuplicate(other, before: before)
    }
  }

  // MARK: - Duplicate

  /// `SelectionActions.Duplicate`.
  ///
  /// The copies land **floating**, offset by whatever `copyComponents`' search chose, (10, 10)
  /// in the ordinary case, because index 0 collides with the originals. They stay floating so the
  /// user can drag them, and the `Translate` that follows coalesces onto this action through
  /// `after`.
  final class Duplicate: SelectedComponentsAction {
    private let selection: Selection
    fileprivate var after: SelectionSave?

    init(selection: Selection) {
      self.selection = selection
      super.init()
    }

    override func doItFirstTime(_ project: Project) throws {
      let circuit = project.currentCircuit
      let xn = project.makeCircuitMutation(circuit)
      try selection.duplicateHelper(xn)
      xnForward = xn
      let result = try xn.execute()
      xnReverse = try result.reverseTransaction()
      after = SelectionSave.create(selection)
    }

    override var name: String { "duplicateSelectionAction" }
  }

  // MARK: - Paste

  /// `SelectionActions.Paste`.
  final class Paste: SelectedComponentsAction {
    private let selection: Selection
    /// `nil` means the user cancelled; see `pasteMaybe` for why that is not a crash here.
    private let componentReplacements: [SelectionComponentKey: (any Component)?]?
    fileprivate var after: SelectionSave?

    init(
      selection: Selection,
      componentReplacements: [SelectionComponentKey: (any Component)?]?
    ) {
      self.selection = selection
      self.componentReplacements = componentReplacements
      super.init()
    }

    /// `computeAdditions(Collection<Component>)`.
    ///
    /// Absent from the map → paste as is. Present and non-nil → paste the replacement. Present
    /// and nil → drop. Order follows the clipboard's, which is the selection order the copy was
    /// taken in.
    private func computeAdditions(_ comps: [any Component]) -> [any Component] {
      guard let replMap = componentReplacements else { return [] }
      var toAdd: [any Component] = []
      toAdd.reserveCapacity(comps.count)
      for comp in comps {
        if let entry = replMap[SelectionComponentKey(comp)] {
          if let repl = entry { toAdd.append(repl) }
        } else {
          toAdd.append(comp)
        }
      }
      return toAdd
    }

    override func doItFirstTime(_ project: Project) throws {
      guard let clip = Clipboard.get() else { return }
      let circuit = project.currentCircuit
      let xn = project.makeCircuitMutation(circuit)
      let comps = clip.components
      let toAdd = computeAdditions(comps)

      // The circularity check runs over the *clipboard*, not over `toAdd`: a subcircuit that was
      // going to be dropped or replaced still counts, which is deliberately conservative.
      if let canvasCircuit = project.canvasCircuit, let depends = project.dependencies {
        for comp in comps {
          guard let circFact = comp.factory as? any SubcircuitFactory else { continue }
          guard let sub = circFact.subcircuit as? Circuit else { continue }
          if !depends.canAdd(canvasCircuit, sub) {
            project.setErrorMessage("circularError")
            return
          }
        }
      }

      if !toAdd.isEmpty {
        try selection.pasteHelper(xn, toAdd)
        xnForward = xn
        let result = try xn.execute()
        xnReverse = try result.reverseTransaction()
        after = SelectionSave.create(selection)
      } else {
        // Explicit, and upstream's: an empty paste leaves both transactions nil, so undo and
        // redo are no-ops rather than replaying a mutation that did nothing.
        xnForward = nil
        xnReverse = nil
      }
    }

    override var name: String { "pasteClipboardAction" }
  }

  // MARK: - Translate

  /// `SelectionActions.Translate`, the move.
  final class Translate: SelectedComponentsAction {
    private let selection: Selection
    private let dx: Int
    private let dy: Int
    private let replacements: ReplacementMap?
    fileprivate let before: SelectionSave

    init(
      selection: Selection, dx: Int, dy: Int,
      replacements: ReplacementMap?
    ) {
      self.selection = selection
      self.dx = dx
      self.dy = dy
      self.replacements = replacements
      self.before = SelectionSave.create(selection)
      super.init()
    }

    override func doItFirstTime(_ project: Project) throws {
      let circuit = project.currentCircuit
      let xn = project.makeCircuitMutation(circuit)
      try selection.translateHelper(xn, dx: dx, dy: dy)
      // The background reroute goes into the *same* transaction, after the move, so undo puts the
      // wires back in one step with the components.
      if let replacements { xn.replace(replacements) }
      xnForward = xn
      let result = try xn.execute()
      xnReverse = try result.reverseTransaction()
    }

    override var name: String { "moveSelectionAction" }

    override func shouldAppendTo(_ other: Action) -> Bool {
      SelectionActions.appendsOntoPasteOrDuplicate(other, before: before)
    }
  }

  // MARK: - The shared coalescing test

  /// The body all three `shouldAppendTo` overrides share verbatim upstream.
  ///
  /// Only `Paste` and `Duplicate` record an `after` snapshot, which is what makes them the only
  /// two actions anything coalesces onto.
  fileprivate static func appendsOntoPasteOrDuplicate(
    _ other: Action, before: SelectionSave
  ) -> Bool {
    let last = Action.lastAction(of: other)
    let otherAfter: SelectionSave?
    if let paste = last as? Paste {
      otherAfter = paste.after
    } else if let dupe = last as? Duplicate {
      otherAfter = dupe.after
    } else {
      otherAfter = nil
    }
    guard let otherAfter else { return false }
    return otherAfter == before
  }
}
