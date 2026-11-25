import statistics
import uuid
from datetime import date, datetime, time, timedelta, timezone

from fastapi import APIRouter, Depends, Query
from pydantic import BaseModel, Field
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from .. import services
from ..audit import audit
from ..config import get_settings
from ..db import get_db
from ..domain import flows, levels, pricing, team, trust
from ..domain.state import transition
from ..enums import AudioUploadState, BidStatus, JobStatus, Role, Trade
from ..errors import AppError
from ..models import Assignment, Bid, Job, Payment, PriceHistory, User, WorkerProfile, WorkItem, WorkItemPhoto
from ..security import require
from .views import assignment_view, job_card, payment_view, rating_breakdown, work_item_view, worker_history, worker_summary

router = APIRouter(prefix="/customer", tags=["customer"])
C = require(Role.customer)


def _own(db: Session, user: User, job_id: uuid.UUID) -> Job:
    job = db.get(Job, job_id)
    if not job or job.customer_id != user.id:
        raise AppError("err.not_found", 404)
    return job


def _level_mult(w: User) -> float:
    wp = w.worker_profile
    return levels.level_for(wp.completed_jobs, wp.overall_rating if wp.rating_count else 0.0, wp.refix_count)["fair_multiplier"]


def _assignment(db: Session, job: Job) -> Assignment:
    """The ACTIVE hire. After a cancel / no-show / change-of-worker there is none (err.hire_cancelled);
    anything still running on an old screen (e.g. a late "Pay") is refused instead of touching money."""
    a = flows.active_assignment(db, job.id)
    if not a:
        raise AppError("err.hire_cancelled", 409)
    flows.maybe_auto_confirm(db, a)  # the 48 h rule applies before ANY customer action is evaluated
    return a


@router.get("/jobs")
def jobs(user: User = Depends(C), db: Session = Depends(get_db)):
    """C1. Active + completed jobs with bid counts and the 'rate to release payment' flag."""
    if flows.sweep_auto_confirm(db):
        db.commit()
    rows = db.scalars(select(Job).where(Job.customer_id == user.id).order_by(Job.created_at.desc())).all()
    counts = dict(db.execute(select(Bid.job_id, func.count()).where(Bid.job_id.in_([j.id for j in rows]),
                                                                    Bid.status != BidStatus.withdrawn)
                             .group_by(Bid.job_id)).all()) if rows else {}
    out = []
    for j in rows:
        a = flows.active_assignment(db, j.id)
        p = db.scalar(select(Payment).where(Payment.assignment_id == a.id)) if a else None
        row = {**job_card(db, j, user.language_code), "bid_count": counts.get(j.id, 0),
               "needs_rating": j.status == JobStatus.completed and p is not None and p.escrow_state.value == "held",
               "refix": bool(a and a.kind == "refix"), "direct_state": trust.direct_state(j),
               "direct_until": j.direct_until.isoformat() if j.direct_until else None,
               "direct_worker": (db.get(User, j.direct_worker_id).name if j.direct_worker_id else None),
               "hire_again_worker_id": str(a.worker_id) if a and j.kind == "single" and a.kind == "job" else None,
               "warranty": trust.warranty_view(db, a) if a and j.kind == "single" else None,
               "worker_name": a.worker.name if a else None,
               "payment_state": p.escrow_state.value if p else None,
               "needs_action": bool(a and j.status == JobStatus.in_progress and a.worker_done_at and not a.rework_open),
               "rework_open": bool(a and a.rework_open),
               "auto_confirm_at": (flows.auto_confirm_at(a).isoformat() if a and flows.auto_confirm_at(a) else None),
               "no_quotes_24h": flows.no_quotes_hint(db, j)}
        if j.kind == "team":  # roster-level facts instead of a single worker
            ros = team.roster(db, j, user.language_code)
            row.update({"needs_rating": False, "worker_name": None, "payment_state": "created" if ros["payment_due_count"] else
                        (p.escrow_state.value if p else None), "payment_due_inr": ros["payment_due_inr"],
                        "to_settle": sum(1 for w in ros["workers"] if not w["settled"] and w["payment"]
                                         and w["payment"]["escrow_state"] == "held" and w["days_worked"] >= w["days_planned"])})
        out.append(row)
    return out


