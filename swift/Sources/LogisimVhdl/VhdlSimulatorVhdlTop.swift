// VhdlSimulatorVhdlTop: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// com/cburch/logisim/vhdl/sim/VhdlSimulatorVhdlTop.java. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore licensed
// GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── What came across, and what did not ───────────────────────────────────────────────────
//
// `VhdlSimulatorVhdlTop.generate(List<Component>)` does two separable things. The first is a
// walk over live components, `vhdlSimulator.getProject().getCircuitState().getInstanceState(
// comp)`, a downcast on the factory, a read of `VhdlEntityComponent.CONTENT_ATTR`, and it
// needs `Project`, `CircuitState` and `Component`, none of which `LogisimVhdl` can see
// (`Package.swift`: this module depends on `LogisimKernel` alone). The second is pure text
// generation from `(simulation name, ports)` pairs, and that is what this file is: the walk is
// replaced by the caller supplying `[VhdlSimulatorEntity]`.
//
// **NOT-PORTED; the file write.** Java ends by `PrintWriter`-ing the result to
// `SIM_SRC_PATH + SIM_TOP_FILENAME`, swallowing any `IOException` into a log line and leaving
// `valid` false. That is the QuestaSim/ModelSim co-simulation bridge, which D11 puts
// permanently out of scope on macOS; `HdlFile.save(_:to:)` is right there if it is ever
// revived. The `valid`/`fireInvalidated()` memoisation goes with it; it exists only to skip
// rewriting a file that is already on disk, and there is no file.
//
// ── Byte-exactness ───────────────────────────────────────────────────────────────────────
//
// The output is a generated VHDL source an external tool consumes, so it is compared
// byte-for-byte, not read for sense. `template` below is `resources/logisim/hdl/top_sim.templ`
// embedded verbatim: 869 bytes, LF line endings, and, the trap that already cost this port a
// byte once, in `VhdlContent.template`, **a trailing newline**, which a Swift `"""` literal
// does not produce. The `+ "\n"` is that newline and is load-bearing; `VhdlSimulatorTests`
// pins the byte count so it cannot go missing again. Java reads this one with
// `FileUtil.getBytes`, which (unlike `VhdlContent.loadTemplate`) copies bytes and does not
// rewrite line endings, so the resource's own bytes are the contract.

import Foundation

/// One VHDL component as the two sim-file generators need it: the name it was given for this
/// simulation run (`VhdlSimConstants.VHDL_COMPONENT_SIM_NAME + index`, assigned by
/// `VhdlSimulatorTop.generateFiles`) and its entity ports, in `VhdlContent.getPorts()` order,
/// inputs first, then outputs.
public struct VhdlSimulatorEntity: Equatable, Sendable {
  public let simulationName: String
  public let ports: [VhdlPortDescription]

  public init(simulationName: String, ports: [VhdlPortDescription]) {
    self.simulationName = simulationName
    self.ports = ports
  }
}

/// `com.cburch.logisim.vhdl.sim.VhdlSimulatorVhdlTop`, reduced to its text generation.
public enum VhdlSimulatorVhdlTop {

  /// `System.getProperty("line.separator")` on macOS.
  static let lineSeparator = "\n"

  /// The full `top_sim.vhdl` source: the template with `%date%`, `%ports%`, `%components%` and
  /// `%map%` substituted, in that order.
  ///
  /// - Parameter date: `LocaleManager.PARSER_SDF.format(new Date())`; `yyyy-MM-dd'T'HH:mm:ssZ`.
  ///   Passed in rather than read from the clock so the result is reproducible and testable;
  ///   `formattedNow()` supplies the live value.
  public static func generate(entities: [VhdlSimulatorEntity], date: String) -> String {
    var result = template
    // Java chains four `String.replaceAll` calls. `replaceAll` is regex-driven on *both* sides:
    // the pattern (`%date%` etc., which happens to be literal) and the replacement, where `$`
    // and `\` are special. Nothing generated below can contain either, VHDL identifiers are
    // `[A-Za-z_0-9]` after `VhdlParser`, and the date format has no metacharacters, so plain
    // literal replacement is equivalent, and is used because it cannot surprise.
    result = result.replacingOccurrences(of: "%date%", with: date)
    result = result.replacingOccurrences(of: "%ports%", with: portsSection(for: entities))
    result = result.replacingOccurrences(of: "%components%", with: componentsSection(for: entities))
    result = result.replacingOccurrences(of: "%map%", with: mapSection(for: entities))
    return result
  }

