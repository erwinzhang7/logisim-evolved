// logisim-evolved-app: the macOS application entry point.
//
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// ── Why this file is three lines, and why it exists at all ──────────────────────────────────
//
// `LogisimEvolvedApp` is deliberately NOT annotated `@main`: `LogisimUI` is a library target, so
// the shell stays unit-testable and previewable and the entry point remains a build-graph detail
// rather than a source-code one. Its own header says so. This is the other half of that design.
//
// It had been missing. `LogisimEvolvedApp.swift` was complete, scenes, DocumentGroup, Settings,
// the GPLv3 §5 About window, and `Package.swift` declared only libraries plus `logisim-cli`, so
// **nothing built an app bundle and the entire UI half had never been run.** Not once. That is
// the same defect class as the eleven join failures catalogued in objectives.md: each half
// correct on its own, nothing owning the join. Here the missing half was the manifest entry.
//
// Consequences worth stating, because they shape what to trust:
//   * every `LogisimUITests` result is a library-level result: real, but not evidence the app
//     launches;
//   * `ToolCanvas` has references and NO conformer, so canvas editing is a design with no
//     substrate. This file does not fix that; it makes it observable.
//
// Nothing else belongs here. Anything that looks like it wants to live in this file wants to
// live in `LogisimUI` instead, where it can be tested.
//
// ── IN PARTICULAR: THE BUILTIN REGISTRATIONS ARE NOT HERE, AND THAT IS THE DECISION ──────────
//
// `logisim-cli/main.swift` calls `StdLibraries.registerAll()`, `SocLibrary.registerBuiltinTools()`
// and `BuiltinHdlWiring.installBuiltins()` from its own `main`, so the symmetric-looking move is
// to add the same three lines here. Deliberately not done. This file is the ONE piece of the app
// no test executes: `LogisimUITests` links `LogisimUI` and never runs this `main`, so a
// registration made here would be present in the shipping binary and absent from every test;
// the tests would then be exercising a differently-configured program than the one that ships,
// which is the same "a registration living in one executable's startup is a registration the
// other silently lacks" trap that left `#Soc` unregistered for a milestone, one level down and
// harder to see.
//
// They live in `LogisimFileProjectHostFactory.registerBuiltinLibrariesIfNeeded` instead. That is
// the app's equivalent of the CLI's `main`; it is the first thing both `makeEmptyProject` and
// `openProject` do, so it still precedes every load, it still runs exactly once, and the app and
// the tests get the identical set.
//
// The CLI cannot use the same home: it never constructs a `ProjectHostFactory`, and
// `LogisimUI` is not in its link graph at all.

import LogisimUI

LogisimEvolvedApp.launch()
