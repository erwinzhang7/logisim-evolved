// AppearanceRoundTripTests: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// DOES OPENING THE APPEARANCE EDITOR CHANGE THE FILE?
//
// This is the gate the appearance editor is measured by, and it is the one that decides whether
// the feature is allowed to exist at all. A viewer that quietly normalises shapes corrupts every
// file it opens, and D8 makes that worse than merely lossy: an `<appear>` may hold `visible-*`
// elements this port keeps as raw XML and cannot draw, so a model that round-trips only what it
// *understands* deletes the user's dynamic shapes on the first save.
//
// Every assertion below is on **bytes out of `XmlWriter`** or on **primitive counts out of
// `SceneBuilder`**. Neither "the pane exists" nor "the model was built" appears anywhere, because
// both pass against a feature wired to nothing; the defect class this port has hit twenty-five
// times.
//
// ── The red probe: what was PREDICTED, and what was MEASURED ─────────────────────────────────
//
// Two mutations, applied one at a time to the shipping source and reverted afterwards. The
// second matched the prediction; **the first did not, and the discrepancy is the interesting
// result**; it is recorded here rather than tidied away, because a test whose failure mode you
// have guessed wrong is a test you do not actually understand.
//
// MUTATION 1; `AppearanceEditorModel.reassembled()` drops the D8 verbatim splice.
//
//   PREDICTED: `d8VerbatimShapesSurviveAnEdit` goes red.
//   MEASURED: four tests go red, and `d8VerbatimShapesSurviveAnEdit` **passes**.
//
//     ✘ building the editor model and committing it leaves the bytes identical
//                                                       (before 1197B == after 1190B)
//     ✘ a move through Project.doAction lands in the saved bytes   (no x="80" in the output)
//     ✘ the edit is on the undo stack and undoes to the original bytes
//     ✘ consecutive moves of the same shapes coalesce into one undo entry
//     ✔ D8: an unmodelled <appear> child survives an edit and a save unchanged
//
//   The D8 element survives the mutation for a reason worth knowing: `CircuitAppearanceSvgSaver
//   .hasCustomAppearance` checks `shapes.count == childElementCount(of: raw)` and, seeing 4
//   against 5, **refuses the model and writes the original verbatim `<appear>` instead**. So the
//   unmodelled child is still there, and the user's *edit* is what was thrown away, silently.
//   That fidelity check is doing exactly the job its own header claims ("converts every future
//   parsing gap in this seam from silent data loss into a no-op"), and this run is the first
//   evidence of it firing.
//
//   The consequence for reading this suite: **`d8VerbatimShapesSurviveAnEdit` does not
//   discriminate the splice.** What catches a lost verbatim entry is the pair of byte tests,
//   because the fallback they trigger produces a *different* `<appear>` from the modelled one
//   (the model rewrites a pre-4.0 `circ-port` into 4.1.0's `dir`/`pin`/`x`/`y` spelling, and
//   re-layers the anchor). The D8 test's real content is narrower and still worth having: it
//   pins that the composed system, model, splice, fidelity check, writer, never destroys the
//   element by any route.
//
// MUTATION 2: `AppearanceTranslateAction.undo` translates by `+dx` instead of `-dx`.
//
//   PREDICTED and MEASURED alike:
//
//     ✘ the edit is on the undo stack and undoes to the original bytes  (1243B vs 1244B, x != 50)
//     ✘ consecutive moves of the same shapes coalesce into one undo entry  (x = 150, not 50)
// ═════════════════════════════════════════════════════════════════════════════════════════════

import CoreGraphics
import Foundation
import LogisimDraw
import LogisimFile
import LogisimKernel
import LogisimRender
import LogisimStd
import Testing

@testable import LogisimUI

// MARK: - Fixtures

private func corpusDirectory() -> URL? {
  guard let path = ProcessInfo.processInfo.environment["LOGISIM_CORPUS"] else { return nil }
  var isDirectory: ObjCBool = false
  guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
    isDirectory.boolValue
  else { return nil }
  return URL(fileURLWithPath: path)
}

