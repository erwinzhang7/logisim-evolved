// LogisimUI: part of logisim-evolved.
//
// Derived from logisim-evolution 4.1.0, GPL-3.0-only. See LICENSE.md at the repository root.
//
// **Provenance, per D10.** This file is not a translation of upstream logic, it is a
// transcription of upstream *artwork*: the coordinates below are Logisim-evolution's own icon
// drawings, copied out of the shipped 4.1.0 jar. Each glyph names the class and method it came
// from in its doc comment, so any one of them can be checked against the artefact. Both are
// GPL-3.0-only, so the reuse needs no separate grant: only the acknowledgement, which is this
// paragraph plus the per-glyph citations. The repo records its two lineages in `LICENSE.md` and
// in `About ▸ Credits` (`AboutCreditsTab`/`AboutFacts`); a line naming the icons belongs there
// too, and this branch's report gives the wording, since those files are owned elsewhere.
//
// Reference tree: the shipped 4.1.0 jar
// `/Applications/Logisim-evolution.app/Contents/app/logisim-evolution-4.1.0-all.jar`,
// read with `javap -c` (D16: NOT `src/main/java`, which is upstream main).
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// THE TOOL ICONS, TAKEN FROM 4.1.0 RATHER THAN INVENTED.
//
// ── WHAT WAS HERE BEFORE, AND WHY IT WAS WRONG ──────────────────────────────────────────────
//
// `Tool.swift`'s header records the original decision: "`paintIcon(ComponentDrawContext,int,int)`
// ; the toolbar/explorer icon. `DomainTypes.ToolItem` already carries an SF Symbol name for this,
// which is the macOS-native answer." The SF Symbols were then chosen by hand, in
// `ProjectOutlineBuilder.ToolSymbols`, and the gate row came out as:
//
//     AND → capsule        OR  → shield                 XOR  → xmark.circle
//     NAND → capsule.portrait  NOR → shield.lefthalf.filled  XNOR → xmark.shield
//     NOT → circle.slash   Buffer → triangle
//
// A pill, a shield and an ✗-in-a-circle. None of those is a logic gate. Reported from the first
// real use of the app: the gate icons were wrong, and the original ones should be used because
// they are the industry standard. That is right, and it is a fidelity regression this port
// introduced; the ANSI distinctive-shape glyphs are the notation every engineer reads without
// thinking, and 4.1.0 draws them correctly.
//
// ── WHY GEOMETRY AND NOT AN ASSET FILE ──────────────────────────────────────────────────────
//
// The obvious plan, lift the icon files out of the jar, does not survive contact with the jar.
// `unzip -l` on 4.1.0 finds exactly 31 entries under `resources/logisim/icons/`, all 60–900 byte
// GIFs (`splitter.gif`, `tunnel.gif`, `clock.gif`, `power.gif`, …) plus one PNG, and **not one of
// them is a gate**. Every gate and every canvas-tool icon in 4.1.0 is a `.class`: the drawing is
// Java2D code, run at whatever scale the display asks for.
//
//   * `com/cburch/logisim/std/gates/AbstractGate.class`: `paintIcon(InstancePainter)` dispatches
//     to the abstract `paintIconANSI(Graphics2D,int,int,int)`, which `AndGate`, `OrGate` and
//     `XorGate` implement and `NandGate`/`NorGate`/`XnorGate` reuse with `negate = true`.
//   * `NotGate`/`Buffer` call the shared `AbstractGate.paintIconBufferAnsi(Graphics2D,ZZ)`.
//   * `com/cburch/logisim/gui/icons/SelectIcon.class`, `tools/WiringTool.class`,
//     `std/wiring/Pin.class`; the same story.
//
// So "use the original icons" means porting the geometry, and that is what the tables below are:
// each glyph is transcribed from the 4.1.0 bytecode, with the disassembly's own local-variable
// arithmetic worked through and the resulting literal coordinates written down. The upstream
// space is `AppPreferences.getIconSize()`, `16` before display scaling, with
// `AppPreferences.getIconBorder()` = `2`, so **every glyph here is expressed in a 16×16 box** and
// `ToolGlyphView` scales it to whatever the view asks for. Vectors, not the 16px 1-bit GIFs:
// those would be soft at Retina scale and would stay black on a dark background, since a GIF
// carries no template/tint information.
//
// This is a derivative work of GPL-3.0-only code, which is the licence this port is already
// under, so the reuse is clean. The provenance is recorded in `NOTICE`.
//
// ── WHAT THIS FILE DOES *NOT* CLAIM ─────────────────────────────────────────────────────────
//
// The transcription is small and closed: the ten gates, the Select arrow, the wiring elbow, the
// Pin pentagon, and the `#TTL` DIP that upstream shares across every 74-series part. **71 of the
// explorer's 165 tools still draw a stand-in**: `#Plexers`, `#Arithmetic`, `#FPArithmetic`,
// `#I/O`, `#Input/Output-Extra`, `#Soc`, `#BFH-Praktika` and `#TCL`, each sharing one glyph
// across the whole library. That number is pinned as a ratchet in `ToolIconTests`, not papered
// over; it was 165 of 165 before this file and 132 before the TTL rule.
//
// `deliberateSymbols` is the middle ground and the distinction that matters: a symbol chosen
// **for that one tool**, as against `ToolSymbols.symbol(forToolNamed:inLibrary:)`'s fallbacks,
// which hand every tool in a library the same glyph or, at the end, `square.on.circle` for
// anything unrecognised. `ToolIcon.fallback` names that state so a test can refuse it.
//
// And what is asserted nowhere: that the palette and the sidebar actually *call* this catalog.
// Reverting both call sites to `Image(systemName: item.symbolName)` leaves the whole suite
// green: measured, not assumed. It is a one-line seam in each of two views and it is visible in
// review; closing it would need a rendering harness this project does not have.
// ═════════════════════════════════════════════════════════════════════════════════════════════

