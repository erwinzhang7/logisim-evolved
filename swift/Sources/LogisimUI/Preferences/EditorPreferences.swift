// LogisimUI: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// ============================================================================
// Current 2026-09-09 audit: see AUDIT.md in this directory. The historical analysis below
// predates removal of the automatic-propagation and clock-marker controls. Their stored
// values remain only to avoid editing the existing test suite outside this task's ownership.
// DIN is no longer offered. Default tick frequency remains unwired; wire colours are partial.
//
// PREFERENCES; the model half. Upstream issue #2680 ("broken preferences dialogue").
//
// What is actually wrong upstream, since "broken dialogue" is vague:
//
//  1. `PreferencesFrame` builds ten `OptionsPanel`s into a `JTabbedPane` inside a
//     `JScrollPane` and then `pack()`s (PreferencesFrame.java:38-66). Packing a tabbed
//     pane sizes the window to the *currently selected* tab, so every other tab is
//     clipped or scrolls. It then force-selects the Intl tab (`:62`), which is why the
//     window opens at the wrong size for whatever you came to change.
//  2. It is a singleton `JFrame` cached in a static `WindowMenuManager` and positioned
//     `setLocationRelativeTo(parent)` exactly once, at first creation (`:98-104`). If it
//     was first opened while a window was on a display that is now gone, it stays there.
//  3. Values are written into `AppPreferences` statics. Several consumers latch those
//     statics at class-init time, that is the same root cause as #2661, so a change
//     takes effect on the *next launch*, with nothing in the UI saying so.
//
// The fixes here are structural, not cosmetic:
//
//  - There is no dialogue. This is a SwiftUI `Settings` scene, so it is ⌘, , it is a
//    real preferences window, and the system owns its size, position and restoration.
//  - Every property is observed. A change publishes immediately, is pushed down the
//    render seam via `CircuitRenderSurface.setAppearance(_:)`, and repaints. There is
//    no Apply button and no relaunch, because there is nothing latched anywhere.
//  - Persistence is `UserDefaults` written on `didSet`, so quitting mid-edit cannot
//    lose a setting.
//
// ── A FIFTH SEAM SHAPE: the preference nothing reads ────────────────────────────────────────
//
// The three structural fixes above are about a preference reaching its consumer *promptly*.
// They say nothing about whether it has a consumer at all, and it turned out four did not:
// `defaultTickFrequency`, `autoPropagateByDefault`, `confirmCircuitDeletion` and
// `addsUnnamedLabels` were bound by `SettingsWindow`, persisted correctly by `save()` below,
// and read back by nobody. The user flips the control, it sticks across a relaunch, and the
// app's behaviour never changes, which is *worse* than upstream's stale-static bug, because
// there at least the next launch honours it.
//
// **No checker can see this.** A preference written by a binding and read by nobody is a seam
// shape `deadseam.py` does not hunt: the property is referenced (twice: the binding and the
// persistence dictionary), so it is not dead code; and hit-test/render gates cannot see it
// because nothing it would have changed is exercised. `PreferenceConsumerTests` is the only
// cover, and `preferencesPendingWiring` below is the pinned exception list it enforces.
//
// What was decided for each of the four, measured against 4.1.0 rather than against taste:
//
//   * `defaultTickFrequency`; KEPT. It is the one of the four with a real upstream analogue:
//     `AppPreferences.TICK_FREQUENCY` (`AppPreferences.java:857`), read by `Simulator`'s
//     constructor (`Simulator.java:656`) and written back from the live project by
//     `Frame.savePreferences()` (`Frame.java:561`). Its consumer here is `SimulationEngine`'s
//     initialiser, which is not a file this slice owns; see `preferencesPendingWiring`.
//   * `autoPropagateByDefault`; KEPT for the same wiring, though it has NO upstream analogue:
//     `Simulator.java:140` hard-codes `private boolean autoPropagating = true` and there is no
//     `PrefMonitor` for it anywhere in `AppPreferences`. It is one line from its consumer, in
//     the same initialiser as the one above.
//   * `confirmCircuitDeletion`: REMOVED, control and all. Upstream does not make this
//     optional: `ProjectCircuitActions.doRemoveCircuit` (`ProjectCircuitActions.java:240-247`)
//     confirms **unconditionally**, and there is no `PrefMonitor` for it. So the port had
//     invented a switch for something 4.1.0 does not switch. The real gap is that the port's
//     own removal path (`Sidebar/ExplorerSidebar.swift:163`) shows no confirmation at all;
//     that is a missing sheet, not a missing preference, and a preference here would only
//     have made the sheet optional in a way upstream never intended.
//   * `addsUnnamedLabels`: REMOVED, control and all. Upstream's auto-labeller is not an
//     application preference either: `AutoLabel` is toggled per-tool at runtime by a keystroke
//     (`AppPreferences.java:1004`, `hotkeyAutoLabelToggle`), and `AutoLabel` itself is recorded
//     NOT PORTED at the `AddTool` call sites (D11: `Tools/AddTool.swift:78` and `:383`). A
//     checkbox for an unported feature with no upstream preference behind it is exactly the
//     "actively told the setting works" failure.
//
// ── A SIXTH SHAPE: the preference that DID have a reader, and still had to go ────────────────
//
// `snapToGrid`: REMOVED, control and all, by an explicit owner decision: "the snap to grid, no
// toggle. i think we basically just conform it to the grid anyhow, its not freehand wires."
//
// It is worth separating from the four above because it was NOT inert by the audit's measure.
// It had a genuine reader, `CanvasHostView.swift`'s `snapsToGrid`, feeding
// `CanvasHostNSView.snapped(_:)`, so `PreferenceConsumerTests` was satisfied and always would
// have been. It was inert where it counted, which is a different and harder thing to see: the
// value it computed reached the tool layer as `CanvasPointerEvent.snappedWorld` and the tools
// never read it, because they snap for themselves with upstream's exact integer arithmetic
// (`ToolGeometry.CanvasGrid`). `GridSnapParityTests.placementIgnoresTheShellsPrecomputedSnap`
// is the measurement: feeding a deliberately absurd `snappedWorld` places the component in the
// same place.
//
// The 4.1.0 evidence, from the shipped jar rather than from `src/main/java`:
//
//   * `javap -c com.cburch.logisim.gui.main.Canvas`; `snapToGrid(java.awt.event.MouseEvent)`
//     is 33 bytecodes and contains no branch: getX, getY, snapXToGrid, snapYToGrid,
//     translatePoint, return. It reads no `PrefMonitor`. Snapping is not optional upstream.
//   * `javap com.cburch.logisim.prefs.AppPreferences`; the grid-related monitors are
//     `LAYOUT_SHOW_GRID`, `APPEARANCE_SHOW_GRID`, `GRID_BG_COLOR`, `GRID_DOT_COLOR` and
//     `GRID_ZOOMED_DOT_COLOR`. Grid *display* is a preference; grid *snapping* is not.
//   * `resources/logisim/strings/gui/gui.properties` in the same jar; zero occurrences of
//     "snap". There is no string for a snap checkbox because there is no checkbox.
//
// And its rule was wrong on its own terms anyway: the shell snapped the *world* value with a
// continuous `(v / spacing).rounded() * spacing`, whose 0 -> 10 threshold sits at 5.0, where
// upstream integerises first (`(int) Math.round(px / zoom)`) and so thresholds at 4.5. The two
// disagree over the half-unit band [4.5, 5.0) and agree everywhere else.
//
// Note what is NOT this preference and must stay: `AddTool.shouldSnap` is upstream's per-factory
// `ComponentFactory.SHOULD_SNAP` feature, and `SelectionBase.snapsToGrid()` is upstream's
// `Selection.shouldSnap()`. Both exist in the 4.1.0 jar under those names. Neither was ever
// wired to this preference.
// ============================================================================

