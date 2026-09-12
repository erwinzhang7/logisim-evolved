// LogisimUI -- part of logisim-evolved.
// Derived from logisim-evolution (com.cburch.logisim.gui.main.ExportImage), GPL-3.0-only.
// See LICENSE.md.
//
// Reference artifact: /Applications/Logisim-evolution.app/Contents/app/
// logisim-evolution-4.1.0-all.jar, inspected with javap -c -p (D16).
//
// ExportImage$ExportThread.export in 4.1.0 does the pixel-critical work:
//
//   * bounds are `circuit.getBounds(canvas.getGraphics()).expand(5)`;
//   * pixel dimensions are `Math.round(bounds.width * scale)` and the same for height;
//   * raster outputs are filled white before the circuit is drawn;
//   * the graphics context is scaled, translated by `-bounds.x/-bounds.y`, and then
//     `Circuit.draw(..., printerView)` is called;
//   * PNG and JPEG are written by `ImageIO.write`, while GIF uses `GifEncoder`.
//
// This port follows that shape with the retained-scene renderer and ImageIO's CGImage
// destinations. The AppKit panel is next door; the functions in this file are the part tests
// can exercise without putting a modal save panel on screen.

import CoreGraphics
import Foundation
import ImageIO
import LogisimFile
import LogisimKernel
import LogisimRender
import LogisimRenderBackend
import LogisimStd
import UniformTypeIdentifiers

enum ExportImageFormat: String, CaseIterable, Identifiable {
  case png
  case gif
  case jpeg

  var id: String { rawValue }

  static let defaultFormat: ExportImageFormat = .png

  var displayName: String {
    switch self {
    case .png: return "PNG"
    case .gif: return "GIF"
    case .jpeg: return "JPEG"
    }
  }

  var filenameExtension: String {
    switch self {
    case .png: return "png"
    case .gif: return "gif"
    case .jpeg: return "jpg"
    }
  }

  var acceptedExtensions: [String] {
    switch self {
    case .png: return ["png"]
    case .gif: return ["gif"]
    // 4.1.0's ImageFileFilter lists jpg/jpeg/jpe/jfi/jfif, with jfi repeated.
    case .jpeg: return ["jpg", "jpeg", "jpe", "jfi", "jfif"]
    }
  }

  var contentType: UTType {
    switch self {
    case .png: return .png
    case .gif: return .gif
    case .jpeg: return .jpeg
    }
  }

  func accepts(_ url: URL) -> Bool {
    acceptedExtensions.contains(url.pathExtension.lowercased())
  }
}

struct ExportImageSettings: Equatable {
  var format: ExportImageFormat = .defaultFormat
  var scale: Double = 1
  var printerView: Bool = true

  // 4.1.0: new JSlider(0, -18, 18, 0), getScale() = pow(2, value / 6.0).
  static let minimumSliderValue = -18
  static let maximumSliderValue = 18
  static let sliderDivisions = 6.0

  static func scale(forSliderValue value: Int) -> Double {
    pow(2.0, Double(value) / sliderDivisions)
  }

  static func nearestSliderValue(forScale scale: Double) -> Int {
    guard scale.isFinite, scale > 0 else { return 0 }
    let value = Int((log2(scale) * sliderDivisions).rounded())
    return min(max(value, minimumSliderValue), maximumSliderValue)
  }

  static func label(forScale scale: Double) -> String {
    "\(Int((100.0 * scale).rounded()))%"
  }
}

struct ExportedCircuitImage {
  var circuitName: String
  var format: ExportImageFormat
  var bounds: CGRect
  var pixelWidth: Int
  var pixelHeight: Int
  var paintedComponentCount: Int
  var primitiveCount: Int
  var data: Data
}

struct ExportImageWriteResult {
  var circuitName: String
  var url: URL
  var image: ExportedCircuitImage
}

enum ExportImageError: Error, LocalizedError {
  case noDrawableCircuits
  case noSelectedCircuits
  case invalidScale(Double)
  case imageTooLarge(width: Int, height: Int)
  case couldNotRender(String)
  case couldNotCreateDestination(ExportImageFormat)
  case couldNotEncode(ExportImageFormat)
  case couldNotCreateDirectory(URL)
  case destinationIsNotDirectory(URL)