import CoreGraphics
import LogisimFile
import SwiftUI

// MARK: - What a tool's icon resolved to

/// The outcome of looking a tool up in the catalog, kept as a value so it can be asserted on
/// without a window. The three cases are ranked, and the ranking is the point: `fallback` is the
/// state the palette should never be in for a tool it actually offers.
enum ToolIcon: Hashable {
  /// Geometry transcribed from 4.1.0. The domain-standard glyph.
  case upstream(ToolGlyph)
  /// An SF Symbol picked for *this specific tool*. Not upstream's drawing, but not a stand-in
  /// for a whole library either.
  case symbol(String)
  /// Whatever `ToolSymbols` produced, which for most libraries is one glyph shared by every
  /// tool in it, and at worst `square.on.circle`. A placeholder wearing an icon's clothes.
  case fallback(String)

  /// True when the icon distinguishes this tool from its neighbours.
  var isToolSpecific: Bool {
    switch self {
    case .upstream, .symbol: return true
    case .fallback: return false
    }
  }
}

// MARK: - The catalog

enum ToolIcons {

  /// 4.1.0's own drawings, keyed on the tool's `_ID`, the stable string `.circ` references,
  /// for the same reason `ToolSymbols` keys on it: a display name is localised upstream and a
  /// table keyed on one would be locale-dependent.
  ///
  /// **The lookup key this port can actually supply is `ToolItem.name`**, which
  /// `ProjectOutlineBuilder` fills from `Tool.displayName`. In this port `LibraryModel.Tool`
  /// declares `open var displayName: String { name }` and `AddTool.displayName` forwards to
  /// `factory.displayName`, which is likewise the factory's `name`, so the two coincide *today*
  /// and the key is the `_ID`. The day this port grows localisation they stop coinciding, and the
  /// fix is for `ToolItem` to carry the `_ID` outright; see the file's report. Until then the
  /// miss is not silent-blank: it degrades to `deliberateSymbols` and then to the caller's
  /// existing `symbolName`.
  static let upstreamGlyphs: [String: ToolGlyph] = [
    // #Gates: `AbstractGate.paintIconANSI` and `AbstractGate.paintIconBufferAnsi`.
    "AND Gate": .and(negated: false),
    "NAND Gate": .and(negated: true),
    "OR Gate": .or(negated: false),
    "NOR Gate": .or(negated: true),
    "XOR Gate": .xor(negated: false),
    "XNOR Gate": .xor(negated: true),
    "NOT Gate": .buffer(negated: true, controlled: false),
    "Buffer": .buffer(negated: false, controlled: false),
    "Controlled Buffer": .buffer(negated: false, controlled: true),
    "Controlled Inverter": .buffer(negated: true, controlled: true),

    // #Base: `SelectIcon.paint` and `WiringTool.paintIcon`.
    BaseToolIds.select: .selectArrow,
    BaseToolIds.edit: .selectArrow,
    BaseToolIds.wiring: .wire,

    // #Wiring, `Pin.paintIcon`.
    "Pin": .pin(output: false),
  ]

