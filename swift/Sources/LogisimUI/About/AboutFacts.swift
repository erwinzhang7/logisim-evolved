// LogisimUI: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md at the repository root.
//
// ============================================================================
// EVERY FACT THE ABOUT WINDOW STATES, IN ONE AUDITABLE PLACE.
//
// This file is a legal surface, not copy. GPLv3 §5(a) requires a prominent notice that
// the work is modified and a relevant date; §5(b) requires a notice that it is released
// under this Licence; §5(d) requires an interactive program to display Appropriate Legal
// Notices, which §0 defines as including a copyright notice, the no-warranty statement,
// a notice of the recipient's redistribution rights, and how to view a copy of the
// Licence. `AboutWindow` renders exactly what is declared here, so an audit reads one
// file rather than chasing string literals through a view hierarchy.
//
// SOURCING RULE, and it is strict: every name, year and URL below is copied from a file
// in the 4.1.0 reference tree (D16), cited inline. Nothing here is inferred, rounded, or
// remembered. If a fact could not be verified from that tree it is absent rather than
// approximated; an About box that guesses at attribution is worse than one that says
// less.
//
// What is deliberately NOT claimed anywhere in this window:
//   - endorsement, certification, affiliation, or any relationship with the upstream
//     project beyond "this is a derivative work of theirs";
//   - a contributor count. D10 records ~183 for the relicensing analysis; upstream's own
//     `git shortlog` yields 206 distinct author *strings*, several of which are the same
//     person spelled differently. Neither number is a fact about people, so we print
//     neither and name only those upstream itself names;
//   - authorship of upstream's work by this port, or vice versa.
// ============================================================================

import CryptoKit
import Foundation

/// The verified content of the About window.
enum AboutFacts {

  // MARK: - Identity

  /// The port's own name. Distinct from upstream's, per D10; a derivative work must not
  /// present itself as the original.
  static let productName = "logisim-evolved"

  static let tagline = "A native macOS digital logic designer and simulator"

  /// The upstream release this port targets. D16: the reference tree is the `v4.1.0` tag,
  /// never `main`. Displaying it is not trivia: it tells a user which upstream behaviour,
  /// file format and component set they are actually getting.
  static let upstreamVersion = "4.1.0"

  static let upstreamName = "logisim-evolution"

  /// `gradle.properties:19` in the 4.1.0 tree gives `https://github.com/logisim-evolution/`;
  /// the repository README links the project repository itself, which is the URL a user
  /// needs to reach the original work, so that is the one we show.
  static let upstreamURL = URL(string: "https://github.com/logisim-evolution/logisim-evolution")!

  /// This port's own version.
  ///
  /// Taken from the app bundle when there is one, so a shipped build reports what it
  /// actually is rather than what was compiled in months earlier. There is no bundle yet
  /// (the executable target is a three-line `main.swift`; see `LogisimEvolvedApp`), so the
  /// fallback is what you see during development, and it says so.
  static let portVersion: String = {
    let info = Bundle.main.infoDictionary
    let short = info?["CFBundleShortVersionString"] as? String
    let build = info?["CFBundleVersion"] as? String
    switch (short, build) {
    case let (short?, build?) where short != build: return "\(short) (\(build))"
    case let (short?, _): return short
    default: return developmentVersion
    }
  }()

  /// Used when the code is not running from a versioned bundle. Deliberately marked
  /// pre-release: the port is not at parity with 4.1.0 yet, and a version string that
  /// implied otherwise would be a false claim in the one window that must not make any.
  static let developmentVersion = "0.1.0-dev"

  static var versionSummary: String {
    "Version \(portVersion) · ports \(upstreamName) \(upstreamVersion)"
  }

  // MARK: - GPLv3 §5(a): the modified-version notice

  /// The date the first commit of this port landed on the `swift-port` branch, read from
  /// the repository history rather than chosen. §5(a) asks for "a relevant date"; the date
  /// modification began, together with the fact that it is ongoing, is that.
  static let modificationStartDate = "4 September 2026"

  static let modifiedVersionNotice = """
    This is a **modified version** of \(upstreamName): an independent rewrite in Swift for \
    macOS, begun on \(modificationStartDate) and still in progress. It is not the original \
    program, and it is neither endorsed by nor affiliated with the \(upstreamName) project \
    or its developers.
    """

  /// A modified version has to be honest about *how* it differs, not only that it does.
  /// D11's permanent gaps are the ones a user can hit, so they are stated here rather than
  /// left to be discovered as bugs.
  static let divergenceNotice = """
    Java component libraries (`.jar`), the vendor FPGA toolchains (Xilinx ISE and Vivado, \
    Intel Quartus) and the TCL console are not available in this build. Circuits that use \
    them still open, and their components are preserved exactly on save rather than being \
    silently discarded.
    """

  // MARK: - GPLv3 §5(b) and §5(d): licence, copyright, warranty

  static let licenceSPDXIdentifier = "GPL-3.0-only"

