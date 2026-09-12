// XmlReaderSupport.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution).
// Copyright by the Logisim-evolution developers. This translation is a derivative work and is
// therefore GPL-3.0-only. See LICENSE.md.
// SPDX-License-Identifier: GPL-3.0-only
//
// The pieces `XmlReader.java` and `XmlCircuitReader.java` reach into that live outside the
// `file` package and have no port yet. Each section below is either
//
//   (a) a faithful miniature port of a class the reader genuinely needs to *parse* something
//       (`InputEventUtil`, `BoardRectangle`, `CircuitMapInfo`, `MapComponent.getMapInfo`,
//       `VhdlContent.labelVHDLInvalid`), or
//   (b) a seam, a protocol plus a global install point, for a subsystem that is scheduled for
//       a later milestone (circuit appearance/SVG at M6, VHDL content in the parity backlog).
//
// Seams follow the pattern this module already uses for `LoaderUI`, `LogisimFileReading`,
// `BuiltinToolProviders` and `LoadedLibrary.replacementHandler`: nothing is stubbed with a
// `fatalError`, and with no handler installed the reader degrades to "does not interpret this
// element" rather than to "reports it as broken". Each such degradation is called out where it
// happens, because the difference shows up in the error list a differential run compares.

import Foundation
import LogisimKernel

// MARK: - Shared with the writer: BuildInfo, and Tool as an AttributeDefaultProvider
//
// Two declarations are needed by BOTH halves of the codec and must exist exactly once in the
// module. They currently live in `XmlWriter.swift`; if that file is ever split or removed they
// have to move somewhere, not disappear.
//
//   * `BuildInfo`; `com.cburch.logisim.generated.BuildInfo`. The reader uses `version` for one
//     thing: `toLogisimFile` takes it as `sourceVersion` when a `.circ` carries **no** `source=`
//     attribute at all. Note the asymmetry that creates, because it is load-bearing;
//     `considerRepairs` parses the same missing attribute through `LogisimVersion.fromString("")`
//     and gets `0.0.0`, so the migration gates see an ancient file while the attribute-default
//     machinery sees a brand new one. That is upstream's behaviour, and it is what makes the
//     synthesised `<2.3.0` fixture work.
//
//   * `extension Tool: AttributeDefaultProvider`: Java declares `public abstract class Tool
//     implements AttributeDefaultProvider`, and the reader relies on it at four call sites
//     (`initMouseMappings`, `initToolbarData`, `toLibrary`, and `XmlCircuitReader.getComponent`
//     via the factory).

// MARK: - std/wiring attributes the reader names directly

/// `com.cburch.logisim.std.wiring.ProbeAttributes`, reduced to the single attribute
/// `ReadContext.initAttributeSet` compares against by identity.
///
/// **This must be the same object the ported `Probe` component uses.** The comparison upstream
/// is `attr.equals(ProbeAttributes.PROBEAPPEARANCE)` and `Attribute` neither overrides `equals`
/// nor `hashCode`, so it is reference identity, which the port preserves (`AnyAttribute ==` is
/// `===`). When `std/wiring` lands at M5 it must import this declaration rather than minting a
/// second `Attributes.forOption("appearance", …)`, or the probe branch below silently stops
/// firing and every `<comp name="Probe">` without an explicit `appearance` attribute loads with
/// the wrong shape.
/// The unshadowed spelling of `ProbeAttributes`, for use from `LogisimStd`.
///
/// `LogisimStd/Wiring/ProbeAttributes.swift` declares its own `ProbeAttributes`, the ported
/// component's attribute set, which shadows this one inside that module, so the component
/// cannot name the declaration it must share. It forwards through this alias instead.
///
/// Sharing matters for a specific reason spelled out above: upstream compares with
/// `attr.equals(ProbeAttributes.PROBEAPPEARANCE)`, and since `Attribute` overrides neither
/// `equals` nor `hashCode`, that is reference identity. Minting a second
/// `Attributes.forOption("appearance", …)` in `LogisimStd` would compile and then silently stop
/// the probe branch firing, so every `<comp name="Probe">` without an explicit `appearance`
/// would load with the wrong shape.
public typealias SharedProbeAttributes = ProbeAttributes

public enum ProbeAttributes {

  /// `ProbeAttributes.APPEAR_EVOLUTION_NEW`.
  public static let appearEvolutionNew = AttributeOption(name: "NewPins")

