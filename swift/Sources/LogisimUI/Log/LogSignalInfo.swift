// LogSignalInfo.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.gui.log.SignalInfo: the naming and radix
// half), https://github.com/logisim-evolution/logisim-evolution. Copyright by the
// Logisim-evolution developers. This translation is a derivative work and is therefore
// GPL-3.0-only. See LICENSE.md.
// SPDX-License-Identifier: GPL-3.0-only
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── What came across, and what did not ──────────────────────────────────────────────────────
//
// `SignalInfo` is three things bolted together: an identity (a path of components from the
// top-level circuit down to the logged one), a display name derived from that path, and a radix.
// Only the second and third are model state; the first is a *reference into the circuit*, which
// this port expresses as a `LogSignalProbe` (see LogSignalProbe.swift). Splitting them is what
// makes the log model runnable with no circuit at all, which is what the tests do.
//
// Not ported, deliberately:
//
//   * `implements Transferable` and the two `DataFlavor` blocks. Swing drag-and-drop; SwiftUI
//     uses `Transferable`/`UTType` and the selection list here moves rows by index.
//   * `public final Icon icon` and `paintIcon`. An AWT `Icon` that calls
//     `factory.paintIcon(ComponentDrawContext, …)`. D6 routes all drawing through `RenderScene`,
//     and the sidebar already has its own component iconography.
//   * `Location.At` conformance. Used only by `Location.sortHorizontal(info)` in `Model`'s
//     constructor; `LogSignalDiscovery` sorts by the component's location directly instead, so
//     the conformance would exist to serve one call in one file.
//   * The `CircuitListener`/`AttributeListener` conformances that recompute the name when a
//     component is replaced or relabelled. Those need the transaction system's
//     `ReplacementMap`, which `LogModel` subscribes to instead: one subscription for the whole
//     model rather than one per row, which is both fewer tokens to lose and closer to how the
//     rest of this port handles D3 lifetimes.

import Foundation
import LogisimFile
import LogisimKernel

/// One selected signal: what to sample, how to name it, and how to render it.
///
/// Reference type with a stable `id`, because SwiftUI lists, the file writer's cursor table and
/// the model's own index all key on the same object across reorderings.
public final class LogSignalInfo: Identifiable {

  /// Stable across renames and reorderings. SwiftUI's `ForEach` needs this; using the display
  /// name would make every row lose its selection when a pin is relabelled.
  public let id = UUID()

  /// Where the value comes from.
  public let probe: any LogSignalProbe

  /// `getRadix()` / `setRadix(RadixOption)`.
  public var radix: LogRadix

  /// The path prefix for a signal inside a subcircuit: `"adder/carry"`. Empty for a top-level
  /// component. Upstream builds this by walking `path[0..<n-1]`; here the discoverer supplies it
  /// because it is the thing that knows the nesting.
  public let pathPrefix: [String]

  public init(probe: any LogSignalProbe, radix: LogRadix = .default, pathPrefix: [String] = []) {
    self.probe = probe
    self.radix = radix
    self.pathPrefix = pathPrefix
  }

  /// `getShortName()`: the last path element only.
  public var shortName: String { probe.probeName }

  /// `getWidth()`.
  public var width: Int { probe.probeWidth }

  /// `isInput(option)`.
  public var isInput: Bool { probe.probeIsInput }

  /// `getDisplayName()` / `toString()`; `"sub/adder/carry[3..0]"`.
  ///
  /// The width suffix is appended only for buses, exactly as `computeName` does: a one-bit
  /// signal reads `"clk"`, not `"clk[0..0]"`.
  public var displayName: String {
    var name = (pathPrefix + [shortName]).joined(separator: "/")
    let bits = width
    if bits > 1 { name += "[\(bits - 1)..0]" }
    return name
  }

  /// `fetchValue(CircuitState)`, with upstream's `Value.NIL` fallback for a component that
  /// supplies no logger.
  public func fetchValue() -> Value {
    probe.readValue() ?? .nilValue
  }

  /// `format(Value)`.
  public func format(_ value: Value) -> String { radix.format(value) }

  /// `setRadix(RadixOption)`; returns whether anything changed, which is what the model uses to
  /// decide whether to fire `selectionChanged`.
  @discardableResult
  public func setRadix(_ value: LogRadix) -> Bool {
    if value == radix { return false }
    radix = value
    return true
  }

  /// `getFormattedMaxValue()`; the widest string this signal can render, used to size a column.
  public var formattedMaxValue: String {
    guard let bits = try? BitWidth.create(max(width, 1)) else { return "" }
    return format(Value.createKnown(bits, -1))
  }

  /// `getFormattedMinValue()`.
  public var formattedMinValue: String {
    guard let bits = try? BitWidth.create(max(width, 1)) else { return "" }
    return format(Value.createKnown(bits, 0))
  }
}

extension LogSignalInfo: CustomStringConvertible {
  public var description: String { displayName }
}

// MARK: - Naming

/// `SignalInfo.logName(Component, Object)` and its `normalize` helper.
///
/// Kept as free functions on a caseless enum rather than methods on `Component`, so that nothing
/// in LogisimFile has to know the Log window exists.
public enum LogComponentNaming {

  /// `normalize(String s, Object o)`: empty and `nil` both mean "no name at this tier", and a
  /// non-`nil` option is appended with a dot.
  static func normalize(_ name: String?, option: String?) -> String? {
    guard let name, !name.isEmpty else { return nil }
    guard let option else { return name }
    return "\(name).\(option)"
  }

  /// `logName(Component c, Object option)`.
  ///
  /// Upstream tries three tiers in order: the component's `LoggableContract.getLogName`, then
  /// `StdAttr.LABEL`, then `factory.getDisplayName() + location`. **The first tier is absent**
  /// because no component in this port supplies the `loggable` feature yet; see the seam note
  /// in LogSignalProbe.swift. The remaining two are upstream's exactly, and they are what
  /// actually names a Pin or a Led in practice, because those components' `getLogName` returns
  /// their label anyway.
  public static func logName(of component: any Component, option: String? = nil) -> String {
    if let label = normalize(component.attributeSet[StdAttr.label], option: option) {
      return label
    }
    // `Location.toString()` in Java is "(x,y)", which this port's `Location` reproduces.
    let fallback = "\(component.factory.displayName)\(component.location)"
    return normalize(fallback, option: option) ?? fallback
  }
}
