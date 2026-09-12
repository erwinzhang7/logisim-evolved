# Settings consumer audit — 2026-09-09

**Not clean.** The initial 20 stored preferences included two entirely inert controls
(`defaultTickFrequency`, `autoPropagateByDefault`), one dead template field
(`showsTickMarkers`), and one partially implemented promise (`showsValueColours`).
The gate-shape picker also offered an unsupported DIN option. No other preference was
found wholly inert in the inspected layout/document paths. Source reachability is not
an interactive verification; the distinctions below are intentional.

Verified branch `trap-audit` and `swift/Package.swift`. No upstream repository Java
source was read. No app was built/launched, no screenshots or input events were used.

## Evidence convention

Every upstream citation below refers to **J410**, the artifact
`/Applications/Logisim-evolution.app/Contents/app/logisim-evolution-4.1.0-all.jar`,
inspected with `/opt/homebrew/opt/openjdk@21/bin/javap -c -p -classpath <J410>`.
Class names below omit the common `com.cburch.logisim.` prefix. These are bytecode
citations, not line numbers from the repository's unrelated upstream-main sources.

`prefs.AppPreferences` was inspected in full, including its static initializer.
`gui.prefs.PreferencesFrame`, `LayoutOptions`, `SimOptions`, `WindowOptions`,
`ExperimentalOptions`, `AutosaveOptions`, `IntlOptions`, `TemplateOptions`, and
`HotkeyOptions` were also inspected. “No” means no corresponding persisted
AppPreferences setting or inspected Settings control, not that Java lacks the
underlying operation. In particular a runtime simulation command is not a launch default.

Swift paths in the table are relative to `swift/Sources/LogisimUI/`; `Std/` means
`swift/Sources/LogisimStd/`. Settings line numbers describe the final control layout.
All values are persisted by `EditorPreferences.save()` and loaded/reset by that model.
The application installs the real Settings scene in `App/LogisimEvolvedApp.swift:76`.

## Every stored preference

