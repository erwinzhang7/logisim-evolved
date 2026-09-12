// logisim-evolved: a native Swift/macOS port of logisim-evolution.
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution),
// which is GPL-3.0-only. This port is a derivative work and is therefore GPL-3.0-only.
// SPDX-License-Identifier: GPL-3.0-only
//
// Port of com.cburch.logisim.file.Options.

import Foundation
import LogisimKernel

/// `com.cburch.logisim.file.Options`: the `<options>` element of a `.circ`, plus the toolbar
/// and mouse-mapping tables that live beside it.
public final class Options {
  /// `Options.GATE_UNDEFINED_IGNORE`.
  public static let gateUndefinedIgnore = AttributeOption(name: "ignore")
  /// `Options.GATE_UNDEFINED_ERROR`.
  public static let gateUndefinedError = AttributeOption(name: "error")

  /// `Options.ATTR_SIM_LIMIT`; the oscillation iteration cap. D7/M3 read this.
  public static let simulationLimit: Attribute<Int32> = Attributes.forInteger("simlimit")

  /// `Options.ATTR_SIM_RAND`, the oscillation random shift.
  public static let simulationRandomness: Attribute<Int32> = Attributes.forInteger("simrand")

  /// `Options.ATTR_GATE_UNDEFINED`.
  public static let gateUndefined: Attribute<AttributeOption> = Attributes.forOption(
    "gateUndefined", choices: [gateUndefinedIgnore, gateUndefinedError])

  /// `Options.SIM_RAND_DFLT`. Note this is *not* the default value of `simrand`, which is 0;
  /// it is the value the preferences dialog installs when randomness is switched on.
  public static let simulationRandomnessDefault: Int32 = 32

  /// Declaration order is upstream's `ATTRIBUTES` array and is observable: it fixes the order
  /// `<a>` elements are written in inside `<options>`.
  public static let attributes: [AnyAttribute] = [gateUndefined, simulationLimit, simulationRandomness]

  private let attrs: any AttributeSet
  private let mouseMappingsStorage = MouseMappings()
  private let toolbarStorage = ToolbarData()

  public init() {
    attrs = AttributeSets.fixedSet([
      Options.gateUndefined.binding(Options.gateUndefinedIgnore),
      Options.simulationLimit.binding(1000),
      Options.simulationRandomness.binding(0),
    ])
  }

  public var attributeSet: any AttributeSet { attrs }
  public var mouseMappings: MouseMappings { mouseMappingsStorage }
  public var toolbarData: ToolbarData { toolbarStorage }

  /// Java `copyFrom(Options, LogisimFile)`.
  ///
  /// D5/D13: `AttributeSets.copy` throws, so this does too rather than swallowing a failure to
  /// carry an option across.
  public func copyFrom(_ other: Options, destination: LogisimFile) throws {
    try AttributeSets.copy(from: other.attrs, to: attrs)
    try toolbarStorage.copyFrom(other.toolbarStorage, file: destination)
    try mouseMappingsStorage.copyFrom(other.mouseMappingsStorage, file: destination)
  }
}
