#!/bin/bash
# ============================================================
# test-network-static.sh — the address validators, and the one resolver
#
# RFC 0033. Two things are checked here and both are checked on the
# host because the interesting cases are the ones a running machine
# never produces.
#
# THE VALIDATORS. `network.address` is the first value in system.conf
# that becomes an argument to `ip addr add`, so a value that gets past
# novi-state costs the machine its network and reports it in `ip`'s
# words rather than as a key in a file. The cases worth having are
# textual: an octet of 256, a leading zero (octal to one reader and
# decimal to another), three octets, five octets, a leading dot -- and
# that last one is the reason this file exists at all, because field
# splitting DROPS the empty field `.1.2.3` produces and a naive
# four-octet count passes it.
#
# THE RESOLVER. /run/novi/resolv.conf has one writer
# (/usr/lib/novi/resolv.sh) with one rule: a declared network.dns beats
# the lease, `auto` asks for the lease's answer. That rule used to
# exist twice, and the second copy had already lost the `search` line.
#
# Runs the real files under the SHIPPED BusyBox ash where one is
# built, for the reason CLAUDE.md records about packages/pkg: testing
# the shell answers a different question than testing the image.
# ============================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

STATE=packages/novi-state
RESOLV_LIB="$(pwd)/packages/lib-resolv.sh"
BUSYBOX=/build/rootfs/bin/busybox

if [ -x "${BUSYBOX}" ]; then
    SH=("${BUSYBOX}" ash)
    echo ">>> network static, under the shipped busybox ash"
else
    SH=(sh)
    echo ">>> network static, under host sh (no shipped busybox found)" >&2
fi

checks=0
fail=0
note() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }
did() { checks=$((checks + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# ── 1. the validators, called out of the real novi-state ─────────────
#
# Sourced rather than reimplemented: a test with its own copy of the
# rule tests the copy.
cat > "${TMP}/validate" <<'DRIVER'
#!/bin/sh
# novi-state runs its dispatcher at the bottom of the file, so it is
# read up to the marker and no further -- enough for the functions,
# not enough to do anything.
sed '/^observe_network() {/,$d' "$1" > /tmp/novi-state-funcs.$$
. /tmp/novi-state-funcs.$$
rm -f /tmp/novi-state-funcs.$$
shift
case "$1" in
    cidr)    valid_cidr "$2" && echo yes || echo no ;;
    gateway) valid_gateway "$2" && echo yes || echo no ;;
    cidr6)   valid_cidr6 "$2" && echo yes || echo no ;;
    gw6)     valid_gateway6 "$2" && echo yes || echo no ;;
esac
DRIVER
chmod +x "${TMP}/validate"

v() { "${SH[@]}" "${TMP}/validate" "$(pwd)/${STATE}" "$1" "$2" 2>/dev/null; }

for good in dhcp 192.168.1.50/24 10.0.2.15/24 0.0.0.0/1 255.255.255.255/32 172.16.0.1/12; do
    did; [ "$(v cidr "$good")" = "yes" ] || note "network.address '${good}' should be accepted"
done

# Each of these is a real mistake, not a fuzz case.
for bad in \
    ""                  `# empty` \
    "192.168.1.50"      `# no prefix -- the netmask is not ours to guess` \
    "192.168.1.256/24"  `# octet over 255` \
    "192.168.010.5/24"  `# leading zero: octal to some readers, decimal to others` \
    ".1.2.3/24"         `# leading dot -- splitting drops the empty field` \
    "1.2.3./24"         `# trailing dot` \
    "1.2..3/24"         `# empty octet` \
    "1.2.3/24"          `# three octets` \
    "1.2.3.4.5/24"      `# five octets` \
    "1.2.3.4/33"        `# prefix over 32` \
    "1.2.3.4/0"         `# a host address is not /0` \
    "1.2.3.4/"          `# empty prefix` \
    "1.2.3.4/24/8"      `# two prefixes` \
    "DHCP"              `# not the keyword; case matters` \
    "192.168.1.5/2a"    `# non-numeric prefix` \
    ; do
    did; [ "$(v cidr "$bad")" = "no" ] || note "network.address '${bad}' should be REFUSED"
done

for good in auto none "" 192.168.1.1 10.0.2.2; do
    did; [ "$(v gateway "$good")" = "yes" ] || note "network.gateway '${good}' should be accepted"
done
for bad in 192.168.1.256 1.2.3 "192.168.1.1/24" gateway; do
    did; [ "$(v gateway "$bad")" = "no" ] || note "network.gateway '${bad}' should be REFUSED"
done

