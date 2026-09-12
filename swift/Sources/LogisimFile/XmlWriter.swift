// XmlWriter.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.file.XmlWriter),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
// SPDX-License-Identifier: GPL-3.0-only
//
// ═══════════════════════════════════════════════════════════════════════════════════════════
// The pass condition is BYTE-EXACT output, so almost nothing here is cosmetic.
// ═══════════════════════════════════════════════════════════════════════════════════════════
//
// Upstream builds an `org.w3c.dom.Document`, sorts parts of it, and hands it to a JAXP identity
// `Transformer` with `INDENT=yes`, `indent-amount=2` and `ENCODING=UTF-8`. The bytes that come
// out are therefore specified by *the JDK's serializer*, not by the XML spec; the resolved
// handler is `com.sun.org.apache.xml.internal.serializer.ToXMLStream`. `XmlSerializer` below is
// a port of the parts of `ToStream` this DOM shape can reach, read out of JDK 21's own
// `src.zip` and then verified byte-for-byte against real `-n(-n(f))` converter output. The four
// rules a plausible pretty-printer gets wrong are documented on `XmlSerializer` itself.
//
// ── What did not come across ────────────────────────────────────────────────────────────────
//
//   * `ZipOutputStream` project-bundle export. `Loader.write` returns `Data` in this port, so
//     there is no stream to push zip entries into. `isProjectExport` and every branch it guards
//     ARE ported; with no `ProjectBundleSink` installed they take the path Java takes when
//     `Loader.getZipFile()` returns null, which is "leave the descriptor alone". No behaviour is
//     lost, only an unexercised path.
//   * `AppPreferences.REMOVE_UNUSED_LIBRARIES`. D9 keeps preferences out of this layer, so it is
//     a property on the writer carrying upstream's default of `false`
//     (`AppPreferences.java:569-570`), which is why a saved file still declares all twelve
//     builtin libraries while instantiating from two or three.
//   * `writeJarToZip` / `writeLogisimFileToZip`, for the same reason; both are behind the sink.

import Foundation
import LogisimKernel

// MARK: - BuildInfo

/// `com.cburch.logisim.generated.BuildInfo`, which upstream generates at build time.
///
/// Declared here because the writer needs three of its fields and is the only place they are
/// load-bearing: `version` is written as `source=` and is the version every attribute default is
/// resolved against, while `displayName` and `url` are interpolated into the banner text node
/// inside `<project>`. A wrong string in any of the three is a byte diff on every saved file, so
/// all three are the values the shipped 4.1.0 oracle jar reports through reflection rather than
/// guesses. `XmlReader` reads `version` from here too.
///
/// Upstream's own `gradle.properties` currently says `4.2.0-dev`; the port pins 4.1.0 because
/// that is what the differential oracle *is*, so both sides ask
/// `getDefaultAttributeValue(attr, ver)` the same question. It is a `var` so a harness can pin a
/// different one.
public enum BuildInfo {
  /// `BuildInfo.version`.
  public static var version = LogisimVersion(4, 1, 0)
  /// `BuildInfo.name`.
  public static let name = "Logisim-evolution"
  /// `BuildInfo.displayName`, `"Logisim-evolution v4.1.0"`.
  public static let displayName = "Logisim-evolution v4.1.0"
  /// `BuildInfo.url`.
  public static let url = "https://github.com/logisim-evolution/"
}

// MARK: - Tool as an AttributeDefaultProvider

// Java declares `public abstract class Tool implements AttributeDefaultProvider`, and both
// halves of the `.circ` codec depend on it: the reader at four call sites, the writer at three.
// It must exist exactly once, and it lives here because the writer is where getting it wrong is
// visible: `AddTool`'s override is what makes a `<lib>`'s `<tool>` entries compare against
// *factory* defaults, and without it every saved attribute of every library tool would be
// written out.
//
// **Mechanism deviation, no behavioural one.** A protocol conformance added in an extension is
// statically dispatched, so `AddTool` cannot override a witness declared on `Tool`. The
// forwarding is therefore written as the type tests it stands for. Upstream has exactly three
// implementations of `getDefaultAttributeValue`, `Tool` → null, `AddTool` → `getFactory()`,
// `TextTool` → `Text.FACTORY`, so the downcasts are total and the answer is identical for every
// possible receiver.

extension Tool: AttributeDefaultProvider {
  /// `Tool.getDefaultAttributeValue` returns null; `AddTool` and `TextTool` delegate to a
  /// factory.
  ///
  /// `TextTool`'s arm is not decoration. Its `null` would make the first write condition in
  /// `addAttributeSetContent` (`dflt == nil`) true for every attribute, so a Text Tool carrying
  /// nothing but a non-default font would save all five of `text`, `font`, `color`, `halign` and
  /// `valign` where the oracle saves `font` alone.
  public func defaultAttributeValue(
    _ attribute: AnyAttribute, version: LogisimVersion
  ) -> AttributeValue? {
    if let addTool = self as? AddTool {
      return addTool.factory.defaultAttributeValue(attribute, version: version)
    }
    if let textTool = self as? TextTool {
      return textTool.textFactory.defaultAttributeValue(attribute, version: version)
    }
    return nil
  }

  /// `Tool.isAllDefaultValues` returns false.
  ///
  /// `AddTool.isAllDefaultValues` is `attrs == attributeSet && attributeSet instanceof
  /// FactoryAttributes f && !f.isFactoryInstantiated()`; it asks whether the tool's own *lazily*
  /// created attribute set has ever been forced into existence. `FactoryAttributes` is a
  /// component-tranche type (M4/M5) with no port yet, and the test is false for every set that is
  /// not one, so the port answers false.
  ///
  /// The consequence for the writer is nil, and that is worth stating rather than assuming: when
  /// the shortcut is false, `addAttributeSetContent` still runs and still finds every attribute
  /// equal to its factory default, produces no `<a>` children, and `fromLibrary` drops the empty
  /// `<tool>`; the same output by a longer route. The only thing lost is upstream's avoidance of
  /// materialising a set nobody touched.
  public func isAllDefaultValues(
    _ attributes: any AttributeSet, version: LogisimVersion
  ) -> Bool {
    false
  }
}

// MARK: - Errors

/// The failures `XmlWriter` can report.
///
/// D13: every one of these stands for a Java exception that escapes `XmlWriter` into
/// `Loader.save`'s `catch`, where it becomes "Error while saving file: …". None may trap; a
/// malformed model must not take the process down along with the user's unsaved work.
public enum XmlWriterError: Error, CustomStringConvertible, Equatable {
  /// Java: `NullPointerException` from `toolElt.setAttribute(…)` / `elt.appendChild(…)` after
  /// `fromTool` returned null; a toolbar button or mouse binding whose library cannot be found.
  case toolNotFound(String)
  /// Java: `ClassCastException` inside `attr.toStandardString(val)` when the stored value is not
  /// of the attribute's own type. Unreachable through a well-formed `AttributeSet`; kept because
  /// D5's `.opaque` storage makes the type recoverable only at run time.
  case unrepresentableAttributeValue(attribute: String)
  /// Java: `Paths.relativize` throwing `IllegalArgumentException` for a `filePath` attribute
  /// that mixes an absolute path with a relative one.
  case cannotRelativize(base: String, target: String)
  /// Java: `org.xml.sax.SAXException("An invalid XML character (Unicode: 0x…) was found …")`,
  /// which the transformer wraps in a `TransformerException`.
  case invalidXmlCharacter(scalar: UInt32)
  /// Java: `value.isEmpty()` on the null `Text.ATTR_TEXT` of a `Text` component, an NPE.
  case missingTextAttribute
  /// A `<vhdl>` entity whose implementation does not provide the saving seam. No upstream
  /// counterpart: upstream's `VhdlContent` is a concrete class.
  case vhdlContentCannotBeSaved(String)

  public var description: String {
    switch self {
    case .toolNotFound(let name): return "tool `\(name)' not found"
    case .unrepresentableAttributeValue(let attribute):
      return "attribute \(attribute) holds a value it cannot render"
    case .cannotRelativize(let base, let target):
      return "cannot relativize '\(target)' against '\(base)'"
    case .invalidXmlCharacter(let scalar):
      return String(format: "An invalid XML character (Unicode: 0x%x) was found", scalar)
    case .missingTextAttribute:
      return "a Text component carries no `text' attribute"
    case .vhdlContentCannotBeSaved(let name):
      return "VHDL entity \u{2018}\(name)\u{2019} does not implement the .circ saving seam"
    }
  }
}

// MARK: - Java String.compareTo

/// Java's `String.compareTo`, which is **UTF-16 code-unit lexicographic order**.
///
/// Swift's `<` on `String` compares by Unicode canonical equivalence over grapheme clusters and
/// disagrees with Java on combining sequences and on any string containing an astral character
/// (Swift orders by scalar, Java by surrogate code unit). Every ordering decision in
/// `XmlWriter.sort` and in attribute serialisation is Java's, so it goes through here.
///
/// The magnitude is Java's own (`c1 - c2`, else the length difference), not `-1/0/1`, so a
/// differential harness can compare the number directly.
public func javaStringCompareTo(_ a: String, _ b: String) -> Int {
  let left = Array(a.utf16)
  let right = Array(b.utf16)
  let shared = min(left.count, right.count)
  var index = 0
  while index < shared {
    if left[index] != right[index] { return Int(left[index]) - Int(right[index]) }
    index += 1
  }
  return left.count - right.count
}

// MARK: - Seams

