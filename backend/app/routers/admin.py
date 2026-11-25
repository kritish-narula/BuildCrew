import csv
import io
import uuid

from fastapi import APIRouter, Depends
from fastapi.responses import Response
from pydantic import BaseModel, Field
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from ..audit import audit
from ..db import get_db
from ..domain import flows
from ..domain.state import transition
from ..enums import BidStatus, DisputeStatus, DocStatus, EscrowState, JobStatus, Role
from ..errors import AppError
from ..models import (
    Assignment, AuditLog, Bid, ChatMessage, Dispute, Job, Payment, Payout, Rating, User, WorkerProfile, WorkItem,
)
from ..security import require
from .views import assignment_view, job_card, payment_view, rating_breakdown, signed, work_item_view, worker_summary

router = APIRouter(prefix="/admin", tags=["admin"])
A = require(Role.admin)


@router.get("/kpis")
def kpis(user: User = Depends(A), db: Session = Depends(get_db)):
    from datetime import datetime, timezone
    today = datetime.now(timezone.utc).replace(hour=0, minute=0, second=0, microsecond=0)
    active = [JobStatus.open, JobStatus.bidding, JobStatus.assigned, JobStatus.in_progress]
    by_status = dict(db.execute(select(Job.status, func.count()).group_by(Job.status)).all())
    return {
        "active_jobs": db.scalar(select(func.count()).select_from(Job).where(Job.status.in_(active))),
        "workers_online": db.scalar(select(func.count()).select_from(WorkerProfile).where(WorkerProfile.is_online)),
        "workers_total": db.scalar(select(func.count()).select_from(WorkerProfile)),
        "bids_today": db.scalar(select(func.count()).select_from(Bid).where(Bid.created_at >= today)),
        "gmv_inr": (db.scalar(select(func.coalesce(func.sum(Payment.amount_paise), 0))
                              .where(Payment.escrow_state != EscrowState.created)) or 0) / 100,
        "in_escrow_inr": (db.scalar(select(func.coalesce(func.sum(Payment.amount_paise), 0))
                                    .where(Payment.escrow_state == EscrowState.held)) or 0) / 100,
        "platform_revenue_inr": (db.scalar(select(func.coalesce(func.sum(Payment.platform_fee_paise), 0))
                                           .where(Payment.escrow_state.in_([EscrowState.released, EscrowState.split]))) or 0) / 100,
        "open_disputes": db.scalar(select(func.count()).select_from(Dispute).where(Dispute.status != DisputeStatus.resolved)),
        "pending_bids": db.scalar(select(func.count()).select_from(Bid).where(Bid.status == BidStatus.pending)),
        "kyc_pending": db.scalar(select(func.count()).select_from(WorkerProfile).where(
            (WorkerProfile.aadhaar_status == DocStatus.pending) | (WorkerProfile.pan_status == DocStatus.pending))),
        "jobs_by_status": {k.value: v for k, v in by_status.items()},
    }


@router.get("/map")
def job_map(user: User = Depends(A), db: Session = Depends(get_db)):
    """A1 live map data: active jobs by locality + pins."""
    active = [JobStatus.open, JobStatus.bidding, JobStatus.assigned, JobStatus.in_progress, JobStatus.disputed]
    jobs = db.scalars(select(Job).where(Job.status.in_(active))).all()
    loc: dict[str, int] = {}
    for j in jobs:
        loc[j.locality] = loc.get(j.locality, 0) + 1
    return {"pins": [{"id": str(j.id), "lat": j.location_lat, "lng": j.location_lng, "status": j.status.value,
                      "locality": j.locality, "trades": [wi.trade.value for wi in j.work_items]} for j in jobs],
            "by_locality": sorted(({"locality": k, "count": v} for k, v in loc.items()), key=lambda x: -x["count"])}


