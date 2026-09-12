// LogisimUITests -- part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// File > Export Image, without an NSSavePanel. The command shell is native AppKit and deliberately
// thin; these tests assert the exported bytes decode to the dimensions and pixels the 4.1.0
// ExportImage path specifies.

import CoreGraphics
import Foundation
import ImageIO
import LogisimFile
import LogisimKernel
import LogisimRenderBackend
import LogisimStd
import Testing
import UniformTypeIdentifiers

@testable import LogisimUI

private let exportCommandFixture = """
  <?xml version="1.0" encoding="UTF-8" standalone="no"?>
  <project source="4.1.0" version="1.0">
    <lib desc="#Base" name="0"/>
    <lib desc="#Wiring" name="1"/>
    <lib desc="#Gates" name="2"/>
    <main name="alpha"/>
    <circuit name="alpha">
      <wire from="(0,0)" to="(40,0)"/>
    </circuit>
    <circuit name="beta">
      <wire from="(0,0)" to="(0,40)"/>
    </circuit>
  </project>
  """

@Suite("Export Image -- encoded bytes and command join", .serialized)
struct ExportImageTests {

  @Test("export image settings match the 4.1.0 raster defaults")
  func exportImageSettingsMatch410RasterDefaults() {
    #expect(ExportImageFormat.allCases.map(\.displayName) == ["PNG", "GIF", "JPEG"])
    #expect(ExportImageSettings().format == .png)
    #expect(ExportImageSettings().scale == 1)
    #expect(ExportImageSettings().printerView)
    #expect(ExportImageSettings.scale(forSliderValue: -18) == 0.125)
    #expect(ExportImageSettings.scale(forSliderValue: 0) == 1)
    #expect(ExportImageSettings.scale(forSliderValue: 18) == 8)
    #expect(ExportImageSettings.label(forScale: 1) == "100%")
  }

  @Test("a PNG export decodes to the expanded bounds at the requested scale and contains ink")
  @MainActor
  func pngExportDecodesToScaledBoundsAndContainsInk() throws {
    let circuit = try wireCircuit(name: "alpha", end: Location.create(40, 0, hasToSnap: false))
    var appearance = CanvasAppearance()
    appearance.antialiasing = false

    var settings = ExportImageSettings()
    settings.scale = 1.5
    let exported = try CircuitExportImage.export(
      circuit: circuit, settings: settings, appearance: appearance)

    #expect(exported.bounds == CGRect(x: -5, y: -5, width: 51, height: 11))
    #expect(exported.pixelWidth == 77)
    #expect(exported.pixelHeight == 17)
    #expect(exported.primitiveCount > 0)

    let image = try decodedImage(exported.data)
    #expect(image.width == 77)
    #expect(image.height == 17)

    let bitmap = try #require(bitmapOf(image))
    #expect(whitePixelCount(bitmap) > bitmap.width * bitmap.height / 2)
    #expect(darkPixelCount(bitmap) > 20, "exported image decoded, but it has no dark ink")
  }

  @Test("every raster format writes bytes that ImageIO can decode")
  @MainActor
  func everyRasterFormatDecodes() throws {
    let circuit = try wireCircuit(name: "alpha", end: Location.create(40, 0, hasToSnap: false))

    for format in ExportImageFormat.allCases {
      var settings = ExportImageSettings()
      settings.format = format
      let exported = try CircuitExportImage.export(circuit: circuit, settings: settings)
      let image = try decodedImage(exported.data)
      #expect(image.width == exported.pixelWidth, "\(format.displayName) width did not survive")
      #expect(image.height == exported.pixelHeight, "\(format.displayName) height did not survive")
      #expect(exported.data.count > 0, "\(format.displayName) wrote no bytes")
    }
  }