/// Everything `XmlWriter` needs from `com.cburch.logisim.circuit.Circuit`.
///
/// A protocol rather than a direct reach into `Circuit` because it states the writer's
/// requirement exactly and keeps the two halves of the codec from growing an implicit dependency
/// on each other's internals. `Circuit` conforms; nothing else needs to.
public protocol CircuitSaving: AnyObject {
  /// `Circuit.getName()`.
  var savedName: String { get }
  /// `Circuit.getStaticAttributes()`, where `<circuit>`'s own `<a>` children come from.
  var savedStaticAttributes: any AttributeSet { get }
  /// `Circuit.getWires()`. Order is irrelevant: `<circuit>` is sorted, and that is precisely what
  /// makes upstream's hash-set-backed wire collection reproducible on disk.
  var savedWires: [Wire] { get }
  /// `Circuit.getNonWires()`. Order likewise irrelevant.
  var savedNonWires: [any Component] { get }
  /// `Circuit.getWireBusWidthPos(Wire)`, with `BUS_WIDTH_POS_NONE` folded into nil; the writer
  /// skips both, so `pos != null && pos != NONE` becomes one test instead of two.
  func savedWireBusWidthPos(_ wire: Wire) -> AttributeOption?
}

/// `Circuit.getBoardMapNamestoSave()` / `getMapInfo(String)`, reduced the same way.
///
/// **Deviation, shared with the reader.** Upstream regenerates each `<mc>` from a parsed
/// `CircuitMapInfo` through `MapComponent.getMapElement` / `getComplexMap`, which is FPGA
/// data-model code well outside M2. `Circuit` keeps the `<mc>` children verbatim instead (its own
/// `addLoadedMap` documents why), so the seam hands back finished elements. Nothing is
/// recomputed, so nothing can drift, and a file carrying a `<boardmap>` still round-trips.
public protocol CircuitBoardMapSaving: AnyObject {
  /// `Circuit.getBoardMapNamestoSave()`.
  var savedBoardMapNames: [String] { get }
  /// The `<mc>` children for one board, in `getMapInfo(board).keySet()` order. `<boardmap>` is
  /// sorted afterwards, so that order is not observable.
  func savedBoardMapElements(forBoard board: String) -> [XMLElement]
}

/// `circuit.getAppearance()`, reduced to what `fromCircuit` touches.
///
/// The appearance editor is M6/M7: `CircuitAppearance.getCustomObjectsFromBottom()` returns
/// `AbstractCanvasObject`s whose `toSvgElement(Document)` lives in `com.cburch.draw`. The writer
/// only ever needs the resulting elements, so that is what the seam returns.
public protocol CircuitAppearanceSaving: AnyObject {
  /// `circuit.getAppearance().hasCustomAppearance()`.
  func hasCustomAppearance(_ circuit: any CircuitSaving) -> Bool
  /// One element per `AbstractCanvasObject.toSvgElement(doc)` that did not return null, in
  /// `getCustomObjectsFromBottom()` order. The elements must be detached and owned by the
  /// caller; they are appended straight into the output document.
  func appearanceElements(for circuit: any CircuitSaving) -> [XMLElement]
}

/// Install point for the appearance writer, mirroring `CircuitAppearanceReader`.
///
/// Nothing installs one at this milestone, and until something does, `<appear>` comes from
/// `CircuitAppearancePreserving` instead, see `fromCircuit`.
public enum CircuitAppearanceWriter {
  public static var handler: (any CircuitAppearanceSaving)?
}

/// D8 for `<appear>`: the verbatim element the reader kept, re-emitted unchanged.
///
/// **This is a seam with two owners, so it is stated explicitly rather than left implicit.**
/// `CircuitAppearanceReader.handler` is nil at this milestone and nothing installs one, so the
/// model-driven path above produces nothing; without this protocol every custom circuit
/// appearance is destroyed by a plain open-and-save, while the
/// `<a name="appearance" val="custom"/>` attribute that *names* it survives; the file then
/// claims an appearance it no longer carries. That is precisely the loss D8 exists to prevent,
/// and it is the same shape as the one already solved for `<boardmap>`
/// (`Circuit.absorbBoardMap(_:)` / `boardMapElement(forBoard:)`).
///
/// The conforming type is `Circuit`, whose reader-side half is `absorbAppearance(_:)`; this
/// writer needs only the getter. Ownership of `<appear>` transfers to
/// `CircuitAppearanceWriter.handler` the moment a real appearance model exists, and this
/// protocol then becomes dead, but it must not be removed before then, and it must not be
/// removed at the same time as the reader's storage either. Removing only one of the two halves
/// is the data-losing combination.
public protocol CircuitAppearancePreserving: AnyObject {
  /// The verbatim `<appear>` element read for this circuit, or nil when it had none. The writer
  /// copies it before appending, so the model keeps ownership.
  var appearanceElement: XMLElement? { get }
}

/// `com.cburch.logisim.vhdl.base.VhdlContent`, reduced to the four members `fromVhdl` uses.
///
/// `LogisimFile.vhdlContents` is `[any VhdlContentReference]` and that protocol carries only the
/// name, because the VHDL subsystem sits in the parity backlog. Whatever `VhdlContentLoading`
/// produces must also conform to this for the entity to survive a save.
public protocol VhdlContentSaving: VhdlContentReference {
  /// `VhdlContent.aboutToSave()`.
  func aboutToSave()
  /// `VhdlContent.getContent()`.
  var content: String { get }
  // `getAppearance()` is deliberately absent: 4.1.0's `fromVhdl` does not write it (D16, and see
  // `fromVhdl`). Requiring it here would imply the writer needs it.
}

/// D8 for `<vhdl>`: the verbatim element the reader kept, re-emitted unchanged.
///
/// The same two-owner seam as `CircuitAppearancePreserving`, and it fails the same way.
/// `VhdlContentReader.handler` is nil at this milestone and nothing installs one, so
/// `VhdlContent.parse` has no port and no entity can be built; upstream's own behaviour when
/// `parse` returns null is to drop the element, which is a permanent loss on re-save. A
/// conforming placeholder carries the original `<vhdl>` element instead, and `fromLogisimFile`
/// emits it ahead of the model-driven path.
///
/// Note what this does *not* do: it does not synthesise the entity, so `<comp>` elements referring
/// to it are still `UnresolvedComponent`s and are still written from their own preserved element.
/// They do, however, resolve to the carrier's `PreservedVhdlEntityFactory` and share it; see that
/// type. Both halves are needed for a VHDL file to survive, and neither is sufficient alone.
public protocol VhdlContentPreserving: VhdlContentReference {
  /// The verbatim `<vhdl>` element, or nil for a content object that can be written from the
  /// model. The writer copies it before appending.
  var rawElement: XMLElement? { get }
}

/// The project-bundle (`.lsebdl`) export path: `LibraryManager.getLibraryFilePath` /
/// `isJarLibrary` / `getReplacementDescriptor`, plus `Loader.getZipFile()`.
///
/// A nil sink is exactly Java's `zipFile == null`, in which case upstream leaves the descriptor
/// untouched, so the port's default is a faithful branch of upstream, not a stub.
public protocol ProjectBundleSink: AnyObject {
  /// `LibraryManager.getLibraryFilePath(loader, desc)`; nil where Java returns null.
  func libraryFilePath(forDescriptor descriptor: String) -> String?
  /// `LibraryManager.isJarLibrary(loader, desc)`.
  func isJarLibrary(descriptor: String) -> Bool
  /// `ProjectBundlePaths.libraryEntry(filename)`.
  func bundleLibraryEntryName(for filename: String) -> String
  /// `writeJarToZip` / `writeLogisimFileToZip`, selected by `isJar`.
  func copyLibraryIntoBundle(from originalPath: String, to entryName: String, isJar: Bool) throws
  /// `LibraryManager.getReplacementDescriptor(loader, desc,
  /// ProjectBundlePaths.libraryDescriptor(filename, isRecursiveCall))`.
  func replacementDescriptor(
    for descriptor: String, filename: String, isRecursiveCall: Bool
  ) -> String
}

// ── D16: `Image.ATTR_LICENSE` is NOT a 4.1.0 force-write rule ────────────────────────────────
//
// 4.2.0-dev adds `|| (attr.equals(Image.ATTR_LICENSE) && !userModifiedOnly)` to
// `addAttributeSetContent`'s write condition. There is no such branch in 4.1.0, and there is no
// `com.cburch.logisim.std.base.Image` either: 4.1.0's `std/base/` contains exactly
// `BaseLibrary`, `Text` and `TextAttributes`. The hook that used to live here (an
// `ImageComponentAttributes.license` slot, nil by default and therefore inert) has been removed
// rather than left dormant: its only possible effect was to start force-writing an attribute the
// oracle never writes, the moment some future tranche registered it.

// MARK: - XmlSerializer

/// The JDK identity-transform serializer, ported.
///
/// Four of `ToStream`'s rules decide the bytes, and none of them is what a hand-written
/// pretty-printer would do. Each was read out of JDK 21's `ToStream.java` and then confirmed
/// against real converter output:
///
/// 1. **An element always starts on its own indented line; a text node is indented only when
///    its parent has more than one child.** `flushCharactersBuffer` indents iff
///    `shouldIndentForText()`, which is `shouldIndent() && m_childNodeNum > 1`
///    (`ToStream.java:1551`, `:1573`). So `<a name="contents">addr/data: 24 32⏎8c210000⏎</a>`
///    keeps its body flush against both tags, while `<project>`'s banner, a text node with
///    element siblings, is indented like an element.
/// 2. **When a text node *is* indented, its leading `\n` characters are dropped.**
///    `flushCharactersBuffer` passes `skipBeginningNewlines = true`, and `CharacterBuffer
///    .addText`'s flush skips `'\n'` and nothing else (`ToStream.java:3411`): not spaces, not
///    tabs, not `\r`. This is why `"\nThis file is intended…\n"` renders as
///    `⏎␣␣This file is intended…⏎` rather than `⏎␣␣⏎This file…`.
/// 3. **The closing tag is indented iff `m_childNodeNum > 1 || !m_isprevtext`**
///    (`ToStream.java:2127`); everywhere except an element whose only child is text. An element
///    with no children never closes its start tag at all and is written `/>`.
/// 4. **Attributes are emitted in ascending name order**, because Xerces' `NamedNodeMapImpl`
///    keeps them sorted by qualified name and the serializer just walks the map. Upstream's own
///    comment ("Attribute name=value pairs seem to be sorted already") is describing exactly
///    this. Foundation preserves insertion order instead, so the sort happens here.
///
/// Plus the framing: `<?xml version="1.0" encoding="UTF-8" standalone="no"?>` and a newline
/// (`ToXMLStream.startDocumentInternal`), and a trailing newline after the root because
/// `ToXMLStream.endDocument` emits one when indenting and the last thing written was not
/// character data.
///
/// The escape tables were derived by probing every code point 0x0000–0x010F plus the interesting
/// outliers, in both positions, against the real transformer. They are **not** the XML spec's
/// minimum: `>` is escaped in both positions, `'` in neither, `"` only in attributes, and C1
/// controls only in text.
///
/// **Deviation, macOS-only (D0):** `m_lineSep` is `System.lineSeparator()`. This port hard-codes
/// `\n`. On Windows the JDK would emit `\r\n` everywhere, including inside text nodes; the
/// oracle runs on macOS and so does the port.
public enum XmlSerializer {

