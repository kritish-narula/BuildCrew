#!/usr/bin/env python3
"""Merge lib/l10n/fragments/*.json into the ARB files.

Fragment format: {"key": {"en": "...", "hi": "...", "hinglish": "...", "placeholders": {"name": "String"|"int"}}}
English goes to app_en.arb (with @key metadata), Hindi to app_hi.arb, and every other locale
gets the English text until translated. Existing keys are overwritten. Exits 1 on conflicts
between fragments that define the same key differently.
"""
import json
import sys
from pathlib import Path

root = Path(__file__).resolve().parent.parent / "lib" / "l10n"
merged: dict[str, dict] = {}
src: dict[str, str] = {}
bad = False
for f in sorted((root / "fragments").glob("*.json")):
    data = json.loads(f.read_text() or "{}")
    for k, v in data.items():
        if k.startswith("_"):
            continue
        if k in merged and merged[k]["en"] != v["en"]:
            print(f"conflict: {k} in {src[k]} and {f.name}")
            bad = True
        merged[k] = v
        src[k] = f.name
if bad:
    sys.exit(1)

for arb_file in sorted(root.glob("app_*.arb")):
    arb = json.loads(arb_file.read_text())
    loc = arb["@@locale"]
    for k, v in merged.items():
        # Hinglish (en_IN) uses the fragment's "hinglish" text, falling back to English.
        arb[k] = (v.get("hinglish") or v["en"]) if loc == "en_IN" else (v.get(loc) or v["en"])
        if loc == "en":
            ph = v.get("placeholders") or {}
            arb[f"@{k}"] = {"placeholders": {n: {"type": t} for n, t in ph.items()}} if ph else {}
    arb_file.write_text(json.dumps(arb, ensure_ascii=False, indent=2) + "\n")
print(f"merged {len(merged)} keys from fragments")
