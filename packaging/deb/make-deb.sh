#!/usr/bin/env bash
# Build the Debian package from the payload: extract the tree, write DEBIAN/control
# and wrap it. Uses dpkg-deb when available (CI) and falls back to assembling the
# ar archive by hand (this host has no dpkg).
#
# Usage: make-deb.sh --payload <payload.tar.zst> --version <YYYY.MM.DD> --out <dir>
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: make-deb.sh --payload <payload.tar.zst> --version <YYYY.MM.DD> --out <dir>

Prints the final .deb path as the last line of stdout.
EOF
}

payload=
version=
out=
while [ $# -gt 0 ]; do
  case "$1" in
    --payload) payload=${2:?--payload needs a value}; shift 2 ;;
    --version) version=${2:?--version needs a value}; shift 2 ;;
    --out) out=${2:?--out needs a value}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "make-deb: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ -z "$payload" ] || [ -z "$version" ] || [ -z "$out" ]; then
  usage >&2
  exit 2
fi
[ -f "$payload" ] || { echo "make-deb: payload not found: $payload" >&2; exit 1; }
case "$version" in
  *-*) echo "make-deb: version must not contain '-'" >&2; exit 1 ;;
esac

unset CDPATH
here=$(cd -- "$(dirname -- "$0")" && pwd)
mkdir -p "$out"
out=$(cd "$out" && pwd)

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/pkg"
tar -xpf "$payload" -C "$work/pkg" --strip-components=1
[ -d "$work/pkg/usr/local" ] || { echo 'make-deb: unexpected payload layout (no usr/local)' >&2; exit 1; }

installed_size=$(du -sk "$work/pkg" | cut -f1)
mkdir -p "$work/pkg/DEBIAN"
sed -e "s/@VERSION@/$version/g" -e "s/@INSTALLED_SIZE@/$installed_size/g" \
  "$here/control.in" > "$work/pkg/DEBIAN/control"
chmod 644 "$work/pkg/DEBIAN/control"
# The payload ships its own libLLVM under /usr/local/lib/lol-on-linux/llvm and
# an ld.so.conf.d entry for it; iridium dlopen()s that library by name, so the
# loader cache has to be refreshed after (un)install.
cat > "$work/pkg/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
[ "$1" = configure ] || exit 0
if command -v ldconfig >/dev/null 2>&1; then
  ldconfig
fi
EOF
cat > "$work/pkg/DEBIAN/postrm" <<'EOF'
#!/bin/sh
set -e
if command -v ldconfig >/dev/null 2>&1; then
  ldconfig
fi
EOF
chmod 755 "$work/pkg/DEBIAN/postinst" "$work/pkg/DEBIAN/postrm"

target="$out/lol-on-linux_${version}_amd64.deb"
rm -f "$target"

if command -v dpkg-deb >/dev/null 2>&1; then
  dpkg-deb --root-owner-group --build "$work/pkg" "$target"
else
  # No dpkg on this host: assemble the ar archive by hand. Member order matters
  # (debian-binary first) and xz is understood by every dpkg since Debian 6 /
  # Ubuntu 10.10, unlike zstd.
  printf '2.0\n' > "$work/debian-binary"
  tar --owner=0 --group=0 --numeric-owner -cJf "$work/control.tar.xz" -C "$work/pkg/DEBIAN" .
  tar --owner=0 --group=0 --numeric-owner -cJf "$work/data.tar.xz" -C "$work/pkg" --exclude ./DEBIAN .
  ( cd "$work" && ar rc "$target" debian-binary control.tar.xz data.tar.xz )
fi

echo "$target"