/// Every `.circ` under the corpus whose bytes contain an `<appear` element, cheapest test first.
///
/// Reading the file to decide is deliberate: `Circuit.rawAppearance` is only populated *after* a
/// successful load, and a file that fails to load must not silently drop out of the sample and
/// make the gate look broader than it is.
private func corpusFilesWithAppearance(limit: Int) -> [URL] {
  guard let corpus = corpusDirectory() else { return [] }
  let all =
    (FileManager.default.enumerator(at: corpus, includingPropertiesForKeys: nil)?
    .compactMap { $0 as? URL }
    .filter { $0.pathExtension == "circ" }
    .sorted { $0.path < $1.path } ?? [])
  var hits: [URL] = []
  for url in all {
    guard let data = try? Data(contentsOf: url) else { continue }
    if data.range(of: Data("<appear".utf8)) != nil {
      hits.append(url)
      if hits.count >= limit { break }
    }
  }
  return hits
}

/// A circuit whose `<appear>` the reader actually parsed into shapes.
@MainActor
private func firstCustomAppearance(in file: LogisimFile) -> Circuit? {
  file.circuits.first { !CircuitAppearanceSeam.shapes(for: $0).isEmpty }
}

/// A hand-written file with one custom appearance holding a rect, a text, a port, an anchor:
/// and an `<unknown-shape>` child that nothing in this port models.
///
/// The synthetic fixture exists so the D8 assertion does not depend on the corpus being present:
/// exactly one harvested file (`4.1.0__case-406.circ`) carries a `visible-*` element,
/// so a corpus-only test for it would be one file wide and would silently pass as a skip on any
/// machine without the corpus.
private let d8Fixture = """
<?xml version="1.0" encoding="UTF-8" standalone="no"?>
<project source="4.1.0" version="1.0">
  <lib desc="#Wiring" name="0"/>
  <lib desc="#Base" name="1"/>
  <main name="main"/>
  <options>
    <a name="gateUndefined" val="ignore"/>
  </options>
  <circuit name="main">
    <a name="appearance" val="custom"/>
    <appear>
      <rect fill="none" height="60" stroke="#000000" stroke-width="2" width="90" x="50" y="50"/>
      <text font-family="SansSerif" font-size="12" x="95" y="85">sym</text>
      <unknown-shape flavour="apricot" x="7" y="9"/>
      <circ-anchor facing="east" height="6" width="6" x="47" y="47"/>
      <circ-port dir="in" height="8" pin="120,110" width="8" x="46" y="76"/>
    </appear>
    <comp lib="0" loc="(120,110)" name="Pin">
      <a name="appearance" val="classic"/>
      <a name="label" val="a"/>
    </comp>
  </circuit>
</project>

"""

@MainActor
private func loadFixture(_ text: String) throws -> (file: LogisimFile, loader: Loader, url: URL) {
  StdLibraries.registerAll()
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("appear-\(UUID().uuidString).circ")
  try Data(text.utf8).write(to: url)
  let loader = Loader()
  return (try loader.openLogisimFile(url), loader, url)
}

// MARK: - The gate

@Suite("Appearance round trip", .serialized)
struct AppearanceRoundTripTests {

  // MARK: 1 — the appearance renders at all

  @Test("a parsed <appear> produces scene primitives, not an empty scene")
  @MainActor
  func appearanceRenders() throws {
    let loaded = try loadFixture(d8Fixture)
    defer { try? FileManager.default.removeItem(at: loaded.url) }
    let circuit = try #require(firstCustomAppearance(in: loaded.file))

    let model = AppearanceEditorModel(circuit: circuit)
    let (build, _) = AppearanceSceneSource.build(
      shapes: model.drawing.objectsFromBottom, appearance: CanvasAppearance())

    // The discriminator between "a painter exists" and "a painter drew": `paintedShapeCount`
    // went to 2 the instant `AppearanceShapePainter` was called at all, so it is asserted
    // *alongside* the primitive count and never instead of it.
    #expect(model.sourceShapeCount == 5, "reader saw \(model.sourceShapeCount) children")
    #expect(build.shapes.count == 2, "rect + text should be the drawable set")
    #expect(build.paintedShapeCount == 2)
    #expect(build.scene.primitives.count > 0, "the scene is empty — nothing was drawn")
    #expect(build.portLocations.count == 1, "the circ-port should be surfaced as an anchor")
    #expect(build.anchorLocation != nil)
    #expect(!build.contentBounds.isNull)

    // D8, counted: `<unknown-shape>` is kept and is not drawable. The pane reports this number.
    let unmodelled = model.sourceShapeCount - model.drawing.objectsFromBottom.count
    #expect(unmodelled == 1, "the unrecognised child should be preserved-but-not-drawn")
  }

