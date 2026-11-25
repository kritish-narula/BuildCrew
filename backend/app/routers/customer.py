import statistics
import uuid
from datetime import date

from fastapi import APIRouter, Depends, Query
from pydantic import BaseModel, Field
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from .. import services
from ..audit import audit
from ..config import get_settings
from ..db import get_db
from ..domain import flows
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


def _assignment(db: Session, job: Job) -> Assignment:
    a = db.scalar(select(Assignment).where(Assignment.job_id == job.id))
    if not a:
        raise AppError("err.not_found", 404)
    return a


@router.get("/jobs")
def jobs(user: User = Depends(C), db: Session = Depends(get_db)):
    """C1. Active + completed jobs with bid counts and the 'rate to release payment' flag."""
    rows = db.scalars(select(Job).where(Job.customer_id == user.id).order_by(Job.created_at.desc())).all()
    counts = dict(db.execute(select(Bid.job_id, func.count()).where(Bid.job_id.in_([j.id for j in rows]),
                                                                    Bid.status != BidStatus.withdrawn)
                             .group_by(Bid.job_id)).all()) if rows else {}
    out = []
    for j in rows:
        a = db.scalar(select(Assignment).where(Assignment.job_id == j.id))
        p = db.scalar(select(Payment).where(Payment.assignment_id == a.id)) if a else None
        out.append({**job_card(db, j, user.language_code), "bid_count": counts.get(j.id, 0),
                    "needs_rating": j.status == JobStatus.completed and p is not None and p.escrow_state.value == "held",
                    "worker_name": a.worker.name if a else None,
                    "payment_state": p.escrow_state.value if p else None})
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


class JobIn(BaseModel):
    location_lat: float
    location_lng: float
    address_text: str = Field(min_length=3, max_length=300)
    city: str = "Pune"
    locality: str | None = None
    start_date: date
    work_items: list[WorkItemIn]


@router.post("/jobs")
def create_job(body: JobIn, user: User = Depends(C), db: Session = Depends(get_db)):
    """C2. One job, many work cards; each may have photos AND text AND a voice note."""
    s = get_settings()
    if not body.work_items:
        raise AppError("err.no_work_items", 422)
    for wi in body.work_items:
        if len(wi.photo_keys) > 5:
            raise AppError("err.too_many_photos", 422)
        if wi.audio_duration_sec and wi.audio_duration_sec > s.audio_max_seconds + 2:
            raise AppError("err.audio_too_long", 422)
        if not (wi.text_description or wi.transcript or wi.audio_key or wi.photo_keys):
            raise AppError("err.validation", 422)
    locality = body.locality or services.maps().reverse_locality(body.location_lat, body.location_lng) or body.city
    job = Job(customer_id=user.id, location_lat=body.location_lat, location_lng=body.location_lng,
              address_text=body.address_text, city=body.city, locality=locality, start_date=body.start_date)
    db.add(job)
    db.flush()
    for i, w in enumerate(body.work_items):
        item = WorkItem(job_id=job.id, sort_order=i, trade=w.trade, text_description=w.text_description,
                        transcript=w.transcript, description_language=w.description_language,
                        audio_url=w.audio_key, audio_duration_sec=w.audio_duration_sec, audio_size_bytes=w.audio_size_bytes,
                        audio_upload_state=AudioUploadState.uploaded if w.audio_key else None)
        db.add(item)
        db.flush()
        for k, key in enumerate(w.photo_keys):
            db.add(WorkItemPhoto(work_item_id=item.id, photo_url=key, sort_order=k))
    audit(db, actor_id=user.id, action="job.posted", entity="job", entity_id=job.id, items=len(body.work_items))
    db.commit()
    return {"id": str(job.id), "status": job.status.value, "locality": locality}


@router.get("/price-estimate")
def price_estimate(trades: str = Query(..., description="comma-separated"), locality: str | None = None,
                   city: str = "Pune", user: User = Depends(C), db: Session = Depends(get_db)):
    """C2 step 4: fair price from completed jobs of the same trade, same locality first,
    falling back to the whole city when the locality has too few data points."""
    out, low_sum, high_sum = [], 0, 0
    for code in dict.fromkeys(trades.split(",")):
        try:
            trade = Trade(code.strip())
        except ValueError:
            continue
        q = select(PriceHistory.price_paise).where(PriceHistory.trade == trade, PriceHistory.city == city)
        prices = db.scalars(q.where(PriceHistory.locality == locality)).all() if locality else []
        scope = "locality"
        if len(prices) < 5:
            prices, scope = db.scalars(q).all(), "city"
        if len(prices) < 5:  # new city with no history yet → national data
            prices, scope = db.scalars(select(PriceHistory.price_paise).where(PriceHistory.trade == trade)).all(), "all"
        if not prices:
            continue
        qs = statistics.quantiles(sorted(prices), n=4) if len(prices) >= 4 else [min(prices), statistics.median(prices), max(prices)]
        lo, med, hi = round(qs[0] / 100 / 50) * 50, round(qs[1] / 100 / 50) * 50, round(qs[2] / 100 / 50) * 50
        low_sum, high_sum = low_sum + lo, high_sum + hi
        out.append({"trade": trade.value, "low_inr": lo, "median_inr": med, "high_inr": hi, "samples": len(prices), "scope": scope})
    return {"items": out, "total_low_inr": low_sum, "total_high_inr": high_sum,
            "platform_fee_inr": get_settings().platform_fee_flat_inr}