  /// SF Symbols chosen per tool, for tools whose 4.1.0 drawing was **not** transcribed.
  ///
  /// Listed rather than left to `ToolSymbols`' library fallback, because the fallback is what
  /// makes two different tools look identical: `D Flip-Flop` and `Register` both land on
  /// `memorychip` today, and every one of `#TTL`'s chips lands on `cpu`. Each entry here is a
  /// judgement that this symbol reads as this tool at 16pt: not a claim of upstream fidelity.
  static let deliberateSymbols: [String: String] = [
    // #Base. Upstream's Poke icon is a drawn hand (`PokeTool.paintIcon`, a 12-segment
    // `GeneralPath`); `hand.point.up.left` is the same idea drawn by Apple, so it was not worth
    // transcribing. Text and Menu likewise.
    BaseToolIds.poke: "hand.point.up.left",
    BaseToolIds.textTool: "textformat",
    BaseToolIds.textFactory: "textformat",
    BaseToolIds.menu: "ellipsis.circle",

    // #Memory. Both of these are on the default toolbar and both fall through to `memorychip`
    // today, so the two default-template memory buttons are currently indistinguishable.
    "D Flip-Flop": "d.square",
    "T Flip-Flop": "t.square",
    "J-K Flip-Flop": "j.square",
    "S-R Flip-Flop": "s.square",
    "Register": "rectangle.split.3x1",
    "Counter": "number.square",
    "Shift Register": "arrow.right.square",
    "RAM": "memorychip",
    "ROM": "memorychip.fill",
    "Random": "dice",

    // #Wiring, for the members whose 4.1.0 drawing was not transcribed.
    "Probe": "waveform.path",
    "Tunnel": "arrow.triangle.branch",
    "Pull Resistor": "bolt.horizontal",
    "Clock": "clock",
    "Constant": "number",
    "Splitter": "arrow.triangle.branch",
    "Bit Extender": "arrow.left.and.right",
    "Power": "bolt.fill",
    "Ground": "arrow.down.to.line",
    "Transistor": "triangle",
    "Transmission Gate": "square.on.square.dashed",

    // #Gates, the two that are not distinctive-shape gates.
    "Odd Parity": "1.circle",
    "Even Parity": "2.circle",
  ]

  /// `#Base`'s tools do not reach a view under their `_ID`.
  ///
  /// `ProjectOutlineBuilder` builds every `ToolItem` with
  /// `ToolSymbols.editingDisplayName(forToolNamed: tool.name) ?? tool.displayName`, and for the
  /// six canvas tools that first branch fires: the `_ID` "Poke Tool" becomes the button label
  /// **"Poke"**, "Edit Tool" becomes **"Select"**, "Wiring Tool" becomes **"Wire"**. So the
  /// catalog's `_ID` keys miss for exactly the tools whose `_ID`s are best documented.
  ///
  /// Found by `ToolIconTests.paletteHasNoPlaceholderIcons`, which is the whole reason that test
  /// asserts on the resolved *outcome* rather than on the tables: the tables looked right.
  ///
  /// The table is inverted here rather than the labels being written into `upstreamGlyphs`
  /// directly, so that the keys above stay `_ID`s and stay checkable against the jar. The real
  /// fix is for `ToolItem` to carry the `_ID` alongside the label, see this branch's report.
  private static let baseToolLabels: [String: String] = [
    "Poke": BaseToolIds.poke,
    "Select": BaseToolIds.edit,
    "Wire": BaseToolIds.wiring,
    "Text": BaseToolIds.textTool,
    "Menu": BaseToolIds.menu,
  ]

  /// Resolve a tool to the best icon this port has for it.
  ///
  /// `fallbackSymbol` is whatever the outline builder already computed; kept as the last resort
  /// so that a key this catalog does not know still draws *something*, rather than regressing to
  /// a blank where it used to draw a symbol.
  /// `#TTL`'s tools are named for their part: `Ttl7408`'s display name is
  /// `"7408: quad 2-input AND gate"`. There are ~60 of them and they all get the same icon,
  /// because `AbstractTtlGate.paintIcon` is declared `final`; a DIP package is a DIP package.
  ///
  /// A rule rather than sixty table rows, and deliberately a tight one: `74` followed by a
  /// digit, at the start. It will not swallow a user library's `"7-segment Display"` or a
  /// circuit somebody called `"74LS-based ALU"`: those get no glyph and fall through, which is
  /// the correct answer for something this catalog knows nothing about.
  static func isTtlPartNumber(_ name: String) -> Bool {
    guard name.hasPrefix("74"), name.count > 2 else { return false }
    return name[name.index(name.startIndex, offsetBy: 2)].isNumber
  }

