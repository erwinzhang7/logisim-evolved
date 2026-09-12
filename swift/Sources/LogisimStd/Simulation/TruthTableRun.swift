// TruthTableRun.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.gui.start.TtyInterface.doTableAnalysis /
// displayTableRow / valueFormat, and com.cburch.logisim.circuit.Analyze.getPinLabels /
// toValidLabel), https://github.com/logisim-evolution/logisim-evolution. Copyright by the
// Logisim-evolution developers. This translation is a derivative work and is therefore
// GPL-3.0-only. See LICENSE.md.
// SPDX-License-Identifier: GPL-3.0-only
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── What this is for ────────────────────────────────────────────────────────────────────────
//
// This is the port of the exact code path the differential oracle runs:
//
//     java -Djava.awt.headless=true -jar logisim-evolution-4.1.0-all.jar \
//          --toplevel-circuit <name> -tty table <file.circ>
//
// (`tools/difftest/rig.py:run_java`). 1,392 golden files / 7.6M rows were generated from it and
// have never been compared against the port, because nothing could run a simulation. Producing
// this text is therefore the whole point of wiring the kernel.
//
// ── The three things that decide whether a row matches ──────────────────────────────────────
//
//  1. **Column order** is `Analyze.getPinLabels`' `TreeMap<Instance, String>(CompareVertical)`,
//     top-to-bottom, ties left-to-right, filtered to inputs first, then outputs. It is NOT the
//     order pins appear in the file.
//  2. **Column names** are the same routine's label assignment: valid user labels first (with a
//     numeric suffix on collision), then `a,b,c,…` for unlabelled inputs and `x,y,z,…` for
//     unlabelled outputs, skipping any name already taken.
//  3. **Row values** are `Value.toBinaryString()` for widths ≤ 6 and `"0x" + toHexString()`
//     above, right-aligned in a column as wide as the wider of the header and the *first* row's
//     rendering; the format strings are computed once, on the header row, and reused. A later
//     row that renders wider is simply not padded, which is upstream behaviour and is visible in
//     the golden files.
//
// …and all three of those describe the *plain* `-tty table`. The four modifiers `binary`, `hex`,
// `csv` and `tabs` change (3) and, for csv/tabs, the padding and the separator as well. See
// `TableFormat`; every claim there was measured against the jar, including two precedence rules
// and the nibble space that `binary` puts inside a CSV field.
//
// ── Deliberate divergence, one, and it is a determinism fix ─────────────────────────────────
//
// `Location.CompareVertical` breaks a final tie, same x, same y, with `a.hashCode() -
// b.hashCode()`, i.e. JVM identity hash order. Two pins at the identical location is a
// degenerate circuit, but the comparator is total in Java and must be total here. The port
// breaks that tie by the pin's position in `circuit.nonWires`, which is file order: deterministic
// across runs, where the Java is not. `docs/experiments/hashorder.md` established by experiment
// that simulation *output* does not depend on hash iteration order; this is the one place where
// upstream's column *order* could, and the port declines to reproduce it for the same reason
// D14 declines to reproduce `Location`'s cache.
//
// ── M9: why this still evaluates ONE ROW PER PROPAGATION ────────────────────────────────────
//
// The M9 plan was to bitslice: pack 64 (or, with `SIMD8<UInt64>`, 512) independent row
// assignments into the bit positions of one value, propagate once, and read 64 rows out. **That
// was investigated and rejected, and the reason is not the value representation; it is the
// component set.** Recording it here because the idea is a good one and will be had again.
//
// *The lattice bitslices, and this file already proves it.* A `Value` is three disjoint `Int64`
// planes, `error`, `unknown`, `value`, one bit per bit position, so {0,1,U,E} is two bits of
// state per lane. `Value.and`'s *wide* branch is literally a bitsliced 4-valued AND over 64
// independent lanes (`Value.swift:592-601`), as are `or`, `xor` and `not`. So "X/Z are not one
// bit" is **not** the obstacle: they are two, they are already planar, and every gate in the
// tree already evaluates 64 of them at once.
//
// *What does not bitslice is everything that is not a gate.* Bitslicing rows means re-expressing
// every component's transfer function lane-wise, i.e. as a boolean network: an adder's carry
// chain, a multiplexer's select decode, a comparator, a shifter, a ROM address lookup. Measured
// over the corpus that this file's golden gate scores (446 distinct `.circ` files, 40,569 `<comp>`
// placements): **21.5% of placements are not gates or wiring primitives**, and only 200 of the
// 1,282 attempted oracles (16%) consist purely of gates, wiring primitives and subcircuits. Of
// the 109 oracles the gate skips for size, the ones bitslicing was meant to unblock, **8 (7%)
// are pure-gate and 90 (83%) contain at least one sequential component** (1,238 `Register`, 127
// `RAM`, 127 `Clock`, 128 `Counter` placements). So the win does not generalise; it would apply
// to a sixth of the cases that already run fastest and almost none of the cases that are slow.
//
// Three further obstacles, each fatal on its own:
//
//   1. **Per-lane state.** `Register`, `RAM`, `ROM` and `Counter` hold `componentData` per
//      `CircuitState`. Sixty-four lanes need sixty-four copies of every memory, so the sharing
//      that made the pass cheap is gone exactly where the circuits are big.
//   2. **The schedule is per-propagation, not per-lane.** `Propagator.propagate` runs an event
//      queue to a fixed point and reports `isOscillating` for the *whole* propagation; the loop
//      below then replaces **every** output column of that row with `Value.createError(width)`.
//      Under one shared schedule for 64 lanes, oscillation stops being a per-row property: you
//      either poison 64 rows because one oscillated (wrong output) or track convergence per lane
//      , and once the queue is per-lane, "propagate once for 64 rows" is no longer what is
//      happening.
//   3. **It is a second implementation of every component.** This port's entire contract is
//      bug-for-bug reproduction of 4.1.0, down to Java's masked shift distances and
//      `Value.and`'s unmasked-plane quirk. A lane-parallel re-derivation of each component is a
//      second implementation of rules that already exist once, and two implementations of one
//      rule drift apart; the failure mode `TableFormat` below is annotated against.
//
// **What was kept.** The one place bitslicing *is* sound is building the input vector: the input
// assignment for a row is `w` known bits with no U and no E, so it is a single `value` plane and
// needs no per-bit `Value` array at all. `inputPlane` below packs it directly. That is the whole
// of the idea that survives contact with this component set.
//
// **Where the time actually goes** (measured, `2.7.1__case-438.circ::CPU`, 2,048
// rows, debug build): 212.7 s, i.e. **9.6 rows/s**, at 20 propagation iterations per row:
// *not* oscillating, so the oscillation cap is not the cost. A `sample(1)` of that run puts the
// weight in `InstanceStateImpl.end(at:)` → `SimulatableComponent.wireEnds`, which **rebuilds and
// discards a fresh `[WireEndInfo]` array on every single port read and write**. That is a defect
// in `LogisimKernel/Propagation/InstanceStateImpl.swift` + `LogisimStd/Simulation/
// ComponentSimulationSeams.swift`, not in this file, and it is reported rather than fixed here.
// It is also the reason the row cap has not moved: no evaluation strategy this file can choose
// gets past an O(ports²) allocation in the layer below it.

