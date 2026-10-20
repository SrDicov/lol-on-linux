#!/usr/bin/env bash
# Build the Void Linux package (.xbps) from the payload tar.
# Must run inside a Void Linux container (xbps-create), as in CI.
# Prints the final package path as the last line of stdout.
set -euo pipefail

usage() {
  cat <<EOF
usage: make-xbps.sh --payload <payload.tar.zst> --version <YYYY.MM.DD> --out <output-dir>
requires: xbps-create, zstd (Void Linux environment)
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
[ -f "$payload" ] || { echo "make-xbps: no such payload: $payload" >&2; die_usage; }
case $ver in
  '' | *[!0-9.]*) { echo "make-xbps: invalid version '$ver' (expected YYYY.MM.DD, no '-')" >&2; die_usage; } ;;
esac

command -v xbps-create >/dev/null 2>&1 || {
  echo "make-xbps: xbps-create not found; this script must run inside a Void Linux container" >&2
  exit 1
}
command -v zstd >/dev/null 2>&1 || {
  echo "make-xbps: zstd not found; install zstd" >&2
  exit 1
}

mkdir -p "$out"
case $payload in
  /*) payload_abs=$payload ;;
  *) payload_abs=$PWD/$payload ;;
esac

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

echo "make-xbps: extracting payload into package directory" >&2
mkdir "$work/pkg"
zstd -dc -- "$payload_abs" | tar -xpf - -C "$work/pkg" --strip-components=1

echo "make-xbps: creating package" >&2
# -s one-line summary, -m maintainer, -l license, -H homepage,
# -D space-separated runtime dependency names. Verify the flag against this
# build's xbps-create --help so an upstream rename fails loudly here first.
if ! xbps-create --help 2>&1 | grep -q -- --dependencies; then
  echo "make-xbps: xbps-create -D/--dependencies flag not recognized by this version" >&2
  exit 1
fi

# xbps never runs ldconfig (no trigger, no code path: grepped the whole source),
# and the bundled libLLVM sits outside the loader's default search path, so the
# cache is the only way dlopen() finds it by name. A destdir ./INSTALL file is
# xbps's install script slot, and xbps-create consumes it as metadata instead of
# shipping it. No case label on "$1": the action is bare "post", ldconfig is
# idempotent, and guessing the spelling is how that check would silently rot.
cat >"$work/pkg/INSTALL" <<'EOF'
#!/bin/sh
command -v ldconfig >/dev/null 2>&1 && ldconfig
exit 0
EOF

# xbps-create has no -o/--output: it always writes into the cwd.
mkdir -p "$work/repodir"
(cd "$work/repodir" && xbps-create \
  -A x86_64 \
  -n "lol-on-linux-${ver}_1" \
  -s "League of Legends client on x86-64 Linux via Darling" \
  -m "SrDicov <noreply@users.noreply.github.com>" \
  -l GPL-3.0 \
  -H https://github.com/SrDicov/lol-on-linux \
  -D "libstdc++>=1 libX11>=1 libxcb>=1 libXext>=1 alsa-lib>=1 pulseaudio>=1 python3>=1 bash>=1 curl>=1 unzip>=1 libxml2>=1 libzstd>=1 zlib>=1 libffi>=1" \
  "$work/pkg")

built_list=$(find "$work/repodir" -maxdepth 1 -type f -name '*.xbps')
built=${built_list%%$'\n'*}
[ -n "$built" ] || { echo "make-xbps: xbps-create produced no .xbps" >&2; exit 1; }

# Keep xbps-create's own file name: it is <name>-<version>_<rev>.<arch>.xbps and
# xbps derives the archive it fetches from the pkgver, so renaming it to
# lol-on-linux_... makes the transaction fail to checksum a file that is not
# there.
dest="$out/$(basename -- "$built")"
mv -- "$built" "$dest"
echo "make-xbps: wrote $dest" >&2
echo "$dest"