  private static let indentUnit = "  "

  /// Serialize as the JAXP identity transform would, and return the UTF-8 bytes.
  public static func serialize(_ document: XMLDocument) throws -> Data {
    var out = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"no\"?>\n"
    if let root = document.rootElement() {
      try writeElement(root, depth: 0, into: &out)
      // `ToXMLStream.endDocument`: one line separator when indenting and the last write was not
      // character data. A root's `</…>` never is, so this is unconditional.
      out += "\n"
    }
    return Data(out.utf8)
  }

  /// Serialize a subtree. Exists so a test can pin one element without building a document.
  public static func serialize(element: XMLElement, depth: Int = 0) throws -> String {
    var out = ""
    try writeElement(element, depth: depth, into: &out)
    return out
  }

  private static func writeElement(
    _ element: XMLElement, depth: Int, into out: inout String
  ) throws {
    out += "<" + (element.name ?? "")

    // Rule 4. `String.compareTo` order, not Swift's.
    let attributes = (element.attributes ?? []).sorted {
      javaStringCompareTo($0.name ?? "", $1.name ?? "") < 0
    }
    for attribute in attributes {
      out += " " + (attribute.name ?? "") + "=\""
      out += try escapeAttributeValue(attribute.stringValue ?? "")
      out += "\""
    }

    // `ToStream.characters` returns before `closeStartTag()` when the text is empty, so a
    // zero-length text child leaves the start tag open and the element self-closes. Dropping
    // such children here reproduces that, and reproduces Xerces' `normalize()` at the same time.
    let children = (element.children ?? []).filter { node in
      switch node.kind {
      case .element: return true
      case .text: return !(node.stringValue ?? "").isEmpty
      default: return false
      }
    }

    if children.isEmpty {
      // `endElement` with `m_startTagOpen` still true.
      out += "/>"
      return
    }

    out += ">"
    // Rules 1 and 3. For this DOM shape `m_childNodeNum > 1` is exactly "has an element child":
    // the writer never gives one element two text children, and `normalize()` would merge them
    // if it did.
    let hasElementChild = children.contains { $0.kind == .element }

    for child in children {
      switch child.kind {
      case .element:
        // `startElement`'s `shouldIndent() && m_startNewLine`, which is true for every element
        // below the root, and `hasElementChild` is necessarily true here anyway.
        out += "\n" + String(repeating: indentUnit, count: depth + 1)
        if let childElement = child as? XMLElement {
          try writeElement(childElement, depth: depth + 1, into: &out)
        }
      case .text:
        var data = child.stringValue ?? ""
        if hasElementChild {
          out += "\n" + String(repeating: indentUnit, count: depth + 1)
          // Rule 2.
          while data.hasPrefix("\n") { data.removeFirst() }
        }
        out += try escapeTextContent(data)
      default:
        break
      }
    }

    if hasElementChild {
      out += "\n" + String(repeating: indentUnit, count: depth)
    }
    out += "</" + (element.name ?? "") + ">"
  }

  // MARK: Escaping

  /// `ToStream.writeAttrString` + `accumDefaultEscape(fromTextNode: false, escLF: true)`.
  ///
  /// Measured, not assumed: `&<>"` become entities, `'` does **not**, tab/LF/CR become decimal
  /// character references, C1 controls (0x7F–0x9F) stay literal *in attributes* (they do not in
  /// text), astral scalars become decimal character references, and the XML-1.0-invalid C0
  /// controls throw.
  public static func escapeAttributeValue(_ value: String) throws -> String {
    var out = ""
    out.reserveCapacity(value.count)
    for scalar in value.unicodeScalars {
      switch scalar {
      case "&": out += "&amp;"
      case "<": out += "&lt;"
      case ">": out += "&gt;"
      case "\"": out += "&quot;"
      case "\t": out += "&#9;"
      case "\n": out += "&#10;"
      case "\r": out += "&#13;"
      default:
        if isInvalidXml10Scalar(scalar) {
          throw XmlWriterError.invalidXmlCharacter(scalar: scalar.value)
        }
        if scalar.value > 0xFFFF {
          out += "&#\(scalar.value);"
        } else {
          out.unicodeScalars.append(scalar)
        }
      }
    }
    return out
  }

  /// `ToStream.outputCharacters` + `accumDefaultEscape(fromTextNode: true, escLF: false)`.
  ///
  /// Every asymmetry against the attribute table is real and measured: `"` is literal here
  /// because `outputCharacters` short-circuits it with an explicit `|| ('"' == ch)`
  /// (`ToStream.java:1496`); tab and LF are literal; and C1 controls *do* become character
  /// references here, through `isCharacterInC0orC1Range`.
  public static func escapeTextContent(_ value: String) throws -> String {
    var out = ""
    out.reserveCapacity(value.count)
    for scalar in value.unicodeScalars {
      switch scalar {
      case "&": out += "&amp;"
      case "<": out += "&lt;"
      case ">": out += "&gt;"
      case "\r": out += "&#13;"
      case "\t", "\n": out.unicodeScalars.append(scalar)
      default:
        if isInvalidXml10Scalar(scalar) {
          throw XmlWriterError.invalidXmlCharacter(scalar: scalar.value)
        }
        if scalar.value > 0xFFFF || (scalar.value >= 0x7F && scalar.value <= 0x9F) {
          out += "&#\(scalar.value);"
        } else {
          out.unicodeScalars.append(scalar)
        }
      }
    }
    return out
  }

  /// `XMLChar.isInvalid` for XML 1.0, restricted to the range the serializer actually reaches.
  ///
  /// Note the deliberate omission of U+FFFE/U+FFFF: they are invalid per the spec, but the
  /// serializer's fast path (`escapingNotNeeded(ch)` is true under UTF-8) lets them through
  /// literally before the validity check is ever consulted. Verified against the oracle. Adding
  /// them here would make the port stricter than the thing it has to byte-match.
  private static func isInvalidXml10Scalar(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F: return true
    default: return false
    }
  }
}

// MARK: - XmlWriter

/// `com.cburch.logisim.file.XmlWriter`.
///
/// One instance per `write`, exactly as upstream's private constructors imply: `libs` is
/// per-document state, and the library indices it hands out (`name="0"`, `"1"`, …) must restart
/// at zero for every file.
public final class XmlWriter {

  // MARK: Per-write state

  private let file: LogisimFile
  private let document: XMLDocument
  private let loader: any LibraryLoader

  /// Java's `outFilePath`: the *directory* the file is being written into, used to relativize
  /// `filePath` attributes. Java computes it as `destFile.getAbsolutePath()` truncated at the
  /// last separator.
  private let outFilePath: String?

  /// Java's `isProjectExport = StringUtil.isNotEmpty(mainCircFile)`.
  private let isProjectExport: Bool

  /// Java's `isRecursiveCall`.
  private let isRecursiveCall: Bool

  /// Java's `HashMap<Library, String> libs`, keyed by identity: `Library` overrides neither
  /// `equals` nor `hashCode` upstream, and D4 forbids giving it value equality here.
  private var libs: [ObjectIdentifier: String] = [:]
  /// `libs.size()` at insertion time, which is what names a library. Kept separately because a
  /// Swift dictionary's `count` is read *after* the insert.
  private var libCount = 0

  /// `AppPreferences.REMOVE_UNUSED_LIBRARIES.getBoolean()`; upstream's default is `false`.
  private let removeUnusedLibraries: Bool

  /// `Loader.getZipFile()` plus the `ProjectBundlePaths`/`LibraryManager` helpers around it.
  /// Nil is Java's `zipFile == null`.
  private let bundleSink: (any ProjectBundleSink)?

  private init(
    file: LogisimFile,
    document: XMLDocument,
    loader: any LibraryLoader,
    outFilePath: String? = nil,
    mainCircFile: String? = nil,
    isRecursiveCall: Bool = false,
    removeUnusedLibraries: Bool = false,
    bundleSink: (any ProjectBundleSink)? = nil
  ) {
    self.file = file
    self.document = document
    self.loader = loader
    self.outFilePath = outFilePath
    self.isProjectExport = StringUtil.isNotEmpty(mainCircFile)
    self.isRecursiveCall = isRecursiveCall
    self.removeUnusedLibraries = removeUnusedLibraries
    self.bundleSink = bundleSink
  }

  // MARK: - Entry point