import Foundation
import LogisimFile
import LogisimKernel

/// The port of `TtyInterface`'s `-tty table` path.
public enum TruthTableRun {

  // MARK: - Errors

  public enum Failure: Error, CustomStringConvertible {
    /// The named circuit is not in the file. Upstream's `file.getCircuit(name)` returns `null`
    /// and it NPEs; a `throw` is D13's answer.
    case noSuchCircuit(String)

    public var description: String {
      switch self {
      case let .noSuchCircuit(name): return "no circuit named \(name)"
      }
    }
  }

  // MARK: - Pin labelling (Analyze.getPinLabels)

  /// One column of the table.
  public struct PinColumn {
    public let component: any Component
    public let label: String
    public let isInput: Bool
    public let width: BitWidth
  }

  /// `Analyze.getPinLabels(Circuit)`, restricted to what the table path uses.
  ///
  /// Upstream sources its pins from `circuit.getAppearance().getPortOffsets(Direction.EAST)
  /// .values()`. `CircuitAppearance` is not ported, but for this call it does not matter: for a
  /// circuit with a default appearance the port set *is* the circuit's `Pin` components, and
  /// `getPinLabels` immediately re-sorts whatever it is given into a
  /// `TreeMap<Instance, String>(Location.CompareVertical)`, so the appearance contributes
  /// membership and nothing else. A **custom** `<appear>` can omit a pin from the ports, and that
  /// case is not reproduced; see the report; it needs `CircuitAppearance`, which is M6.
  public static func pinColumns(of circuit: Circuit) -> [PinColumn] {
    // Membership: every Pin component.
    var pins: [(component: any Component, fileIndex: Int)] = []
    for (index, component) in circuit.nonWires.enumerated() where component.factory is Pin {
      pins.append((component, index))
    }

    // `new TreeMap<Instance, String>(Location.CompareVertical)`: top before bottom, ties left
    // before right, final tie by file order rather than identity hash (see the file header).
    pins.sort { a, b in
      let la = a.component.location
      let lb = b.component.location
      if la.y != lb.y { return la.y < lb.y }
      if la.x != lb.x { return la.x < lb.x }
      return a.fileIndex < b.fileIndex
    }

    var labels: [String?] = Array(repeating: nil, count: pins.count)
    var labelsTaken: Set<String> = []

    // "Process first the pins that the user has given labels."
    for (i, pin) in pins.enumerated() {
      guard var label = toValidLabel(pin.component.attributeSet[StdAttr.label]) else { continue }
      if labelsTaken.contains(label) {
        var n = 2
        while labelsTaken.contains("\(label)\(n)") { n += 1 }
        label = "\(label)\(n)"
      }
      labels[i] = label
      labelsTaken.insert(label)
    }

    // "Now process the unlabeled pins."
    //
    // The two default lists are `S.get("defaultInputLabels")` / `"defaultOutputLabels"`, with a
    // hard-coded fallback used whenever the localised string contains no comma. Localisation
    // does not come across (D5's note on `Attribute`), and the English resource is exactly these
    // two strings, so the fallback *is* the behaviour for the oracle's default locale.
    let inputDefaults = ["a", "b", "c", "d", "e", "f", "g", "h"]
    let outputDefaults = ["x", "y", "z", "u", "v", "w", "s", "t"]
    for (i, pin) in pins.enumerated() where labels[i] == nil {
      let isInput = Pin.isInputPin(pin.component.attributeSet)
      let options = isInput ? inputDefaults : outputDefaults
      var label = options.first { !labelsTaken.contains($0) }
      if label == nil {
        // Upstream: "an extreme measure that should never happen".
        var n = 1
        repeat {
          n += 1
          label = "x\(n)"
        } while labelsTaken.contains(label!)
      }
      labels[i] = label
      labelsTaken.insert(label!)
    }

    return pins.enumerated().map { i, pin in
      PinColumn(
        component: pin.component,
        label: labels[i] ?? "",
        isInput: Pin.isInputPin(pin.component.attributeSet),
        width: Pin.getWidth(pin.component.attributeSet))
    }
  }

