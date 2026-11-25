"""India labour price model + "Fair Wage Shield".

One model, mirrored 1:1 in `mobile/lib/core/demo_api.dart` (keep both in sync).

Rates are tier-1 (metro) labour-only rupees from the 2025-26 analyst notes:
  mason 650-1,000/day · carpenter 900-1,800/day · plumber 280-450/point, visit 250-400
  electrician socket/switch 250-400, new point 800-1,300, rewiring ~375-625/point
  painter 8-12/sq ft labour · helper 500-700/day.
City multiplier: tier-1 = 1.0, tier-2 = 0.85, anything else 0.8.
"""
import math
import re
from typing import Iterable

# ------------------------------------------------------------------ city tiers
TIER1 = {"mumbai", "delhi", "new delhi", "bengaluru", "bangalore", "pune", "hyderabad", "chennai", "kolkata", "ahmedabad"}
TIER2 = {"jaipur", "lucknow", "chandigarh", "ludhiana", "jalandhar", "amritsar", "indore", "nagpur", "surat", "kochi",
         "bhopal", "coimbatore", "vadodara", "patna", "kanpur", "nashik", "visakhapatnam", "thane", "noida", "gurugram",
         "gurgaon", "ghaziabad", "faridabad", "mohali", "dehradun", "ranchi", "raipur", "bhubaneswar", "guwahati",
         "thiruvananthapuram", "madurai", "mysuru", "mysore", "rajkot", "agra", "varanasi", "meerut", "patiala"}


def city_multiplier(city: str | None) -> float:
    c = (city or "").strip().lower()
    if c in TIER1:
        return 1.0
    if c in TIER2:
        return 0.85
    return 0.8


# ------------------------------------------------------------------ minimum wage (Fair Wage Shield)
# !!! PLACEHOLDER VALUES !!! Approximate central-sphere construction rates per 8-hour day.
# They MUST be verified against the current Chief Labour Commissioner (Central) notification and the
# relevant STATE notification (state rates differ and are revised every April/October) BEFORE LAUNCH.
MIN_WAGE_PER_DAY = {"unskilled": 783, "semi_skilled": 868, "skilled": 954}
TRADE_SKILL = {"helper": "unskilled", "painter": "semi_skilled",
               "mason": "skilled", "carpenter": "skilled", "plumber": "skilled", "electrician": "skilled"}


def min_wage_per_day(trade: str) -> int:
    return MIN_WAGE_PER_DAY[TRADE_SKILL.get(trade, "skilled")]


# ------------------------------------------------------------------ unit rates: (low, median, high) tier-1 rupees
DAY_RATE = {"mason": (650, 850, 1000), "carpenter": (900, 1300, 1800), "plumber": (650, 800, 1000),
            "electrician": (700, 900, 1200), "painter": (700, 900, 1100), "helper": (500, 600, 700)}
WALL_PER_SQFT = (60, 75, 90)        # compound/brick wall labour incl. helper, per sq ft of wall face
WALL_FT_PER_DAY = 9                 # one crew-day per ~9 ft of 5 ft wall
TILING_PER_SQFT = (45, 60, 80)
PLASTER_PER_SQFT = (25, 32, 40)
PAINT_PER_SQFT = (8, 10, 12)        # interior painting labour only
PAINT_DEFAULT_SQFT = 750            # a kitchen / one-room job when no area is written
PAINT_SQFT_PER_DAY = 250
PLUMB_POINT = (280, 360, 450)
PLUMB_SMALL_FIX = (400, 550, 700)   # tap / leak visit
PLUMB_VISIT = (250, 320, 400)
ELEC_SOCKET = (250, 320, 400)       # install socket / switch
ELEC_NEW_POINT = (800, 1050, 1300)
ELEC_REWIRE_POINT = (375, 500, 625)
ELEC_VISIT = (200, 280, 350)

SAMPLE_JOBS = {  # typical jobs; used by the seed to build realistic price history
    "mason": ["Compound wall 40 ft, 5 ft height", "Plaster damaged wall, 1 day", "Bathroom floor tiling 60 sq ft",
              "Brick wall repair 2 days", "Compound wall 20 ft"],
    "plumber": ["Bathroom tap leak", "Fix leaking pipe", "Install 3 plumbing points", "Replace kitchen tap",
                "Full flat pipeline replacement"],
    "electrician": ["Rewire kitchen, 4 points", "Install 3 sockets", "Fix switchboard", "Add 2 new points",
                    "Fan and light installation 4 points"],
    "carpenter": ["Fix wardrobe door hinge", "Repair 2 drawers", "Door repair 2 days", "Modular kitchen repair"],
    "painter": ["Paint kitchen", "Repaint living room 900 sq ft", "Paint bedroom 400 sq ft", "Touch-up door grill"],
    "helper": ["Material shifting 2 days", "Debris removal", "Site cleaning 1 day", "Helper for mason 3 days"],
}

