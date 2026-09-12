# The font-family divergence — and why it makes the migration gate host-specific

Measured 2026-09-05 against the 4.1.0 oracle jar
(`/Applications/Logisim-evolution.app/Contents/app/logisim-evolution-4.1.0-all.jar`) via
`CircBridge`, invoked exactly as `tools/difftest/canonical.py` does (D17). Reference tree
`~/Developer/logisim/upstream-java-4.1.0` (D16). Every number below was produced by running
code, not by reading it.

**Headline.** The 13 remaining font-only migration failures are not a port defect. They are the
port refusing to destroy data that upstream destroys. Worse, and this is the part that matters
beyond these 13 cases: **upstream's `.circ` output is a function of the fonts installed on the
machine that runs it.** I proved that by installing one font and re-running the unchanged jar
over unchanged input; the output changed. The migration golden baseline is therefore not
portable, and nothing in the rig currently records that.

---

## 1. What Java actually does

Two write sites, both in 4.1.0, both calling `Font.getFamily()`:

| site | code |
|---|---|
| `data/Attributes.java:195` | `String.format("%s %s %s", font.getFamily(), FontUtil.toStyleStandardString(font.getStyle()), font.getSize())` |
| `draw/shapes/SvgCreator.java:142` | `elt.setAttribute(prefix + "font-family", font.getFamily())` |

The matching read sites keep the *requested* name: `Attributes.java:185` is
`Font.decode(value)`, and `SvgReader.java:198` is `new Font(fontFamily, styleFlags, size)`.
Neither validates anything.

`Font.getName()` returns the string that was asked for; `Font.getFamily()` returns what the
graphics environment resolved it to. So the asymmetry is entirely in the writer: **Logisim reads
the name faithfully and writes back the resolution.**

Probed directly (`java.awt.headless=true`, openjdk@21, this machine):

```
"CMU Sans Serif plain 12"    -> name=CMU Sans Serif   family=Dialog           std=Dialog plain 12
"Ubuntu plain 12"            -> name=Ubuntu           family=Dialog           std=Dialog plain 12
"NoSuchFontXYZ plain 12"     -> name=NoSuchFontXYZ    family=Dialog           std=Dialog plain 12
"Menlo plain 12"             -> name=Menlo            family=Menlo            std=Menlo plain 12
"Zapfino plain 12"           -> name=Zapfino          family=Zapfino          std=Zapfino plain 12
"Comic Sans MS plain 12"     -> name=Comic Sans MS    family=Comic Sans MS    std=Comic Sans MS plain 12
```

Hypothesis confirmed: an **unavailable** family resolves to `Dialog`; an available one is
returned unchanged. `Dialog` is not a normalisation rule, it is a *failure sentinel*.

### 1a. Does the answer depend on this machine's font set? Yes. Directly demonstrated.

`CMU Sans Serif` and `Ubuntu` are **not** installed here; `system_profiler SPFontsDataType`
matches neither, and no CMU/Computer-Modern font file exists on disk.

The corpus's `.circ` files name 13 distinct families in `<a name="font">` attributes. On this
machine Java splits them exactly along "is it installed":

```
Arial                    -> Arial                    PRESERVED
Arial Black              -> Arial Black              PRESERVED
Dialog                   -> Dialog                   PRESERVED
Monospaced               -> Monospaced               PRESERVED
SansSerif                -> SansSerif                PRESERVED
Serif                    -> Serif                    PRESERVED
Tahoma                   -> Tahoma                   PRESERVED     <- macOS Supplemental, MS font
CMU Sans Serif           -> Dialog                   COLLAPSED
Noto Sans SC Black       -> Dialog                   COLLAPSED
Segoe UI                 -> Dialog                   COLLAPSED
Ubuntu                   -> Dialog                   COLLAPSED
Ubuntu Sans Mono         -> Dialog                   COLLAPSED
Yu Gothic UI Semibold    -> Dialog                   COLLAPSED
```