  static func icon(forToolNamed name: String, fallbackSymbol: String) -> ToolIcon {
    let key = baseToolLabels[name] ?? name
    if let glyph = upstreamGlyphs[key] { return .upstream(glyph) }
    if let symbol = deliberateSymbols[key] { return .symbol(symbol) }
    if isTtlPartNumber(key) { return .upstream(.dipPackage) }
    return .fallback(fallbackSymbol)
  }

  static func icon(for item: ToolItem) -> ToolIcon {
    icon(forToolNamed: item.name, fallbackSymbol: item.symbolName)
  }

  /// The SF Symbol to use where an `NSImage` is the only thing the surface can take.
  ///
  /// A `Menu`'s rows become `NSMenuItem`s and only `Text`/`Image`/`Label` survive the crossing;
  /// a `Canvas`-drawn glyph renders as nothing at all. The palette's overflow menu is the one
  /// place in this file's surfaces where that bites, so it asks for a symbol explicitly rather
  /// than getting an invisible row. For a tool with an upstream glyph that means the symbol the
  /// builder already computed, which is what the menu showed before.
  static func menuSymbol(for item: ToolItem) -> String {
    switch icon(for: item) {
    case .upstream: return item.symbolName
    case .symbol(let name), .fallback(let name): return name
    }
  }
}

// MARK: - The glyphs

/// One 4.1.0 icon painter. The cases are 1:1 with the jar's methods rather than with tools,
/// because that is how upstream factors them: `NandGate.paintIconANSI` is literally
/// `AndGate.paintIconANSI(g, w, b, n, /*negate*/ true)`.
enum ToolGlyph: Hashable {
  /// `AndGate.paintIconANSI(Graphics2D,int,int,int,boolean)`. `negated` is `NandGate`.
  case and(negated: Bool)
  /// `OrGate.paintIconANSI(...)`. `negated` is `NorGate`.
  case or(negated: Bool)
  /// `XorGate.paintIconANSI(...)`. `negated` is `XnorGate`.
  case xor(negated: Bool)
  /// `AbstractGate.paintIconBufferAnsi(Graphics2D,boolean,boolean)`. `NotGate` is
  /// `(negate: true, controlled: false)`; `Buffer` is `(false, false)`.
  case buffer(negated: Bool, controlled: Bool)
  /// `com.cburch.logisim.gui.icons.SelectIcon.paint(Graphics2D)`.
  case selectArrow
  /// `com.cburch.logisim.tools.WiringTool.paintIcon(ComponentDrawContext,int,int)`.
  case wire
  /// `com.cburch.logisim.std.wiring.Pin.paintIcon(InstancePainter)`, `APPEAR_EVOLUTION_NEW`
  /// branch, which is the default, per `ProbeAttributes.getDefaultProbeAppearance()`.
  case pin(output: Bool)
  /// `com.cburch.logisim.std.ttl.AbstractTtlGate.paintIcon(InstancePainter)`: a DIP package
  /// seen from above. Declared `final` upstream, so **every** 74-series part shares it; see
  /// `ToolIcons.isTtlPartNumber`.
  case dipPackage
}

/// A glyph reduced to two paths and a stroke width, in the 16×16 upstream icon box.
///
/// Two paths because upstream uses both: the gates are stroked outlines, the Select arrow is a
/// `fillPolygon`. Keeping them apart lets the view stroke and fill in one pass each instead of
/// per-segment.
struct GlyphGeometry {
  var stroked = Path()
  var filled = Path()
  /// `GraphicsUtil.switchToWidth(g, AppPreferences.getScaled(1))` for the gates;
  /// `new BasicStroke(getScaled(2))` for the wiring tool.
  var lineWidth: CGFloat = 1
}

extension ToolGlyph {

  /// Upstream's `AppPreferences.getIconSize()` before display scaling. Every coordinate below is
  /// in this box.
  static let canonicalSize: CGFloat = 16

