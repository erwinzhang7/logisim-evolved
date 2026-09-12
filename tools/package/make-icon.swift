#!/usr/bin/env swift
//
// make-icon.swift: generates logisim-evolved's app and document icons.
//
// Part of logisim-evolved. Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// ── Why this file exists rather than a checked-in .icns ────────────────────────────────
//
// D10 requires this port to ship its **own icon**: a derivative work must not present
// itself as the original, and upstream's `support/jpackage/macos/Logisim-evolution.icns`
// is upstream's mark. D12 separately records that upstream ships artwork whose rights are
// not clean; inheriting any of it would import that problem. So the icon is drawn here,
// from scratch, in code, which also makes it reviewable as a diff instead of as an
// opaque 1.6 MB binary, and reproducible from a fresh clone with no design tool.
//
// Deterministic: same source, same bytes out. Nothing here reads the clock, the locale,
// the user's appearance setting, or any system font; the glyph is pure geometry, because
// a font would make the output depend on which macOS drew it.
//
// Usage: swift tools/package/make-icon.swift <output-dir>
// Writes: <output-dir>/logisim-evolved.icns          (app)
//         <output-dir>/logisim-evolved-circuit.icns  (.circ document)
//
import AppKit
import CoreGraphics
import Foundation

// MARK: - Palette
//
// Chosen to be unmistakably *not* upstream's icon at a glance in a Dock full of apps.
// Values are literal so the icon cannot drift with a system accent colour.

let fieldTop = CGColor(red: 0.204, green: 0.259, blue: 0.541, alpha: 1)  // indigo
let fieldBottom = CGColor(red: 0.114, green: 0.153, blue: 0.357, alpha: 1)  // deeper indigo
let inkColor = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
let paperColor = CGColor(red: 0.976, green: 0.976, blue: 0.980, alpha: 1)
let paperEdge = CGColor(red: 0.741, green: 0.753, blue: 0.788, alpha: 1)
let foldColor = CGColor(red: 0.878, green: 0.886, blue: 0.910, alpha: 1)

// MARK: - The mark
//
// An AND gate with two inputs and one output, drawn in unit coordinates on [0,1]².
// It is filled rather than stroked: at 16 pt a 1 px outline disappears, and an icon that
// only reads at 512 is not an icon. Wires are strokes because they must stay wires.

/// Fills the gate body; a "D" shape: flat left edge, semicircular right cap.
func gateBodyPath(in unit: CGRect) -> CGPath {
  func x(_ u: CGFloat) -> CGFloat { unit.minX + u * unit.width }
  func y(_ v: CGFloat) -> CGFloat { unit.minY + v * unit.height }

  let left = x(0.32), straightRight = x(0.52)
  let top = y(0.255), bottom = y(0.745)
  let radius = (bottom - top) / 2
  let capCentre = CGPoint(x: straightRight, y: (top + bottom) / 2)

  let path = CGMutablePath()
  path.move(to: CGPoint(x: left, y: bottom))
  path.addLine(to: CGPoint(x: straightRight, y: bottom))
  path.addArc(
    center: capCentre, radius: radius,
    startAngle: .pi / 2, endAngle: -.pi / 2, clockwise: true)
  path.addLine(to: CGPoint(x: left, y: top))
  path.closeSubpath()
  return path
}

/// The three wires. Returned separately so they can be stroked, not filled.
func wirePaths(in unit: CGRect) -> CGPath {
  func x(_ u: CGFloat) -> CGFloat { unit.minX + u * unit.width }
  func y(_ v: CGFloat) -> CGFloat { unit.minY + v * unit.height }

  let path = CGMutablePath()
  // Inputs, entering the flat edge at the canonical 1/3 and 2/3 heights of the body.
  // Spread wide and kept thin: at the previous 0.075 width and 0.395/0.605 spacing the
  // three wires and the body fused into one silhouette that read as a wall plug.
  for v in [0.365, 0.635] as [CGFloat] {
    path.move(to: CGPoint(x: x(0.13), y: y(v)))
    path.addLine(to: CGPoint(x: x(0.33), y: y(v)))
  }
  // Output, leaving the cap.
  path.move(to: CGPoint(x: x(0.71), y: y(0.50)))
  path.addLine(to: CGPoint(x: x(0.91), y: y(0.50)))
  return path
}

func drawMark(in ctx: CGContext, unit: CGRect, colour: CGColor) {
  ctx.saveGState()
  ctx.setFillColor(colour)
  ctx.addPath(gateBodyPath(in: unit))
  ctx.fillPath()

  ctx.setStrokeColor(colour)
  ctx.setLineWidth(unit.width * 0.052)
  ctx.setLineCap(.round)
  ctx.addPath(wirePaths(in: unit))
  ctx.strokePath()
  ctx.restoreGState()
}

// MARK: - Shapes

/// macOS app icons are a rounded square on a ~0.8 inset of the canvas, corner radius
/// ≈ 22.37 % of the square's side. Both figures are from Apple's macOS icon grid.
func roundedSquarePath(_ rect: CGRect) -> CGPath {
  CGPath(roundedRect: rect, cornerWidth: rect.width * 0.2237, cornerHeight: rect.height * 0.2237,
    transform: nil)
}

