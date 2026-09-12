// logisim-evolved: a native Swift/macOS port of logisim-evolution.
// Derived from logisim-evolution, which is GPL-3.0-only. This port is a derivative work and is
// therefore GPL-3.0-only.
// SPDX-License-Identifier: GPL-3.0-only
//
// A project with an external library, opened and saved BY THE APP, keeps its library reference
// relative. It does today, and this pins that it keeps doing so.
//
// ── This file began as the fix for board #87, and the board was wrong ────────────────────────
//
// #87 claimed the app writes ABSOLUTE library paths. The observation behind it was correct and
// was verified twice: `LogisimFileProjectHost` opens every document through
// `openLogisimFile(data:)`, the overload that never touches `mainFileURL`, so the loader's
// `currentDirectory` really is nil for every document the app opens.
//
// **The consequence did not follow.** With no `currentDirectory`, `LibraryManager.toRelative`
// returns early, and what it returns is the descriptor the file already carried, not a
// recomputed absolute path. So the reference round-trips VERBATIM, which is exactly what D8
// preservation is for and exactly what a portable project needs.
//
// Measured, both ways, printing the saved `<lib>` lines:
//
//     without a sourceURL   file#shared.circ
//     with a sourceURL      file#../../../../../../private/var/folders/…/shared.circ
//
// So supplying the URL, the "fix", made it strictly WORSE on any symlinked directory and
// neutral elsewhere, because it switches `toRelative` from preserving to recomputing, and the
// recomputation resolves the file side through the link while leaving the directory side alone.
// That divergence is upstream's own and is pinned by
// `LibraryRelativePathTests.symlinkedProjectDirectoryClimbsOutThroughTheLink`; the point here is
// that the app never reaches it.
//
// The change was written, measured, and reverted. **The red probe is what caught it**: reverting
// the fix reddened nothing, and rather than accept a green probe the two outputs were printed and
// compared. A probe that reddens nothing is not a passing probe.
//
// The test is kept because the property is worth pinning and nothing pinned it before:
// `canonical` and `migration` drive `logisim-cli`, which passes a URL and therefore takes the
// recomputing path. This is the only coverage of what the APP writes.

import Darwin
import Foundation
import LogisimFile
import Testing
import UniformTypeIdentifiers

@testable import LogisimUI

/// POSIX `realpath`, matching Java's `getCanonicalPath`.
private func canonicalPath(_ path: String) -> String {
  guard let resolved = realpath(path, nil) else { return path }
  defer { free(resolved) }
  return String(cString: resolved)
}

/// A minimal library, and a project that names it by a RELATIVE path in the same directory.
private func writeProject(in directory: URL) throws -> URL {
  let library = """
    <?xml version="1.0" encoding="UTF-8" standalone="no"?>
    <project source="4.1.0" version="1.0">
      <lib desc="#Base" name="0"/>
      <lib desc="#Wiring" name="1"/>
      <main name="shared"/>
      <circuit name="shared"/>
    </project>
    """
  try library.write(
    to: directory.appendingPathComponent("shared.circ"), atomically: true, encoding: .utf8)

  let project = """
    <?xml version="1.0" encoding="UTF-8" standalone="no"?>
    <project source="4.1.0" version="1.0">
      <lib desc="#Base" name="0"/>
      <lib desc="#Wiring" name="1"/>
      <lib desc="file#shared.circ" name="2"/>
      <main name="main"/>
      <circuit name="main"/>
    </project>
    """
  let url = directory.appendingPathComponent("main.circ")
  try project.write(to: url, atomically: true, encoding: .utf8)
  return url
}

@Suite("Board #87 — the app keeps external library paths relative")
struct AppLibraryPathTests {

