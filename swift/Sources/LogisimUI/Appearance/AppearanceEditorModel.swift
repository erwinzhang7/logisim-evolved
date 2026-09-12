// AppearanceEditorModel.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.gui.appear.{AppearanceView, AppearanceCanvas},
// com.cburch.draw.model.Drawing, com.cburch.draw.tools.SelectTool),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// THE MODEL BEHIND THE APPEARANCE PANE
//
// `EditorWindow.centre`'s `.appearance` arm used to be a `ContentUnavailableView`. Everything it
// needed already existed and was joined to nothing:
//
//   * `LogisimDraw`: 28 files, the full shape model **including `Drawing`**, which already has
//     `translateObjects`, `moveHandle`, `reorderObjects`, `setAttributeValues` and the
//     `CanvasModelEvent` vocabulary. Until today it was imported only by the codec.
//   * `CircuitAppearanceReader.shapes(for:)`: the parsed `<appear>` list, kept alive between
//     load and save in `CircuitAppearanceStore`.
//   * `AppearanceShapePainter`: `LogisimStd`, landed hours ago, paints one of those shapes into
//     a `SceneBuilder`.
//
// This file is the join, and it is deliberately thin: it owns no geometry, no drawing code and
// no serialisation. It owns exactly one thing, **the ordered shape list, including the entries
// this port does not model**, because that list is where D8 can be lost.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// D8, AND WHY THE MODEL IS NOT SIMPLY A `Drawing`
//
// Measured before writing a line of this file, by walking the 561 corpus files that carry an
// `<appear>`: the reader's list is `[AppearanceShape]`, i.e. `[AnyObject]`, and it holds **two
// disjoint kinds**,
//
//   * `CanvasObject`, every `draw.shapes` tag plus `circ-port`/`circ-anchor`. Modelled.
//   * `VerbatimAppearanceShape`; `visible-*` (`DynamicElement`) and any tag nothing recognises.
//     Kept as the original XML element. `CircuitAppearanceReader` is explicit that this is the
//     D8 trade, and `4.1.0__case-406.circ` is the corpus file that exercises it.
//
// `Drawing` is `[CanvasObject]`. A model that were *just* a `Drawing` therefore **cannot hold
// the second kind at all**, and the first save after opening such a file would drop the user's
// `visible-*` shapes; the precise failure D8 exists to forbid, and worse than the placeholder
// this replaces.
//
// So the model keeps the whole list and hands `Drawing` only the `CanvasObject` subset, with the
// verbatim entries' indices recorded so `commit()` can splice them back where they were. That
// splice is exact for every edit that does not reorder (move, attribute change, text edit) and
// is the reason `AppearanceRoundTripTests` asserts on *bytes*, not on a shape count.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// WHY EDITS GO THROUGH `Project.doAction`
//
// `Project.modelGuard` serialises actions against the propagation thread (see
// `ProjectModelGuardTests`, whose whole point is that a `doAction` which does *not* wait for
// `modelLock` races it silently). A shape list reachable from `CircuitAppearance.portOffsets`,
// which `SubcircuitFactory.computePorts` calls **on the simulation thread**, is exactly the
// kind of state that must not be mutated outside that guard. `AppearanceTranslateAction` is
// therefore the only writer; nothing here mutates a shape directly.

import CoreGraphics
import Foundation
import LogisimDraw
import LogisimFile
import LogisimKernel

// MARK: - Reaching the circuit and the project

/// What the appearance editor needs from the host, and nothing else.
///
/// A retroactive conformance rather than a member of `ProjectHost`: `Seams/ProjectSeam.swift`
/// and `Project/LogisimFileProjectHost.swift` are not this work's files to change, and the two
/// properties below are already `internal` on the host, so the conformance costs nothing and
/// leaves both files untouched. If the appearance editor grows past "read the circuit, submit an
/// action", promoting this onto `ProjectHost` proper is the right move: say so then rather than
/// widening this protocol.
@MainActor
protocol AppearanceHosting: AnyObject {
  var appearanceCircuit: Circuit? { get }
  var appearanceProject: Project? { get }
}

extension LogisimFileProjectHost: AppearanceHosting {
  var appearanceCircuit: Circuit? { currentCircuitObject }
  var appearanceProject: Project? { project }
}

