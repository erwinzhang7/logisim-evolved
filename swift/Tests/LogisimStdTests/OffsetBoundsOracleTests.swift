// OffsetBoundsOracleTests.swift: part of logisim-evolved.
//
// Task #18, the differential half. `tools/difftest/BoundsOracle.java` runs against the shipped
// 4.1.0 jar and prints one row per (library, factory, attribute assignment, offset bounds);
// this suite replays every row against the ported factory and compares the rectangle literally.
//
// The table is committed at `tools/difftest/bounds-4.1.0.oracle` rather than regenerated,
// because it derives only from the public jar, no corpus, no lab solutions, nothing that
// standing rule 1 covers, and committing it means the gate runs with no JVM on the machine.
// Regenerate with the command in `BoundsOracle.java`'s header if 4.1.0 is ever re-pinned.
//
// ── Why bounds are a gate and not a drawing detail ──────────────────────────────────────────
//
// `XmlCircuitReader.buildCircuit` keys its overlap detector on `getBounds()` and relocates a
// collision by `+10,+10` until the slot is free. A factory whose box is empty collapses every
// placement of that factory onto one key, and all but the first are silently dropped on load.
// A factory whose box is wrong by one pixel relocates a component that should not have moved,
// or fails to relocate one that should: off-grid, and very hard to trace back to geometry.
//
// ── What is out of scope, and why each is not a defect ──────────────────────────────────────
//
// The oracle covers all thirteen builtin libraries; the port has nine of them. Rows for a
// library or a factory the port does not have are counted and reported, never silently
// dropped; an unported factory is a parity gap on the M-backlog, not a bounds bug, and the
// two must stay distinguishable in the output.
//
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.

import Foundation
import LogisimFile
import LogisimKernel
import Testing

@testable import LogisimStd

/// One row of the Java table.
struct BoundsOracleRow {
  let library: String
  let factory: String
  /// `<default>`, or a comma-separated list of `name=value` assignments.
  let assignment: String
  let x: Int32
  let y: Int32
  let width: Int32
  let height: Int32

  var box: String { "\(x),\(y),\(width),\(height)" }
  var label: String { "\(library)/\(factory) [\(assignment)]" }
}

enum BoundsOracle {

  /// `tools/difftest/bounds-4.1.0.oracle`, found relative to this source file so the suite
  /// needs no environment variable and no resource bundle.
  static var tablePath: String {
    // …/swift/Tests/LogisimStdTests/OffsetBoundsOracleTests.swift → repo root
    let here = URL(fileURLWithPath: #filePath)
    let root = here
      .deletingLastPathComponent()  // LogisimStdTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // swift
      .deletingLastPathComponent()  // repo root
    return root.appendingPathComponent("tools/difftest/bounds-4.1.0.oracle").path
  }

  static func load() throws -> [BoundsOracleRow] {
    let text = try String(contentsOfFile: tablePath, encoding: .utf8)
    var rows: [BoundsOracleRow] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
      let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
      guard parts.count == 4 else { continue }
      let box = parts[3].split(separator: ",", omittingEmptySubsequences: false)
      guard box.count == 4,
        let x = Int32(box[0]), let y = Int32(box[1]),
        let w = Int32(box[2]), let h = Int32(box[3])
      else { continue }
      rows.append(
        BoundsOracleRow(
          library: String(parts[0]), factory: String(parts[1]), assignment: String(parts[2]),
          x: x, y: y, width: w, height: h))
    }
    return rows
  }
}

/// Every builtin factory the port has, keyed by its `.circ` name. Names are globally unique
/// across the builtin set: verified against the oracle table, which has no duplicate.
private func factoriesByName() -> [String: any ComponentFactory] {
  var out: [String: any ComponentFactory] = [:]
  for (_, factory) in allBuiltinFactories() { out[factory.name] = factory }
  // The two libraries `StdLibraries.registerAll` does not register yet are still ported, and
  // their geometry is just as gate-visible, so they are measured here regardless.
  for tool in ExtraIoLibrary().tools {
    if let add = tool as? AddTool { out[add.factory.name] = add.factory }
  }
  return out
}