  /// `AppPreferences.getIconBorder()`.
  private static let border: CGFloat = 2
  /// `AppPreferences.getIconSize() - (border << 1)`; the argument `paintIcon` passes as the
  /// gates' drawing extent.
  private static let extent: CGFloat = 12
  /// `AppPreferences.getScaled(4)`, the negation bubble's diameter.
  private static let negateSize: CGFloat = 4

  var geometry: GlyphGeometry {
    switch self {
    case .and(let negated): return Self.andGeometry(negated: negated)
    case .or(let negated): return Self.orGeometry(negated: negated)
    case .xor(let negated): return Self.xorGeometry(negated: negated)
    case .buffer(let negated, let controlled):
      return Self.bufferGeometry(negated: negated, controlled: controlled)
    case .selectArrow: return Self.selectArrowGeometry
    case .wire: return Self.wireGeometry
    case .pin(let output): return Self.pinGeometry(output: output)
    case .dipPackage: return Self.dipPackageGeometry
    }
  }

  // ── Gates ─────────────────────────────────────────────────────────────────────────────────
  //
  // Upstream draws each gate into a `Graphics2D` that has been `translate(border, border)`d, so
  // every coordinate transcribed below is the *pre-translation* one and `b` is added at the end.
  // Local names match the disassembly's slot arithmetic where that helps the transcription be
  // checkable against `javap -c`.

  /// `AndGate.paintIconANSI(g, wh, border, negateSize, negate)`, `javap -c` on the 4.1.0 jar:
  ///
  ///     v5 = negateSize >> 1        = 2      v6 = wh - v5        = 10
  ///     v7 = (v6 - v5) >> 1         = 4      v9 = wh - neg - v7  = 4
  ///     drawPolyline([v9,0,0,v9], [v5,v5,v6,v6], 4)
  ///     GraphicsUtil.drawCenteredArc(g, v9, wh >> 1, v7, -90, 180)
  ///
  /// : the flat back with its two straight edges, then the semicircular nose. Java's arc angles
  /// run counter-clockwise on screen from 3 o'clock, so `-90 … +90` is the **right** half.
  private static func andGeometry(negated: Bool) -> GlyphGeometry {
    let b = border
    var path = Path()
    path.move(to: CGPoint(x: b + 4, y: b + 2))
    path.addLine(to: CGPoint(x: b + 0, y: b + 2))
    path.addLine(to: CGPoint(x: b + 0, y: b + 10))
    path.addLine(to: CGPoint(x: b + 4, y: b + 10))
    // The nose: centre (4, 6) radius 4, bottom → right → top. Written as two Bézier quarters
    // rather than `addArc`, because `addArc`'s `clockwise:` flag is defined against the user
    // space and silently draws the *left* half in a y-down context if it is set the wrong way;
    // a bug that would look like a mirrored gate and nothing else.
    appendRightSemicircle(to: &path, centre: CGPoint(x: b + 4, y: b + 6), radius: 4)
    appendPins(to: &path, negated: negated, singleInput: false)
    return GlyphGeometry(stroked: path, lineWidth: 1)
  }

  /// `OrGate.paintIconANSI(...)`:
  ///
  ///     v5 = neg >> 1 = 2   v6 = wh - v5 = 10   v8 = wh - neg = 8
  ///     moveTo(v8, wh>>1);            quadTo(2*v8/3, v5,  0, v5)
  ///     quadTo(v8/3, wh>>1, 0, v6);   quadTo(2*v8/3, v6,  v8, wh>>1);  closePath
  ///
  /// The integer divisions are Java's, so `2*8/3 = 5` and `8/3 = 2`, not 5.33 and 2.67.
  private static func orGeometry(negated: Bool) -> GlyphGeometry {
    let b = border
    var path = Path()
    path.move(to: CGPoint(x: b + 8, y: b + 6))
    path.addQuadCurve(to: CGPoint(x: b + 0, y: b + 2), control: CGPoint(x: b + 5, y: b + 2))
    path.addQuadCurve(to: CGPoint(x: b + 0, y: b + 10), control: CGPoint(x: b + 2, y: b + 6))
    path.addQuadCurve(to: CGPoint(x: b + 8, y: b + 6), control: CGPoint(x: b + 5, y: b + 10))
    path.closeSubpath()
    appendPins(to: &path, negated: negated, singleInput: false)
    return GlyphGeometry(stroked: path, lineWidth: 1)
  }

