// GPLNoticeSetTests.swift: part of logisim-evolved.
//
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md at the repository root.
//
// Reference artefact: the shipped 4.1.0 jar at
// `/Applications/Logisim-evolution.app/Contents/app/logisim-evolution-4.1.0-all.jar`, read with
// `unzip -p` and `javap -c -p`. NOT this repository's `src/main/java`, which is upstream *main*
// and not 4.1.0. (D16.) Every 4.1.0 fact asserted below was checked against that jar:
//
//   unzip -p …-all.jar LICENSE.md | shasum -a 256
//     → f8d4768b381f1e342911e83df8fdad2b30c83a1594f8e4fddb440dfe19311614. This repository's LICENSE.md is
//       that text plus the GPL's own "How to Apply These Terms" appendix, which upstream
//       omits and the FSF says may not be omitted, so its digest is
//       18d43ab40ad976266cf9a8d6d29cbf38114199edc1caa174e6d0f0f1813bf50a and `GPLv3Text.sourceDigest`
//       matches THAT. `tools/package/embed-licence.py --check` keeps them equal.
//   javap -c -p -cp …-all.jar com.cburch.logisim.gui.start.AboutCredits
//     → the ten contributor names, the four institutions, and "Carl Burch"/"Hendrix College"/
//       "http://www.cburch.com/logisim/", which is what `AboutFacts` reproduces.
//   javap -p -cp …-all.jar com.cburch.logisim.std.gates.AbstractGate
//     → `protected abstract void paintIconANSI(java.awt.Graphics2D,int,int,int)` and
//       `protected static void paintIconBufferAnsi(java.awt.Graphics2D,boolean,boolean)`, the
//       artwork `Icons/ToolIcons.swift` transcribes and this suite requires be credited.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// THE NOTICE SET IS A RELEASE GATE, SO IT GETS A GATE.
//
// D10: this port is a derivative work of a GPL-3.0-only program, distributed as a signed DMG.
// Shipping without the correct notices is a licence violation, and it is the one 0.1.0 item
// that cannot be retrofitted; once a binary is conveyed, it is conveyed.
//
// The obligations, and where each is discharged:
//
//   §5(a)  a prominent notice that this is a modified version, carrying a date
//            → AboutFacts.modifiedVersionNotice, README.md, NOTICE.md, bundled NOTICE.md
//   §5(b)  a notice that the whole work is released under this Licence
//            → AboutFacts.licenceNotice
//   §5(d)  an interactive program must DISPLAY Appropriate Legal Notices, which §0 defines as
//          the copyright notice, the no-warranty statement, notice that recipients may
//          redistribute under this Licence, and how to view a copy of it
//            → the About window's Notices tab, reachable from two menus
//   §4     convey a copy of the Licence itself, intact
//            → LICENSE.md, unedited; GPLv3Text, digest-checked against it
//   §6     the Corresponding Source offer
//            → AboutFacts.sourceOfferNotice
//
// WHAT THIS SUITE IS FOR, precisely: not to prove the wording is legally sufficient; no test
// can do that, and neither the author of this file nor its reviewer is a lawyer. It is to stop
// a *later* refactor silently deleting a notice that is currently there. That is the realistic
// failure: a tidy-up removes a `Text(…)` from a credits tab, nothing looks broken, and the
// build ships without an attribution it was carrying last month. A string check is cheap and
// catches exactly that.
//
// ── WHY SOME OF THESE ARE SOURCE SCANS ──────────────────────────────────────────────────────
//
// Three properties cannot be observed by calling into the module:
//
//   1. that `AboutCreditsTab` actually *renders* the artwork notice. A declared-but-unrendered
//      `static let` is the exact false green this project keeps finding one layer down; the
//      string would still be present, the About window would still show nothing.
//   2. that the About window is *reachable* from a menu. SwiftUI `Commands` are not
//      instantiable in a test process.
//   3. that the repo-root and packaged notice files agree with the app.
//
// So those three read the source and the repository files. A source scan is a weaker assertion
// than a behavioural one and is used only where the behavioural one does not exist.
// ═════════════════════════════════════════════════════════════════════════════════════════════

import Foundation
import Testing

@testable import LogisimUI

@Suite("GPLv3 notice set")
struct GPLNoticeSetTests {

  // MARK: - Repository layout

  /// The repository root, from this file's own path.
  static let repoRoot: URL =
    URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // LogisimUITests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // swift
    .deletingLastPathComponent()  // repo root

