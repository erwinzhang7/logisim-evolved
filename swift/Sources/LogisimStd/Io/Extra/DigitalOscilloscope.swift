// DigitalOscilloscope.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.io.extra.DigitalOscilloscope),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// A scrolling logic-analyzer: N input probes plus a clock, enable and clear pin, sampling every
// input on each clock edge into `DiagramState`. All of the *sampling* logic is `propagate`'s, not
// `paintInstance`'s, the paint routine only ever reads what `propagate` already wrote, so this
// file ports every bit of `propagate` and none of the drawing.
//
// ── What did not come across ─────────────────────────────────────────────────────────────────
//
//   (`paintInstance` IS ported; see the Paint section at the end of this file. Upstream declares
//   no `paintGhost` for this component.)
//   * `setKeyConfigurator`, UI.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

/// `DigitalOscilloscope.NO` / `TRIG_RISING` / `TRIG_FALLING` / `BOTH`: `VERT_LINE`'s options.
/// Paint-only upstream (which clock-edge front lines to draw); kept for attribute round-tripping.
public enum OscilloscopeFrontLines: String, AttributeOptionValue, CaseIterable, Sendable {
  case no
  case rising
  case falling
  case both
  public static var attributeOptions: [OscilloscopeFrontLines] { Array(allCases) }
}

/// `com.cburch.logisim.std.io.extra.DigitalOscilloscope`.
public final class DigitalOscilloscope: InstanceFactoryBase {

  public static let id = "Digital Oscilloscope"

  public static let attrInputs: Attribute<Int32> = Attributes.forIntegerRange(
    "inputs", start: 1, end: 32)
  public static let attrStateCount: Attribute<Int32> = Attributes.forIntegerRange(
    "nState", start: 4, end: 35)
  public static let attrFrontLines: Attribute<OscilloscopeFrontLines> = Attributes.forOption(
    "frontlines")
  public static let attrShowClock: Attribute<Bool> = Attributes.forBoolean("showclock")
  public static let attrColor: Attribute<ColorSpec> = Attributes.forColor("color")

  private static let border = 10

  public init() {
    super.init(DigitalOscilloscope.id, displayName: "Digital oscilloscope")
    setAttributes([
      DigitalOscilloscope.attrInputs.binding(3),
      DigitalOscilloscope.attrStateCount.binding(10),
      DigitalOscilloscope.attrFrontLines.binding(.rising),
      DigitalOscilloscope.attrShowClock.binding(true),
      DigitalOscilloscope.attrColor.binding(ColorSpec(red: 0, green: 208, blue: 208)),
      StdAttr.label.binding(""),
      stdAttrLabelLocation.binding(.north),
      StdAttr.labelFont.binding(StdAttr.defaultLabelFont),
    ])
  }

  private static func diagramState(for state: any InstanceState) -> DiagramState {
    let inputs = Int(state.attributeValue(DigitalOscilloscope.attrInputs, default: 3)) + 1
    let length = Int(state.attributeValue(DigitalOscilloscope.attrStateCount, default: 10)) * 2
    if let existing = state.data as? DiagramState {
      existing.updateSize(inputs: inputs, length: length)
      return existing
    }
    let fresh = DiagramState(inputs: inputs, length: length)
    state.setData(fresh)
    return fresh
  }

  public override func ports(_ attributes: any AttributeSet) -> [Port] {
    let inputs = Int(attributes.getValue(DigitalOscilloscope.attrInputs) ?? 3)
    var ports: [Port] = []
    ports.reserveCapacity(inputs + 3)
    for i in 0...inputs {
      ports.append(Port(0, 30 * i, .input, 1))
    }
    ports.append(Port(20, 30 * inputs + 2 * DigitalOscilloscope.border, .input, 1))  // enable
    ports.append(Port(30, 30 * inputs + 2 * DigitalOscilloscope.border, .input, 1))  // clear
    return ports
  }

  public override func offsetBounds(_ attributes: any AttributeSet) -> Bounds {
    let border = DigitalOscilloscope.border
    let stateCount = Int(attributes.getValue(DigitalOscilloscope.attrStateCount) ?? 10)
    let inputCount = Int(attributes.getValue(DigitalOscilloscope.attrInputs) ?? 3)
    let showClock = attributes.getValue(DigitalOscilloscope.attrShowClock) ?? true
    let width = stateCount * 30 + 2 * border + 15
    let height = showClock ? (inputCount + 1) * 30 + 3 * border + 2 : inputCount * 30 + 3 * border
    let showClockOffset = showClock ? 32 : 0
    return Bounds.create(0, -border - showClockOffset, width, height)
  }

