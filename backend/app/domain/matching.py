"""Best-match scoring for the quotes list (customer job detail).

Pure functions, no DB: the router gathers the facts about each quote and passes them in.
Mirrored 1:1 in `mobile/lib/core/demo_api.dart` (DemoMatching) - keep both in sync.

Score 0-100 =  fair price 30 + rating 25 + distance 15 + jobs done 10 + police verified 10
               + level 5 + response time 5.
"""
from __future__ import annotations

import math
from typing import Iterable

FAIR_POINTS = {"fair": 30.0, "high": 10.0, "below_min_wage": 12.0}
LEVEL_POINTS = {"helper": 0.0, "semi_skilled": 2.0, "skilled": 3.5, "master": 5.0}
TODAY_RADIUS_KM = 10.0   # "Can come today" only for workers this close
MIN_QUOTES_FOR_BEST = 2  # one lonely quote is not "the best" of anything


def rating_points(rating: float, count: int) -> float:
    """3 stars = 0, 5 stars = 25. Few reviews count for less (x0.6 under 3 reviews)."""
    if count <= 0:
        return 8.0  # new worker: neutral, not punished
    pts = max(0.0, min(1.0, (rating - 3.0) / 2.0)) * 25.0
    return pts * (0.6 if count < 3 else 1.0)


def distance_points(km: float | None) -> float:
    if km is None:
        return 5.0
    if km <= 2:
        return 15.0
    if km >= 15:
        return 0.0
    return 15.0 * (15.0 - km) / 13.0


def response_points(minutes: float | None) -> float:
    if minutes is None:
        return 2.0
    if minutes <= 30:
        return 5.0
    if minutes <= 120:
        return 3.5
    if minutes <= 24 * 60:
        return 2.0
    return 0.0


def score(*, verdict: str, rating: float, rating_count: int, completed_jobs: int, distance_km: float | None,
          police_verified: bool, level: str, response_min: float | None) -> int:
    total = (FAIR_POINTS.get(verdict, 0.0) + rating_points(rating, rating_count) + distance_points(distance_km)
             + min(max(completed_jobs, 0), 50) / 50.0 * 10.0 + (10.0 if police_verified else 0.0)
             + LEVEL_POINTS.get(level, 0.0) + response_points(response_min))
    return int(math.floor(max(0.0, min(100.0, total)) + 0.5))  # round half up (same as the app)


def reasons(*, verdict: str, rating: float, rating_count: int, completed_jobs: int, distance_km: float | None,
            police_verified: bool, level: str, response_min: float | None) -> list[dict]:
    """Why this quote looks good, most important first, at most 4. `code` + optional `value` (the app localises)."""
    out: list[dict] = []
    if verdict == "fair":
        out.append({"code": "fair"})
    if rating_count > 0 and rating >= 4.0:
        out.append({"code": "rating", "value": round(rating, 1)})
    if distance_km is not None and distance_km <= 5:
        out.append({"code": "distance", "value": round(distance_km, 1)})
    if police_verified:
        out.append({"code": "police"})
    if level in ("skilled", "master"):
        out.append({"code": "level", "value": level})
    if completed_jobs >= 20:
        out.append({"code": "jobs", "value": completed_jobs})
    if response_min is not None and response_min <= 60:
        out.append({"code": "fast"})
    return out[:4]


def can_come_today(*, job_is_today: bool, distance_km: float | None, busy_today: bool) -> bool:
    """Nearby, and no other hire today, for a job that starts today."""
    return bool(job_is_today and not busy_today and distance_km is not None and distance_km <= TODAY_RADIUS_KM)


def mark_best(rows: Iterable[dict]) -> None:
    """Sets `best_match` on exactly one row (highest score; the cheaper quote wins a tie) when there are >= 2
    pending quotes. Rows need `match_score`, `price_inr`, `status`."""
    rows = list(rows)
    for r in rows:
        r["best_match"] = False
    pending = [r for r in rows if r.get("status") == "pending"]
    if len(pending) < MIN_QUOTES_FOR_BEST:
        return
    best = max(pending, key=lambda r: (r["match_score"], -r["price_inr"]))
    best["best_match"] = True
