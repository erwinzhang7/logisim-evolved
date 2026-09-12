// VhdlContent: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// com/cburch/logisim/vhdl/base/VhdlContent.java. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore licensed
// GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── Module boundary ──────────────────────────────────────────────────────────────────────
//
// This file depends on `LogisimKernel` only. Three things Java's `VhdlContent` reaches for
// live in modules this task does not own (`LogisimFile`, `LogisimStd`) and are deliberately
// not imported here, to keep this port buildable and testable in isolation:
//
//   * **`LogisimFile` (duplicate-name checking).** Java's constructor takes a `LogisimFile`
//     and calls `file.containsFactory(label)` to reject a name already used by another
//     component in the project. `VhdlNameCollisionChecking` below is the seam: any type
//     (eventually `LogisimFile`) can conform and be passed in; omitting it (the default)
//     just skips that one check, matching Java's own `null`-file path
//     (`labelVHDLInvalidNotify(name, null)`, used deliberately when the name did not change).
//
//   * **`StdAttr`/`AttributeOption` identity for `appearance`.** Java compares the current
//     appearance against `StdAttr.APPEAR_CLASSIC`/`APPEAR_FPGA`/`APPEAR_EVOLUTION`, three
//     singletons declared in `LogisimFile`'s `StdAttr`. `AttributeOption` (from
//     `LogisimKernel`) already compares structurally on `(name, payload)` (see
//     `Attributes.swift`), so this file declares its own `VhdlAppearanceStyle` constants with
//     the exact same `name` strings Java uses: `"classic"`, `"evolution"`, and, confusingly,
//     `"logisim_evolution"` for what Java calls `APPEAR_EVOLUTION` (see `VhdlAppearanceStyle`
//     for the full naming trap). They compare equal to `StdAttr`'s constants by value, with
//     no shared instance required.
//
//   * **Real VHDL syntax validation.** Java's `setContent` calls
//     `Softwares.validateVhdl(...)`, a QuestaSim/ModelSim `vcom` invocation, *before*
//     running `VhdlParser`. That is the co-simulation bridge D11 puts out of scope on macOS.
//     This port's validity is exactly what `VhdlParser` accepts (see that file's header for
//     what that ceiling actually is).
//
//   * **Dialogs (`showErrors`).** D9/D17: converted to data. `lastValidationError` carries
//     the same title/message Java would have shown in a modal dialog (or logged, under
//     `Main.headless`); nothing pops a window.

import Foundation
import LogisimKernel

// MARK: - Name-collision seam (see header)

/// The one fact Java's `LogisimFile` contributes to VHDL name validation: whether some other
/// component in the project already uses a given name. See the file header for why this is a
/// protocol rather than a direct `LogisimFile` dependency.
public protocol VhdlNameCollisionChecking: AnyObject {
  func containsFactory(named name: String) -> Bool
}

// MARK: - Appearance style (see header for the naming trap)

/// Stand-ins for `StdAttr.APPEAR_CLASSIC`/`APPEAR_FPGA`/`APPEAR_EVOLUTION`, matching their
/// `.circ` token (`AttributeOption.name`) exactly.
///
/// The trap, preserved because it is what actually round-trips: the *value* Java calls
/// `APPEAR_FPGA` is literally named `"evolution"`, and the *default* style, the one named
/// `APPEAR_EVOLUTION` and used for every new component, is named `"logisim_evolution"`.
/// `"evolution"` as a `.circ` token means the FPGA/Holy-Cross appearance, not the Evolution
/// one.
public enum VhdlAppearanceStyle {
  public static let classic = AttributeOption(name: "classic")
  public static let fpga = AttributeOption(name: "evolution")
  public static let evolution = AttributeOption(name: "logisim_evolution")

  public static let all: [AttributeOption] = [classic, fpga, evolution]
}

// MARK: - Name validation