  var errorDescription: String? {
    switch self {
    case .noDrawableCircuits:
      return "There are no non-empty circuits to export."
    case .noSelectedCircuits:
      return "No circuits were selected for export."
    case .invalidScale(let scale):
      return "The image scale \(scale) is not valid."
    case .imageTooLarge(let width, let height):
      return "The requested image is too large (\(width)x\(height) pixels)."
    case .couldNotRender(let name):
      return "Could not render '\(name)' for export."
    case .couldNotCreateDestination(let format):
      return "Could not create an ImageIO destination for \(format.displayName)."
    case .couldNotEncode(let format):
      return "Could not encode the image as \(format.displayName)."
    case .couldNotCreateDirectory(let url):
      return "Could not create the export directory at \(url.path)."
    case .destinationIsNotDirectory(let url):
      return "\(url.path) is not a directory."
    }
  }
}

struct ExportImageCircuit {
  var name: String
  var isSelectedByDefault: Bool

  private let renderImage: @MainActor (ExportImageSettings) throws -> ExportedCircuitImage

  init(
    name: String,
    isSelectedByDefault: Bool,
    renderImage: @escaping @MainActor (ExportImageSettings) throws -> ExportedCircuitImage
  ) {
    self.name = name
    self.isSelectedByDefault = isSelectedByDefault
    self.renderImage = renderImage
  }

  @MainActor
  func export(settings: ExportImageSettings) throws -> ExportedCircuitImage {
    try renderImage(settings)
  }
}

struct ExportImageJob {
  var settings: ExportImageSettings = ExportImageSettings()
  var circuits: [ExportImageCircuit]

  var defaultSelection: [Int] {
    let selected = circuits.indices.filter { circuits[$0].isSelectedByDefault }
    return selected.isEmpty && !circuits.isEmpty ? [circuits.startIndex] : selected
  }

  var defaultFilename: String {
    guard let index = defaultSelection.first else {
      return "circuit.\(settings.format.filenameExtension)"
    }
    return "\(circuits[index].name).\(settings.format.filenameExtension)"
  }

  @MainActor
  @discardableResult
  func write(
    selectedCircuitIndices indices: [Int],
    to destination: URL,
    settings requestedSettings: ExportImageSettings? = nil,
    fileManager: FileManager = .default
  ) throws -> [ExportImageWriteResult] {
    let chosen = indices.compactMap { index -> ExportImageCircuit? in
      guard circuits.indices.contains(index) else { return nil }
      return circuits[index]
    }
    guard !chosen.isEmpty else { throw ExportImageError.noSelectedCircuits }

    let settings = requestedSettings ?? self.settings
    if chosen.count > 1 {
      try ensureDirectory(at: destination, fileManager: fileManager)
    }

    var results: [ExportImageWriteResult] = []
    results.reserveCapacity(chosen.count)

    for circuit in chosen {
      let image = try circuit.export(settings: settings)
      let url =
        chosen.count == 1
        ? try singleCircuitDestination(
          destination, circuitName: circuit.name, format: settings.format, fileManager: fileManager)
        : destination.appendingPathComponent(
          "\(circuit.name).\(settings.format.filenameExtension)", isDirectory: false)
      try image.data.write(to: url, options: .atomic)
      results.append(ExportImageWriteResult(circuitName: circuit.name, url: url, image: image))
    }
    return results
  }

  private func ensureDirectory(at url: URL, fileManager: FileManager) throws {
    var isDirectory: ObjCBool = false
    if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
      guard isDirectory.boolValue else { throw ExportImageError.destinationIsNotDirectory(url) }
      return
    }
    do {
      try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    } catch {
      throw ExportImageError.couldNotCreateDirectory(url)
    }
  }

  private func singleCircuitDestination(
    _ destination: URL,
    circuitName: String,
    format: ExportImageFormat,
    fileManager: FileManager
  ) throws -> URL {
    var isDirectory: ObjCBool = false
    if fileManager.fileExists(atPath: destination.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    {
      return destination.appendingPathComponent(
        "\(circuitName).\(format.filenameExtension)", isDirectory: false)
    }
    return format.accepts(destination)
      ? destination
      : destination.appendingPathExtension(format.filenameExtension)
  }
}

