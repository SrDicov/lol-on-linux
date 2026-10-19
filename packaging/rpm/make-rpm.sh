#!/usr/bin/env bash
# Build the RPM wrapper from the payload tar. Repackages the payload as-is.
# Run on a normal Linux host (e.g. an Ubuntu CI runner); needs the `rpm`
# package (rpmbuild) and zstd. Prints the final package path as the last
# line of stdout. Usage: see --help.
set -euo pipefail

case $0 in
  */*) script_dir=${0%/*} ;;
  *) script_dir=. ;;
esac

usage() {
  cat <<EOF
usage: make-rpm.sh --payload <payload.tar.zst> --version <YYYY.MM.DD> --out <output-dir>
requires: rpmbuild (rpm), zstd, tar
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
[ -f "$payload" ] || { echo "make-rpm: no such payload: $payload" >&2; die_usage; }
case $ver in
  '' | *[!0-9.]*) { echo "make-rpm: invalid version '$ver' (expected YYYY.MM.DD, no '-')" >&2; die_usage; } ;;
esac

command -v rpmbuild >/dev/null 2>&1 || {
  echo "make-rpm: rpmbuild not found; install the 'rpm' package (e.g. apt-get install -y rpm)" >&2
  exit 1
}
command -v zstd >/dev/null 2>&1 || {
  echo "make-rpm: zstd not found; install zstd" >&2
  exit 1
}

mkdir -p "$out"
case $payload in
  /*) payload_abs=$payload ;;
  *) payload_abs=$PWD/$payload ;;
esac

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

echo "make-rpm: rendering spec for version $ver" >&2
# @VERSION@ and @PAYLOAD@ are substituted with plain sed (no rpmbuild macros);
# the payload path is additionally passed as --define payload_path, which the
# spec's %install section reads via %{payload_path}.
sed \
  -e "s|@VERSION@|$ver|g" \
  -e "s|@PAYLOAD@|$payload_abs|g" \
  "$script_dir/lol-on-linux.spec.in" > "$work/lol-on-linux.spec"

echo "make-rpm: building package (payload copied into buildroot)" >&2
if ! rpmbuild -bb \
    --define "_topdir $work/rpmbuild" \
    --define "payload_path $payload_abs" \
    "$work/lol-on-linux.spec" > "$work/rpmbuild.log" 2>&1; then
  echo "make-rpm: rpmbuild failed; last log lines:" >&2
  tail -n 30 -- "$work/rpmbuild.log" >&2
  exit 1
fi

built_list=$(find "$work/rpmbuild/RPMS" -type f -name '*.rpm')
built=${built_list%%$'\n'*}
[ -n "$built" ] || { echo "make-rpm: rpmbuild produced no .rpm" >&2; exit 1; }

dest="$out/lol-on-linux-$ver-1.x86_64.rpm"
cp -- "$built" "$dest"
echo "make-rpm: wrote $dest" >&2
echo "$dest"
