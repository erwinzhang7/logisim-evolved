// Regression: the dominant upstream call shape must compile.
//
// Java resolves createKnown(BitWidth, long) over createKnown(BitWidth, double) for an int
// argument by widening rules (int->long beats int->double). Swift has no such rule, so while
// both overloads were named createKnown, a bare integer literal was ambiguous and roughly 25
// of the 185 upstream call sites, Multiplier.java:61, Register.java:338, Ram.java:250,
// Counter.java:611, ShiftRegisterData.java:30/35/84 and others, would not have compiled.
//
// The floating-point entry points are therefore named createKnownFloat. If anyone merges them
// back into createKnown, this file stops compiling, which is the intent.

import Testing

@testable import LogisimKernel

@Test("createKnown accepts a bare integer literal, as the upstream call sites require")
func createKnownAcceptsIntegerLiterals() throws {
  // These are the exact shapes that appear throughout the Java component library.
  let a = Value.createKnown(try BitWidth.create(8), 5)
  #expect(a.getWidth() == 8)
  #expect(a.toLongValue() == 5)

  let b = Value.createKnown(4, 5)
  #expect(b.getWidth() == 4)
  #expect(b.toLongValue() == 5)

  let zero = Value.createKnown(try BitWidth.create(16), 0)
  #expect(zero.toLongValue() == 0)
  #expect(zero.isFullyDefined())

  // The floating-point paths remain reachable under their distinct name.
  let f = Value.createKnownFloat(Float(1.5))
  #expect(f.getWidth() == 32)
  #expect(f.toFloatValue() == 1.5)

  let d = Value.createKnownFloat(Double(2.5))
  #expect(d.getWidth() == 64)
  #expect(d.toDoubleValue() == 2.5)
}