class WorkItemIn(BaseModel):
    trade: Trade
    text_description: str | None = Field(default=None, max_length=1000)
    transcript: str | None = Field(default=None, max_length=4000)  # customer-reviewed STT
    description_language: str = "hi"
    audio_key: str | None = None
    audio_duration_sec: int | None = Field(default=None, ge=1)
    audio_size_bytes: int | None = None
    photo_keys: list[str] = []
    # team jobs only: `headcount` workers x `days` days at `daily_wage_inr` each
    headcount: int = Field(default=1, ge=1, le=100)
    days: int = Field(default=1, ge=1, le=120)
    daily_wage_inr: int | None = Field(default=None, ge=1, le=100_000)


class JobIn(BaseModel):
    location_lat: float
    location_lng: float
    address_text: str = Field(min_length=3, max_length=300)
    city: str = ""
    locality: str | None = None
    start_date: date
    scheduled_for: datetime | None = None   # exact start; naive values are read as IST
    time_slot: str | None = Field(default=None, pattern="^(morning|afternoon|evening|exact)$")
    kind: str = Field(default="single", pattern="^(single|team)$")
    work_items: list[WorkItemIn]
    direct_worker_id: uuid.UUID | None = None  # "Send to <worker> first": exclusive for 2 hours (hire again)


MIN_PHOTOS, MIN_DESCRIPTION = 2, 50
SLOT_HOURS = {"morning": (8, 11), "afternoon": (12, 15), "evening": (16, 19)}  # local (IST) start, end


def _validate_schedule(body: "JobIn") -> datetime | None:
    """Not in the past: a slot is still bookable until it ends; an exact time needs >= now - 2 min."""
    now = datetime.now(timezone.utc)
    today = now.astimezone(team.IST).date()
    if body.start_date < today:
        raise AppError("err.schedule_past", 422)
    when = body.scheduled_for
    if when is None:
        return None
    if when.tzinfo is None:
        when = when.replace(tzinfo=team.IST)
    when = when.astimezone(timezone.utc)
    slot = body.time_slot
    if slot in SLOT_HOURS:
        end = datetime.combine(when.astimezone(team.IST).date(), time(SLOT_HOURS[slot][1]), tzinfo=team.IST)
        if end <= now:
            raise AppError("err.schedule_past", 422)
    elif when < now - timedelta(minutes=2):
        raise AppError("err.schedule_past", 422)
    return when


