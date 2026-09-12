import Foundation
import Testing

@testable import LogisimFile

/// D16, task #15. `LibraryManager.toRelative` produces the string inside `<lib desc="file#…">`,
/// so it is codec output and a divergence here rewrites saved files.
///
/// 4.1.0 canonicalises **only the file side** and compares it against the raw
/// `currentDirectory.toString()`; 4.2.0-dev changed the directory side to `getCanonicalPath()`
/// and this port had followed main. Every expectation below was produced by driving the shipped
/// 4.1.0 jar's own private method, `tools/m2audit/RelativeBridge.java`, reflectively, and the
/// canonicalisation rows by `tools/m2audit/CanonBridge.java`.
///
/// The fixtures live under `/tmp` on purpose. On macOS `/tmp`, `/var` and every `$TMPDIR` are
/// symlinks into `/private`, which is exactly what makes the divergence reachable; a test rooted
/// anywhere else would pass against the defect.
@Suite("LibraryManager relative paths — 4.1.0 semantics")
struct LibraryRelativePathTests {

  // MARK: - javaCanonicalPath

  /// `resolvingSymlinksInPath()` returns `/tmp` unchanged, Foundation treats it as a stable
  /// alias, while `getCanonicalPath()` resolves it. This single assertion is what separates the
  /// two implementations, and it is why the doc comment forbids the Foundation call.
  @Test func canonicalPathResolvesTmpWhereFoundationDeclinesTo() {
    #expect(LibraryManager.javaCanonicalPath("/tmp") == "/private/tmp")
    #expect(URL(fileURLWithPath: "/tmp").resolvingSymlinksInPath().path == "/tmp")
  }

  /// `realpath(3)` alone fails when the leaf does not exist, which is every save-as target.
  /// Java resolves the deepest existing ancestor and re-appends the rest.
  @Test func canonicalPathResolvesTheDeepestExistingAncestor() throws {
    let fixture = try Fixture()
    let missing = fixture.root.appendingPathComponent("proj/not-created-yet.circ").path
    let canonical = LibraryManager.javaCanonicalPath(missing)
    #expect(canonical == "/private" + missing)
  }