# ── 1b. IPv6 (RFC 0033 roadmap 1) ────────────────────────────────────
#
# The sharp edges are NOT IPv4's, which is why there are two validators
# rather than one with a branch:
#
#   * `::` may appear at most once and cannot be found by splitting --
#     field splitting on `:` drops the empty fields it produces, the
#     same trap that made `.1.2.3` pass a naive four-octet count;
#   * LEADING ZEROS ARE FINE. `0001` is 1 to every reader because hex
#     has no octal convention, so the v4 rule that rejects `010` must
#     not be carried over;
#   * the last 32 bits may be a dotted quad, and "last" is a POSITION:
#     `::1.2.3.4:5` and `1.2.3.4::` are not addresses.
for good in auto none "" "::1/128" "2001:db8::5/64" "fe80::1/64" \
            "1:2:3:4:5:6:7:8/64" "::ffff:192.0.2.1/96" "2001:DB8::1/48" \
            "0001:0002:0003:0004:0005:0006:0007:0008/128"; do
    did; [ "$(v cidr6 "$good")" = "yes" ] || note "network.address6 '${good}' should be accepted"
done

for bad in \
    "2001:db8::5"       `# no prefix -- the same rule as v4` \
    "2001:db8::5/129"   `# prefix over 128` \
    "2001:db8::5/0"     `# a host address is not /0` \
    "1::2::3/64"        `# two ::` \
    "12345::1/64"       `# five hex digits` \
    ":1:2:3:4:5:6:7/64" `# a leading single colon` \
    "1:2:3:4:5:6:7:/64" `# a trailing single colon` \
    "::1:/64"           `# a trailing colon after the ::` \
    "1:2:3:4:5:6:7/64"  `# seven groups and no ::` \
    "1:2:3:4:5:6:7:8:9/64" `# nine groups` \
    "fe80::1%eth0/64"   `# a zone id: the interface has its own key` \
    "::1.2.3.4:5/64"    `# a group after the dotted quad` \
    "1.2.3.4::/64"      `# a dotted quad that is not the last 32 bits` \
    "gg::1/64"          `# not hex` \
    "::ffff:192.0.2.256/96" `# the v4 tail is still a v4 address` \
    "dhcp"              `# DHCPv6 is a protocol this system does not speak` \
    ; do
    did; [ "$(v cidr6 "$bad")" = "no" ] || note "network.address6 '${bad}' should be REFUSED"
done

for good in auto none "" "fe80::1" "2001:db8::1" "::1"; do
    did; [ "$(v gw6 "$good")" = "yes" ] || note "network.gateway6 '${good}' should be accepted"
done
for bad in "2001:db8::1/64" "192.168.1.1" "1::2::3" gateway; do
    did; [ "$(v gw6 "$bad")" = "no" ] || note "network.gateway6 '${bad}' should be REFUSED"
done

# ── 1c. the same validator, against inet_pton ────────────────────────
#
# THE HAND-WRITTEN LIST ABOVE IS NOT THE VERIFICATION, and cannot be:
# it contains the cases somebody thought of, and IPv6's grammar has
# more corners than that. `ip addr add` parses with inet_pton, so
# inet_pton is the oracle -- and comparing against it found two real
# bugs the list had missed (`1.2.3.4::` and `::1:`, both accepted).
#
# The corpus is GENERATED rather than listed: every group count with a
# `::` inserted at every position, dotted quads in every position, and
# colon torture. python3 is already required by scripts/lint.sh, so
# this does not skip itself -- a test that skips where it would have
# caught something skips exactly where it matters.
if command -v python3 >/dev/null 2>&1; then
    cat > "${TMP}/fuzz6.py" <<'FUZZ'
import socket, subprocess, random, sys
state, shell = sys.argv[1], sys.argv[2:]
random.seed(20260915)
groups = ["0","1","a","ff","abcd","0001","FFFF","00000","12345","g","1g","","0x1","-1"]
cases = set()
for n in range(1, 10):
    for _ in range(60):
        gs = [random.choice(groups) for _ in range(n)]
        cases.add(":".join(gs))
        for pos in range(n + 1):
            cases.add(":".join(gs[:pos] + [""] + gs[pos:]).replace(":::", "::"))
quads = ["1.2.3.4","192.0.2.1","256.0.0.1","1.2.3","1.2.3.4.5","0.0.0.0","255.255.255.255"]
for n in range(0, 8):
    for q in quads:
        gs = ["1"] * n
        cases.add(":".join(gs + [q]))
        cases.add("::" + (":".join(gs + [q]) if gs else q))
        cases.add(":".join([q] + gs))
for c in ["", ":", "::", ":::", "::::"]:
    for a in ["", "1", "1:2", "1:2:3:4:5:6:7:8"]:
        for b in ["", "1", "8", "1:2:3"]:
            cases.add(a + c + b)
cases = sorted(x for x in cases if len(x) < 60)

def oracle(a):
    try:
        socket.inet_pton(socket.AF_INET6, a); return True
    except (OSError, ValueError, UnicodeEncodeError):
        return False