/// Why `VhdlContent.labelVHDLInvalidNotify` rejected a name. The three cases map 1:1 to
/// upstream's three dialog messages (`vhdlInvalidNameError`/`vhdlKeywordNameError`/
/// `vhdlDuplicateNameError` in `hdl.properties`); presenting them is a UI concern (D9), so
/// this is data, not a dialog.
public enum VhdlNameError: Equatable, Sendable {
  /// Fails `^[A-Za-z]\w*$`, ends with `_`, or contains `__`.
  case invalidSyntax
  /// One of the 96 reserved VHDL keywords.
  case reservedKeyword
  /// Already used by another component in the project (only checked when a collision checker
  /// was supplied and the name actually changed, see `VhdlContent.setName`).
  case duplicateName

  /// English text mirroring `hdl.properties`, for logging (D17), not localized (D9).
  public var message: String {
    switch self {
    case .invalidSyntax:
      return "Invalid VHDL Entity name. Names must:\n"
        + " * start with a letter,\n"
        + " * contain only letters,numbers, and underscores,\n"
        + " * not end with an underscore,\n"
        + " * not contain two consecutive underscores."
    case .reservedKeyword:
      return "Invalid VHDL Entity name. That is a reserved keyword."
    case .duplicateName:
      return "Invalid VHDL Entity name. Names must be unique."
    }
  }
}

// MARK: - VhdlContent

/// `com.cburch.logisim.vhdl.base.VhdlContent`.
public final class VhdlContent: HdlContent {

  // MARK: Generic (mirrors `VhdlContent.Generic`)

  /// A reference type (unlike `VhdlGenericDescription`, a value type) because `setContent`
  /// needs to preserve *identity* across a re-parse when a generic's name and type are
  /// unchanged; see the comment in `setContent` on why that also means a generic's default
  /// value can go stale relative to newly-edited source, faithfully.
  public final class Generic {
    public let name: String
    public let type: String
    public let defaultValue: Int32

    public init(name: String, type: String, defaultValue: Int32) {
      self.name = name
      self.type = type
      self.defaultValue = defaultValue
    }

    convenience init(_ description: VhdlGenericDescription) {
      self.init(name: description.name, type: description.type, defaultValue: description.defaultValue)
    }
  }

  /// A validation failure, as data (see the file header on `showErrors`).
  public struct ValidationError {
    public let title: String
    public let message: String
    public let underlying: Error?
  }

  // MARK: Storage

  private(set) var rawContent: String = ""
  private(set) var valid = false
  private(set) var storedName: String
  private(set) var storedLibraries: String = ""
  private(set) var storedArchitecture: String = ""
  private(set) var storedPorts: [VhdlPortDescription] = []
  private(set) var storedGenerics: [Generic] = []
  private(set) var storedGenericAttributes: [VhdlGenericAttribute] = []
  private(set) var storedStaticAttributes: (any AttributeSet)?

  /// `VhdlContent.appearance`, defaulting to `StdAttr.APPEAR_EVOLUTION` as Java does.
  public private(set) var appearance: AttributeOption = VhdlAppearanceStyle.evolution

  /// `VhdlContent.showErrors`'s payload, as data. `nil` once `setContent` last succeeded.
  public private(set) var lastValidationError: ValidationError?

  /// See `VhdlNameCollisionChecking`. Weak: this is a query seam, not an ownership edge.
  public private(set) weak var nameCollisionChecker: VhdlNameCollisionChecking?

  private init(name: String, nameCollisionChecker: VhdlNameCollisionChecking?) {
    self.storedName = name
    self.nameCollisionChecker = nameCollisionChecker
    super.init()
  }

  // MARK: Static factories (`VhdlContent.create` / `.parse`)

  /// `VhdlContent.create(String, LogisimFile)`: a fresh entity from the built-in template.
  public static func create(
    name: String, nameCollisionChecker: VhdlNameCollisionChecking? = nil
  ) -> VhdlContent {
    let content = VhdlContent(name: name, nameCollisionChecker: nameCollisionChecker)
    content.setContent(template.replacingOccurrences(of: "%entityname%", with: name))
    return content
  }