  // MARK: 2 — building the model changes nothing

  @Test("building the editor model and committing it leaves the bytes identical")
  @MainActor
  func modelIsByteNeutralOnTheFixture() throws {
    let baseline = try loadFixture(d8Fixture)
    defer { try? FileManager.default.removeItem(at: baseline.url) }
    let before = try #require(baseline.file.write(loader: baseline.loader))

    let subject = try loadFixture(d8Fixture)
    defer { try? FileManager.default.removeItem(at: subject.url) }
    let circuit = try #require(firstCustomAppearance(in: subject.file))
    let model = AppearanceEditorModel(circuit: circuit)
    model.commit()
    let after = try #require(subject.file.write(loader: subject.loader))

    #expect(
      before == after,
      """
      opening the appearance editor changed the saved bytes:
      before \(before.count)B / after \(after.count)B
      """)
  }

  /// Every `<appear>...</appear>` section of a saved document, concatenated, in document order.
  ///
  /// **Why the comparison is scoped to `<appear>` and not to the whole file, measured rather than
  /// assumed.** The first version of this test compared full bytes and reported 31 of 59 corpus
  /// files as failures, every one of them the *same length* before and after. The control -- two
  /// independent bare loads of the same file, with no editor model built at all -- reproduced it:
  ///
  ///     PROBE 2.7.1__case-507.circ: two bare loads agree = false
  ///       A   <main name="L_7474_df05ab63"/>
  ///       B   <main name="L_7474_55be9d45"/>
  ///     PROBE 2.7.1__case-192.circ: two bare loads agree = false
  ///       A   <a name="label" val="R0_1_03f15d07"/>
  ///       B   <a name="label" val="R0_1_af2bb9a1"/>
  ///
  /// Every difference is a **randomised name-collision suffix**, minted fresh on each load by the
  /// reader's uniquifier. It is pre-existing, it has nothing to do with the appearance model, and
  /// a whole-file comparison across two loads can therefore never pass on these files. Left as
  /// written, this test would have been 31 permanent red herrings attached to the wrong feature.
  ///
  /// The narrowed comparison is also the *better* instrument, not merely the passing one: the
  /// claim under test is "opening the appearance editor does not rewrite the appearance", and
  /// this measures exactly that, with none of the file's unrelated churn in the signal.
  private static func appearSections(_ data: Data) -> [String] {
    let text = String(decoding: data, as: UTF8.self)
    var sections: [String] = []
    var cursor = text.startIndex
    while let open = text.range(of: "<appear>", range: cursor..<text.endIndex),
      let close = text.range(of: "</appear>", range: open.upperBound..<text.endIndex)
    {
      sections.append(String(text[open.lowerBound..<close.upperBound]))
      cursor = close.upperBound
    }
    return sections
  }

  @Test("every corpus file's <appear> survives the model byte-identically")
  @MainActor
  func modelIsByteNeutralAcrossTheCorpus() throws {
    let files = corpusFilesWithAppearance(limit: 60)
    guard !files.isEmpty else {
      print("LOGISIM_CORPUS unset or has no <appear> files -- corpus round-trip skipped")
      return
    }
    StdLibraries.registerAll()

    var checked = 0
    var sectionsCompared = 0
    var mismatches: [String] = []
    for url in files {
      let baselineLoader = Loader()
      guard let baseline = try? baselineLoader.openLogisimFile(url),
        let before = baseline.write(loader: baselineLoader)
      else { continue }

      // A second, independent load: the model shares shape objects with
      // `CircuitAppearanceStore`, so reusing the first file would let a mutation from the model
      // reach the baseline bytes and hide exactly the defect this test is for.
      let subjectLoader = Loader()
      guard let subject = try? subjectLoader.openLogisimFile(url) else { continue }

      var touched = 0
      for circuit in subject.circuits where !CircuitAppearanceSeam.shapes(for: circuit).isEmpty {
        AppearanceEditorModel(circuit: circuit).commit()
        touched += 1
      }
      guard touched > 0 else { continue }
      checked += 1

      guard let after = subject.write(loader: subjectLoader) else {
        mismatches.append("\(url.lastPathComponent): re-save produced no bytes")
        continue
      }

      let a = Self.appearSections(before)
      let b = Self.appearSections(after)
      sectionsCompared += a.count
      if a.count != b.count {
        mismatches.append("\(url.lastPathComponent): \(a.count) <appear> in, \(b.count) out")
        continue
      }
      for (index, pair) in zip(a, b).enumerated() where pair.0 != pair.1 {
        mismatches.append(
          "\(url.lastPathComponent) <appear> #\(index):\n  bare  \(pair.0.prefix(300))"
            + "\n  model \(pair.1.prefix(300))")
      }
    }

    print(
      "appearance round-trip: \(checked) corpus files, \(sectionsCompared) <appear> sections "
        + "compared byte-for-byte")
    #expect(checked > 0, "no corpus file's <appear> parsed into shapes -- the seam may be off")
    #expect(sectionsCompared > 0, "no <appear> section reached the comparison")
    let report = mismatches.prefix(6).joined(separator: "\n")
    #expect(mismatches.isEmpty, "<appear> round-trip failures (\(mismatches.count)):\n\(report)")
  }


  // MARK: 3 — an edit is real, undoable, and D8-safe

  @Test("a move through Project.doAction lands in the saved bytes")
  @MainActor
  func anEditReachesTheFile() throws {
    let host = try #require(
      try LogisimFileProjectHostFactory().openProject(
        data: Data(d8Fixture.utf8), url: nil, contentType: LogisimDocumentType.circuit)
        as? LogisimFileProjectHost)

    let circuit = try #require(firstCustomAppearance(in: host.file))
    let model = AppearanceEditorModel(circuit: circuit)
    let rect = try #require(
      model.drawing.objectsFromBottom.first { $0 is DrawRectangle } as? DrawRectangle)
    #expect(rect.x == 50 && rect.y == 50)

    let before = try host.serialize()
    #expect(String(decoding: before, as: UTF8.self).contains("x=\"50\""))

    try host.project.doAction(
      AppearanceTranslateAction(model: model, shapes: [rect], dx: 30, dy: -20))

    // Observable state #1: the model moved.
    #expect(rect.x == 80 && rect.y == 30)

    // Observable state #2: the SAVED BYTES moved. This is the assertion that separates a real
    // edit from one that mutates a copy the writer never sees, which is precisely what happens
    // if `commit()` stops pushing the list back, since `hasCustomAppearance`'s fidelity check
    // then rejects the model and the verbatim element is written instead.
    let after = try host.serialize()
    let text = String(decoding: after, as: UTF8.self)
    #expect(text.contains("x=\"80\""), "the moved rectangle is not in the saved file")
    #expect(text.contains("y=\"30\""))
    #expect(before != after)
  }

  @Test("the edit is on the undo stack and undoes to the original bytes")
  @MainActor
  func anEditIsUndoableToTheOriginalBytes() throws {
    let host = try #require(
      try LogisimFileProjectHostFactory().openProject(
        data: Data(d8Fixture.utf8), url: nil, contentType: LogisimDocumentType.circuit)
        as? LogisimFileProjectHost)
    let circuit = try #require(firstCustomAppearance(in: host.file))
    let model = AppearanceEditorModel(circuit: circuit)
    let rect = try #require(
      model.drawing.objectsFromBottom.first { $0 is DrawRectangle } as? DrawRectangle)

    let before = try host.serialize()
    try host.project.doAction(
      AppearanceTranslateAction(model: model, shapes: [rect], dx: 30, dy: -20))
    #expect(host.project.canUndo, "the edit never reached the undo stack")

    try host.project.undoAction()
    let after = try host.serialize()

    #expect(rect.x == 50 && rect.y == 50)
    #expect(before == after, "undo did not restore the original bytes")
  }

  @Test("D8: an unmodelled <appear> child survives an edit and a save unchanged")
  @MainActor
  func d8VerbatimShapesSurviveAnEdit() throws {
    let host = try #require(
      try LogisimFileProjectHostFactory().openProject(
        data: Data(d8Fixture.utf8), url: nil, contentType: LogisimDocumentType.circuit)
        as? LogisimFileProjectHost)
    let circuit = try #require(firstCustomAppearance(in: host.file))
    let model = AppearanceEditorModel(circuit: circuit)
    let rect = try #require(
      model.drawing.objectsFromBottom.first { $0 is DrawRectangle } as? DrawRectangle)

    try host.project.doAction(
      AppearanceTranslateAction(model: model, shapes: [rect], dx: 30, dy: -20))
    let text = String(decoding: try host.serialize(), as: UTF8.self)

    // The whole D8 claim, in one line: the element this port cannot model is still there, with
    // its attributes, after an edit that rewrote the section around it.
    #expect(
      text.contains("<unknown-shape"),
      "the unmodelled element was destroyed by an edit — this is the D8 failure")
    #expect(text.contains("flavour=\"apricot\""))
    #expect(text.contains("<circ-port"), "the port element was lost")
    #expect(text.contains("<circ-anchor"), "the anchor element was lost")
  }

  // MARK: 3b — the pane can actually reach the circuit

  @Test("the real host satisfies AppearanceHosting, so the pane is not wired to nothing")
  @MainActor
  func theRealHostIsReachable() throws {
    let host = try #require(
      try LogisimFileProjectHostFactory().openProject(
        data: Data(d8Fixture.utf8), url: nil, contentType: LogisimDocumentType.circuit))

    // `CircuitAppearancePane` reaches the circuit by casting `EditorModel.host`, an
    // `any ProjectHost`, to `any AppearanceHosting`. That cast is the single point at which the
    // whole pane can be silently inert: it compiles either way, and a failed cast shows as an
    // empty "No Custom Appearance" screen rather than as an error. Nothing else in this suite
    // exercises it, because every other test constructs the model directly.
    let hosting = try #require(
      host as? any AppearanceHosting,
      "LogisimFileProjectHost no longer satisfies AppearanceHosting — the pane is inert")
    let circuit = try #require(hosting.appearanceCircuit, "the host exposes no current circuit")
    #expect(hosting.appearanceProject != nil, "the host exposes no project to submit actions to")

    // And that the circuit it exposes is the one with the appearance, not merely non-nil.
    let controller = AppearanceEditorController(host: hosting)
    #expect(circuit.name == "main")
    #expect(controller.hasCustomAppearance, "the controller found no appearance to edit")
    #expect(controller.build.scene.primitives.count > 0, "the controller built an empty scene")
    #expect(controller.unmodelledShapeCount == 1)
  }

  // MARK: 4 — coalescing, so a drag is one undo entry

  @Test("consecutive moves of the same shapes coalesce into one undo entry")
  @MainActor
  func consecutiveMovesCoalesce() throws {
    let host = try #require(
      try LogisimFileProjectHostFactory().openProject(
        data: Data(d8Fixture.utf8), url: nil, contentType: LogisimDocumentType.circuit)
        as? LogisimFileProjectHost)
    let circuit = try #require(firstCustomAppearance(in: host.file))
    let model = AppearanceEditorModel(circuit: circuit)
    let rect = try #require(
      model.drawing.objectsFromBottom.first { $0 is DrawRectangle } as? DrawRectangle)

    let before = try host.serialize()
    for _ in 0..<5 {
      try host.project.doAction(
        AppearanceTranslateAction(model: model, shapes: [rect], dx: 10, dy: 0))
    }
    #expect(rect.x == 100, "five moves of +10 should land at 50+50")

    // One undo, not five. Without `shouldAppendTo`/`append` this needs five, and a real drag
    // emits one action per mouse-moved sample, so Cmd-Z would rewind one mouse sample.
    try host.project.undoAction()
    #expect(rect.x == 50, "the five moves did not coalesce into one undo entry")
    #expect(try host.serialize() == before)
  }
}
