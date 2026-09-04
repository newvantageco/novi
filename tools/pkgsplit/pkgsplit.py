#!/usr/bin/env python3
"""
pkgsplit — work out which files in the rootfs belong to the desktop, split
them into packages, and stage each one for `mkpkg`.

RFC 0007. The base image is supposed to be console-only, with the desktop
delivered as packages. Doing that by hand-listing files is how a split
rots: someone adds a library in build/06-wayland.sh, nobody updates the
list, and the "console-only" image quietly grows a Wayland stack again.

So the file set is COMPUTED, from the only thing that cannot lie about it:
the ELF dependency graph.

    desktop  = closure(NEEDED) from the desktop binaries
    keep     = closure(NEEDED) from everything else that ships
    move     = desktop - keep

and then a check that nothing left in `keep` links against anything in
`move`, which turns "I think this is safe" into "the build fails if it
isn't".

Assignment to packages is an explicit table, matched on filename. A file
that matches nothing is a hard error rather than a guess: silently
dropping a library into the wrong package produces an image that installs
cleanly and fails at runtime, which is the worst of both.

Inter-package dependencies are computed the same way -- for every file in
a package, every soname it NEEDs is mapped back to its owning package.
Hand-written depends= lines would be one more thing to forget.
"""

import argparse
import os
import re
import shutil
import subprocess
import sys

# ---------------------------------------------------------------------------
# What counts as "the desktop"
# ---------------------------------------------------------------------------
#
# Binaries, not libraries: the libraries follow from the ELF graph. These
# are the things a console-only machine has no use for.
#
# The fontconfig/libinput/expat utilities are in here for a reason worth
# recording. They are BUILD-TIME tools that `make install` dropped into
# the image (fc-cache, fc-list, libinput, mtdev-test, di-edid-decode,
# xmlwf). While they sit in /usr/bin they are part of the "keep" set, and
# so every library they need -- fontconfig, freetype, libinput, libudev,
# libevdev, libmtdev, libexpat, libdisplay-info -- counts as "needed by
# the base" and can never move. Eight libraries were being held in a
# console image by eight programs nobody would run on one.
DESKTOP_BINARIES = [
    # The desktop proper
    "usr/bin/novi-shell",
    "usr/bin/novi-panel",
    "usr/bin/novi-launcher",
    "usr/bin/novi-settings",
    "usr/bin/novi-lockscreen",
    "usr/bin/novi-screenshot",
    "usr/bin/foot",
    "usr/bin/footclient",
    "usr/bin/seatd",
    "usr/bin/seatd-launch",
    # Tooling that came along with the graphics stack's `make install`
    "usr/bin/fc-cache", "usr/bin/fc-cat", "usr/bin/fc-conflist",
    "usr/bin/fc-genconf", "usr/bin/fc-list", "usr/bin/fc-match",
    "usr/bin/fc-pattern", "usr/bin/fc-query", "usr/bin/fc-scan",
    "usr/bin/fc-validate",
    "usr/bin/libinput",
    "usr/bin/mtdev-test",
    "usr/bin/di-edid-decode",
    "usr/bin/xmlwf",
    "usr/bin/wayland-scanner",
]

LIB_DIRS = ["lib", "usr/lib", "lib64"]

