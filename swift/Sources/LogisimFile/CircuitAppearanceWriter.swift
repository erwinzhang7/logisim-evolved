// CircuitAppearanceWriter.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution): the
// `CircuitAppearance.getCustomObjectsFromBottom()` / `AbstractCanvasObject.toSvgElement(Document)`
// pair that `XmlWriter.fromCircuit` drives. Copyright by the Logisim-evolution developers. This
// translation is a derivative work and is therefore licensed GPL-3.0-only. See LICENSE.md.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// WHERE THE SHAPES COME FROM
//
// Upstream asks a live `CircuitAppearance`, a `CanvasModel` the editor mutates, for its
// objects. This port has no such model yet (the appearance editor is M6/M7), so the list is the
// one the *reader* produced, held in `CircuitAppearanceStore` between load and save.
//
// A side table rather than a field on `Circuit`, for one reason: `Circuit.swift` is not this
// seam's to change, and the seam is deliberately reversible; `CircuitAppearanceSeam.uninstall()`
// puts the file back on the pure-D8 verbatim path with no residue anywhere else. When M6 builds
// the real `CircuitAppearance`, the model becomes a field on `Circuit`, this store goes away, and
// `CircuitAppearanceSaving` keeps working unchanged because it only ever asks for elements.
//
// The keys are **weak**: a `Circuit` that goes away must not be kept alive by its own drawing,
// and D3 requires every weak-collection site to say so. `NSMapTable` with weak keys drops the
// entry when the circuit is collected.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// THE FIDELITY CHECK, AND WHY IT IS NOT PARANOIA
//
// `hasCustomAppearance` is what chooses between this model-driven path and D8's verbatim one
// (`XmlWriter.fromCircuit` tests it first, and falls through to `CircuitAppearancePreserving`
// only when it is false). Answering `true` is therefore a claim that the model can reproduce the
// whole section, and if it cannot, the difference is not a formatting wobble, it is a shape
// deleted from the user's file.
//
// So the claim is *checked* rather than assumed: the stored list must have exactly one entry per
// child element of the `<appear>` the reader saw. Anything less means a shape was dropped along
// the way, and the verbatim element is written instead. The check costs one integer comparison
// and it converts every future parsing gap in this seam from silent data loss into a
// no-op, which, given that the writer is the last thing to touch the file before it hits disk,
// is the right default.
//
// It has one *known* false positive, and it is deliberate: a `<circ-port>` naming a pin the
// circuit no longer has is dropped on purpose (upstream drops it too), and this check reads that
// as infidelity and keeps the stale port. Preferring a stale port over a deleted one is the
// conservative direction, and no corpus file exercises it; measured: enabling the check costs
// zero files on either gate.

import Foundation
import LogisimDraw
import LogisimKernel

// MARK: - Load-to-save storage

/// The parsed `<appear>` shapes for each loaded circuit.
///
/// See the file header for why this is a side table and why the keys are weak. Access is
/// serialised because a `.circ` load and a save can be driven from different threads; the lock
/// is uncontended in the CLI and is here for correctness, not throughput.
final class CircuitAppearanceStore {
  static let shared = CircuitAppearanceStore()

  /// Boxed because `NSMapTable` stores objects and the value is a Swift array.
  private final class Box {
    let shapes: [AppearanceShape]
    init(_ shapes: [AppearanceShape]) { self.shapes = shapes }
  }

  private let lock = NSLock()
  private let table = NSMapTable<AnyObject, Box>.weakToStrongObjects()

  func set(_ shapes: [AppearanceShape], for circuit: Circuit) {
    lock.lock()
    defer { lock.unlock() }
    table.setObject(Box(shapes), forKey: circuit)
  }

  func shapes(for circuit: AnyObject) -> [AppearanceShape]? {
    lock.lock()
    defer { lock.unlock() }
    return table.object(forKey: circuit)?.shapes
  }

  func clear(for circuit: AnyObject) {
    lock.lock()
    defer { lock.unlock() }
    table.removeObject(forKey: circuit)
  }
}

