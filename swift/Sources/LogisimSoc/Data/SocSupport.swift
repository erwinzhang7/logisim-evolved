// SocSupport.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.soc.data.SocSupport),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── Numeric fidelity note ────────────────────────────────────────────────────────────────────
//
// `convUnsignedInt`/`convUnsignedLong` are the single most load-bearing pair of functions in
// the whole SoC bus fabric: every slave's `canHandleTransaction` compares addresses through
// them so that a Java `int` whose top bit is set (an address >= 0x8000_0000) still compares as
// the large unsigned value a real embedded map expects, not as a negative number. Swift's
// `Int32` also wraps two's-complement, so the direct port is a masked widen into `Int64` /
// `UInt32`, never a signed comparison of the raw 32-bit value.
//
// ── `addAllFunctions`/`addGetterFunction`/`addSetterFunction`: GENUINELY MISSING, AND COSTED ──
//
// The line here used to bundle these three with `createItem` as "HDL/C header generation; out
// of scope per the port brief: 'Strip HDL generation'". That classification does not survive
// reading them. They emit **C**, not HDL, a `unsigned int get<Comp><Func>()` /
// `void set<Comp><Func>(unsigned int value)` pair over `volatile unsigned int*` at a literal
// `0x%X` base, indexed by register offset (`SocSupport.java:43-67`), and nothing in
// `LogisimHdl`, `HdlGeneratorLookup` or the netlist path can reach them. Filing them under the
// HDL exclusion made a genuinely missing feature look like a decision that had already been
// taken.
//
// What they are: the whole model half of upstream's **Export C** menu item, which exists on
// exactly two components. `PioMenu.exportC` (`PioMenu.java:54-160`) calls them 11 times across
// five configuration branches, direction, bidirectional, IRQ mask, edge capture, bit
// manipulation, so the generated header differs per PIO configuration, and `VgaMenu.exportC`
// (`VgaMenu.java:53-106`) calls `addAllFunctions` once for the mode-select register after
// emitting the five `SOFT_MODE_*_MASK` defines. `SocPio.swift` and `SocVga.swift` carry the
// per-component account.
//
// What it costs a user today: they cannot generate the C accessors for a PIO or a VGA
// component's memory-mapped registers, so a program driving those peripherals has to be written
// against hand-computed addresses. Measured against the harvested corpus that is a narrow
// audience, exactly **1** of 576 files places any SoC component at all
// (`3.7.2__case-186.circ`: one `Rv32im`, one `SocBus`, two `Socmem`, six
// `SocPio`), and **0** place a `SocVga`, but for that one file it is six PIOs' worth of
// addresses done by hand.
//
// WHY IT IS NOT PORTED HERE, DESPITE BEING REAL. Its only entry point in 4.1.0 is
// `getInstanceFeature(MenuExtender.class)`, and this port implements that hook for **no**
// component in any module. `LogisimUI/Tools/MenuTool.swift:169` states the position outright,
// `MenuExtender` is not ported and deliberately not stubbed, no protocol is declared for it,
// and grep finds no `: MenuExtender` conformance anywhere in `swift/Sources`.
// Emitting the generator now would add a function no user path can reach: a dead seam of exactly
// the shape boards #64-#66 were spent removing, and `deadseam.py` would then have to be taught
// to tolerate it. The correct sequencing is MenuExtender first, these three with it. Porting
// them is small and mechanical (three pure string emitters, ~60 lines, no Swing, no
// `CircuitState`); the cost is entirely in the hook, not here.
//
// Also not ported: `createItem` (`javax.swing.JMenuItem`: UI, D9), and the hierarchical-name
// helpers that walk
// `CircuitState.getParentState()`/`SubcircuitFactory` to build a breadcrumb name for nested
// subcircuits (`getMasterHierName`/`getMasterName`). Those need the live `CircuitState`
// hierarchy, which belongs to the simulation core (owned elsewhere); `getComponentName` below
// captures the leaf-name half that is pure data, and the hierarchical prefix is a UI/debug
// display concern the CPU-debugger UI can layer on top by walking `CircuitState` itself.

import Foundation
import LogisimFile
import LogisimKernel

public enum SocSupport {

  /// `SocSupport.convUnsignedInt(int)`: widen a 32-bit two's-complement value to its unsigned
  /// magnitude in a 64-bit accumulator. Every bus-address comparison in this subsystem goes
  /// through this so that addresses with the top bit set sort as large positive values.
  public static func convUnsignedInt(_ value: Int32) -> Int64 {
    Int64(UInt32(bitPattern: value))
  }

  /// Convenience overload for call sites that still hold a plain (possibly out-of-`Int32`-range)
  /// `Int`; wraps to 32 bits first (Java `int` semantics) and then widens unsigned, matching
  /// `convUnsignedInt(int)` applied to whatever 32-bit value the `int` argument denoted.
  public static func convUnsignedInt(_ value: Int) -> Int64 {
    convUnsignedInt(Int32(truncatingIfNeeded: wrap32(value)))
  }

  /// `SocSupport.convUnsignedLong(long)`: narrow back to the low 32 bits, matching Java's
  /// `(int) (value & LONG_MASK)`.
  public static func convUnsignedLong(_ value: Int64) -> Int32 {
    Int32(bitPattern: UInt32(truncatingIfNeeded: value))
  }

  /// `SocSupport.getComponentName(Component)` minus the hierarchical prefix (see file header).
  /// Java: label if set, else `"<displayName>@x,y"`.
  public static func componentName(_ component: any Component) -> String {
    let label = component.attributeSet.getValue(StdAttr.label)
    if let label, !label.isEmpty {
      return label
    }
    let loc = component.location
    return "\(component.factory.name)@\(loc.x),\(loc.y)"
  }
}
