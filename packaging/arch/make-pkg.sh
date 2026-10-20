#!/usr/bin/env bash
# Build the Arch pacman package (.pkg.tar.zst) from the payload tar.
# Does NOT use makepkg (it refuses to run as root, which is what CI
# containers run as); we assemble .PKGINFO/.MTREE by hand instead.
# Needs bsdtar (libarchive) and zstd. Note: extracted files are owned by
# root here (CI container), which pacman happily accepts.
set -euo pipefail

usage() {
  cat <<EOF
usage: make-pkg.sh --payload <payload.tar.zst> --version <YYYY.MM.DD> --out <output-dir>
requires: zstd; bsdtar optional (skips .MTREE, packs with GNU tar)
EOF
}
die_usage() {
  usage >&2
  exit 2
}

case ${1:-} in
  -h | --help) usage; exit 0 ;;
esac

payload=''
ver=''
out=''
while [ "$#" -gt 0 ]; do
  case $1 in
    --payload) [ "$#" -ge 2 ] || die_usage; payload=$2; shift 2 ;;
    --version) [ "$#" -ge 2 ] || die_usage; ver=$2; shift 2 ;;
    --out) [ "$#" -ge 2 ] || die_usage; out=$2; shift 2 ;;
    *) die_usage ;;
  esac
done

if [ -z "$payload" ] || [ -z "$ver" ] || [ -z "$out" ]; then die_usage; fi
[ -f "$payload" ] || { echo "make-pkg: no such payload: $payload" >&2; die_usage; }
case $ver in
  '' | *[!0-9.]*) { echo "make-pkg: invalid version '$ver' (expected YYYY.MM.DD, no '-')" >&2; die_usage; } ;;
esac

command -v zstd >/dev/null 2>&1 || {
  echo "make-pkg: zstd not found; pacman packages are .tar.zst" >&2
  exit 1
}

mkdir -p "$out"
case $payload in
  /*) payload_abs=$payload ;;
  *) payload_abs=$PWD/$payload ;;
esac

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

echo "make-pkg: extracting payload into package directory" >&2
mkdir "$work/pkg"
zstd -dc -- "$payload_abs" | tar -xpf - -C "$work/pkg" --strip-components=1

echo "make-pkg: computing size" >&2
size=$(find "$work/pkg" -type f -printf '%s\n' | awk '{s+=$1} END {printf "%.0f\n", s + 0}')
builddate=$(date +%s)

echo "make-pkg: writing .PKGINFO" >&2
cat > "$work/pkg/.PKGINFO" <<EOF
pkgname = lol-on-linux
pkgver = $ver-1
pkgdesc = League of Legends client on x86-64 Linux via Darling
url = https://github.com/SrDicov/lol-on-linux
builddate = $builddate
packager = SrDicov <noreply@users.noreply.github.com>
size = $size
arch = x86_64
license = GPL-3.0
depend = gcc-libs
depend = libx11
depend = libxcb
depend = libxext
depend = alsa-lib
depend = libpulse
depend = python
depend = bash
depend = curl
depend = unzip
depend = libxml2
depend = zstd
depend = zlib
depend = libffi
depend = libbsd
optdepend = gamemode: GPU/latency nice-to-haves
EOF

# The bundled libLLVM lives under /usr/local/lib, which pacman's ldconfig hook
# does not watch, and iridium dlopen()s it by name.
cat > "$work/pkg/.INSTALL" <<'EOF'
post_install() {
  ldconfig
}
post_upgrade() {
  ldconfig
}
post_remove() {
  ldconfig
}
EOF

# .MTREE (checksum manifest) needs bsdtar's mtree format support; skip it
# with a warning if bsdtar is absent (pacman still installs such packages).
echo "make-pkg: generating .MTREE" >&2
(
  cd "$work/pkg" || exit 1
  bsdtar -czf .MTREE --format=mtree \
    --options='!all,use-set,type,uid,gid,mode,time,size,md5,sha256,link' .
) 2>/dev/null || echo "make-pkg: bsdtar missing, skipping .MTREE" >&2

echo "make-pkg: packing" >&2
dest="$out/lol-on-linux-$ver-1-x86_64.pkg.tar.zst"
# Pack the top-level entries by name instead of '.': with '.', every member
# becomes './.PKGINFO' and libalpm reports "missing package metadata" (real
# Arch packages store .PKGINFO, .INSTALL, .MTREE and usr/ at the archive root).
mapfile -t entries < <(ls -A "$work/pkg")
if command -v bsdtar >/dev/null 2>&1; then
  ( cd "$work/pkg" && bsdtar -cf - "${entries[@]}" ) | zstd -q > "$dest"
else
  ( cd "$work/pkg" && tar -cf - "${entries[@]}" ) | zstd -q > "$dest"
fi
echo "make-pkg: wrote $dest" >&2
echo "$dest"