# ---------------------------------------------------------------------------
# Package table
# ---------------------------------------------------------------------------
#
# (package, version-key, description, [filename patterns])
#
# Patterns are matched against the BASENAME of each file to move, in
# order; first match wins. Anything unmatched is fatal.
PACKAGE_TABLE = [
    ("libffi",           "LIBFFI",        "Foreign function interface library",
     [r"^libffi\.so"]),
    ("wayland",          "WAYLAND",       "Wayland core protocol libraries",
     [r"^libwayland-", r"^wayland-scanner$"]),
    ("libdrm",           "LIBDRM",        "Direct Rendering Manager userspace library",
     [r"^libdrm"]),
    ("pixman",           "PIXMAN",        "Low-level pixel manipulation library",
     [r"^libpixman"]),
    ("libxkbcommon",     "LIBXKBCOMMON",  "Keyboard keymap compiler and handling library",
     [r"^libxkbcommon"]),
    ("libudev",          "LIBUDEV",       "Device enumeration library (libudev-zero)",
     [r"^libudev\.so"]),
    ("libevdev",         "LIBEVDEV",      "Wrapper library for evdev input devices",
     [r"^libevdev"]),
    ("libmtdev",         "LIBMTDEV",      "Multitouch protocol translation library",
     [r"^libmtdev", r"^mtdev-test$"]),
    ("libinput",         "LIBINPUT",      "Input device handling library",
     [r"^libinput"]),
    ("libdisplay-info",  "LIBDISPLAYINFO","EDID and DisplayID parsing library",
     [r"^libdisplay-info", r"^di-edid-decode$"]),
    ("expat",            "EXPAT",         "Stream-oriented XML parser",
     [r"^libexpat", r"^xmlwf$"]),
    ("freetype",         "FREETYPE",      "Font rasterisation library",
     [r"^libfreetype"]),
    ("fontconfig",       "FONTCONFIG",    "Font configuration and matching library",
     [r"^libfontconfig", r"^fc-"]),
    ("fcft",             "FCFT",          "Font loading and glyph rasterisation library",
     [r"^libfcft"]),
    ("wlroots",          "WLROOTS",       "Modular Wayland compositor library",
     [r"^libwlroots"]),
    ("seatd",            "SEATD",         "Seat management daemon and client library",
     [r"^libseat", r"^seatd"]),
    ("foot",             "FOOT",          "Fast, lightweight Wayland terminal emulator",
     [r"^foot", r"^footclient$"]),
    ("novi-shell",       "OS",            "The Novi Wayland compositor (RFC 0001)",
     [r"^novi-shell$"]),
    ("novi-panel",       "OS",            "Top bar and taskbar for the Novi desktop",
     [r"^novi-panel$"]),
    ("novi-launcher",    "OS",            "Alt+Space application launcher and symbol picker",
     [r"^novi-launcher$"]),
    ("novi-settings",    "OS",            "Settings: account and declared system state",
     [r"^novi-settings$"]),
    ("novi-lockscreen",  "OS",            "Super+L session lock",
     [r"^novi-lockscreen$"]),
    ("novi-screenshot",  "OS",            "PrintScreen screen capture",
     [r"^novi-screenshot$"]),
]

# Data directories that belong to a package but contain no ELF, so the
# dependency graph cannot find them. Each is (package, rootfs path).
DATA_FILES = [
    # Development files for every library this system ships.
    #
    # These had been going nowhere: the split moved libwayland,
    # libwlroots, libinput and the rest out of the base image and left
    # 5.6 MB of their headers and pkg-config files behind, describing
    # an API the console-only base could not link against even in
    # principle. Orphaned weight, and the reason nothing could be
    # compiled against any of these once RFC 0015 put a compiler on the
    # machine.
    #
    # One package rather than a `-dev` per library, and that is a
    # deliberate coarseness, not an oversight: splitting them properly
    # means mapping each header directory and .pc file to its owning
    # library, and the honest way to do that is to derive it (a .pc
    # file's `-lfoo` names the library the ELF graph already assigns)
    # rather than hand-maintain a second table. Worth doing; not worth
    # doing badly first. §17's "finer-grained packages" roadmap item.
    #
    # Note this takes the alsa and libnl headers too, whose libraries
    # DO stay in the base. That is correct: a header is useless without
    # a compiler, the compiler is a package, and the base has neither.
    ("novi-headers", "usr/include"),
    ("novi-headers", "usr/lib/pkgconfig"),

    ("fontconfig", "etc/fonts"),
    ("fontconfig", "usr/share/fontconfig"),
    ("fonts-jetbrains-mono", "usr/share/fonts"),
    ("foot", "usr/share/terminfo"),
    ("novi-launcher", "usr/share/novi"),
]

# Packages that exist only to pull others in.
META_PACKAGES = [
    ("novi-desktop", "OS", "The Novi desktop: compositor, panel, launcher, terminal",
     ["novi-shell", "novi-panel", "novi-launcher", "novi-settings",
      "novi-lockscreen", "novi-screenshot", "foot", "fonts-jetbrains-mono"]),
]

EXTRA_PACKAGE_DESCRIPTIONS = {
    "fonts-jetbrains-mono": ("JETBRAINS_MONO", "JetBrains Mono, the default terminal font"),
    "novi-headers": ("OS", "Headers and pkg-config files for the libraries Novi ships"),
}


def readelf_needed(readelf, path):
    if os.path.islink(path) or not os.path.isfile(path):
        return []
    try:
        out = subprocess.run([readelf, "-d", path],
                             capture_output=True, text=True).stdout
    except OSError:
        return []
    return [ln.split("[", 1)[1].split("]", 1)[0]
            for ln in out.splitlines()
            if "(NEEDED)" in ln and "Shared library: [" in ln]


