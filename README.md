# lol-on-linux

Unofficial, prebuilt packages to run Riot's **macOS League of Legends client** on
Linux through [Darling](https://github.com/darlinghq/darling).

This repository is an extension of
[lucannez64/darling-lol](https://github.com/lucannez64/darling-lol) — all credit
for the runtime work belongs upstream. This repo only builds it in GitHub Actions,
packages it for your distro, and installs it for you.

> **WARNING — account risk.** Using this project can get your account permanently
> banned (Riot's anti-cheat does not run here; upstream documents even 3-day
> suspensions). Do not cheat, do not play ranked, do not use your main account.
> Not affiliated with Riot Games or the Darling project. No Riot content ships
> here: the game is downloaded and installed by Riot's own installer, on first
> launch, with your account.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/SrDicov/lol-on-linux/main/install-remote.sh | bash
```

The installer audits your environment (distro, architecture, kernel, libc, GPU),
installs the required dependencies and drivers, installs the prebuilt runtime
package, and creates the menu entry and desktop shortcut. After that, start
**League of Legends (lol-on-linux)** from your applications menu: the first
launch downloads and runs Riot's official installer (~35 GB).

Run it with `| sudo bash` if you prefer to authenticate sudo up front (the
script never uses root as the target user).

## Requirements

- x86-64, Linux kernel >= 5.14, glibc >= 2.35 (musl is not supported)
- X11 session, or Wayland with Xwayland
- AMD RADV is the validated GPU path upstream; Intel/NVIDIA are experimental
- ~35 GB free disk for the game itself

## Supported distributions (initial)

| Family | Packages | Status |
|---|---|---|
| Ubuntu 22.04+, Debian 12+, and derivatives (Mint, Pop, …) | `.deb` | supported |
| Arch and derivatives (EndeavourOS, CachyOS, Artix, …) | `.pkg.tar.zst` | supported |
| Fedora (recent releases) | `.rpm` | supported |
| Void (glibc) | `.xbps` | supported |

Explicitly unsupported for now: musl distros (Alpine, Void-musl), RHEL clones
(Rocky, Alma, Oracle), and atomic/immutable images (Silverblue, Bazzite,
SteamOS). The installer refuses these with a clear message.

## What gets installed

- Darling runtime (prebuilt) under `/usr/local`
- per-user compatibility overlays, rendered on first run into
  `~/.local/share/lol-on-linux` and `~/.darling`
- `/usr/local/bin/lol-on-linux` — the launcher CLI (`--doctor`, `--verify`,
  `--install-game`, `--first-run`)

Nothing is compiled on your machine; the packages are prebuilt in CI from the
commit pinned in `upstream.lock`.

## Uninstall

Remove the system package (`sudo apt remove lol-on-linux`, `sudo pacman -R
lol-on-linux`, …). The game data (and prefix) lives in `~/.darling` — delete it
manually to reclaim the ~35 GB.

## License

GPL-3.0 (inherited from the upstream tooling). This project distributes no Riot
assets and is not affiliated with Riot Games.
