import uuid
from datetime import datetime

from fastapi import APIRouter, Depends
from pydantic import BaseModel, Field
from sqlalchemy import and_, or_, select
from sqlalchemy.orm import Session, selectinload

from .. import services
from ..audit import audit
from ..config import get_settings
from ..crypto import mask_upi
from ..db import get_db
from ..domain import flows, pricing, team
from ..domain.policies import can_access_job_media
from ..enums import JobStatus, Role, Trade
from ..errors import AppError
from ..i18n import t
from ..models import Assignment, Bid, Job, Payment, Payout, User, WorkItem
from ..security import require
from .views import assignment_view, job_card, rating_breakdown, signed, work_item_view, worker_history, worker_summary

router = APIRouter(prefix="/worker", tags=["worker"])
W = require(Role.worker)


def _job(db: Session, job_id: uuid.UUID) -> Job:
    job = db.get(Job, job_id)
    if not job:
        raise AppError("err.not_found", 404)
    return job


def _my_assignment(db: Session, user: User, assignment_id: uuid.UUID) -> Assignment:
    a = db.get(Assignment, assignment_id)
    if not a or a.worker_id != user.id:
        raise AppError("err.not_found", 404)
    return a


@router.get("/feed")
def feed(user: User = Depends(W), db: Session = Depends(get_db)):
    """S4. NO audio URLs here — only the 🔊 badge (duration + KB). Audio is fetched on the
    detail screen when the worker taps play: tiny feed on 2G/3G and never auto-plays."""
    wp = user.worker_profile
    origin = (wp.home_lat, wp.home_lng) if wp.home_lat else None
    jobs = db.scalars(select(Job).where(or_(Job.status.in_([JobStatus.open, JobStatus.bidding]),
                                            and_(Job.kind == "team", Job.status.in_([JobStatus.assigned, JobStatus.in_progress]))))
                      .options(selectinload(Job.work_items).selectinload(WorkItem.photos))
                      .order_by(Job.created_at.desc())).all()
    my_bids = {b.job_id: b for b in db.scalars(select(Bid).where(Bid.worker_id == user.id))}
    out = []
    for job in jobs:
        trades = [wi.trade.value for wi in job.work_items]
        if wp.trades and not set(trades) & set(wp.trades):
            continue
        tsum = team.summary(db, job)
        if tsum and not any(i["filled"] < i["headcount"] and (not wp.trades or i["trade"] in wp.trades) for i in tsum["items"]):
            continue  # every line this worker could fill is already full
        dist = services.maps().distance_km(origin, (job.location_lat, job.location_lng)) if origin else None
        if dist is not None and dist > get_settings().worker_feed_radius_km:
            continue
        audio = [wi for wi in job.work_items if wi.audio_url and not wi.audio_muted]
        mine = my_bids.get(job.id)
        out.append({
            "id": str(job.id), "locality": job.locality,
            "trades": [{"code": tr, "label": t(f"trade.{tr}", user.language_code)} for tr in dict.fromkeys(trades)],
            "thumbnails": [signed(p.photo_url) for wi in job.work_items for p in wi.photos][:4],
            "audio": {"count": len(audio), "total_seconds": sum(wi.audio_duration_sec or 0 for wi in audio),
                      "total_kb": round(sum(wi.audio_size_bytes or 0 for wi in audio) / 1024)} if audio else None,
            "work_count": len(job.work_items), "distance_km": round(dist, 1) if dist is not None else None,
            "posted_at": job.created_at.isoformat(), "start_date": job.start_date.isoformat(),
            "kind": job.kind, "team": tsum, "scheduled_for": job.scheduled_for.isoformat() if job.scheduled_for else None,
            "time_slot": job.time_slot,
            "already_bid": mine is not None, "my_price_inr": mine.quoted_price_paise / 100 if mine else None,
        })
    return out


