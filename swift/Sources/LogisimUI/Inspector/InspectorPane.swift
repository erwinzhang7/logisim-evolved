// LogisimUI: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// ============================================================================
// THE INSPECTOR.
//
// Upstream's attribute editor is a `JTable` with two columns, wedged into the bottom of
// the left region behind an unlabelled tab, and every value is edited through an
// `AttributeTable.CellEditor` that returns a `Component` chosen by `getCellEditor` on the
// `Attribute` subclass. That design has three visible consequences:
//
//   - Everything looks like a text field, because most attributes fall through to the
//     default editor. A Direction is typed, not picked. A font is typed. A colour is typed
//     unless the attribute happens to be one of the handful with a custom editor.
//   - A bad value is swallowed. `AttrTable`'s listener catches the exception and reverts
//     the cell with no explanation, so "width 999" simply does nothing, twice, before the
//     user gives up.
//   - Attributes an unresolvable library defined are absent entirely, because upstream has
//     already dropped the component (D8).
//
// Here the projection is a closed `InspectorValue` enum, so every kind gets a real native
// control and adding a kind is a compile error rather than a blank row. Rejected values
// surface as an inline message (D13's rule, carried into the UI), and D5 `.opaque` values
// are shown read-only with a note that they round-trip.
// ============================================================================

import AppKit
import SwiftUI

struct InspectorPane: View {
  @Bindable var model: EditorModel

  var body: some View {
    Group {
      if model.inspectorForm.isEmpty && model.selection.isEmpty {
        ContentUnavailableView {
          Label("Nothing Selected", systemImage: "cursorarrow.rays")
        } description: {
          Text("Select a circuit, a component, or a tool in the sidebar.")
        }
      } else {
        form
      }
    }
    .frame(minWidth: 260, idealWidth: 300)
  }

  private var form: some View {
    Form {
      header

      if let notice = model.inspectorForm.notice {
        Section {
          Label {
            Text(notice).font(.callout)
          } icon: {
            Image(systemName: "lock.doc").foregroundStyle(.orange)
          }
        }
      }

      if let error = model.transientError {
        Section {
          Label {
            Text(error).font(.callout).foregroundStyle(.red)
          } icon: {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
          }
        }
      }

      ForEach(model.inspectorForm.sections) { section in
        InspectorSectionView(section: section, model: model)
      }
    }
    .formStyle(.grouped)
  }

  private var header: some View {
    Section {
      HStack(spacing: 10) {
        Image(systemName: model.inspectorForm.symbolName)
          .font(.title2)
          .foregroundStyle(.tint)
          .frame(width: 28)
        VStack(alignment: .leading, spacing: 1) {
          Text(model.inspectorForm.title).font(.headline)
          if let subtitle = model.inspectorForm.subtitle {
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
          }
        }
        Spacer(minLength: 0)
      }
      .padding(.vertical, 2)
    }
  }
}

private struct InspectorSectionView: View {
  var section: InspectorSection
  var model: EditorModel
  @State private var isExpanded: Bool?

  var body: some View {
    Section(isExpanded: expansion) {
      ForEach(section.rows) { row in
        InspectorRowView(row: row, model: model)
      }
    } header: {
      Text(section.title)
    }
  }

  private var expansion: Binding<Bool> {
    Binding(
      get: { isExpanded ?? section.isInitiallyExpanded },
      set: { isExpanded = $0 })
  }
}

struct InspectorRowView: View {
  var row: InspectorRow
  var model: EditorModel

  var body: some View {
    LabeledContent {
      editor
        .disabled(!row.isEditable)
    } label: {
      HStack(spacing: 4) {
        Text(row.displayName)
        if let help = row.help {
          Image(systemName: "questionmark.circle")
            .foregroundStyle(.tertiary)
            .help(help)
        }
      }
    }
  }

  private func commit(_ value: InspectorValue) {
    model.apply(AttributeEdit(target: model.selection, key: row.key, newValue: value))
  }

