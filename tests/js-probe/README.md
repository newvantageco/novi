# js-probe — what JavaScript would actually buy this browser

RFC 0031 roadmap 2 said: *"Duktape is one flag and a real question: it
is an interpreter with no JIT, so it is slow, and slow scripting on
pages written for fast scripting may be worse than none. Measure before
turning it on."*

These pages are that measurement. **The answer is no**, and the
shipped browser still has `NETSURF_USE_DUKTAPE=NO` — but the
instrument is kept, because the next person should be able to re-run
it rather than re-argue it.

## Two things that silently do nothing

**`NETSURF_USE_DUKTAPE=YES` is not enough.** `enable_javascript`
defaults to **false** in NetSurf's own options, so a browser with a
complete JavaScript engine compiled in runs no script at all and says
nothing about it.

**And the option file is `~/.netsurf/Choices`, not
`~/.config/netsurf/Choices`.** The framebuffer frontend looks for
`Choices` on its RESOURCE path (`$HOME/.netsurf/`, `$NETSURFRES`,
`/usr/share/netsurf`), not the XDG config directory. The first attempt
put it in the XDG place, which is silently ignored — the page renders
exactly as it does with no engine at all.

## What was measured, on a booted Novi

**It works.** `dom.html` renders `SCRIPT RAN: DOM WRITE OK` plus an
element the script created: `getElementById`, `textContent`,
`createElement`, `appendChild` and `typeof window` all behave.

**The syntax is ES5, and that is the finding.**

| feature | result |
|---|---|
| ES5 functions, `const`, `JSON` | work |
| `let` | **SyntaxError** |
| arrow functions | **SyntaxError** |
| template literals | **SyntaxError** |
| `class` | **SyntaxError** |
| `for…of` | **SyntaxError** |

**A syntax error is a WHOLE-SCRIPT failure.** One arrow function
anywhere in a bundle and nothing in that bundle runs — not a degraded
page, nothing. That is not a guess: the first version of `modern.html`
was written in ES6 and rendered its own `loading...` placeholder
forever, which is exactly what a 2020s site would do.

**The APIs a page needs to be dynamic are absent.**

| API | result |
|---|---|
| `querySelector` / `querySelectorAll` | function |
| `addEventListener`, `element.onclick` | function |
| `innerHTML`, `getElementsByTagName` | work |
| `setTimeout`, `canvas.getContext` | function |
| `Array.map`, `Object.assign`, `String.includes` | function |
| **`Promise`** | **undefined** |
| **`fetch`** | **undefined** |
| **`XMLHttpRequest`** | **undefined** |
| **`localStorage`** | **undefined** |

No `fetch` and no `XMLHttpRequest` means a page cannot load anything
after its initial HTML. That rules out not just React but 2005-era
AJAX.

**Speed: interpreter-class, two orders off a JIT.** On the guest,
`bench.html` reports fib(24) **308 ms**, a 2-million-iteration modulo
loop **9153 ms**, and 50k string appends plus a join **654 ms** — and
the page's own status bar reads *Done (10.2s)*, because the script
blocks the load.

That guest is TCG, not KVM, so the number needs correcting: the same
2M loop in CPython takes **4577 ms on the guest and 151 ms on the
build host**, a **30×** emulation penalty. So Duktape's 9153 ms is
about **305 ms** of real hardware — roughly **CPython's speed, within
2×**, and roughly **60–150× slower than a JIT'd engine**, which is
what the pages it would be asked to run are written for.

## Why the answer is no

- **+1.34 MB** on the browser binary (2,557,840 → 3,901,840, +52%),
  for pages that overwhelmingly cannot run in it anyway.
- **An interpreter parsing hostile script**, in a browser that RFC
  0031 roadmap 4 and 5 just established has no sandbox and no CPU
  bound. One page can already peg a core with HTML alone.
- **What it buys is ES5 DOM manipulation with no network**: menus,
  tabs and accordions written before 2015, or with jQuery's DOM half.
  Real, and small.

Worth revisiting when there is a CPU bound (RFC 0031 roadmap 6), or if
somebody demonstrates a class of sites that actually comes to life.

## One probe here was wrong

`spread` reports `5` and does not test spread syntax: it evaluates
`Math.max.apply(null,[1,5,3])`, which is ES5 and would pass on any
engine. The line is kept, corrected, as a reminder that a probe
reporting success is not the same as the feature existing — the same
mistake this repository has now made in a glyph test, an OpenSSL
symbol diff and an `-ssl3` check.
