// AbstractTtlGate.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.ttl.AbstractTtlGate),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── Why this is the highest-leverage file in the module ─────────────────────────────────────
//
// 65 chips extend this class, and 64 of them override exactly two methods: `propagateTtl` and
// `paintInternal`. Everything else, the DIP-package geometry, the port table, the Vcc/GND
// rule, is here and must be right once.
//
// ── The port-index contract, which is the whole game ─────────────────────────────────────────
//
// A chip's `propagateTtl` addresses ports by *index into the port array*, not by pin number, and
// the mapping between the two is non-obvious. Upstream builds the array in this order:
//
//     [ pins 1 … n/2-1 ] [ pins n/2+1 … n-1 ] [ GND (pin n/2) ] [ Vcc (pin n) ]
//       ^ lower row, GND excluded  ^ upper row, Vcc excluded      ^ only when VCC_GND is on
//
// so for a 14-pin chip the port indices are pin-1 for pins 1…6, pin-2 for pins 8…13, then 12=GND
// and 13=Vcc. Unused pins are squeezed out and shift everything after them down. Get this wrong
// and every chip is subtly miswired while still "working".
//
// The transcription below keeps upstream's exact loop, including the `portindex--` / `portindex++`
// dance that implements the squeeze, precisely so that no chip's indices have to be re-derived.
//
// ── Not ported ──────────────────────────────────────────────────────────────────────────────
//
//   * `paintBase`, `paintInternal`, `paintInternalBase`, `paintInstance`, `paintGhost`,
//     `paintIcon`, `computeTextField`, `getTranslatedTtlXY`; D6/M6. `numberOfGatesToDraw` is
//     retained as stored state because it is a constructor argument of every chip.
//   * `Port.setToolTip`; see `Port.swift`; tool tips are localisation and hover UI.
//   * `getHDLName`, D11.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

/// `com.cburch.logisim.std.ttl.AbstractTtlGate`.
open class AbstractTtlGate: InstanceFactoryBase {

  /// `DEFAULT_HEIGHT` / `PIN_WIDTH` / `PIN_HEIGHT`.
  public static let defaultHeight = 60
  public static let pinWidth = 10
  public static let pinHeight = 7

  private let packageHeight: Int
  /// `pinNumber`: total pins, GND and Vcc included.
  public let pinNumber: Int
  private let ttlName: String
  /// Pin numbers (1-based, as printed on the chip) that are outputs.
  private let outputPorts: Set<Int>
  private let inoutPorts: Set<Int>
  private let unusedPins: Set<Int>
  /// Paint-only; retained because every chip passes `drawGates` through the constructor.
  private let numberOfGatesToDraw: Int
  /// Paint/hover only, same reason.
  public let portNames: [String]?

  /// The widest upstream constructor. The seven narrower overloads collapse into default
  /// arguments; Swift has them and Java does not, which is the only reason there were eight.
  public init(
    _ name: String,
    pins: Int,
    outputPorts: [Int]? = nil,
    notUsedPins: [Int]? = nil,
    inoutPorts: [Int]? = nil,
    portNames: [String]? = nil,
    drawGates: Bool = false,
    height: Int = AbstractTtlGate.defaultHeight
  ) {
    self.ttlName = name
    self.pinNumber = pins
    self.outputPorts = Set(outputPorts ?? [])
    self.inoutPorts = Set(inoutPorts ?? [])
    self.unusedPins = Set(notUsedPins ?? [])
    self.portNames = portNames
    self.numberOfGatesToDraw = drawGates ? Set(outputPorts ?? []).count : 0
    self.packageHeight = height
    super.init(name)
    setAttributes([
      StdAttr.facing.binding(Direction.east),
      TtlLibraryAttributes.vccGnd.binding(false),
      TtlLibraryAttributes.drawInternalStructure.binding(false),
      StdAttr.label.binding(""),
    ])
    setFacingAttribute(StdAttr.facing)
    // `setIconName("ttl.gif")`, M6.
  }

  // MARK: Geometry

  /// `getOffsetBounds(AttributeSet)`: a DIP package `pinNumber * 10` long, rotated to face.
  open override func offsetBounds(_ attributes: any AttributeSet) -> Bounds {
    let dir = attributes[StdAttr.facing, default: .east]
    return Bounds.create(0, -30, pinNumber * 10, packageHeight)
      .rotate(from: .east, to: dir, xc: 0, yc: 0)
  }

