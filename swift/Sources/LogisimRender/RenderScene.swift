// LogisimRender: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// The retained scene (D6).
//
// Two halves, deliberately separated:
//
//   IMMUTABLE GEOMETRY   primitives, points, pathOps, texts, images, transforms, groups,
//                        palette, index: built once by `SceneBuilder`, never mutated.
//
//   PER-FRAME STATE      `colorSlots`, a flat `[PaletteIndex]`. This is the *entire* delta
//                        between two simulation frames, because wire endpoints do not move.
//
// A frame is therefore: write a handful of `UInt16`s, then draw. At M9 that becomes "leave
// the vertex buffers resident, upload `colorSlots`, issue one instanced draw", with no change
// to any of the component draw implementations.

import LogisimKernel

// MARK: - RenderScene

public struct RenderScene: Sendable {

  // --- immutable geometry -------------------------------------------------------------

  public private(set) var primitives: [ScenePrimitive]
  public private(set) var points: [ScenePoint]
  public private(set) var pathOps: [PathOp]
  public private(set) var texts: [TextRun]
  public private(set) var images: [SceneImageRef]
  /// `transforms[0]` is always identity.
  public private(set) var transforms: [SceneTransform]
  public private(set) var groups: [SceneGroup]
  public private(set) var palette: ScenePalette
  public private(set) var bounds: SceneBounds
  public private(set) var index: SpatialIndex

  // --- per-frame ----------------------------------------------------------------------

  /// slot -> palette index. The only thing that changes while a simulation runs.
  public private(set) var colorSlots: [PaletteIndex]

  /// Slots the builder marked dynamic, i.e. the ones a per-frame update is expected to touch.
  /// Static slots are shared and interned; writing one would recolour unrelated primitives,
  /// so `setColor` refuses.
  public private(set) var dynamicSlots: Set<ColorSlot>

  init(
    primitives: [ScenePrimitive],
    points: [ScenePoint],
    pathOps: [PathOp],
    texts: [TextRun],
    images: [SceneImageRef],
    transforms: [SceneTransform],
    groups: [SceneGroup],
    palette: ScenePalette,
    colorSlots: [PaletteIndex],
    dynamicSlots: Set<ColorSlot>,
    cellSize: Int32
  ) {
    self.primitives = primitives
    self.points = points
    self.pathOps = pathOps
    self.texts = texts
    self.images = images
    self.transforms = transforms
    self.groups = groups
    self.palette = palette
    self.colorSlots = colorSlots
    self.dynamicSlots = dynamicSlots

    var b = SceneBounds.empty
    for g in groups { b.formUnion(g.bounds) }
    self.bounds = b
    self.index = SpatialIndex(groups: groups, cellSize: cellSize)
  }

  /// An empty scene. Rendering it is a no-op.
  public static let empty = RenderScene(
    primitives: [], points: [], pathOps: [], texts: [], images: [],
    transforms: [.identity], groups: [], palette: ScenePalette(),
    colorSlots: [], dynamicSlots: [], cellSize: SpatialIndex.defaultCellSize)

  public var isEmpty: Bool { primitives.isEmpty }

  // MARK: Per-frame colour update

  /// Repoints a **dynamic** slot at a different palette entry. This is the per-frame write.
  ///
  /// Returns `false` and does nothing if the slot is static or out of range; a static slot is
  /// shared by every primitive that asked for the same colour, so honouring the write would
  /// silently recolour unrelated geometry. Failing visibly beats corrupting the frame.
  @discardableResult
  public mutating func setColor(_ slot: ColorSlot, to index: PaletteIndex) -> Bool {
    let i = Int(slot.rawValue)
    guard i >= 0, i < colorSlots.count, dynamicSlots.contains(slot) else { return false }
    colorSlots[i] = index
    return true
  }

  @discardableResult
  public mutating func setColor(_ slot: ColorSlot, to value: ValuePaletteConvertible) -> Bool {
    setColor(slot, to: PaletteIndex(value.scenePaletteSlot))
  }

  /// Bulk form. `updates` is `(slot, index)` pairs; ordering does not matter.
  public mutating func applyColorUpdates(_ updates: [(ColorSlot, PaletteIndex)]) {
    for (slot, index) in updates { setColor(slot, to: index) }
  }

