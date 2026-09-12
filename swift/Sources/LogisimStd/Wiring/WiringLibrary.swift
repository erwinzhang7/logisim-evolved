// WiringLibrary.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.wiring.WiringLibrary),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── `FactoryDescription` is not ported ──────────────────────────────────────────────────────
//
// Same reasoning as `MemoryLibrary.swift`/`IoLibrary.swift`: upstream defers eight of its
// fourteen tools' construction through `FactoryDescription` (the lazy/reflective machinery
// behind JAR-loaded libraries, D11) purely to avoid loading their icon and factory class until
// the toolbar actually needs them. This port always holds a live `ComponentFactory`, `AddTool`
// itself builds eagerly (`LibraryModel.swift`'s header), so `ADD_TOOLS` and `DESCRIPTIONS`
// collapse into one flat list built with `AddTool(factory:)`, in the same relative order Java
// declares them (`ADD_TOOLS` first, then `DESCRIPTIONS`). `cachedTools` is memoized for the
// identity reason `MemoryLibrary` documents: `AddTool.sharesSource` and `Library.tool(named:)`
// compare factories by reference (D4), so a freshly-rebuilt array on every access would still
// compare equal (the factories are singletons either way) but would pointlessly reallocate an
// `AddTool` plus a fresh attribute set on every read.
//
// ── Splitter is the one factory without a `.factory` static let ────────────────────────────
//
// Every other component in this list exposes `public static let factory = X()`; `Splitter`'s
// factory is a `ComponentFactory` singleton named `SplitterFactory.instance`, mirroring Java's
// own `SplitterFactory.instance` (not `Splitter.FACTORY`; Java has no such constant either,
// since `Splitter` itself is not a factory). See `SplitterFactory.swift`'s header for why
// `Splitter` does not fit the rest of this module's chassis.
//
// ── Components from a sibling slice ─────────────────────────────────────────────────────────
//
// `Pin`, `Probe`, `PullResistor` are ported by this module's pin/probe slice; `Clock`, `Ground`,
// `Power`, `NoConnect` (Java's `DoNotConnect`, `_ID = "NoConnect"`), `PowerOnReset`,
// `Transistor`, `TransmissionGate` by its clock/passive slice. All seven files already exist on
// disk as of this writing, so this reference compiles; had it landed first it would not have,
// which is expected and accounted for under this task's file-ownership split (see the task
// brief's "write your port AS IF the change exists" instruction).
//
// ── What did not come across ─────────────────────────────────────────────────────────────────
//
//   * `getDisplayName()`'s localisation (`S.get("wiringLibrary")`); D5/D9's precedent;
//     the string itself DOES come across; it lives with the library's identity in
//     `LogisimFile/Builtin.swift`'s `BuiltinLibraryShell` table, because that shell, not
//     this class, is the `Library` object the loader hands to the app. This class is
//     registered only as a tool provider.
//   * The `.gif` icon filenames threaded through `FactoryDescription`/`setIconName`, M6 (D6).

import Foundation
import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.std.wiring.WiringLibrary`.
public final class WiringLibrary: Library {

  /// `WiringLibrary._ID`. Do not change: `.circ` files reference it via `<lib desc="#Wiring">`.
  public override class var libraryId: String { "Wiring" }

  private lazy var cachedTools: [Tool] = [
    // Java's `ADD_TOOLS`.
    AddTool(factory: SplitterFactory.instance),
    AddTool(factory: Pin.factory),
    AddTool(factory: Probe.factory),
    AddTool(factory: Tunnel.factory),
    AddTool(factory: PullResistor.factory),
    AddTool(factory: Clock.factory),
    AddTool(factory: PowerOnReset.factory),
    AddTool(factory: Constant.factory),
    // Java's `DESCRIPTIONS`, resolved eagerly instead of through `FactoryDescription`.
    AddTool(factory: Power.factory),
    AddTool(factory: Ground.factory),
    AddTool(factory: NoConnect.factory),
    AddTool(factory: Transistor.factory),
    AddTool(factory: TransmissionGate.factory),
    AddTool(factory: BitExtender.factory),
  ]

  public override var tools: [Tool] { cachedTools }
}
