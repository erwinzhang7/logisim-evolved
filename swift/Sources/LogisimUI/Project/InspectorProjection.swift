// InspectorProjection.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.gui.generic.AttrTableModel and its four
// subclasses: AttrTableCircuitModel, AttrTableComponentModel, AttrTableSelectionModel,
// AttrTableToolModel), https://github.com/logisim-evolution/logisim-evolution. Copyright by the
// Logisim-evolution developers. This translation is a derivative work and is therefore
// GPL-3.0-only. See LICENSE.md.
// SPDX-License-Identifier: GPL-3.0-only
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── What this file is ───────────────────────────────────────────────────────────────────────
//
// The two directions between a real `AttributeSet` (D5) and the inspector's closed
// `InspectorValue` enum:
//
//   read , `rows(of:)`      : AttributeSet -> [InspectorRow]
//   write, `encode(_:for:)` : InspectorValue -> AttributeValue, or a throw
//
// It replaces `DemoProjectHost.inspectorForm`, which returned a fixed table of literals with an
// override dictionary behind it, so a "width" row existed on a wire and editing it changed
// nothing in any model.
//
// ── The write direction is where D13 lives ──────────────────────────────────────────────────
//
// `AttributeSet.setValue` throws and the subscript is read-only, deliberately: swallowing a
// rejected value is precisely the failure D13 exists to prevent, and upstream's `AttrTable`
// listener does swallow it: it catches the exception and reverts the cell with no explanation,
// which is why typing width 999 in 4.1.0 silently does nothing, twice, before you give up.
//
// So `encode` **never** guesses and never coerces. It builds a candidate `AttributeValue`,
// asks the attribute itself whether it accepts it (`AnyAttribute.accepts`), and where it cannot
// build one structurally it falls back to the attribute's own `.circ` parser
// (`parseToAttributeValue`); the same parser the loader uses, so anything the inspector
// accepts is by construction something the file format can round-trip. Whatever the attribute
// rejects comes back as a thrown `ProjectHostError.invalidValue` carrying the parser's own
// message, and the pane shows it.
//
// ── One honest gap: option lists ────────────────────────────────────────────────────────────
//
// An `Attributes.forOption` attribute knows its legal values, the closure captured in its
// codec compares against them, but `AnyAttribute` exposes no way to *enumerate* them, and
// `AttributeCodec` has no `choices` field. So an option-valued attribute is projected as
// editable **text**, not as a popup menu.
//
// That is deliberate, and the alternative was considered and rejected: a hard-coded table of
// "the options I think `gates/size` has" in the UI layer would be exactly the fabricated
// content this whole task exists to remove, and it would go stale silently the first time a
// component's option list changed. Text is worse-looking and correct; the attribute's own
// parser throws `"value not among choices"` for a bad entry and the inspector shows that
// sentence.
//
// The fix belongs in the kernel, not here: give `AnyAttribute` an
// `open var standardStringChoices: [String]? { nil }` that `Attributes.forOption` overrides
// with the names it already has in hand. That is a five-line change to a file this slice does
// not own; it is recorded here and in the task report rather than worked around.
//
// `.direction` *is* a popup, because `AttributeValue.Direction` is `CaseIterable` and the four
// cases are the whole legal set, enumerating it invents nothing.

import Foundation
import LogisimFile
import LogisimKernel

@MainActor
enum InspectorProjection {

  // MARK: - Read: AttributeSet -> rows

  /// Every visible attribute of `set`, in the set's own order.
  ///
  /// Hidden attributes are skipped, which is `AttrTableModel`'s behaviour: `Attribute.isHidden`
  /// exists precisely so a component can flip an attribute out of the table (gates do this as
  /// their input count changes). Read-only attributes are *shown*, disabled; upstream shows
  /// them too, and hiding them would make a component look like it had fewer settings than it
  /// does.
  static func rows(of set: any AttributeSet) -> [InspectorRow] {
    set.attributes.compactMap { attribute in
      guard !attribute.isHidden else { return nil }
      return row(attribute, in: set)
    }
  }

  static func row(_ attribute: AnyAttribute, in set: any AttributeSet) -> InspectorRow {
    let stored = set.rawValue(attribute)
    let readOnly = set.isReadOnly(attribute)
    return InspectorRow(
      key: AttributeKey(attribute.name),
      displayName: displayName(for: attribute.name),
      value: inspectorValue(for: stored, attribute: attribute),
      isEditable: !readOnly && isEditable(stored),
      help: help(for: attribute, stored: stored))
  }