class Rootfs:
    def __init__(self, root, readelf):
        self.root = root
        self.readelf = readelf
        self.soname = {}          # soname -> rootfs-relative path
        for d in LIB_DIRS:
            p = os.path.join(root, d)
            if not os.path.isdir(p):
                continue
            for f in sorted(os.listdir(p)):
                self.soname.setdefault(f, os.path.join(d, f))

    def full(self, rel):
        return os.path.join(self.root, rel)

    def needed(self, rel):
        return readelf_needed(self.readelf, self.full(rel))

    def closure(self, seeds):
        seen, queue = set(), [s for s in seeds if os.path.exists(self.full(s))]
        while queue:
            rel = queue.pop()
            if rel in seen:
                continue
            seen.add(rel)
            for so in self.needed(rel):
                tgt = self.soname.get(so)
                if tgt and tgt not in seen:
                    queue.append(tgt)
        return seen

    def all_programs(self):
        out = []
        for d in ["bin", "sbin", "usr/bin", "usr/sbin"]:
            p = os.path.join(self.root, d)
            if not os.path.isdir(p):
                continue
            for f in sorted(os.listdir(p)):
                rel = os.path.join(d, f)
                if os.path.isfile(self.full(rel)) and not os.path.islink(self.full(rel)):
                    out.append(rel)
        return out

    # A library's versioned real file, its soname symlink and its
    # development symlink are one thing, not three. Whichever of them the
    # graph reached, the package needs all of them or the dynamic linker
    # finds a dangling link.
    def siblings(self, rel):
        d, base = os.path.split(rel)
        real = base
        # libfoo.so.1.2.3 / libfoo.so.1 / libfoo.so all share this stem
        stem = re.sub(r"\.so.*$", ".so", base)
        if stem == base and not base.endswith(".so"):
            return [rel]
        out = []
        dirpath = os.path.join(self.root, d)
        if os.path.isdir(dirpath):
            for f in sorted(os.listdir(dirpath)):
                if f == stem or f.startswith(stem + "."):
                    out.append(os.path.join(d, f))
        return out or [rel]


