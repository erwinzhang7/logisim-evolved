// AppearancePlacementTests.swift: part of logisim-evolved.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// THE LIGHT/DARK PREFERENCE: where its control lives, that it survives a relaunch, and that it
// reaches the palette the canvas actually draws with.
//
// Written for a report from real use on 2026-09-08; "the light/dark mode toggle should be in a
// settings or smth", which turned out to have a false premise. There is no light/dark control
// in the menu bar, the toolbar or the canvas overlay, and there never was; the only one is the
// radio group in `SettingsWindow.swift`'s Appearance tab. Verified against the shipping build
// by enumerating its live menu bar, not by reading the source: File/Edit/View/Arrange/Circuit/
// Simulate/Window/Help contain nothing of the kind, and Settings ▸ Appearance ▸ Theme does.
//
// 4.1.0 agrees on placement. `AppPreferences.LookAndFeel` is built into `WindowOptions`, the
// Preferences window's Window tab, and appears in **none** of `MenuFile`, `MenuEdit`,
// `MenuProject`, `MenuSimulate`, `LogisimMenuBar`. Measured with `javap -c -p` against
// `/Applications/Logisim-evolution.app/Contents/app/logisim-evolution-4.1.0-all.jar`, NOT
// against this repository's `src/main/java`, which is upstream *main* and not 4.1.0.
//
// So nothing moved, and the value of this file is to keep it that way and to close the loop
// nobody had asserted: preference → persistence → `NSAppearance` → `CircuitPalette`.
//
// ── What is and is not covered ──────────────────────────────────────────────────────────────
//
// COVERED: the value round-trips through `UserDefaults` including the unparseable-string
// fallback; the three cases map to the `ColorScheme` `EditorWindow` applies; the matching
// `NSAppearance` resolves to the light and dark `CircuitPalette`, which is the object the
// canvas draws from; `CanvasDrawsTests.darkModeChangesThePixels` already carries that palette
// the rest of the way to pixels, so the two together are the whole chain.
//
// NOT COVERED, and deliberately stated rather than implied: no test here drives SwiftUI, so
// "the window actually repaints" is not asserted. Nor could it be; `preferredColorScheme` is
// applied in `EditorWindow.swift:47`, which is view code with no headless surface. The
// placement test below is a source scan for the same reason `PreferenceConsumerTests` is one:
// placement is a fact about files, and there is no runtime handle on "is this control in a
// menu".
// ═════════════════════════════════════════════════════════════════════════════════════════════

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import LogisimUI

@Suite("The light/dark preference — its home, its persistence, and the palette it reaches")
@MainActor
struct AppearancePlacementTests {

  // MARK: - Locating the tree
  //
  // From `#filePath`, because `swift test` does not pin the working directory. Same approach as
  // `PreferenceConsumerTests.sourcesRoot`.