  /// `Analyze.toValidLabel(String)`.
  ///
  /// `Character.isJavaIdentifierStart` / `isJavaIdentifierPart` are approximated by their ASCII
  /// core plus `_` and `$`, which is total for every label in the corpus. A label whose only
  /// identifier characters are non-ASCII letters would be dropped here and kept by Java; that is
  /// recorded rather than papered over, because it changes a column *name* and would show up as
  /// a whole-file diff rather than a subtle one.
  static func toValidLabel(_ label: String?) -> String? {
    guard let label else { return nil }
    var ret = ""
    var end = ""
    var afterWhitespace = false
    for character in label {
      if isIdentifierStart(character) {
        if afterWhitespace {
          // "capitalize words after the first one"
          ret.append(contentsOf: character.uppercased())
          afterWhitespace = false
        } else {
          ret.append(character)
        }
      } else if isIdentifierPart(character) {
        // "If we can't place it at the start, we'll dump it onto the end."
        if !ret.isEmpty { ret.append(character) } else { end.append(character) }
        afterWhitespace = false
      } else if character.isWhitespace {
        afterWhitespace = true
      }
      // "just ignore any other characters"
    }
    if !end.isEmpty && !ret.isEmpty { ret += end }
    return ret.isEmpty ? nil : ret
  }

