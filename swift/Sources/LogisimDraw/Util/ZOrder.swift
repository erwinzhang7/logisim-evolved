// ZOrder.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// com/cburch/draw/util/ZOrder.java. Copyright by the Logisim-evolution developers. This
// translation is a derivative work and is therefore licensed GPL-3.0-only. See LICENSE.md.

/// `com.cburch.draw.util.ZOrder`.
public enum ZOrder {
  private static func index(of query: CanvasObject, in objects: [CanvasObject]) -> Int {
    objects.firstIndex { $0 === query } ?? -1
  }

  /// Returns the first object above `query` in z-order that overlaps it, ignoring anything in
  /// `ignore`.
  public static func objectAbove(
    _ query: CanvasObject, in model: CanvasModel, ignoring ignore: [CanvasObject]
  ) -> CanvasObject? {
    previous(query, model.objectsFromTop, model, ignore)
  }

  /// Returns the first object below `query` in z-order that overlaps it, ignoring anything in
  /// `ignore`.
  public static func objectBelow(
    _ query: CanvasObject, in model: CanvasModel, ignoring ignore: [CanvasObject]
  ) -> CanvasObject? {
    previous(query, model.objectsFromBottom, model, ignore)
  }

  private static func previous(
    _ query: CanvasObject, _ objects: [CanvasObject], _ model: CanvasModel,
    _ ignore: [CanvasObject]
  ) -> CanvasObject? {
    let idx = index(of: query, in: objects)
    guard idx > 0 else { return nil }
    let overlapping = model.objectsOverlapping(query)
    for i in stride(from: idx - 1, through: 0, by: -1) {
      let o = objects[i]
      if overlapping.contains(where: { $0 === o }) && !ignore.contains(where: { $0 === o }) {
        return o
      }
    }
    return nil
  }

  /// `0` for the bottommost element, larger for higher up.
  public static func zIndex(of query: CanvasObject, in model: CanvasModel) -> Int {
    index(of: query, in: model.objectsFromBottom)
  }

  /// `0` for the bottommost element, larger for higher up, for every object in `query`.
  public static func zIndex(
    of query: [CanvasObject], in model: CanvasModel
  ) -> [(object: CanvasObject, index: Int)] {
    var result: [(CanvasObject, Int)] = []
    var z = -1
    for o in model.objectsFromBottom {
      z += 1
      if query.contains(where: { $0 === o }) {
        result.append((o, z))
      }
    }
    return result
  }

  public static func sortBottomFirst<E: CanvasObject>(_ objects: [E], in model: CanvasModel) -> [E] {
    sortXFirst(objects, model.objectsFromTop)
  }

  public static func sortTopFirst<E: CanvasObject>(_ objects: [E], in model: CanvasModel) -> [E] {
    sortXFirst(objects, model.objectsFromBottom)
  }

  private static func sortXFirst<E: CanvasObject>(_ objects: [E], _ ordered: [CanvasObject]) -> [E] {
    ordered.compactMap { o in objects.first { $0 === o } }
  }
}
