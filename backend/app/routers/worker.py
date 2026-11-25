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
from ..domain import flows, levels, pricing, team, trust
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
    flows.maybe_auto_confirm(db, a)
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
        ex = trust.exclusive_to(job)
        if ex is not None and ex != user.id:
            continue  # a "hire again" offer is for ONE worker until he declines or the 2 hours pass
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
            "direct": {"customer_name": db.get(User, job.customer_id).name, "until": job.direct_until.isoformat()}
            if ex == user.id else None,
        })
    out.sort(key=lambda r: 0 if r["direct"] else 1)  # stable: direct requests first, newest first otherwise
    return out


@router.get("/jobs/{job_id}")
def job_detail(job_id: uuid.UUID, user: User = Depends(W), db: Session = Depends(get_db)):
    """S5. Each work item: photos, text + transcript translated into the worker's language,
    and a signed audio URL (only if the access policy allows)."""
    job = _job(db, job_id)
    trust.check_direct_access(job, user)
    allowed = can_access_job_media(db, user, job)
    if not allowed and job.status not in (JobStatus.open, JobStatus.bidding) and not (job.kind == "team" and job.status in (JobStatus.assigned, JobStatus.in_progress)):
        raise AppError("err.forbidden", 403)
    mine = db.scalar(select(Bid).where(Bid.job_id == job.id, Bid.worker_id == user.id))
    wp = user.worker_profile
    dist = services.maps().distance_km((wp.home_lat, wp.home_lng), (job.location_lat, job.location_lng)) if wp.home_lat else None
    lvl = levels.level_for(wp.completed_jobs, wp.overall_rating if wp.rating_count else 0.0, wp.refix_count)
    mult = lvl["fair_multiplier"]
    out = {**job_card(db, job, user.language_code),
           "address": job.address_text if mine and mine.status.value == "accepted" else job.locality,  # exact address only once hired
           "distance_km": round(dist, 1) if dist is not None else None,
           "work_items": [work_item_view(db, wi, user.language_code, include_audio=allowed) for wi in job.work_items],
           "my_bid": {"id": str(mine.id), "price_inr": mine.quoted_price_paise / 100, "status": mine.status.value} if mine else None,
           "bid_count": len(job.bids),
           "fair_range": pricing.scale_range(pricing.fair_range(job, wp.trades), mult),
           "level": lvl["code"], "level_multiplier": mult,
           "direct": ({"customer_name": db.get(User, job.customer_id).name, "until": job.direct_until.isoformat(),
                       "state": trust.direct_state(job)} if job.direct_worker_id == user.id else None)}
    if job.kind == "team":
        # A team line is a DAILY wage: the fair range is the day-wage band of the trade this worker would fill.
        mine_item = next((wi for wi in job.work_items if not wp.trades or wi.trade.value in wp.trades), job.work_items[0])
        dw = pricing.day_wage_range(mine_item.trade.value, job.city)
        out["fair_range"] = pricing.scale_range({"low": dw["low"], "median": dw["median"], "high": dw["high"],
                                                 "min_wage_total": dw["min_wage"], "est_days": 1}, mult)
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
        a = db.scalar(select(Assignment).where(Assignment.accepted_bid_id == b.id, Assignment.released_at.is_(None)))
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
    if flows.sweep_auto_confirm(db):
        db.commit()
    rows = db.scalars(select(Assignment).where(Assignment.worker_id == user.id, Assignment.released_at.is_(None))).all()
    out = []
    for a in sorted(rows, key=lambda x: x.job.created_at, reverse=True):
        v = assignment_view(db, a, user.language_code, viewer="worker")
        v["job"] = {**job_card(db, a.job, user.language_code), "address": a.job.address_text}
        v["customer_name"] = a.job and db.get(User, a.job.customer_id).name
        out.append(v)
    return out


class StartIn(BaseModel):
    code: str | None = Field(default=None, max_length=8)  # the 4 digits the customer shows on arrival


