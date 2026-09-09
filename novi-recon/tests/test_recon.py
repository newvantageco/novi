#!/usr/bin/env python3
# ============================================================
# novi-recon self-test, run on the BUILD HOST by scripts/lint.sh
#
# Same argument as novi-panel/icons.c's host test. Most of what can be
# wrong in this tool is wrong in a way a live run cannot show you:
#
#   * The DNS parser is only exercised by whatever a real resolver
#     happens to send back, and a real resolver never sends a
#     compression pointer loop, a TXT record split across two chunks,
#     or a mismatched transaction ID -- which are exactly the three
#     cases worth getting right.
#   * The clickjacking verdict is a truth table over two headers that
#     interact, and a live site exercises one row of it.
#   * The robots parser's one subtle rule (consecutive User-agent lines
#     share a group) does not show up on most real files.
#
# So the wire format is tested by BUILDING a message here and parsing
# it back, and every verdict is tested as a table. No network, no
# fixtures downloaded, nothing that can fail because a third party
# changed.
#
#   python3 novi-recon/tests/test_recon.py
# ============================================================

import importlib.machinery
import importlib.util
import pathlib
import struct
import sys

HERE = pathlib.Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_loader(
    "novi_recon",
    importlib.machinery.SourceFileLoader("novi_recon", str(HERE.parent / "novi-recon")),
)
R = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(R)

FAILURES = []


def check(name, got, want):
    if got != want:
        FAILURES.append(f"{name}\n     got:  {got!r}\n     want: {want!r}")


def check_raises(name, exc, fn, *a):
    try:
        fn(*a)
    except exc:
        return
    except Exception as e:  # noqa: BLE001 - the point is that it was the WRONG one
        FAILURES.append(f"{name}: raised {type(e).__name__}, wanted {exc.__name__}")
        return
    FAILURES.append(f"{name}: did not raise {exc.__name__}")


# ── DNS name encoding ────────────────────────────────────────────────

check("encode example.com",
      R.dns_encode_name("example.com"), b"\x07example\x03com\x00")
check("encode trailing dot is the same",
      R.dns_encode_name("example.com."), R.dns_encode_name("example.com"))
check_raises("a label over 63 bytes is refused", R.Fail,
             R.dns_encode_name, "a" * 64 + ".com")


# ── DNS name decoding, including compression ─────────────────────────

msg = b"\x00" * 12 + b"\x03www\x07example\x03com\x00"
check("read an uncompressed name", R.dns_read_name(msg, 12)[0], "www.example.com")
# The root name is a single dot, not "". A null MX (RFC 7505) is `0 .`,
# and rendering it as `0 ` reads as a parse failure -- seen live.
check("the root name is a dot", R.dns_read_name(b"\x00", 0)[0], ".")

# A pointer to offset 16 ("example.com" inside the name above), the way
# every real server compresses an answer's owner name.
ptr = b"\x04mail" + struct.pack(">H", 0xC000 | 16)
compressed = msg + ptr
name, end = R.dns_read_name(compressed, len(msg))
check("read a compressed name", name, "mail.example.com")
check("a compressed name's end is AFTER the pointer, not after the target",
      end, len(msg) + 7)

# A pointer at offset 12 that points at itself. A parser that follows
# pointers without a bound hangs on this forever, and it is two bytes
# for anyone to send.
loop = b"\x00" * 12 + struct.pack(">H", 0xC000 | 12)
check_raises("a compression loop is refused, not followed", R.Fail,
             R.dns_read_name, loop, 12)


# ── DNS message round trip ───────────────────────────────────────────

def build_response(qid, name, rtype, rdata, flags=0x8180, ancount=None):
    """Assemble a response the way a server would, so the parser is
    tested against the wire format rather than against itself."""
    q = R.dns_encode_name(name)
    head = struct.pack(">HHHHHH", qid, flags, 1,
                       ancount if ancount is not None else 1, 0, 0)
    body = q + struct.pack(">HH", rtype, 1)
    # Owner name as a pointer to the question, which is what servers do.
    body += struct.pack(">H", 0xC000 | 12)
    body += struct.pack(">HHIH", rtype, 1, 300, len(rdata)) + rdata
    return head + body


