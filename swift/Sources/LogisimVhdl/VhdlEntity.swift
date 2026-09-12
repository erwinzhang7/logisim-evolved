// VhdlEntity: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// com/cburch/logisim/vhdl/base/VhdlEntity.java. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore licensed
// GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── What did NOT come across, and why ─────────────────────────────────────────────────────
//
// Java's `VhdlEntity extends InstanceFactory`; it is the *component factory* that turns a
// `VhdlContent` into something placeable on a canvas: it builds `Pin` instances from the
// entity's ports, derives a `VhdlAppearance` (a `CircuitAppearance`, i.e. drawable shapes),
// paints itself, tracks which circuits place it, and, this is the file's single largest
// method, implements `propagate(InstanceState)` by speaking a line protocol to an external
// QuestaSim/ModelSim `vcom`/`vsim` process over a TCL socket bridge.
//
// None of that is "the entity model" this task ports:
//
//   * `configureNewInstance`, `createAttributeSet`, `getOffsetBounds`,
//     `instanceAttributeChanged`, `updatePorts`, `getPins` all depend on `Instance`/
//     `InstanceFactory`/`Pin`/`Port` from `LogisimStd`, another workflow's module.
//   * `paintInstance` depends on `VhdlAppearance` (a `CircuitAppearance`/`CanvasObject`
//     drawing tree); explicitly out of scope ("NO DRAWING CODE"; a separate workflow owns
//     `RenderScene`).
//   * `propagate` and `saveFile` are the QuestaSim/ModelSim bridge itself: `vhdl/sim`,
//     explicitly skipped per this task's instructions and D11 (no macOS story for
//     QuestaSim/ModelSim).
//   * `getCircuitsUsingThis`/`addCircuitUsing`/`removeCircuitUsing` key a
//     `WeakHashMap<Component, Circuit>`; `Component`/`Circuit` are `LogisimFile` types.
//     This is pure bookkeeping glue with no logic of its own; wiring it up is a couple of
//     lines once `LogisimFile` is a dependency this module is allowed to take, not a design
//     decision that belongs here.
//
// What remains, and what this file actually ports, is the handful of pure functions that
// derive a placed entity's HDL identifiers from its content and its attribute set, none of
// which touch drawing, simulation, or another module's types.

import LogisimKernel

/// `com.cburch.logisim.vhdl.base.VhdlEntity`, reduced to its HDL-name derivation (see the
/// file header for what was deliberately left out and why). A namespace of pure functions
/// rather than a type, since nothing here needs to be instantiated or subclassed.
public enum VhdlEntity {
  /// `VhdlEntity.getHDLName(AttributeSet)`. Java ignores its `attrs` parameter entirely here
  /// (the entity name comes from `content`, not the instance); reproduced with the same
  /// signature shape by taking `content` directly instead.
  public static func hdlName(for content: VhdlContent) -> String {
    content.name.lowercased()
  }

  /// `VhdlEntity.getHDLTopName(AttributeSet)`: the per-instance HDL name, disambiguated by
  /// the component's label when it has one.
  public static func hdlTopName(using attributes: VhdlEntityAttributes) -> String {
    let label = attributes.getValue(VhdlEntityAttributes.labelAttribute) ?? ""
    let suffix = label.isEmpty ? "" : "_" + label.lowercased()
    return hdlName(for: attributes.vhdlContent) + suffix
  }

  /// `VhdlEntity.setSimName(AttributeSet, String)`. Returns whether the attribute set even
  /// carries the (hidden) sim-name attribute, matching Java's `containsAttribute` guard.
  /// Simulation-name bookkeeping for the QuestaSim/ModelSim bridge (`vhdl/sim`, skipped) is
  /// the only consumer of this value; it is otherwise inert data.
  @discardableResult
  public static func setSimName(_ attributes: VhdlEntityAttributes, to simulationName: String) -> Bool {
    guard attributes.containsAttribute(VhdlEntityAttributes.simNameAttribute) else { return false }
    let label = attributes.getValue(VhdlEntityAttributes.labelAttribute) ?? ""
    let resolved = label.isEmpty ? simulationName : hdlTopName(using: attributes)
    try? attributes.setValue(VhdlEntityAttributes.simNameAttribute, resolved)
    return true
  }