def assign(basename):
    for name, _vkey, _desc, patterns in PACKAGE_TABLE:
        for pat in patterns:
            if re.match(pat, basename):
                return name
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rootfs", required=True)
    ap.add_argument("--readelf", required=True)
    ap.add_argument("--stage", required=True, help="directory to stage packages into")
    ap.add_argument("--arch", default="x86_64")
    ap.add_argument("--versions", required=True,
                    help="path to build/00-versions.sh, for *_VERSION values")
    ap.add_argument("--manifest", required=True,
                    help="write the list of files that moved, for the split stage")
    args = ap.parse_args()

    rf = Rootfs(args.rootfs, args.readelf)

    versions = {}
    with open(args.versions) as f:
        for line in f:
            m = re.match(r'^([A-Z0-9_]+)_VERSION="([^"]*)"', line.strip())
            if m:
                versions[m.group(1)] = m.group(2)

    desktop_seeds = [b for b in DESKTOP_BINARIES if os.path.exists(rf.full(b))]
    keep_seeds = [p for p in rf.all_programs() if p not in set(DESKTOP_BINARIES)]

    desktop_closure = rf.closure(desktop_seeds)
    keep_closure = rf.closure(keep_seeds)
    move = sorted(desktop_closure - keep_closure)

    # Pull in every sibling symlink of each library that moves.
    expanded = set()
    for rel in move:
        for s in rf.siblings(rel):
            expanded.add(s)

    # The ELF graph cannot see dlopen. libdrm loads libdrm_amdgpu /
    # libdrm_nouveau / libdrm_radeon at runtime by name, and
    # libwayland-egl is linked against by GL clients that do not exist
    # yet -- so nothing NEEDs any of them and the closure leaves all
    # four sitting in a "console-only" base image. Found by looking at
    # what was actually left behind after the first split, not by
    # reasoning about it.
    #
    # So the graph is not the only input: it finds what is reachable,
    # and PACKAGE_TABLE claims what is ours. Anything the table claims,
    # that lives in a library directory, and that nothing staying
    # behind needs, moves too. A library the base genuinely uses is
    # still protected -- it is in keep_closure, and the check below
    # would fail the build.
    for d in LIB_DIRS:
        p = os.path.join(args.rootfs, d)
        if not os.path.isdir(p):
            continue
        for f in sorted(os.listdir(p)):
            rel = os.path.join(d, f)
            if rel in keep_closure or rel in expanded:
                continue
            if assign(f) is not None:
                expanded.add(rel)

    move = sorted(expanded)

    # Safety net: nothing that stays may need anything that goes.
    moving_sonames = {os.path.basename(m) for m in move}
    violations = []
    for rel in sorted(keep_closure):
        for so in rf.needed(rel):
            if so in moving_sonames:
                violations.append((rel, so))
    if violations:
        print("ERROR: files staying in the base image link against libraries "
              "being moved out:", file=sys.stderr)
        for rel, so in violations:
            print("  %s needs %s" % (rel, so), file=sys.stderr)
        return 1

    # Assign each moving file to a package.
    contents = {}
    unassigned = []
    for rel in move:
        pkg = assign(os.path.basename(rel))
        if pkg is None:
            unassigned.append(rel)
        else:
            contents.setdefault(pkg, []).append(rel)
    if unassigned:
        print("ERROR: no package owns these files -- add a pattern to "
              "PACKAGE_TABLE rather than letting them land somewhere by "
              "accident:", file=sys.stderr)
        for rel in unassigned:
            print("  " + rel, file=sys.stderr)
        return 1

    # Data directories.
    for pkg, path in DATA_FILES:
        full = rf.full(path)
        if not os.path.exists(full):
            continue
        if os.path.isdir(full):
            for dirpath, _dirs, files in os.walk(full):
                for f in files:
                    p = os.path.join(dirpath, f)
                    contents.setdefault(pkg, []).append(
                        os.path.relpath(p, args.rootfs))
        else:
            contents.setdefault(pkg, []).append(path)

    # Which package owns which soname, so depends= can be computed.
    owner = {}
    for pkg, files in contents.items():
        for rel in files:
            owner[os.path.basename(rel)] = pkg

    meta = {name: (vkey, desc) for name, vkey, desc, _p in PACKAGE_TABLE}
    meta.update({k: v for k, v in EXTRA_PACKAGE_DESCRIPTIONS.items()})

    os.makedirs(args.stage, exist_ok=True)
    built = []
    for pkg in sorted(contents):
        files = sorted(set(contents[pkg]))
        deps = set()
        for rel in files:
            for so in rf.needed(rel):
                o = owner.get(so)
                if o and o != pkg:
                    deps.add(o)

        vkey, desc = meta.get(pkg, ("OS", pkg))
        version = versions.get(vkey) or versions.get("OS") or "0"

        stage = os.path.join(args.stage, pkg)
        shutil.rmtree(stage, ignore_errors=True)
        os.makedirs(os.path.join(stage, "files"))
        for rel in files:
            dst = os.path.join(stage, "files", rel)
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copy2(rf.full(rel), dst, follow_symlinks=False)

        with open(os.path.join(stage, "MANIFEST"), "w") as m:
            m.write("name=%s\n" % pkg)
            m.write("version=%s\n" % version)
            m.write("arch=%s\n" % args.arch)
            if deps:
                m.write("depends=%s\n" % ",".join(sorted(deps)))
            m.write("description=%s\n" % desc)
        built.append((pkg, version, len(files), sorted(deps)))

    # Meta packages: no files, just dependencies.
    for name, vkey, desc, deps in META_PACKAGES:
        deps = [d for d in deps if d in contents]
        stage = os.path.join(args.stage, name)
        shutil.rmtree(stage, ignore_errors=True)
        os.makedirs(os.path.join(stage, "files"))
        with open(os.path.join(stage, "MANIFEST"), "w") as m:
            m.write("name=%s\n" % name)
            m.write("version=%s\n" % (versions.get(vkey) or "0"))
            m.write("arch=%s\n" % args.arch)
            m.write("depends=%s\n" % ",".join(deps))
            m.write("description=%s\n" % desc)
        built.append((name, versions.get(vkey) or "0", 0, deps))

    all_files = sorted({rel for files in contents.values() for rel in files})
    with open(args.manifest, "w") as f:
        for rel in all_files:
            f.write(rel + "\n")

    for pkg, version, n, deps in built:
        print("    %-22s %-8s %3d file(s)  deps: %s"
              % (pkg, version, n, ", ".join(deps) or "-"))
    print("    %d package(s), %d file(s) leave the base image"
          % (len(built), len(all_files)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
