// XmlIterator.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution),
// specifically `src/main/java/com/cburch/logisim/file/XmlIterator.java`.
// logisim-evolution is free software released under the GNU GPLv3; this translation is
// therefore GPL-3.0-only. See LICENSE.md.

import Foundation

/// Java's `XmlIterator`, reduced to the three factory methods the reader actually calls.
///
/// Upstream's class is an `Iterable`+`Iterator`+`Cloneable` triple hat: `iterator()` clones
/// itself and resets the index so the same object can be re-iterated. Swift's `Array` gives
/// that for free, so the class collapses into static functions returning arrays.
///
/// **The one behavioural question this raises is snapshot-vs-live, and it is answered.**
/// `forChildElements` already materialises an `ArrayList` upstream, so those are snapshots in
/// Java too. `forDescendantElements` wraps `getElementsByTagName`, which returns a *live*
/// `NodeList`; a snapshot could diverge if the tree were mutated mid-iteration. Every one of
/// the four call sites was checked:
///
/// * `considerRepairs` → `convertObsoletePinAttributes` adds and removes `<a>` children only,
///   never a `<comp>` or `<tool>`, so neither list can change while it is being walked.
/// * `repairForLegacyLibrary` → both `findLibraryUses` calls fully drain the list into
///   `toRemove` *before* anything is removed. Note also that `root.removeChild(legacyElt)`
///   happens **first**, so tools nested inside the deleted `#Legacy` element are already
///   detached and are correctly not found; an ordering that must be preserved.
/// * `repairForWiringLibrary` → `updateFromLabelMap` only rewrites a `lib=` attribute.
///
/// So a snapshot is exact here. If a future repair deletes elements while iterating, this note
/// is where the equivalence stops holding.
public enum XmlIterator {

  /// Java: `XmlIterator.forChildElements(Element)`: direct element children, document order.
  public static func forChildElements(_ node: XMLElement) -> [XMLElement] {
    guard let children = node.children else { return [] }
    var result: [XMLElement] = []
    result.reserveCapacity(children.count)
    for child in children where child.kind == .element {
      if let element = child as? XMLElement { result.append(element) }
    }
    return result
  }

  /// Java: `XmlIterator.forChildElements(Element, String)`.
  ///
  /// Compares against `getTagName()` with `String.equals`, so this filters on the qualified
  /// name. Foundation's `elements(forName:)` applies its own prefix-matching rules, which is
  /// why the comparison is spelled out rather than delegated.
  public static func forChildElements(_ node: XMLElement, _ tagName: String) -> [XMLElement] {
    forChildElements(node).filter { $0.tagName == tagName }
  }

  /// Java: `XmlIterator.forDescendantElements(Element, String)` → `getElementsByTagName`.
  ///
  /// DOM specifies document order, i.e. preorder depth-first, and, importantly, the element
  /// the search starts from is *not* included even if its own tag matches.
  public static func forDescendantElements(_ node: XMLElement, _ tagName: String) -> [XMLElement] {
    var result: [XMLElement] = []
    func walk(_ element: XMLElement) {
      for child in element.children ?? [] where child.kind == .element {
        guard let childElement = child as? XMLElement else { continue }
        if childElement.tagName == tagName { result.append(childElement) }
        walk(childElement)
      }
    }
    walk(node)
    return result
  }
}
