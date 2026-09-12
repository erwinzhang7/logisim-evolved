# Which factories install a label field — board #78

> ## ⚠ SUPERSEDED IN PART: read this first (2026-09-06, hours after the rest was written)
>
> **The headline number below is wrong. It says 39; the jar says 99 of 114.**
>
> Everything below was derived by grepping for `Instance.setTextField` and
> `Instance.computeLabelTextField`. That misses every factory reaching them through a *helper*.
> The case that exposed it: `Buffer.java:102` calls `NotGate.configureLabel(instance, false, null)`,
> which is a static one hop from `setTextField`: invisible to both greps. So the section below
> titled "the port labels two that upstream does not" is **also wrong**: `Buffer` and
> `ControlledBuffer` DO label upstream, the port is correct to conform them, and there is no D18
> decision to make.
>
> **Measured instead of read**, by `tools/editbridge/LabelFieldProbe.java`, which instantiates
> every factory in the five builtin libraries against the real 4.1.0 jar and asks
> `getFeature(TextEditable.class)`: the exact predicate `InstanceComponent.drawLabel` branches on.
> Full output: `docs/experiments/label-fields-measured.txt`.
>
> **99 of 114 factories have a label field.** The fifteen that do NOT are the whole exception list,
> and it is short enough to state: `Bit Extender`, `Constant`, `Ground`, `Joystick`, `Keyboard`,
> `NoConnect`, `POR`, `Power`, `Pull Resistor`, `RGB Video`, `ReptarLB`, `Splitter`, `TTY`,
> `Transistor`, `Transmission Gate`.
>
> **The per-factory placements below are still correct and still usable**; they were read out of
> the Java call sites one at a time, and each one that is listed is right. What is wrong is the
> claim that the list is *complete*. Treat it as a verified subset, not a survey.
>
> The lesson, which cost two separate mistakes in one session: **searching for the name of a
> mechanism is not the same as searching for the guarantee.** The same day, a grep for
> `hdlGlobalStateLock` missed every suite using the `withHdlGlobals` helper and produced six false
> positives (#80, withdrawn). Here a grep for `setTextField` missed 60 factories using helpers and
> produced a false *negative*. When a property can be satisfied indirectly, enumerate and ASK
> rather than grep.


Derived from the 4.1.0 tree on 2026-09-06 by reading every call site, not from a count.

## Why the first survey was wrong

The gap was first reported as "9 of 24", from the 27 files calling `Instance.setTextField`.
Upstream installs a label field through **two** entry points:

| call | factories |
|---|---|
| `Instance.setTextField(labelAttr, fontAttr, x, y, hAlign, vAlign)` | 24 |
| `Instance.computeLabelTextField(avoidMask)`: `Instance.java:172`, calls `setTextField` itself | 16 |

Only two factories appear in both, so the union is **39** (excluding `Instance`/`InstanceComponent`
plumbing and the `com.cburch.gray` tutorial).

The tell that the first list was wrong was available without counting anything: it did not contain
`Pin`, `Probe` or `Clock`, all three of which already draw labels in this port. A survey that
cannot explain the current state is measuring the wrong thing.

## What the port has: 8 of 39

`SubcircuitFactory`, `Text`, `AbstractGate`, `NotGate`, `Pla`, `Clock`, `Pin`, `Probe`.

`Pin`/`Probe`/`Clock` arrive via `computeLabelTextField`, which is exactly why they were absent
from the first list.

## Missing: 31

All 31 were checked individually; every one is a ported type with no `InstanceLabelProvider`
conformance, so its label neither draws nor edits. Nine are SoC and blocked behind #24.

### Priority: the eight a CSC258 circuit actually contains

Exact upstream arguments, so no one has to re-derive them.

Four of the six memory factories share **one identical placement**: centre of the bounds,
3px above the top, `H_CENTER`/`V_BASELINE`:

| factory | Java | placement |
|---|---|---|
| `Counter` | `Counter.java:142` | `bds.x + bds.width/2`, `bds.y - 3`, `H_CENTER`, `V_BASELINE` |
| `ShiftRegister` | `ShiftRegister.java:146` | *identical* |
| `Random` | `Random.java:172` | *identical* |
| `AbstractFlipFlop` | `AbstractFlipFlop.java:233` | *identical* |

The other four each differ:

| factory | Java | placement |
|---|---|---|
| `Mem` (base of RAM/ROM) | `Mem.java:142` | `bds.x + bds.width/2`, `bds.y - 2`, `H_CENTER`, **`V_BOTTOM`**: note `-2`, not `-3` |
| `Register` | `Register.java:254`, `:361`, `:363` | `computeLabelTextField(AVOID_SIDES)`, and it is **re-run on attribute change** (three call sites, not one) |
| `AbstractTtlGate` | `AbstractTtlGate.java:146` / `:154` | **facing-dependent**: E/W → right of the body, `H_LEFT`/`V_CENTER_OVERALL`; otherwise above, `H_CENTER`/`V_CENTER_OVERALL` |
| `Tunnel` | `Tunnel.java:94` | attribute-driven: `loc + (attrs.labelX, attrs.labelY)`, with the h/v align also read from `TunnelAttributes` |

`VAlign` already has `baseline` and `centerOverall` (`SceneText.swift:31-38`), so nothing in the
render layer blocks this.

### The io family (14)

Mostly one-liners through `computeLabelTextField`, so they are the cheapest of the lot:

| mask | factories |
|---|---|
| `AVOID_LEFT` | `Led:108`, `RgbLed:155`, `DotMatrixBase:285`, `DipSwitch:166`, `DigitalOscilloscope:103`, `ProgrammableGenerator:334` |
| `AVOID_CENTER \| AVOID_LEFT` | `Button:149` |
| `AVOID_RIGHT \| AVOID_LEFT` | `Switch:110` |
| `AVOID_BOTTOM` | `PortIo:254` |
| `AVOID_SIDES` | `Telnet:204` |
| explicit `setTextField` | `SevenSegment:234`, `Buzzer:149`, `PlaRom:267`, `Slider:177` |

### SoC (9) — blocked behind #24

`SocBus`, `SocDma`, `JtagUart`, `SocMemory`, `Nios2`, `SocPio`, `Rv32imRiscV`, `SocVga`,
`VgaState`.

## The opposite direction: two the port labels and upstream does not

`Buffer` and `ControlledBuffer` both call `painter.drawLabel()` and **neither installs a text
field**. `InstanceComponent.drawLabel` returns early when `textField == null`, so upstream's call
is dead code and those labels never draw in 4.1.0; while this port conforms both to
`InstanceLabelProvider` and draws them.

Deterministic and raster-observable, so **D18 says reproduce it**. Decide explicitly and record
the decision; do not leave it as an accident. Note the reading is not certain to be complete:
confirm by placing a labelled buffer in the jar before acting.

## How to verify a conformance is right

The M7 edit-parity gate is the instrument: a script that clicks the component's label, retypes
it, and byte-matches the saved `.circ` against 4.1.0. Drawing and editing cannot disagree by
construction, `InstanceTextField` recomputes its six arguments from
`InstanceLabelProvider.labelPlacement(_:)`, the same function `InstancePainter.drawLabel()` uses,
so one conformance closes both halves, and the gate covers both.
