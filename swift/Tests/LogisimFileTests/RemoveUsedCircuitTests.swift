// logisim-evolved: a native Swift/macOS port of logisim-evolution.
// Derived from logisim-evolution, which is GPL-3.0-only. This port is a derivative work and is
// therefore GPL-3.0-only.
// SPDX-License-Identifier: GPL-3.0-only
//
// Board #94, the sharper half: removing a circuit that another circuit PLACES.
//
// `LogisimFile.removeCircuit` refuses only the last circuit (`:602`). Upstream refuses a great
// deal more; `ProjectCircuitActions.doRemoveCircuit` (`gui/menu/ProjectCircuitActions.java:233`)
// checks `proj.getDependencies().canRemove(circuit)` first and puts up
// `circuitRemoveUsedError` if another circuit depends on it.
//
// This file exists to establish what the port actually DOES in that situation, before anyone
// decides what it should do. The distinction matters: #87 was withdrawn the same day for asserting
// a consequence that did not follow from a correct observation, so "there is no guard" is recorded
// here as a measurement of the resulting bytes rather than as an inference from the missing check.

import Foundation
import Testing

@testable import LogisimFile

/// `main` places `helper` as a subcircuit. A `<comp>` with no `lib` attribute names a circuit in
/// this same file, which is how upstream writes a subcircuit placement.
private let fileWhereMainUsesHelper = """
  <?xml version="1.0" encoding="UTF-8" standalone="no"?>
  <project source="4.1.0" version="1.0">
    <lib desc="#Base" name="0"/>
    <lib desc="#Wiring" name="1"/>
    <main name="main"/>
    <circuit name="helper"/>
    <circuit name="main">
      <comp loc="(100,100)" name="helper"/>
    </circuit>
  </project>
  """

@Suite("Board #94 — removing a circuit another circuit places")
struct RemoveUsedCircuitTests {

  private func load() throws -> LogisimFile {
    let loader = Loader()
    let file = try #require(try loader.openLogisimFile(data: Data(fileWhereMainUsesHelper.utf8)))
    return file
  }

  /// The premise, asserted rather than assumed: the fixture really does contain a placement of
  /// `helper` inside `main`. Without this the rest of the file could pass against a fixture that
  /// never wired the two circuits together.
  @Test func theFixtureReallyPlacesTheSubcircuit() throws {
    let file = try load()
    let main = try #require(file.circuit(named: "main"))
    #expect(
      main.nonWires.contains { $0.factory.name == "helper" },
      "the fixture does not place `helper` in `main`; every other assertion here would be vacuous")
  }

  /// What the port does today. Recorded as behaviour, not endorsed as correct, see the header.
  @Test func removingAUsedCircuitIsCurrentlyAllowed() throws {
    let file = try load()
    let helper = try #require(file.circuit(named: "helper"))
    #expect(throws: Never.self) { try file.removeCircuit(helper) }
    #expect(file.circuitCount == 1)
  }

  /// **The consequence, measured on the bytes.** Upstream never reaches this state, so there is no
  /// oracle for it; the question is only whether the port loses the user's work quietly.
  ///
  /// `XmlWriter` resolves each placed component back to a library (`XmlWriter.swift:1483`), and a
  /// component whose circuit is gone hits `loader.showError(...)` followed by `return nil`; the
  /// element is simply not written. So the placement disappears from the saved file.
  @Test func savingAfterwardsSilentlyDropsThePlacement() throws {
    let loader = Loader()
    let file = try #require(try loader.openLogisimFile(data: Data(fileWhereMainUsesHelper.utf8)))
    let helper = try #require(file.circuit(named: "helper"))
    try file.removeCircuit(helper)

    let saved = String(decoding: try #require(file.write(loader: loader)), as: UTF8.self)
    let recorder = loader.ui as? HeadlessLoaderUI

    #expect(
      !saved.contains("name=\"helper\""),
      "the placement survived the save, so this board's premise needs re-measuring")
    #expect(
      !(recorder?.errors.isEmpty ?? true),
      """
      the writer dropped the placement WITHOUT reporting it. That is the silent half: \
      XmlWriter.showError feeds HeadlessLoaderUI, whose array the app now drains \
      (LoaderDiagnosticsTests) — but only at LOAD time, not at save.
      """)
  }
}