| Preference | Written by Settings | Production read and reachability | In 4.1.0? (artifact J410) | Does changing it change behavior? |
|---|---|---|---|---|
| `appearance` | Appearance picker, `SettingsWindow.swift:118` | `Editor/EditorWindow.swift:47` sets document colour scheme; `Canvas/CanvasHostNSView.swift:168` resolves effective appearance into the render palette | Analogue: `AppPreferences.LookAndFeel`, `WindowOptions` constructor | **Live, source-traced.** Document chrome/canvas; Settings and auxiliary windows do not receive this override. Not globally applied. |
| `gateShape` | Gate shape picker, :136 | Template → `Canvas/CircuitSceneSource.swift:274` → `Std/Instance/CircuitRenderer.swift` → gate painters | Yes: `AppPreferences.GATE_SHAPE`, `IntlOptions` constructor; exactly shaped and rectangular | **Live, tested** shaped vs rectangular yields different scene primitives. **DIN option unsupported**; simple AND produces shaped geometry. Removed DIN from Settings. |
| `showGrid` | Show grid toggle, :153; also menu/canvas toggles | Template → `Canvas/CircuitSceneView.swift:189` conditionally calls grid drawing | Yes: `AppPreferences.LAYOUT_SHOW_GRID` (also independent `APPEARANCE_SHOW_GRID`); persisted canvas state, not necessarily a Preferences tab control | **Live, source-traced** in layout canvas. |
| `gridSpacing` | Spacing picker, :155 | Template → `Canvas/CircuitSceneView.swift:245`, grid dot iteration and density cutoff | No adjustable spacing monitor in `AppPreferences`; grid display/colour/zoom monitors are different settings | **Live, source-traced:** changes displayed dot spacing, not the tools' fixed placement grid. Retain; display-only spacing can mislead and should be labeled accordingly. |
| `antialiasing` | Antialias toggle, :166 | Template → `Canvas/CircuitSceneView.swift:200` and :224 → renderer options; export surface also reads it | Yes: `AppPreferences.AntiAliassing`, `LayoutOptions` constructor | **Live, source-traced:** drawing/text antialias options change. Pixel comparison not run. |
| `showsValueColours` | Colour wires by simulated value, :167; also menu | Template → `Canvas/CircuitSceneSource.swift:272` → `StaticPaintContext.shouldDrawColor` → component painters. Wire renderer ignores it | No matching boolean in `AppPreferences`. Analogue behavior: `comp.ComponentDrawContext.shouldDrawColor/getShowState`; `SimOptions` exposes value-colour choices, not this wire toggle | **Partial/latent for its advertised purpose. Tested:** a Constant's drawing changes, but wire scene primitives AND palette do not. Canvas `showState` is fixed false; simulated wire coloring is unwired. **Wire**, report-only. |
| `showsTickMarkers` | Former “Show clock tick markers”; control removed | Before: template → `CanvasAppearance` storage only. No downstream field reader. Now retired stored value, no template forwarding | No clock-marker monitor/control in `AppPreferences`/inspected panels. `SHOW_TICK_RATE` is the rate display, not markers | **Inert, demonstrated by the new failing-before gate. Remove:** clear port invention. Control and forwarding removed; stored-key cleanup deferred below. |
| `showsAttentionHalo` | Highlight inspected component, :168 | Template → `Canvas/CircuitSceneView.swift:304`; selection supplies halo ID at `Project/LogisimFileProjectHost.swift:923` | Yes: `AppPreferences.ATTRIBUTE_HALO`, `LayoutOptions` constructor | **Live, source-traced:** selected component halo suppressed/enabled. Multiple selection chooses `Set.first`, so wording “inspected” is imprecise. |
| `zoomBehaviour` | Zoom picker, :172 | `CanvasHostView.Coordinator:55` → `CanvasHostNSView.swift:429` chooses pointer world point vs viewport centre | No anchor-choice monitor in `AppPreferences`; zoom level persistence is not an anchor preference | **Live, source-traced:** changes wheel/pinch zoom anchor. No synthetic gestures used. |
| `scrollPans` | Two-finger scroll pans, :177 | Coordinator :56 → `CanvasHostNSView.swift:404` gates pan | No corresponding monitor in `AppPreferences` | **Live, source-traced**, but OFF discards unmodified scrolling; it does not vertically scroll as the old model comment claimed. Corrected that comment. |
| `invertScrollDirection` | Invert scroll direction, :178 | Coordinator :57 → `CanvasHostNSView.swift:394` negates deltas | No corresponding monitor in `AppPreferences` | **Live, source-traced:** reverses pan and modifier-scroll zoom; does not reverse pinch. |
| `panSensitivity` | Pan speed slider, :180 | Coordinator :58 → `CanvasHostNSView.swift:407` multiplies pan deltas | No corresponding monitor in `AppPreferences` | **Live, source-traced** for scrolling with panning enabled; not space/middle-button drag speed. |
| `zoomSensitivity` | Zoom speed slider, :183 | Coordinator :59 → `CanvasHostNSView.swift:400` and :412 | No corresponding monitor in `AppPreferences` | **Live, source-traced:** changes wheel exponent and pinch factor. |
| `defaultTickFrequency` | Default rate picker, :206 | No production preference reader; `Project/SimulationEngine.swift:182` falls back to literal 1 | Yes: `AppPreferences.TICK_FREQUENCY`; `circuit.Simulator.<init>` bytecodes 96–110 read/get/setTickFrequency; `gui.main.Frame.savePreferences` writes it | **Inert, tested:** setting 1 then 64 produces the same fresh-engine rate. **Wire**, outside ownership; retain upstream-backed control. |
| `showsSimulationDiagnostics` | Show measured rate and jitter, :214 | `Canvas/CanvasOverlays.swift:113` wraps visible status HUD | Analogue: `AppPreferences.SHOW_TICK_RATE`, `WindowOptions` constructor (bytecode 64); port adds jitter/status | **Live, source-traced:** toggles the HUD, including pointer coordinates as well as rate/status. |
| `autoPropagateByDefault` | Former “Propagate automatically”; control removed | No production preference reader. Engine snapshot defaults true | No persisted default: `circuit.Simulator$SimThread.<init>` bytecodes 38–40 load true/store `autoPropagating`. `HOTKEY_SIM_AUTO_PROPAGATE` is a command key, not this preference | **Inert. Remove:** port-invented default. Control removed; runtime simulation propagation command unaffected. Stored-key cleanup deferred below. |
| `autosaveEnabled` | Save automatically, :58 | `App/CircuitDocument.swift:122` supplies closure → `Document/AutosaveController.tick`; started by `App/LogisimEvolvedApp.swift:145` | Yes: `AppPreferences.AUTOSAVE_ENABLED`, `AutosaveOptions` constructor | **Live, tested:** false returns disabled/no write; true writes expected sidecar bytes. Production closure hookup separately source-traced. |
| `autosaveIntervalSeconds` | Interval picker, :61 (visible when enabled) | `CircuitDocument.swift:123` → `AutosaveController.swift:214`/`:224` → task sleep | Yes: `AppPreferences.AUTOSAVE_INTERVAL`, `AutosaveOptions` | **Live, source-traced:** changes next scheduled sleep; a currently sleeping task is not rescheduled. No timed sleep test. |
| `showsUnavailableTools` | Show unavailable tools, :87 | `Editor/EditorModel.swift:312` filters `filteredLibraries`, used by Explorer | No corresponding monitor/control in `AppPreferences`/inspected panels | **Live, source-traced** with an empty search. **Partial:** nonempty search bypasses this filter (:320 onward), so unavailable tools reappear. Missing-library placeholders are reachable when opening such documents; not gated on porting JAR execution. |
| `expandsLibrariesByDefault` | Expand libraries by default, :91 | `Sidebar/ExplorerSidebar.swift:307`, disclosure row `.onAppear` | No corresponding expansion monitor in `AppPreferences` | **Live, source-traced** when rows next appear. It intentionally does not change already-visible disclosure state; search also forces expansion. |

