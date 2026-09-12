// XmlDom.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// this file supplies the `org.w3c.dom` operations that `XmlReader.java`,
// `XmlCircuitReader.java` and `XmlIterator.java` are written against, mapped onto Foundation's
// `XMLDocument`/`XMLElement`. logisim-evolution is free software released under the GNU GPLv3;
// this translation is therefore GPL-3.0-only. See LICENSE.md.
//
// Foundation's XML tree is a real mutable DOM, which is why D-level guidance picks it over a
// SAX pass: the migration repairs in `considerRepairs` insert, move and delete live nodes
// (`insertBefore`, `removeChild`, `appendChild`, `setAttribute`), and those shapes map across
// one-for-one. The three places the two DOMs genuinely differ are called out below.

import Foundation

extension XMLElement {

  /// Java: `Element.getTagName()`.
  ///
  /// Java's parser runs namespace-aware, so `getTagName()` is the *qualified* name. Foundation's
  /// `name` is likewise qualified. No `.circ` file declares a namespace, so the two agree; the
  /// distinction is recorded only so a future namespaced file does not silently change meaning.
  var tagName: String { name ?? "" }

  /// Java: `Element.getAttribute(String)`.
  ///
  /// **Returns `""` for an absent attribute, never `nil`**; this is the single most
  /// consequential DOM convention in the reader. It is what makes upstream's `if (name == null
  /// || lib == null || ...)` guards dead code, and what makes `"".startsWith("label")` false
  /// rather than a crash in the `<2.6.3` repair. Modelling it as `String?` would quietly change
  /// the behaviour of half a dozen comparisons.
  func getAttribute(_ attributeName: String) -> String {
    attribute(forName: attributeName)?.stringValue ?? ""
  }

  /// Java: `Element.hasAttribute(String)`. Distinguishes "absent" from "present but empty",
  /// which `getAttribute` deliberately cannot.
  func hasAttribute(_ attributeName: String) -> Bool {
    attribute(forName: attributeName) != nil
  }

  /// Java: `Element.setAttribute(String, String)`.
  ///
  /// Updates the existing attribute node in place when there is one. Foundation's
  /// `addAttribute(_:)` is a no-op if an attribute of that name already exists, so the naive
  /// translation silently drops every rewrite the repairs perform: `select.setAttribute("name",
  /// EditTool._ID)` would do nothing. Mutating `stringValue` also preserves attribute order,
  /// matching the DOM's replace-in-place semantics.
  func setAttribute(_ attributeName: String, _ value: String) {
    if let existing = attribute(forName: attributeName) {
      existing.stringValue = value
    } else if let node = XMLNode.attribute(withName: attributeName, stringValue: value) as? XMLNode
    {
      addAttribute(node)
    }
  }

  /// Java: `Node.getTextContent()` for an element.
  ///
  /// **Deviation, documented rather than fixed.** Java's `DocumentBuilder` keeps
  /// whitespace-only text nodes; Foundation's `XMLDocument` discards them at parse time and
  /// offers no option to retain them (`.nodePreserveWhitespace` affects output, not parsing:
  /// verified). So `<a name="x">   </a>` yields `"   "` in Java and `""` here.
  ///
  /// Reachable only from `initAttributeSet`'s `<a>`-without-`val=` branch and from `<vhdl>`
  /// bodies. `<vhdl>` bodies are never whitespace-only, and every attribute parser in the
  /// kernel trims before use, so no known attribute changes value. It is recorded because it
  /// is the one lossy step in the DOM mapping.
  var textContent: String { stringValue ?? "" }

  /// Java: `Node.removeChild(Node)`.
  ///
  /// Foundation exposes removal by index, so this resolves the index first. Java throws
  /// `NOT_FOUND_ERR` when the node is not a child; every call site in the reader has just
  /// found the node by walking this element's children, so a mismatch is a programmer error
  /// and not something a `.circ` file can provoke (D13 keeps the trap).
  func removeChild(_ child: XMLNode) {
    precondition(child.parent === self, "removeChild: node is not a child of this element")
    removeChild(at: child.index)
  }

  /// Java: `Node.insertBefore(Node, Node)`.
  ///
  /// A `nil` reference node appends, exactly as the DOM specifies, which is the branch
  /// `repairFloatLibrary` relies on when `#Arithmetic` is the last child of the root.
  ///
  /// Note the whitespace difference has no effect here. Java's `lastLibElt.getNextSibling()`
  /// is usually the indentation text node, so upstream inserts *before* that whitespace;
  /// Foundation has no such node and inserts before the following element. The resulting
  /// **element** order is identical, and the reader only ever iterates elements.
  func insertBefore(_ newChild: XMLNode, _ referenceChild: XMLNode?) {
    newChild.detach()
    if let reference = referenceChild, reference.parent === self {
      insertChild(newChild, at: reference.index)
    } else {
      addChild(newChild)
    }
  }

  /// Java: `Node.appendChild(Node)`. Detaches first so a node can be *moved* between parents,
  /// which is what `relocateTools` and `repairFloatLibrary` both do.
  func appendChild(_ newChild: XMLNode) {
    newChild.detach()
    addChild(newChild)
  }

  /// Java: `doc.createElement(tag)` followed by `setAttribute` calls.
  ///
  /// Foundation nodes are not bound to a document until they are inserted, so the `Document`
  /// argument upstream threads through `appendChildAttribute`, `repairForWiringLibrary`,
  /// `repairForLegacyLibrary` and `repairFloatLibrary` has no counterpart. The parameter is
  /// kept on the public entry points for shape fidelity and ignored.
  static func createElement(_ tag: String, attributes: [(String, String)] = []) -> XMLElement {
    let element = XMLElement(name: tag)
    for (attributeName, value) in attributes {
      element.setAttribute(attributeName, value)
    }
    return element
  }
}
