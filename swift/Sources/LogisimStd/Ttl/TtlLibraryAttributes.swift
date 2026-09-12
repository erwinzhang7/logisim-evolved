// TtlLibraryAttributes.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.ttl.TtlLibrary: the attribute
// declarations only), https://github.com/logisim-evolution/logisim-evolution. Copyright by the
// Logisim-evolution developers. This translation is a derivative work and is therefore
// GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// Only the two attributes are here. `TtlLibrary` itself is a `Library`, a tool list plus
// `FactoryDescription`s, which belongs to the library-registration workflow, not to this
// module. The 65 chips need these two names to exist and nothing else.

import Foundation
import LogisimKernel

/// The two attributes every TTL chip carries beyond `StdAttr.FACING` and `StdAttr.LABEL`.
public enum TtlLibraryAttributes {

  /// `TtlLibrary.VCC_GND`, when true the chip exposes its GND and Vcc pins as real ports and
  /// refuses to compute unless they are driven correctly. Simulation-visible.
  public static let vccGnd: Attribute<Bool> = Attributes.forBoolean("VccGndPorts")

  /// `TtlLibrary.DRAW_INTERNAL_STRUCTURE`: draw-only, declared because it is part of the
  /// attribute template and therefore part of the `.circ` round trip.
  public static let drawInternalStructure: Attribute<Bool> =
    Attributes.forBoolean("ShowInternalStructure")
}
