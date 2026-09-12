// LogisimUI: part of logisim-evolved.
// Derived from logisim-evolution (com.cburch.logisim.gui.main.Print), GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// THE PLATFORM SHELL; deliberately the thinnest file in this directory.
//
// `Print.doPrint` is `PrinterJob.getPrinterJob()`, `job.setPrintable(print, format)`,
// `job.printDialog()`, `job.print()`. On macOS that is `NSPrintOperation`, and the panel,
// the paper, the margins, the orientation and the page range all belong to `NSPrintInfo`,
// which is why upstream's `ParmsPanel` has no paper controls either.
//
// **Nothing in this file is asserted on by a test, on purpose.** A test that checks "an
// `NSPrintOperation` was constructed" passes against a version that prints a blank page; that is
// the exact false green this board warned about. Everything that decides what lands on the paper
// is in `PrintPageLayout`, `PrintHeaderFormat` and `CircuitPrintScene`, all three of which are
// pure and are tested against an offscreen bitmap. This file only forwards.
//
// ── Upstream's `ParmsPanel` is not reproduced as a modal ────────────────────────────────────
//
// Its four controls are the circuit list, the header template, "rotate to fit" and "printer
// view". The first is `NSPrintPanel`'s job on a Mac and the last three are `PrintJobSettings`
// below, with upstream's own seeded defaults (`Print.java:209-214`: rotate ON, printer view ON,
// header `"%n (%p of %P)"`). Wiring them to an accessory view on `NSPrintPanel` is a UI task
// that changes none of the arithmetic; the defaults are what upstream ships pre-selected.

import AppKit
import CoreGraphics
import Foundation
import LogisimFile

/// `ParmsPanel`'s three values, with upstream's seeded defaults.
struct PrintJobSettings: Equatable {
  /// `header.setText("%n (%p of %P)")`. Empty means "no header line", matching
  /// `header != null && !header.isEmpty()`.
  var headerTemplate: String = PrintHeaderFormat.defaultTemplate
  /// `rotateToFit.setSelected(true)`.
  var rotateToFit: Bool = true
  /// `printerView.setSelected(true)`.
  var printerView: Bool = true
}

/// One circuit destined for one page, carrying the **already-built scene** rather than the
/// `Circuit` it came from.
///
/// That shape is not incidental. `ProjectSeam.swift:8` states the invariant plainly: the shell
/// "never sees a `Circuit`, a `Component`, an `AttributeSet` or a `CircuitState`", and Print is
/// shell code, so a `func printablePages() -> [(name, Circuit)]` on `ProjectHost` would have put
/// the model back through the façade the façade exists to prevent. The host builds the scenes
/// because the host is the side that legitimately holds the model; what crosses the seam is a
/// `RenderScene`, which is a value type and is exactly what D6 says the boundary carries.
public struct PrintableCircuit {
  public var name: String
  var scene: CircuitPrintScene

  init(name: String, scene: CircuitPrintScene) {
    self.name = name
    self.scene = scene
  }
}

/// Everything a print run needs, gathered by `EditorModel.printJob()` before any panel appears.
public struct PrintJob {
  var settings: PrintJobSettings
  var circuits: [PrintableCircuit]
  var appearance: CanvasAppearance
}

/// The `Printable`: one circuit per page, no tiling, exactly as `MyPrintable` does.
@MainActor
final class CircuitPrintView: NSView {

  private let pages: [CircuitPrintScene]
  private let names: [String]
  private let settings: PrintJobSettings
  /// Named `canvasAppearance` because `NSView.appearance` is `NSAppearance?` and cannot be
  /// shadowed by a stored property of another type.
  private let canvasAppearance: CanvasAppearance
  private let pageSize: CGSize
  private let metrics = PrintPageMetrics.standard()

  init(
    circuits: [PrintableCircuit],
    settings: PrintJobSettings,
    appearance: CanvasAppearance,
    printInfo: NSPrintInfo
  ) {
    self.pages = circuits.map(\.scene)
    self.names = circuits.map(\.name)
    self.settings = settings
    self.canvasAppearance = appearance
    self.pageSize = printInfo.imageablePageBounds.size
    super.init(
      frame: CGRect(
        x: 0, y: 0,
        width: pageSize.width,
        height: pageSize.height * CGFloat(Swift.max(circuits.count, 1))))
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  override func knowsPageRange(_ range: NSRangePointer) -> Bool {
    range.pointee = NSRange(location: 1, length: max(pages.count, 1))
    return true
  }

  /// Page `i` (1-based) is the `i`-th slice from the TOP of an unflipped view.
  override func rectForPage(_ page: Int) -> NSRect {
    CGRect(
      x: 0,
      y: bounds.height - CGFloat(page) * pageSize.height,
      width: pageSize.width,
      height: pageSize.height)
  }

  override func draw(_ dirtyRect: NSRect) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    let pageNumber = NSPrintOperation.current?.currentPage ?? 1
    let index = pageNumber - 1
    // `if (pageIndex >= circuits.size()) return Printable.NO_SUCH_PAGE;`
    guard index >= 0, index < pages.count else { return }

    let header =
      settings.headerTemplate.isEmpty
      ? nil
      : PrintHeaderFormat.format(
        settings.headerTemplate, index: pageNumber, max: pages.count,
        circuitName: names[index])

    CircuitPrintPage.draw(
      pages[index],
      into: context,
      imageable: rectForPage(pageNumber),
      header: header,
      rotateToFit: settings.rotateToFit,
      appearance: canvasAppearance,
      metrics: metrics)
  }
}

/// `Print.doPrint(Project)`.
enum CircuitPrintCommand {

  /// Puts up the standard print panel and prints. Returns `false` when there is nothing to
  /// print, upstream's `printEmptyCircuitsMessage` case, or when the user cancels.
  @discardableResult
  @MainActor
  static func run(
    circuits: [PrintableCircuit],
    settings: PrintJobSettings = PrintJobSettings(),
    appearance: CanvasAppearance,
    printInfo: NSPrintInfo = NSPrintInfo.shared,
    window: NSWindow? = nil
  ) -> Bool {
    guard !circuits.isEmpty else { return false }
    let view = CircuitPrintView(
      circuits: circuits, settings: settings, appearance: appearance, printInfo: printInfo)
    let operation = NSPrintOperation(view: view, printInfo: printInfo)
    operation.jobTitle = circuits.count == 1 ? circuits[0].name : "Circuits"
    if let window {
      operation.runModal(
        for: window, delegate: nil, didRun: nil, contextInfo: nil)
      return true
    }
    return operation.run()
  }
}
