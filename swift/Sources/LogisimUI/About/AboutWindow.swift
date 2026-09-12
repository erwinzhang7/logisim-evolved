// LogisimUI: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md at the repository root.
//
// ============================================================================
// THE ABOUT WINDOW: the app's Appropriate Legal Notices, and its manners.
//
// This window discharges four separate GPLv3 obligations (D10):
//
//   §5(a)  a prominent notice that this is a modified version, with a date;
//   §5(b)  a notice that the work is released under this Licence;
//   §5(d)  Appropriate Legal Notices displayed by an interactive program: §0 defines
//          those as the copyright notice, the no-warranty statement, notice that
//          recipients may redistribute under this Licence, and how to view a copy of it;
//   §4/§6  a copy of the Licence itself, and the Corresponding Source offer.
//
// Hence three tabs and not one scroll: the notices are what a user must be able to find,
// the credits are what upstream is owed, and the licence is the document itself. Burying
// the first two under 32 KB of legal text would satisfy the letter of §5(d) and defeat it.
//
// On the look: upstream's About is a 640×440 white `JDialog` with a bitmap logo and a
// credits reel that scrolls at a fixed 20 ms/raster on a dedicated `Thread` which keeps
// running while the dialog is open (`About.java`'s `PanelThread`). It is unreadable by
// design; you cannot scroll it, you wait for it. Erwin's stated reason for this project
// is that upstream's UI is bad, and the About box is where a reader forms their first
// opinion, so: a real macOS window, a vector mark that is correct in both appearances, no
// animation the user cannot stop, and text they can select and copy.
//
// This module is the one place AppKit and SwiftUI are permitted (D9).
// ============================================================================

import AppKit
import SwiftUI

/// GPLv3 §5(d) "Appropriate Legal Notices" plus D10's two-lineage attribution.
///
/// A licence notice that exists only in a `LICENSE.md` beside the source is not a notice
/// displayed by the running program, which is what §5(d) asks for. This window is that.
struct AboutWindow: View {
  static let sceneID = "about"

  enum Tab: String, CaseIterable, Identifiable {
    case notices = "About"
    case credits = "Credits"
    case licence = "Licence"

    var id: Self { self }
  }

  @State private var selection = AboutSelection.shared
  @State private var didCopyDetails = false

  private var tab: Tab { selection.tab }

