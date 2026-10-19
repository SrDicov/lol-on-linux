#!/usr/bin/env bash
# Install the LLVM/Clang 22 toolchain from apt.llvm.org. The darling-lol
# patches support LLVM 22 and 23, and 22 is the newest major apt.llvm.org
# builds for jammy (the glibc baseline of the payload). The official LLVM
# release tarballs are static-only, so iridium cannot use them: it dlopen()s
# the shared libLLVM and rejects a mismatched major at runtime, and the payload
# bundles this same library so headers and library always agree.
# Works as root (CI container) or via passwordless sudo (host runner).
# Verify with: clang --version && llvm-config --link-shared --libnames
set -euo pipefail
want=${LLVM_VERSION:-22}

run_root() {
  if [ "$(id -u)" = 0 ]; then
    "$@"
  else
    sudo -n env DEBIAN_FRONTEND=noninteractive "$@"
  fi
}

if clang --version 2>/dev/null | head -n 1 | grep -q "clang version $want\."; then
  echo "install-toolchain: clang $want already present"
  exit 0
fi

codename=$(sed -n 's/^VERSION_CODENAME=//p' /etc/os-release 2>/dev/null | head -n 1) || true
if [ -z "$codename" ]; then
  codename=jammy
fi
case "$codename" in
  jammy|noble|bookworm|trixie) ;;
  *) codename=jammy ;;
esac

echo "install-toolchain: apt.llvm.org llvm-toolchain-$codename-$want"
run_root apt-get update -qq
run_root apt-get install -y -qq --no-install-recommends ca-certificates wget gnupg
wget -qO /tmp/llvm.key https://apt.llvm.org/llvm-snapshot.gpg.key
run_root gpg --dearmor --yes -o /usr/share/keyrings/llvm.gpg /tmp/llvm.key
echo "deb [signed-by=/usr/share/keyrings/llvm.gpg] http://apt.llvm.org/$codename/ llvm-toolchain-$codename-$want main" |
  run_root tee /etc/apt/sources.list.d/llvm.list >/dev/null
run_root apt-get update -qq
run_root apt-get install -y -qq --no-install-recommends \
  "clang-$want" "lld-$want" "llvm-$want-dev" "libclang-rt-$want-dev" \
  libzstd-dev libcurl4-openssl-dev

for tool in clang clang++ lld lld-link ld.lld ld64.lld llvm-ar llvm-ranlib llvm-objcopy; do
  if command -v "$tool-$want" >/dev/null 2>&1; then
    run_root ln -sf "$(command -v "$tool-$want")" "/usr/local/bin/$tool"
  fi
done
if [ -x "/usr/lib/llvm-$want/bin/llvm-config" ]; then
  run_root ln -sf "/usr/lib/llvm-$want/bin/llvm-config" /usr/local/bin/llvm-config
fi
# /usr/local is always searched by find_package(LLVM CONFIG); without this the
# older LLVMs preinstalled on the runner win and iridium cannot compile.
if [ -d "/usr/lib/llvm-$want/lib/cmake/llvm" ]; then
  run_root mkdir -p /usr/local/lib/cmake
  run_root ln -sfn "/usr/lib/llvm-$want/lib/cmake/llvm" /usr/local/lib/cmake/llvm
fi

command -v clang >/dev/null 2>&1 || { echo 'install-toolchain: clang is missing after install' >&2; exit 1; }
clang --version | head -n 1
ld.lld --version 2>/dev/null | head -n 1 || true
llvm-config --version
if ! shared_lib=$(llvm-config --link-shared --libnames); then
  echo 'install-toolchain: this LLVM has no shared libLLVM; iridium needs one' >&2
  exit 1
fi
echo "install-toolchain: shared libLLVM: $shared_lib"
echo "install-toolchain: library file: $(llvm-config --link-shared --libfiles)"