  /// `VhdlEntity.getSimName(AttributeSet)`.
  public static func simName(_ attributes: VhdlEntityAttributes) -> String? {
    attributes.getValue(VhdlEntityAttributes.simNameAttribute)
  }

  /// `VhdlEntity.getName()`; the factory name a `.circ` `<comp name="…">` carries, and what
  /// `getDisplayGetter()` shows in the explorer.
  ///
  /// Java branches on `content == null`, which its own constructor makes impossible
  /// (`this.content = content` is followed immediately by `content.addHdlModelListener(this)`,
  /// so a null content would have already thrown). The fallback string is nonetheless the
  /// literal `"VHDL Entity"` for `getName()` and `S.getter("vhdlComponent")` for the display
  /// name, whose English is also `"VHDL Entity"`, so the two agree and the parameter can be
  /// optional here without introducing a second spelling.
  public static func name(for content: VhdlContent?) -> String {
    content?.name ?? "VHDL Entity"
  }

  /// `VhdlEntity.saveFile(AttributeSet)`'s text transform: the entity source with its own name
  /// rewritten to the per-run simulation name, ready to be written to
  /// `SIM_SRC_PATH + simName + ".vhdl"`.
  ///
  /// The write itself is NOT-PORTED (D11; the QuestaSim/ModelSim bridge; see
  /// `VhdlNotPorted.swift`). What is ported is the substitution, and it is worth being precise
  /// about because it is not a rename of the entity declaration; it is
  /// `content.replaceAll("(?i)" + getHDLName(attrs), getSimName(attrs))`, i.e. a
  /// case-insensitive replacement of the **lower-cased entity name wherever it appears**, with
  /// no word boundary. An entity `foo` with a signal `food` therefore yields
  /// `LogisimVhdlSimComp_0d`, and a comment mentioning "Foo" is rewritten too. That is
  /// upstream's behaviour and is reproduced rather than corrected; correcting it would change
  /// the bytes handed to an external compiler.
  ///
  /// Two Java-regex details go with it. The pattern is the entity name spliced in *unescaped*,
  /// which is safe only because `VhdlContent` rejects any name outside `[A-Za-z]\w*`; and the
  /// replacement is a `replaceAll` replacement string, where `$` and `\` are metacharacters.
  /// A simulation name derived from a component label could in principle contain them (labels
  /// are not restricted to `\w`), so the replacement is applied literally here; Java would
  /// throw `IllegalArgumentException` on a stray `$`, which is a crash, not a behaviour.
  public static func simulationSource(content: VhdlContent, simulationName: String) -> String {
    let hdlName = hdlName(for: content)
    guard !hdlName.isEmpty else { return content.content }
    return content.content.replacingOccurrences(
      of: hdlName, with: simulationName, options: [.caseInsensitive])
  }
}

// MARK: - NOT-PORTED, recorded rather than silently dropped
//
// `VhdlEntity.WIDTH`/`HEIGHT`/`PORT_GAP`/`X_PADDING` (140/40/10/5) are declared `static final`
// in 4.1.0 and referenced by nothing: not by `paintInstance`, not by `getOffsetBounds`, not
// from outside the class. They are leftovers from the pre-`VhdlAppearance` drawing code. Not
// carried across: a constant with no reader is not a behaviour, and reintroducing them would
// invite someone to lay a component out with them.
//
// `VhdlEntity.icon` (`ArithmeticIcon("VHDL")`) and `contentSet(HdlModel)`, whose entire body is
// `icon.setInvalid(!content.isValid())`, are D9; an icon is a UI concern and this module has
// no drawing story. The *fact* the icon reports is `VhdlContent.isValid`, which is already
// public, so nothing is lost for whoever draws it.
