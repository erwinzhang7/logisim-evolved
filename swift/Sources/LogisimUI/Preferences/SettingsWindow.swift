// LogisimUI: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// ============================================================================
// PREFERENCES: the view half. See `EditorPreferences.swift` for the analysis of #2680.
//
// Structural differences from upstream's `PreferencesFrame`:
//
//   - It is a `Settings` scene, so it is ⌘,, it lives in the application menu, the system
//     restores its size and position per-tab, and it cannot end up stranded on a display
//     that no longer exists. Upstream caches one `JFrame` in a static and positions it
//     once, at first creation, forever.
//   - Each pane sizes itself. Upstream `pack()`s a `JTabbedPane` around whichever tab
//     happens to be selected, so every other tab is clipped or scrolls.
//   - Changes apply instantly and are observed all the way to the canvas. There is no
//     Apply button because there is nothing latched to apply.
//   - Ten upstream tabs collapse to five. Template, Intl, Window, Layout, Sim,
//     Experimental, Softwares, FPGA, Hotkeys and Autosave were ten tabs because each was
//     a class; several are single checkboxes. Localisation is gone entirely; it is a
//     system setting on macOS, not an app setting. The FPGA and Softwares panes configure
//     vendor toolchains that have never shipped for macOS (D11), so they are not here.
// ============================================================================

import SwiftUI

struct SettingsWindow: View {
  @Bindable var preferences: EditorPreferences

  var body: some View {
    TabView {
      Tab("General", systemImage: "gearshape") {
        GeneralPane(preferences: preferences)
      }
      Tab("Appearance", systemImage: "paintpalette") {
        AppearancePane(preferences: preferences)
      }
      Tab("Canvas", systemImage: "square.grid.3x3") {
        CanvasPane_Settings(preferences: preferences)
      }
      Tab("Simulation", systemImage: "waveform.path.ecg") {
        SimulationPane(preferences: preferences)
      }
      Tab("Advanced", systemImage: "wrench.and.screwdriver") {
        AdvancedPane(preferences: preferences)
      }
    }
    .frame(width: 520)
    .scenePadding()
  }
}

private struct GeneralPane: View {
  @Bindable var preferences: EditorPreferences

  var body: some View {
    Form {
      Section("Documents") {
        Toggle("Save automatically", isOn: $preferences.autosaveEnabled)
        if preferences.autosaveEnabled {
          LabeledContent("Interval") {
            Picker("", selection: $preferences.autosaveIntervalSeconds) {
              Text("30 seconds").tag(30.0)
              Text("1 minute").tag(60.0)
              Text("2 minutes").tag(120.0)
              Text("5 minutes").tag(300.0)
            }
            .labelsHidden()
            .fixedSize()
          }
        }
      }

      // The whole "Editing" section is gone, and with it three toggles: "Confirm before removing
      // a circuit", "Give new components a label automatically" and "Snap to the grid". None had
      // a reader that changed anything, and none corresponds to a preference 4.1.0 has:
      // upstream confirms circuit removal unconditionally, toggles the auto-labeller per-tool
      // from a keystroke, and snaps to the grid unconditionally (`Canvas.snapToGrid(MouseEvent)`
      // in the 4.1.0 jar is a straight line of bytecode with no branch and no `PrefMonitor`
      // read). `EditorPreferences.swift`'s header carries the evidence for each.
      //
      // All three were removed rather than wired because a control that persists and changes
      // nothing tells the user it works. "Snap to the grid" was the worst of the three: it named
      // a real and important behaviour, so leaving it would have implied the behaviour was
      // optional when the tools snap unconditionally and always have.

      Section("Explorer") {
        Toggle("Show tools that are unavailable", isOn: $preferences.showsUnavailableTools)
          .help(
            "Components from libraries this build cannot load are listed, disabled, with "
              + "the reason. They are always preserved on save whether or not they are shown.")
        Toggle("Expand libraries by default", isOn: $preferences.expandsLibrariesByDefault)
          .help("Upstream expands every built-in library on open — about 200 rows.")
      }
    }
    .formStyle(.grouped)
  }
}

private struct AppearancePane: View {
  @Bindable var preferences: EditorPreferences