  /// `VhdlContent.parse(String, String, LogisimFile)`: an entity loaded from existing source
  /// (the `<vhdl>` element in a `.circ` file).
  public static func parse(
    name: String, vhdl: String, nameCollisionChecker: VhdlNameCollisionChecking? = nil
  ) -> VhdlContent {
    let content = VhdlContent(name: name, nameCollisionChecker: nameCollisionChecker)
    content.setContent(vhdl)
    return content
  }

  // MARK: HdlModel

  public override var content: String { rawContent }
  public override var name: String { storedName }
  public override var isValid: Bool { valid }

  public override func compare(toContent text: String) -> Bool {
    normalizeNewlines(rawContent) == normalizeNewlines(text)
  }

  /// Java: `.replaceAll("\\r\\n|\\r|\\n", " ")`.
  private func normalizeNewlines(_ text: String) -> String {
    text.replacingOccurrences(of: "\\r\\n|\\r|\\n", with: " ", options: .regularExpression)
  }

  // MARK: Accessors

  public var libraries: String { storedLibraries }
  public var architecture: String { storedArchitecture }
  public var ports: [VhdlPortDescription] { storedPorts }
  public var generics: [Generic] { storedGenerics }
  public var genericAttributes: [VhdlGenericAttribute] { storedGenericAttributes }

  /// `VhdlContent.getStaticAttributes()`: the shared prototype attribute set built by
  /// `VhdlEntityAttributes.createBaseAttrs`, populated after the first successful
  /// `setContent`.
  public var staticAttributes: (any AttributeSet)? { storedStaticAttributes }

  public func setAppearance(_ style: AttributeOption) {
    appearance = style
    fireAppearanceChanged()
  }

  /// `VhdlContent.aboutToSave()`.
  public func aboutToSave() { fireAboutToSave() }

  // MARK: Renaming (`ENTITY_PATTERN`/`ARCH_PATTERN`/`END_PATTERN`)

  private static let entityRenamePattern = "(\\s*\\bentity\\s+)%entityname%(\\s+is)\\b"
  private static let architectureRenamePattern = "(\\s*\\barchitecture\\s+\\w+\\s+of\\s+)%entityname%\\b"
  private static let endRenamePattern = "(\\s*\\bend\\s+)%entityname%(\\s*;)"

  /// `VhdlContent.labelVHDLInvalid(String)`.
  public static func isInvalidVhdlLabel(_ label: String) -> Bool {
    validate(label, against: nil) != nil
  }

  /// `VhdlContent.labelVHDLInvalidNotify`, minus the dialog (see `VhdlNameError`).
  public static func validate(
    _ label: String, against checker: VhdlNameCollisionChecking?
  ) -> VhdlNameError? {
    if !matchesIdentifierShape(label) || label.hasSuffix("_") || label.contains("__") {
      return .invalidSyntax
    }
    if vhdlKeywords.contains(label.lowercased()) {
      return .reservedKeyword
    }
    if let checker, checker.containsFactory(named: label) {
      return .duplicateName
    }
    return nil
  }

  /// Java: `label.matches("^[A-Za-z]\\w*")`, where `String.matches` requires matching the
  /// *entire* string (an implicit `$` Java adds that the literal pattern text does not spell
  /// out). `\w` is ASCII-only in Java's default regex mode.
  private static func matchesIdentifierShape(_ label: String) -> Bool {
    guard let first = label.unicodeScalars.first, isAsciiLetter(first) else { return false }
    return label.unicodeScalars.dropFirst().allSatisfy { isAsciiLetter($0) || isAsciiDigit($0) || $0 == "_" }
  }