  private static func isIdentifierStart(_ c: Character) -> Bool {
    c.isLetter || c == "_" || c == "$"
  }

  private static func isIdentifierPart(_ c: Character) -> Bool {
    isIdentifierStart(c) || c.isNumber
  }

  // MARK: - The four table modifiers (FORMAT_TABLE_BIN / _HEX / _CSV / _TABBED)

  /// Upstream's four `-tty` table modifiers, resolved into the two independent choices they
  /// actually make.
  ///
  /// ── The outgoing note said "one `switch` inside `valueFormat`". IT IS NOT ─────────────────
  ///
  /// That was checked before being believed, and it is half right. `binary` and `hex` are indeed
  /// `valueFormat` (`TtyInterface.java:189-200`). **`csv` and `tabs` are not in `valueFormat` at
  /// all**: they live in `displayTableRow` (`:158-186`) and change *two* things there:
  ///
  ///   * the column separator: `"\t"` for tabs, `","` for csv, `" "` otherwise; and
  ///   * the per-column format string: `"%s"` for BOTH tabs and csv, versus `"%" + w + "s"` for
  ///     the pretty form. **So a csv/tabs table is not padded at all**, and the width
  ///     computation that the pretty path performs on the header row is skipped entirely.
  ///
  /// An implementation that only touched `valueFormat` would emit space-separated, padded rows
  /// for `-tty table,csv` and every row would differ from the jar.
  ///
  /// ── Precedence, measured rather than read ─────────────────────────────────────────────────
  ///
  /// Upstream ORs the bits together and then tests them in a fixed order, so asking for two
  /// modifiers of the same kind is not an error; one silently wins. Measured on `wide.circ`
  /// (two 7-bit columns, so every style is distinguishable) against the 4.1.0 jar:
  ///
  ///     -tty table,csv,tabs      ->  TAB separated   (TABBED is tested first, :160)
  ///     -tty table,binary,hex    ->  binary          (BIN is tested first, :190)
  ///
  /// Both are reproduced below by resolving in the same order.
  public struct TableFormat: Equatable, Sendable {

    /// How a single `Value` is rendered. `TtyInterface.valueFormat(Value, int)`.
    public enum ValueStyle: Equatable, Sendable {
      /// No modifier: "under 6 bits or less in binary, no spaces; otherwise in hex, with prefix".
      case pretty
      /// `binary`: `FORMAT_TABLE_BIN`, which is **`Value.toString()`**, not `toBinaryString()`.
      ///
      /// THE DIFFERENCE IS A SPACE EVERY FOUR BITS. `Value.toString()` appends `" "` after each
      /// nibble boundary (`Value.java:771-784`); `toBinaryString()` does not (`:561-579`).
      /// Measured: `-tty table,binary` on a 7-bit column prints `000 0000`, and
      /// `-tty table,csv,binary` prints `0,000 0000,0,000 0000`; an embedded space inside an
      /// unquoted CSV field. That is upstream, it is reproduced exactly, and it is safe for CSV
      /// only because no rendering upstream can emit a comma (space, hex digits, and the four
      /// display characters are the whole alphabet).
      case binary
      /// `hex`: `FORMAT_TABLE_HEX`: `toHexString()` with **no `0x` prefix**, at every width.
      case hex
    }