  public func colorIndex(of slot: ColorSlot) -> PaletteIndex {
    let i = Int(slot.rawValue)
    guard i >= 0, i < colorSlots.count else { return PaletteIndex(rawValue: 0) }
    return colorSlots[i]
  }

  /// Fully resolved colour for a primitive, under a theme.
  public func color(of slot: ColorSlot, theme: ValueColorTheme = .logisim) -> RGBA {
    palette.resolve(colorIndex(of: slot), theme: theme)
  }

  // MARK: Culling

  /// Groups whose bounds intersect `rect`, in painter's order.
  public func visibleGroups(in rect: SceneBounds) -> [Int32] {
    guard !groups.isEmpty else { return [] }
    let candidates = index.groupsIntersecting(rect, groupCount: groups.count)
    // The index is conservative at bucket granularity; this second test is exact.
    return candidates.filter { groups[Int($0)].bounds.intersects(rect) }
  }

  /// Walks every primitive that survives culling, in draw order.
  ///
  /// Group bounds reject the bulk of a large schematic in one test each; the per-primitive
  /// test then catches the leftovers inside a partially visible component. Upstream does
  /// neither: it repaints every component in the circuit on every frame, which is what the
  /// 20 fps cap in `CanvasPaintCoordinator` is really defending against.
  public func forEachVisiblePrimitive(
    in rect: SceneBounds, _ body: (ScenePrimitive) throws -> Void
  ) rethrows {
    for gi in visibleGroups(in: rect) {
      let group = groups[Int(gi)]
      for pi in group.range {
        let prim = primitives[pi]
        if prim.bounds.intersects(rect) {
          try body(prim)
        }
      }
    }
  }

  /// Count of primitives that would be drawn for `rect`. Diagnostics, and the number the
  /// culling tests assert on.
  public func visiblePrimitiveCount(in rect: SceneBounds) -> Int {
    var n = 0
    forEachVisiblePrimitive(in: rect) { _ in n += 1 }
    return n
  }

  // MARK: Hit testing

  /// Group tags whose bounds contain the point, **topmost first** (reverse paint order).
  ///
  /// The same index that culls answers this, so the UI needs no second structure, which is the
  /// point of `SceneGroup.tag` carrying `ObjectIdentifier`-derived component identity (D4).
  /// Bounds-level only: a caller wanting exact geometry filters this shortlist.
  public func hitTest(x: Int32, y: Int32) -> [UInt64] {
    let probe = SceneBounds(minX: x, minY: y, maxX: x, maxY: y)
    return visibleGroups(in: probe).reversed().map { groups[Int($0)].tag }
  }

  /// Convenience for the common "what did the user click" question.
  public func topmostTag(atX x: Int32, y: Int32) -> UInt64? {
    hitTest(x: x, y: y).first { $0 != 0 }
  }

  // MARK: Pool access

  public func transform(_ prim: ScenePrimitive) -> SceneTransform {
    let i = Int(prim.transform)
    guard i >= 0, i < transforms.count else { return .identity }
    return transforms[i]
  }

  public func textRun(_ prim: ScenePrimitive) -> TextRun? {
    guard prim.kind == .text else { return nil }
    let i = Int(prim.poolOffset)
    guard i >= 0, i < texts.count else { return nil }
    return texts[i]
  }

  public func imageRef(_ prim: ScenePrimitive) -> SceneImageRef? {
    guard prim.kind == .image else { return nil }
    let i = Int(prim.poolOffset)
    guard i >= 0, i < images.count else { return nil }
    return images[i]
  }
}

// MARK: - ValuePaletteConvertible

/// Anything that names a simulation palette slot.
///
/// `LogisimKernel.Value.paletteIndex` returns a `ValuePalette` (D9), so a per-frame update
/// reads `scene.setColor(slot, to: state.getValue(loc).paletteIndex)` with no colour type
/// crossing the module boundary in either direction.
public protocol ValuePaletteConvertible {
  var scenePaletteSlot: ValuePalette { get }
}

extension ValuePalette: ValuePaletteConvertible {
  public var scenePaletteSlot: ValuePalette { self }
}