@router.post("/assignments/{assignment_id}/start")
def start(assignment_id: uuid.UUID, body: StartIn | None = None, user: User = Depends(W), db: Session = Depends(get_db)):
    """Start work. Needs the customer's 4-digit start code (err.start_code_invalid / err.start_code_locked)."""
    trust.worker_start(db, user, _my_assignment(db, user, assignment_id), (body.code if body else None))
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


class DoneIn(BaseModel):
    photos: list[str] = Field(default=[], max_length=5)  # "after" proof photo keys: at least 1 is required
    note: str | None = Field(default=None, max_length=1000)


@router.post("/assignments/{assignment_id}/done")
def done(assignment_id: uuid.UUID, body: DoneIn | None = None, user: User = Depends(W), db: Session = Depends(get_db)):
    """"Work finished" (also the "fixed it" after a send-back). Needs >= 1 proof photo. Idempotent."""
    body = body or DoneIn()
    flows.worker_done(db, user, _my_assignment(db, user, assignment_id), body.photos, body.note)
    db.commit()
    return {"ok": True}


class WorkerDisputeIn(BaseModel):
    reason: str = Field(min_length=5, max_length=2000)


@router.post("/assignments/{assignment_id}/dispute")
def dispute(assignment_id: uuid.UUID, body: WorkerDisputeIn, user: User = Depends(W), db: Session = Depends(get_db)):
    """"Customer is not confirming / unfair": money stays in escrow, support decides."""
    d = flows.raise_dispute(db, user, _my_assignment(db, user, assignment_id), body.reason)
    db.commit()
    return {"id": str(d.id), "status": d.status.value}


@router.post("/assignments/{assignment_id}/withdraw")
def withdraw_hire(assignment_id: uuid.UUID, user: User = Depends(W), db: Session = Depends(get_db)):
    """Worker can no longer do the job (before starting). Customer is refunded in full, the job re-opens,
    and a strike is recorded if the customer had already paid."""
    out = flows.worker_withdraw_hire(db, user, _my_assignment(db, user, assignment_id))
    db.commit()
    return out


class AttendanceIn(BaseModel):
    assignment_id: uuid.UUID
    kind: str = Field(pattern="^(in|out)$")
    lat: float
    lng: float
    at: datetime | None = None
    selfie_key: str | None = None
    client_ref: str | None = Field(default=None, max_length=64)
    offline: bool = False
    start_code: str | None = Field(default=None, max_length=8)  # needed for check-in; offline ones are verified on sync


@router.post("/attendance")
def attendance(body: AttendanceIn, user: User = Depends(W), db: Session = Depends(get_db)):
    a = _my_assignment(db, user, body.assignment_id)
    row = flows.attendance(db, user, a, kind=body.kind, lat=body.lat, lng=body.lng, at=body.at,
                           selfie_key=body.selfie_key, client_ref=body.client_ref, offline=body.offline,
                           start_code=body.start_code)
    db.commit()
    return {"id": str(row.id), "geofence_ok": row.geofence_ok, "code_status": row.code_status}


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
    """S7. One dominant number (available), plus held-in-escrow and history rows. Same-day pay: payouts that
    were sent to UPI automatically when a job was released show up in `paid_today`."""
    trust.settle_payouts(db, user.id)
    bal = flows.worker_balance(db, user.id)
    released = db.execute(select(Payment, Assignment).join(Assignment, Assignment.id == Payment.assignment_id)
                          .where(Assignment.worker_id == user.id).order_by(Payment.released_at.desc().nullslast())).all()
    rows = [{"kind": "job", "amount_inr": p.worker_payout_paise / 100, "state": p.escrow_state.value,
             "date": (p.released_at or a.completed_at or a.job.created_at).isoformat(), "locality": a.job.locality,
             "trades": sorted({wi.trade.value for wi in a.job.work_items})} for p, a in released]
    pays = list(db.scalars(select(Payout).where(Payout.worker_id == user.id).order_by(Payout.created_at.desc())))
    rows += [{"kind": "payout", **trust.payout_view(po), "state": trust.payout_view(po)["state"], "date": po.created_at.isoformat()} for po in pays]
    rows.sort(key=lambda r: r["date"], reverse=True)
    today = trust.now().astimezone(trust.IST).date()
    todays = []
    for po in pays:
        if po.source == "auto" and po.created_at.astimezone(trust.IST).date() == today:
            a = db.get(Assignment, po.assignment_id) if po.assignment_id else None
            todays.append({**trust.payout_view(po), "locality": a.job.locality if a else None,
                           "trades": sorted({wi.trade.value for wi in a.job.work_items}) if a else []})
    wp = user.worker_profile
    db.commit()
    return {"available_inr": bal["available_paise"] / 100, "held_inr": bal["held_paise"] / 100,
            "total_earned_inr": bal["total_earned_paise"] / 100, "paid_out_inr": bal["paid_out_paise"] / 100,
            "upi": mask_upi(wp.upi_id), "kyc": flows.kyc_state(user), "history": rows,
            "paid_today": {"total_inr": sum(x["amount_inr"] for x in todays), "items": todays},
            "nudge_add_upi": bool(bal["available_paise"] > 0 and not wp.upi_id)}


