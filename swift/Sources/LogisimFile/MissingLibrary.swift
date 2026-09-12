// logisim-evolved: a native Swift/macOS port of logisim-evolution.
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution),
// which is GPL-3.0-only. This port is a derivative work and is therefore GPL-3.0-only.
// SPDX-License-Identifier: GPL-3.0-only
//
// D8: unknown components round-trip instead of being dropped.
//
// This file has no upstream counterpart, and that is the point. Upstream, an unresolvable
// `<lib>` produces an error dialog and `LibraryManager.loadLibrary` returns null; XmlReader
// then discards every `<comp>` that referenced it, and the next save writes the file back
// without them. The data is gone, silently, with no placeholder mechanism anywhere in the
// codebase to recover it.
//
// The port instead resolves such a declaration to a `MissingLibrary` that remembers its
// descriptor verbatim and mints an opaque `MissingTool` for every component name asked of it.
// That is what makes the permanent `jar#` gap (D11) non-destructive: a file using
// `jar#logisim-uart.jar#org.cdm.logisim.uart.Components`, the corpus contains five such
// files, loads, displays its components as placeholders, and saves back byte-identically
// instead of being quietly gutted.

import Foundation
import LogisimKernel

/// Why a `<lib>` declaration could not be resolved. Carried so a UI can say something more
/// useful than "missing", and so the differential rig can assert *which* path was taken.
public enum MissingLibraryReason: Equatable {
  /// `#Name` naming a builtin this version does not have. Real in the corpus: `#Risc-V` and
  /// `#Yosys Components` are 3.0.0-era builtins that 4.1.0 no longer ships.
  case builtinUnavailable(name: String)
  /// `jar#file.jar#com.Foo`: D11, a permanent functional gap. Resolving it needs
  /// `ZipClassLoader` + `Class.forName` + reflective instantiation, none of which has an
  /// AOT-Swift equivalent.
  case jarUnsupported(file: String, className: String)
  /// `file#path.circ` whose target could not be read or could not be parsed.
  case fileUnavailable(path: String, detail: String)
  /// A descriptor whose type segment is none of "", "file", "jar".
  case unrecognizedType(String)
  /// A descriptor with no `#` at all.
  case malformedDescriptor
}

/// An opaque stand-in for a tool of an unresolved library.
///
/// It exists so that a `<comp lib="6" name="UART">` has something to resolve to, and so the
/// writer can put the same `lib`/`name` pair back. It deliberately has no factory: there is
/// nothing to place, simulate or draw, and pretending otherwise would let a placeholder leak
/// into the netlist.
public final class MissingTool: Tool {
  private let identifier: String

  /// D3: the library owns its tools, so this back edge is `unowned`. A `MissingTool` is never
  /// held past its library's lifetime; the file owns the library, the library owns the tool.
  public unowned let library: MissingLibrary

  /// The `<tool>` element this placeholder came from, if the declaration carried one, so its
  /// `<a>` children survive the round trip untouched.
  public var rawElement: XMLElement?

  init(name: String, library: MissingLibrary) {
    self.identifier = name
    self.library = library
    super.init()
  }

  public override var name: String { identifier }
  public override var displayName: String { identifier }
}

/// A `<tool>` entry in `<toolbar>` or `<mouse>` whose tool could not be resolved, kept verbatim.
///
/// Distinct from `MissingTool`, which belongs to a `MissingLibrary`. This one is for the far
/// commoner case where the library resolved perfectly well and the *tool* did not: a builtin
/// shell has a real identity but an empty tool list until the component library lands at M4/M5,
/// so every toolbar entry naming one of its tools fails to resolve.
///
/// Upstream drops those entries and loses the user's toolbar layout on save. D8 says an element
/// we cannot interpret survives unchanged, so this carries the original and the writer re-emits
/// it. Each entry stops being used as its tool becomes real; nothing here needs revisiting.
public final class PreservedTool: Tool {
  private let identifier: String

  /// The `<tool>` element this stands in for, detached so later mutation of the source document
  /// cannot reach into stored state.
  public let rawElement: XMLElement

  public init(name: String, rawElement: XMLElement) {
    self.identifier = name
    let duplicate = (rawElement.copy() as? XMLElement) ?? rawElement
    duplicate.detach()
    self.rawElement = duplicate
    super.init()
  }

  public override var name: String { identifier }
  public override var displayName: String { identifier }
}

/// A `<lib>` declaration that could not be resolved, preserved so it survives load → save.
public final class MissingLibrary: Library {
  /// The descriptor exactly as it appeared in the file. `LibraryManager.getDescriptor` returns
  /// this unchanged, which is the whole round-trip guarantee: no path recomputation, no
  /// canonicalisation, no re-derivation from a library that does not exist.
  public let descriptorText: String

  public let reason: MissingLibraryReason

  /// The `<lib>` element's children, copied at load time. The writer re-emits these verbatim
  /// for any tool it has no better information about.
  public private(set) var rawChildren: [XMLElement] = []

  private var toolsByName: [String: MissingTool] = [:]
  private var toolOrder: [String] = []

  public init(descriptor: String, reason: MissingLibraryReason) {
    self.descriptorText = descriptor
    self.reason = reason
    super.init()
  }

  /// Java `Library.getName()` is the `_ID`. An unresolved library has none, so the closest
  /// stable identity is the part of the descriptor that *would* have been the id for a
  /// builtin, and the whole descriptor otherwise. This is only ever used for display and for
  /// `removeLibrary(named:)`; the file format keys libraries by their numeric handle and by
  /// `desc`, never by this.
  public override var name: String {
    if descriptorText.hasPrefix("#") { return String(descriptorText.dropFirst()) }
    return descriptorText
  }

  public override var displayName: String { descriptorText }

  public override var tools: [Tool] { toolOrder.compactMap { toolsByName[$0] } }

  /// Unlike a real library, this one never answers nil: any name asked of it is a name the
  /// file used, so a placeholder is minted on demand and remembered. That is what keeps
  /// `<comp>` elements attached to their library across a save.
  public override func tool(named name: String) -> Tool? {
    placeholderTool(named: name)
  }

  @discardableResult
  public func placeholderTool(named name: String) -> MissingTool {
    if let existing = toolsByName[name] { return existing }
    let created = MissingTool(name: name, library: self)
    toolsByName[name] = created
    toolOrder.append(name)
    return created
  }

  /// Records the `<lib>` element's `<tool>` children so the writer can reproduce them.
  ///
  /// Copies are taken (`XMLElement.copy()`), because the source document is released once the
  /// load finishes and Foundation's DOM nodes do not outlive their document safely.
  public func absorb(libraryElement element: XMLElement) {
    rawChildren.removeAll()
    for child in element.children ?? [] {
      guard let childElement = child as? XMLElement else { continue }
      guard let duplicate = childElement.copy() as? XMLElement else { continue }
      duplicate.detach()
      rawChildren.append(duplicate)
      if childElement.name == "tool",
        let toolName = childElement.attribute(forName: "name")?.stringValue
      {
        placeholderTool(named: toolName).rawElement = duplicate
      }
    }
  }

  /// D8's counterpart on the write side: nothing about a missing library is recomputed.
  public var isRoundTripOnly: Bool { true }
}
