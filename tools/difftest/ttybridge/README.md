# ttybridge — oracles and gates for `logisim-cli`'s verification path

Upstream issue #1546 asks for a usable command-line verification path. This directory holds the
Java-side oracles and the Python gates for the two formats the port added for it, plus the
probes whose results decided what NOT to port.

Everything here takes the corpus path from `LOGISIM_CORPUS`. The corpus and its golden outputs
are deliberately outside this repo; they derive from private coursework and the golden tables
are effectively lab solutions.

## Gates

| command | what it proves | last reading |
|---|---|---|
| `statsgate.py` | `--tty stats` byte-matches the jar | 1,728 pass / 7 fail of 1,735, 52 excluded |
| `statsgate.py --selfcheck --write-nondet …` | which cases the JAR cannot reproduce against itself | 52 of 157 |
| `tablefmtgate.py` | `--tty table` + `binary`/`hex`/`csv`/`tabs` byte-match the jar | 800 pass / 0 fail, 100 per format (`--scope root`) |
| `tablefmtgate.py --selfcheck` | whether the JAR reproduces itself here | 840 stable / 16 timeout / **0 DIFFERS** |
| `tablefmtgate.py --probe-divergences` | re-measures the two upstream behaviours the port declines to copy | both still hold |
| `vectorgate.py` | `--test-vector` stdout byte-matches the bridge | 62 byte-exact / 0 fail, 580 setup-refusals agreeing |
| `namediff.py` | classifies statsgate's failures | 0 name divergences left; 12 rows NFC/NFD, 1 missing subcircuit row |
| `normcheck.py` | why two identical-looking rows differ | NFC (Java) vs NFD (Swift `URL.lastPathComponent`) |

```sh
LOGISIM_CORPUS=/path/to/corpus python3 statsgate.py --regenerate
LOGISIM_CORPUS=/path/to/corpus python3 statsgate.py
LOGISIM_CORPUS=/path/to/corpus python3 tablefmtgate.py --regenerate
LOGISIM_CORPUS=/path/to/corpus python3 tablefmtgate.py
LOGISIM_CORPUS=/path/to/corpus python3 vectorgate.py
```

Every gate refuses to report a number when `logisim-cli` is not built, rather than scoring every
case as a failure. `statsgate.py`'s first run did exactly that; an off-by-one in its own
`REPO` path produced a confident `pass 0 / fail 1787`.

### `tablefmtgate.py` — the table modifiers

Eight format strings per (file, circuit), chosen so that each decision is independently
observable: `table` (the control, also gated corpus-wide by `rig.py`), the four modifiers alone,
`table,csv,binary` (a space inside a CSV field), and the two precedence pairs. It reports
**per-format** pass/fail as well as a total, a total alone lets three modifiers carry a fourth
that is entirely broken, and a format that contributes zero cases is a red gate, not agreement.

The regeneration is `8 ×` the plain-table one, so it is the slowest thing in this directory:
about **nine hours** over the whole corpus at ~20 oracles/minute. `--scope root` (the default,
the 17 CSC258 corpus-root files: 100 circuits, 800 oracles, ~15 min) is the named slice;
`--scope all` adds `harvested/` and writes to its own golden directory so the two can never be
compared against each other.

**Can it fail?** Measured over the full default scope with two injected defects. A CLI that
writes nothing and exits 0 scores `0 pass / 8 fail`. A CLI that *ignores every modifier* and
always prints the plain table scores `297 / 503`, and the split says how much of the corpus can
see each modifier at all:

| format | pass / fail under the modifier-ignoring CLI | what it needs to discriminate |
|---|---|---|
| `table` | 100 / 0 | the control: correctly unaffected |
| `table,csv` · `,tabs` · `,csv,binary` · `,csv,tabs` | 0 / 100 | any table with ≥2 columns |
| `table,hex` | 49 / 51 | a pin of width ≥ 2 |
| `table,binary` · `table,binary,hex` | 74 / 26 | a pin of width > 6 |

So 26 of 100 root circuits can detect a broken `binary` and 51 can detect a broken `hex`. That is
real but not universal coverage, and it is why `CliTableFormatTests` pins the value styles on a
hand-built 7-bit fixture and asserts explicitly that a 1-bit fixture *cannot* discriminate.

Three facts it pins, each measured against the jar rather than read off the Java:

* `FORMAT_TABLE_BIN` is **`Value.toString()`**, not `toBinaryString()`: a space every four
  bits, so a 7-bit column prints `000 0000`, and `table,csv,binary` prints `0,000 0000`. That is
  a space inside an unquoted CSV field; it stays parseable only because nothing upstream can
  render a comma.
