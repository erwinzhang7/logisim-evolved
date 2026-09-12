// D13TrapTests; part of logisim-evolved.
//
// D13: a catchable Java exception becomes a Swift `throw`, never a trap. A `preconditionFailure`
// is not catchable and terminates the process, converting a recoverable generation error into an
// app crash with unsaved work lost.
//
// These are regression tests in the strictest sense: every one of them **killed the whole test
// runner** before the fix. That is also why they matter more than most; a trap does not report a
// failure, it takes the process down, so every suite scheduled after it goes silently unmeasured.
// The `{{when}}` trap presented as "the memory suite hangs".
//
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.

import Foundation
import LogisimKernel
import Testing

@testable import LogisimHdl

@Suite("D13 — HDL generation reports errors instead of trapping", .serialized)
struct D13TrapTests {

  // MARK: - HdlParameters

  /// The exact call the brief names: `getComponentMap(componentInfo: nil)`.
  ///
  /// That branch of `AbstractHdlGeneratorFactory` hands `HdlParameters.getMaps` an **empty**
  /// attribute set. Every attribute-reading parameter kind then fails `containsAttribute`, and
  /// before the fix that was `preconditionFailure("Component has not the required attribute")`:
  /// process dead. Java raises `UnsupportedOperationException` (`HdlParameters.java:159`), which
  /// is catchable, so the port must throw.
  @Test("getComponentMap with no component info throws rather than killing the process")
  func componentMapWithNilComponentInfoThrows() throws {
    let width: Attribute<BitWidth> = Attributes.forBitWidth("width")
    let generator = AbstractHdlGeneratorFactory(subDirectory: "d13", widthAttribute: width)
    // One `.widthFormula` parameter, which is what `HdlParameters.add(name, id)` builds and what
    // essentially every width-parameterised generator declares. It reads `widthAttribute`, which
    // the empty attribute set does not have.
    //
    // Deliberately NOT `addBusOnly`: a bus-only parameter is skipped by `isUsed` when the width
    // attribute is absent (nrOfBits falls back to 0), so it never reaches the failing read and
    // would have made this test pass for the wrong reason.
    _ = generator.myParametersList.add("NrOfBits", -1)

    #expect(throws: HdlParameterError.self) {
      _ = try generator.getComponentMap(
        netlist: D13Netlist(), componentId: 1,
        componentInfo: nil as (any HdlNetlistComponent)?, name: "Widget")
    }
  }

  /// `getNumberOfVectorBits` for an id the list never declared. Java: `UnsupportedOperationException`
  /// (`HdlParameters.java:392`).
  @Test("an undeclared parameter id throws rather than trapping")
  func undeclaredParameterIdThrows() {
    let width: Attribute<BitWidth> = Attributes.forBitWidth("width")
    let parameters = HdlParameters(widthAttribute: width)
    #expect(throws: HdlParameterError.self) {
      _ = try parameters.getNumberOfVectorBits(-99, attrs: AttributeSets.empty)
    }
  }

  // MARK: - LineBuffer

  /// The reachability claim behind the `LineBuffer.abort` change, asserted rather than reasoned.
  ///
  /// `add(_:applyMap:)` substitutes the pair map and *then* validates the RESULT, so a substituted
  /// **value** containing `{{…}}` is indistinguishable from an unmapped placeholder. Values
  /// include component labels, and `CorrectLabel.correctLabel` only maps spaces and hyphens to
  /// underscores; it does **not** strip braces. So a component labelled `a{{x}}b`, which any
  /// `.circ` file may contain, reaches `#E006`.
  ///
  /// This is the test that refutes the old comment's "never something reachable from a `.circ`
  /// file". Before the fix it did not fail, it terminated the runner.
  @Test("a component label containing braces reaches validation, and reports instead of trapping")
  func labelWithBracesIsRecordedNotFatal() {
    // Step 1: the label survives sanitisation with its braces intact.
    let sanitised = CorrectLabel.correctLabel("a{{x}}b")
    #expect(sanitised.contains("{{x}}"), "correctLabel stripped the braces — reachability changed")

    // Step 2: substituting it into a template leaves an unmappable placeholder behind.
    let buffer = LineBuffer.getHdlBuffer()
    buffer.pair("label", sanitised)
    buffer.add("   signal {{label}} : std_logic;")

    #expect(buffer.hasAbortedValidation, "validation did not notice the unresolved placeholder")
    #expect(
      buffer.abortedValidationMessages.contains { $0.contains("#E006") },
      "expected an #E006 report, got \(buffer.abortedValidationMessages)")

    // Step 3: and the emitted text is unchanged; recording is a pure observation, so the four
    // byte-exact oracle gates cannot be affected by this change.
    #expect(buffer.get() == ["   signal a{{x}}b : std_logic;"])
  }

  /// A well-formed buffer records nothing, so `hasAbortedValidation` is a usable signal rather
  /// than something that is always true.
  @Test("a well-formed buffer reports no validation failure")
  func wellFormedBufferIsClean() {
    let buffer = LineBuffer.getHdlBuffer()
    buffer.pair("label", "s_ok")
    buffer.add("   signal {{label}} : std_logic;")
    #expect(!buffer.hasAbortedValidation)
    #expect(buffer.abortedValidationMessages.isEmpty)
  }

  /// The `{{when}}` case from the brief, reproduced directly: a VHDL keyword placeholder used
  /// without `addVhdlKeywords()`. This is what `WithSelectHdlGenerator` hit when a parallel suite
  /// flipped `HdlSettings.language` between its two `Hdl.isVhdl()` reads.
  @Test("an unmapped keyword placeholder reports #E006 instead of killing the runner")
  func unmappedKeywordPlaceholderIsRecorded() {
    let buffer = LineBuffer.getHdlBuffer()
    buffer.add("   \"111\" {{when}} \"000\",")
    #expect(buffer.hasAbortedValidation)
    #expect(buffer.abortedValidationMessages.contains { $0.contains("when") })
  }
}

/// The minimum `HdlNetlist` `getComponentMap` reads.
private final class D13Netlist: HdlNetlist {
  func netId(for net: any HdlNet) -> Int { -1 }
  func isContinuesBus(_ component: any HdlNetlistComponent, endIndex: Int) -> Bool { false }
  var currentHierarchyLevel: [String]? { nil }
  func clockSourceId(hierarchyLevel: [String], net: any HdlNet, bitIndex: Int) -> Int { -1 }
  var circuitName: String { "d13" }
  var projName: String { "d13" }
  var requiresGlobalClockConnection: Bool { false }
}