  /// `LocaleManager.PARSER_SDF.format(new Date())`.
  ///
  /// `SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ssZ")` with no explicit locale or zone: it formats in
  /// the *default* locale and time zone, and `Z` is RFC-822 (`+0100`), not ISO-8601 (`+01:00`).
  /// `en_US_POSIX` is forced here because a default-locale `SimpleDateFormat` in, say, a Thai
  /// locale emits Buddhist-era years: an upstream latent bug, not a behaviour worth porting
  /// into a file another program parses.
  public static func formattedNow(_ now: Date = Date()) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
    return formatter.string(from: now)
  }

  // MARK: The three generated blocks

  /// The `%ports%` block: the top entity's port list, one line per port of every component.
  ///
  /// Note `firstPort` is a *field* in Java, initialised once before the component loop and only
  /// ever cleared, so the `;` separator runs across component boundaries, unlike `firstComp`
  /// and `firstMap`, which are reset per component. That asymmetry is why this is one flat
  /// `isFirst` over the flattened port list and the other two are not.
  public static func portsSection(for entities: [VhdlSimulatorEntity]) -> String {
    var out = autogeneratedHeader()
    var isFirst = true
    for entity in entities {
      for port in entity.ports {
        if !isFirst {
          out += ";" + lineSeparator
        } else {
          isFirst = false
        }
        out += "      " + entity.simulationName + "_" + port.name + " : " + port.direction.vhdlKeyword
          + " std_logic"
        out += vectorSuffix(port)
      }
    }
    out += lineSeparator
    out += "      ---------------------------" + lineSeparator
    return out
  }

  /// The `%components%` block: a `component … end component ;` declaration per entity.
  public static func componentsSection(for entities: [VhdlSimulatorEntity]) -> String {
    var out = autogeneratedHeader()
    for entity in entities {
      out += "   component " + entity.simulationName + lineSeparator
      out += "      port (" + lineSeparator
      var isFirst = true
      for port in entity.ports {
        if !isFirst {
          out += ";" + lineSeparator
        } else {
          isFirst = false
        }
        out += "         " + port.name + " : " + port.direction.vhdlKeyword + " std_logic"
        out += vectorSuffix(port)
      }
      out += lineSeparator
      out += "      );" + lineSeparator
      out += "   end component ;" + lineSeparator
      // A line carrying three spaces and nothing else; upstream's `components.append("   ")`
      // followed by a separator. Preserved; it is part of the byte-exact output.
      out += "   " + lineSeparator
    }
    out += "   ---------------------------" + lineSeparator
    return out
  }

  /// The `%map%` block: a `port map` instantiating each entity and wiring it to the top ports.
  public static func mapSection(for entities: [VhdlSimulatorEntity]) -> String {
    var out = autogeneratedHeader()
    for entity in entities {
      out += "   " + entity.simulationName + "_map : " + entity.simulationName + " port map ("
        + lineSeparator
      var isFirst = true
      for port in entity.ports {
        if !isFirst {
          out += "," + lineSeparator
        } else {
          isFirst = false
        }
        out += "      " + port.name + " => " + entity.simulationName + "_" + port.name
      }
      out += lineSeparator
      out += "   );" + lineSeparator
      out += "   " + lineSeparator
    }
    out += "   ---------------------------" + lineSeparator
    return out
  }

  // MARK: Helpers

  /// `String.format("Autogenerated by %s --", BuildInfo.displayName)` plus a separator. The
  /// trailing `--` closes the VHDL comment the template opened with `-- %ports%`.
  private static func autogeneratedHeader() -> String {
    "Autogenerated by \(VhdlBuildInfo.displayName) --" + lineSeparator
  }

  /// `_vector(width-1 downto 0)`, for any port wider than one bit. A one-bit port stays plain
  /// `std_logic`.
  private static func vectorSuffix(_ port: VhdlPortDescription) -> String {
    let width = port.width.width
    guard width > 1 else { return "" }
    return "_vector(\(width - 1) downto 0)"
  }

  // MARK: - The template (`resources/logisim/hdl/top_sim.templ`, embedded verbatim)

  /// 869 bytes. See the file header on the trailing newline.
  public static let template = """
    --------------------------------------------------------------------------------
    -- HEIG-VD, Haute Ecole d'Ingenierie et de Gestion du canton de Vaud
    -- Institut REDS
    --
    -- Fichier :  top_sim.vhdl
    -- Auteur  :  Logisim auto-generated from top_sim.templ > reds@heig-vd.ch
    -- Date    :  %date%
    --
    --------------------------------------------------------------------------------
    -- This file has been auto-generated by Logisim, please do not modify.
    -- The top sim_file interfaces with all the VHDL components to be
    -- simulated by a single instance of the external simulator.
    --------------------------------------------------------------------------------


    library IEEE;
    use IEEE.std_logic_1164.all;
    use IEEE.numeric_std.all;

    entity top_sim is
      port(
        -- %ports%
      );
    end top_sim ;

    architecture comp of top_sim is

      -- %components%

    begin

      -- %map%

    end comp;
    """ + "\n"
}