* `csv`/`tabs` are **not** in `valueFormat` at all. They change the separator *and* the
  per-column format string (`"%s"` instead of `"%<w>s"`), so a csv table is **unpadded**. An
  implementation that only touched `valueFormat` differs on every row.
* Precedence: `tabs` beats `csv` (`TtyInterface:160`), `binary` beats `hex` (`:190`).

A circuit with **no pins** makes the jar print exactly `"\n\n"` and exit 0; the port prints the
identical two bytes. 20 such captures exist in the `^lab` slice. They are excluded from the
golden set, the same call `rig.py` makes when it discards outputs of two lines or fewer.

## Why one format needs a bridge and the other does not

`Startup.parseArgs` sets `Main.headless = true` for any `-t`/`--tty` invocation
(`Startup.java:357-360`), so **`-tty stats` already runs dialog-free in the shipped jar** and
the oracle is the jar itself, invoked exactly as a user would.

`--test-vector` does **not** set it. It takes the GUI branch of `Startup.run()`, throws, and
`Main`'s `catch (Throwable)` then throws a *second* `HeadlessException` out of its own first
statement (`OptionPane.showMessageDialog`), so the `System.exit(100)` below never runs and the
JVM dies with 1 having printed nothing. `TestVectorBridge.java` applies D17's switch and reaches
the same `ProjectActions.doOpenNoWindow` + `Project.doTestVector`, which runs to completion.

## The probes, and the decision they settled

`speed` and `halt` are **not ported**, on measurement rather than taste:

* `find_halt.py`: `TtyInterface.run` routes to `runSimulation` only for a circuit with an
  output pin labelled exactly `halt`; without one the loop has no exit but an oscillation.
  Across 591 parseable corpus files: **8 pins labelled `halt`, 6 of them outputs.**
* `probe_halt.py`; runs the jar on all 6. **Four fail to load** (each needs a sibling `.circ`
  the harvest did not capture, so the jar tries to open a `JFileChooser` and dies with
  `HeadlessException`), **two do not terminate in 40 s.** Zero produce output.
* `probe.py`: a bounded single invocation, since macOS has no `timeout(1)`. `-tty speed` on
  `golden-15.circ` printed nothing and was still running when killed at 15 s.

So there is not one corpus case against which a `speed` or `halt` implementation could be
diffed. `speed` additionally reports wall-clock Hz, which is not byte-comparable against
anything.

## The two deliberate divergences, and how to re-measure them

`tablefmtgate.py --probe-divergences` re-runs both against the jar on a self-contained fixture,
and reports a *failure* if upstream has changed; the point being that a claim about upstream
must not quietly stop being true. Both are also recorded in `logisim-cli/main.swift`'s exit-code
contract.

1. **A bare modifier hangs upstream.** `-tty csv` sets `FORMAT_TABLE_CSV` and no `FORMAT_TABLE`
   bit, so `format == 0` does not fire and control reaches `runSimulation`, whose `while (true)`
   has no exit without a `halt` pin. Measured with a 20 s cap: `csv`, `tabs`, `binary` and `hex`
   were all killed having printed nothing, and `stats,csv` printed the stats and then hung. The
   port exits 2 and names the spelling that works.
2. **A loader error over 60 characters is dropped.** `Loader.showError` wraps long text in a
   `JScrollPane` and `OptionPane`'s headless arm logs only `String`s, so the message is lost.
   `The built-in library “Risc-V” is not available in this version.` is 63 characters. Three
   measurements, all exit 0: the 35-char `Unrecognized library descriptor bogus` **is** logged,
   the 63-char one is **not**, and the three-line pre-2.7.2 notice **is**; because its call site
   passes a plain `String`. The suppression is about the argument's type, not length as such, and
   the class it suppresses is the one that costs the user components (D8). The port prints every
   recorded diagnostic on stderr, with the exit code and stdout unchanged.

## Traps recorded here because each one cost a wrong reading

* **`subprocess(text=True)` translates newlines.** Upstream's per-row progress counter is
  `System.out.print((row + 1) + " \r")`. In text mode Python rewrote the CLI's `\r` to `\n`
  while the oracle arrived base64'd and untranslated, so `vectorgate.py`'s first run reported
  every case as differing while all the values matched. Compare as bytes.
* **`harvested/2.7.1__case-169.circ` declares `<circuit name="decoder">` twice**
  (lines 548 and 1179). A regex-built job list yields one identical job twice, and a collision
  preflight then aborts the whole run. `rig.py` builds its list the same way and has the same
  preflight, so `rig.py --regenerate` over the full corpus aborts today for this reason.
* **Empty compares equal to empty.** `is_stats_shaped` is applied to the oracle *and* to the
  port, and `--regenerate` refuses to write a capture that fails it, so a run that produced
  nothing can never be scored as agreement.