_SQFT = re.compile(r"(\d[\d,]*(?:\.\d+)?)\s*(?:sq\.?\s*ft|sqft|square\s*f(?:ee|oo)t|वर्ग\s*फ)", re.I)
_FT = re.compile(r"(\d[\d,]*(?:\.\d+)?)\s*(?:ft|feet|foot|फुट|फीट)(?![a-z])", re.I)
_DAYS = re.compile(r"(\d+(?:\.\d+)?)\s*(?:days?|din|दिन)", re.I)
_POINTS = re.compile(r"(\d+)\s*(?:[\w\-]+\s+){0,2}?(?:sockets?|points?|switch(?:es)?|plugs?|लाइट|पॉइंट|सॉकेट)", re.I)


def _num(m) -> float:
    return float(m.group(1).replace(",", ""))


def _r50(x: float) -> int:
    return int(math.floor(x / 50.0 + 0.5)) * 50


def _step(x: float) -> int:
    """Rounding grain: Rs 50 normally, Rs 10 for tiny jobs (so a Rs 320 job is not squashed to Rs 300/350)."""
    return 50 if x >= 500 else 10


def _round(x: float, step: int) -> int:
    return int(math.floor(x / step + 0.5)) * step


def _ceil(x: float, step: int) -> int:
    return int(math.ceil(x / step - 1e-9)) * step


def spread(low: float, med: float, high: float) -> tuple[int, int, int]:
    """Guarantee low < median < high with a sensible spread (the "Rs 400 to Rs 400" bug):
    median >= low x 1.12, high >= low x 1.3 and high > median, rounded to Rs 50 (Rs 10 under Rs 500)."""
    step = _step(low)
    lo = max(_round(low, step), step)
    md = max(_round(med, step), _ceil(lo * 1.12, step))
    if md <= lo:
        md = lo + step
    hi = max(_round(high, step), _ceil(lo * 1.3, step), _ceil(md * 1.1, step))
    if hi <= md:
        hi = md + step
    return lo, md, hi


def _has(text: str, *words: str) -> bool:
    t = text.lower()
    return any(w in t for w in words)


def _base(trade: str, text: str) -> tuple[tuple[int, int, int], float, str]:
    """-> (low, median, high) tier-1 rupees, estimated days, basis label."""
    t = text or ""
    days_m = _DAYS.search(t)
    days = min(_num(days_m), 60) if days_m else None
    sq = _SQFT.search(t)
    sqft = _num(sq) if sq else None
    pts_m = _POINTS.search(t)
    pts = int(pts_m.group(1)) if pts_m else None

    if trade == "painter":
        area = sqft or PAINT_DEFAULT_SQFT
        return tuple(r * area for r in PAINT_PER_SQFT), max(1.0, math.ceil(area / PAINT_SQFT_PER_DAY)), f"{int(area)} sq ft"
    if trade == "mason":
        ft = _FT.search(t)
        if ft and _has(t, "wall", "दीवार") and not days:
            length = _num(ft)
            area = length * 5
            return tuple(r * area for r in WALL_PER_SQFT), max(1.0, math.ceil(length / WALL_FT_PER_DAY)), f"{int(length)} ft wall"
        if sqft and _has(t, "til", "टाइल"):
            return tuple(r * sqft for r in TILING_PER_SQFT), max(1.0, math.ceil(sqft / 60)), f"{int(sqft)} sq ft tiling"
        if sqft:
            return tuple(r * sqft for r in PLASTER_PER_SQFT), max(1.0, math.ceil(sqft / 120)), f"{int(sqft)} sq ft plaster"
        d = days or 1.0
        return tuple(r * d for r in DAY_RATE["mason"]), d, f"{d:g} day"
    if trade == "electrician":
        if pts:
            if _has(t, "rewir", "वायरिंग"):
                rate, label = ELEC_REWIRE_POINT, "rewiring points"
            elif _has(t, "new point", "नया पॉइंट"):
                rate, label = ELEC_NEW_POINT, "new points"
            else:
                rate, label = ELEC_SOCKET, "points"
            return tuple(r * pts for r in rate), max(0.5, pts * 0.25), f"{pts} {label}"
        if days:
            return tuple(r * days for r in DAY_RATE["electrician"]), days, f"{days:g} day"
        return ELEC_VISIT, 0.4, "1 visit"
    if trade == "plumber":
        if pts and not _has(t, "leak", "tap"):
            return tuple(r * pts for r in PLUMB_POINT), max(0.5, pts * 0.25), f"{pts} points"
        if _has(t, "pipeline", "पाइपलाइन", "full flat", "repip"):
            d = days or 3.0
            return tuple(r * d for r in DAY_RATE["plumber"]), d, f"{d:g} day"
        if _has(t, "tap", "leak", "टपक", "नल", "लीक", "drip", "seep"):
            return PLUMB_SMALL_FIX, 0.4, "small fix"
        if days:
            return tuple(r * days for r in DAY_RATE["plumber"]), days, f"{days:g} day"
        return PLUMB_VISIT, 0.4, "1 visit"
    d = days or 1.0  # carpenter, helper, anything else
    rate = DAY_RATE.get(trade, DAY_RATE["helper"])
    return tuple(r * d for r in rate), d, f"{d:g} day"