  /// `ProbeAttributes.PROBEAPPEARANCE`.
  public static let probeAppearance: Attribute<AttributeOption> = Attributes.forOption(
    "appearance", choices: [StdAttr.appearClassic, appearEvolutionNew])

  /// `ProbeAttributes.getDefaultProbeAppearance()`.
  ///
  /// Upstream reads `AppPreferences.NEW_INPUT_OUTPUT_SHAPES`, whose default is `true`, so the
  /// stock answer is `APPEAR_EVOLUTION_NEW`. D9 forbids the model reaching into preferences, so
  /// the preference becomes an injectable default carrying upstream's value.
  public static var defaultProbeAppearance: AttributeOption = appearEvolutionNew
}

/// The two `AppPreferences` reads `initToolbarData` performs, lifted out per D9.
///
/// `AppPreferences.getDefaultAppearance()` maps the `defaultAppearance` preference, whose
/// declared default is `StdAttr.APPEAR_EVOLUTION`, onto `APPEAR_EVOLUTION` or `APPEAR_CLASSIC`.
/// Only those two are reachable; `APPEAR_FPGA` is a valid preference value but the method folds
/// it into `APPEAR_CLASSIC`, which is preserved by storing the *result* rather than the
/// preference.
public enum AppearancePreferences {
  public static var defaultAppearance: AttributeOption = StdAttr.appearEvolution
}

/// `com.cburch.logisim.std.base.Text`, reduced to what `buildCircuit`'s empty-text-box filter
/// needs.
///
/// The filter is `comp.getFactory() instanceof Text && comp.getAttributeSet().getValue(
/// Text.ATTR_TEXT).isEmpty()`. Neither the factory class nor the attribute exists yet, so both
/// tests go through stable `.circ` tokens instead of object identity; `"Text"` is the
/// factory's `_ID` and `"text"` is the attribute's serialised name. When `std/base` lands the
/// identity test can replace this without changing behaviour, because no other stock factory is
/// named `Text` and no other attribute of a `Text` component is named `text`.
public enum TextComponent {
  /// `Text._ID`.
  public static let id = "Text"
  /// `Text.ATTR_TEXT.getName()`.
  public static let textAttributeName = "text"
}

// MARK: - InputEventUtil

/// `com.cburch.logisim.util.InputEventUtil`, the `fromString`/`toString` half.
///
/// The `fromDisplayString`/`toDisplayString` half is localised UI text and does not come across
/// (D5's note on display strings). The masks are `java.awt.event.InputEvent`'s `*_DOWN_MASK`
/// constants, reproduced numerically so no AWT type is needed and so a saved file's `map=`
/// string round-trips to the same integer it had in Java.
public enum InputEventUtil {
  public static let ctrl = "Ctrl"
  public static let shift = "Shift"
  public static let alt = "Alt"
  public static let button1 = "Button1"
  public static let button2 = "Button2"
  public static let button3 = "Button3"

  /// `java.awt.event.InputEvent` down-masks. These values are part of the `.circ` contract only
  /// indirectly, the file stores the words above, but they are what `MouseMappings` keys on.
  public static let shiftDownMask: Int32 = 1 << 6
  public static let ctrlDownMask: Int32 = 1 << 7
  public static let altDownMask: Int32 = 1 << 9
  public static let button1DownMask: Int32 = 1 << 10
  public static let button2DownMask: Int32 = 1 << 11
  public static let button3DownMask: Int32 = 1 << 12

  /// Thrown where Java throws `NumberFormatException("InputEventUtil")`. `initMouseMappings`
  /// catches it and reports `mappingBadError`, so it never aborts a load.
  public struct ParseError: Error, CustomStringConvertible, Equatable {
    public var description: String { "InputEventUtil" }
  }

  /// Java: `InputEventUtil.fromString(String)`.
  ///
  /// `StringTokenizer` with no delimiter argument splits on `" \t\n\r\f"` and yields no empty
  /// tokens, which is what the whitespace split below reproduces.
  public static func fromString(_ str: String) throws -> Int32 {
    var result: Int32 = 0
    for token in javaWhitespaceTokens(str) {
      switch token {
      case ctrl: result |= ctrlDownMask
      case shift: result |= shiftDownMask
      case alt: result |= altDownMask
      case button1: result |= button1DownMask
      case button2: result |= button2DownMask
      case button3: result |= button3DownMask
      default: throw ParseError()
      }
    }
    return result
  }