  public override func propagate(_ state: any InstanceState) throws {
    let inputs = Int(state.attributeValue(DigitalOscilloscope.attrInputs, default: 3)) + 1
    let length = Int(state.attributeValue(DigitalOscilloscope.attrStateCount, default: 10)) * 2
    let clock = state.portValue(0)
    let enable = state.portValue(inputs)
    let clear = state.portValue(inputs + 1)
    let diagram = DigitalOscilloscope.diagramState(for: state)

    if clock != .unknownValue && clear != .trueValue && enable != .falseValue {
      let lastClock = diagram.setLastClock(clock)
      if lastClock != .unknownValue {
        if lastClock != clock {
          if diagram.usedCell < length - 1 {
            diagram.setUsedCell(diagram.usedCell + 1)
          }
          if diagram.moveBack {
            diagram.moveBackAll()
            if clock == .trueValue {
              diagram.setClockNumber(diagram.clockNumber + 1)
            }
          }
          if diagram.usedCell == length - 1 { diagram.setMoveBack(true) }
          for i in 0..<inputs {
            let v = state.portValue(i)
            diagram.setState(i, diagram.usedCell, v == .trueValue ? true : (v == .falseValue ? false : nil))
          }
        } else if diagram.usedCell != -1 {
          for i in 1..<inputs {
            let v = state.portValue(i)
            diagram.setState(i, diagram.usedCell, v == .trueValue ? true : (v == .falseValue ? false : nil))
          }
        }
      }
    } else if clear == .trueValue {
      diagram.clear()
      diagram.setUsedCell(-1)
      _ = diagram.setLastClock(.unknownValue)
      diagram.setMoveBack(false)
      diagram.setClockNumber(length / 2)
    }
  }

  // MARK: - Paint (D6)

  /// The paint-path twin of `diagramState(for:)`.
  private static func diagramState(painting painter: any IoInstancePainter) -> DiagramState {
    let inputs = Int(painter.attributeValue(DigitalOscilloscope.attrInputs, default: 3)) + 1
    let length = Int(painter.attributeValue(DigitalOscilloscope.attrStateCount, default: 10)) * 2
    if let existing = painter.data as? DiagramState {
      existing.updateSize(inputs: inputs, length: length)
      return existing
    }
    let fresh = DiagramState(inputs: inputs, length: length)
    painter.setData(fresh)
    return fresh
  }