  /// `XmlWriter.write(LogisimFile, OutputStream, LibraryLoader, File, String, boolean)`.
  ///
  /// Upstream writes into a stream (and, for a project bundle, into a `ZipOutputStream` entry);
  /// this returns the bytes, because `Loader.save`, `autosave` and `export` all want `Data`.
  public static func write(
    file: LogisimFile,
    loader: any LibraryLoader,
    destination: URL? = nil,
    mainCircFile: String? = nil,
    recurse: Bool = false,
    removeUnusedLibraries: Bool = false,
    bundleSink: (any ProjectBundleSink)? = nil
  ) throws -> Data {
    let document = XMLDocument()
    document.characterEncoding = "UTF-8"

    let context: XmlWriter
    if let destination {
      // Java, verbatim:
      //
      //     var dstFilePath = destFile.getAbsolutePath();
      //     dstFilePath = dstFilePath.substring(0, dstFilePath.lastIndexOf(File.separator));
      //
      // Both halves are literal on purpose, because the obvious Foundation spellings are each
      // wrong in a different way and the result feeds `Paths.relativize`:
      //
      //   * `standardizedFileURL` resolves `.` and `..`. **`File.getAbsolutePath` does not**:
      //     only `getCanonicalPath` does, and upstream does not call it. `Paths.get` does not
      //     normalise either, so `relativize` compares `.` and `..` as ordinary name elements
      //     (see `javaRelativize`). Normalising here would silently change the relative path
      //     written into a `filePath` attribute.
      //   * `NSString.deletingLastPathComponent` returns `"/"` for `"/x.circ"` and strips
      //     trailing separators; Java's `substring` returns `""` and strips nothing. `""` and
      //     `"/"` relativize differently; `Paths.get("")` is a *relative* empty path, so
      //     relativizing an absolute target against it throws where `"/"` would succeed.
      let absolute = XmlWriter.javaAbsolutePath(destination)
      // `lastIndexOf` cannot miss: `getAbsolutePath` always yields a rooted path, so there is
      // always at least one separator. Java would throw `StringIndexOutOfBoundsException` if it
      // could; the port keeps the whole string, which is the only non-throwing reading of a case
      // neither side can reach.
      let parent =
        absolute.lastIndex(of: "/").map { String(absolute[absolute.startIndex..<$0]) } ?? absolute
      context = XmlWriter(
        file: file, document: document, loader: loader, outFilePath: parent,
        removeUnusedLibraries: removeUnusedLibraries, bundleSink: bundleSink)
    } else if let mainCircFile {
      context = XmlWriter(
        file: file, document: document, loader: loader, mainCircFile: mainCircFile,
        isRecursiveCall: recurse, removeUnusedLibraries: removeUnusedLibraries,
        bundleSink: bundleSink)
    } else {
      context = XmlWriter(
        file: file, document: document, loader: loader,
        removeUnusedLibraries: removeUnusedLibraries, bundleSink: bundleSink)
    }

    try context.fromLogisimFile()

    // Java: `doc.normalize()` then `sort(doc)`. `normalize()` merges adjacent text nodes and
    // drops empty ones; this DOM never has adjacent text nodes, and `XmlSerializer` ignores
    // empty ones for the same reason the JDK serializer does, so the call has no counterpart.
    XmlWriter.sort(document)
    return try XmlSerializer.serialize(document)
  }

  // MARK: - Sorting
  //
  // Upstream's comment, reproduced because it is the specification:
  //
  //   "We sort some parts of the xml tree, to help with reproducibility and to ease testing
  //    (e.g. diff a circuit file). Attribute name=value pairs seem to be sorted already, so we
  //    don't worry about those. The code below sorts the nodes, but only in best-effort fashion
  //    (some nodes are identical except for their child contents, which seems overkill to
  //    bother sorting). Parts of the tree where node order matters (top-level "project", the
  //    libraries, and the toolbar, for example) are not sorted."
  //
  // This is what makes the writer reproducible at all. `Circuit.getWires()` and `getNonWires()`
  // are hash-set backed upstream and `MouseMappings` is a `HashMap`, so without the sort the
  // bytes on disk would depend on hash iteration order.

