// LogChronogramView.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.gui.chrono.{ChronoPanel, LeftPanel,
// RightPanel, PopupMenu}), https://github.com/logisim-evolution/logisim-evolution. Copyright by
// the Logisim-evolution developers. This translation is a derivative work and is therefore
// GPL-3.0-only. See LICENSE.md.
// SPDX-License-Identifier: GPL-3.0-only
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── The timing diagram ──────────────────────────────────────────────────────────────────────
//
// This is the thing a student actually needs when a sequential circuit misbehaves: a picture of
// what every signal did, tick by tick, with a cursor that reads out the values at one instant.
//
// The *semantics* are upstream's and are ported faithfully:
//
//   * one-bit signals draw as a level, high at the top of the band and low at the bottom, with
//     a sloped transition when the run is wide enough to fit one (`RightPanel.Waveform`'s
//     `slope = tickWidth < 12 ? tickWidth/3 : 4`);
//   * multi-bit signals draw as a hexagonal band carrying the formatted value, crossing over at
//     each change: the standard bus notation;
//   * unknown (`X`) and error (`E`) fill the whole band rather than picking a level, because
//     neither is high or low;
//   * a spotlight row is drawn darker, and selected rows are tinted.
//
// The *rendering* is not upstream's. `RightPanel` keeps a `BufferedImage` per waveform, redraws
// into it on a listener callback, and blits; that cache exists because Swing repaints the whole
// component on every model event and Java2D cannot afford it. SwiftUI's `Canvas` already
// coalesces and clips, and the geometry here is a handful of line segments per run, so the
// cache would be pure liability; a second copy of the truth that goes stale.
//
// Colours come from `CircuitPalette`, the same table the schematic canvas uses, so "green means
// high" is the same green in both places and both follow Dark Mode. That is upstream issue
// #2661 avoided rather than inherited: `Value.java` resolves its colours into static fields at
// class-init time and can never follow an appearance change.

import AppKit
import LogisimKernel
import SwiftUI

/// Layout constants. Upstream's, in points rather than pixels.
enum ChronoMetrics {
  /// `ChronoPanel.SIGNAL_HEIGHT`.
  static let rowHeight: CGFloat = 30
  /// `ChronoPanel.GAP`: the inset from the row band to the drawn high/low levels.
  static let gap: CGFloat = 5
  /// `ChronoPanel.HEADER_HEIGHT`, the time ruler.
  static let headerHeight: CGFloat = 22
  /// `RightPanel.EXTRA_SPACE`; trailing room so the newest edge is not flush with the border.
  static let trailingSpace: CGFloat = 40
  /// `RightPanel.TIMELINE_SPACING`: minimum points between two ruler labels.
  static let rulerSpacing: CGFloat = 80
  /// `ChronoPanel.INITIAL_SPLIT`: width of the name column.
  static let nameColumnWidth: CGFloat = 180
}

/// The timing diagram.
struct LogChronogramView: View {
  @Bindable var controller: LogController
  @Environment(\.colorScheme) private var colorScheme

  private var model: LogModel { controller.model }

  private var palette: CircuitPalette {
    colorScheme == .dark ? .dark : .light
  }

  /// Display points per simulated nanosecond.
  private var scale: Double {
    let timeScale = max(model.timeScale, 1)
    return controller.pointsPerTick / Double(timeScale)
  }

  private var visibleStart: Int64 { model.startTime }
  private var visibleEnd: Int64 { max(model.endTime, model.startTime + 1) }

  private var diagramWidth: CGFloat {
    CGFloat(Double(visibleEnd - visibleStart) * scale) + ChronoMetrics.trailingSpace
  }