# ------------------------------------------------------------------ A2 workers
@router.get("/workers")
def workers(trade: str | None = None, kyc: int | None = None, min_rating: float | None = None, city: str | None = None,
            q: str | None = None, suspended: bool | None = None, user: User = Depends(A), db: Session = Depends(get_db)):
    stmt = select(User).join(WorkerProfile, WorkerProfile.user_id == User.id).where(User.role == Role.worker)
    if trade:
        stmt = stmt.where(WorkerProfile.trades.any(trade))
    if kyc is not None:
        stmt = stmt.where(User.kyc_level == kyc)
    if min_rating is not None:
        stmt = stmt.where(WorkerProfile.overall_rating >= min_rating)
    if city:
        stmt = stmt.where(WorkerProfile.city == city)
    if suspended is not None:
        stmt = stmt.where(WorkerProfile.is_suspended.is_(suspended))
    if q:
        stmt = stmt.where(User.name.ilike(f"%{q}%") | User.phone.like(f"%{q}%"))
    out = []
    for w in db.scalars(stmt.order_by(User.created_at.desc())).all():
        wp = w.worker_profile
        out.append({**worker_summary(db, w), "phone": w.phone, "city": wp.city, "suspended": wp.is_suspended,
                    "strikes": wp.strikes, "online": wp.is_online, "aadhaar": wp.aadhaar_status.value,
                    "pan": wp.pan_status.value, "eshram": bool(wp.eshram_id),
                    "earned_inr": wp.lifetime_earnings_paise / 100})
    return out


@router.get("/kyc-queue")
def kyc_queue(user: User = Depends(A), db: Session = Depends(get_db)):
    rows = db.scalars(select(User).join(WorkerProfile, WorkerProfile.user_id == User.id).where(
        (WorkerProfile.aadhaar_status == DocStatus.pending) | (WorkerProfile.pan_status == DocStatus.pending))).all()
    return [{**worker_summary(db, w), "phone": w.phone, "doc_type": w.worker_profile.kyc_doc_type or "aadhaar",
             "doc_url": signed(w.worker_profile.kyc_doc_key) or signed(w.worker_profile.selfie_url),
             "earned_inr": w.worker_profile.lifetime_earnings_paise / 100} for w in rows]


class KycDecision(BaseModel):
    approve: bool
    note: str | None = Field(default=None, max_length=300)


@router.post("/workers/{worker_id}/kyc")
def kyc_decide(worker_id: uuid.UUID, body: KycDecision, user: User = Depends(A), db: Session = Depends(get_db)):
    w = db.get(User, worker_id)
    if not w or not w.worker_profile:
        raise AppError("err.not_found", 404)
    wp = w.worker_profile
    doc = wp.kyc_doc_type or ("aadhaar" if wp.aadhaar_status == DocStatus.pending else "pan")
    setattr(wp, f"{doc}_status", DocStatus.approved if body.approve else DocStatus.rejected)
    wp.kyc_note = None if body.approve else (body.note or "Document not clear")
    if body.approve:
        w.kyc_level = 2
    audit(db, actor_id=user.id, action="kyc.approved" if body.approve else "kyc.rejected", entity="user",
          entity_id=w.id, doc=doc, note=body.note)
    db.commit()
    return {"kyc_level": w.kyc_level}


class SuspendIn(BaseModel):
    suspend: bool
    reason: str = Field(default="", max_length=300)


@router.post("/workers/{worker_id}/suspend")
def suspend(worker_id: uuid.UUID, body: SuspendIn, user: User = Depends(A), db: Session = Depends(get_db)):
    w = db.get(User, worker_id)
    if not w or not w.worker_profile:
        raise AppError("err.not_found", 404)
    w.worker_profile.is_suspended = body.suspend
    if not body.suspend:
        w.worker_profile.strikes = 0
    audit(db, actor_id=user.id, action="worker.suspended" if body.suspend else "worker.reinstated", entity="user",
          entity_id=w.id, reason=body.reason)
    db.commit()
    return {"suspended": body.suspend}


# ------------------------------------------------------------------ A3 jobs
@router.get("/jobs")
def jobs(status: JobStatus | None = None, user: User = Depends(A), db: Session = Depends(get_db)):
    stmt = select(Job).order_by(Job.created_at.desc())
    if status:
        stmt = stmt.where(Job.status == status)
    rows = db.scalars(stmt.limit(300)).all()
    counts = dict(db.execute(select(Bid.job_id, func.count()).group_by(Bid.job_id)).all())
    return [{**job_card(db, j, "en"), "bid_count": counts.get(j.id, 0),
             "customer": db.get(User, j.customer_id).name} for j in rows]