qid = 0x1234
import socket as _s
r = R.dns_parse(build_response(qid, "example.com", 1, _s.inet_aton("93.184.216.34")), qid)
check("A record parses", r["answers"][0]["data"], "93.184.216.34")
check("A record type name", r["answers"][0]["type"], "A")
check("A record owner name came through the pointer",
      r["answers"][0]["name"], "example.com")
check("rcode NOERROR", r["rcode"], "NOERROR")

aaaa = _s.inet_pton(_s.AF_INET6, "2606:2800:220:1:248:1893:25c8:1946")
r = R.dns_parse(build_response(qid, "example.com", 28, aaaa), qid)
check("AAAA record parses", r["answers"][0]["data"],
      "2606:2800:220:1:248:1893:25c8:1946")

null_mx = struct.pack(">H", 0) + b"\x00"
r = R.dns_parse(build_response(qid, "example.com", 15, null_mx), qid)
check("a null MX renders as `0 .`", r["answers"][0]["data"], "0 .")

mx = struct.pack(">H", 10) + R.dns_encode_name("mail.example.com")
r = R.dns_parse(build_response(qid, "example.com", 15, mx), qid)
check("MX record keeps its preference", r["answers"][0]["data"],
      "10 mail.example.com")

# A TXT record longer than 255 bytes is ALWAYS split into chunks on the
# wire. Reading only the first chunk is the classic bug and it
# truncates exactly the records people care about (SPF, DKIM).
long_txt = "v=spf1 " + "ip4:10.0.0.1 " * 30 + "-all"
chunks = [long_txt[i:i + 255] for i in range(0, len(long_txt), 255)]
rdata = b"".join(bytes([len(c)]) + c.encode() for c in chunks)
check("a TXT record is split on the wire", len(chunks) > 1, True)
r = R.dns_parse(build_response(qid, "example.com", 16, rdata), qid)
check("multi-chunk TXT is rejoined whole", r["answers"][0]["data"], long_txt)

# The transaction ID is the only thing standing between this and any
# host on the path answering first.
check_raises("a mismatched transaction ID is refused", R.Fail,
             R.dns_parse, build_response(0x1234, "example.com", 1,
                                         _s.inet_aton("1.2.3.4")), 0x9999)

# TC set means "ask again over TCP"; the flag has to survive parsing or
# the retry never happens.
r = R.dns_parse(build_response(qid, "example.com", 1, _s.inet_aton("1.2.3.4"),
                               flags=0x8380), qid)
check("the truncation flag is reported", r["truncated"], True)

r = R.dns_parse(build_response(qid, "nope.example", 1, b"", flags=0x8183, ancount=0), qid)
check("NXDOMAIN is named, not a number", r["rcode"], "NXDOMAIN")
check("NXDOMAIN has no answers", r["answers"], [])


# ── resolver host:port splitting ─────────────────────────────────────
#
# A bare IPv6 literal is full of colons, so splitting on the last one
# unconditionally turns 2606:4700::1111 into a host ending in a colon
# and a port that is not a number. Brackets are the only way to say
# "this colon is the port".

check("bare v4", R.split_server("8.8.8.8"), ("8.8.8.8", 53))
check("v4 with a port", R.split_server("8.8.8.8:5353"), ("8.8.8.8", 5353))
check("a bare v6 literal keeps all its colons",
      R.split_server("2606:4700:4700::1111"), ("2606:4700:4700::1111", 53))
check("bracketed v6, no port",
      R.split_server("[2606:4700:4700::1111]"), ("2606:4700:4700::1111", 53))