  var body: some View {
    if model.rows.isEmpty {
      ContentUnavailableView {
        Label("No signals logged", systemImage: "waveform.slash")
      } description: {
        Text("Add pins, LEDs or clocks from the sidebar to see their timing.")
      }
    } else {
      HStack(spacing: 0) {
        nameColumn
        Divider()
        ScrollView([.horizontal], showsIndicators: true) {
          diagram
            .frame(width: max(diagramWidth, 1))
        }
        .defaultScrollAnchor(.trailing)
      }
      // `revision` is read so SwiftUI re-renders when the plain model changes; see
      // `LogController.revision`.
      .id(controller.revision)
    }
  }

  // MARK: - The fixed name column (upstream's LeftPanel)

  private var nameColumn: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(LogDurationFormat.string(for: controller.effectiveCursorTime))
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .frame(height: ChronoMetrics.headerHeight, alignment: .leading)
        .padding(.horizontal, 8)

      ForEach(model.rows) { row in
        HStack(spacing: 6) {
          VStack(alignment: .leading, spacing: 1) {
            Text(row.info.shortName)
              .font(.system(size: 11, weight: .medium))
              .lineLimit(1)
              .truncationMode(.middle)
            Text(controller.formattedValueAtCursor(row))
              .font(.system(size: 10, design: .monospaced))
              .foregroundStyle(.secondary)
          }
          Spacer(minLength: 0)
          if model.clockSource === row.info {
            Image(systemName: "metronome")
              .font(.system(size: 9))
              .foregroundStyle(.tertiary)
              .help("Clock source")
          }
        }
        .padding(.horizontal, 8)
        .frame(height: ChronoMetrics.rowHeight)
        .background(controller.selection.contains(row.id) ? Color.accentColor.opacity(0.18) : .clear)
        .contentShape(.rect)
        .onTapGesture { toggle(row) }
        .onHover { model.spotlight = $0 ? row : (model.spotlight === row ? nil : model.spotlight) }
        .contextMenu { radixMenu(for: row) }
      }
      Spacer(minLength: 0)
    }
    .frame(width: ChronoMetrics.nameColumnWidth)
  }

  private func radixMenu(for row: LogRow) -> some View {
    Group {
      Picker("Radix", selection: radixBinding(for: row)) {
        ForEach(LogRadix.allCases, id: \.self) { radix in
          Text(radix.displayName).tag(radix)
        }
      }
      Divider()
      Button("Remove", systemImage: "minus.circle") {
        model.remove([row.info])
      }
    }
  }

  private func radixBinding(for row: LogRow) -> Binding<LogRadix> {
    Binding(
      get: { row.info.radix },
      set: { model.setRadix($0, for: row.info) }
    )
  }

  private func toggle(_ row: LogRow) {
    if controller.selection.contains(row.id) {
      controller.selection.remove(row.id)
    } else {
      controller.selection.insert(row.id)
    }
  }

  // MARK: - The waveforms (upstream's RightPanel)

  private var diagram: some View {
    Canvas { context, size in
      drawRuler(in: &context, size: size)
      for row in model.rows {
        drawRow(row, in: &context, size: size)
      }
      drawCursor(in: &context, size: size)
    }
    .frame(height: ChronoMetrics.headerHeight + CGFloat(model.rows.count) * ChronoMetrics.rowHeight)
    .contentShape(.rect)
    .gesture(
      DragGesture(minimumDistance: 0)
        .onChanged { value in
          controller.cursorTime = time(atX: value.location.x)
        }
    )
  }

  private func x(forTime t: Int64) -> CGFloat {
    CGFloat(Double(t - visibleStart) * scale)
  }

  private func time(atX x: CGFloat) -> Int64 {
    let raw = Double(x) / max(scale, .leastNonzeroMagnitude)
    return min(max(visibleStart + Int64(raw), visibleStart), visibleEnd - 1)
  }

  /// The time ruler. Upstream's `Timeline` picks the largest power-of-ten multiple of the time
  /// scale whose spacing exceeds `TIMELINE_SPACING`; the same rule is used here so the labels
  /// land on tick boundaries rather than on arbitrary round numbers of nanoseconds.
  private func drawRuler(in context: inout GraphicsContext, size: CGSize) {
    var step = max(model.timeScale, 1)
    while CGFloat(Double(step) * scale) < ChronoMetrics.rulerSpacing {
      step *= 2
      if step > Int64.max / 4 { break }
    }

    let baseline = ChronoMetrics.headerHeight
    context.stroke(
      Path { $0.move(to: CGPoint(x: 0, y: baseline)); $0.addLine(to: CGPoint(x: size.width, y: baseline)) },
      with: .color(palette[.gridLine].color),
      lineWidth: 1)

    var t = visibleStart - (visibleStart % step)
    while t < visibleEnd {
      let px = x(forTime: t)
      if px >= 0 {
        context.stroke(
          Path {
            $0.move(to: CGPoint(x: px, y: baseline - 5))
            $0.addLine(to: CGPoint(x: px, y: baseline))
          },
          with: .color(palette[.gridLine].color), lineWidth: 1)
        context.draw(
          Text(LogDurationFormat.string(for: t))
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(.secondary),
          at: CGPoint(x: px + 3, y: baseline - 9),
          anchor: .leading)
      }
      t += step
    }
  }

  private func drawRow(_ row: LogRow, in context: inout GraphicsContext, size: CGSize) {
    let top = ChronoMetrics.headerHeight + CGFloat(row.index) * ChronoMetrics.rowHeight
    let band = CGRect(x: 0, y: top, width: size.width, height: ChronoMetrics.rowHeight)

    if controller.selection.contains(row.id) {
      context.fill(Path(band), with: .color(Color.accentColor.opacity(0.12)))
    } else if model.spotlight === row {
      context.fill(Path(band), with: .color(Color.primary.opacity(0.06)))
    }

    context.stroke(
      Path {
        $0.move(to: CGPoint(x: 0, y: band.maxY))
        $0.addLine(to: CGPoint(x: size.width, y: band.maxY))
      },
      with: .color(palette[.gridLine].color.opacity(0.4)), lineWidth: 0.5)

    let high = top + ChronoMetrics.gap
    let low = top + ChronoMetrics.rowHeight - ChronoMetrics.gap
    let mid = (high + low) / 2
    // `RightPanel`: slope narrows when a tick is too small to fit the standard 4-point ramp.
    let slope: CGFloat =
      controller.pointsPerTick < 12 ? CGFloat(controller.pointsPerTick / 3) : 4

    var t = row.history.timeStart
    var previousWasHigh: Bool?

    for run in row.history.allRuns {
      let x0 = x(forTime: t)
      let x1 = x(forTime: t + run.duration)
      t += run.duration
      if x1 < 0 { previousWasHigh = nil; continue }
      if x0 > size.width { break }

      let value = run.value.extendWidth(row.info.width, .falseValue)
      drawRun(
        value: value,
        row: row,
        x0: x0, x1: x1, high: high, low: low, mid: mid, slope: min(slope, max((x1 - x0) / 2, 0)),
        previousWasHigh: previousWasHigh,
        in: &context)
      previousWasHigh = value == .trueValue ? true : (value == .falseValue ? false : nil)
    }
  }

  private func drawRun(
    value: Value,
    row: LogRow,
    x0: CGFloat, x1: CGFloat,
    high: CGFloat, low: CGFloat, mid: CGFloat,
    slope: CGFloat,
    previousWasHigh: Bool?,
    in context: inout GraphicsContext
  ) {
    let stroke = palette[.stroke].color
    let width = max(row.info.width, 1)

    // Error and unknown fill the whole band: neither is a level.
    if value.hasErrorBits {
      fillBand(x0: x0, x1: x1, high: high, low: low, colour: palette[.error].color, in: &context)
      label(row.info.format(value), x0: x0, x1: x1, mid: mid, in: &context)
      return
    }
    if value.hasUnknownBits {
      fillBand(x0: x0, x1: x1, high: high, low: low, colour: palette[.unknown].color, in: &context)
      label(row.info.format(value), x0: x0, x1: x1, mid: mid, in: &context)
      return
    }

    if width == 1 {
      let isHigh = value == .trueValue
      let level = isHigh ? high : low
      var path = Path()
      if let previousWasHigh, previousWasHigh != isHigh {
        // Sloped transition, as `RightPanel.Waveform` draws it.
        path.move(to: CGPoint(x: x0, y: previousWasHigh ? high : low))
        path.addLine(to: CGPoint(x: x0 + slope, y: level))
        path.addLine(to: CGPoint(x: x1, y: level))
      } else {
        path.move(to: CGPoint(x: x0, y: level))
        path.addLine(to: CGPoint(x: x1, y: level))
      }
      context.stroke(
        path,
        with: .color(isHigh ? palette[.trueValue].color : palette[.falseValue].color),
        lineWidth: 2)
      return
    }

    // A bus: a hexagon crossing over at each end, with the value inside.
    var hexagon = Path()
    hexagon.move(to: CGPoint(x: x0, y: mid))
    hexagon.addLine(to: CGPoint(x: x0 + slope, y: high))
    hexagon.addLine(to: CGPoint(x: max(x1 - slope, x0 + slope), y: high))
    hexagon.addLine(to: CGPoint(x: x1, y: mid))
    hexagon.addLine(to: CGPoint(x: max(x1 - slope, x0 + slope), y: low))
    hexagon.addLine(to: CGPoint(x: x0 + slope, y: low))
    hexagon.closeSubpath()
    context.fill(hexagon, with: .color(palette[.bus].color.opacity(0.22)))
    context.stroke(hexagon, with: .color(palette[.bus].color), lineWidth: 1.5)
    _ = stroke
    label(row.info.format(value), x0: x0, x1: x1, mid: mid, in: &context)
  }

  private func fillBand(
    x0: CGFloat, x1: CGFloat, high: CGFloat, low: CGFloat, colour: Color,
    in context: inout GraphicsContext
  ) {
    let rect = CGRect(x: x0, y: high, width: max(x1 - x0, 1), height: low - high)
    context.fill(Path(rect), with: .color(colour.opacity(0.55)))
    context.stroke(Path(rect), with: .color(colour), lineWidth: 1)
  }

  /// Draws a value label centred in its run, but only when it fits: upstream measures the
  /// string and omits it otherwise rather than letting it spill into the neighbouring run.
  private func label(
    _ text: String, x0: CGFloat, x1: CGFloat, mid: CGFloat, in context: inout GraphicsContext
  ) {
    let available = x1 - x0 - 6
    guard available > 12 else { return }
    let resolved = context.resolve(
      Text(text).font(.system(size: 10, design: .monospaced)).foregroundStyle(.primary))
    guard resolved.measure(in: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)).width
      <= available
    else { return }
    context.draw(resolved, at: CGPoint(x: (x0 + x1) / 2, y: mid), anchor: .center)
  }

  private func drawCursor(in context: inout GraphicsContext, size: CGSize) {
    let px = x(forTime: controller.effectiveCursorTime)
    context.stroke(
      Path {
        $0.move(to: CGPoint(x: px, y: 0))
        $0.addLine(to: CGPoint(x: px, y: size.height))
      },
      with: .color(Color.accentColor),
      lineWidth: 1)
  }
}

// MARK: - Value classification
//
// `RightPanel` tests one-bit values against the `Value.TRUE`/`FALSE`/`UNKNOWN`/`ERROR`
// singletons. Generalised to buses, the question a waveform asks is "can this be drawn as a
// level?", which is `isFullyDefined()`. The two planes are public on `Value`, so no string
// round-trip is needed: `error != 0` is any bit in error, and a defined value has neither plane
// set.

extension Value {
  /// Any bit in error, draw a red band.
  fileprivate var hasErrorBits: Bool { error != 0 }

  /// No error, but at least one floating bit, draw an orange band.
  fileprivate var hasUnknownBits: Bool { error == 0 && unknown != 0 }
}