@router.get("/jobs/{job_id}")
def job_detail(job_id: uuid.UUID, user: User = Depends(W), db: Session = Depends(get_db)):
    """S5. Each work item: photos, text + transcript translated into the worker's language,
    and a signed audio URL (only if the access policy allows)."""
    job = _job(db, job_id)
    allowed = can_access_job_media(db, user, job)
    if not allowed and job.status not in (JobStatus.open, JobStatus.bidding) and not (job.kind == "team" and job.status in (JobStatus.assigned, JobStatus.in_progress)):
        raise AppError("err.forbidden", 403)
    mine = db.scalar(select(Bid).where(Bid.job_id == job.id, Bid.worker_id == user.id))
    wp = user.worker_profile
    dist = services.maps().distance_km((wp.home_lat, wp.home_lng), (job.location_lat, job.location_lng)) if wp.home_lat else None
    out = {**job_card(db, job, user.language_code),
           "address": job.address_text if mine and mine.status.value == "accepted" else job.locality,  # exact address only once hired
           "distance_km": round(dist, 1) if dist is not None else None,
           "work_items": [work_item_view(db, wi, user.language_code, include_audio=allowed) for wi in job.work_items],
           "my_bid": {"id": str(mine.id), "price_inr": mine.quoted_price_paise / 100, "status": mine.status.value} if mine else None,
           "bid_count": len(job.bids),
           "fair_range": pricing.fair_range(job, wp.trades)}
    if job.kind == "team":
        # A team line is a DAILY wage: the fair range is the day-wage band of the trade this worker would fill.
        mine_item = next((wi for wi in job.work_items if not wp.trades or wi.trade.value in wp.trades), job.work_items[0])
        dw = pricing.day_wage_range(mine_item.trade.value, job.city)
        out["fair_range"] = {"low": dw["low"], "median": dw["median"], "high": dw["high"], "min_wage_total": dw["min_wage"], "est_days": 1}
        out["my_item"] = {"trade": mine_item.trade.value, "days": mine_item.days, "daily_wage_inr": (mine_item.daily_wage_paise or 0) / 100,
                          "headcount": mine_item.headcount}
        out["open_for_team"] = job.status in team.HIRING and team.open_slots(db, job) > 0
    db.commit()  # persist any freshly cached translations
    return out


class BidIn(BaseModel):
    job_id: uuid.UUID
    price_inr: int = Field(ge=100, le=10_000_000)
    client_ref: str | None = Field(default=None, max_length=64)  # offline idempotency key


@router.post("/bids")
def place_bid(body: BidIn, user: User = Depends(W), db: Session = Depends(get_db)):
    bid = flows.place_bid(db, user, _job(db, body.job_id), body.price_inr * 100, body.client_ref)
    db.commit()
    return {"id": str(bid.id), "status": bid.status.value, "price_inr": bid.quoted_price_paise / 100}


@router.get("/bids")
def my_bids(user: User = Depends(W), db: Session = Depends(get_db)):
    """S6. Status pills: pending (amber), accepted (green), rejected/withdrawn (grey) + message."""
    bids = db.scalars(select(Bid).where(Bid.worker_id == user.id).order_by(Bid.created_at.desc())).all()
    out = []
    for b in bids:
        a = db.scalar(select(Assignment).where(Assignment.accepted_bid_id == b.id))
        out.append({"id": str(b.id), "price_inr": b.quoted_price_paise / 100, "status": b.status.value,
                    "created_at": b.created_at.isoformat(), "job": job_card(db, b.job, user.language_code),
                    "assignment_id": str(a.id) if a else None,
                    "message": t("bid.not_selected", user.language_code) if b.status.value == "rejected" else None})
    return out


@router.post("/bids/{bid_id}/withdraw")
def withdraw_bid(bid_id: uuid.UUID, user: User = Depends(W), db: Session = Depends(get_db)):
    bid = db.get(Bid, bid_id)
    if not bid:
        raise AppError("err.not_found", 404)
    flows.withdraw_bid(db, user, bid)
    db.commit()
    return {"ok": True}


@router.get("/assignments")
def assignments(user: User = Depends(W), db: Session = Depends(get_db)):
    rows = db.scalars(select(Assignment).where(Assignment.worker_id == user.id)).all()
    out = []
    for a in sorted(rows, key=lambda x: x.job.created_at, reverse=True):
        v = assignment_view(db, a, user.language_code)
        v["job"] = {**job_card(db, a.job, user.language_code), "address": a.job.address_text}
        v["customer_name"] = a.job and db.get(User, a.job.customer_id).name
        out.append(v)
    return out


