# Is the busybox/GNU gap in `sed`, `grep`, `awk` and `tar` worth a package?

RFC 0040 roadmap 4. The item named four tools in one breath and said
the answer should be *"a number, not an opinion"*, the way RFC 0027's
mbedTLS/OpenSSL collapse was settled. This is the number, and **it
says the four are not alike** — one of them earns a package, one is
arguable, and two do not.

```
bash probe.sh                 # measure busybox against GNU
bash probe.sh --self-check    # point BOTH sides at GNU; must be 52/52
```

## The result

52 constructs, each something a script written elsewhere plausibly
contains, run under the shipped busybox **and** under the GNU program,
comparing output *and* exit status.

```
52 cases:  agree 37   differ 15
of the differences: 12 LOUD (busybox errors), 3 SILENT (exits 0, different output)

  sed   agree=6    differ=7
  grep  agree=8    differ=4
  awk   agree=14   differ=1
  tar   agree=9    differ=3
```

## What decides it is LOUD versus SILENT, not agree versus differ

A busybox that errors is a bug report the person at the terminal gets
for free: `unrecognized option: P`, and they know. A busybox that
**exits 0 and produces different text** has quietly corrupted the
output of a script that looked like it worked.

**All three silent cases are `sed`:**

| construct | GNU | busybox |
|---|---|---|
| `s/one/\U&/` | `ONE` | `Uone` — the `\U` is emitted literally |
| `s/AAA/\L&/` | `aaa` | `LAAA` |
| `0,/beta/s/a/A/` | substitutes in the first matching line | no substitution at all |

The first two are the dangerous shape: a case conversion that silently
becomes a stray capital letter in the middle of whatever the script was
generating.

## Per tool

- **`sed` earns a package.** It is the only one of the four that
  answers differently while exiting 0, and it does so three times. Its
  loud gaps (`-z`, `-s`, `0,/re/`, the `e` and `F` commands) are on top
  of that.
- **`grep` is arguable.** Four differences, all loud: `-P` (twice —
  plain `\d` and a lookahead), `-r --include`, and `-z`. `-P` is common
  in scripts found online, but a script that uses it stops with an
  error naming the option.
- **`awk` does not.** 14 of 15 agree, `gensub`, `strftime`, `ENVIRON`,
  regex `RS` and `length(array)` included. The single difference is
  `asort`. busybox awk is close to a drop-in for gawk here, which was
  not the expected answer.
- **`tar` does not.** Three differences — `--transform`,
  `--owner`/`--group`, `--sparse` — all loud, and all *packaging*
  flags rather than things an ordinary script does. Hardlinks, mtimes,
  `--exclude`, `--strip-components`, `-z` and `-J` all agree.

## Three probe bugs, and each one changed an answer

Recorded because in this repository the instrument has been the broken
thing more often than the code:

1. **Debian's `awk` is mawk.** The first run compared busybox against
   mawk and reported `gensub` as a busybox *win* — inverting the one
   conclusion the awk rows exist to reach. The probe names `gawk` now
   and refuses to run without it.
2. **The runs shared a directory.** The tar hardlink case failed under
   busybox with `File exists`, left behind by the GNU run of the same
   case, and read as a busybox limitation it is not. Each side gets a
   clean directory — which then exposed that seven tar cases had been
   chaining off the first case's `td`, so those are self-contained now
   too.
3. **A pipeline reports its last command's status.** `printf | $T -z |
   tr` returned 0 with busybox's `unrecognized option: z` sitting in
   the output, so two LOUD failures were counted as SILENT ones. The
   snippet shell runs with `set -o pipefail`. CLAUDE.md already records
   this trap three times; this is the fourth.

And the self-check's own first shim was written `#!/bin/sh` with
`"${@:2}"`, which dash expands to nothing — so the check that exists to
prove the harness can report agreement reported 0/52 and looked like a
finding.