  /// Java: `InputEventUtil.toString(int)`. Order is upstream's and is what the writer emits.
  public static func toString(_ mods: Int32) -> String {
    var parts: [String] = []
    if mods & ctrlDownMask != 0 { parts.append(ctrl) }
    if mods & altDownMask != 0 { parts.append(alt) }
    if mods & shiftDownMask != 0 { parts.append(shift) }
    if mods & button1DownMask != 0 { parts.append(button1) }
    if mods & button2DownMask != 0 { parts.append(button2) }
    if mods & button3DownMask != 0 { parts.append(button3) }
    return parts.joined(separator: " ")
  }

  /// `java.util.StringTokenizer(str)`: split on space, tab, newline, carriage return and form
  /// feed, discarding empty runs.
  private static func javaWhitespaceTokens(_ str: String) -> [String] {
    str.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" || $0 == "\u{0C}" })
      .map(String.init)
  }
}

// MARK: - Java numeric parsing the reader needs beyond the kernel's helpers

/// Java's `Integer.parseUnsignedInt`: accepts `0 … 4294967295` (and a leading `+`, but never a
/// `-`), and returns the two's-complement `int`: so `"4294967295"` is `-1`.
public func javaParseUnsignedInt32(_ s: some StringProtocol) -> Int32? {
  var text = Substring(s)
  guard !text.isEmpty else { return nil }
  if text.first == "+" {
    text = text.dropFirst()
    guard !text.isEmpty else { return nil }
  }
  var magnitude: UInt64 = 0
  for ch in text {
    guard let d = ch.wholeNumberValue, d >= 0, d <= 9 else { return nil }
    magnitude = magnitude &* 10 &+ UInt64(d)
    if magnitude > UInt64(UInt32.max) { return nil }
  }
  return Int32(bitPattern: UInt32(magnitude))
}

/// Java's `Long.parseLong`: 64-bit and signed.
public func javaParseInt64(_ s: some StringProtocol) -> Int64? {
  var text = Substring(s)
  guard !text.isEmpty else { return nil }
  var negative = false
  if let first = text.first, first == "-" || first == "+" {
    negative = (first == "-")
    text = text.dropFirst()
    guard !text.isEmpty else { return nil }
  }
  // Accumulate the magnitude unsigned so `Long.MIN_VALUE` is representable.
  let limit: UInt64 = negative ? 9_223_372_036_854_775_808 : 9_223_372_036_854_775_807
  var magnitude: UInt64 = 0
  for ch in text {
    guard let d = ch.wholeNumberValue, d >= 0, d <= 9 else { return nil }
    let (multiplied, overflowA) = magnitude.multipliedReportingOverflow(by: 10)
    if overflowA { return nil }
    let (added, overflowB) = multiplied.addingReportingOverflow(UInt64(d))
    if overflowB { return nil }
    magnitude = added
    if magnitude > limit { return nil }
  }
  return negative ? Int64(bitPattern: ~magnitude &+ 1) : Int64(magnitude)
}

/// Java's `Long.parseUnsignedLong`: `0 … 18446744073709551615`, returned as the
/// two's-complement `long`.
public func javaParseUnsignedInt64(_ s: some StringProtocol) -> Int64? {
  var text = Substring(s)
  guard !text.isEmpty else { return nil }
  if text.first == "+" {
    text = text.dropFirst()
    guard !text.isEmpty else { return nil }
  }
  var magnitude: UInt64 = 0
  for ch in text {
    guard let d = ch.wholeNumberValue, d >= 0, d <= 9 else { return nil }
    let (multiplied, overflowA) = magnitude.multipliedReportingOverflow(by: 10)
    if overflowA { return nil }
    let (added, overflowB) = multiplied.addingReportingOverflow(UInt64(d))
    if overflowB { return nil }
    magnitude = added
  }
  return Int64(bitPattern: magnitude)
}