@router.post("/assignments/{assignment_id}/start")
def start(assignment_id: uuid.UUID, user: User = Depends(W), db: Session = Depends(get_db)):
    flows.start_work(db, user, _my_assignment(db, user, assignment_id))
    db.commit()
    return {"ok": True}


class LocIn(BaseModel):
    lat: float | None = Field(default=None, ge=6, le=37.5)
    lng: float | None = Field(default=None, ge=68, le=97.5)


@router.post("/assignments/{assignment_id}/journey")
def journey(assignment_id: uuid.UUID, body: LocIn, user: User = Depends(W), db: Session = Depends(get_db)):
    """'I'm on my way' — starts live location sharing for the customer's ETA."""
    flows.start_journey(db, user, _my_assignment(db, user, assignment_id), body.lat, body.lng)
    db.commit()
    return {"ok": True}


@router.post("/assignments/{assignment_id}/location")
def location(assignment_id: uuid.UUID, body: LocIn, user: User = Depends(W), db: Session = Depends(get_db)):
    if body.lat is None or body.lng is None:
        raise AppError("err.validation", 422)
    flows.update_location(db, user, _my_assignment(db, user, assignment_id), body.lat, body.lng)
    db.commit()
    return {"ok": True}


@router.post("/assignments/{assignment_id}/done")
def done(assignment_id: uuid.UUID, user: User = Depends(W), db: Session = Depends(get_db)):
    flows.worker_done(db, user, _my_assignment(db, user, assignment_id))
    db.commit()
    return {"ok": True}


class AttendanceIn(BaseModel):
    assignment_id: uuid.UUID
    kind: str = Field(pattern="^(in|out)$")
    lat: float
    lng: float
    at: datetime | None = None
    selfie_key: str | None = None
    client_ref: str | None = Field(default=None, max_length=64)
    offline: bool = False


@router.post("/attendance")
def attendance(body: AttendanceIn, user: User = Depends(W), db: Session = Depends(get_db)):
    a = _my_assignment(db, user, body.assignment_id)
    row = flows.attendance(db, user, a, kind=body.kind, lat=body.lat, lng=body.lng, at=body.at,
                           selfie_key=body.selfie_key, client_ref=body.client_ref, offline=body.offline)
    db.commit()
    return {"id": str(row.id), "geofence_ok": row.geofence_ok}


class RateCustomerIn(BaseModel):
    clarity: int
    timely_payment: int
    comment: str | None = None


@router.post("/assignments/{assignment_id}/rate-customer")
def rate_customer(assignment_id: uuid.UUID, body: RateCustomerIn, user: User = Depends(W), db: Session = Depends(get_db)):
    r = flows.rate_customer(db, user, _my_assignment(db, user, assignment_id), clarity=body.clarity,
                            timely_payment=body.timely_payment, comment=body.comment)
    db.commit()
    return {"overall": r.overall}


@router.get("/earnings")
def earnings(user: User = Depends(W), db: Session = Depends(get_db)):
    """S7. One dominant number (available), plus held-in-escrow and history rows."""
    bal = flows.worker_balance(db, user.id)
    released = db.execute(select(Payment, Assignment).join(Assignment, Assignment.id == Payment.assignment_id)
                          .where(Assignment.worker_id == user.id).order_by(Payment.released_at.desc().nullslast())).all()
    rows = [{"kind": "job", "amount_inr": p.worker_payout_paise / 100, "state": p.escrow_state.value,
             "date": (p.released_at or a.completed_at or a.job.created_at).isoformat(), "locality": a.job.locality,
             "trades": sorted({wi.trade.value for wi in a.job.work_items})} for p, a in released]
    rows += [{"kind": "payout", "amount_inr": po.amount_paise / 100, "state": po.status, "date": po.created_at.isoformat(),
              "upi": po.upi_masked} for po in db.scalars(select(Payout).where(Payout.worker_id == user.id))]
    rows.sort(key=lambda r: r["date"], reverse=True)
    return {"available_inr": bal["available_paise"] / 100, "held_inr": bal["held_paise"] / 100,
            "total_earned_inr": bal["total_earned_paise"] / 100, "paid_out_inr": bal["paid_out_paise"] / 100,
            "upi": mask_upi(user.worker_profile.upi_id), "kyc": flows.kyc_state(user), "history": rows}