  /// `README.md` of the 4.1.0 tree, "License" section, verbatim in substance:
  /// "`Logisim-evolution` is copyrighted ©2001-2024 by Logisim-evolution developers."
  ///
  /// Upstream's own About screen instead renders `2001-{build year}`, which makes the
  /// displayed copyright range depend on the clock of whoever compiled it. We use the
  /// published range, which is a fact rather than a side effect of a build machine.
  static let upstreamCopyright = "Copyright © 2001–2024 Logisim-evolution developers"

  /// Original Logisim, per upstream `docs/credits.md`: "The `Logisim-evolution` project is
  /// based on `Logisim` software by: Carl Burch, Hendrix College, USA".
  static let originalCopyright = "Original Logisim by Carl Burch, Hendrix College"

  /// GPL-3.0-**only**, and that is not a stylistic choice. Upstream's `LICENSE.md` carries
  /// no "or any later version" clause, so a derivative work cannot add one (D10).
  static let licenceNotice = """
    \(productName) is free software: you may redistribute it and modify it under the terms \
    of the **GNU General Public License, version 3** as published by the Free Software \
    Foundation. Upstream deliberately omits the "or any later version" clause, so this port \
    is GPL-3.0-only and permanently cannot be relicensed.
    """

  /// §15/§16 in the user's own words. Kept shouty on the one clause the Licence itself
  /// puts in capitals, and calm everywhere else.
  static let warrantyNotice = """
    This program is distributed in the hope that it will be useful, but with **ABSOLUTELY \
    NO WARRANTY**, without even the implied warranty of merchantability or fitness for a \
    particular purpose. See sections 15 and 16 of the Licence for details.
    """

  /// §5(d)'s "how to view a copy of this License", answered with somewhere to click rather
  /// than a URL that can rot.
  static let howToViewLicence = """
    The complete licence text is included in this application — open the **Licence** tab \
    above — and ships as `LICENSE.md` with the source.
    """

  /// §6. Deliberately has no link: this port's repository is not published yet, and a
  /// button pointing at *upstream's* repository would misrepresent where this program's
  /// Corresponding Source is; the one lie an About window must not tell. When the
  /// repository goes public, add the URL here and the footer will pick it up.
  static let sourceOfferNotice = """
    The complete corresponding source for this program, including the whole build \
    pipeline, is published alongside every binary, as GPLv3 section 6 requires. It is a \
    separate repository from \(upstreamName)'s.
    """

  /// Where *this* program's Corresponding Source lives, once it is published. `nil` until
  /// then, and the UI renders the offer without a link rather than inventing one.
  static let sourceURL: URL? = nil

  // MARK: - Credits

  /// A credited party, mirroring what upstream itself publishes. `detail` carries the
  /// affiliation upstream lists; `url` the link upstream lists. Both optional, because for
  /// several entries upstream gives neither and we do not invent one.
  struct Credit: Identifiable, Sendable {
    var name: String
    var detail: String?
    var url: URL?

    var id: String { name }

    init(_ name: String, _ detail: String? = nil, _ url: String? = nil) {
      self.name = name
      self.detail = detail
      self.url = url.flatMap(URL.init(string:))
    }
  }

  /// From `docs/credits.md` in the 4.1.0 tree: "The `Logisim-evolution` project is based on
  /// `Logisim` software by: Carl Burch, Hendrix College, USA". The URL is the one upstream's
  /// own About screen uses for him (`AboutCredits.java`).
  static let originalAuthor = Credit(
    "Carl Burch", "Hendrix College, USA", "http://www.cburch.com/logisim/")

  /// From `docs/credits.md`: "The following people and institutions actively contributed to
  /// further development of the `Logisim-evolution`". Reproduced in upstream's order, which
  /// is alphabetical by surname, with upstream's own affiliations and links.
  ///
  /// This is the people half of that list. Upstream's About screen shows the same ten names
  /// under "Developed by", followed by "and others…"; that trailing acknowledgement is not
  /// decoration and is reproduced too, because the list is explicitly not exhaustive.
  /// Affiliations are upstream's own wording, not shortened. `Berner Fachhochschule |
  /// Haute école spécialisée bernoise` is one institution with a bilingual name, and
  /// printing half of it would be an edit to somebody's affiliation rather than a layout
  /// choice, the row wraps instead.
  static let evolutionContributors: [Credit] = [
    Credit("Moshe Berman", "Brooklyn College, USA"),
    Credit("Theldo Cruz Franqueira", "Pontifícia Universidade Católica de Minas Gerais, Brazil"),
    Credit("Zhao Hanyuan", "Tsinghua University, China", "https://github.com/gtxzsxxk"),
    Credit("David H. Hutchens", "Millersville University, Pennsylvania, USA"),
    Credit(
      "Theo Kluter", "Berner Fachhochschule | Haute école spécialisée bernoise, Switzerland",
      "https://www.bfh.ch/en/theo-kluter"),
    Credit(
      "Torsten Maehne", "Berner Fachhochschule | Haute école spécialisée bernoise, Switzerland",
      "https://www.bfh.ch/en/torsten-maehne"),
    Credit("Tom Niget", "LEAT, Polytech Nice-Sophia, France", "https://github.com/zdimension/"),
    Credit("Marcin Orłowski", "Poland", "http://www.marcinorlowski.com/"),
    Credit("Kevin Walsh", "College of the Holy Cross, USA"),
    Credit("Liu Yuchen", "Beijing University of Technology, China", "https://github.com/smallg0at"),
  ]