  static func text(at relativePath: String) throws -> String {
    let url = repoRoot.appendingPathComponent(relativePath)
    return try String(contentsOf: url, encoding: .utf8)
  }

  /// The same file with every run of whitespace collapsed to one space.
  ///
  /// The notice files are markdown hard-wrapped at 96 columns, so a phrase that must be
  /// present, "ABSOLUTELY NO WARRANTY", is routinely split across a line break. Asserting
  /// on the raw text would make the gate depend on where a paragraph happened to wrap, which
  /// is a test that fails for a reason nobody will guess. Prose assertions use this; the
  /// byte-identity check on `LICENSE.md` deliberately does not.
  static func prose(at relativePath: String) throws -> String {
    try text(at: relativePath)
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
  }

  static let uiSources: URL =
    repoRoot
    .appendingPathComponent("swift")
    .appendingPathComponent("Sources")
    .appendingPathComponent("LogisimUI")

  // MARK: - §5(a): the modified-version notice, and a date

  @Test("§5(a): the app states it is a modified version, names upstream, and carries a date")
  func modifiedVersionNoticeIsComplete() {
    let notice = AboutFacts.modifiedVersionNotice

    #expect(notice.localizedCaseInsensitiveContains("modified version"))
    #expect(notice.contains(AboutFacts.upstreamName))
    // "a relevant date" is the clause's own wording. The date must be *in the notice*, not
    // merely in a constant next to it.
    #expect(notice.contains(AboutFacts.modificationStartDate))
    #expect(AboutFacts.modificationStartDate.contains("2026"))

    // A modified version must not present itself as the original, and must not imply a
    // relationship it does not have. Both are §5(a) in substance and D10 explicitly.
    #expect(notice.localizedCaseInsensitiveContains("not the original"))
    #expect(notice.localizedCaseInsensitiveContains("neither endorsed by nor affiliated"))
  }

  @Test("the port does not claim to be upstream: distinct name, honest version")
  func identityIsDistinct() {
    #expect(AboutFacts.productName != AboutFacts.upstreamName)
    #expect(AboutFacts.upstreamVersion == "4.1.0")
    // The fallback version must not imply parity with 4.1.0, which the port has not reached.
    #expect(AboutFacts.developmentVersion.contains("dev"))
    #expect(AboutFacts.versionSummary.contains(AboutFacts.upstreamVersion))
  }

  // MARK: - §5(b), §5(d), §6

  @Test("§5(b): the licence notice names GPL version 3 and says GPL-3.0-only")
  func licenceNoticeIsPresent() {
    #expect(AboutFacts.licenceSPDXIdentifier == "GPL-3.0-only")
    let notice = AboutFacts.licenceNotice
    #expect(notice.contains("GNU General Public License"))
    #expect(notice.contains("version 3"))
    // D10: upstream omits "or any later version", so a derivative cannot add one. If this
    // sentence ever disappears the port has quietly claimed a relicensing option it lacks.
    #expect(notice.contains("or any later version"))
    #expect(notice.contains("GPL-3.0-only"))
  }

  @Test("§5(d)/§0: no-warranty, redistribution right, and how to view the Licence")
  func appropriateLegalNoticesAreComplete() {
    #expect(AboutFacts.warrantyNotice.contains("NO WARRANTY"))
    #expect(AboutFacts.warrantyNotice.contains("15"))
    #expect(AboutFacts.warrantyNotice.contains("16"))

    // "notice that recipients may redistribute the work under this License", §0.
    #expect(AboutFacts.licenceNotice.localizedCaseInsensitiveContains("redistribute"))

    // "how to view a copy of this License"; §0. It must point somewhere the user can go,
    // and the Licence tab is the in-app answer.
    #expect(AboutFacts.howToViewLicence.localizedCaseInsensitiveContains("licence"))
    #expect(AboutFacts.howToViewLicence.contains("LICENSE.md"))
  }

  @Test("§4: the copyright notice covers both lineages")
  func copyrightCoversBothLineages() {
    #expect(AboutFacts.upstreamCopyright.contains("Copyright"))
    #expect(AboutFacts.upstreamCopyright.contains("2001"))
    #expect(AboutFacts.upstreamCopyright.contains("Logisim-evolution"))
    // Carl Burch is the other lineage and is owed the same notice, not a footnote.
    #expect(AboutFacts.originalCopyright.contains("Carl Burch"))
    #expect(AboutFacts.originalAuthor.name == "Carl Burch")
  }

