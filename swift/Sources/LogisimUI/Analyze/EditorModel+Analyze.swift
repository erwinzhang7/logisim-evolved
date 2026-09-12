// EditorModel+Analyze.swift: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// The one seam between the menu bar and the analyzer.
//
// `ProjectHost` is a protocol over "a document the editor is showing", and it deliberately vends
// *projections*, `ProjectOutline`, `InspectorForm`, `CircuitID`, rather than kernel objects, so
// that a test double can implement it without a `LogisimFile`. `CircuitAnalysis` needs the real
// `Circuit` and the real `LogisimFile` (for `<options>`: `simrand` and `simlimit` have to match
// what the canvas simulates with, or the analyzer's table can disagree with the canvas on a
// circuit with an oscillation).
//
// So this reaches past the protocol to the one real conformer. That is a downcast, and it is
// stated rather than hidden: an editor backed by anything else simply cannot be analysed, the
// menu item greys out, and no silent wrong answer is possible. Widening `ProjectHost` to vend a
// `Circuit` would put a kernel type in the seam every test double has to satisfy, which is the
// trade the seam exists to avoid.

import LogisimFile

extension EditorModel {
  /// The circuit the editor is showing, and the file it belongs to, or `nil` if the host is not
  /// a real document (a preview or a test double) or no circuit is current.
  var analyzableCircuit: (circuit: Circuit, file: LogisimFile)? {
    guard let host = host as? LogisimFileProjectHost,
      let circuit = host.currentCircuitObject
    else { return nil }
    return (circuit, host.file)
  }
}
