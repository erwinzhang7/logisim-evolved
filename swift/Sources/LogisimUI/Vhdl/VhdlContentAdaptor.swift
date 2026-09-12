// VhdlContentAdaptor.swift: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
// SPDX-License-Identifier: GPL-3.0-only
//
// `LogisimVhdl` cannot depend on `LogisimFile`, and `LogisimFile` cannot depend on
// `LogisimVhdl`. The shipping UI sees both modules, so their reader and entity-factory seams
// close here.

import LogisimFile
import LogisimKernel
import LogisimVhdl

extension LogisimFile: VhdlNameCollisionChecking {}

extension VhdlContent: VhdlContentLoading, VhdlContentReference, VhdlContentSaving {
  public func parse(name: String, source: String, file: LogisimFile) -> AnyObject? {
    let parsed = VhdlContent.parse(name: name, vhdl: source, nameCollisionChecker: file)
    return parsed.isValid ? parsed : nil
  }

  public func setAppearance(_ appearance: AttributeOption, on content: AnyObject) {
    (content as? VhdlContent)?.setAppearance(appearance)
  }

  public func add(_ content: AnyObject, to file: LogisimFile) {
    guard let content = content as? VhdlContent else { return }
    file.addVhdlContent(content)
  }
}

/// The cross-module half of `com.cburch.logisim.vhdl.base.VhdlEntity`.
final class VhdlEntityAdaptor: AbstractComponentFactory, VhdlEntityFactory {
  let vhdlContent: VhdlContent

  var content: any VhdlContentReference { vhdlContent }

  init(content: VhdlContent) {
    self.vhdlContent = content
    super.init(requiresLabel: false, requiresGlobalClock: false)
  }

  override var name: String { vhdlContent.name }
  override var displayName: String { vhdlContent.name }

  override func createAttributeSet() -> any AttributeSet {
    VhdlEntityAttributes(content: vhdlContent)
  }

  override func createComponent(
    location: Location, attributes: any AttributeSet
  ) throws -> any Component {
    InstanceComponent(factory: self, location: location, attributes: attributes)
  }

