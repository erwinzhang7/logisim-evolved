// LogisimUI: part of logisim-evolved. GPL-3.0-only.
import Foundation
import LogisimKernel
import LogisimFile
import LogisimStd
import Testing

@testable import LogisimUI

@Suite("Preferences — downstream consumers", .serialized)
@MainActor
struct PreferenceDownstreamAuditTests {
  // Conservative source check, not a Swift parser or a proof of reachability. Removing
  // comments and literals prevents documentation from masquerading as a reader. Behavioral
  // tests below cover selected endpoints; the audit report records the remaining limits.
  static func codeOnly(_ source: String) -> String {
    let pattern = #"(?s)/\*.*?\*/|//[^\n]*|\"\"\".*?\"\"\"|\"(?:\\.|[^\"\\])*\""#
    return source.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
  }

  @Test("Comments, strings, and longer names cannot supply a consumer")
  func scannerRejectsFalseReaders() {
    let source = #"""
      // preferences.fake
      let text = "preferences.fake"
      /* preferences.fake */
      let actual = preferences.fakeLonger
      """#
    let files = [(url: URL(fileURLWithPath: "fixture.swift"), text: Self.codeOnly(source))]
    #expect(PreferenceConsumerTests.consumers(of: "fake", in: files).isEmpty)
    #expect(!PreferenceConsumerTests.consumers(of: "fakeLonger", in: files).isEmpty)
  }

  @Test("Pending wiring equals measured missing readers after removing comments and strings")
  func pendingListSelfLiquidates() throws {
    let files = try PreferenceConsumerTests.consumerFiles().map {
      (url: $0, text: Self.codeOnly(try String(contentsOf: $0, encoding: .utf8)))
    }
    let redirected = EditorPreferences.preferencesConsumedViaCanvasTemplate
    let missing = Set(PreferenceConsumerTests.declaredPreferences().filter {
      !redirected.contains($0) && PreferenceConsumerTests.consumers(of: $0, in: files).isEmpty
    })
    #expect(missing == Set(EditorPreferences.preferencesPendingWiring.keys))
    #expect(Set(EditorPreferences.preferencesPendingWiring.keys).isSubset(of:
      ["defaultTickFrequency", "autoPropagateByDefault", "showsTickMarkers"]))
    #expect(!PreferenceConsumerTests.consumers(of: "canvasAppearanceTemplate", in: files).isEmpty)
  }

  @Test("Every redirected field has an actual downstream reader beyond the render seam")
  func templateFieldsReachConsumers() throws {
    let files = try PreferenceConsumerTests.consumerFiles().filter {
      !$0.path.contains("/Seams/")
    }.map { Self.codeOnly(try String(contentsOf: $0, encoding: .utf8)) }
    for name in EditorPreferences.preferencesConsumedViaCanvasTemplate {
      // Excludes declarations, initializer labels, and assignments into storage. A mere
      // forwarding read can still pass: this gate is deliberately not called behavioral proof.
      let pattern = #"\bappearance_?\."# + name + #"\b(?!\s*=(?!=))"#
      #expect(files.contains { $0.range(of: pattern, options: .regularExpression) != nil },
        "\(name) reaches CanvasAppearance but has no downstream reader")
    }
  }

  @Test("Only explicitly retired storage may lack a Settings binding")
  func settingsCoverLivePreferences() throws {
    let settings = Self.codeOnly(try String(contentsOf:
      PreferenceConsumerTests.preferencesDirectory.appendingPathComponent("SettingsWindow.swift"),
      encoding: .utf8))
    let retired: Set<String> = ["autoPropagateByDefault", "showsTickMarkers"]
    for name in PreferenceConsumerTests.declaredPreferences() {
      let bound = PreferenceConsumerTests.hasWordBoundedHit(settings, "$preferences.\(name)")
      #expect(bound == !retired.contains(name), "Unexpected binding status for \(name)")
    }
    #expect(!settings.contains(".din40700"))
  }

  @Test("Previously persisted DIN selection loads as the supported shaped option")
  func retiredDINSelectionMigrates() throws {
    let suite = "logisim-evolved.audit.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(["gateShape": "din40700", "showGrid": false] as [String: Any], forKey: "prefs.v1")
    let preferences = EditorPreferences.forTesting(defaults: defaults)
    #expect(preferences.gateShape == .shaped)
    #expect(preferences.showGrid == false)
  }

  @Test("The default-rate preference still does not seed a new simulation engine")
  func defaultRateIsMeasuredInert() throws {
    let suite = "logisim-evolved.audit.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = EditorPreferences.forTesting(defaults: defaults)
    func freshRate() throws -> Double {
      let host = try #require(
        try LogisimFileProjectHostFactory().makeEmptyProject() as? LogisimFileProjectHost)
      return SimulationEngine(file: host.file).snapshot.requestedTickHz
    }
    preferences.defaultTickFrequency = 1
    let before = try freshRate()
    preferences.defaultTickFrequency = 64
    #expect(try freshRate() == before)
    // This characterization belongs with the exception and must disappear when it is wired.
    #expect(EditorPreferences.preferencesPendingWiring["defaultTickFrequency"] != nil)
  }

  @Test("Changing the autosave preference changes whether a sidecar is written")
  func autosavePreferenceChangesDiskOutput() throws {
    let suite = "logisim-evolved.audit.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = EditorPreferences.forTesting(defaults: defaults)
    let scratch = PreferenceConsumerTests.sourcesRoot.deletingLastPathComponent()
      .appendingPathComponent(".preference-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }
    let controller = AutosaveController(
      subject: .init(baseURL: { scratch.appendingPathComponent("test.circ") },
        isDirty: { true }, bytes: { _ in Data("circuit".utf8) }),
      isEnabled: { preferences.autosaveEnabled },
      intervalSeconds: { preferences.autosaveIntervalSeconds })
    preferences.autosaveEnabled = false
    #expect(controller.tick() == .disabled)
    #expect(controller.writeCount == 0)
    preferences.autosaveEnabled = true
    guard case .wrote(let url) = controller.tick() else {
      Issue.record("Enabling autosave did not write a sidecar")
      return
    }
    #expect(try Data(contentsOf: url) == Data("circuit".utf8))
  }

  @Test("Wire colours ignore the value-colour preference in the reachable static renderer")
  func valueColoursDoNotReachWires() throws {
    let suite = "logisim-evolved.audit.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = EditorPreferences.forTesting(defaults: defaults)
    let circuit = try Circuit(name: "preference-wire")
    try circuit.mutatorAdd(Wire.create(
      Location.create(0, 0, hasToSnap: false), Location.create(100, 0, hasToSnap: false)))
    preferences.showsValueColours = true
    let colour = CircuitSceneSource.build(circuit: circuit, appearance: preferences.canvasAppearanceTemplate)
    preferences.showsValueColours = false
    let plain = CircuitSceneSource.build(circuit: circuit, appearance: preferences.canvasAppearanceTemplate)
    #expect(colour.scene.primitives == plain.scene.primitives)
    #expect(colour.scene.palette.entries == plain.scene.palette.entries)
  }

  @Test("The value-colour preference does change a placed constant's drawing")
  func valueColoursReachComponents() throws {
    let suite = "logisim-evolved.audit.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = EditorPreferences.forTesting(defaults: defaults)
    let circuit = try Circuit(name: "preference-constant")
    try circuit.mutatorAdd(try Constant.factory.createComponent(
      location: Location.create(100, 100, hasToSnap: false),
      attributes: Constant.factory.createAttributeSet()))
    preferences.showsValueColours = true
    let colour = CircuitSceneSource.build(circuit: circuit, appearance: preferences.canvasAppearanceTemplate)
    preferences.showsValueColours = false
    let plain = CircuitSceneSource.build(circuit: circuit, appearance: preferences.canvasAppearanceTemplate)
    #expect(colour.scene.primitives != plain.scene.primitives
      || colour.scene.palette.entries != plain.scene.palette.entries)
  }

  @Test("Gate shape changes scene primitives, not just the appearance template")
  func gateShapeChangesScene() throws {
    let suite = "logisim-evolved.audit.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = EditorPreferences.forTesting(defaults: defaults)
    let circuit = try Circuit(name: "preference-gate")
    let gate = try AndGate.factory.createComponent(
      location: Location.create(100, 100, hasToSnap: false),
      attributes: AndGate.factory.createAttributeSet())
    try circuit.mutatorAdd(gate)
    preferences.gateShape = .shaped
    let shaped = CircuitSceneSource.build(circuit: circuit, appearance: preferences.canvasAppearanceTemplate)
    preferences.gateShape = .rectangular
    let rectangular = CircuitSceneSource.build(circuit: circuit, appearance: preferences.canvasAppearanceTemplate)
    #expect(shaped.scene.primitives != rectangular.scene.primitives)
    preferences.gateShape = .din40700
    let din = CircuitSceneSource.build(circuit: circuit, appearance: preferences.canvasAppearanceTemplate)
    #expect(din.scene.primitives == shaped.scene.primitives)
  }
}
