#!/usr/bin/env python3
"""Collect split-per-ABI APKs and write update.json — the manifest the in-app updater reads.

update.json is uploaded to every GitHub Release; the app fetches
  https://github.com/<repo>/releases/latest/download/update.json
which always resolves to the newest release (no API token, no rate limit).
Usage: make_release.py <repo> <build_number> <tag>
"""
import hashlib
import json
import re
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
repo, build, tag = sys.argv[1], int(sys.argv[2]), sys.argv[3]
version = re.search(r"^version:\s*([\d.]+)", (ROOT / "pubspec.yaml").read_text(), re.M).group(1)
cfg = json.loads((ROOT / "release_notes.json").read_text())
out_dir = ROOT / "dist"
out_dir.mkdir(exist_ok=True)

# Flutter's split-per-abi versionCode = abiCode * 1000 + build number.
ABIS = {"arm64-v8a": ("arm64", 2), "armeabi-v7a": ("armv7", 1), "x86_64": ("x86_64", 4)}
apks = {}
for abi, (short, code) in ABIS.items():
    src = ROOT / "build/app/outputs/flutter-apk" / f"app-{abi}-release.apk"
    if not src.exists():
        continue
    name = f"BuildCrew-{short}.apk"
    shutil.copy(src, out_dir / name)
    data = (out_dir / name).read_bytes()
    apks[abi] = {"url": f"https://github.com/{repo}/releases/download/{tag}/{name}",
                 "sha256": hashlib.sha256(data).hexdigest(), "size": len(data), "versionCode": code * 1000 + build}
if "arm64-v8a" not in apks:
    sys.exit("arm64 APK missing")
shutil.copy(out_dir / "BuildCrew-arm64.apk", out_dir / "BuildCrew.apk")  # simple first-install link

manifest = {"versionName": version, "build": build, "tag": tag, "minSupportedBuild": cfg.get("minSupportedBuild", 0),
            "notes": cfg["notes"], "apks": apks}
(out_dir / "update.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=1))

mb = lambda n: f"{n / 1048576:.1f} MB"
(out_dir / "notes.md").write_text(f"""## BuildCrew {version} (build {build})

{cfg['notes']['en']}

### Install (first time)
Download **BuildCrew.apk** below on your Android phone and open it. Android will ask once to allow installs from your browser.

| Phone type | File | Size |
|---|---|---|
| Most phones (2017 and newer) | BuildCrew.apk / BuildCrew-arm64.apk | {mb(apks['arm64-v8a']['size'])} |
| Older / very low-end phones | BuildCrew-armv7.apk | {mb(apks.get('armeabi-v7a', {}).get('size', 0))} |

### Already installed?
You don't need to download anything — the app shows **"New update ready"** and a notification, and updates itself in place. Your login and data are kept.

<sub>SHA-256 (arm64): `{apks['arm64-v8a']['sha256']}` · signed with the BuildCrew release key</sub>
""")
print(json.dumps(manifest, indent=1))