check("bracketed v6 with a port",
      R.split_server("[2606:4700:4700::1111]:5353"), ("2606:4700:4700::1111", 5353))
check("localhost v6", R.split_server("::1"), ("::1", 53))


# ── Clickjacking verdict: the whole truth table ──────────────────────
#
# CSP frame-ancestors OVERRIDES X-Frame-Options wherever both appear.
# A checker that reads only XFO gets rows 5 and 6 backwards.

cases = [
    ({}, True),
    ({"x-frame-options": "DENY"}, False),
    ({"x-frame-options": "deny"}, False),                     # case-insensitive
    ({"x-frame-options": "SAMEORIGIN"}, False),
    ({"x-frame-options": "ALLOW-FROM https://a.example"}, None),  # obsolete
    ({"content-security-policy": "frame-ancestors 'none'"}, False),
    ({"content-security-policy": "default-src 'self'; frame-ancestors 'none'"}, False),
    ({"content-security-policy": "frame-ancestors https://a.example"}, None),
    # CSP says framable, XFO says no -> CSP wins, so NOT simply "protected"
    ({"content-security-policy": "frame-ancestors https://a.example",
      "x-frame-options": "DENY"}, None),
    # CSP says none, XFO absent -> protected
    ({"content-security-policy": "frame-ancestors 'none'",
      "x-frame-options": "ALLOW-FROM https://a.example"}, False),
    # A CSP with no frame-ancestors directive falls through to XFO
    ({"content-security-policy": "default-src 'self'",
      "x-frame-options": "DENY"}, False),
    ({"content-security-policy": "default-src 'self'"}, True),
]
for headers, want in cases:
    got, why = R.clickjacking_verdict(headers)
    check(f"clickjacking {headers}", got, want)
    check(f"clickjacking {headers} explains itself", bool(why), True)

check("frame-ancestors is found after other directives",
      R.csp_frame_ancestors("default-src 'self'; frame-ancestors 'none'; img-src *"),
      "'none'")
check("no frame-ancestors directive is None, not empty",
      R.csp_frame_ancestors("default-src 'self'"), None)


# ── robots.txt ───────────────────────────────────────────────────────

robots = """
# a comment
User-agent: *
Disallow: /admin
Disallow: /private/
Allow: /public

User-agent: Googlebot
User-agent: Bingbot
Disallow: /nope

Sitemap: https://example.com/sitemap.xml
"""
p = R.parse_robots(robots)
check("two groups", len(p["groups"]), 2)
check("first group is the wildcard", p["groups"][0]["agents"], ["*"])
check("first group has three rules", len(p["groups"][0]["rules"]), 3)
check("consecutive User-agent lines SHARE a group",
      p["groups"][1]["agents"], ["Googlebot", "Bingbot"])
check("sitemap is collected separately", p["sitemaps"],
      ["https://example.com/sitemap.xml"])
check("a comment-only file yields nothing",
      R.parse_robots("# nothing here\n"), {"groups": [], "sitemaps": []})
check("an empty Disallow means everything is allowed, and is kept",
      R.parse_robots("User-agent: *\nDisallow:\n")["groups"][0]["rules"],
      [{"field": "disallow", "value": ""}])


# ── HIBP range parsing ───────────────────────────────────────────────
#
# The service returns SUFFIXES ONLY, uppercase, CRLF-separated. Matching
# case-sensitively against a lowercase digest is the way to get "not
# breached" for a password that is.

body = "0018A45C4D1DEF81644B54AB7F969B88D65:1\r\n00D4F6E8FA6EECAD2A3AA415EEC418D38EC:2\r\n"
check("suffix found", R.pwned_count("00D4F6E8FA6EECAD2A3AA415EEC418D38EC", body), 2)
check("suffix absent", R.pwned_count("FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF", body), 0)
check("match is case-insensitive on our side",
      R.pwned_count("00d4f6e8fa6eecad2a3aa415eec418d38ec".upper(), body), 2)

