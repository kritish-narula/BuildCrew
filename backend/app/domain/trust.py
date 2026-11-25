"""Trust & worker-growth rules: start-work code, share-trip links, police verification, work warranty
(free re-fix visits), same-day pay and "hire again" direct requests.

Every rule here is mirrored in `mobile/lib/core/demo_api.dart`; both sides have tests (tests/test_trust.py,
mobile/test/flow_test.dart group "trust & worker features").
"""
import hashlib
import hmac
import math
import secrets
import uuid
from datetime import datetime, timedelta, timezone
from typing import Iterable

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from .. import services
from ..audit import audit
from ..config import get_settings
from ..crypto import mask_phone, mask_upi
from ..enums import BidStatus, EscrowState, JobStatus, RatingDirection, Role
from ..errors import AppError
from ..models import (
    Assignment, Attendance, Bid, Job, Payment, Payout, Rating, TripShare, User, WorkerProfile, WorkItem, WorkItemPhoto,
)
from . import levels

IST = timezone(timedelta(hours=5, minutes=30))
now = lambda: datetime.now(timezone.utc)  # noqa: E731


# =================================================================== 1. start-work code
def _day_key(a: Assignment, at: datetime | None = None) -> str:
    """Single hire: one code for the whole hire. Team member: a NEW code every (IST) day."""
    return (at or now()).astimezone(IST).date().isoformat() if a.work_item_id else "once"


def new_nonce(a: Assignment) -> None:
    a.start_code_nonce = secrets.token_hex(8)
    a.start_code_attempts, a.start_code_attempts_day, a.start_code_locked_until = 0, None, None


def start_code_for(a: Assignment, at: datetime | None = None) -> str | None:
    """The 4 digits. Derived from the server secret + assignment + nonce + day, so nothing readable is stored
    (a DB dump reveals only the nonce) and it is never returned to the worker."""
    if not a.start_code_nonce:
        return None
    msg = f"{a.id}:{a.start_code_nonce}:{_day_key(a, at)}".encode()
    digest = hmac.new(get_settings().jwt_secret.encode(), msg, hashlib.sha256).digest()
    return f"{int.from_bytes(digest[:4], 'big') % 10_000:04d}"


def code_ok_statuses() -> tuple[str, ...]:
    return ("verified", "not_required")


def start_code_required(db: Session, a: Assignment, at: datetime | None = None) -> bool:
    """Single hire / re-fix: until the work has started. Team member: until today's check-in is verified."""
    if not a.start_code_nonce or a.released_at is not None:
        return False
    if a.work_item_id:
        day = (at or now()).astimezone(IST).date()
        rows = db.execute(select(Attendance.checkin_at, Attendance.code_status).where(Attendance.assignment_id == a.id)).all()
        return not any(r[0].astimezone(IST).date() == day and r[1] in code_ok_statuses() for r in rows)
    return a.started_at is None


def _locked_minutes(a: Assignment) -> int:
    return max(1, math.ceil((a.start_code_locked_until - now()).total_seconds() / 60))


def is_locked(a: Assignment) -> bool:
    return bool(a.start_code_locked_until and now() < a.start_code_locked_until)


def verify_start_code(db: Session, a: Assignment, code: str | None, at: datetime | None = None, *, strict: bool = True) -> bool:
    """Check a code, counting attempts: 5 wrong tries lock the hire for 10 minutes. strict=True raises
    err.start_code_invalid / err.start_code_locked (after COMMITTING the counter, otherwise the rollback would
    forget the wrong tries); strict=False (offline sync) just returns False."""
    s = get_settings()
    if is_locked(a):
        if strict:
            raise AppError("err.start_code_locked", 429, minutes=_locked_minutes(a))
        return False
    if a.start_code_locked_until:  # lock served
        a.start_code_locked_until, a.start_code_attempts = None, 0
    day = _day_key(a, at)
    if a.start_code_attempts_day != day:
        a.start_code_attempts, a.start_code_attempts_day = 0, day
    expected = start_code_for(a, at)
    if code and expected and hmac.compare_digest(str(code).strip(), expected):
        a.start_code_attempts = 0
        return True
    a.start_code_attempts += 1
    audit(db, actor_id=a.worker_id, action="start_code.wrong", entity="assignment", entity_id=a.id, attempts=a.start_code_attempts)
    if a.start_code_attempts >= s.start_code_max_attempts:
        a.start_code_locked_until = now() + timedelta(minutes=s.start_code_lock_minutes)
        a.start_code_attempts = 0
        if strict:
            db.commit()
            raise AppError("err.start_code_locked", 429, minutes=s.start_code_lock_minutes)
        return False
    if strict:
        left = s.start_code_max_attempts - a.start_code_attempts
        db.commit()
        raise AppError("err.start_code_invalid", 409, left=left)
    return False