// MARK: - The model

/// The live, editable `<appear>` of one circuit.
///
/// `com.cburch.logisim.circuit.appear.CircuitAppearance` is upstream's equivalent and is a
/// `Drawing` subclass owned by the `Circuit`. This port cannot put it there yet, `Circuit` is
/// in `LogisimFile`, which sits below `LogisimDraw`'s consumers and below this module, so the
/// shape list stays in `CircuitAppearanceStore` and this type is its editor-side view. See
/// `CircuitAppearanceWriter.swift`'s header, which predicted exactly this arrangement.
@MainActor
final class AppearanceEditorModel {

  /// D3: the circuit owns nothing here and nothing here owns the circuit.
  private(set) weak var circuit: Circuit?

  /// The modelled shapes, in bottom-to-top order. This is the array `Drawing` operates on.
  let drawing = Drawing()

  /// D8. The entries `Drawing` cannot hold, paired with the index they occupied in the reader's
  /// list. Splayed back in by `commit()`.
  private var verbatim: [(index: Int, shape: AppearanceShape)] = []

  /// How many shapes the reader produced. `commit()` must put back exactly this many or the
  /// writer's fidelity check will (correctly) refuse the model and fall back to the verbatim
  /// element; a silent no-op that would look like the editor working.
  private(set) var sourceShapeCount = 0

  /// Selected shapes, by identity (D4's rule, applied to the draw model: `CanvasObject` is a
  /// class and `MatchingSet` exists precisely because structural equality means something else
  /// here).
  private(set) var selection: [CanvasObject] = []

  init(circuit: Circuit?) {
    self.circuit = circuit
    reload()
  }

  // MARK: Loading

  /// Seeds from `CircuitAppearanceReader.shapes(for:)`.
  ///
  /// **The shape objects are shared, not copied.** `CircuitAppearanceStore` holds the same
  /// references, so this is not a snapshot: it is a second handle on the one model, which is
  /// what makes `commit()` cheap and what makes an uncommitted mutation a bug rather than a
  /// harmless local edit. Nothing below mutates a shape outside an `Action`.
  func reload() {
    drawing.removeObjects(drawing.objectsFromBottom)
    verbatim.removeAll()
    selection.removeAll()
    guard let circuit else {
      sourceShapeCount = 0
      return
    }
    let shapes = CircuitAppearanceSeam.shapes(for: circuit)
    sourceShapeCount = shapes.count
    var objects: [CanvasObject] = []
    for (index, shape) in shapes.enumerated() {
      if let object = shape as? CanvasObject {
        objects.append(object)
      } else {
        verbatim.append((index, shape))
      }
    }
    drawing.addObjects(at: 0, objects)
  }

  /// `CircuitAppearance.hasCustomAppearance()`; is there anything to edit?
  ///
  /// False both for a circuit whose appearance is one of the three defaults and for one whose
  /// `<appear>` yielded nothing. The pane says so rather than showing an empty canvas.
  var hasCustomAppearance: Bool {
    sourceShapeCount > 0
  }

  // MARK: Committing

  /// Puts the edited list back where the writer reads it, in the reader's original order.
  ///
  /// Routed through a `CircuitAppearanceSvgLoader` rather than at `CircuitAppearanceStore`
  /// directly, because the store is `internal` to `LogisimFile` and because `setAppearance` **is
  /// `setObjectsForce`**, whose re-layering pass (drawn shapes, then ports, then anchor) is
  /// observable in the saved file. Bypassing it would produce a different `<appear>` from the one
  /// the load path produces, which is the normalisation this editor must not do.
  ///
  /// A fresh loader rather than `CircuitAppearanceReader.handler`, deliberately: the handler is a
  /// mutable global (`public static var`), and reaching it from `@MainActor` code is a Swift 6
  /// concurrency error rather than merely untidy. `CircuitAppearanceSvgLoader` is stateless, its
  /// only field is the shared store, so constructing one costs nothing and the write lands in
  /// exactly the same place the installed handler's would. If it ever gains state, this is the
  /// line that has to change.
  func commit() {
    guard let circuit else { return }
    CircuitAppearanceSvgLoader().setAppearance(reassembled(), for: circuit)
    // A moved `circ-port`/`circ-anchor` changes what `getPortOffsets` returns, and the layout is
    // cached. Nothing else invalidates it, because nothing else knows the appearance moved.
    circuit.appearanceDidChangeForEditor()
  }

