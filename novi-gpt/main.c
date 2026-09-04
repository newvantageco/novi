/*
 * novi-gpt — write a two-partition GPT for a Novi installation.
 *
 *     novi-gpt <device> [--esp-mib N]
 *
 * Partition 1: EFI System, N MiB (default 512)
 * Partition 2: Linux filesystem, the rest of the disk
 *
 * Why this exists: BusyBox's fdisk can only create MBR labels. It can
 * READ a GPT ("nor Sun, SGI, OSF or GPT disklabel") and cannot write
 * one, and the installed system is a static BusyBox with no
 * sfdisk, no sgdisk and no parted. Without GPT there is no UEFI
 * install, and without a UEFI install Novi cannot go on most machines
 * built since about 2012.
 *
 * The alternative considered and rejected was an ESP on an MBR label
 * with partition type 0xEF. Plenty of firmware boots that, OVMF
 * included -- which is exactly the problem: it would have passed the
 * test here and failed on somebody's laptop, and "works on my
 * emulator" is not a claim this project should make about the program
 * that partitions your disk.
 *
 * GPT is a small, rigid, well-specified structure, so writing it is
 * bounded work with an unambiguous right answer -- and one that can be
 * checked by tools that did not write it (util-linux's partx and
 * blkid), which is how it was verified.
 *
 * Deliberately NOT a general partitioner. It writes one layout, the
 * one novi-install needs. A tool that can express every layout is a
 * tool that can express the wrong one.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <linux/fs.h>

#define SECTOR        512u
#define ENTRY_COUNT   128u
#define ENTRY_SIZE    128u
#define ENTRY_LBAS    ((ENTRY_COUNT * ENTRY_SIZE) / SECTOR)   /* 32 */
#define ALIGN_LBAS    2048u                                   /* 1 MiB */
#define HEADER_SIZE   92u

/* Type GUIDs, written in the mixed-endian byte order GPT actually
 * stores: first three fields little-endian, last two big-endian.
 * Spelled out as bytes rather than assembled from a string at runtime,
 * because getting that byte order wrong is the classic GPT bug and a
 * literal cannot get it wrong twice. */
static const unsigned char GUID_ESP[16] = {
    /* C12A7328-F81F-11D2-BA4B-00A0C93EC93B */
    0x28,0x73,0x2A,0xC1, 0x1F,0xF8, 0xD2,0x11,
    0xBA,0x4B, 0x00,0xA0,0xC9,0x3E,0xC9,0x3B
};
static const unsigned char GUID_LINUX[16] = {
    /* 0FC63DAF-8483-4772-8E79-3D69D8477DE4 */
    0xAF,0x3D,0xC6,0x0F, 0x83,0x84, 0x72,0x47,
    0x8E,0x79, 0x3D,0x69,0xD8,0x47,0x7D,0xE4
};

static uint32_t crc_table[256];

static void crc_init(void)
{
    for (uint32_t i = 0; i < 256; i++) {
        uint32_t c = i;
        for (int k = 0; k < 8; k++)
            c = (c & 1) ? (0xEDB88320u ^ (c >> 1)) : (c >> 1);
        crc_table[i] = c;
    }
}

static uint32_t crc32b(const void *buf, size_t len)
{
    const unsigned char *p = buf;
    uint32_t c = 0xFFFFFFFFu;
    for (size_t i = 0; i < len; i++)
        c = crc_table[(c ^ p[i]) & 0xFF] ^ (c >> 8);
    return c ^ 0xFFFFFFFFu;
}

static void die(const char *msg)
{
    fprintf(stderr, "novi-gpt: %s\n", msg);
    exit(1);
}

static void die_errno(const char *msg)
{
    fprintf(stderr, "novi-gpt: %s: %s\n", msg, strerror(errno));
    exit(1);
}

static void put16(unsigned char *p, uint16_t v) { p[0]=v; p[1]=v>>8; }
static void put32(unsigned char *p, uint32_t v) { for (int i=0;i<4;i++) p[i]=v>>(8*i); }
static void put64(unsigned char *p, uint64_t v) { for (int i=0;i<8;i++) p[i]=v>>(8*i); }