  static var sourcesRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // LogisimUITests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // swift
      .appendingPathComponent("Sources")
  }

  /// Every surface a user would call "the main chrome": the menu bar, the window toolbar, and
  /// the controls floating over the canvas. The report was that a theme control sat in one of
  /// these; the assertion is that none does.
  static let chromeFiles = [
    "LogisimUI/App/AppCommands.swift",
    "LogisimUI/Editor/EditorToolbar.swift",
    "LogisimUI/Canvas/CanvasOverlays.swift",
  ]

  static let settingsFile = "LogisimUI/Preferences/SettingsWindow.swift"

  static func read(_ relativePath: String) throws -> String {
    let url = sourcesRoot.appendingPathComponent(relativePath)
    guard let text = try? String(contentsOf: url, encoding: .utf8) else {
      Issue.record("could not read \(url.path) — the scan below would pass vacuously")
      throw CocoaError(.fileNoSuchFile)
    }
    return text
  }

  /// `text.contains(needle)` is not enough on its own: a needle that is a prefix of a longer
  /// identifier would report a hit that is not one. Borrowed from `PreferenceConsumerTests`,
  /// which needs the same guard for the same reason.
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

  /// Every spelling by which a view could reach the appearance preference. `AppearancePreference`
  /// is included because a control could be built over the enum without naming the property.
  static let appearanceNeedles = [
    "preferences.appearance",
    "Preferences.shared.appearance",
    "AppearancePreference",
  ]

  // MARK: - Placement

  /// The report, turned into a gate.
  ///
  /// Note what this does *not* match. `AppCommands.swift` legitimately contains the word
  /// "Appearance" three times, "Revert Custom Appearance", "Edit Appearance" and "Toggle
  /// Layout / Appearance", and all three are about the custom *circuit appearance editor*, a
  /// different feature. Matching on the word would fail on those and be deleted by the next
  /// person as noise, so the needles are the preference's actual spellings.
  @Test("No light/dark control in the menu bar, the toolbar or the canvas overlay")
  func themeControlIsAbsentFromTheChrome() throws {
    for path in Self.chromeFiles {
      let text = try Self.read(path)
      for needle in Self.appearanceNeedles {
        #expect(
          !Self.hasWordBoundedHit(text, needle),
          """
          \(path) reaches the light/dark preference via `\(needle)`. Reported from real use \
          on 2026-09-08: this control belongs in Settings ▸ Appearance ▸ Theme, which already \
          has it. 4.1.0 keeps `AppPreferences.LookAndFeel` out of all five of its menu classes \
          too — see `AppCommands.swift`'s header for that measurement.
          """)
      }
    }
  }

  /// The other half, so the pair cannot pass by the preference having no control at all,
  /// which is the failure mode `PreferenceConsumerTests` exists for, arriving here by a
  /// different route.
  @Test("Settings is where the light/dark control lives")
  func themeControlIsPresentInSettings() throws {
    let text = try Self.read(Self.settingsFile)
    #expect(
      Self.hasWordBoundedHit(text, "$preferences.appearance"),
      """
      \(Self.settingsFile) no longer binds the appearance preference — the only control for \
      light/dark has gone missing rather than moved.
      """)
    #expect(Self.hasWordBoundedHit(text, "AppearancePreference.allCases"))
  }

  // MARK: - Persistence

  /// A relaunch must not lose the choice. `PreferenceConsumerTests` asserts that `save()`
  /// covers the reflected property *set*; nothing asserted that an enum survives the round
  /// trip, and an enum is the case where it can fail: `load()` decodes it through
  /// `AppearancePreference(rawValue:)`, which returns nil for anything it does not know.
  @Test("Every appearance case survives a save and a fresh load")
  func appearanceRoundTripsThroughUserDefaults() throws {
    for value in AppearancePreference.allCases {
      let suiteName = "logisim-evolved.appearance.\(UUID().uuidString)"
      let defaults = try #require(UserDefaults(suiteName: suiteName))
      defer { defaults.removePersistentDomain(forName: suiteName) }

      let writer = EditorPreferences.forTesting(defaults: defaults)
      writer.appearance = value

      // A *second* instance over the same domain; the relaunch. Reading `writer.appearance`
      // back would assert nothing but that a stored property stores.
      let reader = EditorPreferences.forTesting(defaults: defaults)
      #expect(
        reader.appearance == value,
        "appearance \(value.rawValue) did not survive the round trip; got \(reader.appearance)")
    }
  }

  /// A defaults dictionary written by an older or newer build can carry a string this build
  /// does not know. The documented behaviour is to fall back to `.system`, not to crash and not
  /// to silently keep the last value.
  @Test("An unrecognised stored appearance falls back to Match System")
  func unknownAppearanceFallsBackToSystem() throws {
    let suiteName = "logisim-evolved.appearance.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    defaults.set(["appearance": "chartreuse"], forKey: "prefs.v1")
    #expect(EditorPreferences.forTesting(defaults: defaults).appearance == .system)
  }

  // MARK: - Reaching the appearance the canvas uses

  /// What `EditorWindow.swift:47` hands to `preferredColorScheme`. `.system` must be `nil`;
  /// a `ColorScheme` of `.light` would pin the app to light instead of following the system,
  /// which is the one mapping here that is not obvious.
  @Test("The three cases map to the colour scheme the editor window applies")
  func appearanceMapsToColorScheme() {
    #expect(AppearancePreference.system.colorScheme == nil)
    #expect(AppearancePreference.light.colorScheme == .light)
    #expect(AppearancePreference.dark.colorScheme == .dark)
  }

  /// The link the report actually cared about: does choosing Dark reach the thing that draws?
  ///
  /// The canvas never sees an `AppearancePreference`. `CanvasHostNSView` re-resolves
  /// `CircuitPalette.resolved(for:)` from its live `NSAppearance` on every appearance change,
  /// so the preference reaches the pixels through an `NSAppearance` and nothing else.
  /// `CanvasDrawsTests.darkModeChangesThePixels` carries `.light` vs `.dark` the rest of the
  /// way to a raster; this asserts the half above it, which nothing did.
  ///
  /// `.system` is `nil` on purpose and is asserted as such: there is no fixed appearance to
  /// resolve, because the answer is whatever the window is currently showing.
  @Test("Light and Dark resolve to the two palettes the canvas draws from")
  func appearanceReachesTheCanvasPalette() throws {
    #expect(AppearancePreference.system.nsAppearance == nil)

    let lightAppearance = try #require(AppearancePreference.light.nsAppearance)
    let darkAppearance = try #require(AppearancePreference.dark.nsAppearance)

    let light = CircuitPalette.resolved(for: lightAppearance)
    let dark = CircuitPalette.resolved(for: darkAppearance)

    #expect(light.isDark == false)
    #expect(dark.isDark == true)
    // Not redundant with `isDark`: a palette could carry the flag and still hand out identical
    // colours, which is upstream #2661 exactly: `Value.java` freezes its colours into statics
    // at class-init so both appearances render the same.
    #expect(light != dark)
    #expect(light[ChromeRole.canvasBackground] != dark[ChromeRole.canvasBackground])
  }
}