  /// `XmlWriter.attrToString(Attr)`.
  ///
  /// The escaping here is **not** the serializer's: it is `&` then `"`, in that order, and
  /// nothing else. `<`, `>` and control characters pass through untouched. This string is only
  /// ever a sort key, so the difference shows up solely in the ordering it produces, which is
  /// the thing being reproduced.
  static func attributeToString(_ attribute: XMLNode) -> String {
    let name = attribute.name ?? ""
    let value = (attribute.stringValue ?? "")
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "\"", with: "&quot;")
    return name + "=\"" + value + "\""
  }

  /// `XmlWriter.attrsToString(NamedNodeMap)`.
  ///
  /// Java short-circuits at zero and at one attribute and only sorts from two upwards. The
  /// short-circuits are kept even though all three branches agree, so the code reads against
  /// the original.
  ///
  /// **Deviation.** Java calls this with `node.getAttributes()`, which is null for anything that
  /// is not an element and would therefore throw `NullPointerException`. That is unreachable for
  /// the DOM this writer builds: the only text nodes it creates are the sole child of
  /// `<a>`/`<vhdl>` (one child, never sorted) and the `<project>` banner (`"project"` is on the
  /// exclusion list). Returning `""` instead of crashing is a deliberate, recorded choice on a
  /// path Java cannot reach either.
  static func attributesToString(_ node: XMLNode) -> String {
    guard let element = node as? XMLElement, let attributes = element.attributes else {
      return ""
    }
    if attributes.isEmpty { return "" }
    if attributes.count == 1 { return attributeToString(attributes[0]) }
    let parts = attributes.map(attributeToString).sorted { javaStringCompareTo($0, $1) < 0 }
    return parts.joined(separator: " ")
  }

  /// `XmlWriter.stringCompare(String, String)` (4.1.0), verbatim:
  ///
  /// ```java
  /// if (stringA == null) return -1;
  /// if (stringB == null) return 1;
  /// return stringA.compareTo(stringB);
  /// ```
  ///
  /// ── This is an inconsistent comparator, and the port reproduces it deliberately ────────────
  ///
  /// The first test is unguarded, so **`stringCompare(null, null)` is `-1`**, not `0`: the
  /// comparator claims `null < null`. 4.2.0-dev fixed it to `stringB == null ? 0 : -1`; D16 says
  /// main-only behaviour must not be ported, and here that rule has teeth, because the resulting
  /// order *is* the byte-exact pass condition.
  ///
  /// It is reached constantly rather than rarely: `Node.getNodeValue()` is null for **every**
  /// element, so `nodeComparator`'s third key sees two nulls whenever two element siblings agree
  /// on tag name and on their whole attribute set. `compare(a, b) == compare(b, a) == -1` for
  /// every such pair, and Java's `Arrays.sort`, TimSort, responds by treating a tied run as a
  /// *descending* run and reversing it.
  ///
  /// ── What it is worth, measured ────────────────────────────────────────────────────────────
  ///
  /// An earlier revision took 4.2.0-dev's fixed form instead, on the strength of a table claiming
  /// `0` scored 1082/1082 against the corpus and `-1` scored 1078/1082. **That measurement does
  /// not reproduce.** Three binaries built from this file differing only in this `guard` and in
  /// `javaSorted`'s tie-break, (a) `0` + keep input order, (b) `-1` + reverse tied runs, (c) `-1`
  /// handed straight to `sorted(by:)`, produce **byte-identical output on all 539 canonical
  /// corpus files, and all three score 539/539**.
  ///
  /// The reason is worth recording, because it is what makes the choice safe rather than lucky.
  /// The tie needs two sibling elements agreeing on tag *and* on every attribute, which happens
  /// 1,200 times across the corpus: but 1,080 of those pairs have identical subtrees too, so
  /// reordering them is invisible, and **every one of the remaining observable ties sits under
  /// `<toolbar>` or `<project>`**, both of which `sort` refuses to touch. Observable ties under a
  /// *sorted* parent: **0 of 539 canonical files**. (They do exist upstream of migration: 2 of the
  /// 541 `-n(f)` references have one under `<circuit>`; a pair of `<comp>`s at the same `loc`.
  /// The migration gate cannot discriminate on them yet; it fails 539/539 for unrelated reasons.)
  ///
  /// So this is not a case where fidelity costs anything, and D16 plus standing rule 4 decide it:
  /// port 4.1.0 verbatim, bug included, and do not adopt main's fix. Should a future file ever
  /// reach the tie, the port then already behaves the way the oracle does.
  ///
  /// Note the tie-break is not a free parameter; see `javaSorted`. Reversal is what Java does
  /// with this comparator, and it is the half of the behaviour that would move the bytes.
  static func stringCompare(_ a: String?, _ b: String?) -> Int {
    guard let a else { return -1 }
    guard let b else { return 1 }
    return javaStringCompareTo(a, b)
  }

  /// `Node.getNodeName()`. Java gives `"#text"` for a text node and `"#document"` for the
  /// document; Foundation gives nil for both.
  private static func nodeName(_ node: XMLNode) -> String {
    switch node.kind {
    case .text: return "#text"
    case .comment: return "#comment"
    case .document: return "#document"
    default: return node.name ?? ""
    }
  }

  /// `Node.getNodeValue()`: **null for an element**, which is why the comparator's third key
  /// almost never decides anything.
  ///
  /// Foundation's `XMLElement.stringValue` returns the element's concatenated text instead, so
  /// using it directly would make `<a name="contents">` elements order by their bodies. They do
  /// not: Java leaves them tied and the stable sort keeps document order.
  private static func nodeValue(_ node: XMLNode) -> String? {
    switch node.kind {
    case .text, .comment: return node.stringValue
    default: return nil
    }
  }

  /// `XmlWriter.nodeComparator`. Three keys in order: node name, then the attribute set rendered
  /// as one sorted space-joined string, then the node value.
  ///
  /// Public alongside `sort`, because it *is* the sort rule and because a tie in it is the only
  /// circumstance under which stability is observable; a harness has to be able to look for one.
  public static func compareNodes(_ a: XMLNode, _ b: XMLNode) -> Int {
    var result = stringCompare(nodeName(a), nodeName(b))
    if result != 0 { return result }
    result = stringCompare(attributesToString(a), attributesToString(b))
    if result != 0 { return result }
    return stringCompare(nodeValue(a), nodeValue(b))
  }

  /// `nodeComparator` with its one inconsistency removed, so that it is a genuine ordering.
  ///
  /// Identical to `compareNodes` except that two nodes which both have a null `getNodeValue()`:
  /// i.e. any two elements: compare `0` instead of `-1`. `javaSorted` reintroduces the
  /// consequence of the `-1` explicitly, which is the only way to get defined behaviour out of
  /// `Sequence.sorted(by:)`.
  private static func compareNodesConsistently(_ a: XMLNode, _ b: XMLNode) -> Int {
    var result = stringCompare(nodeName(a), nodeName(b))
    if result != 0 { return result }
    result = stringCompare(attributesToString(a), attributesToString(b))
    if result != 0 { return result }
    let valueA = nodeValue(a)
    let valueB = nodeValue(b)
    if valueA == nil && valueB == nil { return 0 }
    return stringCompare(valueA, valueB)
  }

  /// `Arrays.sort(Object[], Comparator)` for *this* comparator, which is not a valid one.
  ///
  /// Java's `Arrays.sort(T[], Comparator)` is TimSort. TimSort is stable, so with a well-behaved
  /// comparator this would simply be "sort, keeping the input order for ties", which is what an
  /// earlier revision implemented. `nodeComparator` is not well-behaved: `stringCompare(null,
  /// null)` is `-1`, so two tied elements each report themselves as strictly smaller than the
  /// other, and TimSort's `countRunAndMakeAscending` classifies a tied run as *descending* and
  /// reverses it (`binarySort` reaches the same result by a different route: with `compare` always
  /// negative its binary search always lands at `lo`, so each successive element is inserted ahead
  /// of the ones before it). `A B C` comes back `C B A`.
  ///
  /// No corpus file currently observes the reversal, `stringCompare`'s doc comment has the count
  /// and the reason, so this is fidelity bought at zero cost, not a fix for a measured diff.
  ///
  /// **Why this is written as an explicit reversal rather than by handing `compareNodes` straight
  /// to `sorted(by:)`.** Passing a predicate that answers `true` to both `f(a, b)` and `f(b, a)`
  /// violates `sorted(by:)`'s documented requirement of a strict weak ordering, and its result is
  /// then *unspecified*; it is not part of Swift's ABI and may change between toolchains. Byte
  /// order is this milestone's pass condition, so it cannot rest on unspecified behaviour. The
  /// form below is a strict total order (consistent comparison, then **descending** original
  /// index), which is exactly "sorted, with each tied run reversed" and is fully defined.
  ///
  /// Verified equivalent: the outputs for all 539 canonical corpus files are byte-identical to
  /// those produced by handing the inconsistent comparator to `sorted(by:)` on this toolchain.
  private static func javaSorted(_ nodes: [XMLNode]) -> [XMLNode] {
    nodes.enumerated()
      .sorted { lhs, rhs in
        let result = compareNodesConsistently(lhs.element, rhs.element)
        // Ties reverse. `>` rather than `<` is the whole of `stringCompare`'s null-null `-1`.
        return result != 0 ? result < 0 : lhs.offset > rhs.offset
      }
      .map(\.element)
  }

  /// `XmlWriter.sort(Node)`.
  ///
  /// The exact rule, in the order Java tests it:
  ///
  /// 1. **`appear` is special-cased and *returns*.** Only the `circ-port` children are
  ///    reordered: they are collected, sorted with the node comparator, and re-appended at the
  ///    end: `insertBefore(node, null)` appends. Every other child (the drawn shapes) keeps its
  ///    relative order and ends up ahead of the ports. `sort` then **returns without recursing**,
  ///    so nothing inside an appearance is sorted at any depth. With no `circ-port` children it
  ///    returns even earlier and the section is untouched.
  /// 2. Otherwise children are sorted iff there are **more than one** and the element is not
  ///    named `project`, `lib`, `toolbar` or `appear`. Those four carry meaning in their order:
  ///    `<project>` fixes libs → main → options → mappings → toolbar → circuits → vhdl, `<lib>`
  ///    fixes tool order, `<toolbar>` fixes button order including `<sep/>` positions. The fourth
  ///    test, `!name.equals("appear")`, is dead; step 1 already returned.
  /// 3. Sorting moves *every* child to the end in sorted order, so the child list is fully
  ///    permuted rather than partially rewritten.
  /// 4. **Then it recurses into every child**, including text nodes (harmless; they have no
  ///    children) and including the four excluded names. The exclusion is one level deep only,
  ///    so a `<lib>`'s tool order survives while each `<tool>`'s own `<a>` children *are* sorted.
  ///
  /// Concretely, the comparator's three keys give: `<circuit>` children come out as `a` …
  /// `appear` … `boardmap` … `comp` … `wire`; `<a>` children sort on `name="…" val="…"` as one
  /// string, so `name="addrWidth"` precedes `name="appearance"` precedes `name="contents"`; and
  /// `<comp>` children sort on `lib`, then `loc` **compared as text**, then `name`: with the
  /// `lib`-bearing ones ahead of a subcircuit's `lib`-less `<comp>`, because `"li"` precedes
  /// `"lo"`.
  public static func sort(_ top: XMLNode) {
    let name = nodeName(top)
    let children = top.children ?? []
    let childrenCount = children.count

    if name == "appear" {
      let ports = children.filter { nodeName($0) == "circ-port" }
      if ports.isEmpty { return }
      if let element = top as? XMLElement {
        for node in javaSorted(ports) {
          node.detach()
          element.addChild(node)
        }
      }
      return
    }

    if childrenCount > 1, name != "project", name != "lib", name != "toolbar", name != "appear" {
      // Only an element can be re-parented here. A document has exactly one child and so never
      // reaches this branch.
      if let element = top as? XMLElement {
        for node in javaSorted(children) {
          node.detach()
          element.addChild(node)
        }
      }
    }

    // Java iterates the *live* NodeList using the count captured before the sort. The sort
    // re-appends every child, so the list holds the same nodes in the new order and a fresh read
    // is equivalent.
    for child in top.children ?? [] {
      sort(child)
    }
  }

  // MARK: - Attribute sets

  /// `XmlWriter.addAttributeSetContent(Element, AttributeSet, AttributeDefaultProvider, boolean)`.
  ///
  /// This is the method that decides which attributes are **omitted because they equal their
  /// default**, and therefore why `<lib desc="#Wiring" name="0"/>` is self-closing in one file
  /// and paired in another.
  ///
  /// The write condition, verbatim from upstream:
  ///
  /// ```
  /// dflt == null
  ///   || (!dflt.equals(val) && !defaultValue.equals(newValue))
  ///   || (attr.equals(StdAttr.APPEARANCE)              && !userModifiedOnly)
  ///   || (attr.equals(Image.ATTR_LICENSE)              && !userModifiedOnly)
  ///   || (attr.equals(ProbeAttributes.PROBEAPPEARANCE) && !userModifiedOnly
  ///                                                    && val.equals(APPEAR_EVOLUTION_NEW))
  /// ```
  ///
  /// Two things worth naming. First, the default test is **doubled**, the values must differ
  /// *and* their standard strings must differ, so two distinct objects that serialise
  /// identically count as equal and are omitted. Second, `userModifiedOnly` is what separates the
  /// two kinds of call site: components and circuits pass `false` and therefore always write
  /// `StdAttr.APPEARANCE`, even at its default, while `<tool>` entries pass `true` and write it
  /// only when it genuinely differs. That single flag is why `<comp lib="0" name="Pin">` carries
  /// `<a name="appearance" val="classic"/>` while the matching `<tool name="Pin">` need not.
  ///
  /// Third, less obvious: the three force-write cases match **by object identity**.
  /// `CircuitAttributes.appearanceAttribute` is a different `Attribute` that also happens to be
  /// called `"appearance"`, and matching on the name would force-write a circuit's appearance at
  /// its default: visibly wrong against the oracle, where `<circuit>` carries no
  /// `<a name="appearance">` at all.
  func addAttributeSetContent(
    _ element: XMLElement,
    _ attributes: (any AttributeSet)?,
    source: (any AttributeDefaultProvider)?,
    userModifiedOnly: Bool
  ) throws {
    guard let attributes else { return }
    if let source, source.isAllDefaultValues(attributes, version: BuildInfo.version) { return }

    for attribute in attributes.attributes {
      let value = attributes.rawValue(attribute)
      if userModifiedOnly && (attributes.isReadOnly(attribute) || attribute.isHidden) { continue }
      guard attributes.isToSave(attribute), let value else { continue }

      let dflt = source?.defaultAttributeValue(attribute, version: BuildInfo.version)
      let defaultText = try dflt.map { try standardString(of: attribute, $0) } ?? ""
      let newValue = try standardString(of: attribute, value)

      let isAppearance = attribute === StdAttr.appearance
      let isProbeAppearance = attribute === ProbeAttributes.probeAppearance

      let shouldWrite =
        dflt == nil
        || (dflt != value && defaultText != newValue)
        || (isAppearance && !userModifiedOnly)
        || (isProbeAppearance && !userModifiedOnly
          && value == .option(ProbeAttributes.appearEvolutionNew))
      guard shouldWrite else { continue }

      let a = XMLElement.createElement("a")
      a.setAttribute("name", attribute.name)
      if attribute.name == "filePath", let outFilePath {
        a.setAttribute("val", try XmlWriter.javaRelativize(base: outFilePath, target: newValue))
      } else if newValue.unicodeScalars.contains("\n") {
        // `unicodeScalars`, NOT `newValue.contains("\n")`. Swift's `Character` is a grapheme
        // cluster and **`"\r\n"` is a single one**, so a CRLF value contains no `"\n"`
        // Character at all and the string test silently answers false. Java's
        // `String.contains("\n")` is UTF-16 and answers true. Measured, not theorised: 91
        // canonical baselines regressed the moment `#TCL` was registered, because 90 corpus
        // files carry a CRLF copy of the TCL entity template and every one of them came back
        // as a single `val="…&#13;&#10;…"` attribute where the oracle writes a text node.
        // A multi-line value becomes the element's body instead of an attribute: as an
        // attribute the newline would have to be escaped `&#10;`, and upstream would rather keep
        // RAM/ROM `contents` readable.
        a.appendChild(XmlWriter.textNode(newValue))
      } else {
        // Java recomputes `attr.toStandardString(val)` here rather than reusing `newValue`; the
        // two are the same call on the same value.
        a.setAttribute("val", newValue)
      }
      element.appendChild(a)
    }
  }

  /// `attr.toStandardString(val)` without recovering `V`, which is what D5's `AnyAttribute`
  /// exists for.
  ///
  /// D13: `standardString(for:)` returns nil when the stored value is not one this attribute can
  /// decode: Java's `ClassCastException` on the unchecked `(Attribute<Object>)` cast.
  /// Unreachable through a well-formed `AttributeSet`, but it is an exception on the file path,
  /// so it throws rather than traps.
  private func standardString(
    of attribute: AnyAttribute, _ value: AttributeValue
  ) throws -> String {
    guard let text = attribute.standardString(for: value) else {
      throw XmlWriterError.unrepresentableAttributeValue(attribute: attribute.name)
    }
    return text
  }

  // MARK: - Library lookup

  // ── D16: library lookup is ONE LEVEL DEEP, because 4.1.0's is ─────────────────────────────
  //
  // 4.2.0-dev rewrote all three of these to recurse into `lib.getLibraries()` and added a
  // `libraryContains(Library, ComponentFactory)` overload. **4.1.0 has neither**, and the
  // difference is not academic; it is the difference between a green and a red gate.
  //
  // `LogisimFile` *is* a `Library` whose `getLibraries()` are the twelve builtin shells. So a
  // recursive `libraryContains(file, tool)` finds `#Base`'s "Menu Tool" *through* the file and
  // answers `file`, which makes `fromTool` emit no `lib=` attribute at all. Measured on the
  // canonical corpus: `<tool lib="7" map="Button2" name="Menu Tool"/>` came out as
  // `<tool map="Button2" name="Menu Tool"/>` on every one of 539 files.
  //
  // 4.1.0's `Library.contains(ComponentFactory)` is `indexOf(query) >= 0` over `getTools()` and
  // its `containsFromSource(Tool)` is a flat `sharesSource` scan: both stop at depth one.

  /// `XmlWriter.findLibrary(ComponentFactory)` (4.1.0).
  ///
  /// Bug-for-bug: 4.1.0 tests `file.contains(source)` and then `lib.contains(source)`: the flat
  /// `Library.contains`, never a recursive walk. A factory living in a sub-library of a
  /// *sub-library* is therefore not found, `fromComponent` calls `showError` and the component is
  /// dropped. That is upstream's behaviour at the version this port is measured against, and
  /// "fixing" it here would put an element in the output that the oracle does not write.
  func findLibrary(factoryOf source: any ComponentFactory) -> Library? {
    if file.contains(source) { return file }
    for library in file.libraries where library.contains(source) {
      return library
    }
    return nil
  }

  /// `XmlWriter.findLibrary(Tool)` (4.1.0): likewise one level deep at every step.
  func findLibrary(of tool: Tool) -> Library? {
    if XmlWriter.libraryContains(file, tool: tool) { return file }
    for library in file.libraries where XmlWriter.libraryContains(library, tool: tool) {
      return library
    }
    return nil
  }

  /// `XmlWriter.libraryContains(Library, Tool)` (4.1.0), which is `Library.containsFromSource`.
  ///
  /// Matched on `sharesSource`, not identity, so a cloned toolbar tool still resolves to the
  /// library its factory came from. No recursion, see the note above.
  static func libraryContains(_ library: Library, tool query: Tool) -> Bool {
    for tool in library.tools where tool.sharesSource(query) { return true }
    return false
  }

  // MARK: - Element builders

  /// `XmlWriter.fromLogisimFile()`.
  ///
  /// The append order *is* the file order, because `<project>` is on `sort`'s exclusion list:
  /// libraries, `<main>`, `<options>`, `<mappings>`, `<toolbar>`, circuits, VHDL entities.
  @discardableResult
  func fromLogisimFile() throws -> XMLElement {
    let root = XMLElement.createElement("project")
    document.setRootElement(root)

    // The banner. Appended before the attributes (immaterial: attributes serialise in name
    // order regardless) and before every child (material). Its leading `\n` is eaten by the
    // serializer; its trailing one produces the blank line before the first `<lib>`.
    root.appendChild(
      XmlWriter.textNode(
        "\nThis file is intended to be loaded by \(BuildInfo.displayName)(\(BuildInfo.url)).\n"))

    root.setAttribute("version", "1.0")
    root.setAttribute("source", BuildInfo.version.description)

    for library in file.libraries {
      if let element = try fromLibrary(library) { root.appendChild(element) }
    }

    if let main = file.mainCircuit {
      let mainElement = XMLElement.createElement("main")
      mainElement.setAttribute("name", main.savedName)
      root.appendChild(mainElement)
    }

    root.appendChild(try fromOptions())
    root.appendChild(try fromMouseMappings())
    root.appendChild(try fromToolbarData())

    for circuit in file.circuits {
      root.appendChild(try fromCircuit(circuit))
    }
    for vhdl in file.vhdlContents {
      // D8 first: a preserved element is re-emitted verbatim, because there is no model to
      // rebuild it from. Copied before appending, or the append re-parents it out of the content
      // object and empties the model on the first save: the same precaution `fromComponent`,
      // `fromTool` and `fromMap` take.
      if let preserved = vhdl as? any VhdlContentPreserving, let raw = preserved.rawElement {
        guard let duplicate = raw.copy() as? XMLElement else { continue }
        duplicate.detach()
        root.appendChild(duplicate)
        continue
      }
      guard let saving = vhdl as? any VhdlContentSaving else {
        throw XmlWriterError.vhdlContentCannotBeSaved(vhdl.name)
      }
      root.appendChild(fromVhdl(saving))
    }
    return root
  }

  /// `XmlWriter.fromLibrary(Library)`.
  func fromLibrary(_ library: Library) throws -> XMLElement? {
    // Java creates the element first and discards it on every early return. Kept in the same
    // place so the code lines up; it has no observable effect either way.
    let element = XMLElement.createElement("lib")
    let key = ObjectIdentifier(library)
    if libs[key] != nil { return nil }

    let name = String(libCount)
    // Java's `LibraryManager.getDescriptor` *throws* `LoaderException` rather than returning
    // null for an unknown library, so upstream's `desc == null` branch is dead code. D13 keeps
    // the throw travelling: `Loader.save` catches it and reports "Error while saving file".
    var desc = try loader.descriptor(for: library)

    libs[key] = name
    libCount += 1

    if removeUnusedLibraries {
      // Bug-for-bug ordering: the library has *already* consumed an index by the time this can
      // drop it, so a skipped library leaves a gap in the `name="n"` sequence.
      var isUsed = false
      let tools = library.tools
      for circuit in file.circuits {
        for component in circuit.savedNonWires {
          // 4.1.0: `isUsed |= lib.contains(tool.getFactory())`, the flat `Library.contains`.
          isUsed = isUsed || library.contains(component.factory)
        }
      }
      for tool in file.options.toolbarData.toolbarContents {
        guard let tool else { continue }
        isUsed = isUsed || tools.contains { $0 === tool }
      }
      for (_, tool) in file.options.mouseMappings.mappings {
        isUsed = isUsed || tools.contains { $0 === tool }
      }
      if !isUsed && desc != "#Base" { return nil }
    }

    if isProjectExport, library is LoadedLibrary, let sink = bundleSink {
      // Java: `LibraryManager.getLibraryFilePath` + `isJarLibrary`, then copy the file into the
      // bundle's zip and rewrite the descriptor to point at the copy. With no sink installed the
      // whole block is skipped, which is precisely Java's `zipFile == null` path.
      if let originalPath = sink.libraryFilePath(forDescriptor: desc) {
        let isJar = sink.isJarLibrary(descriptor: desc)
        let filename = (originalPath as NSString).lastPathComponent
        let entry = sink.bundleLibraryEntryName(for: filename)
        try sink.copyLibraryIntoBundle(from: originalPath, to: entry, isJar: isJar)
        desc = sink.replacementDescriptor(
          for: desc, filename: filename, isRecursiveCall: isRecursiveCall)
      }
    }

    element.setAttribute("name", name)
    element.setAttribute("desc", desc)

    // ── D8, the `<lib>` half ────────────────────────────────────────────────────────────────
    //
    // A library the loader could not resolve has `MissingTool` placeholders with no attribute
    // sets, so the loop below would emit an empty `<lib …/>` and silently discard every tool
    // configuration the file carried. `MissingLibrary` keeps its `<tool>` children verbatim
    // (`absorb(libraryElement:)`), and re-emitting copies of those is what makes the round trip
    // lossless. The descriptor is already preserved verbatim by `LibraryManager.descriptor`.
    if let missing = library as? MissingLibrary {
      for child in missing.rawChildren {
        guard let duplicate = child.copy() as? XMLElement else { continue }
        duplicate.detach()
        element.appendChild(duplicate)
      }
      return element
    }

    for tool in library.tools {
      guard let attributes = tool.attributeSet else { continue }
      let toolElement = XMLElement.createElement("tool")
      toolElement.setAttribute("name", tool.name)
      try addAttributeSetContent(toolElement, attributes, source: tool, userModifiedOnly: true)
      // The self-closing-versus-paired distinction lives right here: a tool whose attributes are
      // all at their factory defaults produced no `<a>` children and is dropped entirely, which
      // is what leaves `<lib desc="#Gates" name="1"/>` empty and therefore self-closing.
      if !(toolElement.children ?? []).isEmpty {
        element.appendChild(toolElement)
      }
    }

    // D8 for tools: re-emit `<tool>` elements the reader could not resolve.
    //
    // These are the ones `Library.absorbUnresolvedTool` kept. A builtin shell resolves as a
    // library but has an empty tool list until M4/M5, so without this every `<tool>` a real file
    // carries is silently dropped and the `<lib>` comes back bare; the diff the round-trip gate
    // reports. Emitted after the resolved tools because the reader appends in document order and
    // resolved ones can only precede unresolved ones while the tool list is empty; once tools
    // become real this list empties and the ordering question disappears with it.
    for preserved in library.unresolvedToolElements {
      guard let duplicate = preserved.copy() as? XMLElement else { continue }
      duplicate.detach()
      element.appendChild(duplicate)
    }
    return element
  }

  /// `XmlWriter.fromOptions()`. `source` is null, so **every** saved option is written
  /// unconditionally; there is nothing to compare against.
  func fromOptions() throws -> XMLElement {
    let element = XMLElement.createElement("options")
    try addAttributeSetContent(
      element, file.options.attributeSet, source: nil, userModifiedOnly: false)
    return element
  }

  /// `XmlWriter.fromMouseMappings()`.
  ///
  /// Upstream iterates a `HashMap<Integer, Tool>`, so its order is the JVM's; the port's
  /// `[Int32: Tool]` has a per-process randomised order. Neither matters: `<mappings>` is sorted,
  /// and no two entries can tie because the modifier mask is the key and appears in `map=`, so
  /// the children are totally ordered and the bytes are reproducible.
  func fromMouseMappings() throws -> XMLElement {
    let element = XMLElement.createElement("mappings")
    for (modifiers, tool) in file.options.mouseMappings.mappings {
      guard let toolElement = try fromTool(tool) else {
        // Java: `toolElt.setAttribute(…)` on a null: an NPE that escapes into `Loader.save`.
        throw XmlWriterError.toolNotFound(tool.displayName)
      }
      toolElement.setAttribute("map", InputEventUtil.toString(modifiers))
      element.appendChild(toolElement)
    }
    return element
  }

  /// `XmlWriter.fromToolbarData()`. A null entry is a separator, and `<toolbar>` is *not* sorted,
  /// so separator positions survive verbatim.
  func fromToolbarData() throws -> XMLElement {
    let element = XMLElement.createElement("toolbar")
    for tool in file.options.toolbarData.toolbarContents {
      guard let tool else {
        element.appendChild(XMLElement.createElement("sep"))
        continue
      }
      guard let toolElement = try fromTool(tool) else {
        // Java: `appendChild(null)`: again an NPE reaching `Loader.save`.
        throw XmlWriterError.toolNotFound(tool.displayName)
      }
      element.appendChild(toolElement)
    }
    return element
  }

  /// `XmlWriter.fromTool(Tool)`.
  ///
  /// Returns nil exactly where Java returns null. Both callers then dereference it, which is why
  /// they turn nil into a throw rather than silently skipping the entry.
  func fromTool(_ tool: Tool) throws -> XMLElement? {
    // D8: an entry whose tool never resolved is re-emitted exactly as it arrived, including its
    // original `lib` handle. Libraries are renumbered from 0 on write, so a preserved handle can
    // only be trusted while the same libraries are present in the same order, which holds for a
    // straight load->save, the case this exists to keep lossless.
    if let preserved = tool as? PreservedTool {
      guard let duplicate = preserved.rawElement.copy() as? XMLElement else { return nil }
      duplicate.detach()
      return duplicate
    }

    let libName: String?
    if let library = findLibrary(of: tool) {
      if library === file {
        libName = nil
      } else if let resolved = libs[ObjectIdentifier(library)] {
        libName = resolved
      } else {
        loader.showError("unknown library within file")
        return nil
      }
    } else {
      loader.showError("tool `\(tool.displayName)' not found")
      return nil
    }

    let element = XMLElement.createElement("tool")
    if let libName { element.setAttribute("lib", libName) }
    element.setAttribute("name", tool.name)
    try addAttributeSetContent(
      element, tool.attributeSet, source: tool, userModifiedOnly: true)
    return element
  }

  /// `XmlWriter.fromCircuit(Circuit)`.
  ///
  /// Append order is `<a>`s, `<appear>`, wires, comps, board maps, but `<circuit>` *is* sorted,
  /// so the file always shows `a` … `appear` … `boardmap` … `comp` … `wire`.
  func fromCircuit(_ circuit: any CircuitSaving) throws -> XMLElement {
    let element = XMLElement.createElement("circuit")
    element.setAttribute("name", circuit.savedName)
    try addAttributeSetContent(
      element, circuit.savedStaticAttributes,
      source: CircuitAttributes.defaultStaticAttributes, userModifiedOnly: false)

    // ── `<appear>`: the model-driven path, then D8's verbatim one ───────────────────────────
    //
    // Upstream has only the first branch, because upstream always has a live `CircuitAppearance`
    // to ask. This port does not: `CircuitAppearanceWriter.handler` is nil until M6/M7 builds
    // the canvas model, and **nothing installs one**. With only the first branch, every custom
    // circuit appearance in the file is destroyed by a plain open-and-save while the
    // `<a name="appearance" val="custom"/>` attribute naming it survives; the saved file then
    // claims an appearance it no longer carries. Measured on the canonical corpus: a missing
    // `<appear>` was the single largest remaining diff, 87 files.
    //
    // So the fallback re-emits the element the reader kept (`Circuit.absorbAppearance(_:)` →
    // `Circuit.rawAppearance`, surfaced here as `CircuitAppearancePreserving.appearanceElement`).
    // It is a **copy**: appending the stored node itself would re-parent it out of the circuit
    // and empty the model on the first save, the same precaution `fromComponent`, `fromTool`,
    // `fromMap` and the `<vhdl>` branch of `fromLogisimFile` all take.
    //
    // `else if`, not a second `if`: the two paths are alternatives, and a live handler is the
    // authority the moment one exists. `sort` then treats the copied element exactly as it would
    // a freshly built one; `"appear"` is special-cased there, so only its `circ-port` children
    // are reordered and the drawn shapes keep the order they were read in. That is idempotent on
    // a file upstream already wrote, because upstream sorted it the same way.
    if let handler = CircuitAppearanceWriter.handler, handler.hasCustomAppearance(circuit) {
      let appear = XMLElement.createElement("appear")
      for svg in handler.appearanceElements(for: circuit) {
        appear.appendChild(svg)
      }
      element.appendChild(appear)
    } else if let preserved = circuit as? any CircuitAppearancePreserving,
      let raw = preserved.appearanceElement,
      let duplicate = raw.copy() as? XMLElement
    {
      duplicate.detach()
      element.appendChild(duplicate)
    }

    for wire in circuit.savedWires {
      element.appendChild(fromWire(wire, in: circuit))
    }
    for component in circuit.savedNonWires {
      if let componentElement = try fromComponent(component) {
        element.appendChild(componentElement)
      }
    }
    if let maps = circuit as? any CircuitBoardMapSaving {
      for board in maps.savedBoardMapNames {
        element.appendChild(fromMap(maps, board: board))
      }
    }
    return element
  }

  /// `XmlWriter.fromWire(Wire)`.
  ///
  /// **D16 deviation, recorded rather than hidden.** 4.1.0's `fromWire` takes only the wire and
  /// writes exactly `from` and `to`; `Wire.ATTRIBUTES` there is `[DIR_ATTR, LEN_ATTR]` and
  /// `BUS_WIDTH_POS` does not exist anywhere in the 4.1.0 tree. The `buswidthpos` attribute below
  /// is 4.2.0-dev's, and it is kept on purpose:
  ///
  ///   * It is **unreachable on any input the gate uses.** The only way `savedWireBusWidthPos`
  ///     returns non-nil is for `XmlCircuitReader` to have parsed a `buswidthpos=` attribute, and
  ///     no file written by 4.1.0 or earlier carries one. Every corpus and canonical file is in
  ///     that set, so this branch never fires against the oracle.
  ///   * Where it *is* reachable, a 4.2.0-authored file, dropping it would silently destroy
  ///     data the reader successfully parsed, which is the failure mode D8 exists to prevent.
  ///
  /// If the port is ever re-pinned to 4.1.0 strictly, this and `XmlCircuitReader`'s matching
  /// `buswidthpos` parse must come out together; removing only one of them is the data-losing
  /// combination.
  func fromWire(_ wire: Wire, in circuit: any CircuitSaving) -> XMLElement {
    let element = XMLElement.createElement("wire")
    element.setAttribute("from", wire.end0.description)
    element.setAttribute("to", wire.end1.description)
    // 4.2.0 tests `pos != null && pos != Wire.BUS_WIDTH_POS_NONE`; the seam folds
    // `BUS_WIDTH_POS_NONE` into nil, so the two halves collapse into one optional binding.
    if let position = circuit.savedWireBusWidthPos(wire) {
      // Java writes `pos.getValue().toString()`, not `pos.toString()`. Upstream builds all four
      // options with the two-argument `AttributeOption(value, desc)` constructor, which sets
      // `name = value.toString()`, so the two agree; the port reads the payload where there is
      // one so a three-argument option would still come out right.
      element.setAttribute("buswidthpos", XmlWriter.optionValueString(position))
    }
    return element
  }

  /// `AttributeOption.getValue().toString()`.
  static func optionValueString(_ option: AttributeOption) -> String {
    switch option.payload {
    case .string(let text): return text
    case .integer(let value): return String(value)
    case .boolean(let flag): return flag ? "true" : "false"
    case .none: return option.name
    }
  }

  /// `XmlWriter.fromComponent(Component)`.
  func fromComponent(_ component: any Component) throws -> XMLElement? {
    // ── D8, the writer's half ────────────────────────────────────────────────────────────────
    //
    // Upstream has no branch here because upstream has nothing to write: a component whose
    // library could not supply a factory was already discarded during the read, and re-saving
    // the file destroys it permanently. The port keeps the `<comp>` element verbatim
    // (`UnresolvedComponent.rawElement`) and re-emits a copy, which is what makes the permanent
    // `jar#` gap (D11) non-destructive rather than merely equal to upstream.
    //
    // Taking Java's path instead would be actively wrong: `findLibrary` cannot resolve an
    // `UnresolvedComponentFactory`, it belongs to no library, so the code below would call
    // `showError` and return nil, i.e. drop the component. That is exactly the behaviour D8
    // exists to replace.
    //
    // The element is **copied** before it is appended, or the append would re-parent it out of
    // the component and empty the model on the first save. `sort` then orders its `<a>` children
    // like any other `<comp>`, which is correct: they were sorted when the file was written.
    //
    // ── The one thing that is *not* re-emitted verbatim: the `lib="n"` handle ────────────────
    //
    // `fromLibrary` renumbers every library from 0 in write order, so the handle the element
    // arrived with is only accidentally still correct. Three ways it goes wrong, all real:
    //
    //   * a migration repair inserts a library; `repairForFPArithmetic` adds `#FPArithmetic`
    //     and rewrites its components to the *string* `lib="float"`, which is not a number at
    //     all and matches no `<lib name=…>` this writer emits;
    //   * a file numbers its libraries non-sequentially (nothing in the format forbids it), so
    //     every later index shifts;
    //   * `removeUnusedLibraries` drops one and leaves a gap.
    //
    // Emitting the stale handle produces a file whose `<comp>` names a library that is absent or
    // , worse, because it is silent, a *different* one. The component is then destroyed by the
    // next load. That is upstream's data loss deferred by exactly one save, not prevented, so
    // D8 is not satisfied until the handle is rewritten. Measured on
    // `3.7.2__case-321.circ`, which trips the `float` case: 101 components in,
    // 101 out, **95** after a second open-and-save. With the rewrite, 101 out and 101 again.
    //
    // The element is **copied** before it is appended and before it is edited, or the append
    // would re-parent it out of the component and the rewrite would corrupt the model's own
    // record on the first save. `sort` then orders its `<a>` children like any other `<comp>`,
    // which is correct: they were sorted when the file was written.
    if let unresolved = component as? UnresolvedComponent, let raw = unresolved.rawElement {
      guard let duplicate = raw.copy() as? XMLElement else { return nil }
      duplicate.detach()
      // Only a non-empty handle is rewritten. An empty or absent one means `findLibrary` returned
      // the file itself, which is exactly the case `fromComponent` writes with no `lib` attribute
      // at all, so there is nothing to renumber and nothing to remove.
      if duplicate.hasAttribute("lib"), !duplicate.getAttribute("lib").isEmpty,
        let factory = unresolved.factory as? UnresolvedComponentFactory,
        let library = factory.sourceLibrary,
        library !== file,
        let resolved = libs[ObjectIdentifier(library)]
      {
        duplicate.setAttribute("lib", resolved)
      }
      return duplicate
    }

    let source = component.factory
    let libName: String?
    if let library = findLibrary(factoryOf: source) {
      if library === file {
        libName = nil
      } else if let resolved = libs[ObjectIdentifier(library)] {
        libName = resolved
      } else {
        loader.showError("unknown library within file")
        return nil
      }
    } else {
      loader.showError("\(source.name) component not found")
      return nil
    }

    if source.name == TextComponent.id {
      // "check if the text element is empty, in this case we do not save"; upstream's comment.
      // Java reaches `Text.ATTR_TEXT` by static import. The factory has already been identified
      // by its `_ID` here, so looking its `"text"` attribute up by name is the same object,
      // without `LogisimFile` importing the component tranche. Same substitution
      // `XmlReaderSupport.TextComponent` documents on the reader's side.
      let attributes = component.attributeSet
      guard let textAttribute = attributes.attribute(named: TextComponent.textAttributeName),
        let stored = attributes.rawValue(textAttribute)
      else {
        // Java: `value.isEmpty()` on a null: an NPE reaching `Loader.save`.
        throw XmlWriterError.missingTextAttribute
      }
      guard case .string(let text) = stored else {
        throw XmlWriterError.unrepresentableAttributeValue(attribute: textAttribute.name)
      }
      if text.isEmpty { return nil }
    }

    let element = XMLElement.createElement("comp")
    if let libName { element.setAttribute("lib", libName) }
    element.setAttribute("name", source.name)
    element.setAttribute("loc", component.location.description)
    // `userModifiedOnly: false`; this is the call site that force-writes `StdAttr.APPEARANCE`
    // even when it equals the factory default.
    try addAttributeSetContent(
      element, component.attributeSet, source: component.factory, userModifiedOnly: false)
    return element
  }

  /// `XmlWriter.fromVhdl(VhdlContent)` (4.1.0).
  ///
  /// The source goes in as a single text node, so the serializer writes it flush against both
  /// tags with no indentation and no newline before `</vhdl>`; the "one text child" case.
  ///
  /// **D16.** 4.2.0-dev added `ret.setAttribute("appearance",
  /// StdAttr.APPEARANCE.toStandardString(vhdl.getAppearance()))`. 4.1.0 writes `name` and the
  /// body and nothing else, and its `XmlReader` (`:461-467`) reads only those two back, so the
  /// attribute is synthesised out of `VhdlContent`'s field default rather than round-tripped.
  /// Emitting it would put an unconditional byte on every `<vhdl>` element that the oracle never
  /// writes. Deliberately omitted; `VhdlContentSaving` no longer requires `appearance`.
  func fromVhdl(_ vhdl: any VhdlContentSaving) -> XMLElement {
    vhdl.aboutToSave()
    let element = XMLElement.createElement("vhdl")
    element.setAttribute("name", vhdl.name)
    element.appendChild(XmlWriter.textNode(vhdl.content))
    return element
  }

  /// `XmlWriter.fromMap(Circuit, String)`.
  ///
  /// The `<boardmap boardname="…">` wrapper is rebuilt exactly as upstream builds it; only the
  /// `<mc>` children come from the seam rather than from `MapComponent` (see
  /// `CircuitBoardMapSaving`). Each child is **copied**, because appending the stored node itself
  /// would re-parent it out of the circuit and empty the model on the first save.
  func fromMap(_ circuit: any CircuitBoardMapSaving, board: String) -> XMLElement {
    let element = XMLElement.createElement("boardmap")
    element.setAttribute("boardname", board)
    for stored in circuit.savedBoardMapElements(forBoard: board) {
      guard let duplicate = stored.copy() as? XMLElement else { continue }
      duplicate.detach()
      element.appendChild(duplicate)
    }
    return element
  }

  // MARK: - Helpers

  static func textNode(_ value: String) -> XMLNode {
    // `XMLNode.text(withStringValue:)` is documented to return an `XMLNode`; the `Any` return
    // type is an Objective-C bridging artefact.
    XMLNode.text(withStringValue: value) as! XMLNode
  }

  /// `java.io.File.getAbsolutePath()`.
  ///
  /// The contract is narrow and it is the *absence* of a step that matters: an already-rooted
  /// path is returned unchanged, and a relative one is resolved against the working directory
  /// (`user.dir`). **Neither branch normalises**, so `.` and `..` survive as name elements;
  /// that is `getCanonicalPath`'s job, and upstream calls `getAbsolutePath`.
  ///
  /// `URL.path` matches for a rooted path. It cannot be trusted to reproduce the relative branch,
  /// because `URL(fileURLWithPath:)` resolves *and collapses* `..` while absolutising
  /// (`"rel/../x.circ"` becomes `"<cwd>/x.circ"`, where Java gives `"<cwd>/rel/../x.circ"`), but
  /// that collapse happens at `URL` construction, before this writer is handed anything, so the
  /// branch below is the faithful behaviour for the only kind of relative `URL` that can still
  /// reach here.
  static func javaAbsolutePath(_ url: URL) -> String {
    let path = url.path
    if path.hasPrefix("/") { return path }
    let workingDirectory = FileManager.default.currentDirectoryPath
    if workingDirectory.hasSuffix("/") { return workingDirectory + path }
    return workingDirectory + "/" + path
  }

  /// `java.nio.file.Path.relativize`, for the one attribute that uses it: `filePath`, defined by
  /// `std.tcl.TclComponentAttributes`. D11 defers `std/tcl` permanently, but the writer must not
  /// change behaviour when that gap is revisited, so the rule is ported now.
  ///
  /// Java's contract, reproduced: identical paths give the empty string; mixing an absolute path
  /// with a relative one throws `IllegalArgumentException` (D13 → `throw`); otherwise the result
  /// is one `..` per unmatched element of the base, followed by the unmatched tail of the target.
  /// `Paths.get` does **not** normalise, so `.` and `..` inside either path are ordinary name
  /// elements and are compared as such; a rule a "helpful" implementation built on
  /// `URL.standardized` would silently change.
  static func javaRelativize(base: String, target: String) throws -> String {
    if base == target { return "" }
    let baseAbsolute = base.hasPrefix("/")
    let targetAbsolute = target.hasPrefix("/")
    guard baseAbsolute == targetAbsolute else {
      throw XmlWriterError.cannotRelativize(base: base, target: target)
    }

    let baseParts = base.split(separator: "/").map(String.init)
    let targetParts = target.split(separator: "/").map(String.init)
    if baseParts.isEmpty { return targetParts.joined(separator: "/") }

    var common = 0
    let shared = min(baseParts.count, targetParts.count)
    while common < shared, baseParts[common] == targetParts[common] { common += 1 }

    var parts = [String](repeating: "..", count: baseParts.count - common)
    parts.append(contentsOf: targetParts[common...])
    return parts.joined(separator: "/")
  }
}

// MARK: - LogisimFileWriting

/// The `LogisimFileWriting` seam `Loader` installs.
///
/// Upstream has no counterpart, `LogisimFile.write` calls `XmlWriter.write` statically, so this
/// is the port's own object, and it is where the two settings that upstream reads out of global
/// state live. A fresh `XmlWriter` is built per call, because `libs` must restart at index 0.
public final class XmlFileWriter: LogisimFileWriting {
  /// `AppPreferences.REMOVE_UNUSED_LIBRARIES.getBoolean()`; upstream's default is `false`.
  public var removeUnusedLibraries = false

  /// `Loader.getZipFile()` and the bundle helpers around it. Nil is Java's `zipFile == null`.
  public var bundleSink: (any ProjectBundleSink)?

  public init() {}

  public func write(
    _ file: LogisimFile,
    loader: any LibraryLoader,
    destination: URL?,
    mainCircFile: String?,
    recurse: Bool
  ) throws -> Data {
    try XmlWriter.write(
      file: file,
      loader: loader,
      destination: destination,
      mainCircFile: mainCircFile,
      recurse: recurse,
      removeUnusedLibraries: removeUnusedLibraries,
      bundleSink: bundleSink)
  }
}
