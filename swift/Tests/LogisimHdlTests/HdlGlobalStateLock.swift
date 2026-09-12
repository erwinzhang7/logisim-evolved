// HdlGlobalStateLock: part of logisim-evolved.
//
// Test-only infrastructure. Not a port of anything upstream.
//
// ── Why one lock for the whole module ──────────────────────────────────────────────────────
//
// `HdlSettings.language`, `HdlSettings.vhdlKeywordsUppercase` and `HdlBuildInfo.name`/`.url` are
// process-wide mutable globals *by design*: they stand in for Java's `AppPreferences`, which is
// an application-wide singleton (see `HdlLanguage.swift`'s header, and D9 on why
// `AppPreferences` itself is not ported). Every HDL oracle suite drives them, because the whole
// point of the gate is to generate each case in both VHDL and Verilog.
//
// Swift Testing runs **suites in parallel even when each suite is `.serialized`**: `.serialized`
// only orders the tests *within* one suite. `IoHdlOracleSupport.swift` discovered this and
// introduced a lock, but scoped it to the two io suites only. The other four suites
// (gates/wiring/plexers, arith, memory, and the netlist gates) kept flipping the same globals
// concurrently, which produced two failures that look nothing like each other and share one
// cause:
//
//   1. `IoHdlOracleTests` reported `SevenSegment/dp=true  VHDL` emitting **Verilog**; a VHDL
//      case whose language was flipped out from under it mid-generation.
//   2. `WithSelectHdlGenerator.getHdlCode()` **trapped the whole test process** with
//      `#E006: No mapping for 'when' placeholder`. That generator branches on `Hdl.isVhdl()`
//      twice: once to call `addVhdlKeywords()`, and again per case to emit `{{when}}`. Read
//      `false` then `true` and the keyword pairs were never installed, so a template referencing
//      `{{when}}` reached validation with nothing to resolve it. The trap killed the runner, so
//      every suite after it was silently never measured; the failure looked like "the memory
//      suite hangs".
//
// The second is the more dangerous shape: a *test-harness* race that presents as a *port* bug,
// in a generator whose Swift is a line-for-line match of the Java.
//
// So: one lock, taken by every test that touches those globals, in every suite. A per-suite lock
// cannot fix this; the racing parties are in different suites.

import Foundation
import LogisimHdl

/// The single mutex guarding `HdlSettings` and `HdlBuildInfo` across every suite in this module.
///
/// Take it for the whole body of any test that reads or writes either. Non-recursive, so do not
/// nest; no test needs to.
let hdlGlobalStateLock = NSLock()

/// Runs `body` with the HDL globals locked and restores every one of them afterwards, whether
/// `body` returns or throws.
///
/// Restoring matters as much as locking: a test that leaves `language` on `.verilog` makes the
/// *next* suite's first case wrong, and that failure is reported against the innocent suite.
func withHdlGlobals<T>(_ body: () throws -> T) rethrows -> T {
  hdlGlobalStateLock.lock()
  defer { hdlGlobalStateLock.unlock() }

  let savedLanguage = HdlSettings.language
  let savedUppercase = HdlSettings.vhdlKeywordsUppercase
  let savedName = HdlBuildInfo.name
  let savedUrl = HdlBuildInfo.url
  defer {
    HdlSettings.language = savedLanguage
    HdlSettings.vhdlKeywordsUppercase = savedUppercase
    HdlBuildInfo.name = savedName
    HdlBuildInfo.url = savedUrl
  }
  return try body()
}

// ── The second global, found the same way ──────────────────────────────────────────────────
//
// `HdlGeneratorLookup.shared` is process-wide mutable state too, and the header above did not
// cover it. Two suites write it, the netlist gate installs `upstreamGeneratorFactoryNames`,
// `upstreamSupportedFactoryNames` and the FPGA map bindings, and `MapInformationOracleTests`
// installs the map bindings alone, and each ends with `removeAll()`, which wipes *everything*
// including the other suite's registrations.
//
// Symptom when it bites: `MapInformationOracleTests` passes on its own and fails in a full run,
// reporting rows the jar has and the port does not; because the bindings it installed were
// removed by the other suite's `defer` mid-test. Which is the signature of shared state, not of a
// bad test, and is the same lesson as `ToolPreservationTests` and the `HdlSettings` race above:
// **passing in isolation and failing in the suite is a fact about the harness.**
//
// Separate from `hdlGlobalStateLock` because the two protect disjoint state and no test needs
// both; a single lock would serialise suites that have no reason to wait on each other.

/// The mutex guarding `HdlGeneratorLookup.shared` across every suite in this module.
let hdlGeneratorLookupLock = NSLock()

/// Runs `body` with `HdlGeneratorLookup.shared` locked, and clears it afterwards whether `body`
/// returns or throws, so the next taker starts from the same empty registry every time.
func withHdlGeneratorLookup<T>(_ body: () throws -> T) rethrows -> T {
  hdlGeneratorLookupLock.lock()
  defer {
    HdlGeneratorLookup.shared.removeAll()
    hdlGeneratorLookupLock.unlock()
  }
  return try body()
}
