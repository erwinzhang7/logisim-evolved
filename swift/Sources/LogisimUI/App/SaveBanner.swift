// LogisimUI: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md at the repository root.
//
// ============================================================================
// THE SAVE CONFIRMATION: asked for explicitly, and a DELIBERATE DIVERGENCE.
//
// State it plainly, because the standing rule says to: **4.1.0 has no "Saved!" message and
// neither does macOS.** Searched, not assumed; `resources/logisim/strings/gui/gui.properties`
// in `logisim-evolution-4.1.0-all.jar` has `fileSaveItem`, `saveButton`, `saveOption`,
// `ramSaveErrorTitle`, `saveIoError` and nothing that confirms a completed save. Upstream's
// confirmation is a *disappearance*: `Frame.buildTitleString()` puts a 💾 in front of the title
// and ` [UNSAVED]` after it while `Project.isFileDirty()` is true, and a successful save takes
// both away. macOS says the same thing with the dot in the close button and "— Edited".
//
// So why does this file exist at all? Because in THIS build both of those signals are
// currently dead, and that is a measurable fact rather than a judgement:
//
//   * Upstream's title badge is not ported. `EditorWindow` sets `.navigationTitle(displayName)`
//     and `.navigationSubtitle(windowSubtitle)`, and `EditorModel.windowSubtitle` is built from
//     the circuit name and the tick rate only; `isDirty` is read by nothing that draws.
//   * The system's badge is not driven. `grep -rn "UndoManager\|updateChangeCount" Sources/`
//     returns **zero hits in the whole target**. Those are the only two ways to move
//     `NSDocument.isDocumentEdited`, so it is provably always false: no edited dot, no
//     "— Edited", and no "Do you want to save the changes…?" sheet on close. That last one is
//     the serious half and it is reported separately; it is not this file's job to fix.
//
// With both persistent indicators inert, ⌘S produces no observable change of any kind, which
// is exactly what the request describes. A transient banner is the smallest honest thing that
// closes that gap without inventing a permanent piece of chrome that will contradict the system
// badge once the badge works.
//
// **This file should be deleted when the change-count wiring lands.** At that point the edited
// dot carries the signal in the place Mac users already look, and keeping a toast as well would
// be the "bespoke indicator that duplicates the system one" that is worse than nothing.
//
// WHAT IT WILL NOT DO: claim a save it has not verified. The banner is driven by
// `CircuitDocument.onSaveResolved`, which fires only after `SaveVerification.bytesReached`
// has read the bytes back off the disk. Producing bytes shows nothing.
// ============================================================================

import SwiftUI

struct SaveBanner: View {

  enum Outcome: Equatable {
    /// The bytes were found at the destination. Upstream's `Loader.save` returning true.
    case saved
    /// They were not: within the time the poll was willing to wait.
    ///
    /// Deliberately NOT called `.failed`. A slow or networked volume can finish the write after
    /// the last attempt, so "we did not see it" is all that is actually known. The document
    /// stays dirty either way, so the user's next move is the same; overstating this as a
    /// failure would be the same species of lie as the bug this whole change fixes, pointed the
    /// other way.
    case notWritten
  }

  @Binding var outcome: Outcome?

  /// How long a success stays up. A confirmation nobody asked to keep should not need
  /// dismissing, and 1.6s is long enough to register in peripheral vision without becoming
  /// something to wait out.
  static let successDuration: Duration = .milliseconds(1600)

  /// A failure does not auto-dismiss. The whole point of board #89 is that a save the user
  /// believes happened and did not is how work disappears, so the one message that carries that
  /// news stays until it is clicked away.
  static let failureDuration: Duration? = nil

  static func title(for outcome: Outcome) -> String {
    switch outcome {
    case .saved: return "Saved"
    case .notWritten: return "Could not confirm this save"
    }
  }

  static func detail(for outcome: Outcome) -> String? {
    switch outcome {
    case .saved: return nil
    case .notWritten:
      return "The document is still marked as having unsaved changes. Try saving again."
    }
  }

  static func symbol(for outcome: Outcome) -> String {
    switch outcome {
    case .saved: return "checkmark.circle.fill"
    case .notWritten: return "exclamationmark.triangle.fill"
    }
  }

  static func duration(for outcome: Outcome) -> Duration? {
    switch outcome {
    case .saved: return successDuration
    case .notWritten: return failureDuration
    }
  }

  var body: some View {
    if let outcome {
      content(outcome)
        .padding(.top, 8)
        .transition(.move(edge: .top).combined(with: .opacity))
        .task(id: outcome) {
          guard let wait = Self.duration(for: outcome) else { return }
          try? await Task.sleep(for: wait)
          guard !Task.isCancelled else { return }
          withAnimation { self.outcome = nil }
        }
        // A confirmation is a status change, not decoration: VoiceOver has to hear it, and it
        // must not steal focus to do so.
        .accessibilityAddTraits(.isStaticText)
        .accessibilityLabel(Self.title(for: outcome))
        .allowsHitTesting(outcome == .notWritten)
    }
  }

  @ViewBuilder
  private func content(_ outcome: Outcome) -> some View {
    HStack(spacing: 8) {
      Image(systemName: Self.symbol(for: outcome))
        .foregroundStyle(outcome == .saved ? Color.accentColor : Color.orange)
      VStack(alignment: .leading, spacing: 1) {
        Text(Self.title(for: outcome)).font(.callout.weight(.medium))
        if let detail = Self.detail(for: outcome) {
          Text(detail).font(.caption).foregroundStyle(.secondary)
        }
      }
      if outcome == .notWritten {
        Button("Dismiss") { withAnimation { self.outcome = nil } }
          .buttonStyle(.link)
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 9)
    // `.regularMaterial` rather than a solid fill so it reads as a transient overlay over the
    // canvas rather than as another pane, and so it inverts with the system appearance without
    // a second colour to keep in step.
    .background(.regularMaterial, in: .capsule)
    .overlay(Capsule().strokeBorder(.separator))
    .shadow(radius: 8, y: 2)
  }
}
