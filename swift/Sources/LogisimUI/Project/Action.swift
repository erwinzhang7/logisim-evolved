// Action.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.proj.{Action, JoinedAction}),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only.
// SPDX-License-Identifier: GPL-3.0-only
//
// Ported from the **4.1.0** tree (D16), not `main`.
//
// ── Why `Action` is a class and not a protocol or a struct ──────────────────────────────────
//
// This is the single most load-bearing shape decision in the undo system, and getting it wrong
// is silent rather than loud.
//
// `Project.doAction` coalesces consecutive edits by asking the *incoming* action whether it
// should absorb the one already on top of the undo log:
//
//     if (!undoLog.isEmpty() && act.shouldAppendTo(getLastAction())) { ... }
//
// Every concrete override in 4.1.0 answers it with a **type test plus a reference-identity
// comparison**: never with value equality:
//
//   | implementation                                       | the deciding test                  |
//   |------------------------------------------------------|------------------------------------|
//   | `LogisimFileActions.MoveCircuit:513`                  | `circ.tool == this.tool`           |
//   | `HdlContentView.HdlEditAction:67`                     | `((HdlEditAction) other).model     |
//   |                                                      |  == model`                         |
//   | `ToolbarActions.MoveTool:131`                         | `this.toolbar == o.toolbar`        |
//   | `SelectionActions:296/443/586` (Move, Delete, Anchor) | `other instanceof JoinedAction`, |
//   |                                                      | then `getLastAction()`             |
//   | `RomContentsListener.Change:81`                       | `other instanceof Change` + range  |
//
// A `struct` cannot express "the same object", only "an equal value". Making these value types
// would compile, look right, and then break coalescing in a way that has no test failure and no
// crash: dragging one component across the canvas emits a move action per mouse-moved event,
// each comparing unequal to the last because the coordinates differ, so the drag lands in the
// undo stack as **one entry per mouse sample** instead of one entry for the whole gesture.
// Ctrl-Z then rewinds a single pixel of travel. That is exactly the failure this comment exists
// to prevent: see the M7 notes in docs/objectives.md.
//
// A protocol with an `AnyObject` constraint would also give identity, but `Action` has real
// inherited behaviour (`append` builds a `JoinedAction`, `isModification` defaults to `true`,
// `shouldAppendTo` defaults to `false`) and `JoinedAction` overrides three of the five members.
// An `open class` is the direct translation of Java's `abstract class` and keeps subclasses in
// the other M7 slices, `CircuitAction`, `SelectionActions.*`, `SetAttributeAction`, writing
// exactly what they write in Java. Note also that three `SelectionActions` overrides downcast
// their argument to `JoinedAction` and call `getLastAction()`: grouping has to be a real
// `Action` subclass, not an array inside `Project`, or those overrides have nothing to ask.
//
// ── D13 ─────────────────────────────────────────────────────────────────────────────────────
//
// `doIt`/`undo` `throws`. Upstream's do not, but every structural edit they perform bottoms out
// in `AttributeSet.setValue` or `Circuit.mutatorAdd`, both of which throw in this port because a
// malformed value is reachable from a bad edit (D13's rule). Swallowing that inside the action
// would turn a reportable edit failure into a silently half-applied undo entry, which is the
// worst outcome available: the undo log would claim a change the model does not have.

import Foundation

/// `com.cburch.logisim.proj.Action`; one undoable edit.
///
/// Subclass this; do not conform to it. See the file header for why it is a class.
/// `@MainActor`: see `Tool.swift`'s header for the module-wide rule. Everything the user's
/// editing gestures reach is isolated, because Java confines all of it to the EDT and the
/// annotation is the compiler-checked version of that confinement. The transaction substrate
/// below this (`CircuitTransaction`, `CircuitLocker`, `CircuitMutator`, `CircuitChange`,
/// `ReplacementMap`) is deliberately *not*, because upstream takes real per-circuit locks there
/// precisely so a transaction can run off the EDT.
@MainActor
open class Action {

  public init() {}

  /// `append(Action)`. Combines `self` with `other` so the pair undoes as a unit.
  ///
  /// The base implementation wraps both in a `JoinedAction`. `JoinedAction` overrides it to
  /// grow in place instead, so a run of *n* coalesced edits costs one wrapper rather than *n*
  /// nested ones.
  ///
  /// Returns `nil` when the append annihilates the pair: e.g. a move by `+d` followed by a
  /// move by `-d`. `Project.doAction` treats `nil` as "drop the entry entirely", which is why
  /// this is optional here even though the two implementations in this file never return `nil`.
  open func append(_ other: Action) -> Action? {
    JoinedAction(self, other)
  }

  /// `doIt(Project)`. Apply the edit.
  ///
  /// Called both when the action is first performed and again on every redo, so it must be
  /// idempotent with respect to its own recorded state; it may not, for instance, capture
  /// "the old value" on the first run and reuse a stale one on the second.
  open func doIt(_ project: Project) throws {
    fatalError("Action is abstract; override doIt(_:)")
  }

