#!/usr/bin/env python3
"""Generate the release manifest.json consumed by install-remote.sh.

See docs/INTERFACES.md section 3 for the schema. Usage:

  ci/make-manifest.py --dir dist --version 2026.10.18 \
      --commit <sha> --url-base https://github.com/OWNER/REPO/releases/download/vX \
      --out dist/manifest.json
"""
import argparse
import datetime
import hashlib
import json
import os
import sys

ASSET_MAP = [
    (".deb", "deb", ["debian", "ubuntu"], "apt"),
    (".rpm", "rpm", ["fedora"], "dnf"),
    (".pkg.tar.zst", "arch", ["arch"], "pacman"),
    (".xbps", "void", ["void"], "xbps"),
    ("payload.tar.zst", "portable", ["*"], None),
]


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", required=True)
    ap.add_argument("--version", required=True)
    ap.add_argument("--commit", required=True)
    ap.add_argument("--url-base", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--mirror", default="")
    ap.add_argument("--glibc-required", default="2.35")
    args = ap.parse_args()

    assets = []
    seen_ids = set()
    for name in sorted(os.listdir(args.dir)):
        path = os.path.join(args.dir, name)
        if not os.path.isfile(path):
            continue
        for suffix, asset_id, families, manager in ASSET_MAP:
            if name.endswith(suffix):
                assets.append(
                    {
                        "id": asset_id,
                        "file": name,
                        "sha256": sha256(path),
                        "size": os.path.getsize(path),
                        "glibc_required": args.glibc_required,
                        "families": families,
                        "manager": manager,
                    }
                )
                seen_ids.add(asset_id)
                break

    expected = {"deb", "rpm", "arch", "void", "portable"}
    missing = sorted(expected - seen_ids)
    if missing:
        print(f"make-manifest: warning: missing assets: {', '.join(missing)}", file=sys.stderr)
    if not assets:
        print("make-manifest: no assets found", file=sys.stderr)
        return 1

    manifest = {
        "schema": 1,
        "version": args.version,
        "released": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "upstream": {
            "repo": "https://github.com/lucannez64/darling-lol",
            "commit": args.commit,
        },
        "url_base": args.url_base.rstrip("/") + "/",
        "mirror_url": args.mirror or None,
        "assets": assets,
    }

    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump(manifest, fh, indent=2)
        fh.write("\n")

    for asset in assets:
        print(f"{asset['file']}: {asset['size']} bytes, {asset['id']}")
    print(f"wrote {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
