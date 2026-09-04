/*
 * novi-verify — Ed25519 signature verification for Novi Linux.
 *
 *     novi-verify <public-key> <signature> <file>
 *
 * Exit 0 if <signature> is a valid Ed25519 signature over <file> under
 * <public-key>; exit 1 otherwise. Nothing is printed on success, so it
 * composes cleanly inside `pkg`.
 *
 * Why this exists at all: `pkg` downloads code over a network and then
 * runs it as root. Verifying a SHA-256 out of the repository index
 * protects the packages, but only if the index itself is trustworthy,
 * and nothing on the target could check a signature -- there is no
 * OpenSSL, no GnuPG, and no libsodium in this base image, deliberately.
 * A package manager whose trust root is "whatever the transport handed
 * me" is not one this project should ship, so the base image gets a
 * ~10 KB verifier instead of a TLS stack.
 *
 * The Ed25519 implementation is TweetNaCl (Bernstein, Janssen, Lange,
 * Schwabe, Van Assche -- public domain, tweetnacl.cr.yp.to), vendored
 * unmodified and hash-pinned in build/01-fetch.sh. It is the smallest
 * audited implementation there is: one C file, no configuration, no
 * assembly, no dependencies. Writing this primitive by hand would be
 * indefensible; picking the 800-line reference implementation the
 * authors publish for exactly this purpose is not.
 *
 * FORMATS, all raw bytes rather than PEM/base64, because parsing is
 * attack surface in the one program that must not have any:
 *
 *   public key   32 bytes
 *   signature    64 bytes (detached)
 *   file         any size up to MAX_MESSAGE
 *
 * build/signing/ produces both from OpenSSL keys.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>

#include "tweetnacl.h"

#define PK_BYTES   32
#define SIG_BYTES  64

/* The signed data here is a repository index or a manifest: kilobytes,
 * not megabytes. crypto_sign_open() needs the whole message plus the
 * signature in memory twice over, so an unbounded read would turn a
 * hostile "index" into an OOM. 16 MiB is far past any real index and
 * far below anything that hurts. */
#define MAX_MESSAGE (16u * 1024u * 1024u)

static void die(const char *msg)
{
    fprintf(stderr, "novi-verify: %s\n", msg);
    exit(1);
}

/* TweetNaCl requires this symbol at link time even though signature
 * verification never generates randomness. Implemented properly rather
 * than stubbed out: a stub that silently returned zeroes would be a
 * catastrophic key-generation bug the moment anyone linked this file
 * into something that does sign. */
void randombytes(unsigned char *out, unsigned long long n)
{
    int fd = open("/dev/urandom", O_RDONLY);
    if (fd < 0)
        die("cannot open /dev/urandom");
    while (n > 0) {
        ssize_t r = read(fd, out, n > 1048576 ? 1048576 : (size_t)n);
        if (r < 1)
            die("short read from /dev/urandom");
        out += r;
        n -= (unsigned long long)r;
    }
    close(fd);
}

/* Read a whole file. `exact` > 0 means the file must be precisely that
 * many bytes -- a truncated key or signature has to be an error, not a
 * verification that quietly fails for the wrong reason. */
static unsigned char *slurp(const char *path, size_t exact, size_t *len_out)
{
    FILE *f = fopen(path, "rb");
    if (!f) {
        fprintf(stderr, "novi-verify: cannot open %s\n", path);
        exit(1);
    }

    size_t cap = exact ? exact + 1 : 65536;
    size_t len = 0;
    unsigned char *buf = malloc(cap);
    if (!buf)
        die("out of memory");

    for (;;) {
        if (len == cap) {
            if (cap >= MAX_MESSAGE)
                die("input too large");
            cap *= 2;
            unsigned char *nb = realloc(buf, cap);
            if (!nb)
                die("out of memory");
            buf = nb;
        }
        size_t r = fread(buf + len, 1, cap - len, f);
        len += r;
        if (r == 0)
            break;
    }
    if (ferror(f))
        die("read error");
    fclose(f);

    if (exact && len != exact) {
        fprintf(stderr, "novi-verify: %s is %zu bytes, expected %zu\n",
                path, len, exact);
        exit(1);
    }
    *len_out = len;
    return buf;
}

int main(int argc, char **argv)
{
    if (argc != 4) {
        fprintf(stderr, "usage: novi-verify <public-key> <signature> <file>\n");
        return 2;
    }

    size_t pk_len, sig_len, msg_len;
    unsigned char *pk  = slurp(argv[1], PK_BYTES,  &pk_len);
    unsigned char *sig = slurp(argv[2], SIG_BYTES, &sig_len);
    unsigned char *msg = slurp(argv[3], 0,         &msg_len);

    /* TweetNaCl's API is the original NaCl one: it verifies a *combined*
     * signed message (signature followed by the message) and hands back
     * the message. Detached signatures are what every tool and every
     * repository layout actually uses, so join them here. */
    size_t sm_len = SIG_BYTES + msg_len;
    unsigned char *sm = malloc(sm_len ? sm_len : 1);
    unsigned char *m  = malloc(sm_len ? sm_len : 1);
    if (!sm || !m)
        die("out of memory");
    memcpy(sm, sig, SIG_BYTES);
    memcpy(sm + SIG_BYTES, msg, msg_len);

    unsigned long long mlen = 0;
    int rc = crypto_sign_open(m, &mlen, sm, (unsigned long long)sm_len, pk);

    free(pk); free(sig); free(msg); free(sm); free(m);

    if (rc != 0) {
        fprintf(stderr, "novi-verify: BAD SIGNATURE on %s\n", argv[3]);
        return 1;
    }
    return 0;
}