  /// `updatePorts(Instance)`.
  ///
  /// Transcribed statement for statement. The `portindex` decrements are load-bearing: they are
  /// what removes an unused pin, and the GND pin when `VCC_GND` is off, from the numbering
  /// without leaving a hole.
  open override func ports(_ attributes: any AttributeSet) -> [Port] {
    let bds = offsetBounds(attributes)
    let dir = attributes[StdAttr.facing, default: .east]
    let width = bds.width
    let height = bds.height
    let hasVccGnd = attributes[TtlLibraryAttributes.vccGnd, default: false]
    let unusedCount = unusedPins.count

    var dx = 0
    var dy = 0
    var portindex = 0
    let count = hasVccGnd ? pinNumber - unusedCount : pinNumber - 2 - unusedCount
    guard count > 0 else { return [] }
    var ps = [Port?](repeating: nil, count: count)

    for i in 0..<pinNumber {
      let pin = i + 1  // the number printed on the package
      let isOutput = outputPorts.contains(pin)
      let isInout = inoutPorts.contains(pin)
      let skip = unusedPins.contains(pin)

      // Position, in component-relative coordinates.
      if i < pinNumber / 2 {
        switch dir {
        case .east:
          dx = i * 20 + 10
          dy = height - 30
        case .west:
          dx = -10 - 20 * i
          dy = 30 - height
        case .north:
          dx = width - 30
          dy = -10 - 20 * i
        case .south:
          dx = 30 - width
          dy = i * 20 + 10
        }
      } else {
        switch dir {
        case .east:
          dx = width - (i - pinNumber / 2) * 20 - 10
          dy = -30
        case .west:
          dx = -width + (i - pinNumber / 2) * 20 + 10
          dy = 30
        case .north:
          dx = -30
          dy = -height + (i - pinNumber / 2) * 20 + 10
        case .south:
          dx = 30
          dy = height - (i - pinNumber / 2) * 20 - 10
        }
      }

      if skip {
        portindex -= 1
      } else if isOutput {
        ps[assertIndex(portindex, count, pin)] = Port(dx, dy, .output, 1)
      } else if isInout {
        ps[assertIndex(portindex, count, pin)] = Port(dx, dy, .inout_, 1)
      } else {
        if hasVccGnd && i == pinNumber - 1 {  // Vcc, always last in the array
          ps[count - 1] = Port(dx, dy, .input, 1)
        } else if i == pinNumber / 2 - 1 {  // GND, second to last when present
          if hasVccGnd {
            ps[count - 2] = Port(dx, dy, .input, 1)
          }
          portindex -= 1
        } else if i != pinNumber - 1 && i != pinNumber / 2 - 1 {  // an ordinary input
          ps[assertIndex(portindex, count, pin)] = Port(dx, dy, .input, 1)
        }
      }
      portindex += 1
    }

    // A hole here means the chip's own pin table is inconsistent (an output declared on the Vcc
    // pin, say): a defect in this port's transcription of a datasheet, not something a `.circ`
    // file can cause. Java gets a `NullPointerException` at `instance.setPorts`. D13's
    // programmer-error carve-out: trap.
    return ps.enumerated().map { index, port in
      guard let port else {
        preconditionFailure("\(ttlName): port \(index) of \(count) was never assigned")
      }
      return port
    }
  }

  private func assertIndex(_ index: Int, _ count: Int, _ pin: Int) -> Int {
    precondition(
      index >= 0 && index < count,
      "\(ttlName): pin \(pin) maps to port index \(index), outside 0..<\(count)")
    return index
  }

  // MARK: Propagation