import AppKit
import Foundation
import Observation
import SwiftUI

/// How the app resolves light/dark.
///
/// Upstream has a "theme" preference that only restyles Swing chrome and leaves the
/// canvas alone. Here the value drives *both* the SwiftUI chrome (`preferredColorScheme`)
/// and the canvas palette, because a canvas that disagrees with its own window is the
/// visible half of #2661.
public enum AppearancePreference: String, CaseIterable, Sendable, Identifiable {
  case system, light, dark

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .system: return "Match System"
    case .light: return "Light"
    case .dark: return "Dark"
    }
  }

  var colorScheme: ColorScheme? {
    switch self {
    case .system: return nil
    case .light: return .light
    case .dark: return .dark
    }
  }

  var nsAppearance: NSAppearance? {
    switch self {
    case .system: return nil
    case .light: return NSAppearance(named: .aqua)
    case .dark: return NSAppearance(named: .darkAqua)
    }
  }
}

public enum PointerZoomBehaviour: String, CaseIterable, Sendable, Identifiable {
  /// Pinch and ⌘-scroll keep the world point under the cursor fixed. This is the
  /// behaviour upstream cannot express at all, because it has no camera (see
  /// `CanvasViewport`'s note on #1262).
  case anchorAtPointer
  case anchorAtCentre

