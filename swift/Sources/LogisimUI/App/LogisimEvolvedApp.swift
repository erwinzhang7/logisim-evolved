// LogisimUI: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md at the repository root.
//
// ============================================================================
// THE APP.
//
// Deliberately NOT annotated `@main`. `LogisimUI` is a library target; the executable
// target is a three-line `main.swift` that calls `LogisimEvolvedApp.launch()`. That keeps
// the whole shell unit-testable and previewable, and it means the app entry point is a
// build-graph detail rather than a source-code one.
//
// Scenes:
//   - one `DocumentGroup` per open `.circ`;
//   - a `Settings` scene, which is what ⌘, opens (see the #2680 note in
//     `EditorPreferences.swift`);
//   - a `Window` for the About/licence/credits notices, because GPLv3 §5 and D10's
//     "Appropriate Legal Notices" obligation require them to be reachable from the
//     running app, not merely present in the source tarball.
//
// The About window is a `Window` and not an AppKit `NSAboutPanel` on purpose: the system
// panel takes its content from `Info.plist` keys and can show a name, a version and one
// short credits blob. It cannot carry the §5(a) modified-version notice, the two-lineage
// credits and 32 KB of licence text without turning into an unreadable single scroll.
// ============================================================================

import AppKit
import SwiftUI

public struct LogisimEvolvedApp: App {
  @State private var preferences = EditorPreferences.shared

  /// The Log window's controller, owned here because the scene needs one to exist.
  ///
  /// `LogWindowScene` was written complete and had **nothing constructing it**; the porting
  /// agent said so in its own report rather than leaving it for the seam check to find later,
  /// which is the difference between a handoff and a defect. This is that handoff taken up.
  ///
  /// One controller for the app rather than one per document, matching upstream: Logisim's log
  /// window is a single window that follows the active project. When the project layer stops
  /// being a stand-in, `attach(to:state:simulated:)` gets called on document activation.
  @State private var logController = LogController(model: LogModel())

  /// The hex editor, wired the moment it landed and for the reason recorded above this line:
  /// `LogWindowScene` was written complete and sat with nothing constructing it. `HexWindowScene`
  /// arrived in exactly that state, a finished window, openable programmatically, reachable from
  /// no running app, so it is constructed here in the same commit that merged it rather than
  /// becoming the twenty-ninth instance of that seam.
  ///
  /// One controller for the app, not one per document, matching `logController` and upstream's
  /// `RomAttributes.windowRegistry`: the registry is keyed on the `MemContents` identity, so
  /// reopening the same ROM returns the same editor with its caret intact.
  @State private var hexController = HexWindowController()

  public init() {
    // The autosave-recovery prompt (board M8). `AutosaveRecovery.prompt` defaults to nil,
    // which answers "open exactly the bytes that were named and touch nothing": the only safe
    // default, and the right one for `logisim-cli`, the rig and every test. This is the one
    // process that has a screen to ask on, so this is where the join is made, next to the
    // other platform seams the shell installs.
    //
    // Assigned here rather than in `LogisimFileProjectHost.registerBuiltinLibrariesIfNeeded`
    // , where `Buzzer.audioSinkFactory` and the two `Tty` seams are installed, because that
    // function is not in this slice's ownership. The two sites want merging; see the report.
    AutosaveRecovery.prompt = AutosaveRecoveryAlert.prompt
  }

  public var body: some Scene {
    DocumentGroup(newDocument: { CircuitDocument() }) { configuration in
      DocumentRoot(document: configuration.document, fileURL: configuration.fileURL)
        .environment(preferences)
    }
    // The hex controller is handed to the menu bar, not read from the environment: a `Commands`
    // tree is not in the view hierarchy. This is the line that gives Edit ▸ Edit Contents…
    // something to open, board #93.
    .commands { LogisimCommands(hexController: hexController) }
    .defaultSize(width: 1280, height: 820)

    Settings {
      SettingsWindow(preferences: preferences)
    }

    Window("About \(AboutFacts.productName)", id: AboutWindow.sceneID) {
      AboutWindow()
    }
    .defaultSize(width: 640, height: 680)
    .windowResizability(.contentMinSize)
    // One About window, and it is not a document window: it must not be duplicable by
    // ⌘N and must not appear as a "New Window" target.
    .commandsRemoved()

    // The Log window and chronogram. A single window that follows the active project, as
    // upstream has it, rather than one per document.
    LogWindowScene(controller: logController)

    // The hex editor. Opened from Edit ▸ Edit Contents…: `AppCommands.EditMemoryContentsItem`,
    // which is 4.1.0's `MemMenu` Edit item (`ramEditMenuItem`). That command is now written; this
    // comment used to describe one that never was, which is board #93.
    HexWindowScene(controller: hexController)
  }

