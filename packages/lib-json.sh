# shellcheck shell=sh
# ============================================================
# /usr/lib/novi/json.sh — emitting JSON from a shell script, once
#
# Sourced by novi-state and novi-agent. It is a file rather than a
# function copied into both for the reason this repository has learned
# three times about C libraries (novi-launcher/fcft, novi-panel/libnl,
# Mesa/zlib): a second copy is a second thing to get wrong, and the
# copy that is wrong is the one nobody is looking at.
#
# THE ESCAPING IS THE WHOLE POINT. Every JSON document this system
# emits is assembled by a shell script out of strings the shell did not
# choose -- a hostname, a filesystem label off a stranger's USB stick,
# an SSID off the air, a package description. One unescaped quote and
# the document an agent is parsing is not a document.
#
# The policy is the one RFC 0024 already argued for the notification
# socket, for the same reason: control characters are DROPPED, not
# escaped; tab and newline become a space; `"` and `\` are escaped;
# length is capped. A JSON string may legally carry \u0001, and no
# consumer of this wants one -- so the smaller, always-valid answer is
# the right one.
#
# UTF-8 above 0x7F passes through unchanged, which is what JSON wants
# and what makes non-English text work. The one input that can still
# produce a document a strict parser rejects is a byte sequence that is
# not valid UTF-8. That is worth knowing rather than papering over:
# stripping the high half would mangle every legitimate non-ASCII name
# to protect against a case that does not arise from any source this
# system reads (novi-mount already reduces a filesystem label to
# [A-Za-z0-9._-] before it becomes a path -- see RFC 0023).
#
# The length cap counts BYTES, so truncating a string longer than
# NOVI_JSON_MAX can in principle split a multi-byte character and leave
# a document a strict parser rejects. Stated rather than hidden: every
# value this system actually emits -- a hostname, a service name, a
# package name, a state value, a CPU model -- is two orders of
# magnitude below the 4096-byte default, so the cap is a guard against
# something already pathological rather than a routine path.
# ============================================================

# No shebang, deliberately: this file is SOURCED, never executed, and a
# shebang on it would invite someone to run it. The `shell=sh` directive
# above is how shellcheck is told which dialect to check it as -- it
# has no other way to know, and defaults to refusing.
NOVI_JSON_MAX="${NOVI_JSON_MAX:-4096}"

# json_str <text>   -> a complete JSON string literal, quotes included
json_str() {
    local s
    # Order is load-bearing: backslash before quote. Doing it the other
    # way turns `"` into `\"` and then that backslash into `\\`, so the
    # quote ends the string.
    # The pipeline's order is all load-bearing:
    #
    #  1. tab and newline become a space FIRST. `cut` is line-oriented
    #     and appends a newline to output that had none, so converting
    #     newlines after it puts a trailing space on EVERY string this
    #     system emits -- which is valid JSON, silently wrong, and was
    #     the first thing the test caught.
    #  2. cut applies the length cap.
    #  3. tr -d then removes the newline cut just added, along with any
    #     other control character.
    #  4. sed escapes backslash BEFORE quote. The other way round turns
    #     `"` into `\"` and then that backslash into `\\`, so the quote
    #     ends the string -- which is the injection this exists to stop.
    s="$(printf '%s' "$1" \
        | tr '\011\012' '  ' \
        | cut -c "1-${NOVI_JSON_MAX}" \
        | tr -d '\000-\037\177' \
        | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
    printf '"%s"' "$s"
}

# json_num <text>   -> a JSON number, or 0 if it is not one.
#
# An unquoted field is the other way to produce an invalid document,
# and "how many bytes free" read out of a file can be empty, a dash, or
# a word on a machine where the thing being measured does not exist.
json_num() {
    case "$1" in
        ''|*[!0-9-]*) printf '0' ;;
        -|-*-*)       printf '0' ;;
        *)            printf '%s' "$1" ;;
    esac
}

# json_bool <text>  -> true when the text is one of the words a shell
#                      script in this repository uses for yes.
json_bool() {
    case "$1" in
        on|yes|true|1|up|enabled) printf 'true' ;;
        *)                        printf 'false' ;;
    esac
}