  // ── `VhdlEntity.getOffsetBounds(AttributeSet)` ─────────────────────────────────────────────
  //
  // ```java
  // public Bounds getOffsetBounds(AttributeSet attrs) {
  //   if (appearance == null) return Bounds.create(0, 0, 100, 100);
  //   final var facing = attrs.getValue(StdAttr.FACING);
  //   return appearance.getOffsetBounds().rotate(Direction.EAST, facing, 0, 0);
  // }
  // ```
  //
  // ══ THIS OVERRIDE IS LOAD-BEARING FOR DATA, NOT ONLY FOR DRAWING ═══════════════════════════
  //
  // Without it the adaptor inherited `AbstractComponentFactory.offsetBounds`, which returns the
  // `Bounds.empty` SENTINEL: and `Bounds.empty.translate(dx, dy)` returns *itself*
  // (`Bounds.swift`, reproducing Java's `EMPTY_BOUNDS` identity semantics). So every placement of
  // every entity, at every location, reported the identical zero-area box, and
  // `XmlCircuitReader.buildCircuit`, whose `componentsAt` map is keyed by `Bounds`, read the
  // second placement as exactly overlapping the first, pushed it onto `overlapComponents`, and
  // then the nudge loop's `if bds.height == 0 || bds.width == 0 { continue }` DELETED it.
  //
  // A fixture placing one entity twice therefore loaded as three components instead of four. The
  // only trace was a recorded reader diagnostic that nobody reads and that is not even true:
  //
  //     Components sig(200,110) and sig(200,110) exactly overlap each other.
  //     One has been moved slightly. [main]
  //
  // Nothing was moved. That is what made the loss silent, and it is why the whole installation
  // was backed out on 2026-09-06 rather than shipped.
  //
  // **The reader is not the bug and must not be `fix`ed.** `XmlCircuitReader.java:238-245` drops
  // a zero-area overlapping component in exactly the same way; the port is faithful there. What
  // upstream never does is *hand it* a zero-area VHDL entity, because `VhdlEntity`'s constructor
  // assigns `appearance` before anything can ask, so the `appearance == null` arm above is
  // unreachable in 4.1.0. Fixing this anywhere but here would be a divergence from 4.1.0 that
  // silently changes what other degenerate components do.
  //
  // ── ORACLE ─────────────────────────────────────────────────────────────────────────────────
  //
  // `java -jar logisim-evolution-4.1.0-all.jar --toplevel-circuit main -tty stats` on the
  // two-placement fixture prints `2  2  sig` and totals of 4: upstream keeps BOTH. The port
  // keeping one was a defect, not a defensible difference.
  //
  // ── WHY THE GEOMETRY IS EXACT HERE, AND WHY IT IS DUPLICATED ───────────────────────────────
  //
  // `appearance` is `VhdlAppearance.create(getPins(), getName(), StdAttr.APPEAR_EVOLUTION)`, i.e.
  // `DefaultEvolutionAppearance.build(pins, name, fixedSize: TRUE)`, and `getOffsetBounds()` is
  // `getBounds(relativeToAnchor: true)`. With `fixedSize` true that builder's box collapses to a
  // function of the port COUNTS alone; `textWidth` is the constant `25 * FIXED_FONT_CHAR_WIDTH`,
  // so neither the labels nor the entity name can move it. Every input below is therefore
  // available from `VhdlContent` without a drawing tree, and this is upstream's number rather
  // than an approximation of it.
  //
  // `LogisimFile` already carries this formula twice, `CircuitAppearanceDefaults.evolution` and
  // `DefaultEvolutionAppearanceGeometry.offsetBounds(of:)`, but both are `internal` to that
  // module and this one is above it, so they are not reachable from here. Making them public is
  // an edit to a file this change does not own; the honest local move is the eleven lines below,
  // flagged so that whoever unifies them finds all three.
  override func offsetBounds(_ attributes: any AttributeSet) -> Bounds {
    // `getPins()`: `Pin.ATTR_TYPE = port.getType() == Port.INPUT ? Pin.INPUT : Pin.OUTPUT`, then
    // `DefaultEvolutionAppearance.build` sends `Pin.OUTPUT` east and everything else west. Note
    // the ternary is `== INPUT`, NOT `!= OUTPUT`: an `inout` port counts as an OUTPUT and lands
    // on the east edge. Only the two counts matter: `sortPinList` orders each edge, and the
    // ordering never reaches the box.
    var numEast = 0
    var numWest = 0
    for port in vhdlContent.ports {
      if port.direction == .input { numWest += 1 } else { numEast += 1 }
    }
    let maxVert = max(numEast, numWest)

    // `DrawAttr.FIXED_FONT_CHAR_WIDTH` = 8, `DrawAttr.FIXED_FONT_HEIGHT` = 12. Every operand is
    // non-negative, so Swift's `/` and `%` agree with Java's (they differ only for negatives).
    let fixedFontCharWidth = 8
    let fixedFontHeight = 12
    let dy = ((fixedFontHeight + (fixedFontHeight >> 2) + 5) / 10) * 10
    // `fixedSize` is hard `true` for a VHDL entity, so this is the `25 * charWidth` arm and the
    // `maxLeft + maxRight + 35` / `TitleWidth + 15` arm is unreachable. This is also why
    // `VhdlEntity` is the one caller that may pass a null name to `build`.
    let textWidth = 25 * fixedFontCharWidth
    let titleBarHeight = ((fixedFontHeight + 10) / 10) * 10
    let width = (textWidth / 10) * 10 + 20
    let height = (maxVert > 0) ? maxVert * dy + titleBarHeight : 10 + titleBarHeight

    // "compute position of anchor relative to top left corner of box", verbatim. `getOffsetBounds`
    // is the box translated by `-anchor`; the `OFFS`-based grid alignment of the box's own origin
    // cancels out of that difference, which is why it does not appear here.
    let ax: Int
    let ay: Int
    if numEast > 0 {
      ax = width
      ay = 10
    } else if numWest > 0 {
      ax = 0
      ay = 10
    } else {
      ax = 0
      ay = 0
    }

    // Non-degenerate unconditionally: `width` is the constant 220 and `height` is at least 30, so
    // this can never be `Bounds.empty` and can never re-enter the reader's discard branch: for
    // an entity with no ports at all, or one that failed to parse a single one.
    let box = Bounds.create(-ax, -ay, width, height)

    // `appearance.getOffsetBounds().rotate(Direction.EAST, facing, 0, 0)`. `CircuitAppearance`'s
    // facing is its anchor's, and `AppearanceAnchor`'s constructor assigns EAST, so a default
    // appearance, which is the only kind a VHDL entity has, always rotates *from* east.
    //
    // Read off `VhdlEntityAttributes` directly rather than through `StdAttr.facing`: that type
    // deliberately mints its own `Attribute` instances carrying Java's name strings (see its file
    // header), so the `StdAttr` singleton is NOT `===` the attribute this set holds and an
    // identity-keyed lookup would silently answer nil and pin every entity to east.
    let facing = (attributes as? VhdlEntityAttributes)?.currentFacing ?? .east
    return box.rotate(from: .east, to: facing, xc: 0, yc: 0)
  }
}