@router.post("/jobs")
def create_job(body: JobIn, user: User = Depends(C), db: Session = Depends(get_db)):
    """C2. One job, many work cards; each may have photos AND text AND a voice note."""
    s = get_settings()
    if not body.work_items:
        raise AppError("err.no_work_items", 422)
    if body.start_date < flows.today_ist():
        raise AppError("err.date_in_past", 422)
    if body.start_date > flows.today_ist() + timedelta(days=365):
        raise AppError("err.date_too_far", 422)
    is_team = body.kind == "team"
    if is_team and not (user.customer_profile and user.customer_profile.type.value == "contractor"):
        raise AppError("err.contractor_only", 403)
    when = _validate_schedule(body)
    for wi in body.work_items:
        if len(wi.photo_keys) > 5:
            raise AppError("err.too_many_photos", 422)
        if wi.audio_duration_sec and wi.audio_duration_sec > s.audio_max_seconds + 2:
            raise AppError("err.audio_too_long", 422)
        if len(wi.photo_keys) < MIN_PHOTOS:
            raise AppError("err.photos_required", 422, min=MIN_PHOTOS)
        if len((wi.text_description or "").strip()) < MIN_DESCRIPTION:
            raise AppError("err.description_short", 422, min=MIN_DESCRIPTION)
        if is_team:
            if wi.daily_wage_inr is None:
                raise AppError("err.validation", 422)
            team.wage_floor_check(wi.trade.value, wi.daily_wage_inr, body.city)
    if is_team and len({wi.trade for wi in body.work_items}) != len(body.work_items):
        raise AppError("err.validation", 422)  # one line per trade
    locality = body.locality or services.maps().reverse_locality(body.location_lat, body.location_lng) or body.city
    job = Job(customer_id=user.id, location_lat=body.location_lat, location_lng=body.location_lng,
              address_text=body.address_text, city=body.city, locality=locality, start_date=body.start_date,
              scheduled_for=when, time_slot=body.time_slot, kind=body.kind)
    db.add(job)
    db.flush()
    for i, w in enumerate(body.work_items):
        item = WorkItem(job_id=job.id, sort_order=i, trade=w.trade, text_description=w.text_description,
                        transcript=w.transcript, description_language=w.description_language,
                        headcount=w.headcount if is_team else 1, days=w.days if is_team else 1,
                        daily_wage_paise=w.daily_wage_inr * 100 if is_team else None,
                        audio_url=w.audio_key, audio_duration_sec=w.audio_duration_sec, audio_size_bytes=w.audio_size_bytes,
                        audio_upload_state=AudioUploadState.uploaded if w.audio_key else None)
        db.add(item)
        db.flush()
        for k, key in enumerate(w.photo_keys):
            db.add(WorkItemPhoto(work_item_id=item.id, photo_url=key, sort_order=k))
    if body.direct_worker_id:
        trust.set_direct(db, user, job, body.direct_worker_id)
    audit(db, actor_id=user.id, action="job.posted", entity="job", entity_id=job.id, items=len(body.work_items), kind=body.kind)
    db.commit()
    return {"id": str(job.id), "status": job.status.value, "locality": locality,
            "direct_until": job.direct_until.isoformat() if job.direct_until else None}


@router.get("/price-estimate")
def price_estimate(trades: str | None = None, locality: str | None = None, city: str | None = None,
                   texts: str | None = Query(None, description="work-card texts, '|'-separated, aligned with `trades`"),
                   job_id: uuid.UUID | None = None, user: User = Depends(C), db: Session = Depends(get_db)):
    """C2 step 4: fair price = unit-rate model (domain/pricing.py: trade rate x quantity parsed from the
    text, x city-tier multiplier), blended with completed-job PriceHistory when it has >= 5 samples.
    The city comes from the job / request; nothing assumes a default city."""
    pairs: list[tuple[str, str | None]] = []
    if job_id:
        job = _own(db, user, job_id)
        city = city or job.city
        locality = locality or job.locality
        pairs = [(wi.trade.value, wi.text_description or wi.transcript) for wi in job.work_items]
    elif trades:
        codes = [c.strip() for c in trades.split(",") if c.strip()]
        tx = texts.split("|") if texts is not None else []
        if texts is None:
            codes = list(dict.fromkeys(codes))
        pairs = [(c, (tx[i].strip() or None) if i < len(tx) else None) for i, c in enumerate(codes)]
    out, low_sum, med_sum, high_sum = [], 0, 0, 0
    est = pricing.estimate_items([(c, t) for c, t in pairs if c in Trade._value2member_map_], city)
    for item in est["items"]:
        trade = Trade(item["trade"])
        q = select(PriceHistory.price_paise).where(PriceHistory.trade == trade)
        if city:
            q = q.where(PriceHistory.city == city)
        prices = db.scalars(q.where(PriceHistory.locality == locality)).all() if locality else []
        scope = "locality"
        if len(prices) < 5:
            prices, scope = db.scalars(q).all(), "city" if city else "all"
        if len(prices) < 5 and city:  # new city with no history yet -> national data
            prices, scope = db.scalars(select(PriceHistory.price_paise).where(PriceHistory.trade == trade)).all(), "all"
        item = pricing.blend_with_history(item, [p / 100 for p in prices])
        low_sum, med_sum, high_sum = low_sum + item["low_inr"], med_sum + item["median_inr"], high_sum + item["high_inr"]
        out.append({**item, "samples": len(prices), "scope": scope if len(prices) >= 5 else "model", "city": city,
                    "city_multiplier": pricing.city_multiplier(city)})
    if out:
        low_sum, med_sum, high_sum = pricing.spread(low_sum, med_sum, high_sum)
    return {"items": out, "total_low_inr": low_sum, "total_median_inr": med_sum, "total_high_inr": high_sum,
            "city": city, "platform_fee_inr": get_settings().platform_fee_flat_inr}