/// Turn one oracle token back into storage form, matching what the oracle's own `setValue`
/// call did on the Java side.
///
/// **The obvious implementation is wrong and it matters.** Going through
/// `parseToAttributeValue` looks right, but `Attribute.parse` enforces a range that
/// `AttributeSet.setValue` does not: `Attributes.forBitWidth("bits", 1, 5)` rejects `32` when
/// parsing text and accepts `BitWidth.create(32)` when assigned directly. The oracle assigns
/// directly, so a parse-only Swift side silently declines 222 rows, including every wide
/// `Joystick` and `Slider`, and reports that as agreement. Those are exactly the rows where an
/// out-of-range width could make the geometry diverge, so dropping them defeats the test.
///
/// So: parse first, because it is the honest path for anything with a textual form, and fall
/// back to a direct encoding shaped like the value already stored under that attribute.
private func encode(
  _ text: String, for attribute: AnyAttribute, in attrs: any AttributeSet
) -> AttributeValue? {
  if let parsed = try? attribute.parseToAttributeValue(text) { return parsed }
  switch attrs.rawValue(attribute) {
  case .bitWidth: return Int32(text).map { AttributeValue.bitWidth($0) }
  case .integer: return Int32(text).map { AttributeValue.integer($0) }
  case .long: return Int64(text).map { AttributeValue.long($0) }
  default: return nil
  }
}

@Suite("task #18 — offset bounds against the 4.1.0 Java oracle")
struct OffsetBoundsOracleTests {

  @Test("the oracle table is present and well-formed")
  func tableLoads() throws {
    let rows = try BoundsOracle.load()
    #expect(rows.count > 5000, "oracle table at \(BoundsOracle.tablePath) looks truncated")
  }

  @Test("every ported factory reproduces Java's offset bounds exactly")
  func boundsMatchOracle() throws {
    let rows = try BoundsOracle.load()
    let factories = factoriesByName()

    var compared = 0
    var mismatches: [String] = []
    var unportedFactories: Set<String> = []
    var unsettable: [String] = []
    var missingAttributes: Set<String> = []

    for row in rows {
      guard let factory = factories[row.factory] else {
        unportedFactories.insert("\(row.library)/\(row.factory)")
        continue
      }

      let attrs = factory.createAttributeSet()
      var applied = true
      if row.assignment != "<default>" {
        for pair in row.assignment.split(separator: ",") {
          guard let eq = pair.firstIndex(of: "=") else { continue }
          let name = String(pair[pair.startIndex..<eq])
          let text = String(pair[pair.index(after: eq)...])
          guard let attribute = attrs.attribute(named: name) else {
            missingAttributes.insert("\(row.factory).\(name)")
            applied = false
            break
          }
          if attrs.isReadOnly(attribute) { applied = false; break }
          guard let value = encode(text, for: attribute, in: attrs) else {
            applied = false
            break
          }
          do { try attrs.setRawValue(attribute, value) } catch { applied = false; break }
        }
      }
      guard applied else {
        unsettable.append(row.label)
        continue
      }

      compared += 1
      let bounds = factory.offsetBounds(attrs)
      let got = "\(bounds.x),\(bounds.y),\(bounds.width),\(bounds.height)"
      if got != row.box {
        mismatches.append("\(row.label)  java=\(row.box)  swift=\(got)")
      }
    }

    let summary = """

      ── offset bounds vs the 4.1.0 oracle ──────────────────────────────────────────
        rows in table         \(rows.count)
        compared              \(compared)
        MISMATCHES            \(mismatches.count)
        rows skipped, factory not ported   \(rows.count - compared - unsettable.count) \
      (\(unportedFactories.count) distinct factories)
        rows skipped, assignment rejected  \(unsettable.count)
      ───────────────────────────────────────────────────────────────────────────────
      """
    print(summary)
    if !unportedFactories.isEmpty {
      print("  not ported: \(unportedFactories.sorted().joined(separator: ", "))")
    }
    if !missingAttributes.isEmpty {
      print("  attribute absent in the port: \(missingAttributes.sorted().joined(separator: ", "))")
    }
    if !unsettable.isEmpty {
      print("  rejected: \(Set(unsettable).sorted().prefix(30).joined(separator: " | "))")
    }
    for line in mismatches.prefix(60) { print("  MISMATCH \(line)") }
    if mismatches.count > 60 { print("  … and \(mismatches.count - 60) more") }

    #expect(compared > 3000, "the comparison covered far too few rows to mean anything")
    #expect(mismatches.isEmpty, "\(mismatches.count) offset-bounds mismatches; see the log")
  }
}
