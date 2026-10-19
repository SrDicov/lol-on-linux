#!/usr/bin/env bash
# Install LLVM/Clang 23 — the toolchain branch the darling-lol patches were
# validated with. Tries the official release tarball(s) first and falls back to
# apt.llvm.org. Works as root (CI container) or via passwordless sudo (host
# runner). Verify with: clang --version
set -euo pipefail
want=${LLVM_VERSION:-23.1.0}
mount=/opt/llvm

run_root() {
  if [ "$(id -u)" = 0 ]; then
    "$@"
  else
    sudo -n env DEBIAN_FRONTEND=noninteractive "$@"
  fi
}

if clang --version 2>/dev/null | head -n 1 | grep -q "clang version 23\."; then
  echo "install-toolchain: clang 23 already present"
  exit 0
fi

cd /tmp
launcher_ok=0
for url in \
  "https://github.com/llvm/llvm-project/releases/download/llvmorg-$want/LLVM-$want-Linux-X64.tar.xz" \
  "https://github.com/llvm/llvm-project/releases/download/llvmorg-$want/clang+llvm-$want-x86_64-linux-gnu-ubuntu-22.04.tar.xz" \
  "https://github.com/llvm/llvm-project/releases/download/llvmorg-$want/LLVM-$want-linux-X64.tar.xz"
do
  echo "install-toolchain: trying $url"
  if curl -fL --retry 3 --retry-delay 2 -o llvm.tar.xz "$url"; then
    launcher_ok=1
    break
  fi
done

if [ "$launcher_ok" = 1 ]; then
  run_root rm -rf "$mount"
  run_root mkdir -p "$mount"
  run_root tar -xJf llvm.tar.xz --strip-components=1 -C "$mount"
  for tool in clang clang++ lld ld.lld ld64.lld llvm-ar llvm-config llvm-ranlib llvm-objcopy; do
    if [ -x "$mount/bin/$tool" ]; then
      run_root ln -sf "$mount/bin/$tool" "/usr/local/bin/$tool"
    fi
  done
  # Make find_package(LLVM CONFIG) resolve this LLVM without extra flags: the
  # /usr/local prefix is always searched. Without it the system LLVM (an old
  # one on the runner image) wins and iridium fails on newer C API entries.
  if [ -d "$mount/lib/cmake/llvm" ]; then
    run_root mkdir -p /usr/local/lib/cmake
    run_root ln -sfn "$mount/lib/cmake/llvm" /usr/local/lib/cmake/llvm
  fi
else
  echo 'install-toolchain: tarballs unavailable; falling back to apt.llvm.org' >&2
  run_root apt-get update -qq
  run_root apt-get install -y -qq --no-install-recommends lsb-release wget gnupg software-properties-common
  wget -qO /tmp/llvm.key https://apt.llvm.org/llvm-snapshot.gpg.key
  run_root gpg --dearmor --yes -o /usr/share/keyrings/llvm.gpg /tmp/llvm.key
  echo "deb [signed-by=/usr/share/keyrings/llvm.gpg] http://apt.llvm.org/jammy/ llvm-toolchain-jammy-23 main" \
    | run_root tee /etc/apt/sources.list.d/llvm.list >/dev/null
  run_root apt-get update -qq
  run_root apt-get install -y -qq --no-install-recommends \
    clang-23 lld-23 llvm-23-dev libclang-rt-23-dev libzstd-dev libcurl4-openssl-dev
  for tool in clang clang++ lld lld-link ld.lld ld64.lld llvm-ar llvm-config llvm-objcopy; do
    if command -v "$tool-23" >/dev/null 2>&1; then
      run_root ln -sf "$(command -v "$tool-23")" "/usr/local/bin/$tool"
    fi
  done
  if [ -d /usr/lib/llvm-23/lib/cmake/llvm ]; then
    run_root mkdir -p /usr/local/lib/cmake
    run_root ln -sfn /usr/lib/llvm-23/lib/cmake/llvm /usr/local/lib/cmake/llvm
  fi
fi

command -v clang >/dev/null 2>&1 || { echo 'install-toolchain: clang is missing after install' >&2; exit 1; }
clang --version | head -n 1
ld.lld --version 2>/dev/null | head -n 1 || true