/* A random RFC 4122 version-4 GUID, stored in GPT byte order. The
 * version and variant bits go in the fields' own byte positions, which
 * for the mixed-endian layout means byte 7 and byte 8. */
static void random_guid(unsigned char out[16])
{
    int fd = open("/dev/urandom", O_RDONLY);
    if (fd < 0)
        die_errno("cannot open /dev/urandom");
    size_t got = 0;
    while (got < 16) {
        ssize_t r = read(fd, out + got, 16 - got);
        if (r < 1)
            die("short read from /dev/urandom");
        got += (size_t)r;
    }
    close(fd);
    out[7] = (unsigned char)((out[7] & 0x0F) | 0x40);  /* version 4   */
    out[8] = (unsigned char)((out[8] & 0x3F) | 0x80);  /* variant RFC */
}

static void write_at(int fd, uint64_t lba, const void *buf, size_t len)
{
    if (lseek(fd, (off_t)(lba * SECTOR), SEEK_SET) == (off_t)-1)
        die_errno("seek failed");
    const unsigned char *p = buf;
    size_t done = 0;
    while (done < len) {
        ssize_t w = write(fd, p + done, len - done);
        if (w < 1)
            die_errno("write failed");
        done += (size_t)w;
    }
}

static uint64_t device_sectors(int fd, const char *path)
{
    uint64_t bytes = 0;
    if (ioctl(fd, BLKGETSIZE64, &bytes) == 0 && bytes > 0)
        return bytes / SECTOR;
    /* Not a block device: a regular file, which is how this gets
     * tested. */
    struct stat st;
    if (fstat(fd, &st) == 0 && S_ISREG(st.st_mode) && st.st_size > 0)
        return (uint64_t)st.st_size / SECTOR;
    fprintf(stderr, "novi-gpt: cannot determine the size of %s\n", path);
    exit(1);
}

/* Build one 128-byte partition entry. `name` is ASCII, stored as
 * UTF-16LE, which for ASCII iseach byte followed by a zero. */
static void make_entry(unsigned char *e, const unsigned char type[16],
                       uint64_t first, uint64_t last, const char *name)
{
    memset(e, 0, ENTRY_SIZE);
    memcpy(e, type, 16);
    random_guid(e + 16);
    put64(e + 32, first);
    put64(e + 40, last);
    put64(e + 48, 0);                     /* attributes */
    for (size_t i = 0; name[i] && i < 35; i++)
        put16(e + 56 + i * 2, (uint16_t)(unsigned char)name[i]);
}

static void make_header(unsigned char *h, uint64_t my_lba, uint64_t alt_lba,
                        uint64_t first_usable, uint64_t last_usable,
                        const unsigned char disk_guid[16],
                        uint64_t entry_lba, uint32_t entries_crc)
{
    memset(h, 0, SECTOR);
    memcpy(h, "EFI PART", 8);
    put32(h + 8,  0x00010000u);           /* revision 1.0 */
    put32(h + 12, HEADER_SIZE);
    put32(h + 16, 0);                     /* header CRC, filled in below */
    put32(h + 20, 0);                     /* reserved */
    put64(h + 24, my_lba);
    put64(h + 32, alt_lba);
    put64(h + 40, first_usable);
    put64(h + 48, last_usable);
    memcpy(h + 56, disk_guid, 16);
    put64(h + 72, entry_lba);
    put32(h + 80, ENTRY_COUNT);
    put32(h + 84, ENTRY_SIZE);
    put32(h + 88, entries_crc);
    /* The header CRC covers exactly header_size bytes with the CRC
     * field itself zeroed -- not the whole sector. */
    put32(h + 16, crc32b(h, HEADER_SIZE));
}

