#!/usr/bin/env bash
# Copy the publishable subset of this repository into the public one.
#
#   ./tools/package/export-public.sh [DEST]      # default ../../public-logisim-evolved
#
# WHY THIS IS AN ALLOWLIST OVER TRACKED FILES
#
# The first version rsynced whole working DIRECTORIES with `--exclude` patterns. An audit found
# that it had copied all three corpus-derived artifacts that `.gitignore` exists to keep out,
# including a 23,813-line oracle generated from student coursework, into the working tree of the
# repository about to be made public. They were never committed, because the destination ignores
# them too, and that is the whole problem: the safety came from a second mechanism happening to
# agree, not from the export. One `git add -f`, one edited ignore rule, or one `zip -r` of the
# directory, and the coursework is published.
#
# So the export now copies exactly the files Git TRACKS here, filtered through the allowlist below.
# An untracked or ignored file cannot be copied by construction, whatever it is called and wherever
# it sits.
#
# WHAT IS NOT PUBLISHED, AND WHY
#
#   src/, artwork/, boards_model/, CHANGES.md, .github/ (except ISSUE_TEMPLATE)
#       Upstream's own tree. This repository is a fork, so it carries them; the port does not need
#       them, and `docs/decisions.md` D16 is why they are a hazard rather than a help: they are
#       upstream's `main`, and the port targets the shipped 4.1.0 release.
#   the corpus, and anything keyed to it
#       Coursework. `.gitignore` covers the data and `tools/corpus.py` covers the names, but this
#       script no longer relies on either.
#   tools/unmerged.py
#       A local branch-and-worktree coordination tool. Nothing to do with the port.
#   docs/notebook.md
#       The dated engineering log. `docs/objectives.md` keeps the goal, standing rules, board and
#       release plan, which is what the source comments cite; the notebook is the working record
#       behind them. Held back deliberately.
#   README.md
#       The two repositories legitimately differ. This fork's README is upstream's, carrying a
#       GPL section 5(a) modification notice; the public one describes the port. So README.md is
#       NOT copied, in either direction, and is maintained in the public repository.
#
# Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
dest=${1:-$(cd "$here/../.." && pwd)/public-logisim-evolved}

[ -d "$dest/.git" ] || { echo "not a git repository: $dest" >&2; exit 1; }
[ "$(cd "$dest" && git rev-parse --show-toplevel)" != "$here" ] || {
  echo "refusing to export onto itself" >&2; exit 1; }

# ── The allowlist ────────────────────────────────────────────────────────────────────────────
# Tracked paths under a published prefix, minus the individually withheld files. Nothing else is
# eligible, so a NEW top-level directory is withheld by default rather than published by default.
allowlist=$(cd "$here" && git ls-files -- docs swift tools .github/ISSUE_TEMPLATE \
    LICENSE.md NOTICE.md CITATION.cff .gitignore .gitattributes .markdownlint.yaml \
  | grep -v -x -e 'docs/notebook.md' -e 'tools/unmerged.py')

[ -n "$allowlist" ] || { echo "allowlist is empty; refusing to touch $dest" >&2; exit 1; }

# ── Refuse to run if the SOURCE tracks something that must never be copied ───────────────────
# Checked on the input, before anything is written, and by name rather than by ignore status.
if printf '%s\n' "$allowlist" | grep -q -e 'handles\.json$' -e 'netlist-4\.1\.0\.oracle$'; then
  echo "a corpus manifest or corpus-derived oracle is TRACKED in $here; that belongs beside the" >&2
  echo "corpus, not in the repository. Refusing to export." >&2
  exit 1
fi

# ── Copy ─────────────────────────────────────────────────────────────────────────────────────
printf '%s\n' "$allowlist" | rsync -a --files-from=- "$here/" "$dest/"

# ── Remove anything the destination tracks that is no longer allowed ─────────────────────────
# `--files-from` cannot delete, and the old `--delete` with excludes PROTECTED stale files, which
# is how a withheld file could survive in the destination from an earlier export. Reconcile against
# the allowlist instead, leaving the destination's own README.md alone.
(
  cd "$dest"
  comm -13 <(printf '%s\n' "$allowlist" | sort) <(git ls-files | grep -v -x 'README.md' | sort) \
    | while IFS= read -r stale; do
        [ -n "$stale" ] || continue
        echo "  removing no-longer-published $stale"
        git rm -q --cached -- "$stale"
        rm -f -- "$stale"
      done
)

# ── Refuse to finish if anything prohibited is sitting in the destination ────────────────────
# On the filesystem, independent of the destination index, because an untracked file is exactly
# what slipped through last time.
# Named individually rather than by glob: `tablefmt-nondeterministic.json` is TRACKED and
# publishable, because its case list is empty by design and the file exists so a gate reports
# "0 excluded" instead of printing a note about a missing list. The other two are keyed by real
# filename. A glob over `*nondeterministic.json` conflates them.
leaked=$(cd "$dest" && find . -path ./.git -prune -o \
  \( -name 'handles.json' \
     -o -name 'netlist-4.1.0.oracle' \
     -o -path './tools/difftest/nondeterministic.json' \
     -o -path './tools/difftest/ttybridge/stats-nondeterministic.json' \) \
  -print 2>/dev/null || true)
if [ -n "$leaked" ]; then
  echo "corpus-derived files are present in $dest (untracked still counts):" >&2
  echo "$leaked" >&2
  echo "Delete them: they are copies of coursework-derived data." >&2
  exit 1
fi

# The general form of the same problem. This script copies only TRACKED files, so an ignored file
# under a published directory in the destination did not come from here; it came from an older
# export that rsynced working directories, or from someone running a tool in place. Either way it
# is unreviewed content inside the repository about to be published.
ignored=$(cd "$dest" && git status --porcelain --ignored -- docs swift tools 2>/dev/null \
  | sed -n 's/^!! //p' | grep -v -e '/\.build/' -e '__pycache__' -e '\.DS_Store' || true)
if [ -n "$ignored" ]; then
  echo "ignored files are sitting inside $dest, which this export did not put there:" >&2
  echo "$ignored" >&2
  echo "Review and remove them before publishing." >&2
  exit 1
fi

# ── And that no corpus name survives in what was just staged ─────────────────────────────────
python3 "$dest/tools/corpuscheck.py" --selftest >/dev/null
python3 "$dest/tools/corpuscheck.py"

echo "exported $(printf '%s\n' "$allowlist" | wc -l | tr -d ' ') tracked files to $dest"
(cd "$dest" && git status --short | head -40)