  @Test("§6: the source offer exists and never points at upstream's repository")
  func sourceOfferDoesNotMisdirect() {
    let offer = AboutFacts.sourceOfferNotice
    #expect(offer.localizedCaseInsensitiveContains("corresponding source"))
    // Corresponding Source is the *whole build pipeline*, per D10; saying "the sources"
    // alone would understate the obligation.
    #expect(offer.localizedCaseInsensitiveContains("build pipeline"))

    // The one lie an About window must not tell: pointing a user at logisim-evolution's
    // repository as though this program's source lived there. `sourceURL` is nil until the
    // port's own repository is published; if it is ever set, it must not be upstream's.
    if let source = AboutFacts.sourceURL {
      #expect(!source.absoluteString.contains("logisim-evolution/logisim-evolution"))
    }
  }

  // MARK: - Attribution — both lineages, and the artwork

  @Test("upstream's ten named contributors and four institutions are all reproduced")
  func upstreamCreditsAreReproduced() {
    // Verified against `javap -c -p com.cburch.logisim.gui.start.AboutCredits` in the 4.1.0
    // jar, which loads exactly these ten names.
    let expected = [
      "Moshe Berman", "Theldo Cruz Franqueira", "Zhao Hanyuan", "David H. Hutchens",
      "Theo Kluter", "Torsten Maehne", "Tom Niget", "Marcin Orłowski", "Kevin Walsh",
      "Liu Yuchen",
    ]
    let actual = AboutFacts.evolutionContributors.map(\.name)
    #expect(actual == expected)

    // Four institutions, same source. Names are checked by a distinguishing fragment rather
    // than in full: the jar and upstream's `docs/credits.md` differ in capitalisation for
    // the Vaud entry, and this suite is not the place to relitigate an institution's name.
    #expect(AboutFacts.institutions.count == 4)
    let institutions = AboutFacts.institutions.map(\.name).joined(separator: "\n")
    #expect(institutions.contains("Berner Fachhochschule"))
    #expect(institutions.contains("Holy Cross"))
    #expect(institutions.localizedCaseInsensitiveContains("canton de Vaud"))
    #expect(institutions.contains("Genève"))

    // Upstream's own list ends "and others…" because it is explicitly not exhaustive.
    // Dropping that turns an acknowledged partial list into an implied complete one.
    #expect(AboutFacts.andOthersNotice.localizedCaseInsensitiveContains("and others"))
    #expect(AboutFacts.upstreamCreditsURL.absoluteString.contains("v4.1.0"))
  }

  @Test("upstream ARTWORK reused by ToolIcons is credited, naming the methods it came from")
  func derivedArtworkIsCredited() {
    let notice = AboutFacts.derivedArtworkNotice
    #expect(notice.contains(AboutFacts.upstreamName))
    // The specific claim: these are upstream's drawings, not this port's design.
    #expect(notice.localizedCaseInsensitiveContains("artwork"))
    #expect(notice.contains("paintIconANSI"))
    #expect(notice.contains("paintIconBufferAnsi"))
    #expect(notice.contains("4.1.0"))
  }

  @Test("the artwork notice is actually RENDERED by the credits tab, not merely declared")
  func derivedArtworkNoticeIsRendered() throws {
    // A `static let` nobody reads is the false green this project keeps catching. The About
    // window is a SwiftUI view with no testable output, so reachability is a source scan.
    let tab = try Self.text(
      at: "swift/Sources/LogisimUI/About/AboutCreditsTab.swift")
    #expect(tab.contains("AboutFacts.derivedArtworkNotice"))
  }

  @Test("ToolIcons still is the transcription this credit describes")
  func toolIconsStillTranscribesUpstreamArtwork() throws {
    // If the icons are ever redrawn from scratch the credit becomes false in the other
    // direction; an unnecessary attribution is a smaller sin than a missing one, but a
    // notice set that has stopped describing the code is not an auditable notice set.
    let icons = try Self.text(at: "swift/Sources/LogisimUI/Icons/ToolIcons.swift")
    #expect(icons.contains("paintIconANSI"))
    #expect(icons.contains("logisim-evolution-4.1.0-all.jar"))
  }

  // MARK: - §4: the Licence itself, complete and unaltered