int main(int argc, char **argv)
{
    const char *path = NULL;
    uint64_t esp_mib = 512;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--esp-mib") && i + 1 < argc) {
            esp_mib = strtoull(argv[++i], NULL, 10);
        } else if (argv[i][0] == '-') {
            fprintf(stderr,
                "usage: novi-gpt <device> [--esp-mib N]\n"
                "\n"
                "Writes a GPT with an EFI System partition of N MiB\n"
                "(default 512) and a Linux filesystem partition filling\n"
                "the rest. Everything already on the device is lost.\n");
            return 2;
        } else if (!path) {
            path = argv[i];
        } else {
            die("too many arguments");
        }
    }
    if (!path) {
        fprintf(stderr, "usage: novi-gpt <device> [--esp-mib N]\n");
        return 2;
    }
    if (esp_mib < 33)
        die("--esp-mib must be at least 33 (a FAT32 filesystem needs the room)");

    crc_init();

    int fd = open(path, O_RDWR);
    if (fd < 0)
        die_errno(path);

    uint64_t total = device_sectors(fd, path);
    uint64_t last_lba = total - 1;

    /* Primary: header at 1, entries at 2..33. Backup: entries at
     * last-32..last-1, header at last. */
    uint64_t first_usable = 2 + ENTRY_LBAS;                 /* 34 */
    uint64_t last_usable  = last_lba - ENTRY_LBAS - 1;      /* last-33 */

    uint64_t esp_first = ALIGN_LBAS;                        /* 1 MiB in */
    uint64_t esp_last  = esp_first + esp_mib * (1024 * 1024 / SECTOR) - 1;
    uint64_t root_first = ((esp_last + 1 + ALIGN_LBAS - 1) / ALIGN_LBAS) * ALIGN_LBAS;
    uint64_t root_last  = last_usable;

    if (esp_first < first_usable || root_first >= root_last)
        die("the device is too small for this layout");

    unsigned char entries[ENTRY_COUNT * ENTRY_SIZE];
    memset(entries, 0, sizeof entries);
    make_entry(entries + 0 * ENTRY_SIZE, GUID_ESP,   esp_first,  esp_last,  "NOVI_ESP");
    make_entry(entries + 1 * ENTRY_SIZE, GUID_LINUX, root_first, root_last, "NOVI_ROOT");
    uint32_t entries_crc = crc32b(entries, sizeof entries);

    unsigned char disk_guid[16];
    random_guid(disk_guid);

    /* Protective MBR. One 0xEE partition covering the whole disk (or
     * 0xFFFFFFFF sectors, whichever is smaller), so a tool that only
     * understands MBR sees a full disk it does not recognise rather
     * than free space it might helpfully offer to use. */
    unsigned char mbr[SECTOR];
    memset(mbr, 0, sizeof mbr);
    unsigned char *pe = mbr + 446;
    pe[0] = 0x00;                       /* not bootable */
    pe[1] = 0x00; pe[2] = 0x02; pe[3] = 0x00;   /* start CHS 0/0/2 */
    pe[4] = 0xEE;                       /* GPT protective */
    pe[5] = 0xFF; pe[6] = 0xFF; pe[7] = 0xFF;   /* end CHS, saturated */
    put32(pe + 8, 1);
    put32(pe + 12, (total - 1) > 0xFFFFFFFFull ? 0xFFFFFFFFu : (uint32_t)(total - 1));
    mbr[510] = 0x55; mbr[511] = 0xAA;

    unsigned char primary[SECTOR], backup[SECTOR];
    make_header(primary, 1, last_lba, first_usable, last_usable,
                disk_guid, 2, entries_crc);
    make_header(backup, last_lba, 1, first_usable, last_usable,
                disk_guid, last_usable + 1, entries_crc);

    write_at(fd, 0, mbr, SECTOR);
    write_at(fd, 1, primary, SECTOR);
    write_at(fd, 2, entries, sizeof entries);
    write_at(fd, last_usable + 1, entries, sizeof entries);
    write_at(fd, last_lba, backup, SECTOR);

    if (fsync(fd) != 0)
        die_errno("fsync failed");
    close(fd);

    printf("novi-gpt: %s\n", path);
    printf("  1  NOVI_ESP    %10llu..%-10llu  %llu MiB  EFI System\n",
           (unsigned long long)esp_first, (unsigned long long)esp_last,
           (unsigned long long)esp_mib);
    printf("  2  NOVI_ROOT   %10llu..%-10llu  %llu MiB  Linux filesystem\n",
           (unsigned long long)root_first, (unsigned long long)root_last,
           (unsigned long long)((root_last - root_first + 1) / 2048));
    return 0;
}