  /// `propagate(InstanceState)`; the Vcc/GND gate that wraps every chip's logic.
  ///
  /// **Deviation (mechanism).** Java writes `getPortValue(...) != Value.FALSE`, a *reference*
  /// comparison. It works there only because `Value.create` interns every one-bit value, so the
  /// singletons are the only FALSE/TRUE objects in existence. `Value` is a struct here, so this
  /// compares structurally, which answers identically on one-bit ports, and these ports are
  /// declared `Port(dx, dy, .input, 1)`, so they are always one bit.
  open override func propagate(_ state: any InstanceState) throws {
    let unusedCount = unusedPins.count
    let vccGnd = state.attributeValue(TtlLibraryAttributes.vccGnd, default: false)

    // The `&&` must short-circuit. When `VCC_GND` is off the port array is two entries shorter,
    // so `pinNumber - 2 - unusedCount` is one past its end; reading it eagerly would be an
    // out-of-range port access on every unpowered chip, which is the majority of them.
    let misPowered =
      vccGnd
      && (state.portValue(pinNumber - 2 - unusedCount) != .falseValue
        || state.portValue(pinNumber - 1 - unusedCount) != .trueValue)

    if misPowered {
      // Mis-powered: every output floats. Note this walks *pin* numbers and counts ports as it
      // goes, which is the inverse of `ports(_:)`'s squeeze, and note it does not exclude the
      // Vcc pin, only GND, exactly as upstream.
      var port = 0
      for pin in 1...pinNumber where !unusedPins.contains(pin) && pin != pinNumber / 2 {
        if outputPorts.contains(pin) {
          state.setPort(port, .unknownValue, 1)
        }
        port += 1
      }
    } else {
      try propagateTtl(state)
    }
  }

  /// `propagateTtl(InstanceState)`; "here you have to write the logic of your component".
  ///
  /// Java declares it `abstract`; no `.circ` file can reach this stub, so it traps (D13).
  open func propagateTtl(_ state: any InstanceState) throws {
    fatalError("\(ttlName): AbstractTtlGate subclasses must override `propagateTtl`")
  }

  // MARK: Painting (M6)
  //
  // `AbstractTtlGate.java:142-161` (paintBase), `:210-426` (paintGhost/paintInstance/
  // paintInternalBase/paintInternal), `:542-580` (paintIcon). Transcribed literally: `xp`/`yp`
  // are kept as running mutable locals exactly as Java has them (only one branch of the
  // if/else touches each per iteration), rather than refactored into a helper: the two
  // duplicate loops here (`paintBase` and `paintInstance`'s own copy, colours aside) are
  // upstream's own duplication, not this port's.
  //
  // NOT PORTED: `painter.drawPorts()`, `paintIcon`. Both are generic Instance-level chrome
  // shared by every one of the ~350 stock components (the per-port wire-stub markers, the
  // toolbar/explorer icon), not TTL-specific, and belong to the shared Instance painter this
  // slice does not own. `computeTextField` **is** now ported, as `labelPlacement` below.

  /// `computeTextField(Instance)`: `AbstractTtlGate.java:141-160`, re-expressed as the
  /// on-demand placement `InstanceLabelProvider` asks for.
  ///
  /// Facing-dependent, and the two arms are genuinely different placements rather than a
  /// rotation of one: a chip lying east/west gets its label to the **right of the package**
  /// (`H_LEFT`, so the text starts 3px past the right edge and runs outward), while one lying
  /// north/south gets it **centred 3px above the top edge**. Both use `V_CENTER_OVERALL`.
  ///
  /// `painter.bounds` is `instance.getBounds()`, i.e. the rotated `getOffsetBounds` translated
  /// to the location, so the width/height read here are already the post-rotation ones, which
  /// is why upstream needs no separate rotation of the label offsets.
  public func labelPlacement(_ painter: InstancePainter) -> LabelPlacement? {
    let bds = painter.bounds
    let dir = painter.attributeValue(StdAttr.facing, default: .east)
    if dir == .east || dir == .west {
      return LabelPlacement(
        x: bds.x + bds.width + 3,
        y: bds.y + bds.height / 2,
        halign: .left,
        valign: .centerOverall)
    }
    return LabelPlacement(
      x: bds.x + bds.width / 2,
      y: bds.y - 3,
      halign: .center,
      valign: .centerOverall)
  }

  /// `paintGhost(InstancePainter)` → `paintBase(painter, true, true)`.
  ///
  /// No placed component exists yet, so `state.bounds` is `factory.getOffsetBounds(attrs)`
  /// (unlocated); exactly what Java's `painter.getBounds()` returns when `comp == null`. The
  /// ghost tool translates the emitter to the cursor before calling this
  /// (`ToolOverlayScene.paint`'s `pushTranslate`), so the arithmetic below is unchanged from the
  /// placed case.
  public func paintGhost(_ painter: SceneBuilder, _ state: any TtlPainter) {
    let dir = state.attributeValue(StdAttr.facing, default: .east)
    paintBase(painter, bounds: state.bounds, direction: dir, drawName: true, ghost: true)
  }