  @ViewBuilder private var editor: some View {
    switch row.value {
    case .text(let string):
      CommittingTextField(text: string) { commit(.text($0)) }

    case .multilineText(let string):
      CommittingTextField(text: string, axis: .vertical) { commit(.multilineText($0)) }

    case .integer(let value):
      // An UNBOUNDED integer row keeps its value in `Int` the whole way. It used to go
      // `Int -> Double -> Int`, which is lossy above 2^53 and TRAPS at both ends; see
      // `InspectorIntegerText` for what that cost. `.boundedInteger` below still uses the
      // `Double` field legitimately: its range rejects a non-finite draft before any conversion,
      // and its bounds (bit widths, radices) are far below the lossy threshold.
      IntegerField(value: value) { commit(.integer($0)) }

    case .boundedInteger(let value, let range):
      // A real Stepper with real bounds, so the width that upstream would silently reject
      // (D13: `BitWidth.create` throws on `<a name="width" val="999"/>`) cannot be typed
      // in the first place.
      HStack(spacing: 6) {
        NumberField(
          value: Double(value),
          range: Double(range.lowerBound)...Double(range.upperBound)
        ) { commit(.integer(Int($0.rounded()))) }
        Stepper(
          "",
          value: Binding(
            get: { value },
            set: { commit(.integer($0)) }),
          in: range)
          .labelsHidden()
      }

    case .double(let value):
      NumberField(value: value, range: nil) { commit(.double($0)) }

    case .boolean(let flag):
      Toggle(
        "",
        isOn: Binding(get: { flag }, set: { commit(.boolean($0)) })
      )
      .labelsHidden()
      .toggleStyle(.switch)

    case .choice(let selected, let options):
      Picker(
        "",
        selection: Binding(
          get: { selected },
          set: { commit(.choice(selected: $0, options: options)) })
      ) {
        ForEach(options) { option in
          if let symbol = option.symbolName {
            Label(option.displayName, systemImage: symbol).tag(option.rawValue)
          } else {
            Text(option.displayName).tag(option.rawValue)
          }
        }
      }
      .labelsHidden()

    case .colour(let rgba):
      ColorPicker(
        "",
        selection: Binding(
          get: { rgba.color },
          set: { commit(.colour(RGBA(colour: $0))) }),
        supportsOpacity: true
      )
      .labelsHidden()

    case .font(let name, let size, let isBold, let isItalic):
      FontEditor(name: name, size: size, isBold: isBold, isItalic: isItalic) {
        commit(.font(name: $0, size: $1, isBold: $2, isItalic: $3))
      }

    case .direction(let direction):
      Picker(
        "",
        selection: Binding(
          get: { direction },
          set: { commit(.direction($0)) })
      ) {
        ForEach(CardinalDirection.allCases, id: \.self) { value in
          Image(systemName: value.symbolName).tag(value)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()

    case .opaque(let raw):
      // D5 `.opaque` / D8 unknown attribute. Read-only and *visible*: the user must be able
      // to see that the value exists and will survive the next save.
      HStack(spacing: 4) {
        Text(raw)
          .font(.system(.caption, design: .monospaced))
          .textSelection(.enabled)
          .lineLimit(2)
        Spacer(minLength: 0)
        Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.tertiary)
      }

    case .mixed:
      // Upstream renders a multi-selection's differing values as an empty cell, which is
      // indistinguishable from "empty string" and silently overwrites everything if you
      // tab through it.
      Menu("Multiple Values") {
        Text("Values differ across the selection.")
      }
      .menuStyle(.borderlessButton)
      .foregroundStyle(.secondary)
    }
  }
}

// MARK: - Small editors

/// A text field that commits on Return and on focus loss, and never on every keystroke.
/// Committing per-keystroke would push one undo entry per character into the model.
private struct CommittingTextField: View {
  @State private var draft: String
  private let original: String
  private let axis: Axis
  private let onCommit: (String) -> Void
  @FocusState private var isFocused: Bool

  init(text: String, axis: Axis = .horizontal, onCommit: @escaping (String) -> Void) {
    self.original = text
    self.axis = axis
    self.onCommit = onCommit
    _draft = State(initialValue: text)
  }