@router.get("/wage-suggestion")
def wage_suggestion(trades: str, city: str | None = None, user: User = Depends(C)):
    """Contractor team posting: suggested daily wage per trade (low <= median <= high) and the legal minimum."""
    codes = [c.strip() for c in trades.split(",") if c.strip() in Trade._value2member_map_]
    return {"city": city, "items": [pricing.day_wage_range(c, city) for c in dict.fromkeys(codes)]}


@router.get("/jobs/{job_id}")
def job_detail(job_id: uuid.UUID, user: User = Depends(C), db: Session = Depends(get_db)):
    """C3/C4. Work items, bids for comparison, assignment tracking + escrow + ratings."""
    job = _own(db, user, job_id)
    a = flows.active_assignment(db, job.id)
    if a and flows.maybe_auto_confirm(db, a):
        db.commit()
    bids = db.scalars(select(Bid).where(Bid.job_id == job.id, Bid.status != BidStatus.withdrawn)
                      .order_by(Bid.quoted_price_paise)).all()
    out = {**job_card(db, job, user.language_code),
           "no_quotes_24h": flows.no_quotes_hint(db, job), "nudged_at": job.nudged_at.isoformat() if job.nudged_at else None,
           "work_items": [work_item_view(db, wi, user.language_code, include_audio=True) for wi in job.work_items],
           "bids": [{"id": str(b.id), "price_inr": b.quoted_price_paise / 100, "status": b.status.value,
                     "created_at": b.created_at.isoformat(), "worker": worker_summary(db, b.worker),
                     "warranty_days": trust.warranty_for_quote(job, b.worker),
                     "fair": pricing.fair_check(b.quoted_price_paise / 100, job, b.worker.worker_profile.trades,
                                                _level_mult(b.worker))} for b in bids],
           "direct": trust.direct_view(db, job),
           "assignment": assignment_view(db, a, user.language_code, viewer="customer") if job.kind != "team" else None,
           "fee_inr": get_settings().platform_fee_flat_inr}
    if job.kind == "team":
        out["team"] = team.roster(db, job, user.language_code)
        for b_out, b in zip(out["bids"], bids):
            wi = db.get(WorkItem, b.work_item_id) if b.work_item_id else None
            b_out.update({"trade": wi.trade.value if wi else None, "work_item_id": str(wi.id) if wi else None,
                          "daily_wage_inr": b.quoted_price_paise / 100, "days": wi.days if wi else 1,
                          "min_wage": pricing.min_wage_per_day(wi.trade.value) if wi else None})
    db.commit()
    return out


@router.post("/jobs/{job_id}/bids/{bid_id}/accept")
def accept(job_id: uuid.UUID, bid_id: uuid.UUID, user: User = Depends(C), db: Session = Depends(get_db)):
    job = _own(db, user, job_id)
    bid = db.get(Bid, bid_id)
    if not bid:
        raise AppError("err.not_found", 404)
    if bid.job_id != job.id:
        raise AppError("err.not_found", 404)
    a = flows.accept_bid(db, user, job, bid)
    db.commit()
    p = db.scalar(select(Payment).where(Payment.assignment_id == a.id))
    # Checkout params for the client (key_id is PUBLIC; the secret never leaves the server).
    return {"assignment_id": str(a.id), "payment": payment_view(p),
            "checkout": {"order_id": p.razorpay_ref, "key_id": get_settings().razorpay_key_id or "rzp_test_mock",
                         "amount_paise": p.amount_paise}}


class PayIn(BaseModel):
    method: str = Field(pattern="^(upi|card|netbanking)$")
    razorpay_payment_id: str | None = None
    razorpay_signature: str | None = None


