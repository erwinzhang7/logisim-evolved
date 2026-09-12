// LibraryReplacementApply.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.file.LoadedLibrary's three `replaceAll`
// overloads), https://github.com/logisim-evolution/logisim-evolution. Copyright by the
// Logisim-evolution developers. This translation is a derivative work and is therefore
// GPL-3.0-only. See LICENSE.md.
// SPDX-License-Identifier: GPL-3.0-only
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// WHAT HAPPENS TO A PLACED COMPONENT WHEN ITS LIBRARY IS RELOADED.
//
// `LoadedLibrary.resolveChanges` diffs the old and new base libraries and builds two complete
// identity maps: old factory → new factory, old tool → new tool, with `nil` values for things
// that are gone. It then handed that to `LoadedLibrary.replacementHandler`, **which nothing ever
// assigned**. The map was computed correctly on every reload and dropped on the floor.
//
// The visible consequence: File ▸ "Reload Library" appeared to work: the explorer updated, the
// listeners fired, the library's own name changed, and every component already placed on a
// canvas kept pointing at a factory belonging to the file that had just been replaced. Those
// components then paint, propagate and save from the OLD definition, so an edit made in the
// library file has no effect on the design that uses it until the project is closed and reopened.
//
// Only reachable from the interactive reload command, never from loading a file, which is why
// it survived this long.
//
// ── UPSTREAM'S THREE OVERLOADS, AND WHERE EACH LANDED ────────────────────────────────────────
//
// ```java
// replaceAll(compMap, toolMap)                  // walks open projects + loaded library files
// replaceAll(LogisimFile, compMap, toolMap)     // toolbar, mouse mappings, then every circuit
// replaceAll(Circuit, compMap)                  // remove + re-add each affected component
// ```
//
// The first needs `Projects.getOpenProjects()`; this port's stand-in is
// `LogisimFileProjectHost.liveHosts`: a weak registry, added for this and read by nothing else.
// The second's first two lines need `ToolbarData`/`MouseMappings.replaceAll`, both internal to
// `LogisimFile`, so they live on `LibraryReplacement.replaceAll(in:)` down there. The third needs
// `CircuitMutation`, which lives here.
//
// ── ONE THING THAT LOOKS LIKE AN OMISSION AND IS UPSTREAM'S ──────────────────────────────────
//
// `xn.execute()`; **not** `proj.doAction(xn.toAction(…))`. A library reload does not go on the
// undo stack upstream, and it should not: the user cannot undo half of it back into a coherent
// state, since the old factories are gone from the file. Preserved.
// ═════════════════════════════════════════════════════════════════════════════════════════════

import Foundation
import LogisimFile

/// The conformer for `LoadedLibrary.replacementHandler`. Installed by
/// `LogisimFileProjectHostFactory.registerBuiltinLibrariesIfNeeded`.
@MainActor
public enum LibraryReplacementApply {

  /// Problems raised by the most recent `apply`, for a caller that wants to surface them.
  ///
  /// The handler cannot throw, `resolveChanges` is called from `setBase`, deep inside a reload,
  /// and neither is a throwing context upstream, and a rewrite that fails on one component must
  /// still rewrite the rest. So failures are collected here rather than propagated or swallowed.
  public private(set) static var lastFailures: [String] = []

  /// `LoadedLibrary.replaceAll(Map, Map)`.
  public static func apply(_ replacement: LibraryReplacement) {
    lastFailures = []
    // Nothing to do is the common case for a reload that changed no factory, and skipping it
    // avoids walking every circuit of every open document for nothing.
    guard !replacement.factories.isEmpty || !replacement.tools.isEmpty else { return }

    for host in LogisimFileProjectHost.liveHosts {
      let project = host.project

      // `if (toolMap.containsKey(oldTool)) proj.setTool(toolMap.get(oldTool));`: note
      // `containsKey`, so a tool mapped to `nil` (gone entirely) deselects rather than being
      // left pointing at a dead tool. The `Tool??` double optional is what carries that
      // distinction: absent means "not from this library", present-and-nil means "removed".
      if let oldTool = project.tool, let entry = replacement.tools[ObjectIdentifier(oldTool)] {
        project.setTool(entry)
      }

      // `final var oldFactory = oldCircuit.getSubcircuitFactory(); if (compMap.containsKey(…))`
      // ; the user is editing a circuit that came from the reloaded library, so move them to its
      // replacement rather than leaving them editing an orphan.
      if let oldCircuit = project.currentCircuit {
        let key = ObjectIdentifier(oldCircuit.subcircuitFactory)
        if let entry = replacement.factories[key],
          let newFactory = entry as? any SubcircuitFactory,
          let newCircuit = newFactory.subcircuit as? Circuit
        {
          project.setCurrentCircuit(newCircuit)
        }
      }

      replaceAll(replacement, in: project.logisimFile)
    }

    // `for (final var file : LibraryManager.instance.getLogisimLibraries()) replaceAll(file, …)`
    // ; a library can itself use a library, so the rewrite has to reach files that are not open
    // documents.
    for file in LibraryManager.instance.logisimLibraries() {
      replaceAll(replacement, in: file)
    }
  }

  /// `LoadedLibrary.replaceAll(LogisimFile, compMap, toolMap)`.
  static func replaceAll(_ replacement: LibraryReplacement, in file: LogisimFile) {
    for error in replacement.replaceAll(in: file) {
      lastFailures.append("could not rebind a toolbar or mouse-mapping entry: \(error)")
    }
    for circuit in file.circuits {
      replaceAll(replacement, in: circuit)
    }
  }

  /// `LoadedLibrary.replaceAll(Circuit, compMap)`.
  static func replaceAll(_ replacement: LibraryReplacement, in circuit: Circuit) {
    // Collected first, then mutated: `nonWires` is the circuit's own live component order, and
    // removing from it while iterating is the classic concurrent-modification bug upstream's
    // `toReplace` list avoids too.
    let affected = circuit.nonWires.filter {
      replacement.factories[ObjectIdentifier($0.factory)] != nil
    }
    guard !affected.isEmpty else { return }

    let mutation = CircuitMutation(circuit)
    for component in affected {
      mutation.remove(component)
      // Present-and-nil means the factory is gone from the reloaded library: the component is
      // removed and NOT replaced, which is upstream's `if (factory != null)`.
      guard let entry = replacement.factories[ObjectIdentifier(component.factory)],
        let factory = entry
      else { continue }
      do {
        // `createAttributes(factory, comp.getAttributeSet())`; a fresh set from the NEW factory,
        // then every attribute the old one shared copied across by name. Copying the old set
        // wholesale would carry attributes the new factory does not declare, and would share one
        // set between two components.
        let attributes = factory.createAttributeSet()
        try LoadedLibrary.copyAttributes(to: attributes, from: component.attributeSet)
        mutation.add(
          try factory.createComponent(location: component.location, attributes: attributes))
      } catch {
        lastFailures.append(
          "could not rebuild \(component.factory.displayName) after a library reload: \(error)")
      }
    }

    do {
      // `xn.execute()`, deliberately not `doAction`, see the file header.
      _ = try mutation.execute()
    } catch {
      lastFailures.append("could not apply the reload to circuit \(circuit.name): \(error)")
    }
  }
}