  /// The modelled list with the D8 entries put back at their recorded indices.
  ///
  /// Ascending index order matters: inserting at 7 then at 3 is not the same as 3 then 7. The
  /// reader produced `verbatim` in ascending order and nothing here reorders it, so the loop
  /// relies on that rather than re-sorting, and the clamp is what keeps a future add/remove
  /// from trapping here instead of merely misplacing a shape (D13: this is reachable from a
  /// user edit).
  private func reassembled() -> [AppearanceShape] {
    var out: [AppearanceShape] = drawing.objectsFromBottom
    for entry in verbatim {
      let index = min(max(entry.index, 0), out.count)
      out.insert(entry.shape, at: index)
    }
    return out
  }

  // MARK: Selection

  func setSelection(_ shapes: [CanvasObject]) {
    selection = shapes
  }

  func clearSelection() {
    selection.removeAll()
  }

  var selectionBounds: CGRect {
    var box = CGRect.null
    for shape in selection {
      box = box.union(AppearanceEditorModel.rect(shape.bounds))
    }
    return box
  }

  // MARK: Hit testing

  /// `SelectTool.getObjectAt(model, x, y, assumeFilled)`:
  ///
  /// ```java
  /// for (final var o : model.getObjectsFromTop()) {
  ///   if (o.contains(loc, assumeFilled)) return o;
  /// }
  /// return null;
  /// ```
  ///
  /// Top-first, first hit wins, and `assumeFilled` is upstream's way of letting a click inside an
  /// unfilled rectangle still select it when nothing else is under the pointer. Upstream calls
  /// this twice, once with `false`, then with `true`, from `mousePressed`; both arms are here
  /// because dropping the second makes every stroke-only shape (the common case in a hand-drawn
  /// symbol) unclickable except exactly on its outline.
  func shape(at point: CGPoint) -> CanvasObject? {
    let loc = Location.create(Int(point.x.rounded()), Int(point.y.rounded()), hasToSnap: false)
    for shape in drawing.objectsFromTop where !(shape is AppearanceElement) {
      if shape.contains(loc, assumeFilled: false) { return shape }
    }
    for shape in drawing.objectsFromTop where !(shape is AppearanceElement) {
      if shape.contains(loc, assumeFilled: true) { return shape }
    }
    return nil
  }

  // MARK: Geometry

  /// `nonisolated` because `AppearanceSceneSource` is deliberately actor-free; the whole point
  /// of that file being pure is that a headless test can call it, and a `@MainActor` helper
  /// reached from it would defeat that.
  nonisolated static func rect(_ bounds: Bounds) -> CGRect {
    CGRect(
      x: CGFloat(bounds.x), y: CGFloat(bounds.y),
      width: CGFloat(bounds.width), height: CGFloat(bounds.height))
  }
}

// MARK: - Cache invalidation

extension Circuit {
  /// `CircuitAppearance.fireCircuitAppearanceChanged(PORT_CHANGE)` → `PortManager.updatePorts`,
  /// reduced to the one effect this port has: drop `CircuitAppearance`'s cached
  /// `AppearanceLayout` and recompute every placement's ends.
  ///
  /// **Not a synthetic `CircuitEvent`.** `CircuitSubcircuitFactory.observeSource` invalidates the
  /// cache on `.add`/`.remove`/`.clear`/`.invalidate`/`.changeDefaultBoxAppearance`/`.setName`,
  /// and an appearance edit is none of those; firing one of them to get the side effect would
  /// also reach every *other* listener with a claim that is false. `CircuitSubcircuitFactory`
  /// already exposes the exact operation, for exactly this reason (its own header calls it "the
  /// end of a transaction"), so it is called directly.
  ///
  /// Moving a `circ-port` is the case that needs it: `portOffsets` feeds
  /// `SubcircuitFactory.computePorts`, so a parent circuit's wiring is wrong until this runs.
  /// Moving a `rect` needs nothing, and pays one cache drop for the simplicity of not asking.
  func appearanceDidChangeForEditor() {
    (subcircuitFactory as? CircuitSubcircuitFactory)?.refreshPortsAfterSourceChanged()
  }
}