@router.get("/jobs/{job_id}")
def job_detail(job_id: uuid.UUID, user: User = Depends(C), db: Session = Depends(get_db)):
    """C3/C4. Work items, bids for comparison, assignment tracking + escrow + ratings."""
    job = _own(db, user, job_id)
    bids = db.scalars(select(Bid).where(Bid.job_id == job.id, Bid.status != BidStatus.withdrawn)
                      .order_by(Bid.quoted_price_paise)).all()
    a = db.scalar(select(Assignment).where(Assignment.job_id == job.id))
    out = {**job_card(db, job, user.language_code),
           "work_items": [work_item_view(db, wi, user.language_code, include_audio=True) for wi in job.work_items],
           "bids": [{"id": str(b.id), "price_inr": b.quoted_price_paise / 100, "status": b.status.value,
                     "created_at": b.created_at.isoformat(), "worker": worker_summary(db, b.worker)} for b in bids],
           "assignment": assignment_view(db, a, user.language_code),
           "fee_inr": get_settings().platform_fee_flat_inr}
    db.commit()
    return out


@router.post("/jobs/{job_id}/bids/{bid_id}/accept")
def accept(job_id: uuid.UUID, bid_id: uuid.UUID, user: User = Depends(C), db: Session = Depends(get_db)):
    job = _own(db, user, job_id)
    bid = db.get(Bid, bid_id)
    if not bid:
        raise AppError("err.not_found", 404)
    a = flows.accept_bid(db, user, job, bid)
    db.commit()
    p = db.scalar(select(Payment).where(Payment.assignment_id == a.id))
    # Checkout params for the client (key_id is PUBLIC; the secret never leaves the server).
    return {"assignment_id": str(a.id), "payment": payment_view(p),
            "checkout": {"order_id": p.razorpay_ref, "key_id": get_settings().razorpay_key_id or "rzp_test_mock",
                         "amount_paise": p.amount_paise}}


@router.post("/jobs/{job_id}/complete")
def complete(job_id: uuid.UUID, user: User = Depends(C), db: Session = Depends(get_db)):
    job = _own(db, user, job_id)
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
    job = _own(db, user, job_id)
    if job.status not in (JobStatus.open, JobStatus.bidding):
        raise AppError("err.job_closed", 409)
    transition(db, job, kind="job", field="status", new=JobStatus.cancelled, actor_id=user.id)
    for b in db.scalars(select(Bid).where(Bid.job_id == job.id, Bid.status == BidStatus.pending)):
        transition(db, b, kind="bid", field="status", new=BidStatus.rejected, actor_id=user.id)
    db.commit()
    return {"status": job.status.value}


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
    return [{**payment_view(p), "job_id": str(a.job_id), "locality": a.job.locality, "worker_name": a.worker.name,
             "trades": sorted({wi.trade.value for wi in a.job.work_items})} for p, a in rows]


@router.get("/workers")
def browse_workers(trade: Trade | None = None, user: User = Depends(C), db: Session = Depends(get_db)):
    """'Browse workers nearby' — verified, not suspended, best rated first."""
    q = select(User).join(WorkerProfile, WorkerProfile.user_id == User.id).where(
        User.role == Role.worker, WorkerProfile.is_suspended.is_(False), User.kyc_level >= 1)
    if trade:
        q = q.where(WorkerProfile.trades.any(trade.value))
    rows = db.scalars(q.order_by(WorkerProfile.overall_rating.desc()).limit(50)).all()
    return [{**worker_summary(db, w), "online": w.worker_profile.is_online} for w in rows]


@router.get("/workers/{worker_id}")
def worker_profile(worker_id: uuid.UUID, user: User = Depends(C), db: Session = Depends(get_db)):
    w = db.get(User, worker_id)
    if not w or w.role != Role.worker:
        raise AppError("err.not_found", 404)
    return {**worker_summary(db, w), "breakdown": rating_breakdown(db, w.id), "history": worker_history(db, w.id)}