    /// How columns are joined, and whether they are padded at all.
    /// `TtyInterface.displayTableRow(:158-186)`.
    public enum Separator: Equatable, Sendable {
      /// No modifier: a single space, with each column right-aligned to a width fixed on the
      /// header row.
      case spaces
      /// `tabs`: `FORMAT_TABLE_TABBED`: `"\t"`, and `"%s"` per column, i.e. **no padding**.
      case tabs
      /// `csv`: `FORMAT_TABLE_CSV`: `","`, and `"%s"` per column, i.e. **no padding**.
      case csv
    }

    public var values: ValueStyle
    public var separator: Separator

    public init(values: ValueStyle = .pretty, separator: Separator = .spaces) {
      self.values = values
      self.separator = separator
    }

    /// Plain `-tty table`.
    public static let `default` = TableFormat()

    /// Resolve a set of modifier names in upstream's own test order, so two modifiers of the
    /// same kind pick the same winner the jar picks. Unknown names are ignored here: the CLI
    /// refuses them long before this point, and duplicating that refusal in two places is how
    /// two implementations of one rule drift apart.
    public init(modifiers: Set<String>) {
      // `:190` tests BIN before HEX.
      let values: ValueStyle =
        modifiers.contains("binary") ? .binary : (modifiers.contains("hex") ? .hex : .pretty)
      // `:160` tests TABBED before CSV.
      let separator: Separator =
        modifiers.contains("tabs") ? .tabs : (modifiers.contains("csv") ? .csv : .spaces)
      self.init(values: values, separator: separator)
    }

    /// The literal string joined between columns.
    var separatorText: String {
      switch separator {
      case .spaces: return " "
      case .tabs: return "\t"
      case .csv: return ","
      }
    }

    /// Whether columns are right-aligned to a fixed width. False for csv and tabs, which use
    /// `"%s"`; this is the half of the behaviour that does not live in `valueFormat`.
    var pads: Bool { separator == .spaces }
  }

  // MARK: - Value rendering (TtyInterface.valueFormat)

  /// `valueFormat(Value, int)`.
  ///
  /// The no-argument overload below keeps the plain `-tty table` call sites (and the golden
  /// suite) reading exactly as they did.
  public static func valueFormat(_ value: Value, _ format: TableFormat) -> String {
    switch format.values {
    case .binary:
      // `v.toString()`; `toDisplayString` is this port's name for it, and it is the one with
      // the nibble spacing. See `ValueStyle.binary`.
      return value.toDisplayString()
    case .hex:
      return value.toHexString()
    case .pretty:
      return value.width <= 6 ? value.toBinaryString() : "0x" + value.toHexString()
    }
  }

  /// `valueFormat(Value, int)` for the plain `-tty table` format (no `bin`/`hex`/`csv`/`tabbed`
  /// modifier): *"under 6 bits or less in binary, no spaces; otherwise in hex, with prefix"*.
  public static func valueFormat(_ value: Value) -> String {
    valueFormat(value, .default)
  }

  // MARK: - doTableAnalysis