  var body: some View {
    TextField("", text: $draft, axis: axis)
      .textFieldStyle(.roundedBorder)
      .labelsHidden()
      .focused($isFocused)
      .onSubmit { if draft != original { onCommit(draft) } }
      .onChange(of: isFocused) { _, focused in
        if !focused, draft != original { onCommit(draft) }
      }
      .onChange(of: original) { _, newValue in
        if !isFocused { draft = newValue }
      }
  }
}

/// Display and parsing for an unbounded integer attribute, as pure functions.
///
/// **Extracted from `NumberField` because that is a `private struct` and none of this could be
/// tested inside it**, which is exactly why the defect below survived: the only way to exercise
/// the formatter was to construct a SwiftUI view, so nobody did.
///
/// The bug it replaces: `Int` attributes were rendered by converting to `Double` and back.
///
///   * `String(Int(value))` on `Double(Int.max)`: the `Double` rounds UP to 2^63, one past
///     `Int.max`, and `Int(_:)` is a partial function in Swift. It trapped while the field was
///     being constructed, before validation, so nothing could catch or report it. Selecting an
///     ordinary 64-bit Constant ended the process.
///   * `Int(draft.rounded())` on commit: `Double("NaN")` parses, no finite check existed, and the
///     conversion trapped.
///   * `Double` cannot represent odd integers above 2^53, so `9007199254740993` displayed as
///     `…992` and the edit callback passed that wrong value onward. Silent, and worse than the
///     crash for being silent.
///
/// 4.1.0 does none of these: `Constant.ATTR_VALUE` is `Attributes.forHexLong`, the jar displays
/// both values exactly, and a `NaN` draft is refused with a catchable `NumberFormatException`.
enum InspectorIntegerText {

  /// No `Double` anywhere. `String(Int)` is total for every `Int`.
  static func display(_ value: Int) -> String { String(value) }

  /// `nil` means "refuse the draft and mark the field invalid": the port's equivalent of
  /// upstream throwing `NumberFormatException`, which is caught and shown rather than fatal.
  ///
  /// Parsed as an `Int` directly rather than via `Double`, so a value that no `Int` can hold is
  /// refused instead of being silently rounded into range. A decimal draft is still accepted and
  /// rounded, because the field previously accepted one and a user typing `3.7` into an integer
  /// row means 4 rather than an error.
  static func parse(_ text: String) -> Int? {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    if let exact = Int(trimmed) { return exact }
    // `isFinite` is REDUNDANT and is kept deliberately: a red probe proved it. Removing it
    // reddens nothing, because the range comparison below already rejects NaN: every comparison
    // against NaN is false, so `rounded >= …` fails and the guard returns nil. That is defence in
    // depth rather than a live check, and it is written down so the next reader does not "simplify"
    // it away believing the range guard is about magnitude alone. If the range guard is ever
    // restructured, say into a `min/max` clamp, which does NOT reject NaN, this line becomes the
    // only thing standing between a typed `NaN` and a trapping conversion.
    guard let approximate = Double(trimmed), approximate.isFinite else { return nil }
    let rounded = approximate.rounded()
    // The bounds are the largest and smallest `Double` that convert to `Int` without trapping.
    // `Double(Int.max)` itself rounds UP past `Int.max`, so comparing against it would let the
    // exact value that caused this whole defect straight through.
    guard rounded >= -9.223_372_036_854_775_5e18, rounded <= 9.223_372_036_854_775_5e18 else {
      return nil
    }
    return Int(rounded)
  }
}

/// The unbounded-integer editor. Mirrors `NumberField`'s behaviour and chrome exactly; the only
/// difference is that its value never becomes a `Double`.
private struct IntegerField: View {
  @State private var draft: String
  private let original: Int
  private let onCommit: (Int) -> Void
  @FocusState private var isFocused: Bool
  @State private var isInvalid = false

  init(value: Int, onCommit: @escaping (Int) -> Void) {
    self.original = value
    self.onCommit = onCommit
    _draft = State(initialValue: InspectorIntegerText.display(value))
  }