  /// **THE LOAD-BEARING ONE.** The only thing standing between the user and Export Image
  /// silently writing a screen-mode picture when they ticked "printer view".
  ///
  /// ── WHAT CARRIES THE DIFFERENCE FOR THIS FIXTURE, MEASURED ────────────────────────────────
  ///
  /// The fixture is one unconnected shaped AND gate and nothing else. Its whole scene is two
  /// primitives, a stroked `arc` (the curved right face) and a stroked `polyline` (the three
  /// straight sides), plus one marker per port. `isPrintView` changes exactly one thing for it:
  /// `AbstractGate.paintInstance:612` skips `drawPorts()` unless the gate is drawn in the
  /// rectangular shape. `PainterShaped.paintInputLines` does not apply; only OR/NOR call it.
  ///
  /// So for this fixture the print/screen difference is carried **entirely by the port markers**,
  /// which is exactly why it is worth keeping: it is the narrowest possible test of that one
  /// branch.
  ///
  /// ── WHY THIS NO LONGER COMPARES INK TOTALS ────────────────────────────────────────────────
  ///
  /// It used to assert `printInk < screenInk`, and that quietly assumed a port marker *adds*
  /// ink. It did, while the marker was a filled black disc: 474 dark pixels on screen against
  /// 454 on paper, +20 for three discs. Once `SceneBuilder.drawPinMarker` became a ring the
  /// assumption failed; not because print view broke, but because a ring both adds and removes.
  /// Decomposed at this exact viewport (60×60, scale 1, antialiasing off):
  ///
  /// | scene                                        | dark pixels |
  /// |----------------------------------------------|-------------|
  /// | gate alone (= what print view emits)          | 454         |
  /// | gate + the three white holes                  | 412         |
  /// | gate + the three stroked rims                 | 488         |
  /// | gate + both, i.e. the ring                    | **454**     |
  ///
  /// Every port of a shaped AND gate sits ON its outline, so each hole erases 14 pixels of a
  /// 2-unit stroke (42 in all) and each rim paints them back (42 in all, of which 8 already
  /// coincided with the outline). Net zero; the two views were reported as identical by a
  /// measure that had never been looking at the right thing. The pictures are plainly different:
  /// 68 pixels differ, 34 in each direction.
  ///
  /// A dark-pixel total is a lossy summary of an image, and "print view emits less ink" was
  /// never the claim. The claim is in the test's name, the flag changes the encoded pixels, so
  /// that is what is asserted now, alongside the structural fact that the flag reached the
  /// painters at all. The *direction* of the ink change is still gated, on a fixture where it
  /// cannot cancel: `PrintTests.printSceneDiffersInPixels` uses an OR gate whose unconnected
  /// input leads print view drops outright, and dropped lines are pure subtraction.
  @Test("the printer-view flag changes the encoded pixels")
  @MainActor
  func printerViewFlagChangesEncodedPixels() throws {
    let circuit = try unconnectedGateCircuit()
    var appearance = CanvasAppearance()
    appearance.antialiasing = false

    var screenSettings = ExportImageSettings()
    screenSettings.printerView = false
    let screen = try CircuitExportImage.export(
      circuit: circuit, settings: screenSettings, appearance: appearance)

    var printSettings = ExportImageSettings()
    printSettings.printerView = true
    let printed = try CircuitExportImage.export(
      circuit: circuit, settings: printSettings, appearance: appearance)

    #expect(screen.pixelWidth == printed.pixelWidth)
    #expect(screen.pixelHeight == printed.pixelHeight)

    // 1. The flag reached the painters. Equal counts mean it reached nothing, which is the
    //    failure a pixel comparison alone cannot name.
    #expect(
      printed.primitiveCount < screen.primitiveCount,
      """
      printer view emitted \(printed.primitiveCount) primitives and screen view \
      \(screen.primitiveCount). Equal means `isPrintView` never reached `AbstractGate`.
      """)

    // 2. …and it survived to the encoded bytes, which is the whole point of asserting on the
    //    decoded image rather than on the scene.
    let screenBitmap = try #require(bitmapOf(decodedImage(screen.data)))
    let printBitmap = try #require(bitmapOf(decodedImage(printed.data)))
    #expect(darkPixelCount(printBitmap) > 0, "printer-view export is blank")

    let differing = differingPixelCount(screenBitmap, printBitmap)
    // A floor, not `> 0`: one stray pixel would satisfy "the images differ" while the printer
    // view was in every meaningful way the screen view.
    //
    // Expressed as a rate per suppressed marker, and set low enough to survive the marker being
    // restyled, which is the mistake this whole file is here to stop repeating. Measured at
    // this viewport: 4.1.0's filled disc gives 20 differing pixels, the ring gives 68. Four per
    // marker clears both by a wide margin and is still an order of magnitude above "a stray
    // pixel". Raising it to hug whichever marker ships today would make a styling change look
    // like a print-view regression, exactly as the old ink-total assertion did.
    let suppressedMarkers = 3
    #expect(
      differing >= suppressedMarkers * 4,
      """
      only \(differing) pixels differ between the printer-view and screen-view exports. The \
      fixture's ONLY print/screen difference is its \(suppressedMarkers) port markers \
      (`AbstractGate.paintInstance:612`), so this means they are being drawn on paper too.
      """)
  }

  @Test("several selected circuits export to a directory as named image files")
  @MainActor
  func severalCircuitsExportToDirectory() throws {
    let alpha = try wireCircuit(name: "alpha", end: Location.create(40, 0, hasToSnap: false))
    let beta = try wireCircuit(name: "beta", end: Location.create(0, 40, hasToSnap: false))
    let job = ExportImageJob(
      circuits: [
        exportCircuit(alpha, selected: true),
        exportCircuit(beta, selected: false),
      ])
    let directory = temporaryURL("export-directory")

    let results = try job.write(selectedCircuitIndices: [0, 1], to: directory)

    #expect(results.map(\.url.lastPathComponent).sorted() == ["alpha.png", "beta.png"])
    for result in results {
      let data = try Data(contentsOf: result.url)
      let image = try decodedImage(data)
      #expect(image.width == result.image.pixelWidth)
      #expect(image.height == result.image.pixelHeight)
    }
  }

  @Test("performing exportImage reaches the non-modal runner and writes image bytes")
  @MainActor
  func exportImageCommandReachesRunnerAndWritesBytes() throws {
    let host = try LogisimFileProjectHostFactory().openProject(
      data: Data(exportCommandFixture.utf8),
      url: nil,
      contentType: LogisimDocumentType.circuit)
    let model = EditorModel(host: host)
    let destination = temporaryURL("command-export")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    var wrote: [ExportImageWriteResult] = []

    try CircuitExportImageCommand.withRunnerForTesting(
      { job in
        wrote = try job.write(selectedCircuitIndices: job.defaultSelection, to: destination)
        return true
      },
      body: {
        model.perform(.exportImage)
      })

    #expect(model.transientError == nil, "export reported: \(model.transientError ?? "")")
    #expect(!model.issues.contains { $0.title == "Command unavailable" })
    let result = try #require(wrote.first)
    #expect(result.circuitName == "alpha")
    let image = try decodedImage(try Data(contentsOf: result.url))
    #expect(image.width == result.image.pixelWidth)
    #expect(image.height == result.image.pixelHeight)
    #expect(darkPixelCount(try #require(bitmapOf(image))) > 20)
  }
}