  /// `TtyInterface.doTableAnalysis(Project, Circuit, Map<Instance,String>, int)`.
  ///
  /// Returns the text upstream prints to stdout, newline-terminated, so a caller can compare it
  /// byte-for-byte against a golden file.
  ///
  /// **A fresh root `CircuitState` per row is upstream's design, not an oversight**; see the
  /// loop. It is what makes the table combinational: no state survives from one input
  /// combination to the next, which is also why a sequential circuit produces a table that says
  /// nothing useful and why the golden generator classified those files as `sequential/timeout`.
  public static func run(
    circuit: Circuit, session: SimulationSession, format: TableFormat = .default
  ) throws -> String {
    let columns = pinColumns(of: circuit)
    let inputs = columns.filter(\.isInput)
    let outputs = columns.filter { !$0.isInput }

    // `inputCount` is the number of input *bits*, summed over the input pins' widths: upstream
    // builds a `Var(name, width)` per pin and counts the names it yields.
    let inputCount = inputs.reduce(0) { $0 + $1.width.width }

    // `final var rowCount = 1 << inputCount;`: **Java `int` semantics, and they are load-bearing
    // here rather than pedantic.**
    //
    // 138 corpus oracles have more than 31 input bits (up to 74). The port originally threw on
    // them, reasoning that `1 << 66` cannot mean anything. Java disagrees: `<<` masks the shift
    // distance to the low 5 bits, so `1 << 66` is `1 << 2` = 4, and upstream cheerfully emits a
    // 4-row "truth table" for a 66-input circuit. Those goldens are not degenerate files the rig
    // failed to filter; they are what the oracle actually printed, and refusing to run them
    // meant scoring the port against a behaviour it had declined to reproduce.
    //
    // Two consequences follow from the same masking and are handled by construction:
    //   * `inputCount & 31 == 31` makes `rowCount` **negative** (`1 << 31` = `Int32.min`), so
    //     Java's `for (i = 0; i < rowCount; i++)` runs zero times and prints *nothing at all*:
    //     not even a header, since `needTableHeader` is only consulted inside the loop. The
    //     `0..<max(0, rowCount)` below reproduces that exactly. (`rig.py` discards outputs of two
    //     lines or fewer as "empty", which is why no such golden exists to compare against.)
    //   * the bit test inside the loop masks its own shift distance for the same reason.
    let rowCount = Int(Int32(truncatingIfNeeded: 1 << Int32(inputCount & 31)))

    // Headers: input pins first, then output pins: a second pass over the same sorted map, not
    // a re-sort, so within each group the vertical order is preserved.
    let ordered = inputs + outputs
    let headers = ordered.map(\.label)

    var out = ""
    var formats: [Int] = []  // column widths; computed once, on the header row
    var needTableHeader = true

    for row in 0..<max(0, rowCount) {
      // "final var circuitState = CircuitState.createRootState(proj, circuit, currentThread())"
      // , inside the loop.
      let circuitState = session.createRootState(for: circuit)
      let propagator = circuitState.propagator

      // One slot per column, in `ordered`'s order. This used to be a
      // `[ObjectIdentifier: Value]` built and thrown away per row, then read back once per
      // column: a dictionary keyed on identity to recover an ordering the loop already knows.
      // Indexing directly is the same values in the same order with no hashing.
      var current = [Value](repeating: .nilValue, count: ordered.count)

      var incol = 0
      for (index, pin) in inputs.enumerated() {
        let value = Value.create(
          width: pin.width.width,
          error: 0,
          unknown: 0,
          value: inputPlane(
            row: row, width: pin.width.width, firstColumn: &incol, inputCount: inputCount))
        // `Pin.FACTORY.driveInputPin(pinState, v)`; the unvalidated reusable instance state is
        // what upstream's `getInstanceState(Instance)` overload hands back.
        if let simComponent = pin.component as? any SimComponent,
          let state = circuitState.unvalidatedReusableInstanceState(for: simComponent)
            as? InstanceStateImpl
        {
          Pin.driveInputPin(state, value)
        }
        current[index] = value
      }

      _ = try propagator.propagate()

      for (offset, pin) in outputs.enumerated() {
        let index = inputs.count + offset
        if propagator.isOscillating {
          // "valueMap.put(pin, Value.createError(width))"
          current[index] = Value.createError(pin.width)
        } else if let simComponent = pin.component as? any SimComponent,
          let state = circuitState.unvalidatedReusableInstanceState(for: simComponent)
            as? InstanceStateImpl
        {
          current[index] = Pin.getValue(state)
        }
      }

      if needTableHeader {
        // `int w = headers.get(i).length(); w = max(w, valueFormat(curOutputs.get(i)).length());`
        //
        // …but ONLY on the pretty path. For csv and tabs upstream pushes `"%s"` instead, so no
        // width is computed and nothing is padded (`:166-167`). Reproduced by leaving `formats`
        // at zero, which `pad` treats as "wide enough already".
        formats = headers.enumerated().map { i, header in
          format.pads ? max(header.count, valueFormat(current[i], format).count) : 0
        }
        out +=
          zip(headers, formats).map { pad($0, to: $1) }
          .joined(separator: format.separatorText) + "\n"
        needTableHeader = false
      }
      out +=
        zip(current, formats).map { pad(valueFormat($0, format), to: $1) }
        .joined(separator: format.separatorText) + "\n"
    }

    return out
  }

