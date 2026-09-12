// WiringPaint.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (the drawing constants of com.cburch.logisim.circuit.Wire and
// the shared idioms of com.cburch.logisim.std.wiring),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// The wiring family's shared paint constants and the one geometric idiom eight of its
// components repeat verbatim. `Wire` itself lives in `LogisimKernel` (it is a `Component` the
// propagator owns, not an `InstanceFactory`), so its two stroke widths are restated here rather
// than reached for across a module boundary.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

/// Shared constants and helpers for `std.wiring`'s painters.
public enum WiringPaint {

  /// `com.cburch.logisim.circuit.Wire.WIDTH`; the stroke a one-bit wire is drawn with.
  public static let wireWidth = 3

  /// `Wire.WIDTH_BUS`, a multi-bit wire.
  public static let busWidth = 4

  /// `Ground` / `Power` / `Transistor` / `TransmissionGate` / `PullResistor` all rotate their
  /// body with this exact expression:
  ///
  ///     int degrees = Direction.EAST.toDegrees() - from.toDegrees();
  ///     double radians = Math.toRadians((degrees + 360) % 360);
  ///
  /// which is **not** the same expression as the gates' `-facing.toRadians()`. The two differ
  /// by a full turn for three of the four facings; `sin`/`cos` agree to within an ulp, but the
  /// literal form is kept so a future reader diffing against the Java finds what they expect.
  public static func rotationRadians(from: Direction) -> Double {
    let degrees = Direction.east.toDegrees() - from.toDegrees()
    return Double((degrees + 360) % 360) * Double.pi / 180.0
  }
}