  /// `paintInstance(InstancePainter)`; `AbstractTtlGate.java:286-426`.
  ///
  /// The two composites Java opens with (`painter.drawPorts()` then `painter.drawLabel()`) are
  /// now ported: `InstancePainter` supplies both, and `drawLabel` reaches this class's own
  /// `labelPlacement` through the `InstanceLabelProvider` conformance at the foot of this file.
  /// Order is upstream's: the pin markers go under the body, the label over it.
  public func paintInstance(_ painter: SceneBuilder, _ state: any TtlPainter) {
    state.drawPorts()
    state.drawLabel()

    let attributes = state.attributeSet
    let bds = state.bounds
    let dir = attributes[StdAttr.facing, default: .east]

    guard attributes[TtlLibraryAttributes.drawInternalStructure, default: false] else {
      let x = bds.x
      let y = bds.y
      let width = bds.width
      let height = bds.height
      var xp = x
      var yp = y

      for i in 0..<pinNumber {
        if i == pinNumber / 2 {
          xp = x
          yp = y
          if dir == .west || dir == .east {
            painter.color = .rgb(0x2C_2C2C)  // Color.DARK_GRAY.darker()
            painter.fillRoundRect(
              xp, yp + Self.pinHeight, width, height - Self.pinHeight * 2 + 2, 10, 10)
            painter.color = .rgb(0x40_4040)  // Color.DARK_GRAY
            painter.fillRoundRect(
              xp, yp + Self.pinHeight, width, height - Self.pinHeight * 2 - 2, 10, 10)
            painter.color = .black
            painter.drawRoundRect(
              xp, yp + Self.pinHeight, width, height - Self.pinHeight * 2 - 2, 10, 10)
            painter.drawRoundRect(
              xp, yp + Self.pinHeight, width, height - Self.pinHeight * 2 + 2, 10, 10)
          } else {
            painter.color = .rgb(0x2C_2C2C)
            painter.fillRoundRect(xp + Self.pinHeight, yp, width - Self.pinHeight * 2, height, 10, 10)
            painter.color = .rgb(0x40_4040)
            painter.fillRoundRect(
              xp + Self.pinHeight, yp, width - Self.pinHeight * 2, height - 4, 10, 10)
            painter.color = .black
            painter.drawRoundRect(
              xp + Self.pinHeight, yp, width - Self.pinHeight * 2, height - 4, 10, 10)
            painter.drawRoundRect(xp + Self.pinHeight, yp, width - Self.pinHeight * 2, height, 10, 10)
          }
          switch dir {
          case .south: painter.fillArc(xp + width / 2 - 7, yp - 7, 14, 14, 180, 180)
          case .west: painter.fillArc(xp + width - 7, yp + height / 2 - 7, 14, 14, 90, 180)
          case .north: painter.fillArc(xp + width / 2 - 7, yp + height - 11, 14, 14, 0, 180)
          case .east: painter.fillArc(xp - 7, yp + height / 2 - 7, 14, 14, 270, 180)
          }
        }
        if i < pinNumber / 2 {
          if dir == .west || dir == .east {
            xp = i * 20 + (10 - Self.pinWidth / 2) + x
          } else {
            yp = i * 20 + (10 - Self.pinWidth / 2) + y
          }
        } else {
          if dir == .west || dir == .east {
            xp = (i - pinNumber / 2) * 20 + (10 - Self.pinWidth / 2) + x
            yp = height + y - Self.pinHeight
          } else {
            yp = (i - pinNumber / 2) * 20 + (10 - Self.pinWidth / 2) + y
            xp = width + x - Self.pinHeight
          }
        }
        if dir == .west || dir == .east {
          painter.color = .rgb(0xC0_C0C0)  // Color.LIGHT_GRAY
          painter.fillRect(xp, yp, Self.pinWidth, Self.pinHeight)
          painter.color = .black
          painter.drawRect(xp, yp, Self.pinWidth, Self.pinHeight)
        } else {
          painter.color = .rgb(0xC0_C0C0)
          painter.fillRect(xp, yp, Self.pinHeight, Self.pinWidth)
          painter.color = .black
          painter.drawRect(xp, yp, Self.pinHeight, Self.pinWidth)
        }
      }

      painter.color = .white  // Color.LIGHT_GRAY.brighter()
      painter.withTransform(
        .rotation(-dir.toRadians(), aroundX: Double(x + width / 2), y: Double(y + height / 2))
      ) {
        painter.font = SceneFont(family: .named("DialogInput"), size: 14, bold: true)
        painter.drawCenteredText(ttlName, x: x + width / 2, y: y + height / 2 - 4)
        painter.font = SceneFont(family: .named("DialogInput"), size: 7, bold: true)
        var vx = x
        var vy = y
        if dir != .west && dir != .east {
          vx = x + (width - height) / 2
          vy = y + (height - width) / 2
        }
        switch dir {
        case .south:
          painter.drawCenteredText("Vcc", x: vx + 10, y: vy + Self.pinHeight + 4)
          painter.drawCenteredText("GND", x: vx + height - 14, y: vy + width - Self.pinHeight - 8)
        case .west:
          painter.drawCenteredText("Vcc", x: vx + 10, y: vy + Self.pinHeight + 6)
          painter.drawCenteredText("GND", x: vx + width - 10, y: vy + height - Self.pinHeight - 8)
        case .north:
          painter.drawCenteredText("Vcc", x: vx + 14, y: vy + Self.pinHeight + 4)
          painter.drawCenteredText("GND", x: vx + height - 10, y: vy + width - Self.pinHeight - 8)
        case .east:
          painter.drawCenteredText("Vcc", x: vx + 10, y: vy + Self.pinHeight + 4)
          painter.drawCenteredText("GND", x: vx + width - 10, y: vy + height - Self.pinHeight - 10)
        }
      }
      return
    }
    paintInternalBase(painter, state)
  }