// MARK: - The handler

/// `circuit.getAppearance()`, reduced to what `XmlWriter.fromCircuit` asks of it.
public final class CircuitAppearanceSvgSaver: CircuitAppearanceSaving {

  public init() {}

  /// `circuit.getAppearance().hasCustomAppearance()`, plus the fidelity check described in the
  /// file header.
  public func hasCustomAppearance(_ circuit: any CircuitSaving) -> Bool {
    guard let shapes = CircuitAppearanceStore.shared.shapes(for: circuit as AnyObject),
      !shapes.isEmpty
    else { return false }
    guard let raw = (circuit as? any CircuitAppearancePreserving)?.appearanceElement else {
      // No verbatim element to fall back to, so the model is all there is. This is the shape a
      // circuit built in memory would have once the editor exists.
      return true
    }
    return shapes.count == Self.childElementCount(of: raw)
  }

  /// One element per shape, in the order the reader produced them, which is the order they
  /// appeared in the document, `visible-*` elements included: `XmlCircuitReader
  /// .buildDynamicAppearance` re-inserts those at the layer index they occupied originally.
  ///
  /// That reproduces `getCustomObjectsFromBottom()`, whose order is the same one upstream read.
  /// The `<circ-port>` children are re-sorted afterwards by `XmlWriter.sort`, which special-cases
  /// `appear` and moves them to the end; everything else keeps the order returned here.
  public func appearanceElements(for circuit: any CircuitSaving) -> [XMLElement] {
    guard let shapes = CircuitAppearanceStore.shared.shapes(for: circuit as AnyObject) else {
      return []
    }
    return shapes.compactMap(Self.element(for:))
  }

  // MARK: - Shape → element

  /// `AbstractCanvasObject.toSvgElement(doc)`, plus D8's verbatim carrier.
  ///
  /// Java's contract is that a null return is skipped, which is what `compactMap` above does.
  static func element(for shape: AppearanceShape) -> XMLElement? {
    if let verbatim = shape as? VerbatimAppearanceShape {
      // A copy, for the same reason `fromComponent`/`fromTool`/`fromMap` all copy: appending the
      // stored node itself would re-parent it out of the model and empty it on the first save.
      guard let duplicate = verbatim.element.copy() as? XMLElement else { return nil }
      duplicate.detach()
      return duplicate
    }
    guard let object = shape as? AbstractCanvasObject else { return nil }
    return element(from: object.toSvgElement())
  }

  /// `LogisimDraw.SvgElement` → `XMLElement`.
  ///
  /// **The attribute order comes from `SvgElement.attributes`, which is alphabetical in UTF-16
  /// code-unit order, and it is load-bearing.** Upstream serialises through `DocumentBuilder`/
  /// `Transformer`, i.e. the JDK's Xerces DOM, whose `NamedNodeMapImpl` keeps attributes in a
  /// binary-searched sorted list, so every element 4.1.0 writes comes out name-sorted whatever
  /// order it was built in. Verified against all 577 harvested corpus files: every observed form
  /// is sorted. Note the comparison is UTF-16 code units (`java.lang.String.compareTo`), not
  /// Swift's `String.<`, which orders by canonical equivalence and disagrees; `SvgElement` does
  /// that comparison, and this function must not re-sort or reorder what it hands back.
  static func element(from svg: SvgElement) -> XMLElement {
    let element = XMLElement.createElement(svg.tagName)
    for (name, value) in svg.attributes {
      element.setAttribute(name, value)
    }
    if !svg.textContent.isEmpty {
      element.appendChild(XmlWriter.textNode(svg.textContent))
    }
    return element
  }

  /// The number of *element* children of an `<appear>`, which is what the reader counted when it
  /// walked it; `XmlIterator.forChildElements` skips text and comment nodes.
  static func childElementCount(of appear: XMLElement) -> Int {
    (appear.children ?? []).reduce(0) { $0 + (($1 as? XMLElement) == nil ? 0 : 1) }
  }
}