  @Test("a project opened and saved by the app keeps its library reference relative")
  @MainActor
  func appSaveKeepsTheLibraryPathRelative() throws {
    // `javaCanonicalPath` on the temp root FIRST, and this is not incidental. On macOS
    // `$TMPDIR`, `/tmp` and `/var` are all symlinks into `/private`, and 4.1.0's `toRelative`
    // resolves the FILE side through the link while leaving the DIRECTORY side alone, so a
    // fixture rooted at an unresolved temp path legitimately produces
    // `../../../../../../private/var/…`, and this test would fail on faithful behaviour.
    //
    // That divergence is upstream's, is already pinned by
    // `LibraryRelativePathTests.symlinkedProjectDirectoryClimbsOutThroughTheLink`, and is matched
    // against `CanonBridge.java`'s canonicalisation rows. It is a different question from the one
    // here. Measured while writing this test: without the resolve, the saved path came out as
    // `file#../../../../../../private/var/folders/…/shared.circ`: relative, correct, and useless
    // as evidence for board #87.
    // POSIX `realpath`, which is what Java's `getCanonicalPath` calls. Foundation's
    // `resolvingSymlinksInPath()` deliberately does NOT resolve `/tmp` or `/var`, the port's own
    // `canonicalPathResolvesTmpWhereFoundationDeclinesTo` asserts exactly that difference, so it
    // is the wrong tool here.
    let root = URL(fileURLWithPath: canonicalPath(NSTemporaryDirectory()))
    let directory = root.appendingPathComponent("libpath-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let url = try writeProject(in: directory)
    let data = try Data(contentsOf: url)

    // Through the real app path, with the URL the shell would supply.
    let host = try LogisimFileProjectHostFactory().openProject(
      data: data, url: url, contentType: LogisimDocumentType.circuit)
    let saved = String(decoding: try host.serialize(), as: UTF8.self)

    // The reference must survive, and it must survive RELATIVE. Both halves are asserted: a
    // version that dropped the library entirely would satisfy "no absolute path" trivially, and
    // that is exactly the failure D8 preservation exists to prevent.
    #expect(
      saved.contains("desc=\"file#shared.circ\""),
      """
      the external library reference did not round-trip as a relative path. Saved bytes:
      \(saved.split(separator: "\n").filter { $0.contains("<lib") }.joined(separator: "\n"))
      """)
    #expect(
      !saved.contains(directory.path),
      """
      the saved file embeds the ABSOLUTE directory \(directory.path), so the project is not \
      portable — board #87. The app's loader has no currentDirectory, so LibraryManager.toRelative \
      returned the canonical path.
      """)
  }

  /// The other half of the contract, and the reason `sourceURL` is optional rather than required:
  /// an untitled document genuinely has no directory, and asking for one would be a lie.
  @Test("a new untitled project still opens, with no directory to be relative to")
  @MainActor
  func untitledProjectOpensWithoutAURL() throws {
    let host = try LogisimFileProjectHostFactory().makeEmptyProject()
    #expect(!(try host.serialize()).isEmpty)
  }
}

/// Board #94's guard, at the layer upstream puts it: the project, not the model.
@Suite("Board #94 — the app refuses to remove a circuit another circuit places")
struct RemoveUsedCircuitGuardTests {

  private static let twoCircuits = """
    <?xml version="1.0" encoding="UTF-8" standalone="no"?>
    <project source="4.1.0" version="1.0">
      <lib desc="#Base" name="0"/>
      <lib desc="#Wiring" name="1"/>
      <main name="main"/>
      <circuit name="helper"/>
      <circuit name="main">
        <comp loc="(100,100)" name="helper"/>
      </circuit>
    </project>
    """

  /// `main` places `helper`, so `helper` must not be removable: and `main`, which nothing
  /// places, must still be. Both halves are asserted: a guard that refuses everything would
  /// satisfy the first on its own.
  @Test("a placed circuit cannot be removed, an unplaced one still can")
  @MainActor
  func theGuardDistinguishesPlacedFromUnplaced() throws {
    let host = try LogisimFileProjectHostFactory().openProject(
      data: Data(Self.twoCircuits.utf8), url: nil, contentType: LogisimDocumentType.circuit)
    let outline = host.outline
    let helper = try #require(outline.circuits.first { $0.name == "helper" })
    let main = try #require(outline.circuits.first { $0.name == "main" })

    #expect(
      !host.canPerform(.removeCircuit(helper.id)),
      "`helper` is placed inside `main`; removing it drops that placement on the next save")
    #expect(
      host.canPerform(.removeCircuit(main.id)),
      "`main` is placed by nothing and must stay removable — the guard must not refuse everything")
  }
}