/// `java.nio.file.Paths.get(first, more…)` for the one call site in `initAttributeSet`.
///
/// On a POSIX file system this joins the segments with `/`, drops empty segments, and collapses
/// redundant separators, but does **not** normalise `.` or `..`, and does **not** treat a
/// leading `/` on a later segment as making it absolute. `Paths.get("/a/b", "/c")` really is
/// `/a/b/c`, which is why the naive `URL.appendingPathComponent` is not a substitute.
public func javaPathsGet(_ first: String, _ more: String...) -> String {
  var segments = [first]
  segments.append(contentsOf: more)
  let joined = segments.filter { !$0.isEmpty }.joined(separator: "/")
  guard !joined.isEmpty else { return "" }

  let isAbsolute = joined.hasPrefix("/")
  var parts: [String] = []
  for part in joined.split(separator: "/", omittingEmptySubsequences: true) {
    parts.append(String(part))
  }
  let body = parts.joined(separator: "/")
  return isAbsolute ? "/" + body : body
}

// MARK: - VHDL label validation

/// `com.cburch.logisim.vhdl.base.VhdlContent.labelVHDLInvalid` and the keyword table it
/// consults (`com.cburch.logisim.fpga.hdlgenerator.Vhdl.VHDL_KEYWORDS`).
///
/// This is the whole of what `XmlReader.findValidLabels` needs from the VHDL subsystem, and it
/// runs on **every** file load through `ensureLogisimCompatibility`, so it cannot be deferred
/// behind a seam the way content parsing can.
public enum VhdlLabels {

  /// `Vhdl.RESERVED_VHDL_WORDS`, verbatim and in upstream's order (which contains `"all"`
  /// twice; harmless in a set, preserved so a diff against the Java array is clean).
  public static let reservedWords: Set<String> = [
    "abs", "all", "access", "after", "alias", "and", "architecture", "array", "assert",
    "attribute", "begin", "block", "body", "buffer", "bus", "case", "component",
    "configuration", "constant", "disconnect", "downto", "else", "elsif", "end", "endcase",
    "endgenerate", "endif", "endprocess", "entity", "exit", "file", "for", "function",
    "generate", "generic", "group", "guarded", "if", "integer", "impure", "in", "inertial",
    "inout", "is", "label", "library", "linkage", "literal", "loop", "map", "mod", "nand",
    "new", "next", "nor", "not", "null", "of", "on", "open", "or", "others", "out", "package",
    "port", "postponed", "procedure", "process", "pure", "range", "record", "register",
    "reject", "rem", "report", "return", "rol", "ror", "select", "severity", "signal",
    "shared", "sla", "sll", "sra", "srl", "subtype", "then", "to", "transport", "type",
    "unaffected", "units", "until", "use", "variable", "wait", "when", "while", "with",
    "xnor", "xor",
  ]

  /// Java: `VhdlContent.labelVHDLInvalid(String)`.
  ///
  /// ```java
  /// if (!label.matches("^[A-Za-z]\\w*") || label.endsWith("_") || label.matches(".*__.*"))
  ///   return true;
  /// return Vhdl.VHDL_KEYWORDS.contains(label.toLowerCase());
  /// ```
  ///
  /// Three Java-isms that a `NSRegularExpression` translation gets wrong:
  ///
  /// * `Matcher.matches()` anchors both ends, so `^[A-Za-z]\w*` means *the entire label* is an
  ///   ASCII letter followed by ASCII word characters. A label of `"a b"` is invalid.
  /// * `\w` is `[a-zA-Z0-9_]`: ASCII only, because `UNICODE_CHARACTER_CLASS` is never set.
  ///   `"café"` is therefore invalid here while ICU's `\w` would accept it.
  /// * `.*__.*` uses `.`, which never matches a line terminator. A label containing both `__`
  ///   and a newline does not match that clause, but it has already failed the first clause,
  ///   so the outcome is the same. The distinction is noted only because it is the kind of
  ///   thing that stops being harmless if the clauses are ever reordered.
  ///
  /// Deviation, deliberate and recorded: upstream calls `label.toLowerCase()` with the **default
  /// locale**, so under a Turkish locale `"IF"` lowercases to `"ıf"` and is not recognised as a
  /// keyword. The port uses ASCII lowercasing (`Locale.ROOT` semantics), which is what every
  /// non-Turkic locale produces and what upstream evidently intends. Importing the host locale
  /// would make label repair depend on system settings.
  public static func labelVHDLInvalid(_ label: String) -> Bool {
    if !isAsciiIdentifier(label) { return true }
    if label.hasSuffix("_") { return true }
    if label.contains("__") { return true }
    return reservedWords.contains(asciiLowercased(label))
  }