  /// Rows shared by a multi-selection, with differing values collapsed to `.mixed`.
  ///
  /// `SelectionAttributes` computes the same intersection upstream. Note the intersection is by
  /// attribute **name**, not by `AnyAttribute` identity: two components of the same kind share
  /// the identical `Attribute` object, but a Pin and a Probe both have a `label` attribute that
  /// is a different object, and a user selecting both expects one Label row.
  static func commonRows(of sets: [any AttributeSet]) -> [InspectorRow] {
    guard let first = sets.first else { return [] }
    var result: [InspectorRow] = []
    for attribute in first.attributes where !attribute.isHidden {
      // Every other set must define an attribute of the same name.
      var peers: [(any AttributeSet, AnyAttribute)] = [(first, attribute)]
      var shared = true
      for other in sets.dropFirst() {
        guard let match = other.attribute(named: attribute.name) else {
          shared = false
          break
        }
        peers.append((other, match))
      }
      guard shared else { continue }

      var row = self.row(attribute, in: first)
      let values = peers.map { $0.0.rawValue($0.1) }
      if values.dropFirst().contains(where: { $0 != values.first }) {
        row.value = .mixed
      }
      row.isEditable = peers.allSatisfy { !$0.0.isReadOnly($0.1) } && isEditable(values.first ?? nil)
      result.append(row)
    }
    return result
  }

  /// D5 `.opaque` and the live-object attributes are shown but never editable: the first is a
  /// value we deliberately do not understand and round-trip verbatim (D8), the second is a
  /// runtime object with no text form at all.
  private static func isEditable(_ stored: AttributeValue?) -> Bool {
    switch stored {
    case .opaque, .object: return false
    default: return true
    }
  }

  static func inspectorValue(
    for stored: AttributeValue?, attribute: AnyAttribute
  ) -> InspectorValue {
    guard let stored else { return .text("") }
    switch stored {
    case .boolean(let flag):
      return .boolean(flag)

    case .integer(let value):
      return .integer(Int(value))

    case .long(let value):
      return .integer(Int(value))

    case .double(let value):
      return .double(value)

    case .string(let text):
      return text.contains("\n") ? .multilineText(text) : .text(text)

    case .bitWidth(let width):
      // The one range the port knows without asking the attribute, and the one D13 names by
      // example: `<a name="width" val="999"/>` throws from `BitWidth.create`. A stepper bounded
      // at the real limit means the rejected value cannot usually be typed, and when it is
      // (a pasted number), `BitWidth`'s own error is what the pane shows.
      return .boundedInteger(Int(width), range: 1...BitWidth.maxWidth)

    case .direction(let direction):
      return .direction(CardinalDirection(direction))

    case .location(let x, let y):
      return .text("(\(x),\(y))")

    case .font(let spec):
      return .font(
        name: spec.family,
        size: Double(spec.size),
        isBold: spec.style.contains(.bold),
        isItalic: spec.style.contains(.italic))

    case .color(let spec):
      return .colour(
        RGBA(
          Double(spec.red) / 255, Double(spec.green) / 255, Double(spec.blue) / 255,
          Double(spec.alpha) / 255))

    case .option(let option):
      // See the file header: no enumerable option list exists on `AnyAttribute`, so this is
      // text validated by the attribute's own parser rather than a fabricated popup.
      return .text(option.name)

    case .object:
      return .opaque("(live object — never saved)")

    case .opaque(let raw):
      return .opaque(raw)
    }
  }

  // MARK: - Write: InspectorValue -> AttributeValue

  /// The candidate storage value for an edit, or a throw carrying why it was refused.
  ///
  /// - Parameter stored: what the attribute currently holds. Used only to pick which numeric
  ///   case to build (`.integer` vs `.long` vs `.bitWidth`), since the inspector's `.integer`
  ///   is one case and D5's storage has three.
  static func encode(
    _ value: InspectorValue, for attribute: AnyAttribute, stored: AttributeValue?
  ) throws -> AttributeValue {
    let key = AttributeKey(attribute.name)

    // Candidates built structurally, in preference order. Anything the attribute accepts is
    // used as-is; otherwise the text form goes through the attribute's own `.circ` parser,
    // which is the single source of truth for what it will take.
    var candidates: [AttributeValue] = []
    var text: String?

    switch value {
    case .text(let string), .multilineText(let string):
      candidates.append(.string(string))
      text = string

    case .integer(let number), .boundedInteger(let number, _):
      switch stored {
      case .bitWidth: candidates.append(.bitWidth(Int32(clamping: number)))
      case .long: candidates.append(.long(Int64(number)))
      default:
        candidates.append(.integer(Int32(clamping: number)))
        candidates.append(.long(Int64(number)))
        candidates.append(.bitWidth(Int32(clamping: number)))
      }
      text = String(number)

    case .double(let number):
      candidates.append(.double(number))
      text = String(number)

    case .boolean(let flag):
      candidates.append(.boolean(flag))
      text = flag ? "true" : "false"

    case .choice(let selected, _):
      candidates.append(.option(AttributeOption(name: selected)))
      text = selected

    case .direction(let direction):
      candidates.append(.direction(direction.attributeDirection))
      text = direction.rawValue

    case .colour(let rgba):
      let spec = ColorSpec(
        red: channel(rgba.red), green: channel(rgba.green), blue: channel(rgba.blue),
        alpha: channel(rgba.alpha))
      candidates.append(.color(spec))
      text = spec.standardString

    case .font(let name, let size, let isBold, let isItalic):
      var style: FontStyle = .plain
      if isBold { style.insert(.bold) }
      if isItalic { style.insert(.italic) }
      let spec = FontSpec(family: name, style: style, size: Int32(size.rounded()))
      candidates.append(.font(spec))
      text = spec.standardString

    case .opaque:
      // D8: an attribute we do not understand round-trips byte-for-byte. Letting the user
      // retype it would be the one way to lose it.
      throw ProjectHostError.readOnly(key)

    case .mixed:
      throw ProjectHostError.invalidValue(
        key, "‘Multiple Values’ is not a value; pick a concrete one")
    }

    for candidate in candidates where attribute.accepts(candidate) {
      return candidate
    }

    if let text {
      do {
        return try attribute.parseToAttributeValue(text)
      } catch {
        throw ProjectHostError.invalidValue(key, message(from: error))
      }
    }
    throw ProjectHostError.invalidValue(key, "this attribute does not accept that kind of value")
  }

