// FontSpecFamilyTests: part of logisim-evolved.
//
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// Pins the ONE deliberate divergence in the font codec: the port re-emits the family name it
// parsed, where 4.1.0 re-emits `font.getFamily()`: the family the host's graphics environment
// resolved the request to, which is `Dialog` whenever that family is not installed.
//
// This file exists to stop a future agent "fixing" the 13 migration failures by hardcoding
// `Dialog`. `Dialog` is not upstream's answer; it is upstream's answer ON A MACHINE WITHOUT THE
// FONT. That was measured, not reasoned: installing a font reporting family "Ubuntu" and
// re-running the unchanged 4.1.0 jar over an unchanged input file changed the jar's output
// (sha256 df855883… -> 01656660…, 36 lines, all of them font). Full write-up and the raw
// numbers in `docs/experiments/font-family.md`.
//
// Everything asserted below is host-independent by construction: the kernel has no font
// database, so these expectations hold on any machine, which is exactly the property upstream
// lacks.

import Testing

@testable import LogisimKernel

// MARK: - The family survives the round trip verbatim

/// The seven third-party families carried by the 13 diverging corpus files. Upstream collapses
/// each of these to `Dialog` on a machine that lacks them; the port keeps them.
private let corpusThirdPartyFamilies = [
  "CMU Sans Serif",
  "Ubuntu",
  "Ubuntu Sans Mono",
  "Yu Gothic UI Semibold",
  "DejaVu Sans",
  "DejaVu Sans Mono",
  "Courier 10 Pitch",
]

@Test func unresolvableFamilyIsPreservedNotCollapsedToDialog() {
  for family in corpusThirdPartyFamilies {
    let text = "\(family) plain 12"
    let spec = AttributeTextFormat.decodeFont(text)
    #expect(spec.family == family)
    #expect(spec.style == .plain)
    #expect(spec.size == 12)
    // The whole point: NOT "Dialog plain 12".
    #expect(spec.standardString == text)
  }
}

@Test func fontStandardStringRoundTripsEveryStyleAndSize() {
  // Style word and size are NOT part of the deviation, Java's `getStyle()`/`getSize()` return
  // what was requested, so these must match upstream exactly.
  let cases = [
    "CMU Sans Serif plain 12",
    "Ubuntu bold 16",
    "Ubuntu bold 20",
    "Ubuntu plain 18",
    "Ubuntu plain 24",
    "Ubuntu Sans Mono bold 18",
    "Yu Gothic UI Semibold bolditalic 20",
    "DejaVu Sans Mono plain 12",
    "Courier 10 Pitch italic 12",
  ]
  for text in cases {
    #expect(AttributeTextFormat.decodeFont(text).standardString == text)
  }
}

/// The four logical names plus the families macOS and the JVM both have. These are the cases
/// where the port and upstream agree, and they must keep agreeing.
@Test func resolvableAndLogicalFamiliesAlreadyAgreeWithUpstream() {
  for text in [
    "SansSerif plain 12", "SansSerif bold 10", "Serif plain 12", "Monospaced plain 12",
    "Dialog plain 12", "DialogInput plain 12",
    "Arial plain 12", "Arial Black bolditalic 20", "Tahoma plain 12",
  ] {
    #expect(AttributeTextFormat.decodeFont(text).standardString == text)
  }
}

// MARK: - The family is never normalised

/// Java's font manager matches case-insensitively and accepts PostScript/face names, so
/// `new Font("arial")` reports family `Arial` and `new Font("Arial-BoldMT")` reports `Arial`.
/// The kernel must NOT imitate that: doing so needs a font database, and the result would be
/// host-dependent in the same way. Verified against openjdk@21 on this machine; the point of
/// the test is that the port deliberately does none of it.
@Test func familyIsNeverCanonicalisedOrCaseFolded() {
  for name in ["arial", "ARIAL", "Arial-BoldMT", "HelveticaNeue", "TimesNewRomanPSMT",
               "Menlo-Regular", "sansserif", "SANSSERIF"] {
    #expect(AttributeTextFormat.decodeFont("\(name) plain 12").family == name)
  }
}

/// A family whose own name ends in a style word must not lose it. `Font.decode` strips at most
/// one trailing style token, and the corpus really does carry `Yu Gothic UI Semibold`.
@Test func familyEndingInAStyleWordKeepsIt() {
  let spec = AttributeTextFormat.decodeFont("Yu Gothic UI Semibold bold 20")
  #expect(spec.family == "Yu Gothic UI Semibold")
  #expect(spec.style == .bold)
  #expect(spec.size == 20)
}

// MARK: - FontSpec formatting itself

@Test func standardStringMatchesJavaFormatString() {
  // `String.format("%s %s %s", family, styleWord, size)`: single spaces, no padding, and the
  // size printed as a plain integer.
  #expect(FontSpec(family: "SansSerif", style: .plain, size: 12).standardString
    == "SansSerif plain 12")
  #expect(FontSpec(family: "Ubuntu", style: .bold, size: 16).standardString == "Ubuntu bold 16")
  #expect(FontSpec(family: "Ubuntu", style: .italic, size: 8).standardString == "Ubuntu italic 8")
  #expect(FontSpec(family: "Ubuntu", style: [.bold, .italic], size: 8).standardString
    == "Ubuntu bolditalic 8")
  // An empty family still formats with both separators, as Java's `%s` would.
  #expect(FontSpec(family: "", style: .plain, size: 12).standardString == " plain 12")
}