Note `Tahoma` survives and `Segoe UI` does not. Both are Microsoft fonts; the only difference is
that macOS ships Tahoma in `/System/Library/Fonts/Supplemental/` and does not ship Segoe UI.
Nothing about the *file* decides this.

**The decisive experiment.** `Tahoma` and `Ubuntu` are both six ASCII characters, so a TrueType
`name` table can be patched in place; every table offset and length stays valid and no table
has to be rebuilt. I copied `/System/Library/Fonts/Supplemental/Tahoma.ttf`, replaced `Tahoma`
with `Ubuntu` in both the MacRoman and the UTF-16BE name records, and dropped the result in
`~/Library/Fonts/`. Then I re-ran **the same jar** over **the same input file**:

| run | `3.3.0__case-362.circ` -> sha256 of output |
|---|---|
| before install | `df855883d33aeb7aa910c6a8e34b1d7d948757219cbef61419fec3e86eda17d4` |
| with a font reporting family `Ubuntu` installed | `01656660b923886f6ad9d31ff9e8d39f364bee83c814ba75c749e40ba11b0a4b` |
| after removing it (`atsutil databases -removeUser`) | `df855883d33aeb7aa910c6a8e34b1d7d948757219cbef61419fec3e86eda17d4` |

The diff between the first two is exactly 36 lines, every one of them a font attribute:

```
-      <a name="font" val="Dialog plain 24"/>
+      <a name="font" val="Ubuntu plain 24"/>
```

The machine was restored; the probe font is deleted and the third sha is byte-identical to the
first.

**This means the migration golden baseline is host-specific.** `canonical.py` bakes
`getFamily()`'s answer into `canonical/migrated/*`, so regenerating the baselines on a machine
with a different font set silently produces a different gate. A CI box, a fresh laptop, a
teammate who has MacTeX (which ships CMU Sans Serif) or Office would each get a different
"correct" answer for the same corpus. Nothing in `canonical.py`, `rig.py` or `decisions.md`
records this dependency today. Two lesser dependencies fall out of the same measurement:
`atsutil databases -removeUser` changed the number of families Java enumerates from **186 to
313** without any font being installed or removed, so even the *font cache state* is an input;
and macOS Supplemental fonts can be disabled in Font Book.

### 1b. The port already matches Java-with-the-font-installed

While the probe font was installed I also ran the release `logisim-cli` over the same file. Its
output agreed with the jar on **all 36** `<a name="font">` lines; zero remaining differences on
that element. The only residual divergence was 12 appearance-path lines carrying
`Courier 10 Pitch`, the one family in that file I had *not* installed:

```
-      <text … font-family="Dialog" …>              (jar: Courier 10 Pitch not installed)
+      <text … font-family="Courier 10 Pitch" …>    (port: re-emits what the file said)
```

So the port's output is not a guess that happens to differ. It is precisely upstream's output on
a machine that has the fonts, and it converges on upstream case-by-case as fonts are installed.

---

## 2. Scope: exactly which cases, measured over whole files

`rig.py --show-diff` prints `d[:8]` (`tools/difftest/rig.py:579`), so a case can look font-only
in the log while diverging further down, and vice versa. Classifying from the log gave 5;
classifying from the **full files** gives 13. Use the full files.

Gate as measured today (unchanged by this work):

```
canonical  539 pass / 0 fail
migration  456 pass / 33 fail / 50 identical but for a random VHDL label
```

and the 33 split cleanly:

```
pass 456 · vhdl-label 50 · font-only 13 · other 20
```

The 13, with the families each side writes:

| file | java writes | port writes |
|---|---|---|
| `2.7.1__case-318.circ` | Dialog, SansSerif | DejaVu Sans Mono, SansSerif |
| `2.7.1__case-091.circ` | Dialog, SansSerif | DejaVu Sans Mono, SansSerif |
| `2.7.1__case-017.circ` | Dialog, SansSerif | DejaVu Sans Mono, SansSerif |
| `2.7.1__case-069.circ` | Dialog, SansSerif | DejaVu Sans Mono, SansSerif |
| `2.7.1__case-507.circ` | Dialog, SansSerif | DejaVu Sans Mono, SansSerif |
| `2.7.1__case-272.circ` | Dialog, SansSerif | DejaVu Sans Mono, SansSerif |
| `2.7.2__case-055.circ` | Dialog, SansSerif | DejaVu Sans, DejaVu Sans Mono, SansSerif |
| `2.7.2__case-427.circ` | **Arial, Arial Black**, Dialog | **Arial, Arial Black**, Yu Gothic UI Semibold |
| `3.3.0__case-411.circ` | Dialog, SansSerif | Courier 10 Pitch, SansSerif |
| `3.3.0__case-362.circ` | Dialog, SansSerif | Courier 10 Pitch, SansSerif, Ubuntu |
| `3.5.0__case-165.circ` | Dialog, SansSerif | CMU Sans Serif, SansSerif |
| `3.5.0__case-173.circ` | Dialog, SansSerif | CMU Sans Serif, SansSerif |
| `4.0.0__case-448.circ` | Dialog, SansSerif | SansSerif, Ubuntu Sans Mono |

The `2.7.2__case-427.circ` row is the clearest single data point in the table: Java preserved `Arial` and
`Arial Black` and collapsed `Yu Gothic UI Semibold` **in the same file, in the same run**. The
discriminator is installation, not "third-party" or "legacy" or "malformed".

The other 20 failures (19 from a single corpus repository, plus
`3.7.1__case-539.circ` and
`2.7.1__case-338.circ`) are unrelated and out of scope here.

Both write paths are affected. Across the corpus the appearance path carries its own family set:
`SansSerif` (5105), `Dialog` (3942), `DejaVu Sans Mono` (81), `Courier 10 Pitch` (49),
`DejaVu Sans` (1), `Cantarell` (1): all four third-party ones being Linux desktop fonts.

---

## 3. The cost of matching Java

### Feasibility — better than expected, and that is not the same as "right"

D9 forbids UI frameworks in the kernel, so `FontSpec` cannot call CoreText. But the honest
question is whether CoreText could reproduce `getFamily()` *at all*, wherever it lived. I
measured two candidate predicates.

**(A) list membership**; `CTFontManagerCopyAvailableFontFamilyNames()` returns **180**
families; Java enumerates **313**. Java's list is a strict superset (0 names are CoreText-only,
133 are Java-only). Java preserves `Athelas`, `Iowan Old Style`, `Marion`, `Courier`,
`Noto Sans Armenian`, `Hiragino Kaku Gothic Pro` and 122 others that a membership test would
collapse to `Dialog`. **(A) does not work.**

**(B) round-trip**: `CTFontCopyFamilyName(CTFontCreateWithName(X))`, treating `X` as available
iff the answer is `X`, with Java's five logical names special-cased. CoreText substitutes
`Helvetica`, not `Dialog`, so the sentinel has to be re-mapped by hand. Over the union of both
family lists plus the corpus names, **322 names, (B) agrees with Java on all 322.**

So "match Java" is roughly fifteen lines, not a research project. Two caveats, both measured:

* **(B) diverges on names that are not clean family names.** Java's font manager folds case and
  accepts PostScript/face names; CoreText's round-trip test does not. 8 of 22 adversarial
  probes disagreed:

  | input | java | predicate (B) |
  |---|---|---|
  | `arial`, `ARIAL` | `Arial` | `Dialog` |
  | `sansserif`, `SANSSERIF` | `SansSerif` | `Dialog` |
  | `Arial-BoldMT` | `Arial` | `Dialog` |
  | `TimesNewRomanPSMT` | `Times New Roman` | `Dialog` |
  | `HelveticaNeue` | `Helvetica Neue` | `Dialog` |
  | `Menlo-Regular` | `Menlo` | `Dialog` |

  `.circ` files carry whatever the writing platform produced, and `SvgReader` hands the raw
  string to `new Font(...)` unvalidated, so this input class is reachable. Closing it means
  chasing `sun.font.CFontManager`'s matching rules, which is open-ended.
