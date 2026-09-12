// PreferenceConsumerTests.swift: part of logisim-evolved.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// The gate for the FIFTH SEAM SHAPE: a preference that is bound to a control, persisted
// correctly, and read back by nobody.
//
// Four of them had accumulated: `defaultTickFrequency`, `autoPropagateByDefault`,
// `confirmCircuitDeletion`, `addsUnnamedLabels`. The user flips the control, it survives a
// relaunch, and the application's behaviour never changes.
//
// ── Why no existing checker can find this, and why it kept regrowing ────────────────────────
//
// `deadseam.py` hunts unreferenced declarations. An inert preference is referenced twice, once
// by `SettingsWindow`'s `$preferences.foo` binding and once by `save()`'s dictionary, so it is
// not dead by any reachability measure. The behaviour gates cannot see it either: canonical,
// migration and edit-parity all operate on serialised circuit content, and a preference changes
// none of that. It is invisible from every direction except this one.
//
// It had *already* been six before the autosave slice consumed two, which is the argument for a
// gate rather than a one-off audit: the population regrows whenever someone adds a control
// ahead of its consumer, and nothing complains.
//
// ── How this test measures, and why it is not a hand-maintained list ────────────────────────
//
// The enumeration is `Mirror`, not a literal. `@Observable` rewrites every `public var foo`
// into a computed property over a stored `_foo`, so reflecting a live `EditorPreferences`
// yields exactly the stored preferences plus three known non-preferences (`defaults`,
// `_isLoading`, `_$observationRegistrar`). A preference added tomorrow therefore enters this
// test's scope with **zero edits here**, which is the whole point. A hand-written list is the
// failure mode this file exists to prevent, so it must not contain one.
//
// The consumer side is measured by scanning `Sources/` on disk, the same technique
// `PlatformFreedomTests` uses, located from `#filePath` because `swift test` does not pin the
// working directory. A consumer is a reference of the form `preferences.foo` /
// `Preferences.shared.foo` in a file OUTSIDE `Sources/LogisimUI/Preferences/`; a binding in
// `SettingsWindow` and a key in `save()` are not consumers, which is precisely the distinction
// the naive "is it mentioned anywhere" check gets wrong.
//
// ── The two things that make it self-liquidating rather than a rubber stamp ─────────────────
//
//   1. The exception list lives in `EditorPreferences.preferencesPendingWiring`, in the source,
//      where a maintainer reading the model sees it; not buried in a test.
//   2. The assertion is an EQUALITY, not a subset. A newly-inert preference fails because it is
//      not on the list; an exception that has since acquired a consumer ALSO fails, because it
//      is still on the list. So the list cannot grow silently and cannot rot silently.

import Foundation
import Testing

@testable import LogisimUI

@Suite("Preferences — every preference has a consumer, or is an explicitly pinned exception")
@MainActor
struct PreferenceConsumerTests {

  // MARK: - Locating the tree