def start_code_state(db: Session, a: Assignment) -> str | None:
    """Worker-facing state, no secrets: None (no code involved) | needed | locked | verified | pending | failed."""
    if not a.start_code_nonce or a.released_at is not None:
        return None
    if start_code_required(db, a):
        rows = db.scalars(select(Attendance.code_status).where(Attendance.assignment_id == a.id)
                          .order_by(Attendance.checkin_at.desc()).limit(1)).all()
        if is_locked(a):
            return "locked"
        if rows and rows[0] in ("pending", "failed"):
            return rows[0]
        return "needed"
    return "verified"


def customer_code_view(db: Session, a: Assignment) -> dict | None:
    """What the CUSTOMER (or contractor) sees: the code itself while it is still needed."""
    if not a.start_code_nonce or a.released_at is not None:
        return None
    paid = a.kind == "refix" or db.scalar(select(Payment.escrow_state).where(Payment.assignment_id == a.id)) in (
        EscrowState.held, EscrowState.released, EscrowState.split)
    if not paid:
        return None
    need = start_code_required(db, a)
    settings = get_settings()
    return {"code": start_code_for(a) if need else None, "needed": need, "state": start_code_state(db, a),
            "locked_until": a.start_code_locked_until.isoformat() if is_locked(a) else None,
            "attempts_left": max(0, settings.start_code_max_attempts - (a.start_code_attempts or 0))}


def team_day_code(db: Session, a: Assignment) -> dict | None:
    """Contractor roster: today's code for this worker (and whether he is already verified for today)."""
    view = customer_code_view(db, a)
    if view is None:
        return None
    return {"code": start_code_for(a), "verified_today": not view["needed"], "state": view["state"],
            "locked_until": view["locked_until"]}


def worker_start(db: Session, worker: User, a: Assignment, code: str | None) -> dict:
    """The explicit "start work" tap. Also upgrades an earlier offline check-in that was only "pending"."""
    from . import flows
    if a.worker_id != worker.id:
        raise AppError("err.forbidden", 403)
    flows._ensure_active(a)
    if start_code_required(db, a):
        if not code:
            raise AppError("err.start_code_required", 422)
        verify_start_code(db, a, code)
    day = now().astimezone(IST).date()
    for row in db.scalars(select(Attendance).where(Attendance.assignment_id == a.id, Attendance.code_status.in_(["pending", "failed"]))):
        if a.work_item_id is None or row.checkin_at.astimezone(IST).date() == day:
            row.code_status = "verified"
    flows.start_work(db, worker, a)
    return {"ok": True}


# =================================================================== 2. share live trip
def _trip_alive(a: Assignment) -> bool:
    return bool(a.journey_started_at and a.started_at is None and a.released_at is None)


