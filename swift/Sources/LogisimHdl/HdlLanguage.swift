// HdlLanguage: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// the `HdlType`/`VhdlKeywordsUpperCase` preferences in
// `com/cburch/logisim/prefs/AppPreferences.java`, consumed throughout
// `com/cburch/logisim/fpga/hdlgenerator/`. Copyright by the Logisim-evolution developers.
// This translation is a derivative work and is therefore licensed GPL-3.0-only. See LICENSE.md.
//
// ── Why this exists instead of a straight port of `AppPreferences` ─────────────────────────
//
// Upstream reads the current target language with a global, persisted preference:
// `AppPreferences.HdlType.get().equals(HdlGeneratorFactory.VHDL)`. `AppPreferences` is an
// application-wide singleton with 287 of 1,204 Java files depending on it (D9) and has not
// been ported; porting it is out of scope for the HDL generation framework, and depending on
// it here would pull LogisimHdl into whichever module eventually owns preferences, UI included.
//
// `HdlSettings` is the minimal seam the framework actually needs: which language to emit, and
// whether VHDL keywords render upper- or lower-case. Defaults match upstream's preference
// defaults exactly (`HdlType` defaults to VHDL, `VhdlKeywordsUpperCase` defaults to `true`), so
// behaviour is identical until something explicitly changes it. Whatever module eventually owns
// persisted preferences can back these with real storage without this module changing at all.
public enum HdlLanguage: String, Hashable, Sendable {
  case vhdl = "VHDL"
  case verilog = "Verilog"
}

/// The mutable, process-wide target-language switch every `Hdl` static function consults.
///
/// Deliberately a plain mutable global, mirroring the Java `PrefMonitor` it replaces: reading
/// and writing it has no side effects beyond the value itself, and HDL generation is expected
/// to run on a single thread (matching upstream, which drives it from Swing's EDT).
public enum HdlSettings {
  /// `AppPreferences.HdlType`. Default: VHDL, matching upstream.
  public static var language: HdlLanguage = .vhdl

  /// `AppPreferences.VhdlKeywordsUpperCase`. Default: `true`, matching upstream.
  public static var vhdlKeywordsUppercase: Bool = true
}
