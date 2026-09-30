#!/bin/sh
# ============================================================
# generate.sh — a corpus of pages designed to break a layout engine
#
# RFC 0031 roadmap 4. NetSurf parses arbitrary HTML and CSS off the
# network with none of the sandboxing a mainstream browser puts around
# that, and until this ran, nothing had ever pointed anything unfriendly
# at it.
#
#   sh generate.sh <outdir>
#
# GENERATED, NOT COMMITTED, for the same reason the xdg-shell patch's
# machine half is: these pages are megabytes of repetition, a diff of
# them is unreviewable, and a derived answer cannot rot. What IS
# reviewable is this script -- every case is a named function with a
# sentence saying what it probes.
#
# WHAT THIS CANNOT ESTABLISH. Surviving a corpus is not a safety
# property. It finds crashes and hangs on the shapes somebody thought
# of; it says nothing about memory disclosure, about the shapes nobody
# thought of, and nothing whatsoever about the absence of a sandbox --
# which is the real finding and stays true whatever this prints.
#
# Sizes are deliberately modest (a few MB total). The target is a live
# image with a tmpfs overlay, and a corpus that fills the disk tests
# the disk.
# ============================================================
set -eu

OUT="${1:?usage: generate.sh <outdir>}"
mkdir -p "$OUT"

# AWK, NOT A SHELL LOOP. The first version of this was a counted
# `while` around `printf`, which is correct and takes MINUTES for the
# 200k-iteration cases -- long enough that the first run was killed
# before it finished. busybox awk does the same 200k in 0.57s, and
# `awk` is in every build this could run on.
rep() {  # rep <count> <string> -- literal, no escape interpretation
    awk -v n="$1" -v s="$2" 'BEGIN { while (i++ < n) printf "%s", s }'
}

# The same, for a string of BACKSLASH ESCAPES that has to become bytes.
# `printf '%s' '\200'` prints four characters, not one byte -- the
# format string is where an escape is interpreted, which is why this is
# a second function rather than a flag on the first. The invalid-UTF-8
# case is entirely about emitting specific bytes, so getting this wrong
# silently turns it into a test of ASCII backslashes.
repraw() {  # repraw <count> <escaped-string>
    i=0
    while [ "$i" -lt "$1" ]; do
        # shellcheck disable=SC2059
        printf "$2"
        i=$((i + 1))
    done
}

# ── 1. recursion in the parser and in layout ─────────────────────────
#
# A tree deep enough to exhaust a recursive descent. 40k is past any
# sane document and cheap to produce; a browser that recurses per
# element dies here and one that iterates does not.
deep_nesting() {
    { printf '<!doctype html><title>deep</title>'
      rep 40000 '<div>'
      printf 'x'
      rep 40000 '</div>'
    } > "$OUT/deep-nesting.html"
}

# Nested TABLES specifically: table layout is a second, different
# recursive pass over the same tree, and historically the one that
# blows up first.
deep_tables() {
    { printf '<!doctype html><title>tables</title>'
      rep 2000 '<table><tr><td>'
      printf 'x'
      rep 2000 '</td></tr></table>'
    } > "$OUT/deep-tables.html"
}

# ── 2. one enormous token ────────────────────────────────────────────
#
# 4 MB with no whitespace: nothing to break a line on, so every
# line-breaking heuristic has to cope with a single word wider than any
# viewport.
long_line() {
    { printf '<!doctype html><title>longline</title><p>'
      rep 131072 'ABCDEFGHIJKLMNOPQRSTUVWXYZ012345'
      printf '</p>'
    } > "$OUT/long-line.html"
}

# An attribute VALUE of the same size. A different code path from text:
# attribute values are interned, copied and often escaped.
huge_attribute() {
    { printf '<!doctype html><title>attr</title><div title="'
      rep 65536 'abcdefghijklmnopqrstuvwxyz012345'
      printf '">x</div>'
    } > "$OUT/huge-attribute.html"
}

# ── 3. malformed markup, which is the ordinary case on the web ───────
#
# Every real parser has an error-recovery path, and error recovery is
# where the bugs live -- it is the code least exercised by the pages
# anybody tests against.
unclosed_tags() {
    { printf '<!doctype html><title>unclosed</title>'
      rep 20000 '<b><i><span><p>'
    } > "$OUT/unclosed-tags.html"
}

broken_entities() {
    { printf '<!doctype html><title>entities</title><p>'
      rep 5000 '&#x &#999999999; &notanentity &#; &#xFFFFFFFF; &'
      printf '</p>'
    } > "$OUT/broken-entities.html"
}

# A tag name and an attribute name of absurd length, plus NUL-adjacent
# control bytes that a C parser may treat as terminators.
weird_tokens() {
    { printf '<!doctype html><title>tokens</title>'
      printf '<'; rep 2000 'x'; printf '>y</'; rep 2000 'x'; printf '>'
      printf '<div '; rep 2000 'a'; printf '="1">z</div>'
      printf '<p>\001\002\003\013\014\016\037</p>'
    } > "$OUT/weird-tokens.html"
}

# ── 4. CSS, which is its own parser and its own cascade ──────────────
#
# A selector chain long enough that matching it against every element
# is quadratic, and a rule count high enough that the cascade is the
# expensive part rather than layout.
css_pathological() {
    { printf 'body{color:#000}\n'
      chain="$(rep 200 ' > div')"
      i=0
      while [ "$i" -lt 400 ]; do
          printf 'div%s{color:#f00}\n' "$chain"
          i=$((i + 1))
      done
    } > "$OUT/pathological.css"
    { printf '<!doctype html><title>css</title>'
      printf '<link rel=stylesheet href="pathological.css">'
      rep 300 '<div>'; printf 'x'; rep 300 '</div>'
    } > "$OUT/css-pathological.html"
}