  @Test("the embedded licence is byte-identical to LICENSE.md, by digest")
  func embeddedLicenceMatchesTheRepositoryFile() throws {
    // `AboutFacts.embeddedLicenceIsIntact` is what the running app checks; assert it agrees.
    #expect(AboutFacts.embeddedLicenceIsIntact)

    // And assert the recorded digest is genuinely LICENSE.md's, so the pair cannot drift by
    // someone regenerating the Swift file from something else.
    let onDisk = try Self.text(at: "LICENSE.md")
    #expect(onDisk == GPLv3Text.markdown)
  }

  /// The appendix upstream drops. The FSF's position is that the GPL's own application
  /// instructions may not be omitted, and a licence audit found this tree had inherited the
  /// omission, so the text is restored and pinned here rather than left to be dropped again by
  /// the next regeneration.
  @Test("the embedded licence carries the GPL's own application instructions")
  func embeddedLicenceCarriesTheAppendix() {
    let text = GPLv3Text.markdown
    #expect(text.contains("How to Apply These Terms to Your New Programs"))
    #expect(text.contains("Copyright (C) <year>  <name of author>"))
    #expect(text.contains("type `show w'"))
    #expect(text.contains("why-not-lgpl.html"))
    // Order matters: the appendix follows the terms, it does not replace them.
    if let terms = text.range(of: "## END OF TERMS AND CONDITIONS"),
      let appendix = text.range(of: "How to Apply These Terms to Your New Programs")
    {
      #expect(terms.lowerBound < appendix.lowerBound)
    }
  }

  @Test("the embedded licence is the WHOLE licence: all 17 sections plus the closing line")
  func embeddedLicenceIsComplete() {
    let text = GPLv3Text.markdown

    #expect(text.contains("GNU GENERAL PUBLIC LICENSE"))
    #expect(text.contains("Version 3, 29 June 2007"))
    #expect(text.contains("## Preamble"))

    // Every numbered section. A truncated licence displayed confidently is the bad outcome
    // this whole file exists to prevent, and truncation is what a careless regeneration
    // produces; the beginning always looks right.
    for section in 0...17 {
      #expect(
        text.contains("### \(section)."),
        "the embedded licence is missing section \(section)")
    }

    // The clauses this port's own compliance turns on.
    #expect(text.contains("### 5. Conveying Modified Source Versions."))
    #expect(text.contains("### 6. Conveying Non-Source Forms."))
    #expect(text.contains("Appropriate Legal Notices"))
    #expect(text.contains("## END OF TERMS AND CONDITIONS"))

