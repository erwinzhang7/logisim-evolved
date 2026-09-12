// FactoryDescription.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.tools.FactoryDescription and the
// `AddTool(Class<? extends Library>, FactoryDescription)` constructor),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── Why this exists at all, when the rest of `FactoryDescription` is deliberately not ported ─
//
// Five library files in this module say, correctly, that `FactoryDescription` is upstream's
// lazy/reflective machinery for JAR-loaded libraries (D11) and that this port builds every
// factory eagerly instead. That reasoning is sound and stands. What it missed is that
// `FactoryDescription` carries a **second, unrelated payload**: the tool's display name.
//
//     AddTool.java:307   public String getDisplayName() {
//     AddTool.java:309     return desc == null ? factory.getDisplayName() : desc.getDisplayName();
//
// A tool built from a description does NOT ask its factory. It answers the description's own
// getter, and upstream frequently passes a *different* key to the two. Measured, by asking the
// running 4.1.0 jar (`tools/valuebridge/NameBridge.java`, output committed as
// `names-4.1.0.tsv`), 66 of 173 builtin tools disagree with their own factory:
//
//     tool "7400"      -> "7400: quad 2-input NAND gate"   factory -> "7400"
//     tool "DipSwitch" -> "Dip switch"                     factory -> "DIP Switch"
//
// Both strings are live in the shipped app and neither is redundant: the explorer sidebar and
// the component palette render `Tool.getDisplayName()`, while `-tty stats` prints
// `count.getFactory().getDisplayName()` (`TtyInterface.java:86` and `:104`). Collapsing them,
// which is what this port did, since `AddTool.displayName` forwards to the factory, is wrong
// for one consumer whichever string you keep. `DipSwitch` is the sharpest case: the two bundle
// keys differ by exactly one capital letter (`dipswitchComponent` vs `DipSwitchComponent`).
//
// So the description's *identity/lazy-loading* half stays unported, per D11, and its
// *display-name* half is ported here, as the one thing `AddTool` needs from it.

import Foundation
import LogisimFile

/// `com.cburch.logisim.tools.AddTool` constructed from a `FactoryDescription`.
///
/// Behaviourally this is upstream's `desc != null` branch of `getDisplayName()`, and nothing
/// else: `name`, `attributeSet`, `sharesSource` and every identity question still come from the
/// factory, exactly as they do upstream once `sourceLoadAttempted` is true (which, in this port,
/// it always is; the factory is constructed eagerly).
///
/// Use it **only** where upstream's library declares a `FactoryDescription` whose getter
/// resolves to something other than the factory's own display name. Everywhere else a plain
/// `AddTool` is both correct and simpler, and `DisplayNameOracleTests` fails if the two are
/// swapped in either direction, because it checks tool and factory names independently against
/// the jar's measured output.
public final class DescribedAddTool: AddTool {

  /// `FactoryDescription.getDisplayName()`; the `StringGetter` the *library* passed, not the
  /// one the *factory* passed to its own superclass constructor.
  private let describedDisplayName: String

  public init(factory: any ComponentFactory, displayName: String) {
    self.describedDisplayName = displayName
    super.init(factory: factory)
  }

  private init(cloningDescribed base: DescribedAddTool) {
    self.describedDisplayName = base.describedDisplayName
    super.init(cloning: base)
  }

  public override var displayName: String { describedDisplayName }

  /// Upstream's copy constructor carries `desc` across, so a cloned toolbar entry keeps the
  /// description's name. Without this override `cloneTool()` would fall back to `AddTool`'s and
  /// silently downgrade the clone to the factory's name; the toolbar and the palette would
  /// then disagree about what the same tool is called.
  public override func cloneTool() -> Tool { DescribedAddTool(cloningDescribed: self) }
}