struct CircuitExportImageScene {
  var scene: RenderScene
  var bounds: CGRect
  var paintedComponentCount: Int

  var primitiveCount: Int { scene.primitives.count }

  @MainActor
  static func build(
    circuit: Circuit,
    appearance: CanvasAppearance,
    printerView: Bool
  ) -> CircuitExportImageScene? {
    let box = circuit.bounds
    guard box != Bounds.empty, box.width > 0, box.height > 0 else { return nil }

    let builder = SceneBuilder(measurer: CoreTextMeasurer())
    let context = StaticPaintContext(
      showState: false,
      showColor: appearance.showsValueColours,
      isPrintView: printerView,
      gateShape: GateShape(rawValue: appearance.gateShape.rawValue) ?? .shaped,
      pinAppearance: .dotSmall,
      componentColor: .rgba(appearance.palette[.componentStroke].sceneRGBA))
    let painted = CircuitRenderer.render(circuit, into: builder, context: context)
    let expanded = box.expand(CircuitExportImage.margin)
    return CircuitExportImageScene(
      scene: builder.finish(),
      bounds: CGRect(
        x: CGFloat(expanded.x), y: CGFloat(expanded.y),
        width: CGFloat(expanded.width), height: CGFloat(expanded.height)),
      paintedComponentCount: painted)
  }
}

enum CircuitExportImage {
  static let margin = 5
  static let maximumPixelDimension = 20_000

  @MainActor
  static func export(
    circuit: Circuit,
    name: String? = nil,
    settings: ExportImageSettings = ExportImageSettings(),
    appearance: CanvasAppearance = CanvasAppearance()
  ) throws -> ExportedCircuitImage {
    guard settings.scale.isFinite, settings.scale > 0 else {
      throw ExportImageError.invalidScale(settings.scale)
    }
    guard let exportScene = CircuitExportImageScene.build(
      circuit: circuit, appearance: appearance, printerView: settings.printerView)
    else {
      throw ExportImageError.couldNotRender(name ?? circuit.name)
    }
    let image = try rasterize(exportScene, scale: settings.scale, appearance: appearance)
    let data = try encode(image, as: settings.format)
    return ExportedCircuitImage(
      circuitName: name ?? circuit.name,
      format: settings.format,
      bounds: exportScene.bounds,
      pixelWidth: image.width,
      pixelHeight: image.height,
      paintedComponentCount: exportScene.paintedComponentCount,
      primitiveCount: exportScene.primitiveCount,
      data: data)
  }

  @MainActor
  static func rasterize(
    _ exportScene: CircuitExportImageScene,
    scale: Double,
    appearance: CanvasAppearance
  ) throws -> CGImage {
    let width = Int((Double(exportScene.bounds.width) * scale).rounded())
    let height = Int((Double(exportScene.bounds.height) * scale).rounded())
    guard width > 0, height > 0 else {
      throw ExportImageError.imageTooLarge(width: width, height: height)
    }
    guard width < maximumPixelDimension, height < maximumPixelDimension else {
      throw ExportImageError.imageTooLarge(width: width, height: height)
    }
    guard let context = SceneRasterizer.makeContext(width: width, height: height) else {
      throw ExportImageError.couldNotRender("image")
    }
    let viewport = CircuitSceneRasterizer.viewport(
      worldRect: exportScene.bounds,
      scale: scale,
      backingScale: 1,
      pixelSize: CGSize(width: width, height: height))
    CoreGraphicsSceneRenderer().render(
      exportScene.scene,
      into: context,
      viewport: viewport,
      options: CircuitSceneRasterizer.options(for: appearance, opaque: true))
    guard let image = context.makeImage() else {
      throw ExportImageError.couldNotRender("image")
    }
    return image
  }

  static func encode(_ image: CGImage, as format: ExportImageFormat) throws -> Data {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
      data as CFMutableData,
      format.contentType.identifier as CFString,
      1,
      nil)
    else {
      throw ExportImageError.couldNotCreateDestination(format)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
      throw ExportImageError.couldNotEncode(format)
    }
    return data as Data
  }
}