  /// `paintBase(InstancePainter, boolean, boolean)`, called directly by the many chips whose
  /// `drawGates` is `false` (`paintInternalBase` only calls it automatically for the
  /// `drawGates == true` chips): e.g. `Ttl7410.paintInternal`'s
  /// `super.paintBase(painter, false, false)`. `protected` in Java; `internal` here, since
  /// every caller is a same-module subclass and nothing outside `LogisimStd` may reach it.
  func paintBase(_ painter: SceneBuilder, _ state: any TtlPainter, drawName: Bool, ghost: Bool) {
    let dir = state.attributeValue(StdAttr.facing, default: .east)
    paintBase(painter, bounds: state.bounds, direction: dir, drawName: drawName, ghost: ghost)
  }

  /// The DIP outline shared by `paintGhost` and (when `DRAW_INTERNAL_STRUCTURE` is on)
  /// `paintInternalBase`/the `drawGates == false` chips above.
  private func paintBase(
    _ painter: SceneBuilder, bounds bds: Bounds, direction dir: Direction,
    drawName: Bool, ghost: Bool
  ) {
    let x = bds.x
    let y = bds.y
    var width = bds.width
    var height = bds.height
    var xp = x
    var yp = y

    if !ghost {
      // `AppPreferences.COMPONENT_COLOR`'s default (`0x00000000`) is opaque black once the
      // alpha byte is dropped by `new Color(int)`. The user preference itself is UI state (D9)
      // and is not threaded through here; this reproduces its default.
      painter.color = .black
    }

    for i in 0..<pinNumber {
      if i < pinNumber / 2 {
        if dir == .west || dir == .east {
          xp = i * 20 + (10 - Self.pinWidth / 2) + x
        } else {
          yp = i * 20 + (10 - Self.pinWidth / 2) + y
        }
      } else {
        if dir == .west || dir == .east {
          xp = (i - pinNumber / 2) * 20 + (10 - Self.pinWidth / 2) + x
          yp = height + y - Self.pinHeight
        } else {
          yp = (i - pinNumber / 2) * 20 + (10 - Self.pinWidth / 2) + y
          xp = width + x - Self.pinHeight
        }
      }
      if dir == .west || dir == .east {
        painter.drawRect(xp, yp, Self.pinWidth, Self.pinHeight)
      } else {
        painter.drawRect(xp, yp, Self.pinHeight, Self.pinWidth)
      }
    }

    switch dir {
    case .south:
      painter.drawRoundRect(x + Self.pinHeight, y, width - Self.pinHeight * 2, height, 10, 10)
      painter.drawArc(x + width / 2 - 7, y - 7, 14, 14, 180, 180)
    case .west:
      painter.drawRoundRect(x, y + Self.pinHeight, width, height - Self.pinHeight * 2, 10, 10)
      painter.drawArc(x + width - 7, y + height / 2 - 7, 14, 14, 90, 180)
    case .north:
      painter.drawRoundRect(x + Self.pinHeight, y, width - Self.pinHeight * 2, height, 10, 10)
      painter.drawArc(x + width / 2 - 7, y + height - 7, 14, 14, 0, 180)
    case .east:
      painter.drawRoundRect(x, y + Self.pinHeight, width, height - Self.pinHeight * 2, 10, 10)
      painter.drawArc(x - 7, y + height / 2 - 7, 14, 14, 270, 180)
    }

    painter.withTransform(
      .rotation(-dir.toRadians(), aroundX: Double(x + width / 2), y: Double(y + height / 2))
    ) {
      if drawName {
        painter.font = SceneFont(family: .named("DialogInput"), size: 14, bold: true)
        painter.drawCenteredText(ttlName, x: x + width / 2, y: y + height / 2 - 4)
      }
      if dir == .west || dir == .east {
        xp = x
        yp = y
      } else {
        xp = x + (width - height) / 2
        yp = y + (height - width) / 2
        width = bds.height
        height = bds.width
      }
      painter.font = SceneFont(family: .named("DialogInput"), size: 7, bold: true)
      painter.drawCenteredText("Vcc", x: xp + 10, y: yp + Self.pinHeight + 4)
      painter.drawCenteredText("GND", x: xp + width - 10, y: yp + height - Self.pinHeight - 7)
    }
  }