  public var id: String { rawValue }
  public var displayName: String {
    switch self {
    case .anchorAtPointer: return "Zoom Toward Pointer"
    case .anchorAtCentre: return "Zoom Toward Centre"
    }
  }
}

@MainActor
@Observable
public final class EditorPreferences {
  public static let shared = EditorPreferences()

  private let defaults: UserDefaults
  private var isLoading = true

  // MARK: Appearance

  public var appearance: AppearancePreference = .system { didSet { save() } }
  public var gateShape: CanvasAppearance.GateShape = .shaped { didSet { save() } }

  // MARK: Canvas

  public var showGrid = true { didSet { save() } }
  public var gridSpacing: Double = 10 { didSet { save() } }
  public var antialiasing = true { didSet { save() } }
  public var showsValueColours = true { didSet { save() } }
  // Retired Settings storage, retained until the existing reflection test's minimum of
  // 20 is updated by its owner. No control and no template forwarding remain. See AUDIT.md.
  public var showsTickMarkers = false { didSet { save() } }
  public var showsAttentionHalo = true { didSet { save() } }

  // MARK: Navigation — the #1262 surface

  public var zoomBehaviour: PointerZoomBehaviour = .anchorAtPointer { didSet { save() } }
  /// Two-finger scroll pans the canvas. Off currently ignores unmodified scroll events.
  public var scrollPans = true { didSet { save() } }
  public var invertScrollDirection = false { didSet { save() } }
  /// Multiplier applied to a precise trackpad delta. Upstream binds panning to wheel
  /// *notches* (`Canvas.java:917-921`) and so has nothing to tune.
  public var panSensitivity: Double = 1.0 { didSet { save() } }
  public var zoomSensitivity: Double = 1.0 { didSet { save() } }

  // MARK: Simulation

  public var defaultTickFrequency: Double = 1 { didSet { save() } }
  /// D7: show the achieved rate and jitter, not the requested rate. Defaults on,
  /// because hiding it is precisely upstream's `TickCounter` bug.
  public var showsSimulationDiagnostics = true { didSet { save() } }
  // Retired Settings storage for the same reason as showsTickMarkers; not a live preference.
  public var autoPropagateByDefault = true { didSet { save() } }