@MainActor
private func wireCircuit(name: String, end: Location) throws -> Circuit {
  StdLibraries.registerAll()
  let circuit = try Circuit(name: name)
  try circuit.mutatorAdd(Wire.create(Location.create(0, 0, hasToSnap: false), end))
  return circuit
}

@MainActor
private func unconnectedGateCircuit() throws -> Circuit {
  StdLibraries.registerAll()
  let circuit = try Circuit(name: "gate")
  let attributes = AndGate.factory.createAttributeSet()
  let component = try AndGate.factory.createComponent(
    location: Location.create(120, 100, hasToSnap: false),
    attributes: attributes)
  try circuit.mutatorAdd(component)
  return circuit
}

@MainActor
private func exportCircuit(_ circuit: Circuit, selected: Bool) -> ExportImageCircuit {
  ExportImageCircuit(name: circuit.name, isSelectedByDefault: selected) { settings in
    try CircuitExportImage.export(circuit: circuit, settings: settings)
  }
}

private func temporaryURL(_ name: String) -> URL {
  FileManager.default.temporaryDirectory
    .appendingPathComponent("logisim-export-image-\(UUID().uuidString)", isDirectory: true)
    .appendingPathComponent(name)
}

private func decodedImage(_ data: Data) throws -> CGImage {
  let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
  return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
}

private func whitePixelCount(_ bitmap: SceneBitmap) -> Int {
  var count = 0
  for y in 0..<bitmap.height {
    for x in 0..<bitmap.width {
      let p = bitmap.pixel(x: x, y: y)
      if p.r == 255 && p.g == 255 && p.b == 255 && p.a == 255 { count += 1 }
    }
  }
  return count
}

/// Pixels whose colour differs between two same-sized rasters.
///
/// The measure `printerViewFlagChangesEncodedPixels` needs and a dark-pixel *total* cannot give:
/// two pictures can carry identical amounts of ink in visibly different places. Mismatched sizes
/// return `-1` rather than trapping, so a size regression fails that test's floor loudly instead
/// of crashing the process.
private func differingPixelCount(_ a: SceneBitmap, _ b: SceneBitmap) -> Int {
  guard a.width == b.width, a.height == b.height else { return -1 }
  var count = 0
  for y in 0..<a.height {
    for x in 0..<a.width {
      let p = a.pixel(x: x, y: y)
      let q = b.pixel(x: x, y: y)
      if p.r != q.r || p.g != q.g || p.b != q.b || p.a != q.a { count += 1 }
    }
  }
  return count
}

private func darkPixelCount(_ bitmap: SceneBitmap) -> Int {
  var count = 0
  for y in 0..<bitmap.height {
    for x in 0..<bitmap.width {
      let p = bitmap.pixel(x: x, y: y)
      if p.a > 0 && bitmap.luminance(x: x, y: y) < 128 { count += 1 }
    }
  }
  return count
}

private func bitmapOf(_ image: CGImage) -> SceneBitmap? {
  let width = image.width
  let height = image.height
  guard let space = CGColorSpace(name: CGColorSpace.sRGB),
    let context = CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: width * 4,
      space: space,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        | CGBitmapInfo.byteOrder32Big.rawValue)
  else { return nil }
  context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
  guard let base = context.data else { return nil }
  let buffer = UnsafeRawBufferPointer(start: base, count: context.bytesPerRow * height)
  return SceneBitmap(width: width, height: height, bytesPerRow: context.bytesPerRow, pixels: Array(buffer))
}