* **Agreement is agreement *on this machine*.** Both sides are reading the same host font set.
  The 322/322 result says CoreText can *observe* what Java observes; it says nothing about the
  answer being stable, because the answer is not stable, §1a.

### Where it would have to live, and what it does to `logisim-cli`

`FontSpec` is in `LogisimKernel`; the `.circ` codec is in `LogisimFile`; CoreText is a UI
framework by D9's definition. The options:

1. **CoreText in the kernel.** Straight D9 violation. Rejected.
2. **A `FontResolver` protocol injected into the codec**, identity by default, CoreText-backed
   from `LogisimRender` up. This is the only D9-clean shape, and it is worse than it looks: the
   *same file* then saves differently depending on which binary opened it. `logisim-cli` without
   a resolver writes `Ubuntu`; the app writes `Dialog`. One codebase, two serialisations, and
   the gate would be testing the one the user never runs.
3. **Link CoreText into `logisim-cli` too.** Headlessness is not the obstacle: Java itself
   enumerates 313 families under `-Djava.awt.headless=true`, so this path needs no GUI session.
   The obstacle is that it makes the *port's* output host-dependent as well, deliberately.

Option 3 is the only one that would actually turn the 13 red, and its whole content is
"reproduce upstream's data loss, on purpose, and inherit its non-reproducibility".

### What matching would cost the user

`Font.decode` keeps the name; `toStandardString` writes the resolution. So on upstream, opening
a file on a machine lacking the font and saving it **destroys the family name permanently**:
demonstrated at the top of §1a, where `CMU Sans Serif` went in and `Dialog` came out. Reopening
on the author's own machine cannot recover it. That is the same failure mode D8 was written for
(`<lib desc="#Legacy">` and its component silently gone after one open-and-save), one level down
in the tree: it is unrecognised content, and it is dropped instead of round-tripped. The corpus
already shows 387 `Dialog plain 12` and 3942 `font-family="Dialog"` occurrences *in the source
files*, at least some of which will be exactly this, already burned in by a previous save.

D8 is binding and it settles the direction: the port must not do this.

---

## 4. Recommendation

**Keep the port's behaviour. Record the deviation. Mask it in the gate, narrowly, and label the
gate's host dependency in `canonical.py`.**

Three parts, in priority order.

**(a) Do not "fix" it, and record why under D11.** D11 lists permanent functional gaps; this is
one, phrased as a deliberate non-inheritance: *the port does not reproduce upstream's
resolve-on-write of font family names, because doing so discards a name the file carried and the
result varies with the host's font set (D8).* The test at
`swift/Tests/LogisimKernelTests/FontSpecFamilyTests.swift` pins the behaviour, and the `FontSpec`
doc comment now states the measured facts rather than the previous "for every family Logisim
itself writes the two agree": true, but it does not cover the corpus, which is the only reason
it read as reassuring.

**(b) Mask, do not exclude — and mask one token, not the case.** Precedent:
`mask_vhdl_labels`. Caveat, from `nondet.py`'s header: excluding a whole case once **hid 8
genuine body divergences**, which is why masking must be narrow. The rule I measured is narrower
than "ignore the family". Neutralise a differing family only when all three hold:

1. the java side is exactly `Dialog`: the unresolved sentinel, not any family; **and**
2. the port side is not `Dialog`; **and**
3. that name occurs verbatim in the **original source file**.