drv = "%s.sh" % sys.argv[1].rsplit("/", 1)[-1]
import tempfile, os
fd, drv = tempfile.mkstemp(suffix=".sh"); os.close(fd)
with open(drv, "w") as fh:
    fh.write("#!/bin/sh\nsed '/^observe_network() {/,$d' \"$1\" > $1.funcs.$$\n"
             ". $1.funcs.$$\nrm -f $1.funcs.$$\n")
    for a in cases:
        fh.write("valid_ipv6 %s && echo yes || echo no\n"
                 % ("'" + a.replace("'", "'\\''") + "'"))
out = subprocess.run(shell + [drv, state], capture_output=True, text=True).stdout.split()
os.unlink(drv)
if len(out) != len(cases):
    print("DRIVER: %d answers for %d cases" % (len(out), len(cases))); sys.exit(2)
bad = [(a, g) for a, g in zip(cases, out) if g != ("yes" if oracle(a) else "no")]
for a, g in bad[:20]:
    print("  %r: novi-state=%s inet_pton=%s" % (a, g, "yes" if oracle(a) else "no"))
print("CASES %d BAD %d" % (len(cases), len(bad)))
sys.exit(1 if bad else 0)
FUZZ
    # The state file is copied so the driver's temp files land in TMP.
    cp "${STATE}" "${TMP}/novi-state"
    out="$(python3 "${TMP}/fuzz6.py" "${TMP}/novi-state" "${SH[@]}" 2>&1)"
    rc=$?
    did
    if [ "${rc}" -ne 0 ]; then
        note "valid_ipv6 disagrees with inet_pton:"
        printf '%s\n' "${out}" >&2
    else
        echo ">>> $(printf '%s' "${out}" | sed -n 's/CASES \([0-9]*\) BAD.*/\1/p') generated IPv6 cases agree with inet_pton"
    fi
else
    note "python3 is missing, so valid_ipv6 was not checked against inet_pton"
    did
fi

# ── 2. the one resolver writer ───────────────────────────────────────
#
# Run against a redirected /run so this never touches the machine.
cat > "${TMP}/resolv-driver" <<'DRIVER'
#!/bin/sh
. "$1"
NOVI_RESOLV_RUN_DIR="$2"
NOVI_RESOLV_FILE="${NOVI_RESOLV_RUN_DIR}/resolv.conf"
NOVI_RESOLV_DNS_FILE="${NOVI_RESOLV_RUN_DIR}/network.dns"
novi_write_resolv "$3" "$4" "$5"
echo "status=$?"
DRIVER
chmod +x "${TMP}/resolv-driver"

RUN="${TMP}/run"
mkdir -p "$RUN"
wr() { "${SH[@]}" "${TMP}/resolv-driver" "$RESOLV_LIB" "$RUN" "test" "$1" "${2:-}"; }

# A lease's servers, with network.dns unset.
rm -f "${RUN}/network.dns"
out="$(wr "1.1.1.1 8.8.8.8" "lan.example")"
did; grep -qx "nameserver 1.1.1.1" "${RUN}/resolv.conf" || note "a lease's servers should be written"
did; grep -qx "search lan.example" "${RUN}/resolv.conf" || note "the lease's search domain should be written"
did; case "${out}" in *"status=0"*) ;; *) note "writing real servers should return 0" ;; esac

# A declared network.dns beats the lease -- the whole rule.
printf 'auto\n' > "${RUN}/network.dns"
wr "1.1.1.1" >/dev/null
did; grep -qx "nameserver 1.1.1.1" "${RUN}/resolv.conf" || note "'auto' should take the lease's answer"

printf '9.9.9.9,149.112.112.112\n' > "${RUN}/network.dns"
wr "1.1.1.1" >/dev/null
did; grep -qx "nameserver 9.9.9.9" "${RUN}/resolv.conf" || note "a declared network.dns should win over the lease"
did; grep -qx "nameserver 149.112.112.112" "${RUN}/resolv.conf" || note "every declared server should be written"
# Anchored: the file's own header names 1.1.1.1 in the example it
# prints, so an unanchored grep matches the comment and this check
# could never fail. It did not, first time round.
did; grep -qx "nameserver 1.1.1.1" "${RUN}/resolv.conf" && note "the lease's server must not survive a declared network.dns"

# THE STATIC TRAP: no lease, and network.dns left at its shipped
# default. The result is a resolver file naming nobody, and the writer
# has to SAY so -- a machine with an address and no DNS looks like a
# broken network rather than an unfinished declaration.
printf 'auto\n' > "${RUN}/network.dns"
out="$(wr "" "")"
did; case "${out}" in *"status=1"*) ;; *) note "no servers at all must report failure, not silence" ;; esac
did; grep -q "^nameserver" "${RUN}/resolv.conf" && note "there should be no nameserver line when nothing supplied one"
# ...and the file is still REWRITTEN, or a stale resolver from the
# previous configuration would sit there looking current.
did; grep -q "Generated by test" "${RUN}/resolv.conf" || note "the file must be rewritten even when it names no server"

if [ "${fail}" -ne 0 ]; then
    echo "network static: ${fail} check(s) FAILED of ${checks}" >&2
    exit 1
fi
echo "network static: ${checks} checks passed"