def share_trip(db: Session, customer: User, a: Assignment) -> dict:
    if a.job.customer_id != customer.id:
        raise AppError("err.not_your_job", 403)
    if not _trip_alive(a) or _arrived(a):
        raise AppError("err.trip_not_active", 409)
    s = get_settings()
    row = db.scalar(select(TripShare).where(TripShare.assignment_id == a.id, TripShare.expires_at > now())
                    .order_by(TripShare.created_at.desc()))
    if not row:
        row = TripShare(assignment_id=a.id, token=secrets.token_urlsafe(24),
                        expires_at=now() + timedelta(hours=s.trip_share_ttl_hours))
        db.add(row)
        db.flush()
        audit(db, actor_id=customer.id, action="trip.shared", entity="assignment", entity_id=a.id)
    w = a.worker
    wi = db.get(WorkItem, a.work_item_id) if a.work_item_id else None
    trade = wi.trade.value if wi else next((x.trade.value for x in a.job.work_items
                                            if x.trade.value in (w.worker_profile.trades or [])), a.job.work_items[0].trade.value)
    return {"token": row.token, "url": f"{s.public_trip_base_url}/{row.token}", "expires_at": row.expires_at.isoformat(),
            "worker_name": w.name, "worker_phone_masked": mask_phone(w.phone), "trade": trade,
            "police_verified": w.worker_profile.police_status == "verified"}


def _arrived(a: Assignment) -> bool:
    t = None
    from . import flows
    t = flows.tracking(a)
    return bool(a.started_at or (t and t.get("arrived")))


def public_trip(db: Session, token: str) -> dict:
    """No auth. NEVER includes the customer, the address, the worker's phone or his exact coordinates."""
    row = db.scalar(select(TripShare).where(TripShare.token == token))
    if not row:
        raise AppError("err.not_found", 404)
    a = db.get(Assignment, row.assignment_id)
    if row.expires_at <= now() or not _trip_alive(a) or _arrived(a):
        raise AppError("err.trip_expired", 410)
    from . import flows
    from ..routers.views import signed
    tr = flows.tracking(a) or {}
    w = a.worker
    wp = w.worker_profile
    wi = db.get(WorkItem, a.work_item_id) if a.work_item_id else None
    trade = wi.trade.value if wi else next((x.trade.value for x in a.job.work_items if x.trade.value in (wp.trades or [])),
                                           a.job.work_items[0].trade.value)
    return {"name": w.name, "photo": signed(wp.selfie_url), "trade": trade, "rating": round(wp.overall_rating, 1),
            "police_verified": wp.police_status == "verified", "level": levels.level_for(wp.completed_jobs, wp.overall_rating, wp.refix_count)["code"],
            "distance_km": tr.get("distance_km"), "eta_min": tr.get("eta_min"), "updated_at": tr.get("updated_at"),
            "status": "on_the_way", "expires_at": row.expires_at.isoformat()}


# =================================================================== 3. police verification
def request_police(db: Session, worker: User) -> dict:
    wp = worker.worker_profile
    if worker.kyc_level < 1:
        raise AppError("err.kyc_required", 409)
    if wp.police_status in ("pending", "verified"):
        return {"status": wp.police_status}
    wp.police_status, wp.police_requested_at, wp.police_note = "pending", now(), None
    audit(db, actor_id=worker.id, action="police.requested", entity="user", entity_id=worker.id)
    return {"status": "pending"}


def decide_police(db: Session, admin: User, worker: User, approve: bool, note: str | None) -> dict:
    wp = worker.worker_profile
    if wp.police_status != "pending":
        raise AppError("err.not_found", 404)
    wp.police_status = "verified" if approve else "rejected"
    wp.police_decided_at = now()
    wp.police_note = None if approve else (note or "Could not verify")
    audit(db, actor_id=admin.id, action="police.verified" if approve else "police.rejected", entity="user", entity_id=worker.id, note=note)
    return {"status": wp.police_status}


# =================================================================== 4. warranty + re-fix
WARRANTY_DAYS = {"plumber": 30, "electrician": 30, "carpenter": 15, "mason": 15, "painter": 7, "helper": 0}


def warranty_days(trades: Iterable[str]) -> int:
    return max((WARRANTY_DAYS.get(t, 0) for t in trades), default=0)


def assignment_trades(db: Session, a: Assignment) -> list[str]:
    if a.work_item_id:
        wi = db.get(WorkItem, a.work_item_id)
        return [wi.trade.value] if wi else []
    mine = set(a.worker.worker_profile.trades or [])
    job_trades = [x.trade.value for x in a.job.work_items]
    return [t for t in job_trades if t in mine] or job_trades