Condition (3) is what stops the mask hiding a port-side bug: the port is forgiven only for
re-emitting a family the input actually carried, so mangling `Ubuntu` to `Ubunt`, dropping a
family, or inventing one all still fail. Style word, size, and every other byte are compared
literally.

Measured over the corpus, that rule folds **exactly 13** and leaves the 20 real failures:

```
pass 456 · vhdl-label 50 · font-unresolved 13 · real fail 20
```

Report it in its own column, as `LABEL` already is; **never folded into pass**. The gate would
then read `migration 456 pass · 20 fail · 50 vhdl-label · 13 font-unresolved`, and the 20 are
what actually needs work.

**(c) Say in `canonical.py` that its baselines are host-specific.** This is the finding with
reach beyond the 13 cases. A regenerated baseline on a different machine is a *different gate*,
and today nothing says so. At minimum the docstring should record it; better, the script should
write the host's Java family count and the resolution of the corpus's font families beside
`_index.json`, so a baseline generated elsewhere is detectably different rather than silently
different.

I own neither `canonical.py` nor `rig.py` nor `decisions.md`, so (b) and (c) are handed over as
exact changes in the report rather than applied here.

### Why not the alternatives

* **Match Java (option 3 above).** Turns 13 red cases green at the cost of adopting a data-loss
  bug and making the port's own output unreproducible across machines. It optimises the number
  the gate prints against the thing the gate exists to protect.
* **Hardcode `Dialog`.** Would pass all 13 here and be wrong everywhere: `Dialog` is this
  machine's answer, not upstream's rule. It also breaks `Arial`/`Arial Black`/`Tahoma`, which
  both sides currently agree on, and would fail immediately on any machine that has CMU or
  Ubuntu installed.
* **Exclude the 13 files.** The failure mode `nondet.py` documents. A file excluded for its font
  attribute stops being checked for everything else.
* **Leave the gate as is.** Defensible, 13 known-benign failures are not a crisis, but it
  leaves a permanent 13-case red band that every future reader has to re-derive, and it leaves
  the host dependency unrecorded, which is the actually dangerous part.

---

## 5. Reproducing this

```sh
# what java resolves a family to, on this machine
cat > FontProbe.java <<'EOF'
import java.awt.Font;
public class FontProbe {
  public static void main(String[] a) {
    for (String n : a) System.out.println(n + " -> " + new Font(n, Font.PLAIN, 12).getFamily());
  }
}
EOF
javac -d . FontProbe.java
/opt/homebrew/opt/openjdk@21/bin/java -Djava.awt.headless=true -cp . FontProbe \
    "CMU Sans Serif" Ubuntu Tahoma "Segoe UI" Arial

# the oracle, invoked as canonical.py does (D17)
printf "%s\t%s\n" "<src.circ>" "/tmp/out.circ" | /opt/homebrew/opt/openjdk@21/bin/java \
    -Djava.awt.headless=true \
    -cp "/Applications/Logisim-evolution.app/Contents/app/logisim-evolution-4.1.0-all.jar:tools/valuebridge/out" \
    com.cburch.logisim.file.CircBridge
ls -l /tmp/out.circ    # assert it exists; an entry point that writes nothing exits 0 too

# the host-dependence experiment (reversible; restore by deleting the font + flushing the cache)
python3 - <<'EOF'
d = open("/System/Library/Fonts/Supplemental/Tahoma.ttf","rb").read()
d = d.replace("Tahoma".encode("utf-16-be"), "Ubuntu".encode("utf-16-be")).replace(b"Tahoma", b"Ubuntu")
open("/tmp/UbuntuProbe.ttf","wb").write(d)
EOF
cp /tmp/UbuntuProbe.ttf ~/Library/Fonts/     # ... re-run the oracle, diff, then:
rm ~/Library/Fonts/UbuntuProbe.ttf && atsutil databases -removeUser
```

`atsutil databases -removeUser` is required; the font stayed visible to a freshly started JVM
until the cache was flushed, which is itself part of the finding.