  /// `swift/Sources`, from this file rather than from the process working directory, which
  /// `swift test` does not pin. Same approach as `PlatformFreedomTests.moduleRoot`.
  static var sourcesRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // LogisimUITests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // swift
      .appendingPathComponent("Sources")
  }

  static var preferencesDirectory: URL {
    sourcesRoot.appendingPathComponent("LogisimUI/Preferences")
  }

  /// Every `.swift` file under `Sources/` that is NOT part of the preferences model or its view.
  /// Those two are excluded on purpose: a `$preferences.foo` binding and a `"foo": foo` entry in
  /// the persistence dictionary are what an inert preference *has*, so counting them as
  /// consumers would make the test vacuous.
  static func consumerFiles() throws -> [URL] {
    let root = sourcesRoot
    let excluded = preferencesDirectory.standardizedFileURL.path
    guard
      let walker = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: [.isRegularFileKey])
    else {
      Issue.record("could not enumerate \(root.path)")
      return []
    }
    var result: [URL] = []
    for case let url as URL in walker where url.pathExtension == "swift" {
      if url.standardizedFileURL.path.hasPrefix(excluded) { continue }
      result.append(url)
    }
    return result
  }

  // MARK: - Enumerating the preferences

  /// The three stored members of `EditorPreferences` that are not preferences. Pinned by name so
  /// that if the class gains a fourth piece of private machinery, this test says so rather than
  /// silently demanding a consumer for it.
  static let nonPreferenceStorage: Set<String> = ["defaults", "isLoading", "$observationRegistrar"]

  /// Reflect a live instance and strip `@Observable`'s leading underscore.
  static func declaredPreferences() -> Set<String> {
    var names: Set<String> = []
    for child in Mirror(reflecting: EditorPreferences.ephemeral()).children {
      guard let label = child.label else { continue }
      let name = label.hasPrefix("_") ? String(label.dropFirst()) : label
      if nonPreferenceStorage.contains(name) { continue }
      names.insert(name)
    }
    return names
  }

  /// If `@Observable`'s expansion ever changes shape, or someone adds private storage, the
  /// reflection above would silently start reporting the wrong set, and every other assertion in
  /// this file would be measuring nothing. So the machinery members are pinned first.
  @Test("Reflection sees the preference storage and nothing else")
  func reflectionIsTrustworthy() {
    let labels = Set(Mirror(reflecting: EditorPreferences.ephemeral()).children.compactMap(\.label))
    #expect(labels.contains("defaults"))
    #expect(labels.contains("_isLoading"))
    #expect(labels.contains("_$observationRegistrar"))

    let preferences = Self.declaredPreferences()
    // A floor, not an equality: the point of this file is that the set may grow.
    #expect(preferences.count >= 20, "only \(preferences.count) preferences reflected")
    #expect(preferences.contains("showGrid"))
    #expect(preferences.contains("autosaveEnabled"))
    #expect(!preferences.contains("isLoading"))
    #expect(!preferences.contains("defaults"))
  }

  /// `save()` must cover the reflected set exactly. A preference missing from the dictionary is
  /// a silent data-loss bug; a key in the dictionary with no property behind it is a leftover.
  /// This runs `save()` for real against an ephemeral suite rather than reading the literal.
  @Test("Persistence covers exactly the reflected preference set")
  func persistenceCoversEveryPreference() throws {
    let suiteName = "logisim-evolved.prefaudit.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let preferences = EditorPreferences.forTesting(defaults: defaults)
    preferences.resetAll()  // resetAll ends in save()

    let stored = try #require(defaults.dictionary(forKey: "prefs.v1"))
    #expect(Set(stored.keys) == Self.declaredPreferences())
  }

  // MARK: - The audit itself

  /// A preference is consumed when some file outside `Sources/LogisimUI/Preferences/` reads it
  /// through a `EditorPreferences` value. Both spellings the codebase actually uses are matched:
  /// `model.preferences.foo` (the overwhelming majority) and `EditorPreferences.shared.foo`.
  static func consumers(of name: String, in files: [(url: URL, text: String)]) -> [String] {
    let needles = ["preferences.\(name)", "Preferences.shared.\(name)"]
    return files.compactMap { file in
      for needle in needles where file.text.contains(needle) {
        // Guard against `preferences.showGridLines` matching a probe for `showGrid`.
        if Self.hasWordBoundedHit(file.text, needle) { return file.url.lastPathComponent }
      }
      return nil
    }
  }

  /// `text.contains(needle)` is not enough: `preferences.showGrid` is a prefix of a
  /// hypothetical `preferences.showGridLines`, and a false positive here would mark an inert
  /// preference as consumed; the exact failure this file is supposed to catch.
  static func hasWordBoundedHit(_ text: String, _ needle: String) -> Bool {
    var searchRange = text.startIndex..<text.endIndex
    while let found = text.range(of: needle, range: searchRange) {
      if found.upperBound == text.endIndex { return true }
      let next = text[found.upperBound]
      if !(next.isLetter || next.isNumber || next == "_") { return true }
      searchRange = found.upperBound..<text.endIndex
    }
    return false
  }

  /// The gate.
  ///
  /// Equality, not containment, in both directions; see this file's header. A preference that
  /// goes inert fails here, and so does an exception that has been wired up and not pruned.
  @Test("Every preference has a consumer outside Preferences/, or is a pinned exception")
  func everyPreferenceIsConsumed() throws {
    let files = try Self.consumerFiles().map {
      (url: $0, text: (try? String(contentsOf: $0, encoding: .utf8)) ?? "")
    }
    #expect(files.count > 100, "only \(files.count) source files scanned — the walk is wrong")

    // The template redirection: these six reach the outside world through
    // `canvasAppearanceTemplate`, not by name. Its own reader is checked like any other, so if
    // the template loses its consumer they all fail together rather than passing on a technicality.
    let templateReaders = Self.consumers(of: "canvasAppearanceTemplate", in: files)
    #expect(
      !templateReaders.isEmpty,
      "canvasAppearanceTemplate itself has no reader — the redirection below is unsound")

    var inert: Set<String> = []
    for name in Self.declaredPreferences().sorted() {
      if EditorPreferences.preferencesConsumedViaCanvasTemplate.contains(name) { continue }
      if Self.consumers(of: name, in: files).isEmpty { inert.insert(name) }
    }

    let pinned = Set(EditorPreferences.preferencesPendingWiring.keys)
    #expect(
      inert == pinned,
      """
      Preferences with no consumer: \(inert.sorted()).
      Pinned as pending wiring:     \(pinned.sorted()).
      A name in the first list and not the second is a NEW inert preference — wire it or
      remove the control. A name in the second and not the first has been wired: delete its
      entry from EditorPreferences.preferencesPendingWiring.
      """)
  }

  /// The redirection list must not become a dumping ground. Every name on it has to be a real
  /// preference AND actually appear in the template, or it would be an exemption in disguise.
  @Test("The canvas-template redirection names only preferences the template really reads")
  func templateRedirectionIsHonest() throws {
    let declared = Self.declaredPreferences()
    let source = try String(
      contentsOf: Self.preferencesDirectory.appendingPathComponent("EditorPreferences.swift"),
      encoding: .utf8)

    // The body of `canvasAppearanceTemplate`, from its signature to the closing of the
    // `CanvasAppearance(...)` call.
    let marker = "public var canvasAppearanceTemplate: CanvasAppearance {"
    let start = try #require(source.range(of: marker))
    let body = String(source[start.upperBound...].prefix(600))

    for name in EditorPreferences.preferencesConsumedViaCanvasTemplate {
      #expect(declared.contains(name), "\(name) is redirected but is not a preference")
      #expect(body.contains(name), "\(name) is redirected but canvasAppearanceTemplate omits it")
    }
  }

  /// The removals made here, pinned so they cannot creep back as controls without a consumer.
  /// Each was removed because 4.1.0 has no such preference at all: upstream confirms circuit
  /// removal unconditionally (`ProjectCircuitActions.java:240-247`), `AutoLabel` is a per-tool
  /// runtime toggle bound to a keystroke rather than an application preference, and
  /// `Canvas.snapToGrid(MouseEvent)` in the shipped 4.1.0 jar is branchless bytecode that reads
  /// no `PrefMonitor` at all.
  ///
  /// `snapToGrid` is the one this test would NOT have caught on its own, and that is worth
  /// stating: unlike the other two it had a real reader (`CanvasHostView`), so the audit above
  /// was satisfied by it and always would have been. It was inert one level further down; the
  /// value reached the tool layer and the tools ignored it. Pinning it here stops it returning;
  /// it is not what found it.
  @Test("The preferences removed as unfounded have not come back")
  func removedPreferencesStayRemoved() {
    let declared = Self.declaredPreferences()
    #expect(!declared.contains("confirmCircuitDeletion"))
    #expect(!declared.contains("addsUnnamedLabels"))
    #expect(!declared.contains("snapToGrid"))
  }

  /// Deleting a persisted key raises a migration question, and this is the answer rather than an
  /// assumption: an existing `prefs.v1` written by a build that still had `snapToGrid` must load
  /// harmlessly, and the stray key must disappear on the next write.
  ///
  /// The failure this rules out is not the stray key itself; it is a decoder that treats an
  /// unknown key as corruption and falls back to defaults, which would silently reset every
  /// OTHER preference for anyone upgrading. `load()` reads by name and never enumerates, and
  /// `save()` rebuilds the dictionary and replaces the whole value, so neither can happen; both
  /// halves are checked below against a seeded domain rather than read off the source.
  @Test("A preferences file still carrying the removed snapToGrid key is harmless")
  func aStalePreferencesFileIsHarmless() throws {
    let suiteName = "logisim-evolved.prefstale.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    // A dictionary an older build could plausibly have written: the removed key, plus two live
    // ones set to NON-default values so a silent reset would be visible.
    defaults.set(
      [
        "snapToGrid": false,
        "showGrid": false,
        "zoomSensitivity": 2.5,
      ] as [String: Any], forKey: "prefs.v1")

    let preferences = EditorPreferences.forTesting(defaults: defaults)

    // Half one: the stray key did not disturb the load.
    #expect(preferences.showGrid == false, "a live preference was lost alongside the stray key")
    #expect(preferences.zoomSensitivity == 2.5)

    // Half two: the next write drops it. `showGrid` is toggled to trigger `save()` through the
    // real `didSet`, which is the path an actual user's next preference change takes.
    preferences.showGrid = true
    let rewritten = try #require(defaults.dictionary(forKey: "prefs.v1"))
    #expect(rewritten["snapToGrid"] == nil, "the removed key survived a save")
    #expect(rewritten["showGrid"] as? Bool == true)
    #expect(rewritten["zoomSensitivity"] as? Double == 2.5, "an unrelated preference was lost")
  }

  /// An exception must carry the address of the edit that would discharge it, or the list
  /// degrades into "known broken, no plan".
  @Test("Every pending-wiring exception names a real file and line")
  func pendingWiringEntriesAreActionable() throws {
    #expect(!EditorPreferences.preferencesPendingWiring.isEmpty)
    for (name, address) in EditorPreferences.preferencesPendingWiring {
      let path = String(address.prefix(while: { $0 != ":" }))
      let url = Self.sourcesRoot.appendingPathComponent(path)
      #expect(
        FileManager.default.fileExists(atPath: url.path),
        "\(name) points at \(path), which does not exist")
      #expect(address.contains(":"), "\(name)'s address names no line")
    }
  }
}