@router.get("/jobs/{job_id}")
def job_detail(job_id: uuid.UUID, user: User = Depends(A), db: Session = Depends(get_db)):
    j = db.get(Job, job_id)
    if not j:
        raise AppError("err.not_found", 404)
    a = db.scalar(select(Assignment).where(Assignment.job_id == j.id))
    out = {**job_card(db, j, "en"), "customer": db.get(User, j.customer_id).name,
           "work_items": [work_item_view(db, wi, "en", include_audio=True, admin=True) for wi in j.work_items],
           "bids": [{"id": str(b.id), "price_inr": b.quoted_price_paise / 100, "status": b.status.value,
                     "created_at": b.created_at.isoformat(), "worker": worker_summary(db, b.worker)} for b in j.bids],
           "assignment": assignment_view(db, a, "en"),
           "audit": [{"action": r.action, "at": r.created_at.isoformat(), "meta": r.meta}
                     for r in db.scalars(select(AuditLog).where(AuditLog.entity_id == str(j.id)).order_by(AuditLog.created_at))]}
    db.commit()
    return out


@router.post("/jobs/{job_id}/cancel")
def cancel_job(job_id: uuid.UUID, user: User = Depends(A), db: Session = Depends(get_db)):
    """Intervene on a stuck job. Escrow (if any) is refunded in full."""
    j = db.get(Job, job_id)
    if not j:
        raise AppError("err.not_found", 404)
    a = db.scalar(select(Assignment).where(Assignment.job_id == j.id))
    if a:
        p = db.scalar(select(Payment).where(Payment.assignment_id == a.id))
        if p and p.escrow_state == EscrowState.held:
            flows.refund_or_split(db, a, user, 0)
    transition(db, j, kind="job", field="status", new=JobStatus.cancelled, actor_id=user.id, reason="admin_intervention")
    db.commit()
    return {"status": j.status.value}


# ------------------------------------------------------------------ A4 disputes
@router.get("/disputes")
def disputes(user: User = Depends(A), db: Session = Depends(get_db)):
    rows = db.scalars(select(Dispute).order_by(Dispute.status, Dispute.created_at.desc())).all()
    out = []
    for d in rows:
        a = db.get(Assignment, d.assignment_id)
        p = db.scalar(select(Payment).where(Payment.assignment_id == a.id))
        out.append({"id": str(d.id), "status": d.status.value, "reason": d.reason, "created_at": d.created_at.isoformat(),
                    "raised_by": db.get(User, d.raised_by).name, "job_id": str(a.job_id), "locality": a.job.locality,
                    "worker": a.worker.name, "customer": db.get(User, a.job.customer_id).name,
                    "amount_inr": p.amount_paise / 100 if p else 0, "resolution": d.resolution})
    return out


@router.get("/disputes/{dispute_id}")
def dispute_evidence(dispute_id: uuid.UUID, user: User = Depends(A), db: Session = Depends(get_db)):
    """Evidence viewer: photos, text, the customer's AUDIO + transcript side by side, chat,
    attendance and both parties' rating history."""
    d = db.get(Dispute, dispute_id)
    if not d:
        raise AppError("err.not_found", 404)
    a = db.get(Assignment, d.assignment_id)
    job = a.job
    customer = db.get(User, job.customer_id)
    chat = db.scalars(select(ChatMessage).where(ChatMessage.job_id == job.id).order_by(ChatMessage.created_at)).all()
    cust_ratings = db.scalars(select(Rating).where(Rating.ratee_id == customer.id).order_by(Rating.created_at.desc()).limit(10)).all()
    out = {"id": str(d.id), "status": d.status.value, "reason": d.reason, "resolution": d.resolution,
           "created_at": d.created_at.isoformat(), "raised_by": db.get(User, d.raised_by).name,
           "job": {**job_card(db, job, "en"),
                   "work_items": [work_item_view(db, wi, "en", include_audio=True, admin=True) for wi in job.work_items]},
           "customer": {"id": str(customer.id), "name": customer.name, "phone": customer.phone,
                        "rating": customer.customer_profile.overall_rating if customer.customer_profile else None,
                        "ratings": [{"overall": r.overall, "comment": r.comment} for r in cust_ratings]},
           "worker": {**worker_summary(db, a.worker), "phone": a.worker.phone, "strikes": a.worker.worker_profile.strikes,
                      "breakdown": rating_breakdown(db, a.worker_id)},
           "assignment": assignment_view(db, a, "en"),
           "chat": [{"from": "customer" if m.sender_id == customer.id else "worker", "body": m.body,
                     "at": m.created_at.isoformat()} for m in chat]}
    db.commit()
    return out


class ResolveIn(BaseModel):
    worker_share_pct: int = Field(ge=0, le=100)  # 100 = release, 0 = refund, else split
    penalise: bool = False
    note: str = Field(default="", max_length=500)