  /// `XorGate.paintIconANSI(...)`: the OR shield with its back pushed right by `neg >> 1 = 2`,
  /// plus the second, detached back curve at `x = 0` that is what makes an XOR an XOR.
  private static func xorGeometry(negated: Bool) -> GlyphGeometry {
    let b = border
    var path = Path()
    path.move(to: CGPoint(x: b + 8, y: b + 6))
    path.addQuadCurve(to: CGPoint(x: b + 2, y: b + 2), control: CGPoint(x: b + 5, y: b + 2))
    path.addQuadCurve(to: CGPoint(x: b + 2, y: b + 10), control: CGPoint(x: b + 4, y: b + 6))
    path.addQuadCurve(to: CGPoint(x: b + 8, y: b + 6), control: CGPoint(x: b + 5, y: b + 10))
    path.closeSubpath()
    // `moveTo(0, 2); quadTo(v9/3, wh>>1, 0, v7)`: a bare arc, deliberately not closed.
    path.move(to: CGPoint(x: b + 0, y: b + 2))
    path.addQuadCurve(to: CGPoint(x: b + 0, y: b + 10), control: CGPoint(x: b + 2, y: b + 6))
    appendPins(to: &path, negated: negated, singleInput: false)
    return GlyphGeometry(stroked: path, lineWidth: 1)
  }

  /// `AbstractGate.paintIconBufferAnsi(g, negate, controlled)`:
  ///
  ///     v7 = neg >> 1 = 2   v8 = wh - v7 = 10   v10 = wh - neg = 8
  ///     drawPolygon([0, v10, 0, 0], [v7, wh>>1, v8, v7], 4)
  ///     paintIconPins(g, wh, border, neg, negate, /*singleInput*/ true)
  ///     if (controlled) drawLine(v10>>1, ((3*(v8-v7))>>2)+v7, v10>>1, v8)
  ///
  /// `NotGate.paintIcon` is this with `negate = true`; `Buffer.paintIcon` with both false.
  private static func bufferGeometry(negated: Bool, controlled: Bool) -> GlyphGeometry {
    let b = border
    var path = Path()
    path.move(to: CGPoint(x: b + 0, y: b + 2))
    path.addLine(to: CGPoint(x: b + 8, y: b + 6))
    path.addLine(to: CGPoint(x: b + 0, y: b + 10))
    path.closeSubpath()
    appendPins(to: &path, negated: negated, singleInput: true)
    if controlled {
      // The control stub hanging off the underside of the triangle.
      path.move(to: CGPoint(x: b + 4, y: b + 8))
      path.addLine(to: CGPoint(x: b + 4, y: b + 10))
    }
    return GlyphGeometry(stroked: path, lineWidth: 1)
  }

  /// `AbstractGate.paintIconPins(g, wh, border, negateSize, negate, singleInput)`, transcribed
  /// with `wh = 12`, `border = 2`, `negateSize = 4`:
  ///
  ///     if (negate) drawOval(wh - neg, (wh - neg) >> 1, neg, neg)      → (8, 4, 4, 4)
  ///     drawLine(wh - (negate ? 0 : neg), wh>>1, … + border, wh>>1)    → (8,6)-(10,6) or
  ///                                                                      (12,6)-(14,6)
  ///     singleInput ? drawLine(-border, wh>>1, 0, wh>>1)
  ///                 : drawLine(-border, wh>>2, 0, wh>>2)
  ///                   drawLine(-border, 3*wh>>2, 0, 3*wh>>2)
  ///
  /// Note the input stubs sit at **negative x** in the translated space, which is exactly what
  /// puts them in the 2pt border; they are not clipped, they are why the border exists.
  private static func appendPins(to path: inout Path, negated: Bool, singleInput: Bool) {
    let b = border
    if negated {
      path.addEllipse(in: CGRect(x: b + 8, y: b + 4, width: negateSize, height: negateSize))
    }
    let outputStart: CGFloat = negated ? 12 : 8
    path.move(to: CGPoint(x: b + outputStart, y: b + 6))
    path.addLine(to: CGPoint(x: b + outputStart + border, y: b + 6))

    if singleInput {
      path.move(to: CGPoint(x: b - border, y: b + 6))
      path.addLine(to: CGPoint(x: b + 0, y: b + 6))
    } else {
      for y in [CGFloat(3), CGFloat(9)] {
        path.move(to: CGPoint(x: b - border, y: b + y))
        path.addLine(to: CGPoint(x: b + 0, y: b + y))
      }
    }
  }