  /// Java's `^[A-Za-z]\w*` under `matches()`.
  static func isAsciiIdentifier(_ label: String) -> Bool {
    var scalars = Array(label.unicodeScalars)
    guard let first = scalars.first, isAsciiLetterScalar(first) else { return false }
    scalars.removeFirst()
    return scalars.allSatisfy(isJavaWordScalar)
  }

  /// `toLowerCase(Locale.ROOT)` restricted to what an ASCII identifier can contain.
  static func asciiLowercased(_ text: String) -> String {
    String(
      String.UnicodeScalarView(
        text.unicodeScalars.map { scalar in
          (scalar.value >= 0x41 && scalar.value <= 0x5A)
            ? Unicode.Scalar(scalar.value + 32)! : scalar
        }))
  }
}

// MARK: - FPGA board maps

/// `com.cburch.logisim.fpga.data.BoardRectangle`, reduced to the four coordinates the reader
/// parses out of a `<mc>` element. The rest of the class is FPGA placement (D11 territory).
public struct BoardRectangle: Hashable, Sendable {
  public let x: Int32
  public let y: Int32
  public let width: Int32
  public let height: Int32

  public init(x: Int32, y: Int32, width: Int32, height: Int32) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }
}

/// `com.cburch.logisim.circuit.CircuitMapInfo`.
///
/// Upstream this is a mutable class with six constructors and a mixture of "old" and "new" map
/// formats distinguished by an `oldMapFormat` flag. The reader only ever *constructs* one, so
/// the port models exactly the shapes `XmlReader.loadMap` and `MapComponent.getMapInfo` can
/// produce. `oldMapFormat` is preserved because it is the flag the FPGA layer branches on, and
/// it is set implicitly by which constructor ran.
public final class CircuitMapInfo {
  public private(set) var rect: BoardRectangle?
  public private(set) var constValue: Int64?
  public private(set) var pinId: Int32 = -1
  public private(set) var ioId: Int32 = -1
  public private(set) var isOldMapFormat = true
  public private(set) var pinMaps: [CircuitMapInfo?]?

  /// Java: `CircuitMapInfo()`, the "open" map.
  public init() {}

  /// Java: `CircuitMapInfo(BoardRectangle)`.
  public init(rect: BoardRectangle) {
    self.rect = rect
  }

  /// Java: `CircuitMapInfo(Long)`, a constant-valued map.
  public init(constant: Int64) {
    self.constValue = constant
  }

  /// Java: `CircuitMapInfo(int sourceId, int ioId, int xpos, int ypos)`. Note this one leaves
  /// `oldMapFormat` true, unlike the two below.
  public init(sourceId: Int32, ioId: Int32, x: Int32, y: Int32) {
    self.pinId = sourceId
    self.ioId = ioId
    self.rect = BoardRectangle(x: x, y: y, width: 1, height: 1)
  }

  /// Java: `CircuitMapInfo(int x, int y)`: the complete-map form, which clears `oldMapFormat`.
  public init(x: Int32, y: Int32) {
    self.isOldMapFormat = false
    self.rect = BoardRectangle(x: x, y: y, width: 1, height: 1)
  }

  /// Java: `addPinMap(CircuitMapInfo)`. Creating the list is what clears `oldMapFormat`.
  public func addPinMap(_ map: CircuitMapInfo?) {
    if pinMaps == nil {
      pinMaps = []
      isOldMapFormat = false
    }
    pinMaps?.append(map)
  }

  /// Java: `addPinMap(int x, int y, int loc)`. The source id is the current list length, so the
  /// insertion order is part of the data.
  public func addPinMap(x: Int32, y: Int32, location: Int32) {
    if pinMaps == nil {
      pinMaps = []
      isOldMapFormat = false
    }
    let sourceLocation = Int32(pinMaps?.count ?? 0)
    pinMaps?.append(
      CircuitMapInfo(sourceId: sourceLocation, ioId: location, x: x, y: y))
  }
}

/// `com.cburch.logisim.fpga.data.MapComponent`, reduced to `getMapInfo(Element)` and the four
/// attribute tokens it reads.
public enum MapComponent {
  public static let completeMap = "map"
  public static let openKey = "open"
  public static let constantKey = "vconst"
  public static let pinMap = "pmap"
  public static let noMap = "u"