  /// Upstream's `AboutCredits.java` labels this group "Fork from original project"; the
  /// same four institutions close the `docs/credits.md` list.
  static let institutions: [Credit] = [
    Credit(
      "Berner Fachhochschule | Haute école spécialisée bernoise", "Switzerland",
      "https://www.bfh.ch/"),
    Credit("College of the Holy Cross", "USA", "https://www.holycross.edu/"),
    Credit(
      "Haute école d'ingénierie et de gestion du canton de Vaud", "Switzerland",
      "https://www.heig-vd.ch/"),
    Credit(
      "Haute école du paysage, d'ingénierie et d'architecture de Genève", "Switzerland",
      "https://hepia.hesge.ch/"),
  ]

  /// Verbatim from upstream's `gui.properties`: `creditsDevelopedByAndOthers = and others…`.
  static let andOthersNotice = "and others — see the upstream credits for the full list"

  /// Pinned to the `v4.1.0` tag, not `main`. The list shown here was copied from that
  /// tag; linking `main` would send a reader to a list that has since changed and
  /// silently make our reproduction look wrong.
  static let upstreamCreditsURL = URL(
    string: "https://github.com/logisim-evolution/logisim-evolution/blob/v4.1.0/docs/credits.md")!

  /// Attribution for upstream *artwork* reused in this port, as distinct from upstream
  /// logic translated by it.
  ///
  /// `Icons/ToolIcons.swift` is not a translation of behaviour; it is a transcription of
  /// drawings. The gate glyphs in the explorer and toolbar are Logisim-evolution's own icon
  /// geometry, read out of the shipped 4.1.0 jar with `javap -c -p` and rewritten as Swift
  /// path coordinates. Verified in
  /// `/Applications/Logisim-evolution.app/Contents/app/logisim-evolution-4.1.0-all.jar`
  /// (D16): `com.cburch.logisim.std.gates.AbstractGate` declares
  /// `protected abstract void paintIconANSI(java.awt.Graphics2D, int, int, int)` and
  /// `protected static void paintIconBufferAnsi(java.awt.Graphics2D, boolean, boolean)`,
  /// which `AndGate`, `OrGate`, `XorGate`, `NotGate` and `Buffer` supply or call.
  ///
  /// Both works are GPL-3.0-only, so the reuse needs no separate grant, but it does need
  /// saying. §5(a) is about being honest that the work is derived, and a user looking at a
  /// gate glyph is looking at upstream's drawing, not ours. `ToolIcons.swift`'s own header
  /// asks for exactly this line and notes it could not add it itself, because this file is
  /// owned elsewhere.
  static let derivedArtworkNotice = """
    The logic-gate, Select, wiring and Pin glyphs in the toolbar and explorer are \
    \(upstreamName)'s own icon drawings, transcribed from the 4.1.0 release as vector \
    geometry (`AbstractGate.paintIconANSI` and `paintIconBufferAnsi`, and the matching \
    painters in `gui.icons`, `tools` and `std.wiring`). They are upstream's artwork, \
    reused under the same licence, not this port's design.
    """

  static let thisPortCredit = """
    The Swift and macOS translation is independent work by Erwin Zhang. Everything it \
    simulates, reads and writes is \(upstreamName)'s design; the errors in the translation \
    are not.
    """

  // MARK: - Integrity

  /// Recomputes the digest recorded when `LicenceTextGPL3.swift` was generated.
  ///
  /// Cheap insurance against the one failure mode that matters here: an edit that leaves
  /// the app displaying licence text which is no longer the licence the source ships under.
  /// A wrong licence displayed confidently is the bad outcome; a visible warning is not.
  static var embeddedLicenceIsIntact: Bool {
    sha256Hex(GPLv3Text.markdown) == GPLv3Text.sourceDigest
  }

  private static func sha256Hex(_ string: String) -> String {
    SHA256.hash(data: Data(string.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
  }

  /// One-line technical summary, for the Copy Details button.
  ///
  /// Upstream has the same affordance (`About.java`'s "Copy details"), and it is genuinely
  /// the useful part of an About box in a bug report, so it is kept, and given the facts
  /// that actually identify a build.
  static var copyableDetails: String {
    let os = ProcessInfo.processInfo.operatingSystemVersion
    return """
      Product:   \(productName) \(portVersion)
      Ports:     \(upstreamName) \(upstreamVersion)
      Licence:   \(licenceSPDXIdentifier)
      macOS:     \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)
      Arch:      \(machineArchitecture)
      """
  }

  private static var machineArchitecture: String {
    #if arch(arm64)
      return "arm64"
    #elseif arch(x86_64)
      return "x86_64"
    #else
      return "unknown"
    #endif
  }
}
