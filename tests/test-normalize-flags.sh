#!/bin/sh
# Offline test for ci/normalize-flags.sh: rewrites host-CPU flags in a fake
# checkout, is idempotent, refuses non-checkouts and honours LOL_SKIP_NORMALIZE.
set -eu

unset CDPATH
repo_root=$(cd -- "$(dirname -- "$0")/.." && pwd)
tool="$repo_root/ci/normalize-flags.sh"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

mkdir -p "$work/fake/scripts" "$work/fake/tools/backend"
printf 'cc -march=native -O3\n' > "$work/fake/scripts/build.sh"
printf '{"cmd": "-march=native"}\n' > "$work/fake/tools/backend/tool.py"
printf 'no flags here\n' > "$work/fake/tools/plain.txt"

sh "$tool" "$work/fake" >/dev/null

if grep -q -- '-march=x86-64' "$work/fake/scripts/build.sh"; then
  pass 'scripts/build.sh is rewritten'
else
  fail 'scripts/build.sh is rewritten'
fi
if grep -q -- '-march=x86-64' "$work/fake/tools/backend/tool.py"; then
  pass 'tools/backend/tool.py is rewritten'
else
  fail 'tools/backend/tool.py is rewritten'
fi
if grep -rq -- '-march=native' "$work/fake"; then
  fail 'no -march=native left behind'
else
  pass 'no -march=native left behind'
fi

if out=$(sh "$tool" "$work/fake") && printf '%s' "$out" | grep -q 'nothing to do'; then
  pass 'second run is a no-op'
else
  fail 'second run is a no-op'
fi

if sh "$tool" "$work" >/dev/null 2>&1; then
  fail 'rejects a non-checkout'
else
  pass 'rejects a non-checkout'
fi

mkdir -p "$work/fake2/scripts" "$work/fake2/tools"
printf '%s\n' 'cc -march=native' > "$work/fake2/scripts/build.sh"
LOL_SKIP_NORMALIZE=1 sh "$tool" "$work/fake2" >/dev/null
if grep -q -- '-march=native' "$work/fake2/scripts/build.sh"; then
  pass 'LOL_SKIP_NORMALIZE leaves files untouched'
else
  fail 'LOL_SKIP_NORMALIZE leaves files untouched'
fi

if [ "$fails" != 0 ]; then
  echo "$fails test(s) failed"
  exit 1
fi
echo 'test-normalize-flags: all tests passed'
