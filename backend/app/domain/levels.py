"""Skill ladder (Helper -> Semi-skilled -> Skilled -> Master) and the weekly streak.

Thresholds live in `config.skill_levels` (jobs, average rating, and for Master a max re-fix rate).
Mirrored 1:1 in `mobile/lib/core/demo_api.dart` (DemoLevels) - keep both in sync.
"""
from datetime import date, datetime, timedelta, timezone

from sqlalchemy import select
from sqlalchemy.orm import Session

from ..config import get_settings
from ..models import Assignment, WorkerProfile

IST = timezone(timedelta(hours=5, minutes=30))


def rules() -> list[dict]:
    return list(get_settings().skill_levels)


def refix_rate(jobs: int, refixes: int) -> float:
    return round(refixes / jobs, 4) if jobs > 0 else 0.0


def _meets(rule: dict, jobs: int, rating: float, rate: float) -> bool:
    if jobs < rule["min_jobs"] or rating < rule["min_rating"]:
        return False
    cap = rule.get("max_refix_rate")
    return cap is None or rate < cap


def level_for(jobs: int, rating: float, refixes: int) -> dict:
    """Highest level whose rules ALL hold, walking up from Helper (a gap stops the climb)."""
    rs, rate = rules(), refix_rate(jobs, refixes)
    cur = rs[0]
    for r in rs[1:]:
        if _meets(r, jobs, rating, rate):
            cur = r
        else:
            break
    return cur


def fair_multiplier(code: str) -> float:
    return next((r["fair_multiplier"] for r in rules() if r["code"] == code), 1.0)


def level_view(wp: WorkerProfile) -> dict:
    """Level card: current level, next level and what is still missing, progress 0..1 to the next level."""
    jobs, rating, refixes = wp.completed_jobs, wp.overall_rating if wp.rating_count else 0.0, wp.refix_count
    rate = refix_rate(jobs, refixes)
    rs = rules()
    cur = level_for(jobs, rating, refixes)
    idx = next(i for i, r in enumerate(rs) if r["code"] == cur["code"])
    nxt = rs[idx + 1] if idx + 1 < len(rs) else None
    out = {"code": cur["code"], "index": idx, "jobs": jobs, "rating": round(rating, 1), "refix_rate": rate,
           "refixes": refixes, "fair_multiplier": cur["fair_multiplier"], "next": None, "needs": [], "progress": 1.0}
    if nxt:
        needs = []
        if jobs < nxt["min_jobs"]:
            needs.append({"kind": "jobs", "need": nxt["min_jobs"] - jobs})
        if rating < nxt["min_rating"]:
            needs.append({"kind": "rating", "need": nxt["min_rating"]})
        cap = nxt.get("max_refix_rate")
        if cap is not None and rate >= cap:
            needs.append({"kind": "refix_rate", "need": round(cap * 100)})
        parts = [min(1.0, jobs / nxt["min_jobs"]) if nxt["min_jobs"] else 1.0,
                 min(1.0, rating / nxt["min_rating"]) if nxt["min_rating"] else 1.0]
        out.update({"next": {"code": nxt["code"], "min_jobs": nxt["min_jobs"], "min_rating": nxt["min_rating"],
                             "max_refix_rate_pct": round(cap * 100) if cap is not None else None},
                    "needs": needs, "progress": round(min(parts), 3)})
    return out


# ------------------------------------------------------------------ weekly streak
def _week(d: date) -> tuple[int, int]:
    iso = d.isocalendar()
    return iso[0], iso[1]


def streak(db: Session, worker_id, today: date | None = None) -> dict:
    """Consecutive ISO weeks (IST) with at least one completed job. The current week may still be empty
    without breaking the streak (the week is not over): `alive` says whether this week already counts."""
    today = today or datetime.now(IST).date()
    rows = db.scalars(select(Assignment.completed_at).where(
        Assignment.worker_id == worker_id, Assignment.completed_at.is_not(None), Assignment.kind == "job")).all()
    weeks = {_week(r.astimezone(IST).date()) for r in rows}
    return streak_from_weeks(weeks, today)


def streak_from_weeks(weeks: set[tuple[int, int]], today: date) -> dict:
    this = _week(today)
    alive = this in weeks
    cursor = today if alive else today - timedelta(days=7)
    n = 0
    while _week(cursor) in weeks:
        n += 1
        cursor -= timedelta(days=7)
    return {"weeks": n, "alive_this_week": alive}