def warranty_for_quote(job: Job, worker: User) -> int:
    mine = set(worker.worker_profile.trades or [])
    trades = [x.trade.value for x in job.work_items]
    return warranty_days([t for t in trades if t in mine] or trades)


def _settled_payment(db: Session, a: Assignment) -> Payment | None:
    p = db.scalar(select(Payment).where(Payment.assignment_id == a.id))
    return p if p and p.escrow_state in (EscrowState.released, EscrowState.split) and p.worker_payout_paise > 0 else None


def refixes_of(db: Session, a: Assignment) -> list[Assignment]:
    """Re-fix visits that still count against the limit: everything except hires that were released (cancelled / withdrawn)."""
    return list(db.scalars(select(Assignment).where(Assignment.parent_assignment_id == a.id, Assignment.released_at.is_(None))))


def warranty_view(db: Session, a: Assignment) -> dict | None:
    """Warranty card for a finished, paid hire. None for re-fix visits (they carry no new warranty)."""
    if a.kind == "refix":
        return None
    days = warranty_days(assignment_trades(db, a))
    p = _settled_payment(db, a)
    out = {"days": days, "until": None, "active": False, "refixes_used": 0, "refixes_max": get_settings().max_refix_per_job,
           "open_job_id": None, "can_request": False, "reason": None}
    kids = refixes_of(db, a)
    out["refixes_used"] = len(kids)
    open_kid = next((k for k in kids if k.job.status not in (JobStatus.completed, JobStatus.cancelled)), None)
    out["open_job_id"] = str(open_kid.job_id) if open_kid else None
    if not p or not p.released_at:
        out["reason"] = "not_released"
        return out
    until = p.released_at + timedelta(days=days)
    out["until"] = until.isoformat()
    out["active"] = days > 0 and now() <= until
    if not out["active"]:
        out["reason"] = "expired"
    elif open_kid:
        out["reason"] = "open"
    elif len(kids) >= out["refixes_max"]:
        out["reason"] = "limit"
    else:
        out["can_request"] = True
    return out


def request_refix(db: Session, customer: User, a: Assignment, reason: str, photos: list[str]) -> Assignment:
    from . import flows
    if a.job.customer_id != customer.id:
        raise AppError("err.not_your_job", 403)
    if a.kind == "refix":
        raise AppError("err.validation", 422)
    reason = (reason or "").strip()
    if len(reason) < 5 or len(reason) > 1000:
        raise AppError("err.validation", 422)
    photos = flows._photos(photos, required=True)
    p = _settled_payment(db, a)
    if not p:
        raise AppError("err.job_not_completed", 409)
    wv = warranty_view(db, a)
    if not wv["active"]:
        raise AppError("err.warranty_expired", 409, days=wv["days"])
    if wv["reason"] == "open":
        raise AppError("err.refix_open", 409)
    if wv["reason"] == "limit":
        raise AppError("err.refix_limit", 409, max=wv["refixes_max"])
    orig = a.job
    trades = assignment_trades(db, a)
    job = Job(customer_id=orig.customer_id, location_lat=orig.location_lat, location_lng=orig.location_lng,
              address_text=orig.address_text, city=orig.city, locality=orig.locality,
              start_date=flows.today_ist(), status=JobStatus.assigned, kind="single")
    db.add(job)
    db.flush()
    for i, tr in enumerate(dict.fromkeys(trades)):
        src = next(x for x in orig.work_items if x.trade.value == tr) if any(x.trade.value == tr for x in orig.work_items) else orig.work_items[0]
        wi = WorkItem(job_id=job.id, sort_order=i, trade=src.trade, text_description=f"Warranty re-fix: {reason}"[:1000],
                      description_language="en")
        db.add(wi)
        db.flush()
        for k, key in enumerate(photos):
            db.add(WorkItemPhoto(work_item_id=wi.id, photo_url=key, sort_order=k))
    bid = Bid(job_id=job.id, worker_id=a.worker_id, quoted_price_paise=0, status=BidStatus.accepted)
    db.add(bid)
    db.flush()
    r = Assignment(job_id=job.id, worker_id=a.worker_id, accepted_bid_id=bid.id, escrow_status=EscrowState.created, kind="refix",
                   parent_assignment_id=a.id, refix_reason=reason[:1000])
    db.add(r)
    db.flush()
    new_nonce(r)
    a.worker.worker_profile.refix_count += 1
    flows.add_event(db, a, "refix_requested", "customer", note=reason[:500], photos=photos)
    audit(db, actor_id=customer.id, action="refix.requested", entity="assignment", entity_id=r.id, parent=a.id)
    services.realtime().publish(f"job:{a.job_id}", "refix", {"job_id": str(job.id)})
    return r


