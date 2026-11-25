#!/usr/bin/env python3
"""Localisation completeness report. Phase 6 turns this into a CI gate (exit 1 on any gap)."""
import json
from pathlib import Path

d = Path(__file__).resolve().parent.parent / "lib" / "l10n"
en = {k: v for k, v in json.loads((d / "app_en.arb").read_text()).items() if not k.startswith("@")}
for f in sorted(d.glob("app_*.arb")):
    arb = json.loads(f.read_text())
    if arb["@@locale"] in ("en",):
        continue
    missing = [k for k in en if k not in arb]
    english = [k for k in en if arb.get(k) == en[k] and k != "appName"]
    print(f"{arb['@@locale']}: {len(en) - len(missing) - len(english)}/{len(en)} translated"
          + (f" · {len(english)} English placeholders" if english else ""))