  /// `paintInternalBase(InstancePainter)`.
  private func paintInternalBase(_ painter: SceneBuilder, _ state: any TtlPainter) {
    let attributes = state.attributeSet
    let bds = state.bounds
    let dir = attributes[StdAttr.facing, default: .east]
    var x = bds.x
    var y = bds.y
    var width = bds.width
    var height = bds.height
    if dir == .south || dir == .north {
      x += (width - height) / 2
      y += (height - width) / 2
      width = bds.height
      height = bds.width
    }

    if numberOfGatesToDraw == 0 {
      paintInternal(painter, state, x: x, y: y, height: height, up: false)
    } else {
      paintBase(painter, bounds: bds, direction: dir, drawName: false, ghost: false)
      let half = numberOfGatesToDraw / 2
      for i in 0..<numberOfGatesToDraw {
        let xOff = (i < half ? i : i - half) * ((width - 20) / half) + (i < half ? 0 : 20)
        paintInternal(painter, state, x: x + xOff, y: y, height: height, up: i >= half)
      }
    }
  }

  /// `paintInternal(InstancePainter, int, int, int, boolean)`: abstract in Java. Every
  /// concrete chip overrides this with its own gate/flop/counter symbol; the coordinate frame
  /// (`x`, `y`, `height`, `up`) is `paintInternalBase`'s, already adjusted for `drawGates`
  /// fan-out and the NORTH/SOUTH width/height swap. Java never re-checks `FACING` inside a
  /// concrete `paintInternal`; the internal-structure glyphs are not actually re-rotated for
  /// NORTH/SOUTH, only re-positioned by the swap above. Preserved, not fixed.
  open func paintInternal(
    _ painter: SceneBuilder, _ state: any TtlPainter, x: Int, y: Int, height: Int, up: Bool
  ) {
    fatalError("\(ttlName): AbstractTtlGate subclasses must override `paintInternal`")
  }

  // PAINT (M6), not ported: `paintIcon`: toolbar/explorer icon, generic UI chrome outside the
  // schematic canvas. See AbstractTtlGate.java:542-580.
}

// One conformance covers all 65 chips: every 74xx factory in this module extends
// `AbstractTtlGate` and none of them overrides `computeTextField`, exactly as upstream, where
// the single `configureNewInstance` in this class is the only `setTextField` call site the whole
// family has.
extension AbstractTtlGate: InstanceLabelProvider {}