func drawAppIcon(size: CGFloat, into ctx: CGContext) {
  let side = size * 0.80
  let field = CGRect(x: (size - side) / 2, y: (size - side) / 2, width: side, height: side)

  ctx.saveGState()
  ctx.addPath(roundedSquarePath(field))
  ctx.clip()
  let space = CGColorSpaceCreateDeviceRGB()
  let gradient = CGGradient(
    colorsSpace: space, colors: [fieldTop, fieldBottom] as CFArray, locations: [0, 1])!
  ctx.drawLinearGradient(
    gradient, start: CGPoint(x: field.minX, y: field.maxY),
    end: CGPoint(x: field.maxX, y: field.minY), options: [])
  ctx.restoreGState()

  drawMark(in: ctx, unit: field, colour: inkColor)
}

func drawDocumentIcon(size: CGFloat, into ctx: CGContext) {
  // A portrait page with a folded top-right corner, carrying the same mark in the field
  // colour. Distinct from the app icon at a glance, which is the whole point: Finder shows
  // both, and a document that looks like its application is a usability bug.
  let pageWidth = size * 0.62
  let pageHeight = size * 0.78
  let page = CGRect(
    x: (size - pageWidth) / 2, y: (size - pageHeight) / 2,
    width: pageWidth, height: pageHeight)
  let fold = pageWidth * 0.26

  let body = CGMutablePath()
  body.move(to: CGPoint(x: page.minX, y: page.minY))
  body.addLine(to: CGPoint(x: page.maxX, y: page.minY))
  body.addLine(to: CGPoint(x: page.maxX, y: page.maxY - fold))
  body.addLine(to: CGPoint(x: page.maxX - fold, y: page.maxY))
  body.addLine(to: CGPoint(x: page.minX, y: page.maxY))
  body.closeSubpath()

  ctx.setFillColor(paperColor)
  ctx.addPath(body)
  ctx.fillPath()

  ctx.setStrokeColor(paperEdge)
  ctx.setLineWidth(max(size * 0.006, 0.75))
  ctx.addPath(body)
  ctx.strokePath()

  let foldTriangle = CGMutablePath()
  foldTriangle.move(to: CGPoint(x: page.maxX - fold, y: page.maxY))
  foldTriangle.addLine(to: CGPoint(x: page.maxX - fold, y: page.maxY - fold))
  foldTriangle.addLine(to: CGPoint(x: page.maxX, y: page.maxY - fold))
  foldTriangle.closeSubpath()
  ctx.setFillColor(foldColor)
  ctx.addPath(foldTriangle)
  ctx.fillPath()
  ctx.setStrokeColor(paperEdge)
  ctx.addPath(foldTriangle)
  ctx.strokePath()

  // The mark sits in the lower two-thirds, inset from the page edges.
  let markSide = pageWidth * 0.82
  let mark = CGRect(
    x: page.midX - markSide / 2, y: page.minY + pageHeight * 0.12,
    width: markSide, height: markSide)
  drawMark(in: ctx, unit: mark, colour: fieldBottom)
}

// MARK: - Rasterisation

func render(size: Int, _ draw: (CGFloat, CGContext) -> Void) -> Data {
  let space = CGColorSpaceCreateDeviceRGB()
  guard
    let ctx = CGContext(
      data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
  else { fatalError("could not create a \(size)×\(size) bitmap context") }

  ctx.setAllowsAntialiasing(true)
  ctx.interpolationQuality = .high
  draw(CGFloat(size), ctx)

  guard let image = ctx.makeImage() else { fatalError("could not snapshot the \(size) px context") }
  let rep = NSBitmapImageRep(cgImage: image)
  rep.size = NSSize(width: size, height: size)
  guard let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("could not PNG-encode the \(size) px image")
  }
  return png
}

/// The ten members `iconutil` requires. Omitting one produces an `.icns` that silently
/// falls back to a scaled neighbour in some Finder views, which reads as a blurry icon.
let iconSetMembers: [(name: String, pixels: Int)] = [
  ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
  ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
  ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
  ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
  ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

func buildICNS(named name: String, in outputDir: URL, draw: (CGFloat, CGContext) -> Void) throws {
  let fm = FileManager.default
  let iconset = outputDir.appendingPathComponent("\(name).iconset")
  try? fm.removeItem(at: iconset)
  try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

  for member in iconSetMembers {
    let png = render(size: member.pixels, draw)
    try png.write(to: iconset.appendingPathComponent(member.name))
  }

  let icns = outputDir.appendingPathComponent("\(name).icns")
  let task = Process()
  task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
  task.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
  try task.run()
  task.waitUntilExit()
  guard task.terminationStatus == 0 else {
    fatalError("iconutil failed with status \(task.terminationStatus)")
  }
  try fm.removeItem(at: iconset)

  // Assert the oracle produced output. A generator that writes nothing and exits 0 is
  // indistinguishable from success until someone looks at the Dock.
  let bytes = (try fm.attributesOfItem(atPath: icns.path)[.size] as? Int) ?? 0
  guard bytes > 4096 else { fatalError("\(icns.path) is \(bytes) bytes — that is not an icon") }
  FileHandle.standardError.write(Data("  icon: \(icns.lastPathComponent) (\(bytes) bytes)\n".utf8))
}

// MARK: - Entry point

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
  FileHandle.standardError.write(Data("usage: make-icon.swift <output-dir>\n".utf8))
  exit(2)
}
let outputDir = URL(fileURLWithPath: arguments[1])
try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

try buildICNS(named: "logisim-evolved", in: outputDir) { size, ctx in
  drawAppIcon(size: size, into: ctx)
}
try buildICNS(named: "logisim-evolved-circuit", in: outputDir) { size, ctx in
  drawDocumentIcon(size: size, into: ctx)
}