def estimate_item(trade: str, text: str | None, city: str | None) -> dict:
    """Model estimate for one work item. Low is floored at the minimum wage for the estimated days."""
    trade = getattr(trade, "value", trade)
    (lo, med, hi), days, basis = _base(trade, text or "")
    m = city_multiplier(city)
    mw = min_wage_per_day(trade) * days
    step = _step(max(lo * m, mw))
    lo = max(_round(lo * m, step), _ceil(mw, step))  # never below the legal wage for the estimated days
    lo, med, hi = spread(lo, med * m, hi * m)
    return {"trade": trade, "low_inr": lo, "median_inr": med, "high_inr": hi, "est_days": round(days, 1),
            "min_wage_total": int(round(mw)), "basis": basis}


def estimate_items(items: Iterable[tuple[str, str | None]], city: str | None) -> dict:
    out = [estimate_item(tr, tx, city) for tr, tx in items]
    return {"items": out, "total_low_inr": sum(i["low_inr"] for i in out), "total_median_inr": sum(i["median_inr"] for i in out),
            "total_high_inr": sum(i["high_inr"] for i in out)}


def day_wage_range(trade: str, city: str | None) -> dict:
    """Daily wage suggestion for contractors hiring a team: (low, median, high) per worker per day.
    `low` is never under the minimum wage, so offering `low` or more always passes the Fair Wage Shield."""
    trade = getattr(trade, "value", trade)
    lo, med, hi = DAY_RATE.get(trade, DAY_RATE["helper"])
    m = city_multiplier(city)
    mw = min_wage_per_day(trade)
    low = max(_r50(lo * m), math.ceil(mw / 50.0) * 50)
    low, med, hi = spread(low, med * m, hi * m)
    return {"trade": trade, "low": low, "median": med, "high": hi, "min_wage": mw}


def blend_with_history(item: dict, prices_inr: list[float], weight: float = 0.3) -> dict:
    """Blend the model with PriceHistory quartiles when there are >= 5 samples."""
    if len(prices_inr) < 5:
        return item
    import statistics
    qs = statistics.quantiles(sorted(prices_inr), n=4)
    lo, med, hi = ((1 - weight) * item[k] + weight * q for k, q in
                   (("low_inr", qs[0]), ("median_inr", qs[1]), ("high_inr", qs[2])))
    step = _step(max(lo, item["min_wage_total"]))
    lo = max(_round(lo, step), _ceil(item["min_wage_total"], step))
    lo, med, hi = spread(lo, med, hi)
    return {**item, "low_inr": lo, "median_inr": med, "high_inr": hi}


# ------------------------------------------------------------------ job level + Fair Wage Shield
def _job_items(job, trades: Iterable[str] | None = None) -> list[tuple[str, str | None]]:
    items = [(getattr(wi.trade, "value", wi.trade), wi.text_description or wi.transcript) for wi in job.work_items]
    if trades:
        keep = {getattr(t, "value", t) for t in trades}
        sub = [i for i in items if i[0] in keep]
        if sub:  # worker with no matching trade falls back to the whole job
            return sub
    return items


def fair_range(job, trades: Iterable[str] | None = None) -> dict:
    """Fair range for the job (optionally only the trades one worker covers)."""
    est = estimate_items(_job_items(job, trades), getattr(job, "city", None))
    days = round(sum(i["est_days"] for i in est["items"]), 1)
    mw = sum(i["min_wage_total"] for i in est["items"])
    # Where the market rate sits near the wage floor, keep a real spread above it.
    low, median, high = spread(int(est["total_low_inr"]), int(est["total_median_inr"]), int(est["total_high_inr"]))
    return {"low": low, "median": median, "high": high, "min_wage_total": int(mw), "est_days": days}


HIGH_FACTOR = 1.2  # more than 20% over the top of the range = "higher than usual"


def scale_range(fr: dict, mult: float) -> dict:
    """Skill-ladder band: a higher level may ask more. Scales low/median/high but NEVER the legal minimum:
    `low` stays >= min_wage_total and the order low < median < high is kept."""
    if mult == 1.0:
        return fr
    lo, md, hi = fr["low"] * mult, fr["median"] * mult, fr["high"] * mult
    step = _step(max(lo, fr["min_wage_total"]))
    lo = max(_round(lo, step), _ceil(fr["min_wage_total"], step))
    lo, md, hi = spread(lo, md, hi)
    return {**fr, "low": lo, "median": md, "high": hi}


def fair_check(price_inr: float, job, trades: Iterable[str] | None = None, level_mult: float = 1.0) -> dict:
    """Never blocks: classifies a quote. verdict: fair | below_min_wage | high."""
    fr = scale_range(fair_range(job, trades), level_mult)
    if price_inr < fr["min_wage_total"]:
        verdict = "below_min_wage"
    elif price_inr > fr["high"] * HIGH_FACTOR:
        verdict = "high"
    else:
        verdict = "fair"
    return {"verdict": verdict, "low": fr["low"], "high": fr["high"], "min_wage_total": fr["min_wage_total"]}