@router.post("/disputes/{dispute_id}/resolve")
def resolve(dispute_id: uuid.UUID, body: ResolveIn, user: User = Depends(A), db: Session = Depends(get_db)):
    d = db.get(Dispute, dispute_id)
    if not d:
        raise AppError("err.not_found", 404)
    flows.resolve_dispute(db, user, d, worker_share_pct=body.worker_share_pct, penalise=body.penalise, note=body.note)
    db.commit()
    return {"status": d.status.value, "resolution": d.resolution}


class AudioModeration(BaseModel):
    flagged: bool | None = None
    muted: bool | None = None


@router.post("/work-items/{item_id}/audio")
def moderate_audio(item_id: uuid.UUID, body: AudioModeration, user: User = Depends(A), db: Session = Depends(get_db)):
    """Flag / mute from the worker feed. The file is RETAINED (audit + evidence), never deleted."""
    wi = db.get(WorkItem, item_id)
    if not wi:
        raise AppError("err.not_found", 404)
    if body.flagged is not None:
        wi.audio_flagged = body.flagged
    if body.muted is not None:
        wi.audio_muted = body.muted
    audit(db, actor_id=user.id, action="audio.moderated", entity="work_item", entity_id=wi.id,
          flagged=wi.audio_flagged, muted=wi.audio_muted, key=wi.audio_url)
    db.commit()
    return {"flagged": wi.audio_flagged, "muted": wi.audio_muted}


# ------------------------------------------------------------------ A5 payments
@router.get("/payments")
def ledger(user: User = Depends(A), db: Session = Depends(get_db)):
    rows = db.execute(select(Payment, Assignment).join(Assignment, Assignment.id == Payment.assignment_id)
                      .order_by(Payment.released_at.desc().nullsfirst())).all()
    return [{**payment_view(p), "job_id": str(a.job_id), "locality": a.job.locality, "worker": a.worker.name,
             "customer": db.get(User, a.job.customer_id).name, "job_status": a.job.status.value} for p, a in rows]


@router.get("/payouts")
def payouts(user: User = Depends(A), db: Session = Depends(get_db)):
    rows = db.scalars(select(Payout).order_by(Payout.created_at.desc())).all()
    pending = []
    for w in db.scalars(select(User).where(User.role == Role.worker)):
        bal = flows.worker_balance(db, w.id)["available_paise"]
        if bal > 0:
            pending.append({"worker": w.name, "worker_id": str(w.id), "available_inr": bal / 100, "kyc_level": w.kyc_level})
    return {"queue": pending, "history": [{"id": str(p.id), "worker": db.get(User, p.worker_id).name,
                                           "amount_inr": p.amount_paise / 100, "upi": p.upi_masked, "status": p.status,
                                           "at": p.created_at.isoformat(), "ref": p.provider_ref} for p in rows]}


# ------------------------------------------------------------------ A6 compliance
def _compliance_rows(db: Session) -> list[dict]:
    out = []
    for w in db.scalars(select(User).where(User.role == Role.worker).order_by(User.name)):
        wp = w.worker_profile
        out.append({"card_id": f"BC-{w.id.hex[:8].upper()}", "name": w.name or "", "trades": ",".join(wp.trades or []),
                    "city": wp.city or "", "kyc_level": w.kyc_level, "eshram_registered": bool(wp.eshram_id),
                    "aadhaar": wp.aadhaar_status.value, "pan": wp.pan_status.value,
                    "earned_inr": wp.lifetime_earnings_paise / 100, "jobs": wp.completed_jobs})
    return out


@router.get("/compliance")
def compliance(user: User = Depends(A), db: Session = Depends(get_db)):
    rows = _compliance_rows(db)
    return {"rows": rows, "eshram_registered": sum(r["eshram_registered"] for r in rows), "total": len(rows)}


@router.get("/compliance.csv")
def compliance_csv(user: User = Depends(A), db: Session = Depends(get_db)):
    rows = _compliance_rows(db)
    buf = io.StringIO()
    w = csv.DictWriter(buf, fieldnames=list(rows[0].keys()) if rows else ["card_id"])
    w.writeheader()
    w.writerows(rows)
    audit(db, actor_id=user.id, action="compliance.exported", entity="report", entity_id="eshram", rows=len(rows))
    db.commit()
    return Response(buf.getvalue(), media_type="text/csv",
                    headers={"Content-Disposition": "attachment; filename=buildcrew-compliance.csv"})