@router.post("/jobs/{job_id}/pay")
def pay(job_id: uuid.UUID, body: PayIn, user: User = Depends(C), db: Session = Depends(get_db)):
    """Payment page → money into escrow. Amount is NOT accepted from the client."""
    job = _own(db, user, job_id)
    if job.kind == "team":
        out = team.pay_team(db, user, job, method=body.method, razorpay_payment_id=body.razorpay_payment_id,
                            signature=body.razorpay_signature)
        db.commit()
        return out
    p = flows.pay_escrow(db, user, _assignment(db, job), method=body.method,
                         razorpay_payment_id=body.razorpay_payment_id, signature=body.razorpay_signature)
    db.commit()
    return payment_view(p)


class SettleIn(BaseModel):
    quality: int
    timeliness: int
    behaviour: int
    value_for_money: int
    comment: str | None = None


@router.get("/jobs/{job_id}/team")
def team_roster(job_id: uuid.UUID, user: User = Depends(C), db: Session = Depends(get_db)):
    """Contractor roster: per worker today's attendance, days worked, amount due, payment state."""
    job = _own(db, user, job_id)
    if job.kind != "team":
        raise AppError("err.not_found", 404)
    return team.roster(db, job, user.language_code)


@router.post("/jobs/{job_id}/team/{assignment_id}/settle")
def team_settle(job_id: uuid.UUID, assignment_id: uuid.UUID, body: SettleIn, user: User = Depends(C), db: Session = Depends(get_db)):
    """Rate one team member (mandatory) -> pay him for the days he worked; unworked days go back to the contractor."""
    job = _own(db, user, job_id)
    a = db.get(Assignment, assignment_id)
    if not a or a.job_id != job.id:
        raise AppError("err.not_found", 404)
    out = team.settle_worker(db, user, job, a, quality=body.quality, timeliness=body.timeliness, behaviour=body.behaviour,
                             value_for_money=body.value_for_money, comment=body.comment)
    db.commit()
    return out


@router.post("/jobs/{job_id}/complete")
def complete(job_id: uuid.UUID, user: User = Depends(C), db: Session = Depends(get_db)):
    job = _own(db, user, job_id)
    if job.kind == "team":  # team jobs finish when every worker is settled
        raise AppError("err.team_use_roster", 409)
    flows.complete_work(db, user, _assignment(db, job))
    db.commit()
    return {"status": job.status.value}


class RateIn(BaseModel):
    quality: int
    timeliness: int
    behaviour: int
    value_for_money: int
    comment: str | None = None


@router.post("/jobs/{job_id}/rate")
def rate(job_id: uuid.UUID, body: RateIn, user: User = Depends(C), db: Session = Depends(get_db)):
    """C5. Mandatory rating → releases escrow in the same transaction."""
    job = _own(db, user, job_id)
    a = _assignment(db, job)
    r = flows.rate_worker(db, user, a, quality=body.quality, timeliness=body.timeliness, behaviour=body.behaviour,
                          value_for_money=body.value_for_money, comment=body.comment)
    db.commit()
    p = db.scalar(select(Payment).where(Payment.assignment_id == a.id))
    return {"overall": r.overall, "payment": payment_view(p)}


@router.post("/jobs/{job_id}/release")
def release(job_id: uuid.UUID, user: User = Depends(C), db: Session = Depends(get_db)):
    """Exists so the rule is testable/obvious: without a rating this ALWAYS fails."""
    job = _own(db, user, job_id)
    p = flows.release_payment(db, _assignment(db, job), user.id)
    db.commit()
    return payment_view(p)