  /// Java: `MapComponent.getMapInfo(Element)`.
  ///
  /// Every failure path returns null, which `loadMap` turns into "skip this entry", so a
  /// malformed `<mc>` loses one mapping and nothing else. Kept exactly, including the detail
  /// that a `pmap` entry containing `_` must split into exactly three parts.
  public static func mapInfo(from map: XMLElement) -> CircuitMapInfo? {
    if map.hasAttribute(completeMap) {
      let xy = javaSplitOnLiteral(map.getAttribute(completeMap), separator: ",")
      guard xy.count == 2 else { return nil }
      guard let x = javaParseUnsignedInt32(xy[0]), let y = javaParseUnsignedInt32(xy[1]) else {
        return nil
      }
      return CircuitMapInfo(x: x, y: y)
    }
    if map.hasAttribute(pinMap) {
      let maps = javaSplitOnLiteral(map.getAttribute(pinMap), separator: ",")
      let complex = CircuitMapInfo()
      for entry in maps {
        if entry == noMap {
          complex.addPinMap(nil)
        } else if entry == openKey {
          complex.addPinMap(CircuitMapInfo())
        } else if entry.contains("_") {
          let parts = javaSplitOnLiteral(entry, separator: "_")
          guard parts.count == 3 else { return nil }
          guard let x = javaParseUnsignedInt32(parts[0]),
            let y = javaParseUnsignedInt32(parts[1]),
            let pin = javaParseUnsignedInt32(parts[2])
          else {
            return nil
          }
          complex.addPinMap(x: x, y: y, location: pin)
        } else {
          guard let constant = javaParseUnsignedInt64(entry) else { return nil }
          complex.addPinMap(CircuitMapInfo(constant: constant))
        }
      }
      return complex
    }
    return nil
  }
}

/// Java's `String.split(String regex)` for a single literal character: keeps leading and
/// interior empty segments, discards trailing ones. The empty input is special: Java returns
/// `[""]`, because no match occurred and therefore there is no trailing split-produced empty
/// segment to discard. `"a,,".split(",")` is `["a"]` and `",a".split(",")` is `["", "a"]`,
/// which is why `Substring.split` cannot be used directly.
func javaSplitOnLiteral(_ text: String, separator: Character) -> [String] {
  if text.isEmpty { return [""] }
  var parts = text.split(separator: separator, omittingEmptySubsequences: false).map(String.init)
  while let last = parts.last, last.isEmpty { parts.removeLast() }
  return parts
}

// MARK: - Circuit appearance seam (M6)

/// The `com.cburch.draw.model.AbstractCanvasObject` list a circuit's custom appearance is made
/// of. The draw model is M6 work; until then a shape is an opaque object produced and consumed
/// by whatever installs the handler below.
public typealias AppearanceShape = AnyObject

/// `com.cburch.logisim.circuit.appear.AppearanceSvgReader` plus the one `CircuitAppearance`
/// call the reader makes.
///
/// Two distinct passes go through this, and their order matters: `XmlReader.loadAppearance`
/// resolves the **static** shapes (anything whose tag does not start with `visible-`) while the
/// circuits are still empty, and `XmlCircuitReader.buildDynamicAppearance` resolves the
/// **dynamic** ones (`visible-*`) after the whole circuit tree exists, because a dynamic shape
/// refers to a component inside it.
public protocol CircuitAppearanceLoading: AnyObject {
  /// `AppearanceSvgReader.getPinInfo(Location, Instance)`. D3 deleted the `Instance` facade, so
  /// the component is passed directly.
  func pinInfo(location: Location, component: any Component) -> AnyObject

  /// `AppearanceSvgReader.createShape(Element, List<PinInfo>, Circuit)`.
  ///
  /// Returns nil for an element it does not recognise, which the reader reports as
  /// `fileAppearanceNotFound`. Throws where upstream's `RuntimeException` escapes, which the
  /// reader reports as `fileAppearanceError`; the two are distinct messages and a differential
  /// run can tell them apart.
  func createShape(
    _ element: XMLElement, pins: [AnyObject]?, circuit: Circuit?
  ) throws -> AppearanceShape?

  /// `circuit.getAppearance().setObjectsForce(shapes)`.
  func setAppearance(_ shapes: [AppearanceShape], for circuit: Circuit)
}