def worker_warranty_record(db: Session, wp: WorkerProfile) -> dict:
    jobs = wp.completed_jobs
    return {"refixes": wp.refix_count, "jobs": jobs, "rate": levels.refix_rate(jobs, wp.refix_count)}


# =================================================================== 5. same-day pay
def auto_payout(db: Session, a: Assignment, amount_paise: int) -> Payout | None:
    """Escrow just released: send the money straight to UPI when the worker has one (L1 KYC) and is not blocked
    by the Level-2 cap. Otherwise it stays in the balance (the app nudges to add UPI)."""
    from . import flows
    if amount_paise <= 0:
        return None
    worker = db.get(User, a.worker_id)
    wp = worker.worker_profile
    if worker.kyc_level < 1 or not wp.upi_id or flows.kyc_state(worker)["blocked_by_level2"]:
        return None
    ref, st = services.payouts().send(upi_id=wp.upi_id, amount_paise=amount_paise, reference=f"asg_{a.id.hex[:16]}")
    p = Payout(worker_id=worker.id, amount_paise=amount_paise, upi_masked=mask_upi(wp.upi_id) or "", status="processing",
               provider_ref=ref, source="auto", assignment_id=a.id)
    db.add(p)
    db.flush()
    audit(db, actor_id=None, action="payout.auto_sent", entity="payout", entity_id=p.id, amount=amount_paise)
    return p


def settle_payouts(db: Session, worker_id=None) -> int:
    """Lazy settlement of processing payouts (the mock provider reports `paid` after a few seconds)."""
    q = select(Payout).where(Payout.status == "processing")
    if worker_id:
        q = q.where(Payout.worker_id == worker_id)
    n = 0
    for p in db.scalars(q):
        if services.payouts().status(p.provider_ref or "", p.created_at) == "paid":
            p.status, p.paid_at = "paid", now()
            audit(db, actor_id=None, action="payout.paid", entity="payout", entity_id=p.id)
            n += 1
    if n:
        db.flush()
    return n


def payout_view(p: Payout) -> dict:
    return {"id": str(p.id), "amount_inr": p.amount_paise / 100, "upi": p.upi_masked, "state": "paid" if p.status in ("paid", "processed") else p.status,
            "source": p.source, "at": p.created_at.isoformat(), "paid_at": p.paid_at.isoformat() if p.paid_at else None}


# =================================================================== 10. hire again (direct request)
def direct_state(job: Job) -> str | None:
    """None (not a direct request) | pending | declined | expired."""
    if not job.direct_worker_id:
        return None
    if job.direct_declined:
        return "declined"
    if job.direct_until and now() >= job.direct_until:
        return "expired"
    return "pending"


def exclusive_to(job: Job) -> uuid.UUID | None:
    """The only worker who may see / quote right now, or None when the job is open to everyone."""
    return job.direct_worker_id if direct_state(job) == "pending" and job.status in (JobStatus.open, JobStatus.bidding) else None


def check_direct_access(job: Job, worker: User) -> None:
    ex = exclusive_to(job)
    if ex is not None and ex != worker.id:
        raise AppError("err.direct_only", 403)


def set_direct(db: Session, customer: User, job: Job, worker_id: uuid.UUID) -> None:
    w = db.get(User, worker_id)
    if not w or w.role != Role.worker or not w.worker_profile or w.worker_profile.is_suspended or job.kind == "team":
        raise AppError("err.validation", 422)
    trades = set(w.worker_profile.trades or [])
    if trades and not any(wi.trade.value in trades for wi in job.work_items):
        raise AppError("err.trade_mismatch", 403)
    job.direct_worker_id = w.id
    job.direct_until = now() + timedelta(hours=get_settings().direct_request_hours)
    job.direct_declined = False
    audit(db, actor_id=customer.id, action="job.direct_offered", entity="job", entity_id=job.id, worker=w.id)