@router.post("/withdraw")
def withdraw(user: User = Depends(W), db: Session = Depends(get_db)):
    p = flows.withdraw(db, user)
    db.commit()
    return {"amount_inr": p.amount_paise / 100, "upi": p.upi_masked, "ref": p.provider_ref}


@router.get("/profile")
def profile(user: User = Depends(W), db: Session = Depends(get_db)):
    """S8: overall + parameter-wise ratings, history with photos, badges, KYC state."""
    wp = user.worker_profile
    return {**worker_summary(db, user), "phone": user.phone, "upi": mask_upi(wp.upi_id), "is_online": wp.is_online,
            "breakdown": rating_breakdown(db, user.id), "history": worker_history(db, user.id),
            "kyc": flows.kyc_state(user), "eshram_registered": bool(wp.eshram_id), "strikes": wp.strikes}


@router.get("/labour-card")
def labour_card(user: User = Depends(W), db: Session = Depends(get_db)):
    """'My Labour Card' — a portable record the worker owns. Contains no phone/UPI/ID numbers."""
    wp = user.worker_profile
    b = rating_breakdown(db, user.id)
    return {"name": user.name, "trades": list(wp.trades or []), "rating": b["overall"], "rating_count": b["count"],
            "completed_jobs": wp.completed_jobs, "badges": list(wp.badges or []), "breakdown": b,
            "verified_level": user.kyc_level, "eshram_registered": bool(wp.eshram_id), "city": wp.city,
            "member_since": user.created_at.date().isoformat(), "card_id": f"BC-{user.id.hex[:8].upper()}"}


class KycL1In(BaseModel):
    name: str = Field(min_length=2, max_length=120)
    upi_id: str = Field(pattern=r"^[a-zA-Z0-9.\-_]{2,64}@[a-zA-Z]{2,32}$")
    selfie_key: str | None = None
    trades: list[Trade] | None = None


@router.post("/kyc/level1")
def kyc_level1(body: KycL1In, user: User = Depends(W), db: Session = Depends(get_db)):
    wp = user.worker_profile
    user.name, wp.upi_id = body.name.strip(), body.upi_id.strip().lower()
    if body.selfie_key:
        wp.selfie_url = body.selfie_key
    if body.trades:
        wp.trades = [tr.value for tr in body.trades]
    user.kyc_level = max(user.kyc_level, 1)
    audit(db, actor_id=user.id, action="kyc.level1", entity="user", entity_id=user.id)
    db.commit()
    return {"kyc_level": user.kyc_level}


class KycL2In(BaseModel):
    doc_type: str = Field(pattern="^(aadhaar|pan)$")
    doc_key: str


@router.post("/kyc/level2")
def kyc_level2(body: KycL2In, user: User = Depends(W), db: Session = Depends(get_db)):
    from ..enums import DocStatus
    wp = user.worker_profile
    wp.kyc_doc_type, wp.kyc_doc_key, wp.kyc_note = body.doc_type, body.doc_key, None
    setattr(wp, f"{body.doc_type}_status", DocStatus.pending)
    audit(db, actor_id=user.id, action="kyc.level2_submitted", entity="user", entity_id=user.id, doc=body.doc_type)
    db.commit()
    return {"status": "pending"}


class ProfilePatch(BaseModel):
    trades: list[Trade] | None = None
    is_online: bool | None = None
    # Current position from the phone → feed radius + distances. Bounded to India.
    home_lat: float | None = Field(default=None, ge=6, le=37.5)
    home_lng: float | None = Field(default=None, ge=68, le=97.5)


@router.patch("/profile")
def patch_profile(body: ProfilePatch, user: User = Depends(W), db: Session = Depends(get_db)):
    wp = user.worker_profile
    if body.trades is not None:
        wp.trades = [tr.value for tr in body.trades]
    if body.is_online is not None:
        wp.is_online = body.is_online
    if body.home_lat is not None and body.home_lng is not None:
        wp.home_lat, wp.home_lng = body.home_lat, body.home_lng
    db.commit()
    return {"ok": True}