  private static func isAsciiLetter(_ scalar: Unicode.Scalar) -> Bool {
    (scalar.value >= 0x41 && scalar.value <= 0x5A) || (scalar.value >= 0x61 && scalar.value <= 0x7A)
  }

  private static func isAsciiDigit(_ scalar: Unicode.Scalar) -> Bool {
    scalar.value >= 0x30 && scalar.value <= 0x39
  }

  /// `VhdlContent.setName(String)`.
  @discardableResult
  public func setName(_ newName: String) -> Bool {
    if Self.validate(newName, against: nameCollisionChecker) != nil { return false }

    let entityPattern = compileRenamePattern(Self.entityRenamePattern, oldName: storedName)
    let architecturePattern = compileRenamePattern(Self.architectureRenamePattern, oldName: storedName)
    let endPattern = compileRenamePattern(Self.endRenamePattern, oldName: storedName)

    var text = rawContent
    text = replacing(entityPattern, in: text, template: "$1\(newName)$2")
    text = replacing(architecturePattern, in: text, template: "$1\(newName)")
    text = replacing(endPattern, in: text, template: "$1\(newName)$2")
    return setContent(text)
  }

  /// Java substitutes the *literal* old name into `%entityname%` with no regex-escaping;
  /// safe in practice because `setName` already rejects any name that is not
  /// `[A-Za-z]\w*`, so `oldName` can never contain a regex metacharacter. Preserved as-is
  /// rather than defensively escaped, to match Java exactly if that invariant is ever broken
  /// by a name that bypassed validation (e.g. one supplied directly to `parse(name:vhdl:)`).
  private func compileRenamePattern(_ template: String, oldName: String) -> NSRegularExpression {
    let pattern = template.replacingOccurrences(of: "%entityname%", with: oldName)
    // swiftlint:disable:next force_try; `template` is one of the three fixed literals above.
    return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
  }

  private func replacing(_ pattern: NSRegularExpression, in text: String, template: String) -> String {
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return pattern.stringByReplacingMatches(in: text, range: range, withTemplate: template)
  }

  // MARK: setContent / setContentNoValidation

  @discardableResult
  public override func setContentNoValidation(_ vhdl: String) -> Bool {
    if valid && rawContent == vhdl { return true }
    rawContent = vhdl
    valid = false
    return false
  }

  /// `VhdlContent.setContent(String)`.
  @discardableResult
  public override func setContent(_ vhdl: String) -> Bool {
    if setContentNoValidation(vhdl) { return true }

    defer { fireContentSet() }

    let parser = VhdlParser(source: rawContent)
    do {
      try parser.parse()
    } catch {
      let message: String
      if let parserError = error as? VhdlParserError, !parserError.message.isEmpty {
        message = parserError.message
      } else {
        message = String(describing: error)
      }
      lastValidationError = ValidationError(
        title: "VHDL Parsing Error", message: message, underlying: error)
      return false
    }

    // Java: check against the project only when the parsed name differs from the entity's
    // current name; when it is unchanged, pass a null file so a name this component already
    // holds never collides with itself.
    let checkerForThisName = parser.name != storedName ? nameCollisionChecker : nil
    if let nameError = Self.validate(parser.name, against: checkerForThisName) {
      lastValidationError = ValidationError(
        title: "VHDL Parsing Error", message: nameError.message, underlying: nil)
      return false
    }

    valid = true
    storedName = parser.name
    storedLibraries = parser.libraries
    storedArchitecture = parser.architecture
    storedPorts = parser.inputs + parser.outputs

    // Java: "If name and type is unchanged, keep old generic and attribute [object]"; note
    // this means a generic's *default value* is frozen at whatever it was the first time its
    // (name, type) pair appeared, even if a later edit to the VHDL source changes the
    // `:= value` for that same generic. Only renaming or retyping the generic makes the new
    // default value take effect. Preserved faithfully; it reads as a bug, not a feature.
    let oldGenerics = storedGenerics
    let oldAttributes = storedGenericAttributes
    var consumed = Array(repeating: false, count: oldGenerics.count)
    var newGenerics: [Generic] = []
    var newAttributes: [VhdlGenericAttribute] = []
    for parsed in parser.generics {
      var reused = false
      for index in oldGenerics.indices where !consumed[index] {
        let old = oldGenerics[index]
        if old.name == parsed.name && old.type == parsed.type {
          newGenerics.append(old)
          newAttributes.append(oldAttributes[index])
          consumed[index] = true
          reused = true
          break
        }
      }
      if !reused {
        let generic = Generic(parsed)
        newGenerics.append(generic)
        newAttributes.append(VhdlEntityAttributes.makeGenericAttribute(for: generic))
      }
    }
    storedGenerics = newGenerics
    storedGenericAttributes = newAttributes

    storedStaticAttributes = VhdlEntityAttributes.makeBaseAttributes(for: self)
    lastValidationError = nil
    return true
  }

