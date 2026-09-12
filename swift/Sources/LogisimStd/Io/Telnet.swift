// Telnet.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.io.Telnet),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// See `TelnetServer.swift`'s header for how the listening socket is scoped so that loading this
// factory, or the whole `IoLibrary`, never binds a port; only an actual `propagate` call on a
// placed, simulating `Telnet` component does.
//
// ── What did not come across ─────────────────────────────────────────────────────────────────
//
//   (`paintInstance` IS ported; see the Paint section at the end of this file.)
//   * `setKeyConfigurator`: UI.
//
// ── D13 ───────────────────────────────────────────────────────────────────────────────────────
//
// Upstream's `getData` wraps `ServerHolder.INSTANCE.getServer`'s checked `IOException` in an
// unchecked `RuntimeException` and lets it propagate out of `propagate` uncaught, which
// `Simulator` catches and reports as a circuit error (D13's exact shape). The port's `propagate`
// already `throws`, so `TelnetServerHolder.server(port:bufferSize:)`'s own `throws` needs no
// wrapping; a port already in use surfaces as a circuit error rather than a crash, matching
// upstream's observable behaviour.

import Foundation
import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.std.io.Telnet`.
public final class Telnet: InstanceFactoryBase {

  /// `Telnet._ID`.
  public static let id = "Telnet"

  private static let inPort = 0
  private static let outPort = 1
  private static let clockPort = 2
  private static let writePort = 3
  private static let readPort = 4
  private static let availablePort = 5

  /// `Telnet.ATTR_TELNET_MODE`.
  public static let attrTelnetMode: Attribute<Bool> = Attributes.forBoolean("telnetMode")
  /// `Telnet.ATTR_PORT`.
  public static let attrPort: Attribute<Int32> = Attributes.forIntegerRange(
    "port", start: 1, end: 65535)
  /// `Telnet.ATTR_BUFFER`. Upstream's range is `1 ... 1024 * 16 * 1024` (16 Mi), added to fix
  /// upstream issue #2284.
  public static let attrBuffer: Attribute<Int32> = Attributes.forIntegerRange(
    "buflen", start: 1, end: 1024 * 16 * 1024)

  public init() {
    super.init(Telnet.id)
    setAttributes([
      Telnet.attrTelnetMode.binding(false),
      Telnet.attrPort.binding(8000),
      Telnet.attrBuffer.binding(1024),
      StdAttr.edgeTrigger.binding(StdAttr.triggerRising),
      StdAttr.label.binding(""),
      stdAttrLabelLocation.binding(.north),
      StdAttr.labelFont.binding(StdAttr.defaultLabelFont),
    ])
    setOffsetBounds(Bounds.create(-30, -20, 40, 60))

    setPorts([
      Port(-30, 10, .input, 8),
      Port(10, 10, .output, 8),
      Port(-30, 20, .input, 1),
      Port(-30, 30, .input, 1),
      Port(10, 30, .input, 1),
      Port(10, 20, .output, 1),
    ])
  }

  private static func data(for state: any InstanceState) throws -> TelnetServer {
    let port = Int(state.attributeValue(Telnet.attrPort, default: 8000))
    let bufferSize = Int(state.attributeValue(Telnet.attrBuffer, default: 1024))
    if let existing = state.data as? TelnetServer, existing.port == port {
      if existing.bufferSize() != bufferSize {
        existing.setBufferSize(bufferSize)
      }
      return existing
    }
    let created = try TelnetServerHolder.shared.server(port: port, bufferSize: bufferSize)
    created.setInstanceState(state)
    state.setData(created)
    return created
  }

  public override func propagate(_ circState: any InstanceState) throws {
    let server = try Telnet.data(for: circState)
    server.setTelnetEscape(circState.attributeValue(Telnet.attrTelnetMode, default: false))
    // JAVA QUIRK, PRESERVED: upstream reads `StdAttr.TRIGGER` here, but the attribute list this
    // factory declares only contains `StdAttr.EDGE_TRIGGER`; a *different* `Attribute` identity
    // that happens to share the `.circ` token `"trigger"` (see `StdAttr.swift`'s note on the
    // two sharing a serialized name). `getAttributeValue(StdAttr.TRIGGER)` therefore always
    // misses and returns `null`; `null == TRIG_FALLING` is always `false`, so the "Trigger:
    // Falling Edge" option in this component's attribute table has never had any observable
    // effect: it always behaves as rising-edge. Reproduced by querying the same (missing)
    // identity rather than special-casing the outcome.
    let triggerType = circState.attributeValue(StdAttr.trigger)
    let clock = circState.portValue(Telnet.clockPort)
    let write = circState.portValue(Telnet.writePort)
    let read = circState.portValue(Telnet.readPort)
    let inValue = circState.portValue(Telnet.inPort)

    // Java: `synchronized (state) { … }`. `TelnetServer` guards its own fields with an internal
    // lock, so no separate lock is taken here, see its header.
    let lastClock = server.setLastClock(clock)
    let go: Bool =
      triggerType == StdAttr.triggerFalling
      ? (lastClock == .trueValue && clock == .falseValue)
      : (lastClock == .falseValue && clock == .trueValue)

    circState.setPort(Telnet.availablePort, server.hasData() ? .trueValue : .falseValue, 0)

    if read == .trueValue {
      circState.setPort(Telnet.outPort, Value.createKnown(8, Int64(server.data())), 0)
    } else {
      circState.setPort(Telnet.outPort, .unknownValue, 0)
    }

    if go {
      if write == .trueValue {
        server.send(Int(inValue.toLongValue()))
      }
      if read == .trueValue {
        server.deleteOldest()
      }
    }
  }

  // MARK: - Paint (D6)

  /// `paintInstance(InstancePainter)`: `Telnet.java:105-143`.
  ///
  /// A labelled box with the word "Telnet" and the configured TCP port number under it. Two
  /// details are upstream's and are preserved:
  ///
  ///   * `metric` is captured **before** the font is shrunk to 80%, and the second line's `y` is
  ///     `y0 + metric.getHeight() - 4`; i.e. the line spacing comes from the *large* font while
  ///     the glyphs are drawn in the small one. Re-measuring after the `deriveFont` would move
  ///     the port number up.
  ///   * `0.8f` is a float scale on a float point size, so a 12pt font becomes 9.6pt, not 9.
  public func paintInstance(_ painter: any IoInstancePainter) {
    let g = painter.scene
    g.color = painter.componentColor

    painter.drawBounds()
    painter.drawPort(Telnet.inPort, "in", .east)
    painter.drawPort(Telnet.outPort, "out", .west)
    painter.drawClock(Telnet.clockPort, .east)
    painter.drawPort(Telnet.writePort, "wr", .east)
    painter.drawPort(Telnet.readPort, "rd", .west)
    painter.drawPort(Telnet.availablePort, "av", .west)

    let metric = g.fontMetrics()
    g.color = painter.componentColor

    let bds = painter.bounds
    let x0 = bds.x + bds.width / 2
    let y0 = bds.y + metric.height + 2
    g.drawText("Telnet", x: x0, y: y0, halign: .center, valign: .bottom)
    g.font = g.font.withSize(g.font.size * 0.8)
    g.drawText(
      String(painter.attributeValue(Telnet.attrPort, default: 8000)),
      x: x0, y: y0 + metric.height - 4, halign: .center, valign: .bottom)

    g.color = .attribute(
      painter.attributeValue(StdAttr.labelColor, default: StdAttr.defaultLabelColor))
    painter.drawLabel()
  }
}

extension Telnet: IoPaintable {}

// MARK: - Label (board #78)

extension Telnet: InstanceLabelProvider {

  /// `Instance.computeLabelTextField(Instance.AVOID_SIDES)`: `Telnet.java:204`, re-run at
  /// `:210`.
  ///
  /// `AVOID_SIDES == AVOID_LEFT | AVOID_RIGHT`. Telnet has **no `StdAttr.FACING`** (checked
  /// against the Java attribute list at `Telnet.java:60-80`), so unlike `Switch`, which sets
  /// the same two bits, the mask is never rotated: only an `EAST` or `WEST` label is nudged.
  public func labelPlacement(_ painter: InstancePainter) -> LabelPlacement? {
    LabelPlacement.computed(painter, avoid: .sides)
  }
}