@router.post("/jobs/{job_id}/cancel")
def cancel(job_id: uuid.UUID, user: User = Depends(C), db: Session = Depends(get_db)):
    """Cancel the job. Before a hire: free. Hired but work not started: the hire ends and anything paid is
    refunded IN FULL. Work started: not here - report a problem (support decides). Idempotent."""
    job = _own(db, user, job_id)
    if job.status == JobStatus.cancelled:
        return {"status": "cancelled", "refunded_inr": 0}
    if job.status in (JobStatus.open, JobStatus.bidding):
        transition(db, job, kind="job", field="status", new=JobStatus.cancelled, actor_id=user.id)
        for b in db.scalars(select(Bid).where(Bid.job_id == job.id, Bid.status == BidStatus.pending)):
            transition(db, b, kind="bid", field="status", new=BidStatus.rejected, actor_id=user.id)
        db.commit()
        return {"status": job.status.value, "refunded_inr": 0}
    a = flows.active_assignment(db, job.id)
    if job.status == JobStatus.assigned and a:
        out = flows.customer_cancel_hire(db, user, a, reopen=False)
        db.commit()
        return out
    raise AppError("err.job_started_dispute" if job.status == JobStatus.in_progress else "err.job_closed", 409)


@router.post("/jobs/{job_id}/reopen")
def reopen(job_id: uuid.UUID, user: User = Depends(C), db: Session = Depends(get_db)):
    """"Choose another worker": ends the current hire (refund if paid) and puts the job back on the market;
    earlier quotes return."""
    job = _own(db, user, job_id)
    a = flows.active_assignment(db, job.id)
    if not a:
        if job.status in (JobStatus.open, JobStatus.bidding):
            return {"status": job.status.value, "refunded_inr": 0}  # idempotent double tap
        raise AppError("err.job_closed", 409)
    out = flows.customer_cancel_hire(db, user, a, reopen=True)
    db.commit()
    return out


@router.post("/jobs/{job_id}/no-show")
def no_show(job_id: uuid.UUID, user: User = Depends(C), db: Session = Depends(get_db)):
    """"Worker never arrived": allowed 60 min after the ETA. Refund if paid, job re-opens, worker gets a strike."""
    job = _own(db, user, job_id)
    out = flows.report_no_show(db, user, _assignment(db, job))
    db.commit()
    return out


@router.post("/jobs/{job_id}/nudge")
def nudge(job_id: uuid.UUID, user: User = Depends(C), db: Session = Depends(get_db)):
    """No quotes yet: remind nearby workers (max once every 6 h)."""
    flows.nudge_workers(db, user, _own(db, user, job_id))
    db.commit()
    return {"ok": True}


class ReworkIn(BaseModel):
    reasons: list[str] = Field(min_length=1, max_length=5)
    note: str | None = Field(default=None, max_length=1000)
    photos: list[str] = Field(default=[], max_length=5)


@router.post("/jobs/{job_id}/rework")
def rework(job_id: uuid.UUID, body: ReworkIn, user: User = Depends(C), db: Session = Depends(get_db)):
    """"Not done yet - send back" (rounds 1-2). The 3rd disagreement opens a dispute automatically."""
    job = _own(db, user, job_id)
    out = flows.request_rework(db, user, _assignment(db, job), body.reasons, body.note, body.photos)
    db.commit()
    return out


class DisputeIn(BaseModel):
    reason: str = Field(min_length=5, max_length=2000)


@router.post("/jobs/{job_id}/dispute")
def dispute(job_id: uuid.UUID, body: DisputeIn, user: User = Depends(C), db: Session = Depends(get_db)):
    job = _own(db, user, job_id)
    d = flows.raise_dispute(db, user, _assignment(db, job), body.reason)
    db.commit()
    return {"id": str(d.id), "status": d.status.value}


@router.get("/payments")
def payments(user: User = Depends(C), db: Session = Depends(get_db)):
    """C6 receipts."""
    rows = db.execute(select(Payment, Assignment).join(Assignment, Assignment.id == Payment.assignment_id)
                      .join(Job, Job.id == Assignment.job_id).where(Job.customer_id == user.id)
                      .order_by(Job.created_at.desc())).all()
    out = []
    for p, a in rows:
        wv = trust.warranty_view(db, a)
        out.append({**payment_view(p), "job_id": str(a.job_id), "locality": a.job.locality, "worker_name": a.worker.name,
                    "trades": sorted({wi.trade.value for wi in a.job.work_items}),
                    "warranty_days": wv["days"] if wv else 0, "warranty_until": wv["until"] if wv else None})
    return out