  private static func channel(_ value: Double) -> UInt8 {
    UInt8(max(0, min(255, (value * 255).rounded())))
  }

  /// The parser's own sentence, without a Swift type name wrapped round it.
  ///
  /// `AttributeParseError`, `BitWidthParseError` and `AttributeSetError` are all
  /// `CustomStringConvertible` and their descriptions *are* the message. The one piece of
  /// cleanup is `AttributeParseError.numberFormat`, whose description carries the Java
  /// exception class name as a prefix: right for a log line, wrong for a text field.
  static func message(from error: any Error) -> String {
    switch error {
    case AttributeParseError.numberFormat(let detail):
      return detail
    case let parse as AttributeParseError:
      return parse.description
    case let width as BitWidthParseError:
      return width.description
    case let set as AttributeSetError:
      return set.description
    case let localized as LocalizedError:
      return localized.errorDescription ?? String(describing: error)
    default:
      return String(describing: error)
    }
  }

  // MARK: - Presentation

  /// D5 leaves display names to the UI layer. Only the handful that read badly as raw `.circ`
  /// tokens are renamed; everything else shows its own name, which is what the file contains
  /// and what the documentation calls it.
  private static let displayNames: [String: String] = [
    "width": "Data Bits",
    "facing": "Facing",
    "label": "Label",
    "labelfont": "Label Font",
    "labelcolor": "Label Colour",
    "labelloc": "Label Position",
    "labelvisible": "Label Visible",
    "circuit": "Name",
    "clabel": "Shared Label",
    "clabelfont": "Shared Label Font",
    "clabelup": "Label Position",
    "circuitnamedbox": "Show Name in Box",
    "circuitnamedboxfixedsize": "Fixed-Size Box",
    "circuitvhdlpath": "VHDL Path",
    "simulationFrequency": "Simulation Frequency",
    "appearance": "Appearance",
    "inputs": "Number of Inputs",
    "size": "Gate Size",
    "negate0": "Negate Input 1",
    "negate1": "Negate Input 2",
    "radix": "Radix",
    "tristate": "Three-state",
    "pull": "Pull Behaviour",
    "trigger": "Trigger",
    "selloc": "Select Location",
  ]

  static func displayName(for attributeName: String) -> String {
    displayNames[attributeName] ?? attributeName
  }

  private static func help(for attribute: AnyAttribute, stored: AttributeValue?) -> String? {
    if case .opaque = stored {
      return "Not recognised by this build. Written back byte-for-byte on save (D8)."
    }
    if case .option = stored {
      return "This attribute has a fixed set of legal values. An entry that is not one of them "
        + "is rejected with the reason, rather than silently ignored."
    }
    if case .bitWidth = stored {
      return "1…\(BitWidth.maxWidth). A width outside that range is reported, never a crash (D13)."
    }
    if !attribute.isToSave {
      return "Runtime-only; never written to the file."
    }
    return nil
  }
}

// MARK: - Direction bridging

extension CardinalDirection {
  init(_ direction: AttributeValue.Direction) {
    switch direction {
    case .east: self = .east
    case .west: self = .west
    case .north: self = .north
    case .south: self = .south
    }
  }

  var attributeDirection: AttributeValue.Direction {
    switch self {
    case .east: return .east
    case .west: return .west
    case .north: return .north
    case .south: return .south
    }
  }
}
