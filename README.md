# logisim-evolved

> **This is a modified version.** `logisim-evolved` is not logisim-evolution. It is a modified
> version of [logisim-evolution](https://github.com/logisim-evolution/logisim-evolution) **4.1.0**,
> rewritten in Swift as a native macOS application. Modification began on **4 September 2026** and
> is ongoing.
>
> It is neither endorsed by nor affiliated with the logisim-evolution project or its developers.
> Please do not report bugs in this port to them; bugs here are mine, not theirs.
>
> Licence: **GPL-3.0-only**, the full text in [`LICENSE.md`](LICENSE.md) and the complete notice
> set in [`NOTICE.md`](NOTICE.md). **ABSOLUTELY NO WARRANTY**; see sections 15 and 16.
>
> *(GNU GPL version 3, section 5(a): prominent notice of modification, carrying a relevant date.)*

The digital logic simulator used to teach introductory computer organisation, rebuilt as a native
macOS application. Same file format, same components, same results; a different program underneath.

Every number below was measured on this machine, and each one is recorded next to the decision
that explains it, in `docs/decisions.md`. Tests assert the behaviour; a few of the comparative
benchmarks against the Java were one-off measurements and are cited as such rather than
re-run by `swift test`. Where something is not done, it says so.

## The simulation clock keeps real time

Upstream schedules the next tick as `lastTick + period`, where `lastTick` is assigned the moment
the loop *noticed* the deadline had passed, after propagation finished. Error is absorbed
permanently and propagation cost is added to the period every cycle, so the clock drifts away from
wall time and never comes back. Within 1 ms of a deadline it busy-spins a core. Its rate readout
then reports the *requested* frequency whenever it cannot compute a real one, which hides all of
this from you.

This port computes `deadline(n) = t0 + n × period` from a fixed origin and waits with
`mach_wait_until` on a time-constraint thread, so propagation cost never shifts the schedule.

Same machine, same workload, same seed; only the algorithm differs:

| tick rate | drift, upstream | drift, here | jitter, upstream | jitter, here | CPU, upstream | CPU, here |
| --- | --- | --- | --- | --- | --- | --- |
| 1 Hz, 2 ms propagation | 80.3 ms | **3.6 µs** | 24.1 ms | **3.2 µs** | 0.2% | 0.2% |
| 100 Hz | 8.71 ms | **1.2 µs** | 2.52 ms | **2.6 µs** | 9.9% | 9.9% |
| 10 kHz | 7.22 ms | **251 µs** | 3.07 ms | **3.4 µs** | **99.6%** | **22.8%** |

At 10 kHz upstream saturates a core. This does the same work at 22.8%.

The rate readout reports what was *achieved*, with measured jitter, and says so when the target
cannot be met. It never substitutes the number you asked for.

## The canvas is a renderer, not a repaint loop

Components emit typed primitives into a retained scene with a per-instance colour index. They never
touch a graphics context. That indirection is the load-bearing design decision: every ported
component painter is written against it, **75 `paintInstance` implementations across 65
component files**, so the backend can change without touching any of them.

Measured: **2.03 ms per frame at 5,000 components**, with viewport culling and rectangle
invalidation.

What upstream does per frame and this does not: a `Graphics2D` clone per component (about 5,001
clones per frame at 5,000 components, counting the frame's own), no viewport culling, no spatial
index, full text re-shaping on every label with the first line measured twice, and a fresh stroke
object per width change across 253 call sites (counted by disassembling the shipped jar). Its
20 fps cap is not a tuning constant; it is a defence against a frame costing time
proportional to the whole circuit.

**Metal is not here yet.** The scene API exists so that it can be, and the schematic is a textbook
case for it: static integer-grid geometry whose only per-frame delta is a small colour palette. The
current backend is Core Graphics with culling, cached text shaping and no per-component context
clone, which already beats the Java comfortably. Claiming a GPU backend that has not shipped would
be the sort of thing this README is trying not to do.

## It behaves like a Mac application

- **The camera is unbounded.** Continuous pinch zoom anchored on the pointer, trackpad panning that
  maps one to one at any zoom, and no scroll region to fall off the edge of. Upstream entangles
  zoom with the scroll pane's preferred size, which is why its zoom anchor drifts and you cannot
  place a component to the left of the leftmost one; five years open as issue #1262, closed here
  with six tests.
- **No firewall prompt on launch.** Measured on the running application: zero network file
  descriptors at startup. Upstream has shown that prompt for five years as issue #747. The one
  component that can open a listening socket is the Telnet terminal, and only once a circuit
  actually uses it.
- **Document-based**, with autosave, a saved/unsaved indicator in the title, and the standard Open
  Recent and version behaviours you expect from a Mac app.
- **A real Settings window**, light and dark appearance, gate shape, grid, and simulation
  preferences.
- **The colour palette is per-frame data**, not compile-time constants. Upstream freezes its value
  colours into static fields at class-init, so a theme change cannot reach them. Here re-theming a
  5,000-component schematic is twelve struct writes and no geometry work.

## It is checked against the original, byte for byte

This is a port, so the interesting question is not "does it run" but "does it agree". The test suite
is differential where it can be: it drives the real 4.1.0 release and compares output exactly.

- **1,757 tests in 214 suites**, plus 46 older XCTest cases, and they pass from a clean
  checkout of this repository. Swift Testing's own summary reports only the first number,
  which is why both are given here.
- **Scripted editing** compared against the jar: 15 edit sequences replayed against a synthetic
  seed circuit, each producing `.circ` output byte-identical to 4.1.0's. The baselines are in
  `tools/editbridge/golden/`, so this gate runs without any extra setup.
- **HDL generation** compared against the jar's own VHDL and Verilog, byte for byte, for the
  arithmetic, gate, memory, I/O and FPGA-board families. Those five oracles are committed, in
  `tools/hdlbridge/`, so the gate runs from a clean checkout.

**What a clean checkout does not check.** Four gates need a corpus of real circuits, which is
coursework and is not in this repository: the netlist comparison, per-component FPGA map
information, command-line statistics (`-tty stats`) and test vectors (`--test-vector`,
byte-exact on 62 of 62 at last run). They read the corpus location from `LOGISIM_CORPUS`, and
without it they report as **skipped rather than passed**, deliberately: a gate that returns
early still counts as green, and this project's own rule is that an uncalibrated checker is an
unchecked one. The corpus is cited by anonymous handle throughout; `tools/corpus.py` explains
the scheme.

Where this port deliberately differs from 4.1.0, the difference is written down at the site with
the upstream file and line it diverges from, and is covered by a test that fails if it silently
drifts back. `docs/decisions.md` is the record.

## Licence

**GPL-3.0-only.** This is a derivative work of logisim-evolution and carries its licence.

- [`LICENSE.md`](LICENSE.md): the full text.
- [`NOTICE.md`](NOTICE.md): the complete notice set, covering copyright, attribution, no-warranty
  and the source offer.

## Credits

Logisim was originally written by **Carl Burch** at Hendrix College. **logisim-evolution** is the
work of its many contributors, among them Theo Kluter, Torsten Maehne, Kevin Walsh and
David H. Hutchens; see [`docs/credits.md`](docs/credits.md) and upstream's own credits.

Everything this program knows how to do, it learned from their work. The Swift and macOS
translation is by Erzheng (Erwin) Zhang.

## What is here

| path | contents |
| --- | --- |
| `swift/` | the port: a SwiftPM package and the application target |
| `tools/` | verification gates, differential harnesses, packaging |
| `docs/` | design decisions (`decisions.md`), objectives, experiment notes |

Upstream's Java source is not in this tree. It lives in the
[logisim-evolution](https://github.com/logisim-evolution/logisim-evolution) repository, which is
where it should be read. This port is checked against the shipped **4.1.0** release artefact rather
than upstream's `main` branch; `docs/decisions.md` D16 records why that distinction matters.

## Building

```sh
cd swift
swift build
swift test
```

`tools/package/build-app.sh` produces the application bundle.

The differential tests need a local install of Logisim-evolution 4.1.0 and will skip or fail
without one. The corpus they run against is coursework and is deliberately not in this repository;
the gates read its location from `LOGISIM_CORPUS`.

## Status

Pre-1.0 and honest about it. Circuits draw, edit, save, print, export and **simulate**: poking an
input drives the wire and the canvas shows live values. Full capability parity with 4.1.0 is the
1.0 bar and is not reached yet. `docs/objectives.md` is the board: what is done, what is left,
and which upstream issues this port has and has not closed.
