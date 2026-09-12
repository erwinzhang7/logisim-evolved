// SubcircuitPaintDump; the "look at it" half of the gate.
//
// Asserts nothing: it rasterises one named circuit out of one named `.circ` to a PNG so the
// result can be put beside the same file opened in the 4.1.0 jar. An inked-pixel count proves
// a canvas is not blank; only a human looking at the two images proves it is a *schematic*.
//
// Inert unless DUMP_CIRC and DUMP_OUT are set, so it costs the suite nothing.

import CoreGraphics
import Foundation
import ImageIO
import LogisimFile
import LogisimKernel
import LogisimRender
import LogisimRenderBackend
import LogisimStd
import Testing

@testable import LogisimUI

@Suite("Subcircuit paint — visual dump")
struct SubcircuitPaintDumpTests {

  @Test("dump one circuit to a PNG")
  @MainActor
  func dump() throws {
    let environment = ProcessInfo.processInfo.environment
    guard let path = environment["DUMP_CIRC"], let out = environment["DUMP_OUT"] else { return }

    StdLibraries.registerAll()
    let file = try Loader().openLogisimFile(URL(fileURLWithPath: path))
    let name = environment["DUMP_CIRCUIT"]
    let circuit = try #require(
      file.circuits.first { name == nil || $0.name == name } ?? file.circuits.first)

    let appearance = CanvasAppearance()
    let build = CircuitSceneSource.build(circuit: circuit, appearance: appearance)
    print(
      "DUMP \(circuit.name): components=\(circuit.components.count) "
        + "painted=\(build.paintedComponentCount) primitives=\(build.scene.primitives.count)")

    let world = build.contentBounds.insetBy(dx: -20, dy: -20)
    guard
      let image = CircuitSceneRasterizer.image(
        build: build, worldRect: world, scale: 2, appearance: appearance),
      let destination = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: out) as CFURL, "public.png" as CFString, 1, nil)
    else { return }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    print("DUMP wrote \(out)")
  }
}