  /// Entry point for the executable target.
  @MainActor
  public static func launch() {
    LogisimEvolvedApp.main()
  }
}

/// Bridges a `CircuitDocument` (bytes) to an `EditorModel` (a live project).
///
/// The host is created here, once, on first appearance: not in the document's
/// `init(configuration:)`, which the system may run off the main thread. That is the only
/// isolation subtlety in the whole shell and it is contained to these twenty lines.
struct DocumentRoot: View {
  var document: CircuitDocument
  var fileURL: URL?

  @Environment(EditorPreferences.self) private var preferences

  @State private var model: EditorModel?
  @State private var failure: String?
  /// Drives the save confirmation. Set only from `CircuitDocument.onSaveResolved`, which fires
  /// after the bytes have been read back off the disk: never from the act of producing them.
  @State private var saveOutcome: SaveBanner.Outcome?

  var body: some View {
    Group {
      if let model {
        EditorWindow(model: model)
      } else if let failure {
        ContentUnavailableView {
          Label("Could Not Open This Circuit", systemImage: "exclamationmark.triangle")
        } description: {
          Text(failure)
        }
      } else {
        ProgressView().controlSize(.small)
      }
    }
    .overlay(alignment: .top) {
      SaveBanner(outcome: $saveOutcome)
    }
    // `DocumentGroup` re-evaluates the body with a new `fileURL` after a Save As or a rename in
    // the title bar, and the sidecar has to follow the file rather than stay beside the name it
    // was opened under. `AutosaveController` deletes the sidecar it left at the old location on
    // the first tick that lands at a new one, which is Java's
    // `if (oldAutosave != null && !oldAutosave.equals(autosaveFile)) oldAutosave.delete()`.
    .onChange(of: fileURL, initial: true) { _, url in
      document.currentURL = url
      // The other half of board #89: `LogisimFileProjectHost.fileURL` was assigned once in
      // `init` and never again, so from the first Save As onward the host and the scene
      // disagreed about where the document lived: and `EditorModel.fileURL`
      // (`EditorModel.swift:146`) mirrors the host's, so it inherited the stale one.
      (document.host as? LogisimFileProjectHost)?.documentMoved(to: url)
    }
    .task {
      guard model == nil else { return }
      do {
        model = EditorModel(host: try document.attachedHost(fileURL: fileURL))
        // Started only once a host exists: an autosave of a document that failed to open would
        // write the empty stand-in project over the sidecar that might have saved it.
        document.startAutosaving(preferences: preferences)
        // ⌘S goes through `DocumentGroup`'s own File ▸ Save, `AppCommands` has no producer for
        // `ProjectCommand.save` and deliberately does not replace `CommandGroupPlacement.saveItem`
        // , so the shell is never told a save happened. `snapshot(contentType:)` is the only
        // notification it gets, and this closure is what it eventually resolves to.
        //
        // Nothing here has to poke `EditorModel`: `confirmSaveSucceeded()` ends with
        // `notify([.dirtyState])`, and `EditorModel.pull` re-reads `isDirty`, `displayName` and
        // `fileURL` on that change (`EditorModel.swift:143-147`). The banner is the only thing
        // this closure owns.
        //
        // `[$saveOutcome]` rather than an implicit capture, and that is a retain cycle rather
        // than a style preference: an implicit capture takes the whole `DocumentRoot` value,
        // which holds a strong `document`, and the document holds this closure, so the
        // document would outlive its window. A `Binding` projected from `@State` refers to
        // SwiftUI's storage for the property, not to the view that declared it, so capturing
        // the projection alone breaks the edge. `.onDisappear` clears it as well.
        document.onSaveResolved = { [$saveOutcome] confirmed in
          $saveOutcome.wrappedValue = confirmed ? .saved : .notWritten
        }
      } catch {
        failure = error.localizedDescription
      }
    }
    .onDisappear {
      // The window is going away. Whether the sidecar goes with it is decided by whether there
      // is anything in it the file on disk does not already have; `stopAutosaving` also
      // refuses to delete one this document was *recovered* from and has not yet re-saved.
      let clean = model?.isDirty == false
      document.stopAutosaving(deleteSidecar: clean)
      document.onSaveResolved = nil
    }
  }
}