@router.get("/notices")
def notices(user: User = Depends(W), db: Session = Depends(get_db)):
    """In-app, push-style notices not yet shown: "Rs 1,300 sent to your UPI ra****@okaxis"."""
    trust.settle_payouts(db, user.id)
    rows = db.scalars(select(Payout).where(Payout.worker_id == user.id, Payout.source == "auto", Payout.notified_at.is_(None))
                      .order_by(Payout.created_at)).all()
    db.commit()
    return [{"id": str(p.id), "kind": "payout_sent", "amount_inr": p.amount_paise / 100, "upi": p.upi_masked,
             "state": trust.payout_view(p)["state"], "at": p.created_at.isoformat()} for p in rows]


class AckIn(BaseModel):
    ids: list[uuid.UUID] = Field(max_length=50)


@router.post("/notices/ack")
def ack_notices(body: AckIn, user: User = Depends(W), db: Session = Depends(get_db)):
    for p in db.scalars(select(Payout).where(Payout.worker_id == user.id, Payout.id.in_(body.ids))):
        p.notified_at = trust.now()
    db.commit()
    return {"ok": True}


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
            "kyc": flows.kyc_state(user), "eshram_registered": bool(wp.eshram_id), "strikes": wp.strikes,
            "level_card": levels.level_view(wp), "streak": levels.streak(db, user.id),
            "warranty_record": trust.worker_warranty_record(db, wp),
            "police": {"status": wp.police_status, "note": wp.police_note,
                       "requested_at": wp.police_requested_at.isoformat() if wp.police_requested_at else None}}


@router.get("/labour-card")
def labour_card(user: User = Depends(W), db: Session = Depends(get_db)):
    """'My Labour Card' — a portable record the worker owns. Contains no phone/UPI/ID numbers."""
    wp = user.worker_profile
    b = rating_breakdown(db, user.id)
    return {"name": user.name, "trades": list(wp.trades or []), "rating": b["overall"], "rating_count": b["count"],
            "completed_jobs": wp.completed_jobs, "badges": list(wp.badges or []), "breakdown": b,
            "verified_level": user.kyc_level, "police_verified": wp.police_status == "verified",
            "level": levels.level_view(wp)["code"], "eshram_registered": bool(wp.eshram_id), "city": wp.city,
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


@router.post("/police-verification")
def police_verification(user: User = Depends(W), db: Session = Depends(get_db)):
    """Optional: ask for police verification (Aadhaar-based check by a partner - admin reviews for now)."""
    out = trust.request_police(db, user)
    db.commit()
    return out


@router.post("/jobs/{job_id}/decline")
def decline_direct(job_id: uuid.UUID, user: User = Depends(W), db: Session = Depends(get_db)):
    """Decline a "hire again" request: the job opens to everyone straight away."""
    out = trust.decline_direct(db, user, _job(db, job_id))
    db.commit()
    return out


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