  /// The `value` plane of one input pin's assignment for `row`; the surviving piece of M9.
  ///
  /// This is `TruthTable.isInputSet(idx, col, inputs)`, `(idx & (1 << (inputs - col - 1))) != 0`
  /// (`TruthTable.java:296-298`), run once per bit of the pin and **packed straight into the
  /// bit positions of an `Int64`** instead of into a `[Value]` that `Value.create(_:)` would
  /// immediately re-pack bit by bit. Same bits, same order, one pass and no allocation.
  ///
  /// It is sound here and nowhere else in the evaluation: a row's input assignment is `width`
  /// *known* bits, never `U` and never `E`, so the `error` and `unknown` planes are identically
  /// zero and the whole assignment is one plane. The moment a value can be unknown, which is
  /// every net downstream of these pins, packing rows into bit positions stops being a
  /// re-encoding and starts being a re-implementation. See the file header.
  ///
  /// **The masked shift is upstream's and is load-bearing** (see `rowCount`). `distance` is
  /// `& 31`, so past 31 input bits distinct columns alias onto the same bit of `row` and the
  /// table upstream prints is the aliased one. `mask` is deliberately computed through `Int32`
  /// so that `distance == 31` yields `Int32.min`, exactly as Java's `int` shift does.
  ///
  /// `firstColumn` is `inout` because the columns of successive pins are consecutive: the caller
  /// walks one running counter across all input pins, as upstream's flattened `Var` list does.
  ///
  /// Bit `width - 1` (the pin's most significant bit) takes the *first* of the pin's columns,
  /// which is why the loop counts down.
  ///
  /// Internal rather than private so `TruthTableBitsliceTests` can hold the `[Value]` form this
  /// replaced as a reference oracle and assert the two agree bit for bit. A packing this
  /// quirk-laden is not something to check by reading.
  static func inputPlane(
    row: Int, width: Int, firstColumn incol: inout Int, inputCount: Int
  ) -> Int64 {
    var plane: Int64 = 0
    for b in stride(from: width - 1, through: 0, by: -1) {
      let distance = Int32((inputCount - incol - 1) & 31)
      let mask = Int(Int32(truncatingIfNeeded: 1 << distance))
      if (row & mask) != 0 { plane |= Int64(1) << Int64(b) }
      incol += 1
    }
    return plane
  }

  /// `System.out.printf("%<w>s", s)`: right-align, and **do not truncate** when the string is
  /// wider than the field. Java's `%Ns` is a minimum width, which is why a late row that renders
  /// wider than the first simply pushes the row out.
  private static func pad(_ s: String, to width: Int) -> String {
    s.count >= width ? s : String(repeating: " ", count: width - s.count) + s
  }

  // MARK: - Entry point

  /// The whole of `--toplevel-circuit <name> -tty table <file>`, from a loaded file.
  ///
  /// `circuitName` is `Startup.getCircuitToTest()`: when it is `nil` or empty, upstream uses
  /// `file.getMainCircuit()`.
  public static func run(
    file: LogisimFile,
    circuitName: String?,
    format: TableFormat = .default,
    thread: Thread? = nil
  ) throws -> String {
    let circuit: Circuit?
    if let circuitName, !circuitName.isEmpty {
      circuit = file.circuit(named: circuitName)
    } else {
      circuit = file.mainCircuit
    }
    guard let circuit else { throw Failure.noSuchCircuit(circuitName ?? "<main>") }
    let session = SimulationSession(file: file, thread: thread)
    return try run(circuit: circuit, session: session, format: format)
  }
}
