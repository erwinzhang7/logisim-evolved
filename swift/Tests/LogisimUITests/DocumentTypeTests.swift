// LogisimUITests: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// CAN THE APP OPEN THE FILES IT EXISTS TO OPEN?
//
// On any Mac that has ever had logisim-evolution installed, a `.circ` resolves to
// `com.cburch.logisim.circ`: upstream exported that type, so LaunchServices answers with
// upstream's declaration for the extension, not ours. That is every CSC258 machine, which is the
// entire motivating audience for this port.
//
// Measured during packaging work, with upstream temporarily unregistered as the only variable:
//
//     resolved UTI                          result
//     com.cburch.logisim.circ               "About logisim-evolved", NO document window
//     app.closiq.logisim-evolved.circuit    opens
//
// `DocumentGroup` filters on `readableContentTypes` BEFORE `DocumentRoot` runs, so the file was
// dropped silently; even the existing "Could Not Open This Circuit" view never appeared. It
// looked like the app ignoring an open request rather than rejecting a type, which is why it
// survived: the failure had no error to search for.
//
// These assert on the TYPE LIST, because that list is what the filter reads. A test that opened a
// file through `CircuitDocument.init` directly would pass against the broken version; the reader
// was never the problem.
// ═════════════════════════════════════════════════════════════════════════════════════════════

import Foundation
import Testing
import UniformTypeIdentifiers

@testable import LogisimUI

@Suite("Document types")
struct DocumentTypeTests {

  @Test("both spellings of a .circ are readable")
  func readsBothUTIs() {
    let readable = LogisimDocumentType.readable
    #expect(readable.contains(LogisimDocumentType.circuit))
    #expect(
      readable.contains(LogisimDocumentType.upstreamCircuit),
      "upstream-typed .circ files are unopenable; this is the migration case")
  }

  @Test("the document and the FACTORY agree about what they accept")
  @MainActor
  func documentAndFactoryAgree() {
    // The second list is on the FACTORY, not the host -- I looked for it on the host first and
    // the compiler said so. Two separate declarations in two files feeding the same decision,
    // which is exactly how a duplicated constant stays wrong in both places at once: they were.
    let factory = LogisimFileProjectHostFactory()
    #expect(CircuitDocument.readableContentTypes == factory.readableContentTypes)
    #expect(CircuitDocument.writableContentTypes == factory.writableContentTypes)
  }

  @Test("upstream's type is IMPORTED, not exported, and is not writable")
  func upstreamTypeIsImportedAndNotWritten() {
    // D10: reading someone else's type is interoperability; writing it is claiming to be them.
    #expect(!CircuitDocument.writableContentTypes.contains(LogisimDocumentType.upstreamCircuit))
    #expect(CircuitDocument.writableContentTypes.contains(LogisimDocumentType.circuit))

    #expect(LogisimDocumentType.upstreamCircuit.identifier == "com.cburch.logisim.circ")
    #expect(LogisimDocumentType.circuit.identifier == "app.closiq.logisim-evolved.circuit")
  }

  @Test("a .circ filename resolves to something the app accepts")
  func extensionResolvesToAnAcceptedType() throws {
    // Whatever this machine's LaunchServices currently believes `.circ` means, upstream's type
    // if it is installed, ours if not, the app must accept it. Asserted against the live
    // resolution rather than a hardcoded identifier, because the whole defect was a mismatch
    // between what the system answers and what the app declared.
    let resolved = try #require(
      UTType(filenameExtension: "circ"), "no UTI is registered for .circ on this machine")
    let accepted = LogisimDocumentType.readable.contains { resolved.conforms(to: $0) || resolved == $0 }
    #expect(
      accepted,
      "`.circ` resolves to \(resolved.identifier), which is not in \(LogisimDocumentType.readable.map(\.identifier))")
  }
}
