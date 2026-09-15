# hostile-pages — pointing something unfriendly at the browser

RFC 0031 roadmap 4. Until this ran, nothing had ever aimed a
deliberately awkward document at NetSurf, which parses arbitrary HTML
and CSS off the network with **none of the sandboxing a mainstream
browser puts around that**.

    sh generate.sh /tmp/hostile     # build the corpus (a few MB)
    sh run.sh 10                    # load each page, 10s each
    sh memcheck.sh <page> 40        # peak RSS for ONE page

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

| page | what it is | CPU |
|---|---|---|
| `deep-nesting.html` | 40k nested `<div>` | 100% |
| `long-line.html` | 4 MB with no whitespace to break on | 100% |
| `unclosed-tags.html` | 20k unclosed `<b><i><span><p>` | 100% |
| `many-siblings.html` | 200k sibling elements | 98% |
| `huge-table.html` | 1000 × 200 cells | 97% |

`deep-tables.html` (2000 nested tables) came in at 73% and settled;
`css-pathological.html` (400 rules of 200-deep descendant selectors) at
25%.

**And running those five for longer took the whole machine down.**
Twice, on two fresh boots: QEMU pinned at 110% CPU with 4.5–4.9 GB
resident against a **4096 MB** guest, the serial console unresponsive,
and — the part that matters — **the supervising script unable to
enforce its own 40-second deadline**, because the shell meant to kill
the browser was starved by it. The Linux OOM killer did not restore the
machine within several minutes of waiting.

That is not "slow". One page, fetched over the network, can put this
system into a state a local shell cannot recover from.

## What is NOT established, and why the gap is the point

**Per-page attribution of the memory blowup.** Two attempts to measure
peak RSS one page at a time ended with the machine in the state
described above, which is precisely why there is no table here. A
harness that shares a machine with an unbounded allocator gets starved
by it — and a per-process memory bound is exactly the thing whose
absence this item exists to record.

**Safety.** Surviving a corpus is not a safety property. This finds
crashes and hangs on shapes somebody thought of. It says nothing about
memory disclosure, nothing about the shapes nobody thought of, and
nothing about the absence of a sandbox — which remains true whatever
these scripts print.

**A green `run.sh` means "did not fall over".** It has never meant
safe, and the script says so on every run.

## The control matters

A benign page (`index.html`) renders in **0.1s** with the window drawn
and the links laid out — screendumped. Without that, "survived" could
have meant a process sitting inert, and every row above would be
worthless.