  /// Bottom → right → top, as two circle quarters. `κ` is the standard cubic approximation
  /// constant, `4/3·(√2 − 1)`; the error is under 0.03 % of the radius, i.e. invisible at 16pt.
  private static func appendRightSemicircle(
    to path: inout Path, centre c: CGPoint, radius r: CGFloat
  ) {
    let k = 0.552_284_749_830_793_6 * r
    path.addCurve(
      to: CGPoint(x: c.x + r, y: c.y),
      control1: CGPoint(x: c.x + k, y: c.y + r),
      control2: CGPoint(x: c.x + r, y: c.y + k))
    path.addCurve(
      to: CGPoint(x: c.x, y: c.y - r),
      control1: CGPoint(x: c.x + r, y: c.y - k),
      control2: CGPoint(x: c.x + k, y: c.y - r))
  }

  // ── Canvas tools and Pin ──────────────────────────────────────────────────────────────────

  /// `SelectIcon.paint(Graphics2D)`: `fillPolygon` over
  /// `xs = {3,3,7,10,11,9,14}`, `ys = {0,17,12,16,16,12,12}`, each coordinate `scale()`d.
  ///
  /// The arrow's tail reaches `y = 17` in a 16-unit box; upstream overshoots by one unit and
  /// this transcription keeps it, because the alternative is inventing a different arrow. The
  /// view does not clip, so it simply draws a hair below the nominal box.
  private static var selectArrowGeometry: GlyphGeometry {
    let xs: [CGFloat] = [3, 3, 7, 10, 11, 9, 14]
    let ys: [CGFloat] = [0, 17, 12, 16, 16, 12, 12]
    var path = Path()
    path.move(to: CGPoint(x: xs[0], y: ys[0]))
    for i in 1..<xs.count { path.addLine(to: CGPoint(x: xs[i], y: ys[i])) }
    path.closeSubpath()
    return GlyphGeometry(filled: path, lineWidth: 1)
  }

  /// `WiringTool.paintIcon`: a flat `int[8]` walked two at a time as `drawLine(a[i], a[i+1],
  /// a[i+2], a[i+3])`, i.e. the polyline `(3,13) → (8,13) → (8,3) → (13,3)`, stroked at
  /// `BasicStroke(getScaled(2))`.
  ///
  /// Upstream then paints a `Value.trueColor` dot at the free end. That is dropped here: the
  /// palette and sidebar render icons as monochrome templates that take the row's tint, and a
  /// single hard-coded green would be the one icon in the strip that ignores dark mode and
  /// selection highlighting.
  private static var wireGeometry: GlyphGeometry {
    var path = Path()
    path.move(to: CGPoint(x: 3, y: 13))
    path.addLine(to: CGPoint(x: 8, y: 13))
    path.addLine(to: CGPoint(x: 8, y: 3))
    path.addLine(to: CGPoint(x: 13, y: 3))
    return GlyphGeometry(stroked: path, lineWidth: 2)
  }

  /// `Pin.paintIcon(InstancePainter)`, `APPEAR_EVOLUTION_NEW` branch, with `size = 16`:
  ///
  ///     v8 = size >> 2 = 4      v10 = 10*size >> 4 = 10     v11 = 3*size >> 4 = 3
  ///     v12 = isOutput ? v8 : 0
  ///     ys = {v11, v11, v11 + (v10>>1), v11 + v10, v11 + v10}      = {3, 3, 8, 13, 13}
  ///     xs = {v12, v12 + size - 2*v8, v12 + size - v8, v12 + size - 2*v8, v12}
  ///                                                                = {c, c+8, c+12, c+8, c}
  ///     drawPolygon(xs, ys, 5)
  ///     isOutput ? drawLine(0, 8, v8, 8) : drawLine(size - v8, 8, size, 8)
  ///
  /// : a right-pointing pentagon with its lead on the far side from the point.
  ///
  /// **Only the input form is reachable from a `ToolItem` today.** The default template puts two
  /// `Pin` entries on the toolbar that differ solely by their attribute sets (`facing=west`,
  /// `output=true`), and `ToolItem` carries neither, so the palette cannot tell them apart. See
  /// the report; the fix belongs in `DomainTypes`/`ProjectOutlineBuilder`, not here.
  private static func pinGeometry(output: Bool) -> GlyphGeometry {
    let c: CGFloat = output ? 4 : 0
    let xs: [CGFloat] = [c, c + 8, c + 12, c + 8, c]
    let ys: [CGFloat] = [3, 3, 8, 13, 13]
    var path = Path()
    path.move(to: CGPoint(x: xs[0], y: ys[0]))
    for i in 1..<xs.count { path.addLine(to: CGPoint(x: xs[i], y: ys[i])) }
    path.closeSubpath()
    if output {
      path.move(to: CGPoint(x: 0, y: 8))
      path.addLine(to: CGPoint(x: 4, y: 8))
    } else {
      path.move(to: CGPoint(x: 12, y: 8))
      path.addLine(to: CGPoint(x: 16, y: 8))
    }
    return GlyphGeometry(stroked: path, lineWidth: 1)
  }