  var body: some View {
    TextField("", text: $draft)
      .textFieldStyle(.roundedBorder)
      .labelsHidden()
      .monospacedDigit()
      .multilineTextAlignment(.trailing)
      .frame(minWidth: 54)
      .focused($isFocused)
      .foregroundStyle(isInvalid ? Color.red : Color.primary)
      .onSubmit(commit)
      .onChange(of: isFocused) { _, focused in if !focused { commit() } }
      .onChange(of: original) { _, newValue in
        if !isFocused {
          draft = InspectorIntegerText.display(newValue)
          isInvalid = false
        }
      }
  }

  private func commit() {
    guard let parsed = InspectorIntegerText.parse(draft) else {
      isInvalid = true
      return
    }
    isInvalid = false
    if parsed != original { onCommit(parsed) }
  }
}

private struct NumberField: View {
  @State private var draft: String
  private let original: Double
  private let range: ClosedRange<Double>?
  private let onCommit: (Double) -> Void
  @FocusState private var isFocused: Bool
  @State private var isInvalid = false

  init(value: Double, range: ClosedRange<Double>?, onCommit: @escaping (Double) -> Void) {
    self.original = value
    self.range = range
    self.onCommit = onCommit
    _draft = State(initialValue: Self.format(value))
  }

  private static func format(_ value: Double) -> String {
    value == value.rounded() ? String(Int(value)) : String(value)
  }

  var body: some View {
    TextField("", text: $draft)
      .textFieldStyle(.roundedBorder)
      .labelsHidden()
      .monospacedDigit()
      .multilineTextAlignment(.trailing)
      .frame(minWidth: 54)
      .focused($isFocused)
      .foregroundStyle(isInvalid ? Color.red : Color.primary)
      .onSubmit(commit)
      .onChange(of: isFocused) { _, focused in if !focused { commit() } }
      .onChange(of: original) { _, newValue in
        if !isFocused {
          draft = Self.format(newValue)
          isInvalid = false
        }
      }
  }

  private func commit() {
    guard let parsed = Double(draft.trimmingCharacters(in: .whitespaces)) else {
      isInvalid = true
      return
    }
    if let range, !range.contains(parsed) {
      isInvalid = true
      return
    }
    isInvalid = false
    if parsed != original { onCommit(parsed) }
  }
}

/// A real font control. Upstream types a font as text into a `JTable` cell.
private struct FontEditor: View {
  var name: String
  var size: Double
  var isBold: Bool
  var isItalic: Bool
  var onCommit: (String, Double, Bool, Bool) -> Void

  @MainActor private static let families: [String] = {
    var names = ["SF Pro", "Helvetica Neue", "Menlo", "SF Mono", "Times New Roman"]
    let installed = NSFontManager.shared.availableFontFamilies
    names.append(contentsOf: installed.filter { !names.contains($0) }.prefix(40))
    return names
  }()

  var body: some View {
    HStack(spacing: 6) {
      Picker(
        "",
        selection: Binding(
          get: { name },
          set: { onCommit($0, size, isBold, isItalic) })
      ) {
        ForEach(Self.families, id: \.self) { family in
          Text(family).tag(family)
        }
      }
      .labelsHidden()
      .frame(minWidth: 90)

      Stepper(
        "",
        value: Binding(
          get: { size },
          set: { onCommit(name, $0, isBold, isItalic) }),
        in: 6...96, step: 1)
        .labelsHidden()

      Toggle(
        isOn: Binding(get: { isBold }, set: { onCommit(name, size, $0, isItalic) })
      ) {
        Image(systemName: "bold")
      }
      .toggleStyle(.button)

      Toggle(
        isOn: Binding(get: { isItalic }, set: { onCommit(name, size, isBold, $0) })
      ) {
        Image(systemName: "italic")
      }
      .toggleStyle(.button)
    }
  }
}

extension RGBA {
  /// SwiftUI `Color` → `RGBA`. Forced through sRGB so the canvas and the picker agree; a
  /// display-P3 colour silently reinterpreted as sRGB is a subtle, permanent shift.
  init(colour: Color) {
    let ns = NSColor(colour).usingColorSpace(.sRGB) ?? .black
    self.init(
      Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent),
      Double(ns.alphaComponent))
  }
}
