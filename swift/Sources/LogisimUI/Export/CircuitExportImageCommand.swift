// LogisimUI -- part of logisim-evolved.
// Derived from logisim-evolution (com.cburch.logisim.gui.main.ExportImage), GPL-3.0-only.
// See LICENSE.md.
//
// The platform shell. 4.1.0 uses a Swing options dialog followed by JFileChooser; on macOS the
// native equivalent is an NSSavePanel with an accessory view. Tests do not present this file's
// panel. They exercise ExportImageJob/CircuitExportImage directly and, for the command join,
// install a temporary runner.

import AppKit
import Foundation

@MainActor
enum CircuitExportImageCommand {
  typealias Runner = @MainActor (ExportImageJob) throws -> Bool

  private static var runnerOverride: Runner?

  @discardableResult
  static func run(job: ExportImageJob) throws -> Bool {
    if let runnerOverride {
      return try runnerOverride(job)
    }
    guard !job.circuits.isEmpty else { return false }
    return try ExportImagePanel(job: job).run()
  }

  static func withRunnerForTesting<T>(
    _ runner: @escaping Runner,
    body: () throws -> T
  ) rethrows -> T {
    precondition(runnerOverride == nil, "nested export image runner overrides are not supported")
    runnerOverride = runner
    defer { runnerOverride = nil }
    return try body()
  }
}

@MainActor
private final class ExportImagePanel {
  private let job: ExportImageJob
  private let accessory: ExportImageAccessoryController
  private let panel = NSSavePanel()

  init(job: ExportImageJob) {
    self.job = job
    self.accessory = ExportImageAccessoryController(job: job)
  }

  func run() throws -> Bool {
    panel.title = "Export Image"
    panel.prompt = "Export"
    panel.canCreateDirectories = true
    panel.allowedContentTypes = ExportImageFormat.allCases.map(\.contentType)
    panel.nameFieldStringValue = job.defaultFilename
    panel.accessoryView = accessory.view

    guard panel.runModal() == .OK, let url = panel.url else { return false }
    let settings = accessory.settings
    return try !job.write(
      selectedCircuitIndices: accessory.selectedCircuitIndices,
      to: url,
      settings: settings
    ).isEmpty
  }
}

@MainActor
private final class ExportImageAccessoryController: NSViewController {
  private let job: ExportImageJob
  private let formatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
  private let scaleSlider = NSSlider(
    value: 0,
    minValue: Double(ExportImageSettings.minimumSliderValue),
    maxValue: Double(ExportImageSettings.maximumSliderValue),
    target: nil,
    action: nil)
  private let scaleLabel = NSTextField(labelWithString: "100%")
  private let printerView = NSButton(checkboxWithTitle: "", target: nil, action: nil)
  private var circuitButtons: [NSButton] = []

  init(job: ExportImageJob) {
    self.job = job
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  override func loadView() {
    formatPopup.addItems(withTitles: ExportImageFormat.allCases.map(\.displayName))
    formatPopup.selectItem(withTitle: job.settings.format.displayName)
    formatPopup.target = self
    formatPopup.action = #selector(optionsChanged)

    let sliderValue = ExportImageSettings.nearestSliderValue(forScale: job.settings.scale)
    scaleSlider.integerValue = sliderValue
    scaleSlider.numberOfTickMarks =
      ExportImageSettings.maximumSliderValue - ExportImageSettings.minimumSliderValue + 1
    scaleSlider.allowsTickMarkValuesOnly = true
    scaleSlider.target = self
    scaleSlider.action = #selector(optionsChanged)
    scaleLabel.alignment = .right
    scaleLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true

    printerView.state = job.settings.printerView ? .on : .off

    let root = NSStackView()
    root.orientation = .vertical
    root.alignment = .leading
    root.spacing = 8
    root.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)

    root.addArrangedSubview(row(label: "Format:", control: formatPopup))
    root.addArrangedSubview(scaleRow())
    root.addArrangedSubview(row(label: "Printer view:", control: printerView))

    if job.circuits.count > 1 {
      root.addArrangedSubview(circuitList())
    }

    view = root
    updateScaleLabel()
  }

  var settings: ExportImageSettings {
    var value = job.settings
    value.format =
      ExportImageFormat.allCases.first { $0.displayName == formatPopup.titleOfSelectedItem }
      ?? .defaultFormat
    value.scale = ExportImageSettings.scale(forSliderValue: scaleSlider.integerValue)
    value.printerView = printerView.state == .on
    return value
  }

  var selectedCircuitIndices: [Int] {
    guard !circuitButtons.isEmpty else { return job.defaultSelection }
    return circuitButtons.indices.filter { circuitButtons[$0].state == .on }
  }

  @objc private func optionsChanged() {
    updateScaleLabel()
  }

  private func updateScaleLabel() {
    scaleLabel.stringValue = ExportImageSettings.label(forScale: settings.scale)
  }

  private func row(label: String, control: NSView) -> NSStackView {
    let labelView = NSTextField(labelWithString: label)
    labelView.alignment = .right
    labelView.widthAnchor.constraint(equalToConstant: 92).isActive = true

    let row = NSStackView(views: [labelView, control])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 8
    return row
  }

  private func scaleRow() -> NSStackView {
    scaleSlider.widthAnchor.constraint(equalToConstant: 180).isActive = true
    let controls = NSStackView(views: [scaleSlider, scaleLabel])
    controls.orientation = .horizontal
    controls.alignment = .centerY
    controls.spacing = 8
    return row(label: "Scale:", control: controls)
  }

  private func circuitList() -> NSView {
    let defaultSelection = Set(job.defaultSelection)
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 4

    circuitButtons = job.circuits.enumerated().map { index, circuit in
      let button = NSButton(checkboxWithTitle: circuit.name, target: nil, action: nil)
      button.state = defaultSelection.contains(index) ? .on : .off
      stack.addArrangedSubview(button)
      return button
    }

    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.borderType = .bezelBorder
    scroll.documentView = stack
    scroll.widthAnchor.constraint(equalToConstant: 280).isActive = true
    scroll.heightAnchor.constraint(equalToConstant: min(144, CGFloat(job.circuits.count * 24))).isActive =
      true
    return row(label: "Circuits:", control: scroll)
  }
}