    // Not a stub. 4.1.0's LICENSE.md is 32,089 bytes; this tree adds the GPL's own application
    // instructions, which upstream omits, for 34,804. Pinned as an exact number because a
    // truncated licence displayed confidently is the failure this file exists to prevent, and
    // truncation always looks right at the top.
    #expect(text.utf8.count == 34_804)
  }

  @Test("the licence is REACHABLE in the app: parsed for display, losing no text")
  func licenceIsDisplayable() {
    // §5(d) says the notices must be *displayed*. `LicenceDocument` is what displays them,
    // and a parse that silently dropped blocks would satisfy every string check above while
    // showing the user an abridged licence.
    let document = LicenceDocument.gplv3
    #expect(!document.blocks.isEmpty)

    let rendered =
      document.blocks
      .map { block in
        block.items.isEmpty ? block.text : block.items.map(\.text).joined(separator: " ")
      }
      .joined(separator: "\n")

    #expect(rendered.contains("END OF TERMS AND CONDITIONS"))
    #expect(rendered.contains("Appropriate Legal Notices"))
    #expect(rendered.localizedCaseInsensitiveContains("NO WARRANTY"))

    // Every numbered section survives the parse and is offered to the section menu, which is
    // how a reader actually gets to §6 in 32 KB of text.
    let numbered = Set(document.blocks.compactMap(\.sectionNumber))
    for section in 1...17 {
      #expect(numbered.contains(section), "section \(section) is not reachable after parsing")
    }
  }

  @Test("the About window has a Licence tab and both menus can open the window")
  func licenceTabIsReachableFromAMenu() throws {
    #expect(AboutWindow.Tab.allCases.contains(.licence))

    // SwiftUI `Commands` cannot be instantiated in a test process, so reachability is a
    // source scan: some file outside About/ must register the scene, and some file must
    // open it. Written against `AboutWindow.sceneID` rather than a literal so it survives a
    // rename of the surrounding menu code; the property under test is that a user can get
    // there at all, which for a §5(d) obligation is the whole point.
    let app = try Self.text(at: "swift/Sources/LogisimUI/App/LogisimEvolvedApp.swift")
    #expect(app.contains("AboutWindow.sceneID"), "no scene registers the About window")

    let commands = try Self.text(at: "swift/Sources/LogisimUI/App/AppCommands.swift")
    #expect(
      commands.contains("openWindow(id: AboutWindow.sceneID)"),
      "no menu item opens the About window")
    #expect(
      commands.contains("tab: .licence"),
      "no menu item lands on the Licence tab, so §5(d)'s \"how to view a copy\" is a hunt")
  }

  // MARK: - The three copies must agree

  @Test("the repository root carries LICENSE.md and a NOTICE.md that names both lineages")
  func repositoryNoticeSetExists() throws {
    // LICENSE.md is upstream's file and must stay intact: §4 conveys the Licence, it does
    // not invite editing it. So the modification notices live in NOTICE.md beside it.
    let licence = try Self.text(at: "LICENSE.md")
    #expect(licence.contains("GNU GENERAL PUBLIC LICENSE"))

    let notice = try Self.prose(at: "NOTICE.md")
    #expect(notice.localizedCaseInsensitiveContains("modified version"))
    #expect(notice.contains(AboutFacts.modificationStartDate))
    #expect(notice.contains("GPL-3.0-only"))
    #expect(notice.contains("NO WARRANTY"))
    #expect(notice.contains("Carl Burch"))
    #expect(notice.localizedCaseInsensitiveContains("corresponding source"))
    #expect(notice.contains("paintIconANSI"))
  }

  @Test("README.md leads with the modification notice, before upstream's own text")
  func readmeCarriesTheModificationNotice() throws {
    let readme = try Self.prose(at: "README.md")

    // "Prominent" is the operative word in §5(a), and a notice below upstream's logo, table
    // of contents and feature list is not prominent. Require it in the first 2 000
    // characters, which is roughly what a reader sees before scrolling: and, critically,
    // *before* upstream's own heading, so a reader cannot mistake this tree for upstream's.
    let head = String(readme.prefix(2_000))
    #expect(head.localizedCaseInsensitiveContains("modified version"))
    #expect(head.contains(AboutFacts.modificationStartDate))
    #expect(head.contains("GPL-3.0-only"))
    #expect(head.localizedCaseInsensitiveContains("neither endorsed by nor affiliated"))
    #expect(head.contains("NOTICE.md"))

    // Where upstream's own README text is still present, the notice must come BEFORE it.
    // Upstream's README describes *their* Java program, with their download links; a reader who
    // meets that before the disclaimer has been misled by the ordering alone.
    //
    // Conditional on the text being there, because the two published trees differ and both are
    // compliant: this fork keeps upstream's README under the notice, and the port-only repository
    // replaced it outright, which satisfies §5(a) more simply. Asserting the heading exists
    // failed in the second tree for the one reason that is not a defect.
    let noticeAt = readme.range(of: "modified version", options: .caseInsensitive)
    #expect(noticeAt != nil)
    if let noticeAt, let upstreamHeadingAt = readme.range(of: "# Logisim-evolution #") {
      #expect(noticeAt.lowerBound < upstreamHeadingAt.lowerBound)
    }
  }

  @Test("the packaged NOTICE.md.in agrees with the app on every load-bearing fact")
  func packagedNoticeAgreesWithTheApp() throws {
    // `build-app.sh` substitutes this into `Contents/Resources/NOTICE.md`. It is what a user
    // who never opens the About window sees, so it must not be a weaker set.
    let template = try Self.prose(at: "tools/package/NOTICE.md.in")

    #expect(template.localizedCaseInsensitiveContains("modified version"))
    #expect(template.contains(AboutFacts.modificationStartDate))
    #expect(template.contains(AboutFacts.upstreamVersion))
    #expect(template.contains("GPL-3.0-only"))
    #expect(template.contains("NO WARRANTY"))
    #expect(template.contains("Carl Burch"))
    #expect(template.contains("paintIconANSI"))

    // Every contributor the About window names is named here too, so the two attributions
    // cannot drift apart.
    for credit in AboutFacts.evolutionContributors {
      #expect(template.contains(credit.name), "packaged NOTICE omits \(credit.name)")
    }

    // The substitution tokens the packager fills in must still be here; `build-app.sh`
    // hard-fails if one is missing, and that failure at package time is far worse than
    // failing here.
    for token in ["@SHORT_VERSION@", "@BUILD_VERSION@", "@REVISION@", "@SOURCE_OFFER@"] {
      #expect(template.contains(token), "packaged NOTICE lost the \(token) token")
    }
  }
}