def decline_direct(db: Session, worker: User, job: Job) -> dict:
    if job.direct_worker_id != worker.id:
        raise AppError("err.forbidden", 403)
    st = direct_state(job)
    if st == "pending":
        job.direct_declined = True
        audit(db, actor_id=worker.id, action="job.direct_declined", entity="job", entity_id=job.id)
        services.realtime().publish("feed", "nudge", {"job_id": str(job.id)})
    return {"state": direct_state(job)}


def direct_view(db: Session, job: Job) -> dict | None:
    st = direct_state(job)
    if st is None:
        return None
    from ..routers.views import worker_summary
    w = db.get(User, job.direct_worker_id)
    quoted = bool(db.scalar(select(Bid.id).where(Bid.job_id == job.id, Bid.worker_id == job.direct_worker_id,
                                                 Bid.status != BidStatus.withdrawn)))
    return {"state": st, "until": job.direct_until.isoformat() if job.direct_until else None, "quoted": quoted,
            "worker": worker_summary(db, w)}


def favourites(db: Session, customer: User) -> list[dict]:
    """Workers this customer rated >= 4 (real ratings only), best and most recent first."""
    from ..routers.views import worker_summary
    rows = db.execute(select(Rating, Assignment).join(Assignment, Assignment.id == Rating.assignment_id).where(
        Rating.rater_id == customer.id, Rating.direction == RatingDirection.customer_to_worker, Rating.is_auto.is_(False),
        Rating.overall >= 4).order_by(Rating.created_at.desc())).all()
    out: dict[uuid.UUID, dict] = {}
    for r, a in rows:
        w = db.get(User, a.worker_id)
        if not w or not w.worker_profile or w.worker_profile.is_suspended:
            continue
        if w.id not in out:
            out[w.id] = {**worker_summary(db, w), "last_job_id": str(a.job_id), "jobs_together": 0,
                         "last_trade": a.job.work_items[0].trade.value if a.job.work_items else None}
        out[w.id]["jobs_together"] += 1
    return list(out.values())


def rebook_draft(db: Session, customer: User, *, job: Job | None = None, worker: User | None = None) -> dict:
    """Prefill for Post a Job: trade(s), address and the last description of a previous job with this worker."""
    from ..routers.views import worker_summary
    if job is None and worker is not None:  # latest job this customer did with the worker
        job = db.scalar(select(Job).join(Assignment, Assignment.job_id == Job.id).where(
            Job.customer_id == customer.id, Assignment.worker_id == worker.id, Assignment.kind == "job", Job.kind == "single")
            .order_by(Job.created_at.desc()).limit(1))
    if job is not None and worker is None:
        a = db.scalar(select(Assignment).where(Assignment.job_id == job.id, Assignment.kind == "job")
                      .order_by(Assignment.released_at.is_(None).desc(), Assignment.id))
        worker = db.get(User, a.worker_id) if a else None
    if worker is None:
        raise AppError("err.not_found", 404)
    if job is None:
        job = db.scalar(select(Job).where(Job.customer_id == customer.id).order_by(Job.created_at.desc()).limit(1))
    mine = set(worker.worker_profile.trades or [])
    items = []
    if job is not None and job.kind != "team":
        items = [{"trade": wi.trade.value, "text_description": wi.text_description or wi.transcript or "",
                  "description_language": wi.description_language} for wi in job.work_items
                 if not mine or wi.trade.value in mine] or []
    if not items:
        items = [{"trade": (worker.worker_profile.trades or ["helper"])[0], "text_description": "", "description_language": customer.language_code}]
    return {"worker": worker_summary(db, worker), "items": items,
            "address_text": job.address_text if job else "", "lat": job.location_lat if job else None,
            "lng": job.location_lng if job else None, "city": job.city if job else "", "locality": job.locality if job else "",
            "source_job_id": str(job.id) if job else None}