“Reset All Settings…” (`SettingsWindow.swift:249`) directly calls `resetAll`, which
restores/persists the reflected values. The existing persistence test executes that
path. Advanced's three unsupported-feature rows are static labels, not controls.

## Implemented and deferred work

Removed only clearly unsupported port inventions: the automatic-propagation default
control, clock-marker control, and DIN picker entry. The jar's `AppPreferences`
static initializer constructs `gateShape` with a two-element shaped/rectangular
array (bytecodes 79–111); `IntlOptions` likewise constructs exactly two choices
(bytecodes 31–86). `std.gates.AbstractGate.paintBase` dispatches rectangular or shaped,
not DIN. Loading an old persisted DIN value now normalizes it to shaped, tested while
preserving an unrelated setting.

**Storage cleanup deferred to the existing-test owner:** this task permits only NEW
files under Tests. `PreferenceConsumerTests.swift:125` requires at least 20 reflected
preferences. Deleting the two retired properties would necessarily fail that existing
test. They remain persisted/resettable legacy storage, explicitly pending deletion,
with no user controls. Their exact declarations are `EditorPreferences.swift:192`
and `:213`; remove corresponding save/load/reset entries when relaxing that floor.
No authorization to edit the existing test was received during this audit.

The upstream-backed default-rate fix is report-only:
`Project/LogisimFileProjectHost.swift:619` constructs `SimulationEngine(file:)`;
read the preference on the main actor there and pass a default into
`Project/SimulationEngine.swift:178`, replacing only the fallback at :182. Preserve
positive circuit-specific frequency precedence. Add a test setting the preference
through the production caller and asserting the fresh project rate; remove the
pending entry and this audit's inert characterization when wired.