  /// `collapse()` runs after the tail is re-appended, so `.` and `..` in the non-existent part
  /// are resolved lexically rather than being left in the output.
  @Test func canonicalPathCollapsesDotSegmentsLexically() throws {
    let fixture = try Fixture()
    let awkward = fixture.root.path + "/proj/./libs/../libs/helper.circ"
    #expect(
      LibraryManager.javaCanonicalPath(awkward)
        == "/private" + fixture.root.path + "/proj/libs/helper.circ")
  }

  /// `/..` resolves to `/`: `realpath(3)` succeeds on it outright, so `collapse()` never sees
  /// the `..` at all. Reasoning from `canonicalize_md.c` predicted `/..` here, and the jar said
  /// otherwise; both rows are measured.
  @Test func rootRelativeDotDotIsResolvedByRealpathNotByCollapse() {
    #expect(LibraryManager.javaCanonicalPath("/..") == "/")
    // Prefix resolves to "/", tail starts with "/"; the JDK drops one to avoid "//".
    #expect(LibraryManager.javaCanonicalPath("/../nonexistent-xyzzy") == "/nonexistent-xyzzy")
  }

  /// A path whose very FIRST component is missing survives untouched: the prefix loop stops one
  /// component short of the root rather than calling `realpath("")`.
  @Test func pathWithNoResolvableAncestorIsReturnedAsWritten() {
    #expect(
      LibraryManager.javaCanonicalPath("/nonexistent-xyzzy/deeper/still")
        == "/nonexistent-xyzzy/deeper/still")
  }

  /// The differential itself. `tools/m2audit/canonprobe.sh` writes `<input>\t<getCanonicalPath>`
  /// for a path set covering every branch; point `LOGISIM_CANON_ORACLE` at it and every row is
  /// re-checked against the JVM rather than against the hand-written rows above.
  ///
  /// Skipped rather than failed when the variable is unset, because the jar is not a build
  /// dependency, but note the assertion that the file was non-empty. A drivable oracle that
  /// produces nothing and exits 0 looks exactly like agreement.
  @Test func matchesTheJvmOnEveryProbedPath() throws {
    guard let oraclePath = ProcessInfo.processInfo.environment["LOGISIM_CANON_ORACLE"] else {
      return
    }
    let text = try String(contentsOfFile: oraclePath, encoding: .utf8)
    let rows = text.split(separator: "\n").map { $0.split(separator: "\t", maxSplits: 1) }
    #expect(!rows.isEmpty, "\(oraclePath) is empty — the oracle produced no rows")

    for row in rows {
      #expect(row.count == 2, "malformed oracle row: \(row)")
      guard row.count == 2 else { continue }
      let input = String(row[0])
      let expected = String(row[1])
      let actual = LibraryManager.javaCanonicalPath(input)
      if expected == "<IOException>" {
        #expect(actual == nil, "\(input): expected IOException, got \(actual ?? "nil")")
      } else {
        #expect(actual == expected, "\(input)")
      }
    }
  }

  // MARK: - toRelative

  /// The headline row of the D16 audit. `/tmp/<fixture>/proj` is the loader's current directory
  /// **as written**; the library file canonicalises into `/private/...`. Because only one side
  /// is resolved, the two share no leading component beyond `/`, and upstream walks all the way
  /// out and back down again.
  ///
  /// Under the both-sides-resolved implementation this was `libs/helper.circ`.
  @Test func unresolvedCurrentDirectoryForcesUpstreamToWalkOut() throws {
    let fixture = try Fixture()
    let loader = Loader()
    loader.setMainFile(fixture.root.appendingPathComponent("proj/main.circ"))

    let relative = try LibraryManager.toRelative(
      loader, fixture.root.appendingPathComponent("proj/libs/helper.circ"))

    // `/tmp/<fixture>/proj` has one leading empty component plus its own names; the file side
    // begins `/private/...`, so nothing past the leading "" matches.
    let depth = fixture.root.path.split(separator: "/").count + 1  // + "proj"
    #expect(relative == String(repeating: "../", count: depth)
      + "private" + fixture.root.path + "/proj/libs/helper.circ")
    #expect(relative.hasPrefix("../"))
    #expect(relative.contains("/private/"))
  }

  /// Row 2 of the same table: give upstream an already-canonical current directory and it
  /// produces the short form. This is the control; it is what makes row 1 evidence of a
  /// one-sided canonicalisation rather than of canonicalisation being broken outright.
  @Test func alreadyCanonicalCurrentDirectoryYieldsTheShortForm() throws {
    let fixture = try Fixture()
    let loader = Loader()
    loader.setMainFile(
      URL(fileURLWithPath: "/private" + fixture.root.path + "/proj/main.circ"))

    let relative = try LibraryManager.toRelative(
      loader, fixture.root.appendingPathComponent("proj/libs/helper.circ"))
    #expect(relative == "libs/helper.circ")
  }

  /// Row 3: a symlinked project directory. The file side resolves through the link, the
  /// directory side does not, so the result climbs out of the link and back down the real path.
  @Test func symlinkedProjectDirectoryClimbsOutThroughTheLink() throws {
    let fixture = try Fixture()
    let link = fixture.root.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(
      at: link, withDestinationURL: fixture.root.appendingPathComponent("proj"))

    let loader = Loader()
    loader.setMainFile(link.appendingPathComponent("main.circ"))

    let relative = try LibraryManager.toRelative(
      loader, link.appendingPathComponent("libs/helper.circ"))

    // Same shape as row 1; the point is that it is NOT the short form, which is what a
    // both-sides-resolved implementation returns.
    #expect(relative.hasPrefix("../"))
    #expect(relative.hasSuffix("/proj/libs/helper.circ"))
  }

  /// With no main file there is no current directory, and upstream returns the canonical path
  /// outright rather than anything relative.
  @Test func absentCurrentDirectoryReturnsTheCanonicalPath() throws {
    let fixture = try Fixture()
    let file = fixture.root.appendingPathComponent("proj/libs/helper.circ")
    let relative = try LibraryManager.toRelative(Loader(), file)
    #expect(relative == "/private" + file.path)
  }

  /// The end-to-end differential: every row is the shipped 4.1.0 jar's own private
  /// `LibraryManager.toRelative`, driven reflectively by `tools/m2audit/RelativeBridge.java`.
  /// Regenerate with `tools/m2audit/relprobe.sh`.
  ///
  /// This is the assertion that actually settles the D16 question. The hand-written cases above
  /// state what the behaviour *is*; this one says it is what the jar does, on a path set the
  /// jar itself produced.
  @Test func toRelativeMatchesTheJarOnEveryProbedPair() throws {
    guard let oraclePath = ProcessInfo.processInfo.environment["LOGISIM_RELATIVE_ORACLE"] else {
      return
    }
    let text = try String(contentsOfFile: oraclePath, encoding: .utf8)
    let rows = text.split(separator: "\n").map { $0.split(separator: "\t", omittingEmptySubsequences: false) }
    #expect(!rows.isEmpty, "\(oraclePath) is empty — the oracle produced no rows")

    var checked = 0
    var skippedNullDirectory = 0
    for row in rows {
      #expect(row.count == 4, "malformed oracle row: \(row)")
      guard row.count == 4 else { continue }
      let (mainFile, libraryFile, currentDirectory, expected) =
        (String(row[0]), String(row[1]), String(row[2]), String(row[3]))

      // KNOWN DIVERGENCE, skipped deliberately rather than silently: Java's
      // `new File("main.circ").getParentFile()` is null, so upstream has no current directory
      // and returns the absolute canonical path. `URL(fileURLWithPath:)` absolutises against
      // the process working directory, so `Loader.currentDirectory` is non-nil and the port
      // answers with a path relative to the cwd instead. It is reachable only by opening a
      // project through a bare filename with no directory part, and closing it means storing
      // the main file as a raw string rather than a URL across all of `Loader`. Recorded, not
      // silently passed.
      if currentDirectory == "<null>" {
        skippedNullDirectory += 1
        continue
      }

      let loader = Loader()
      loader.setMainFile(URL(fileURLWithPath: mainFile))
      #expect(
        loader.currentDirectory?.path == currentDirectory,
        "current directory diverged before toRelative even ran, for \(mainFile)")

      let actual = try LibraryManager.toRelative(loader, URL(fileURLWithPath: libraryFile))
      #expect(actual == expected, "\(mainFile) + \(libraryFile)")
      checked += 1
    }
    #expect(checked > 0, "every oracle row was skipped — that is not agreement")
    #expect(skippedNullDirectory <= 1, "more null-current-directory rows than the one known case")
  }

  // MARK: - Fixture

  /// `/tmp/<uuid>/proj/{main.circ,libs/helper.circ}`. Rooted at `/tmp` rather than at
  /// `FileManager.temporaryDirectory` so the symlink is `/tmp` itself: the shortest and most
  /// stable macOS case, and the one the jar rows above were generated from.
  private struct Fixture {
    let root: URL

    init() throws {
      root = URL(fileURLWithPath: "/tmp/logisim-relpath-" + UUID().uuidString)
      let fm = FileManager.default
      try fm.createDirectory(
        at: root.appendingPathComponent("proj/libs"), withIntermediateDirectories: true)
      try Data("x\n".utf8).write(to: root.appendingPathComponent("proj/main.circ"))
      try Data("x\n".utf8).write(to: root.appendingPathComponent("proj/libs/helper.circ"))
      // Left on disk: a `deinit` cleanup would race the assertions that read the tree, and
      // /tmp is reaped by the OS. Named with a fixed prefix so a stray one is identifiable.
    }
  }
}
