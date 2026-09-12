// SocInstanceFactory.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.soc.data.SocInstanceFactory),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── Seam: this replaces upstream's `isSocComponent()` flag on the base `InstanceFactory` ──────
//
// Java adds `isSocComponent()` (default `false`) directly to `com.cburch.logisim.instance.
// InstanceFactory` so `SocSimulationManager.registerComponent` can test *any* factory with
// `c.getFactory().isSocComponent()` before downcasting to `SocInstanceFactory`. This module does
// not own `LogisimStd/Instance/InstanceFactory.swift`, so that flag cannot be added there.
// The Swift equivalent test is `component.factory as? any SocInstanceFactory`, which is exactly
// as precise (a non-SoC factory simply fails the cast) and needs no upstream edit. Every call
// site in this module (`SocSimulationManager.registerComponent`/`removeComponent`) uses that
// form instead of a boolean flag.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimStd

/// `SocInstanceFactory.SOC_MASTER` / `SOC_SLAVE` / `SOC_BUS` / `SOC_SNIFFER`.
public struct SocComponentKind: OptionSet, Sendable {
  public let rawValue: Int
  public init(rawValue: Int) { self.rawValue = rawValue }

  public static let master = SocComponentKind(rawValue: 1)
  public static let slave = SocComponentKind(rawValue: 2)
  public static let bus = SocComponentKind(rawValue: 4)
  public static let sniffer = SocComponentKind(rawValue: 8)
}

/// `com.cburch.logisim.soc.data.SocInstanceFactory`.
///
/// Java's abstract base gives every SoC factory a default no-op `paintInstance`/`propagate`,
/// preserved here as the `InstanceFactory` extension's defaults below, so a factory that is,
/// say, `SOC_BUS`-only and has nothing to propagate need not override anything.
public protocol SocInstanceFactory: InstanceFactory {
  var socKind: SocComponentKind { get }

  /// `getSlaveInterface(AttributeSet)`.
  func slaveInterface(_ attributes: any AttributeSet) -> (any SocBusSlaveInterface)?
  /// `getSnifferInterface(AttributeSet)`.
  func snifferInterface(_ attributes: any AttributeSet) -> (any SocBusSnifferInterface)?
  /// `getProcessorInterface(AttributeSet)`.
  func processorInterface(_ attributes: any AttributeSet) -> (any SocProcessorInterface)?
}

extension SocInstanceFactory {
  public var isSocSlave: Bool { socKind.contains(.slave) }
  public var isSocSniffer: Bool { socKind.contains(.sniffer) }
  public var isSocBus: Bool { socKind.contains(.bus) }
  public var isSocMaster: Bool { socKind.contains(.master) }
  /// `isSocUnknown()`: `myType == SOC_UNKNOWN`, i.e. **no** flag set, not "some flag missing".
  /// `SocSimulationManager.registerComponent`/`removeComponent` both bail on it before doing
  /// anything, so a factory that forgot its flags is inert rather than half-registered.
  public var isSocUnknown: Bool { socKind.isEmpty }

  // Defaults matching `SocInstanceFactory`'s no-op `paintInstance`/`propagate`; a concrete
  // factory overrides whichever it actually needs (every one of the six built-in SoC
  // components overrides `propagate`, since a slave/master with nothing to do on every
  // propagation would be pointless, but the default keeps the protocol usable for a
  // bus-only or sniffer-only factory that genuinely has none).
  public func propagate(_ state: any InstanceState) throws {}
  public func slaveInterface(_ attributes: any AttributeSet) -> (any SocBusSlaveInterface)? { nil }
  public func snifferInterface(_ attributes: any AttributeSet) -> (any SocBusSnifferInterface)? {
    nil
  }
  public func processorInterface(_ attributes: any AttributeSet) -> (any SocProcessorInterface)? {
    nil
  }
}

/// The concrete base every built-in SoC component extends, mirroring `InstanceFactoryBase`'s
/// role for ordinary components (see `LogisimStd/Instance/InstanceFactory.swift`).
open class SocInstanceFactoryBase: InstanceFactoryBase, SocInstanceFactory {
  public let socKind: SocComponentKind

  /// `displayName` is the port of `SocInstanceFactory(String name, StringGetter displayName,
  /// int type)`; upstream's SoC base takes the getter and hands it straight to
  /// `InstanceFactory`'s. All eight built-in SoC factories pass one
  /// (`super(_ID, S.getter("SocBusComponent"), SOC_BUS)`), so all eight must pass the string
  /// here; `nil` reproduces `constantGetter(getName())`, which for these would print the `_ID`
  /// : "Socmem", "SocJtagUart", "Rv32im". The strings are the measured output of
  /// `tools/valuebridge/NameBridge.java` (`names-4.1.0.tsv`), never transcribed from the Java,
  /// which carries only the bundle key. See `LogisimStd/Instance/InstanceFactory.swift`.
  public init(_ name: String, displayName: String? = nil, socKind: SocComponentKind) {
    self.socKind = socKind
    super.init(name, displayName: displayName)
  }

  // `SocInstanceFactory`'s no-op defaults, overriding `InstanceFactoryBase.propagate`'s trap;
  // Java's `SocInstanceFactory.propagate` is a genuine no-op body, not an abstract method, so a
  // component that happens not to override it must not crash.
  open override func propagate(_ state: any InstanceState) throws {}

  open func slaveInterface(_ attributes: any AttributeSet) -> (any SocBusSlaveInterface)? { nil }
  open func snifferInterface(_ attributes: any AttributeSet) -> (any SocBusSnifferInterface)? {
    nil
  }
  open func processorInterface(_ attributes: any AttributeSet) -> (any SocProcessorInterface)? {
    nil
  }
}