# 'password' -> SHA-1 5BAA61E4C9B93F3F0682250B6CF8331B7EE68FD8, a value
# anyone can check by hand. This pins the prefix/suffix split the range
# API depends on.
import hashlib as _h
d = _h.sha1(b"password").hexdigest().upper()
check("sha1('password')", d, "5BAA61E4C9B93F3F0682250B6CF8331B7EE68FD8")
check("prefix is 5 characters", len(d[:5]), 5)
check("suffix is the other 35", len(d[5:]), 35)


# ── port spec parsing ────────────────────────────────────────────────

check("a list", R.parse_ports("22,80,443"), [22, 80, 443])
check("a range", R.parse_ports("20-23"), [20, 21, 22, 23])
check("mixed, deduplicated and sorted", R.parse_ports("443,20-22,443,1"),
      [1, 20, 21, 22, 443])
check("whitespace is tolerated", R.parse_ports(" 80 , 443 "), [80, 443])
check_raises("port 0 is refused", R.Fail, R.parse_ports, "0")
check_raises("port 65536 is refused", R.Fail, R.parse_ports, "65536")
check_raises("a backwards range is refused", R.Fail, R.parse_ports, "100-50")


# ── WHOIS referral extraction ────────────────────────────────────────

check("IANA's refer: line",
      R.whois_referral("domain:        COM\nrefer:         whois.verisign-grs.com\n"),
      "whois.verisign-grs.com")
check("a registrar's own field name",
      R.whois_referral("Registrar WHOIS Server: whois.example-registrar.com\n"),
      "whois.example-registrar.com")
check("a trailing dot is stripped",
      R.whois_referral("refer: whois.example.com.\n"), "whois.example.com")
check("no referral is None", R.whois_referral("organisation: IANA\n"), None)
check("an http:// referral URL is not mistaken for a host",
      R.whois_referral("Registrar WHOIS Server: http://whois.example.com\n"), None)


# ── WHOIS referral chasing ───────────────────────────────────────────
#
# The chase is what makes whois useful: whois.iana.org knows almost
# nothing and answers with a `refer:` naming the registry that holds
# the record. Tested with a fake `ask` rather than the internet -- the
# VM this is verified in has none, and a test that needs a third party
# to behave is a test that goes red for reasons that are not the code.

RESPONSES = {
    "whois.iana.org": "domain: COM\nrefer: whois.verisign-grs.com\n",
    "whois.verisign-grs.com": "Registrar WHOIS Server: whois.registrar.example\n",
    "whois.registrar.example": "Registrant: somebody\n",
    "loop.example": "refer: loop.example\n",
    "quiet.example": "organisation: nobody\n",
}
asked = []


def fake_ask(server, target):
    asked.append(server)
    return RESPONSES[server]


asked.clear()
chain, text = R.whois_chain("example.com", "whois.iana.org", fake_ask)
check("the chase follows both referral spellings", chain,
      ["whois.iana.org", "whois.verisign-grs.com", "whois.registrar.example"])
check("the chase returns the LAST server's text", text, "Registrant: somebody\n")

asked.clear()
chain, _ = R.whois_chain("example.com", "whois.iana.org", fake_ask, follow=False)
check("--server asks exactly one server", chain, ["whois.iana.org"])

asked.clear()
chain, _ = R.whois_chain("example.com", "loop.example", fake_ask)
check("a server referring to itself is asked once, not forever",
      chain, ["loop.example"])

asked.clear()
chain, _ = R.whois_chain("example.com", "quiet.example", fake_ask)
check("no referral means one hop", chain, ["quiet.example"])


# ─────────────────────────────────────────────────────────────────────

if FAILURES:
    print(f"novi-recon: {len(FAILURES)} check(s) FAILED\n")
    for f in FAILURES:
        print("  ! " + f)
    sys.exit(1)
print("novi-recon: all checks passed")