The wire-colour fix is report-only:
`Canvas/CircuitSceneSource.swift:271` supplies `showState: false` to a static context;
`Std/Instance/CircuitRenderer.swift:88` gives all wires `context.componentColor`.
A real fix needs a safe simulation snapshot/state-value projection to the drawing
path and state-driven repainting, not merely changing the boolean or adding a reader.
`Project/LogisimFileProjectHost.swift:1105` currently publishes simulation status.
Keep the preference pending a behavior decision; it already changes some components,
so deleting it would discard real behavior. The advertised wire behavior remains latent.

Other report-only improvements: apply appearance to auxiliary windows (document-only
application at `EditorWindow.swift:47`), honor unavailable-tool filtering during search
(`EditorModel.swift:320`), and clarify display grid spacing vs fixed tool snapping.

## Exemption-list verdict and tests

Before changes, `preferencesPendingWiring` correctly identified both direct-reader
absences. Its equality check really does reject an entry that gains a reader.
However, the scanner counts comments/string literals as readers; the documentation
also overstates its protection against growth, because adding BOTH an inert property
and an exemption passes. Finally `PreferenceConsumerTests.swift:299` requires the
list to be nonempty: it cannot liquidate its final entry without modifying that test.
These existing-test lines are report-only.

The template list was **not sound**: it redirected seven fields, including
`showsTickMarkers`, while the code comments said six. Checking only that the entire
template is consumed let the dead field pass. Removed that redirection and listed
its retained legacy storage honestly as unconsumed. The list now contains six actual
forwarded fields. `showsValueColours` demonstrates that a downstream read STILL
cannot establish that the behavior promised by the label works.

New `PreferenceDownstreamAuditTests.swift` adds:

- Dynamic preference-to-binding coverage, allowing only the two explicitly retired controls.
- Missing-reader equality after stripping comments/literals; a bounded set of allowed
  pending names, so adding arbitrary exemptions cannot silently pass.
- Per-template-field readers beyond Preferences and the render-seam declarations.
- Scanner fixtures rejecting comments, strings, and longer property-name prefixes.
- Preference-to-output tests for autosave sidecar bytes, gate scene primitives,
  and a Constant's color output; characterizations of inert default rate and unchanged
  wire scene/palette; migration of persisted DIN selection.

Source scanning remains conservative and is not a Swift parser: it does not prove
reachability, follow arbitrary aliases, or fully parse nested comments/raw literals.
No claim that this statically proves every future UI control is correct.

The original seven consumer tests passed before the fix while the new downstream
check failed specifically for `showsTickMarkers`. After the fix the focused suites
pass (17 tests). Test compilation used an in-worktree scratch copy of Sources and a
copy of Package.swift with both executable products/targets removed. Tests were
symlinked from the owned test tree. The app and CLI were not built. Command:

```sh
CLANG_MODULE_CACHE_PATH="$PWD/preference-audit/module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/preference-audit/module-cache" \
swift test --package-path preference-audit/test-package --disable-sandbox \
  --filter 'Preference(Consumer|DownstreamAudit)Tests'
```

Scratch disassembly and red/green logs remain under `preference-audit/` (uncommitted).
An initial harness attempt used a symlinked Sources root, which Foundation's source
enumerator did not traverse; replacing it with a real scratch copy fixed those
harness failures. Module caches were redirected into the worktree after the default
cache path was denied by the sandbox.

Scope not reached: interactive observation/repaint delivery, pixel-level comparison,
all component families under every drawing option, timed autosave rescheduling,
and exhaustive independent behavior tests for navigation, diagnostics, and Explorer.
Those rows are source-traced, not called runtime-verified. No screenshots, synthetic
clicks/gestures, app launch, or unrelated full-suite runs were used.