  /// `AbstractTtlGate.paintIcon(InstancePainter)`: a DIP seen from above:
  ///
  ///     fillRoundRect(4, 0, 8, 16, 3, 3)  /  drawRoundRect(4, 0, 8, 16, 3, 3)
  ///     for (i = 0; i < 3; i++) { fill+draw Rect(2, 5i+1, 3, 3); fill+draw Rect(12, 5i+1, 3, 3) }
  ///     drawRoundRect(6, 0, 6, 16, 3, 3)
  ///
  /// Java's `arcWidth`/`arcHeight` are full diameters, so the corner radius is `3/2`.
  ///
  /// **The colours are not transcribed.** Upstream fills the body `DARK_GRAY.brighter()` and the
  /// legs `LIGHT_GRAY` against a black outline, which is a light-mode-only palette: on a dark
  /// sidebar the body would nearly vanish and the outline entirely. The palette and sidebar
  /// render every other icon as a monochrome template that inherits the row's tint, including
  /// its selected and disabled states, so this one does too: body and groove stroked, legs
  /// filled. The shape, which is what identifies the part, is upstream's.
  private static var dipPackageGeometry: GlyphGeometry {
    var stroked = Path()
    var filled = Path()
    let radius: CGFloat = 1.5
    stroked.addRoundedRect(
      in: CGRect(x: 4, y: 0, width: 8, height: 16),
      cornerSize: CGSize(width: radius, height: radius))
    for i in 0..<3 {
      let y = CGFloat(i) * 5 + 1
      filled.addRect(CGRect(x: 2, y: y, width: 3, height: 3))
      filled.addRect(CGRect(x: 12, y: y, width: 3, height: 3))
    }
    stroked.addRoundedRect(
      in: CGRect(x: 6, y: 0, width: 6, height: 16),
      cornerSize: CGSize(width: radius, height: radius))
    return GlyphGeometry(stroked: stroked, filled: filled, lineWidth: 1)
  }
}

// MARK: - Drawing

/// Draws a `ToolGlyph` scaled from its 16×16 upstream box into whatever frame it is given.
///
/// `foregroundStyle` is deliberately *not* set here: the palette highlights the active tool and
/// the sidebar dims unavailable ones, so the glyph has to inherit the tint the way an
/// `Image(systemName:)` template does. Stroke width scales with the box, so the gate outlines
/// stay 1 upstream-unit thick at any size rather than going hairline when the icon grows.
struct ToolGlyphView: View {
  var glyph: ToolGlyph
  var size: CGFloat

  var body: some View {
    let geometry = glyph.geometry
    let scale = size / ToolGlyph.canonicalSize
    let transform = CGAffineTransform(scaleX: scale, y: scale)
    Canvas { context, _ in
      context.fill(geometry.filled.applying(transform), with: .style(.foreground))
      context.stroke(
        geometry.stroked.applying(transform), with: .style(.foreground),
        style: StrokeStyle(lineWidth: geometry.lineWidth * scale, lineJoin: .round))
    }
    .frame(width: size, height: size)
  }
}

/// The one place the palette and the sidebar ask "what does this tool look like".
///
/// Both call this rather than reaching for `item.symbolName` directly, so that adding an upstream
/// glyph lights it up in both surfaces at once; the previous arrangement had each view build its
/// own `Image(systemName:)` and there was no single place to change.
struct ToolIconView: View {
  var item: ToolItem
  var size: CGFloat = 16

  var body: some View {
    switch ToolIcons.icon(for: item) {
    case .upstream(let glyph):
      ToolGlyphView(glyph: glyph, size: size)
    case .symbol(let name), .fallback(let name):
      Image(systemName: name)
        .font(.system(size: size * 0.8))
        .frame(width: size, height: size)
    }
  }
}