  /// `paintInstance(InstancePainter)`: `DigitalOscilloscope.java:150-294`.
  ///
  /// The scrolling trace grid: a coloured rounded body, a white plot area, optional dashed
  /// vertical lines at clock edges, then one row per input made of horizontal 1/0 runs joined by
  /// vertical transitions, plus a right-pointing arrow per row and clock-cycle numbers along the
  /// top.
  ///
  /// Everything is 15 units per half-cycle and 30 per row; `showclock` is used as an **integer**
  /// (0 or 1) and appears in the arithmetic as `showclock * 2`, i.e. showing the clock nudges
  /// every row down by exactly two units on top of giving it its own row. Transcribed with the
  /// same `Int` so those two uses stay distinguishable.
  ///
  /// A `nil` cell, a sample that was neither TRUE nor FALSE, draws nothing at all, so an
  /// unconnected probe leaves a gap rather than a line. Both the transition test and the run
  /// tests exclude it, which is why the `nil` checks cannot be collapsed into the equality.
  public func paintInstance(_ painter: any IoInstancePainter) {
    let border = DigitalOscilloscope.border
    let baseColor = painter.componentColor
    let bds = painter.bounds
    let showclock = painter.attributeValue(DigitalOscilloscope.attrShowClock, default: true) ? 1 : 0
    let x = bds.x
    let y = bds.y
    let width = bds.width
    let height = bds.height
    let inputs = Int(painter.attributeValue(DigitalOscilloscope.attrInputs, default: 3)) + showclock
    let length = Int(painter.attributeValue(DigitalOscilloscope.attrStateCount, default: 10)) * 2
    let diagram = DigitalOscilloscope.diagramState(painting: painter)
    let g = painter.scene

    let color = painter.attributeValue(
      DigitalOscilloscope.attrColor, default: DigitalOscilloscope.defaultColor)
    let frontLines = painter.attributeValue(DigitalOscilloscope.attrFrontLines, default: .rising)

    painter.drawRoundBounds(bds, .attribute(color))

    g.color = .white
    g.fillRoundRect(
      x + border, y + border, width - 2 * border, height - 2 * border, border / 2, border / 2)

    if frontLines != .no {
      g.color = .attribute(color.darker)
      // `new BasicStroke(0.5f, CAP_ROUND, JOIN_ROUND, 0, {6, 4}, 8)`.
      //
      // ── SceneBuilder gap, reported ── `StrokePen.width` is a `UInt8` of whole scene units, so
      // the 0.5 cannot be expressed. `0` is the closest available meaning ("the thinnest line
      // the device can draw", Java's own `BasicStroke(0)`), and at every zoom the reference
      // renders 0.5 at, that is one device pixel too. Everything else about the pen, round cap,
      // round join, the 6-on/4-off dash and its phase of 8, carries across exactly.
      g.withPen(
        StrokePen(width: 0, cap: .round, join: .round, dashOn: 6, dashOff: 4, dashPhase: 8)
      ) {
        for j in 1..<max(length, 1) {
          let now = diagram.state(0, j)
          let prev = diagram.state(0, j - 1)
          let rising = (frontLines == .rising || frontLines == .both) && now == true && prev == false
          let falling =
            (frontLines == .falling || frontLines == .both) && now == false && prev == true
          if rising || falling {
            g.drawLine(x + border + 15 * j, y + border, x + border + 15 * j, y + height - border)
          }
        }
      }
    }

    var nck = length / 2
    g.font = SceneFont(family: .named("sans serif"), size: 8)
    for i in 0..<max(inputs, 0) {
      g.color = .attribute(color.darker.darker.darker)
      g.strokeWidth = 1
      g.drawLine(
        x + border, y + border + i * 30 + 30 + showclock * 2,
        x + border + 15 * length + 4, y + border + i * 30 + 30 + showclock * 2)

      g.strokeWidth = 2
      if diagram.moveBack && diagram.state(i, length - 1) != nil {
        g.color = baseColor
        g.drawLine(
          x + border + 15 * length, y + border + i * 30 + 30 + showclock * 2,
          x + border + 15 * length + 4, y + border + i * 30 + 30 + showclock * 2)
      }
      // Arrowhead. Note it is filled in whatever colour the branch above left behind: the
      // dark trace colour normally, but `baseColor` on any row whose last cell is populated.
      g.fillPolygon(
        [
          x + border + 15 * length + 4,
          x + border + 15 * length + 13,
          x + border + 15 * length + 4,
        ],
        [
          y + border + i * 30 + 27 + showclock * 2,
          y + border + i * 30 + 30 + showclock * 2,
          y + border + i * 30 + 33 + showclock * 2,
        ])

      if showclock == 1 && i == 0 {
        g.color = .attribute(color.darker.darker)
      } else {
        g.color = .black
      }

      // With the clock row hidden, row `i` shows *input* `i + 1`; index 0 is always the clock.
      let row = i + (showclock == 0 ? 1 : 0)
      for j in 0..<max(length, 0) {
        let now = diagram.state(row, j)
        let prev = j > 0 ? diagram.state(row, j - 1) : nil
        if j != 0 && now != prev && now != nil && prev != nil {
          g.drawLine(
            x + border + 15 * j, y + 2 * border + 30 * i + showclock * 2,
            x + border + 15 * j, y + border + 30 * (i + 1) + showclock * 2)
        }
        if now == true {
          g.drawLine(
            x + border + 15 * j, y + 2 * border + 30 * i + showclock * 2,
            x + border + 15 * (j + 1), y + 2 * border + 30 * i + showclock * 2)
          if j == length - 1 {
            g.drawLine(
              x + border + 15 * (j + 1), y + 2 * border + 30 * i + showclock * 2,
              x + border + 15 * (j + 1), y + border + 30 * (i + 1) + showclock * 2)
          }
          if i == 0 && frontLines != .no && showclock == 1 {
            nck -= 1
            // The wrap is upstream's: past 100 cycles the caption restarts, and the `- 1` in
            // the wrapped branch is not symmetric with the unwrapped one.
            let cknum =
              (diagram.clockNumber - nck) > 0
              ? diagram.clockNumber - nck
              : 100 + (diagram.clockNumber - nck - 1)
            g.color = .attribute(color.darker)
            g.drawCenteredText(String(cknum), x: x + border + 15 * j + 7, y: y + border + 5)
            if showclock == 1 && i == 0 {
              g.color = .attribute(color.darker.darker)
            } else {
              g.color = baseColor
            }
          }
        } else if now == false {
          g.drawLine(
            x + border + 15 * j, y + border + 30 * (i + 1) + showclock * 2,
            x + border + 15 * (j + 1), y + border + 30 * (i + 1) + showclock * 2)
        }
      }
    }

    g.color = baseColor
    g.drawRoundRect(
      x + border, y + border, width - 2 * border, height - 2 * border, border / 2, border / 2)

    for i in 1..<(inputs + 2) {
      painter.drawPort(i)
    }
    painter.drawClock(0, .east)
    painter.drawLabel()
  }

  /// The attribute-template default for `ATTR_COLOR`.
  static let defaultColor = ColorSpec(red: 0, green: 208, blue: 208)
}

extension DigitalOscilloscope: IoPaintable {}

// MARK: - Label (board #78)

extension DigitalOscilloscope: InstanceLabelProvider {

  /// `Instance.computeLabelTextField(Instance.AVOID_LEFT)`: `DigitalOscilloscope.java:103`,
  /// re-run at `:136`/`:138`.
  ///
  /// This factory has **no `StdAttr.FACING`** (checked against the Java attribute list), so the
  /// avoid mask is never rotated and `AVOID_LEFT` stays `AVOID_LEFT`; `computed` reaches that
  /// through the `nil` facing arm, which is Java's "matches none of the three `==` tests".
  public func labelPlacement(_ painter: InstancePainter) -> LabelPlacement? {
    LabelPlacement.computed(painter, avoid: .left)
  }
}