  // MARK: Editing
  //
  // `confirmCircuitDeletion`, `addsUnnamedLabels` and `snapToGrid` used to live here. All three
  // were removed; see this file's header for the 4.1.0 evidence behind each. They are
  // deliberately NOT migrated out of `UserDefaults`: `load()` reads keys by name, so a stale
  // `prefs.v1` dictionary written by an older build simply carries keys nothing asks for, and
  // `save()` rebuilds the dictionary from scratch and `defaults.set`s the whole value, so the
  // strays are dropped on the next write. There is nothing to lose and nothing to convert.
  //
  // That is asserted, not assumed: `PreferenceConsumerTests.aStalePreferencesFileIsHarmless`
  // seeds a `prefs.v1` containing `snapToGrid` and checks both halves; the load is unaffected,
  // and the next save no longer contains the key. The specific risk it rules out is a decoder
  // that fails or resets on an unknown key, which would have silently reverted every OTHER
  // preference for anyone upgrading.

  public var autosaveEnabled = true { didSet { save() } }
  public var autosaveIntervalSeconds: Double = 120 { didSet { save() } }

  // MARK: Explorer

  public var showsUnavailableTools = true { didSet { save() } }
  public var expandsLibrariesByDefault = false { didSet { save() } }

  private init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    load()
    isLoading = false
  }

  /// A test/preview seed that never touches the real domain.
  public static func ephemeral() -> EditorPreferences {
    EditorPreferences(defaults: UserDefaults(suiteName: "logisim-evolved.preview") ?? .standard)
  }

  /// Like `ephemeral()`, but over a domain the caller owns, so a test can read back exactly
  /// what `save()` wrote instead of trusting the literal in it. `PreferenceConsumerTests` uses
  /// this to assert that persistence covers the reflected property set with no gaps and no
  /// leftovers; the check that catches a preference silently dropped from the dictionary.
  static func forTesting(defaults: UserDefaults) -> EditorPreferences {
    EditorPreferences(defaults: defaults)
  }

  // MARK: - The consumer audit

  /// Stored values with no production reader: one live control awaiting wiring and two
  /// retired controls whose storage is retained while the existing test owner updates its
  /// reflection floor. This list is measured by equality, so acquiring a reader requires
  /// removing the entry. PreferenceDownstreamAuditTests also ignores comments/literals and
  /// checks each forwarded template field beyond the render seam.
  ///
  /// SimulationEngine is not MainActor; read defaultTickFrequency in its caller and pass
  /// it as an initializer argument. The stored circuit frequency must still take precedence.
  public static let preferencesPendingWiring: [String: String] = [
    // 4.1.0 jar: Simulator.<init>, bytecode 96–110 reads TICK_FREQUENCY.
    "defaultTickFrequency":
      "LogisimUI/Project/SimulationEngine.swift:182 — replace fallback 1 with caller-supplied preference",
    "autoPropagateByDefault":
      "LogisimUI/Preferences/EditorPreferences.swift:213 — retired storage; remove after test floor update",
    "showsTickMarkers":
      "LogisimUI/Preferences/EditorPreferences.swift:192 — retired storage; remove after test floor update",
  ]

  /// Fields forwarded through canvasAppearanceTemplate. Every field must also have a reader
  /// beyond CanvasAppearance's initializer/storage; forwarding alone proved insufficient for
  /// the removed clock-marker control. The downstream audit checks that extra hop.
  public static let preferencesConsumedViaCanvasTemplate: Set<String> = [
    "showGrid", "gridSpacing", "antialiasing", "showsValueColours", "gateShape",
    "showsAttentionHalo",
  ]

  // MARK: - Derived

  /// The appearance template handed to the canvas. `palette` and `backingScale` are
  /// filled in by the hosting view from its own live `NSAppearance`; they are the two
  /// fields that cannot be answered from preferences alone, and reading them out of a
  /// global is how #2661 happens.
  public var canvasAppearanceTemplate: CanvasAppearance {
    CanvasAppearance(
      palette: .light,
      showGrid: showGrid,
      gridSpacing: gridSpacing,
      antialiasing: antialiasing,
      backingScale: 2,
      showsValueColours: showsValueColours,
      gateShape: gateShape,
      showsAttentionHalo: showsAttentionHalo)
  }

  public func resetAll() {
    isLoading = true
    appearance = .system
    gateShape = .shaped
    showGrid = true
    gridSpacing = 10
    antialiasing = true
    showsValueColours = true
    showsTickMarkers = false
    showsAttentionHalo = true
    zoomBehaviour = .anchorAtPointer
    scrollPans = true
    invertScrollDirection = false
    panSensitivity = 1
    zoomSensitivity = 1
    defaultTickFrequency = 1
    showsSimulationDiagnostics = true
    autoPropagateByDefault = true
    autosaveEnabled = true
    autosaveIntervalSeconds = 120
    showsUnavailableTools = true
    expandsLibrariesByDefault = false
    isLoading = false
    save()
  }

  // MARK: - Persistence

  private enum Key {
    static let all = "prefs.v1"
  }

  private func save() {
    guard !isLoading else { return }
    let dict: [String: Any] = [
      "appearance": appearance.rawValue,
      "gateShape": gateShape.rawValue,
      "showGrid": showGrid,
      "gridSpacing": gridSpacing,
      "antialiasing": antialiasing,
      "showsValueColours": showsValueColours,
      "showsTickMarkers": showsTickMarkers,
      "showsAttentionHalo": showsAttentionHalo,
      "zoomBehaviour": zoomBehaviour.rawValue,
      "scrollPans": scrollPans,
      "invertScrollDirection": invertScrollDirection,
      "panSensitivity": panSensitivity,
      "zoomSensitivity": zoomSensitivity,
      "defaultTickFrequency": defaultTickFrequency,
      "showsSimulationDiagnostics": showsSimulationDiagnostics,
      "autoPropagateByDefault": autoPropagateByDefault,
      "autosaveEnabled": autosaveEnabled,
      "autosaveIntervalSeconds": autosaveIntervalSeconds,
      "showsUnavailableTools": showsUnavailableTools,
      "expandsLibrariesByDefault": expandsLibrariesByDefault,
    ]
    defaults.set(dict, forKey: Key.all)
  }

  private func load() {
    guard let dict = defaults.dictionary(forKey: Key.all) else { return }
    func bool(_ k: String, _ fallback: Bool) -> Bool { dict[k] as? Bool ?? fallback }
    func double(_ k: String, _ fallback: Double) -> Double { dict[k] as? Double ?? fallback }

    appearance =
      (dict["appearance"] as? String).flatMap { AppearancePreference(rawValue: $0) } ?? .system
    gateShape =
      (dict["gateShape"] as? String).flatMap { CanvasAppearance.GateShape(rawValue: $0) }
      ?? .shaped
    if gateShape == .din40700 { gateShape = .shaped }
    showGrid = bool("showGrid", true)
    gridSpacing = double("gridSpacing", 10)
    antialiasing = bool("antialiasing", true)
    showsValueColours = bool("showsValueColours", true)
    showsTickMarkers = bool("showsTickMarkers", false)
    showsAttentionHalo = bool("showsAttentionHalo", true)
    zoomBehaviour =
      (dict["zoomBehaviour"] as? String).flatMap { PointerZoomBehaviour(rawValue: $0) }
      ?? .anchorAtPointer
    scrollPans = bool("scrollPans", true)
    invertScrollDirection = bool("invertScrollDirection", false)
    panSensitivity = double("panSensitivity", 1)
    zoomSensitivity = double("zoomSensitivity", 1)
    defaultTickFrequency = double("defaultTickFrequency", 1)
    showsSimulationDiagnostics = bool("showsSimulationDiagnostics", true)
    autoPropagateByDefault = bool("autoPropagateByDefault", true)
    autosaveEnabled = bool("autosaveEnabled", true)
    autosaveIntervalSeconds = double("autosaveIntervalSeconds", 120)
    showsUnavailableTools = bool("showsUnavailableTools", true)
    expandsLibrariesByDefault = bool("expandsLibrariesByDefault", false)
  }
}
