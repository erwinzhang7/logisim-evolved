// LogisimUI: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md at the repository root.
//
// ============================================================================
// CREDITS: two lineages, reproduced rather than composed.
//
// D10: "Attribution: two lineages, Carl Burch (original Logisim) and the
// logisim-evolution developers." That is the structure below, and it is upstream's own
// structure: `docs/credits.md` opens with "The `Logisim-evolution` project is based on
// `Logisim` software by: Carl Burch", then lists the people and institutions who took it
// forward. `AboutCredits.java` shows the same three groups under the headings
// "Developed by", "Fork from original project" and "Original Version".
//
// Every name, affiliation and link comes from `AboutFacts`, which cites the 4.1.0 file it
// was copied from. Nothing is added, reordered by our own judgement, or filled in from
// memory. Upstream's list ends with "and others…" precisely because it is not exhaustive,
// so that qualifier is reproduced too; dropping it would turn an acknowledged partial
// list into an implied complete one.
//
// The fourth section names this port's own author, kept visually subordinate and worded
// so it cannot be read as a claim over upstream's work.
// ============================================================================

import SwiftUI

struct AboutCreditsTab: View {
  var body: some View {
    AboutScroll {
      // Upstream: `creditsRoleOriginal = Original Version`.
      CreditsSection(
        title: "Original Logisim",
        caption: "Logisim-evolution is a fork of Logisim, by:"
      ) {
        CreditRow(AboutFacts.originalAuthor)
      }

      // Upstream: `creditsDevelopedBy = Developed by`.
      CreditsSection(
        title: "Logisim-evolution",
        caption: AboutFacts.upstreamCopyright
      ) {
        ForEach(AboutFacts.evolutionContributors) { CreditRow($0) }

        HStack(spacing: 6) {
          Text(AboutFacts.andOthersNotice)
            .font(.callout)
            .foregroundStyle(.secondary)
          Link("Full credits", destination: AboutFacts.upstreamCreditsURL)
            .font(.callout)
        }
        .padding(.top, 4)
      }

      // Upstream: `creditsRoleFork = Fork from original project`.
      CreditsSection(
        title: "Institutions",
        caption: "Named by upstream as having supported the fork:"
      ) {
        ForEach(AboutFacts.institutions) { CreditRow($0) }
      }

      // Not a person, but owed the same acknowledgement: upstream artwork this port
      // reuses rather than translates. See `AboutFacts.derivedArtworkNotice`.
      CreditsSection(
        title: "Artwork",
        caption: "Icons taken from upstream rather than drawn here:"
      ) {
        Text(.init(AboutFacts.derivedArtworkNotice))
          .font(.callout)
          .fixedSize(horizontal: false, vertical: true)
      }

      CreditsSection(title: "This port", caption: nil) {
        Text(AboutFacts.thisPortCredit)
          .font(.callout)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

private struct CreditsSection<Content: View>: View {
  var title: String
  var caption: String?
  @ViewBuilder var content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.headline)
        if let caption {
          Text(caption)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      VStack(alignment: .leading, spacing: 8) {
        content
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(16)
    .background {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(Color(nsColor: .controlBackgroundColor))
    }
    .overlay {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
    }
  }
}

/// One credited person or institution. The name is a link when, and only when, upstream
/// itself publishes one for them.
private struct CreditRow: View {
  var credit: AboutFacts.Credit

  init(_ credit: AboutFacts.Credit) {
    self.credit = credit
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 1) {
      if let url = credit.url {
        Link(credit.name, destination: url)
          .font(.callout.weight(.medium))
      } else {
        Text(credit.name)
          .font(.callout.weight(.medium))
      }
      if let detail = credit.detail {
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .fixedSize(horizontal: false, vertical: true)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