  var body: some View {
    Form {
      // The application's ONLY light/dark control, and deliberately so; `AppCommands.swift`'s
      // header carries the 4.1.0 measurement and `AppearancePlacementTests` fails if a second
      // one appears in the menu bar, the toolbar or the canvas overlay. Real use on 2026-09-08
      // reported "the light/dark mode toggle should be in a settings or smth"; it already was,
      // which makes that a discoverability report rather than a placement one.
      //
      // ⚠️ The caption below says "the canvas", and that word is exact rather than modest.
      // `EditorWindow.swift:47` applies `preferredColorScheme` to the **document window only**,
      // so this window, About, the Log window and the hex editor keep the *system* appearance:
      // with Appearance = Light on a Dark system, this very Settings window stays dark
      // (observed in the shipping build, 2026-09-08). `AppearancePreference.nsAppearance`
      // exists precisely to fix that app-wide and has no reader anywhere in the tree; it is
      // the unwired half of this preference, and both files are outside this slice.
      Section("Theme") {
        Picker("Appearance", selection: $preferences.appearance) {
          ForEach(AppearancePreference.allCases) { value in
            Text(value.displayName).tag(value)
          }
        }
        .pickerStyle(.inline)
        Text(
          "The canvas follows this immediately, including its text and grid. It is "
            + "re-resolved from the live system appearance on every change rather than "
            + "captured once at launch."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      // 4.1.0 jar: IntlOptions offers only shaped/rectangular; AbstractGate.paintBase
      // has no DIN dispatch. Do not advertise the latent DIN painter as an option.
      Section("Gates") {
        Picker("Gate shape", selection: $preferences.gateShape) {
          Text("Shaped (US)").tag(CanvasAppearance.GateShape.shaped)
          Text("Rectangular (IEC)").tag(CanvasAppearance.GateShape.rectangular)
        }
      }
    }
    .formStyle(.grouped)
  }
}

/// Named to avoid colliding with the canvas view of the same idea.
private struct CanvasPane_Settings: View {
  @Bindable var preferences: EditorPreferences

  var body: some View {
    Form {
      Section("Grid") {
        Toggle("Show grid", isOn: $preferences.showGrid)
        LabeledContent("Spacing") {
          Picker("", selection: $preferences.gridSpacing) {
            Text("5").tag(5.0)
            Text("10 (standard)").tag(10.0)
            Text("20").tag(20.0)
          }
          .labelsHidden()
          .fixedSize()
        }
      }

      Section("Drawing") {
        Toggle("Antialias", isOn: $preferences.antialiasing)
        Toggle("Colour wires by simulated value", isOn: $preferences.showsValueColours)
        Toggle("Highlight the inspected component", isOn: $preferences.showsAttentionHalo)
      }

      Section("Pointer and Trackpad") {
        Picker("Zoom", selection: $preferences.zoomBehaviour) {
          ForEach(PointerZoomBehaviour.allCases) { value in
            Text(value.displayName).tag(value)
          }
        }
        Toggle("Two-finger scroll pans the canvas", isOn: $preferences.scrollPans)
        Toggle("Invert scroll direction", isOn: $preferences.invertScrollDirection)
        LabeledContent("Pan speed") {
          Slider(value: $preferences.panSensitivity, in: 0.25...3)
        }
        LabeledContent("Zoom speed") {
          Slider(value: $preferences.zoomSensitivity, in: 0.25...3)
        }
        Text(
          "Pinch to zoom, ⌘-scroll to zoom, space-drag or middle-drag to pan. The canvas "
            + "has no scroll bounds — you can always work to the left of what already exists."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }
}

private struct SimulationPane: View {
  @Bindable var preferences: EditorPreferences

  var body: some View {
    Form {
      // Default rate has a 4.1.0 counterpart but still needs its engine consumer.
      // The invented automatic-propagation default was removed in the Settings audit;
      // simulation's runtime propagation command remains independent of Settings.
      Section("Clock") {
        Picker("Default rate", selection: $preferences.defaultTickFrequency) {
          ForEach(SimulationStatus.supportedTickFrequencies, id: \.self) { hz in
            Text(SimulationStatus.tickFrequencyLabel(hz)).tag(hz)
          }
        }
      }

      Section("Diagnostics") {
        Toggle("Show measured rate and jitter", isOn: $preferences.showsSimulationDiagnostics)
        Text(
          "The status readout reports what the scheduler actually achieved. When a rate "
            + "cannot be measured it says so, and when the target cannot be met it says "
            + "that too, rather than echoing the requested figure back."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }
}

private struct AdvancedPane: View {
  @Bindable var preferences: EditorPreferences

  var body: some View {
    Form {
      Section("Unsupported features") {
        LabeledContent("JAR libraries") { Text("Not available").foregroundStyle(.secondary) }
        LabeledContent("Vendor FPGA toolchains") {
          Text("Not available").foregroundStyle(.secondary)
        }
        LabeledContent("TCL components") { Text("Not available").foregroundStyle(.secondary) }
        Text(
          "These require a JVM class loader, macOS builds that Xilinx and Intel have never "
            + "shipped, and an external tclsh process respectively. Circuits that use them "
            + "still open, and their components are written back byte-for-byte on save."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Section {
        Button("Reset All Settings…", role: .destructive) {
          preferences.resetAll()
        }
      }
    }
    .formStyle(.grouped)
  }
}
