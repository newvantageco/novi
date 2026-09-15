# hostile-pages — pointing something unfriendly at the browser

RFC 0031 roadmap 4, and then roadmap 5, which this corpus argued for
and then measured. Until it ran, nothing had ever aimed a deliberately
awkward document at NetSurf, which parses arbitrary HTML and CSS off
the network with **none of the sandboxing a mainstream browser puts
around that**.

    sh generate.sh /tmp/hostile     # build the corpus (a few MB)
    sh run.sh 10                    # load each page, 10s each
    sh memcheck.sh <page> 40        # VmPeak/VmHWM for ONE page

`run.sh` and `memcheck.sh` run **on a booted Novi with the desktop
up**. They serve the corpus from the machine itself with busybox
`httpd` on 127.0.0.1, so a failure is the browser's and not a
network's. `generate.sh` runs anywhere.

## What was found

**Nothing crashed.** Sixteen pages, zero SIGSEGVs — including a PNG
whose IHDR claims 65535×65535, a document of invalid UTF-8 (lone
continuation bytes, truncated multi-byte starts, an overlong `/`),
thousands of unterminated entities, a self-importing stylesheet, and
tag names two thousand characters long. Error recovery is the code path
least exercised by pages anyone tests against, and it held.

**Five pages never settled**, at ~100% CPU through the whole window:

| page | what it is | CPU | VmPeak @40s | @180s |
|---|---|---|---|---|
| `deep-nesting.html` | 40k nested `<div>` | 100% | 29 MB | |
| `long-line.html` | 4 MB with no whitespace to break on | 100% | 44 MB | |
| `unclosed-tags.html` | 20k unclosed `<b><i><span><p>` | 100% | 217 MB | **484 MB** |
| `many-siblings.html` | 200k sibling elements | 98% | 517 MB | 517 MB |
| `huge-table.html` | 1000 × 200 cells | 97% | 519 MB | 519 MB |

`deep-tables.html` (2000 nested tables) came in at 73% and settled at
36 MB; `css-pathological.html` (400 rules of 200-deep descendant
selectors) at 25% and 27 MB. A benign page peaks at **21 MB**.

**Four of the five plateau. `unclosed-tags.html` does not** — 217 MB at
40 seconds, 484 MB at 180, and held at exactly 1048576 kB when it
reached the 1 GiB ceiling roadmap 5 put on the browser. That is the one
page here that grows without bound, and it needs about ten minutes to
become a problem on a 4 GB machine.

## The takedown, and the correction to what caused it

Running those five in a loop **took the whole machine down. Twice, on
two fresh boots**: QEMU pinned at 110% CPU with 4.5–4.9 GB resident
against a **4096 MB** guest, the serial console unresponsive, and the
supervising script unable to enforce its own 40-second deadline.

**The first write-up said the shell was starved by the CPU load. That
was an inference, and it is wrong.** Measured afterwards on the same
4-vCPU guest, with an unrelated shell probe: three runaway browsers
cost it *nothing* (17 centiseconds, same as idle), and it took **eight**
of them to slow it to 40–43. What actually happened is memory: several
half-gigabyte pages plus one that grows without limit, on a guest with
no swap, and under that everything stalls including the kill.

The distinction matters because it decides the fix. A CPU bound would
not have prevented it; the address-space bound does.

**So the honest version of "one page takes the machine down" is: one
page costs a pegged core indefinitely and up to half a gigabyte, one
page in this corpus will reach four gigabytes if left for about half an
hour, and five of them together did it in minutes.**

## What roadmap 5 changed

`pkg install netsurf` now puts a wrapper on PATH and the binary in
`/usr/libexec`: **1 GiB of address space** (`s6-softlimit -a`) and
**nice 5**. Measured on a booted machine — `Max address space
1073741824`, nice 5, a benign page still rendering in 0.1s — and both
overridable per run (`NOVI_BROWSER_AS_LIMIT`, `NOVI_BROWSER_NICE`,
either `off`).

What each buys, exactly:

- **The bound**: a page cannot take the machine's memory. NetSurf
  neither exits nor prints anything when it hits the ceiling — measured,
  not hoped for — so what this converts an unrecoverable machine into is
  a hung window.
- **The nice**: the rest of the machine stays usable while a page runs
  away. Eight runaways took an unrelated shell probe from 17 to 40–43
  centiseconds; at nice 5 it came back to 19–23, and at nice 15 to 16.
  On an idle machine it costs nothing at all.

**Neither is a CPU bound and neither is a sandbox.** `RLIMIT_CPU` was
considered and rejected: it is cumulative over the process's whole
life, so it cannot say "this layout is taking too long" without also
killing a long browsing session that has done nothing wrong.

## What is NOT established

**Safety.** Surviving a corpus is not a safety property. This finds
crashes and hangs on shapes somebody thought of. It says nothing about
memory disclosure, nothing about the shapes nobody thought of, and
nothing about the absence of a sandbox — which remains true whatever
these scripts print.

**A green `run.sh` means "did not fall over".** It has never meant
safe, and the script says so on every run.

## The control matters

A benign page (`index.html`) renders in **0.1s** with the window drawn
and the links laid out — screendumped, before the bound and again after
it. Without that, "survived" could have meant a process sitting inert,
and every row above would be worthless.