@router.get("/workers")
def browse_workers(trade: Trade | None = None, user: User = Depends(C), db: Session = Depends(get_db)):
    """'Browse workers nearby' — verified, not suspended, best rated first."""
    q = select(User).join(WorkerProfile, WorkerProfile.user_id == User.id).where(
        User.role == Role.worker, WorkerProfile.is_suspended.is_(False), User.kyc_level >= 1)
    if trade:
        q = q.where(WorkerProfile.trades.any(trade.value))
    rows = db.scalars(q.order_by(WorkerProfile.overall_rating.desc()).limit(200)).all()
    # best rated first (to 1 decimal); at equal rating the police-verified worker ranks higher ("Verified first" tie-breaker)
    rows = sorted(rows, key=lambda w: (-round(w.worker_profile.overall_rating, 1), w.worker_profile.police_status != "verified",
                                       -w.worker_profile.rating_count))[:50]
    return [{**worker_summary(db, w), "online": w.worker_profile.is_online} for w in rows]


@router.get("/workers/{worker_id}")
def worker_profile(worker_id: uuid.UUID, user: User = Depends(C), db: Session = Depends(get_db)):
    w = db.get(User, worker_id)
    if not w or w.role != Role.worker:
        raise AppError("err.not_found", 404)
    wp = w.worker_profile
    return {**worker_summary(db, w), "breakdown": rating_breakdown(db, w.id), "history": worker_history(db, w.id),
            "warranty_record": trust.worker_warranty_record(db, wp), "level_card": levels.level_view(wp),
            "streak": levels.streak(db, w.id)}


@router.get("/favourites")
def favourites(user: User = Depends(C), db: Session = Depends(get_db)):
    """"Your workers": everyone this customer rated 4 or more (real ratings only)."""
    return trust.favourites(db, user)


@router.get("/workers/{worker_id}/rebook")
def rebook_worker(worker_id: uuid.UUID, user: User = Depends(C), db: Session = Depends(get_db)):
    """Prefill for "Hire again" from a worker's profile: last job done together (else the latest address)."""
    w = db.get(User, worker_id)
    if not w or w.role != Role.worker or not w.worker_profile:
        raise AppError("err.not_found", 404)
    return trust.rebook_draft(db, user, worker=w)


@router.get("/jobs/{job_id}/rebook")
def rebook_job(job_id: uuid.UUID, user: User = Depends(C), db: Session = Depends(get_db)):
    """Prefill for "Hire again" from a past booking: trade, address and last description + the worker who did it."""
    job = _own(db, user, job_id)
    if job.kind == "team":
        raise AppError("err.validation", 422)
    return trust.rebook_draft(db, user, job=job)


@router.post("/jobs/{job_id}/share-trip")
def share_trip(job_id: uuid.UUID, user: User = Depends(C), db: Session = Depends(get_db)):
    """Share live trip: a link (https://buildcrew.app/t/<token>) with the worker, his ETA and nothing about the customer."""
    out = trust.share_trip(db, user, _assignment(db, _own(db, user, job_id)))
    db.commit()
    return out


class RefixIn(BaseModel):
    reason: str = Field(min_length=5, max_length=1000)
    photos: list[str] = Field(default=[], max_length=5)
    assignment_id: uuid.UUID | None = None  # team jobs: which worker


@router.post("/jobs/{job_id}/refix")
def refix(job_id: uuid.UUID, body: RefixIn, user: User = Depends(C), db: Session = Depends(get_db)):
    """"Problem came back": inside the warranty window the SAME worker returns for free (a linked re-fix visit)."""
    job = _own(db, user, job_id)
    if job.kind == "team":
        a = db.get(Assignment, body.assignment_id) if body.assignment_id else None
        if not a or a.job_id != job.id:
            raise AppError("err.not_found", 404)
    else:
        a = flows.active_assignment(db, job.id)
        if not a:
            raise AppError("err.hire_cancelled", 409)
    r = trust.request_refix(db, user, a, body.reason, body.photos)
    db.commit()
    return {"job_id": str(r.job_id), "assignment_id": str(r.id)}