  var body: some View {
    VStack(spacing: 0) {
      AboutHeader()

      Picker(
        "Section",
        selection: Binding(get: { selection.tab }, set: { selection.tab = $0 })
      ) {
        ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .accessibilityLabel("About section")
      .frame(maxWidth: 340)
      .padding(.horizontal, 24)
      .padding(.top, 14)
      .padding(.bottom, 12)

      Divider()

      Group {
        switch tab {
        case .notices: NoticesTab()
        case .credits: AboutCreditsTab()
        case .licence: LicenceView()
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)

      Divider()
      footer
    }
    .frame(minWidth: 560, idealWidth: 640, minHeight: 520, idealHeight: 680)
    .background(Color(nsColor: .windowBackgroundColor))
  }

  /// Upstream has a "Copy details" button on its About dialog (`About.java`), and it is
  /// the genuinely useful part of an About box; it is what someone pastes into a bug
  /// report. Kept, and given the facts that actually identify a build.
  private var footer: some View {
    HStack(spacing: 12) {
      Button {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(AboutFacts.copyableDetails, forType: .string)
        didCopyDetails = true
      } label: {
        Label(didCopyDetails ? "Copied" : "Copy Details", systemImage: "doc.on.doc")
      }
      .disabled(didCopyDetails)

      Spacer(minLength: 0)

      Link(destination: AboutFacts.upstreamURL) {
        Label("Upstream Project", systemImage: "arrow.up.forward.square")
      }
      .buttonStyle(.link)
    }
    .font(.callout)
    .padding(.horizontal, 20)
    .padding(.vertical, 12)
    .background(.bar)
    // The "Copied" acknowledgement is a two-second state change, not an animation loop.
    .task(id: didCopyDetails) {
      guard didCopyDetails else { return }
      try? await Task.sleep(for: .seconds(2))
      didCopyDetails = false
    }
  }
}

/// Which tab the About window should show when it opens.
///
/// A SwiftUI `Window` scene takes no parameter, so a menu item cannot say "open About,
/// on the Licence tab" directly. This is the one bit of state that lets Help ▸ Licence and
/// Attribution land on the licence instead of dropping the user on the About tab to hunt
/// for it, which for a §5(d) obligation is the difference between reachable and
/// technically present.
@MainActor
@Observable
final class AboutSelection {
  static let shared = AboutSelection()

  var tab: AboutWindow.Tab = .notices

  private init() {}
}

// MARK: - Header

private struct AboutHeader: View {
  var body: some View {
    HStack(alignment: .top, spacing: 18) {
      AboutMark()
        .frame(width: 84, height: 84)

      VStack(alignment: .leading, spacing: 5) {
        Text(AboutFacts.productName)
          .font(.system(size: 28, weight: .semibold, design: .rounded))
        Text(AboutFacts.tagline)
          .font(.callout)
          .foregroundStyle(.secondary)
        // `.secondary`, not `.tertiary`: which upstream version this ports is a fact a
        // user may need to quote in a bug report, not a decorative subtitle.
        Text(AboutFacts.versionSummary)
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
          .padding(.top, 3)
          .textSelection(.enabled)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, 24)
    .padding(.top, 26)
    .padding(.bottom, 4)
  }
}

/// The app's mark: an AND gate on a schematic grid.
///
/// Drawn rather than shipped as a bitmap. Upstream's About loads a fixed PNG that is a
/// light-mode asset and looks wrong on a dark background; a vector mark resolves against
/// the current appearance, stays crisp at any scale factor, and adds no resource to the
/// bundle. It is also *ours*; the port must not reuse upstream's logo, which is their
/// mark and not licensed to us by the GPL (§7(e) explicitly contemplates trade-mark terms).
private struct AboutMark: View {
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    Canvas { context, size in
      let s = min(size.width, size.height)
      let unit = s / 100

      let plate = Path(roundedRect: CGRect(origin: .zero, size: CGSize(width: s, height: s)),
                       cornerRadius: s * 0.24)
      context.fill(
        plate,
        with: .linearGradient(
          Gradient(colors: scheme == .dark
            ? [Color(red: 0.16, green: 0.23, blue: 0.34), Color(red: 0.09, green: 0.12, blue: 0.18)]
            : [Color(red: 0.36, green: 0.56, blue: 0.86), Color(red: 0.19, green: 0.33, blue: 0.62)]),
          startPoint: .zero,
          endPoint: CGPoint(x: s, y: s)))

      // The schematic grid the canvas itself draws on, at low contrast.
      var grid = Path()
      for i in stride(from: 12.0, through: 88.0, by: 12.0) {
        grid.move(to: CGPoint(x: i * unit, y: 8 * unit))
        grid.addLine(to: CGPoint(x: i * unit, y: 92 * unit))
        grid.move(to: CGPoint(x: 8 * unit, y: i * unit))
        grid.addLine(to: CGPoint(x: 92 * unit, y: i * unit))
      }
      context.clip(to: plate)
      context.stroke(grid, with: .color(.white.opacity(0.10)), lineWidth: max(0.5, unit * 0.6))

      // An AND gate: flat back, semicircular front, two inputs and an output.
      var gate = Path()
      gate.move(to: CGPoint(x: 34 * unit, y: 26 * unit))
      gate.addLine(to: CGPoint(x: 34 * unit, y: 74 * unit))
      gate.addLine(to: CGPoint(x: 54 * unit, y: 74 * unit))
      gate.addArc(
        center: CGPoint(x: 54 * unit, y: 50 * unit), radius: 24 * unit,
        startAngle: .degrees(90), endAngle: .degrees(270), clockwise: true)
      gate.closeSubpath()

      var leads = Path()
      leads.move(to: CGPoint(x: 12 * unit, y: 38 * unit))
      leads.addLine(to: CGPoint(x: 34 * unit, y: 38 * unit))
      leads.move(to: CGPoint(x: 12 * unit, y: 62 * unit))
      leads.addLine(to: CGPoint(x: 34 * unit, y: 62 * unit))
      leads.move(to: CGPoint(x: 78 * unit, y: 50 * unit))
      leads.addLine(to: CGPoint(x: 90 * unit, y: 50 * unit))

      let ink = Color.white
      context.stroke(
        leads, with: .color(ink.opacity(0.92)),
        style: StrokeStyle(lineWidth: unit * 5, lineCap: .round))
      context.fill(gate, with: .color(ink.opacity(0.16)))
      context.stroke(
        gate, with: .color(ink.opacity(0.95)),
        style: StrokeStyle(lineWidth: unit * 5, lineJoin: .round))
    }
    .accessibilityLabel("\(AboutFacts.productName) icon")
  }
}

// MARK: - Notices

/// Everything §5 requires, in the order a person would ask the questions: what is this,
/// whose is it, what may I do with it, and what is missing.
private struct NoticesTab: View {
  var body: some View {
    AboutScroll {
      // §5(a). First on the page and in the largest type on it, because "prominent" is
      // the operative word in the clause.
      AboutCard(tone: .prominent) {
        Label("Modified version", systemImage: "arrow.triangle.branch")
          .font(.headline)
        Text(.init(AboutFacts.modifiedVersionNotice))
        Link(destination: AboutFacts.upstreamURL) {
          Text(AboutFacts.upstreamURL.absoluteString)
        }
        .font(.callout)
      }

      AboutCard {
        Label("Copyright", systemImage: "c.circle")
          .font(.headline)
        Text(AboutFacts.upstreamCopyright)
        Text(AboutFacts.originalCopyright)
          .foregroundStyle(.secondary)
      }

      // §5(b) and the §0 no-warranty notice.
      AboutCard {
        Label("Licence — \(AboutFacts.licenceSPDXIdentifier)", systemImage: "doc.text")
          .font(.headline)
        Text(.init(AboutFacts.licenceNotice))
        Text(.init(AboutFacts.warrantyNotice))
        Text(.init(AboutFacts.howToViewLicence))
          .foregroundStyle(.secondary)
        Text(.init(AboutFacts.sourceOfferNotice))
          .foregroundStyle(.secondary)
        if let source = AboutFacts.sourceURL {
          Link("Source repository", destination: source)
            .font(.callout)
        }
      }

      AboutCard {
        Label("What this port does not do", systemImage: "exclamationmark.triangle")
          .font(.headline)
        Text(.init(AboutFacts.divergenceNotice))
      }
    }
  }
}

// MARK: - Shared chrome

/// A scroll container with the window's standard measure and insets. Text pages are
/// capped at a readable line length instead of stretching to the window width, which is
/// the single biggest difference between "a native app" and "a resized Java dialog".
struct AboutScroll<Content: View>: View {
  @ViewBuilder var content: Content

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        content
      }
      .textSelection(.enabled)
      .frame(maxWidth: 620, alignment: .leading)
      .padding(.horizontal, 24)
      .padding(.vertical, 20)
      .frame(maxWidth: .infinity)
    }
  }
}

/// One titled block of notice text.
struct AboutCard<Content: View>: View {
  enum Tone { case standard, prominent }

  var tone: Tone = .standard
  @ViewBuilder var content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      content
    }
    .font(.callout)
    .fixedSize(horizontal: false, vertical: true)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(16)
    .background {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(tone == .prominent
          ? AnyShapeStyle(Color.accentColor.opacity(0.10))
          : AnyShapeStyle(Color(nsColor: .controlBackgroundColor)))
    }
    .overlay {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .strokeBorder(
          tone == .prominent ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.08),
          lineWidth: 1)
    }
  }
}
