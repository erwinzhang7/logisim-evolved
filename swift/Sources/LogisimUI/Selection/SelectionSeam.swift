// SelectionSeam.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.proj.{Action, JoinedAction, Project,
// Dependencies} and com.cburch.logisim.circuit.{CircuitMutation, CircuitTransaction,
// CircuitTransactionResult, ReplacementMap}),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// ── Why this file exists, and what is left of it ────────────────────────────────────────────
//
// The selection/clipboard slice and the Project/undo slice were ported in parallel, so this file
// declared the minimum of Project/'s surface the selection needed, as protocols, and neither
// slice reached into the other's files. **Project/ has since landed and those stand-ins are
// gone.** The wiring turned out exactly as predicted, so the reconciliation was a rename:
//
//   | deleted stand-in             | now used directly                                    |
//   |------------------------------|------------------------------------------------------|
//   | `ProjectAction`              | `Action`            (com.cburch.logisim.proj.Action)  |
//   | `JoinedProjectAction`        | `JoinedAction`                                        |
//   | `SelectionProject`           | `Project`                                             |
//   | `CircuitMutating`            | `CircuitMutation`                                     |
//   | `CircuitTransacting`         | `CircuitTransaction`                                  |
//   | `CircuitTransactionOutcome`  | `CircuitTransactionResult`                            |
//   | `ComponentReplacementMap`    | `ReplacementMap`                                      |
//
// Only `CircuitDependencyGraph` survives, because `com.cburch.logisim.proj.Dependencies` is not
// ported yet. Two findings from the deleted protocols are worth keeping and have moved to the
// types they describe:
//
//   * **`ReplacementMap.replacements(for:)`'s nil-versus-empty distinction is load-bearing.**
//     `Selection.MyListener` only touches a component when the answer is non-nil, and an *empty*
//     answer means "replaced by nothing", i.e. deleted. Confusing the two silently drops
//     components out of the selection on undo.
//   * **`shouldAppendTo` must unwrap `JoinedAction` first.** All three overrides in
//     `SelectionActions` open with the same line; `Action.swift`'s header explains what breaks
//     when they do not.
//
// ── D13 ─────────────────────────────────────────────────────────────────────────────────────
//
// The one place this seam made a *choice* rather than a translation was `execute()`, which
// `throws` where Java's does not. `CircuitTransaction.execute()` kept that choice:
// `CircuitMutation.execute()` reaches `Circuit.mutatorAdd`, which the port has already made
// `throws` (it writes attributes on the duplicate-label path). So every transaction execution is
// a throwing call, and every selection action propagates rather than trapping.

import Foundation
import LogisimFile
import LogisimKernel

// MARK: - Dependencies

/// `com.cburch.logisim.proj.Dependencies`; only the one query paste needs.
///
/// The one member of the original stand-in set that has no ported counterpart yet.
/// `Project.depends` is a real field upstream (`Project.java:353`), so this is held on `Project`
/// under the same name and reached through `Project.dependencies`; when `Dependencies` is ported
/// it conforms and this protocol disappears with no call-site change.
@MainActor
public protocol CircuitDependencyGraph: AnyObject {
  /// `canAdd(Circuit, Circuit)`. False when adding `sub` inside `circuit` would close a cycle.
  func canAdd(_ circuit: Circuit, _ sub: Circuit) -> Bool
}

// MARK: - Circuit queries the selection needs

/// The two circuit lookups `SelectionBase.hasConflictTranslated` performs.
///
/// `getAllContaining(Location)` already exists on `Circuit`; `getExclusive(Location)` is
/// `CircuitPoints` connectivity, which `Circuit.swift`'s own header lists as M3. Declaring both
/// here means the conflict test is written once, against its final shape, and starts answering
/// correctly the moment M3 fills the second one in: rather than the whole method being written
/// twice.
///
/// **Known gap until M3.** With `exclusiveComponent(at:)` answering `nil`, the exclusive-end half
/// of the conflict test never fires, so a paste or duplicate whose *only* obstruction is an
/// exclusive end (two components fighting over one connection point) is placed where upstream
/// would have shifted it. The bounds-equality half, which is what actually decides the common
/// "duplicate lands 10,10 away" case: is complete.
@MainActor
public protocol SelectionCircuitQueries: AnyObject {
  /// `getAllContaining(Location)`.
  func componentsContaining(_ point: Location) -> [any Component]

  /// `getExclusive(Location)`.
  func exclusiveComponent(at point: Location) -> (any Component)?
}

extension Circuit: SelectionCircuitQueries {
  public func componentsContaining(_ point: Location) -> [any Component] {
    allContaining(point)
  }

  /// See `SelectionCircuitQueries`; M3's `CircuitPoints` owns the real answer. Returning `nil`
  /// is the *permissive* direction: it can let a placement through that upstream would have
  /// nudged, and never blocks one upstream allows.
  public func exclusiveComponent(at point: Location) -> (any Component)? {
    nil
  }
}

// MARK: - Factory tests that have no capability property yet

/// The three `factory instanceof …` tests the selection performs, and where each one goes.
///
/// `ComponentFactory` already carries `isTunnel`/`isPin`/`isClock` as capability properties
/// (see its header: they are load-bearing at load time, so they had to exist at M2). `Ram`,
/// `Rom` and `Text` are not among them, and adding properties to `ComponentFactory` is not this
/// slice's file to touch: so the tests live here, keyed on the factory's `.circ` name, which is
/// the same token `<comp name="…">` carries.
///
/// Substituting a name comparison for `instanceof` is exact for every file upstream can produce:
/// the name is the library-unique identifier the loader resolves against. It would diverge only
/// for a third-party library that named a component `RAM` or `ROM`: and D11 already rules JAR
/// libraries out permanently, so no such factory can exist in this port.
///
/// Each closure is `var` so that when `LogisimStd`'s `Ram`/`Rom`/`Text` become directly testable
/// the app can install `{ $0 is Ram || $0 is Rom }` and delete the name comparison without
/// touching any call site.
@MainActor
public enum SelectionFactoryTests {
  /// `comp.getFactory() instanceof Rom || comp.getFactory() instanceof Ram`, from
  /// `SelectionBase.copyComponents`.
  ///
  /// What it decides: whether a copied component **shares** its attribute set with the original
  /// instead of getting a clone. RAM and ROM share deliberately, their `contents` is megabytes
  /// of memory image and upstream refuses to duplicate it, which means editing the copy's
  /// contents edits the original's too. That is upstream behaviour, and it is visible in the
  /// saved file, so it is reproduced rather than "fixed".
  public static var sharesAttributesWhenCopied: (any ComponentFactory) -> Bool = { factory in
    factory.name == "RAM" || factory.name == "ROM"
  }

  /// `compFactory == Text.FACTORY`, from `SelectionActions.getReplacementMap`.
  ///
  /// Text components are skipped when the paste target is resolving factories against the
  /// destination file's libraries; they are always available, so there is nothing to resolve.
  public static var isTextFactory: (any ComponentFactory) -> Bool = { factory in
    factory.name == "Text"
  }
}