  // MARK: Template (`resources/logisim/hdl/vhdl_component.templ`, embedded verbatim)

  /// Java loads this from a classpath resource (`RESOURCE`/`loadTemplate()`); embedded
  /// directly here since this module has no bundle-resource story of its own yet. Content is
  /// byte-for-byte the upstream template, `%entityname%` placeholder included.
  private static let template = """
    --------------------------------------------------------------------------------
    -- Project :
    -- File    :
    -- Autor   :
    -- Date    :
    --
    --------------------------------------------------------------------------------
    -- Description :
    --
    --------------------------------------------------------------------------------

    LIBRARY ieee;
    USE ieee.std_logic_1164.all;

    ENTITY %entityname% IS
      PORT (
      ------------------------------------------------------------------------------
      --Insert input ports below
        clock      : IN  std_logic;                    -- input bit example
        val        : IN  std_logic_vector(3 DOWNTO 0); -- input vector example
      ------------------------------------------------------------------------------
      --Insert output ports below
        max        : OUT std_logic;                    -- output bit example
        cpt        : OUT std_logic_vector(3 DOWNTO 0)  -- output vector example
        );
    END %entityname%;

    --------------------------------------------------------------------------------
    --Complete your VHDL description below
    --------------------------------------------------------------------------------

    ARCHITECTURE TypeArchitecture OF %entityname% IS

    BEGIN


    END TypeArchitecture;

    """
}

// MARK: - VHDL reserved words

/// `com.cburch.logisim.fpga.hdlgenerator.Vhdl.VHDL_KEYWORDS` (99 entries; 98 distinct words
/// plus the duplicated `"all"` upstream's own array literal has twice). That type lives in the
/// FPGA/HDL-generator package, a different module than this task owns (and one that does not
/// exist yet); the list is duplicated here rather than imported so `VhdlContent`'s name
/// validation does not have to wait on that module. Reconciling the two into one shared
/// definition is future integration work, not a correctness gap; the words themselves do
/// not change.
let vhdlKeywords: Set<String> = [
  "abs", "all", "access", "after", "alias", "and", "architecture", "array", "assert",
  "attribute", "begin", "block", "body", "buffer", "bus", "case", "component", "configuration",
  "constant", "disconnect", "downto", "else", "elsif", "end", "entity", "exit", "file", "for",
  "function", "generate", "generic", "group", "guarded", "if", "integer", "impure", "in",
  "inertial", "inout", "is", "label", "library", "linkage", "literal", "loop", "map", "mod",
  "nand", "new", "next", "nor", "not", "null", "of", "on", "open", "or", "others", "out",
  "package", "port", "postponed", "procedure", "process", "pure", "range", "record", "register",
  "reject", "rem", "report", "return", "rol", "ror", "select", "severity", "signal", "shared",
  "sla", "sll", "sra", "srl", "subtype", "then", "to", "transport", "type", "unaffected",
  "units", "until", "use", "variable", "wait", "when", "while", "with", "xnor", "xor",
]