/// Install point for the appearance reader.
///
/// **With no handler installed the reader skips `<appear>` entirely and reports nothing.** That
/// is a deliberate departure from "handler returns nil for everything", which would emit one
/// `fileAppearanceNotFound` per shape and drown the error list of any file with a custom
/// appearance; a false signal in exactly the differential gate this milestone is measured by.
/// Round-tripping the element is the writer's job (D8), not the reader's.
public enum CircuitAppearanceReader {
  public static var handler: (any CircuitAppearanceLoading)?
}

// MARK: - VHDL content seam

/// `com.cburch.logisim.vhdl.base.VhdlContent`, as much of it as the reader touches.
///
/// The VHDL subsystem sits in the parity backlog. With no handler installed, a `<vhdl>` element
/// parses to nothing and is not added to the file; matching upstream's own behaviour when
/// `VhdlContent.parse` returns null, which it does for any source it cannot parse.
public protocol VhdlContentLoading: AnyObject {
  /// `VhdlContent.parse(name, vhdl, file)`.
  func parse(name: String, source: String, file: LogisimFile) -> AnyObject?
  /// `contents.setAppearance(StdAttr.APPEARANCE.parse(...))`.
  func setAppearance(_ appearance: AttributeOption, on content: AnyObject)
  /// `file.addVhdlContent(contents)`.
  func add(_ content: AnyObject, to file: LogisimFile)
}

public enum VhdlContentReader {
  public static var handler: (any VhdlContentLoading)?
}

// MARK: - Reader message templates

/// The `.circ` reader's half of `file.properties`, in upstream's exact English.
///
/// Same rationale as `FileStrings`: localisation does not come across, and the wording matters
/// because these strings land in the message list a differential run compares verbatim.
extension FileStrings {
  public static let attrNameMissingError = "attribute name missing"

  public static func attrValueInvalidError(_ value: String, _ attributeName: String) -> String {
    "attribute value (\(value)) is not valid for \(attributeName)"
  }

  public static let circNameMissingError = "circuit name is missing"

  public static func compAbsentError(_ name: String, _ libraryName: String) -> String {
    "component \u{2018}\(name)\u{2019} missing from library \u{2018}\(libraryName)\u{2019}"
  }

  public static func compLocInvalidError(_ name: String, _ location: String) -> String {
    "location of component \u{2018}\(name)\u{2019} is invalid (\(location))"
  }

  public static func compLocMissingError(_ name: String) -> String {
    "location of component \u{2018}\(name)\u{2019} is unspecified"
  }

  public static let compNameMissingError = "component name missing"

  public static func compUnknownError(_ name: String) -> String {
    "component \u{2018}\(name)\u{2019} not found"
  }

  public static func fileAppearanceError(_ tag: String) -> String {
    "Error while loading appearance element \(tag)"
  }

  public static func fileAppearanceNotFound(_ tag: String) -> String {
    "Appearance element \(tag) not found"
  }

  public static func fileComponentOverlapError(_ first: String, _ second: String) -> String {
    "Components \(first) and \(second) exactly overlap each other. One has been moved slightly."
  }

  public static let libDescMissingError = "library descriptor missing"

  public static func libMissingError(_ name: String) -> String {
    "library \u{2018}\(name)\u{2019} not found"
  }

  public static let libNameMissingError = "library name missing"

  public static func mappingBadError(_ modifiers: String) -> String {
    "mouse mapping modifier \u{2018}\(modifiers)\u{2019} invalid"
  }

  public static let mappingMissingError = "mouse mapping modifier missing"

  public static let toolNameMissing = "Tool name not provided"

  public static let toolNameMissingError = "tool name missing"

  public static let toolNotFound = "Tool not found in library"

  public static let wireEndInvalidError = "wire end malformatted"
  public static let wireEndMissingError = "wire end not defined"
  public static let wireStartInvalidError = "wire start malformatted"
  public static let wireStartMissingError = "wire start not defined"

  /// `repairForLegacyLibrary`'s hardcoded English (upstream does not route it through the
  /// resource bundle either).
  public static let legacyLibraryRemovedMessage =
    "Some components have been deleted. The Legacy library is not supported."

  /// The pre-2.7.2 compatibility warning, likewise hardcoded upstream and marked there with a
  /// `FIXME: hardcoded string`.
  public static let oldFileFormatWarning = """
    You are opening a file created with original Logisim code.
    You might encounter some problems in the execution, since some components evolved since then.
    Moreover, labels will be converted to match VHDL limitations for variable names.
    """
}