# A stylesheet that imports ITSELF. An importer with no cycle check
# fetches forever; one with no depth bound recurses forever.
css_import_loop() {
    printf '@import url("import-loop.css");\nbody{color:#0f0}\n' > "$OUT/import-loop.css"
    printf '<!doctype html><title>import</title><link rel=stylesheet href="import-loop.css"><p>x</p>' \
        > "$OUT/css-import-loop.html"
}

# Values that are syntactically fine and semantically enormous.
css_huge_values() {
    { printf '<!doctype html><title>values</title><style>\n'
      printf 'div{width:999999999999px;height:999999999999px;'
      printf 'margin:-999999999px;font-size:99999999px;'
      printf 'border-width:99999999px;z-index:2147483647}\n'
      printf '</style><div>x</div>'
    } > "$OUT/css-huge-values.html"
}

# ── 5. layout blowup without recursion ───────────────────────────────
#
# 200k cells is a real document shape (a generated report) and a
# quadratic table algorithm turns it into a hang rather than a crash --
# which is why the driver measures CPU as well as liveness.
huge_table() {
    { printf '<!doctype html><title>table</title><table>'
      rep 1000 '<tr>ROW</tr>' | sed "s|ROW|$(rep 200 '<td>x</td>')|g"
      printf '</table>'
    } > "$OUT/huge-table.html"
}

many_siblings() {
    { printf '<!doctype html><title>siblings</title>'
      rep 200000 '<span>x</span>'
    } > "$OUT/many-siblings.html"
}

# ── 6. the image decoder, which is C parsing a stranger's bytes ──────
#
# libpng is the one dependency here that is a decoder rather than a
# parser, and RFC 0007 put it in this image for novi-view. A PNG whose
# header CLAIMS 65535x65535 is the classic allocation bomb: 4 bytes a
# pixel is 17 GB, and a decoder that trusts the header asks for it.
png_bombs() {
    # A valid 1x1 PNG, then the same bytes with the IHDR dimensions
    # rewritten. Built with printf rather than shipped, so there is no
    # binary in the repository.
    printf '\211PNG\r\n\032\n' > "$OUT/tiny.png"
    printf '\0\0\0\015IHDR\0\0\0\001\0\0\0\001\010\002\0\0\0\220wS\336' >> "$OUT/tiny.png"
    printf '\0\0\0\014IDATx\234c\370\317\300\0\0\003\001\001\0\030\335\215\260' >> "$OUT/tiny.png"
    printf '\0\0\0\0IEND\256B`\202' >> "$OUT/tiny.png"

    # Same file with IHDR width/height set to 0xFFFF each. The CRC is
    # now wrong on purpose -- a decoder that checks it rejects the
    # chunk, which is the correct behaviour and worth confirming.
    printf '\211PNG\r\n\032\n' > "$OUT/bomb.png"
    printf '\0\0\0\015IHDR\0\0\377\377\0\0\377\377\010\002\0\0\0\220wS\336' >> "$OUT/bomb.png"
    printf '\0\0\0\014IDATx\234c\370\317\300\0\0\003\001\001\0\030\335\215\260' >> "$OUT/bomb.png"
    printf '\0\0\0\0IEND\256B`\202' >> "$OUT/bomb.png"

    # Truncated mid-IDAT.
    head -c 40 "$OUT/tiny.png" > "$OUT/truncated.png" 2>/dev/null || true

    { printf '<!doctype html><title>png</title>'
      printf '<img src="bomb.png"><img src="truncated.png"><img src="tiny.png">'
      printf '<img src="does-not-exist.png">'
    } > "$OUT/png-bombs.html"
}

# ── 7. text that is not the encoding it says it is ───────────────────
#
# A document declaring UTF-8 and containing invalid sequences: lone
# continuation bytes, truncated multi-byte starts, and an overlong
# encoding of '/' -- the last being the classic way past a naive path
# check in anything that decodes before it validates.
bad_encoding() {
    { printf '<!doctype html><meta charset="utf-8"><title>enc</title><p>'
      repraw 2000 '\200\277\301\200\340\200\200\364\220\200\200\300\257'
      printf '</p>'
    } > "$OUT/bad-encoding.html"
}

# ── 8. a page that will not settle ───────────────────────────────────
#
# meta refresh to itself with no delay. Not a parser bug -- a liveness
# one: a browser with no floor on the refresh interval spins forever.
refresh_loop() {
    printf '<!doctype html><meta http-equiv="refresh" content="0"><title>refresh</title><p>x</p>' \
        > "$OUT/refresh-loop.html"
}

# A data: URI several MB long, in an attribute.
data_uri() {
    { printf '<!doctype html><title>datauri</title><img src="data:image/png;base64,'
      rep 32768 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAAB'
      printf '">'
    } > "$OUT/data-uri.html"
}

deep_nesting
deep_tables
long_line
huge_attribute
unclosed_tags
broken_entities
weird_tokens
css_pathological
css_import_loop
css_huge_values
huge_table
many_siblings
png_bombs
bad_encoding
refresh_loop
data_uri

# An index, so the corpus is walkable by hand as well as by the driver.
{
    printf '<!doctype html><title>corpus</title><h1>hostile pages</h1><ul>'
    for f in "$OUT"/*.html; do
        b="${f##*/}"
        [ "$b" = "index.html" ] && continue
        printf '<li><a href="%s">%s</a></li>' "$b" "$b"
    done
    printf '</ul>'
} > "$OUT/index.html"

printf 'corpus in %s: %s file(s), %s\n' \
    "$OUT" "$(find "$OUT" -type f | wc -l)" "$(du -sh "$OUT" | cut -f1)"