  /// `getName()`. Shown in the Edit menu as "Undo <name>".
  open var name: String {
    fatalError("Action is abstract; override name")
  }

  /// `isModification()`. False for actions that change what is *shown* rather than what is
  /// *stored*, selecting, changing the current circuit, so they can sit in the undo log
  /// without marking the file dirty. Defaults to true, as upstream does.
  open var isModification: Bool { true }

  /// `shouldAppendTo(Action)`. Asked of the **incoming** action about the action already on
  /// top of the undo log.
  ///
  /// Overrides must compare by reference identity where upstream does (`==` on a `Circuit`, a
  /// `Selection`, a component). See the file header.
  ///
  /// **Unwrap `JoinedAction` first.** By the third sample of a gesture, `other` is no longer
  /// your action type, the first two have already merged into a group, so a naive
  /// `other as? MyAction` returns `nil` and coalescing stops after exactly one merge. A drag
  /// then lands in the undo log as *n−1* entries instead of one, which looks like coalescing
  /// working (the first two did merge) and is not. Upstream's three `SelectionActions`
  /// overrides all open with the same line, and it is the reason `JoinedAction.lastAction` is
  /// public:
  ///
  /// ```swift
  /// let last = (other as? JoinedAction)?.lastAction ?? other
  /// guard let last = last as? MyAction else { return false }
  /// return last.gesture === gesture
  /// ```
  open func shouldAppendTo(_ other: Action) -> Bool { false }

  /// `undo(Project)`. Reverse the edit. Must leave the model in the state `doIt` found it in,
  /// including component identity; a component that is removed and re-added must be the *same
  /// object*, because D4 keys `componentData` and the simulator's dirty lists on identity and a
  /// structurally identical replacement silently loses its simulation state.
  open func undo(_ project: Project) throws {
    fatalError("Action is abstract; override undo(_:)")
  }

  /// The `other instanceof JoinedAction ? ((JoinedAction) other).getLastAction() : other` idiom,
  /// written once.
  ///
  /// All three `shouldAppendTo` overrides in `SelectionActions` open with it, and they have to:
  /// see the note on `shouldAppendTo` above for what a drag looks like when they do not. Kept as
  /// a static on `Action` rather than a free function so it sits next to the comment explaining
  /// why it exists.
  public static func lastAction(of other: Action) -> Action {
    (other as? JoinedAction)?.lastAction ?? other
  }
}

/// `com.cburch.logisim.proj.JoinedAction`; several actions that undo as one unit.
///
/// This is the *only* grouping mechanism. Do not reimplement it as an array of actions inside
/// `Project`: the group has to be a first-class `Action` because `Project.doAction` puts the
/// result of `append` straight back into the undo log and later asks *that object* for its
/// `name`, its `isModification`, and whether the next edit should append to it. A bare array
/// would have to re-derive all three at every use site, and the places that introspect a group,
/// `firstAction` / `lastAction`, which `SelectionActions` uses to decide whether a drag ended
/// on a drop, would have nothing to ask.
@MainActor
public final class JoinedAction: Action {

  /// `todo`. Java grows a fresh array on every `append`; a Swift `Array` grows amortised, which
  /// is the same semantics with better constants and no `System.arraycopy`.
  private var todo: [Action]

  public init(_ actions: Action...) {
    self.todo = actions
  }

  public init(_ actions: [Action]) {
    self.todo = actions
  }

  /// `append(Action)`. Grows in place and returns `self`, so coalescing a long gesture stays
  /// flat rather than building a right-leaning tree of wrappers.
  public override func append(_ other: Action) -> Action? {
    todo.append(other)
    return self
  }

  public override func doIt(_ project: Project) throws {
    for action in todo {
      try action.doIt(project)
    }
  }

  /// `getActions()`.
  public var actions: [Action] { todo }

  /// `getFirstAction()`. Traps on an empty group, matching Java's `todo[0]` on a zero-length
  /// array: no caller can reach it, because `JoinedAction` is only ever built from at least two
  /// actions by `Action.append`. D13 leaves this trapping deliberately; it is a programmer
  /// error, not something a `.circ` file or a user edit can produce.
  public var firstAction: Action { todo[0] }

  /// `getLastAction()`. Same reasoning as `firstAction`.
  public var lastAction: Action { todo[todo.count - 1] }

  /// `getName()`: the *first* action's name, not the last. The Edit menu therefore says
  /// "Undo Move Selection" for a drag that coalesced fifty moves, which is what the user thinks
  /// they did.
  public override var name: String { todo[0].name }

  /// `isModification()`: true if **any** member modifies. A group of one real edit and forty
  /// selection changes still dirties the file.
  public override var isModification: Bool {
    todo.contains { $0.isModification }
  }

  /// `undo(Project)`: reverse order, which is the whole reason the group exists.
  public override func undo(_ project: Project) throws {
    for action in todo.reversed() {
      try action.undo(project)
    }
  }
}
