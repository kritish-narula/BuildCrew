"""Meta, media, role-scoped read endpoints (Phase 1 proves role routing against seed data;
Phases 2–5 add the write flows), and dev-only helpers."""
import hashlib
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, Query, Request
from fastapi.responses import Response
from pydantic import BaseModel, Field
from sqlalchemy import func, select
from sqlalchemy.orm import Session, selectinload

from .. import services
from ..config import get_settings
from ..db import get_db
from ..enums import LANGUAGE_CODES, LANGUAGES, BidStatus, DisputeStatus, EscrowState, JobStatus, Role, Trade
from ..errors import AppError
from ..i18n import t
from ..models import Bid, Dispute, Job, Payment, User, WorkerProfile, WorkItem
from ..security import client_ip, rate_limit, require
from ..services.storage import LocalStorage

meta = APIRouter(prefix="/meta", tags=["meta"])


@meta.get("/languages")
def languages():
    return LANGUAGES


@meta.get("/trades")
def trades(lang: str = "hi"):
    return [{"code": tr.value, "label": t(f"trade.{tr.value}", lang)} for tr in Trade]


@meta.get("/config")
def public_config():
    s = get_settings()
    return {"platform_fee_flat_inr": s.platform_fee_flat_inr, "platform_take_rate_pct": s.platform_take_rate_pct,
            "audio_max_seconds": s.audio_max_seconds, "audio_soft_prompt_seconds": s.audio_soft_prompt_seconds,
            "audio_target_kbps": s.audio_target_kbps, "kyc_l2_earnings_cap_inr": s.kyc_l2_earnings_cap_inr}


class TtsIn(BaseModel):
    text: str = Field(max_length=500)
    lang: str


@meta.post("/tts")
def tts(body: TtsIn, request: Request):
    """Read-aloud for the speaker buttons (S1 language names, job details, payouts…).
    Cached by content hash so the same sentence is synthesised once."""
    if body.lang not in LANGUAGE_CODES:
        raise AppError("err.language_unsupported", 422)
    rate_limit(f"tts:{client_ip(request)}", 60, 60)
    store = services.storage()
    key = f"tts/{body.lang}/{hashlib.sha256(body.text.encode()).hexdigest()[:32]}.ogg"
    try:
        store.get(key)
    except Exception:
        audio = services.speech().synthesize(body.text, body.lang)
        if isinstance(store, LocalStorage):
            store.put_at(key, audio)
        else:  # S3: write at deterministic key
            store.s3.put_object(Bucket=store.bucket, Key=key, Body=audio, ContentType="audio/ogg")
    return {"url": store.signed_url(key, get_settings().signed_url_ttl_seconds)}


# ------------------------------------------------------------------ media (dev local storage)
media = APIRouter(tags=["media"])
_CT = {"ogg": "audio/ogg", "opus": "audio/ogg", "m4a": "audio/mp4", "jpg": "image/jpeg", "png": "image/png"}


@media.get("/media/{key:path}")
def get_media(key: str, exp: int = Query(...), sig: str = Query(...)):
    store = services.storage()
    if not isinstance(store, LocalStorage):
        raise AppError("err.not_found", 404)
    verdict = store.verify(key, exp, sig)
    if verdict == "expired":
        raise AppError("err.media_link_expired", 410)
    if verdict != "ok":
        raise AppError("err.media_forbidden", 403)
    try:
        data = store.get(key)
    except (FileNotFoundError, ValueError):
        raise AppError("err.not_found", 404)
    return Response(data, media_type=_CT.get(key.rsplit(".", 1)[-1], "application/octet-stream"),
                    headers={"Cache-Control": "private, max-age=300", "X-Robots-Tag": "noindex"})


# ------------------------------------------------------------------ worker
worker = APIRouter(prefix="/worker", tags=["worker"])


def _signed(key: str | None) -> str | None:
    if not key:
        return None
    if key.startswith("http"):  # seed placeholder photos
        return key
    return services.storage().signed_url(key, get_settings().signed_url_ttl_seconds)


@worker.get("/feed")
def worker_feed(user: User = Depends(require(Role.worker)), db: Session = Depends(get_db)):
    """S4 Jobs feed. Deliberately returns NO audio URL — the feed only shows the 🔊 badge with
    duration and estimated size; audio is fetched on the detail screen when the worker taps play.
    That keeps the feed tiny on 2G/3G and guarantees audio never auto-plays."""
    wp: WorkerProfile = user.worker_profile
    origin = (wp.home_lat, wp.home_lng) if wp and wp.home_lat else None
    jobs = db.scalars(select(Job).where(Job.status.in_([JobStatus.open, JobStatus.bidding]))
                      .options(selectinload(Job.work_items).selectinload(WorkItem.photos))
                      .order_by(Job.created_at.desc())).all()
    my_bids = set(db.scalars(select(Bid.job_id).where(Bid.worker_id == user.id)))
    radius = get_settings().worker_feed_radius_km
    out = []
    for job in jobs:
        trades = [wi.trade.value for wi in job.work_items]
        if wp and wp.trades and not set(trades) & set(wp.trades):
            continue
        dist = services.maps().distance_km(origin, (job.location_lat, job.location_lng)) if origin else None
        if dist is not None and dist > radius:
            continue
        audio_items = [wi for wi in job.work_items if wi.audio_url and not wi.audio_muted]
        out.append({
            "id": str(job.id), "locality": job.locality,
            "trades": [{"code": tr, "label": t(f"trade.{tr}", user.language_code)} for tr in dict.fromkeys(trades)],
            "thumbnails": [_signed(p.photo_url) for wi in job.work_items for p in wi.photos][:4],
            "audio": {"count": len(audio_items),
                      "total_seconds": sum(wi.audio_duration_sec or 0 for wi in audio_items),
                      "total_kb": round(sum(wi.audio_size_bytes or 0 for wi in audio_items) / 1024)} if audio_items else None,
            "work_count": len(job.work_items),
            "distance_km": round(dist, 1) if dist is not None else None,
            "posted_at": job.created_at.isoformat(), "start_date": job.start_date.isoformat(),
            "already_bid": job.id in my_bids,
        })
    return out


# ------------------------------------------------------------------ customer
customer = APIRouter(prefix="/customer", tags=["customer"])


@customer.get("/jobs")
def customer_jobs(user: User = Depends(require(Role.customer)), db: Session = Depends(get_db)):
    jobs = db.scalars(select(Job).where(Job.customer_id == user.id).options(selectinload(Job.work_items))
                      .order_by(Job.created_at.desc())).all()
    counts = dict(db.execute(select(Bid.job_id, func.count()).where(Bid.job_id.in_([j.id for j in jobs]))
                             .group_by(Bid.job_id)).all()) if jobs else {}
    return [{"id": str(j.id), "status": j.status.value, "locality": j.locality, "bid_count": counts.get(j.id, 0),
             "trades": [wi.trade.value for wi in j.work_items], "start_date": j.start_date.isoformat()} for j in jobs]


# ------------------------------------------------------------------ admin
admin = APIRouter(prefix="/admin", tags=["admin"])


@admin.get("/kpis")
def kpis(user: User = Depends(require(Role.admin)), db: Session = Depends(get_db)):
    today = datetime.now(timezone.utc).replace(hour=0, minute=0, second=0, microsecond=0)
    active = [JobStatus.open, JobStatus.bidding, JobStatus.assigned, JobStatus.in_progress]
    released = [EscrowState.released, EscrowState.split]
    return {
        "active_jobs": db.scalar(select(func.count()).select_from(Job).where(Job.status.in_(active))),
        "workers_online": db.scalar(select(func.count()).select_from(WorkerProfile).where(WorkerProfile.is_online)),
        "bids_today": db.scalar(select(func.count()).select_from(Bid).where(Bid.created_at >= today)),
        "gmv_inr": (db.scalar(select(func.coalesce(func.sum(Payment.amount_paise), 0))
                              .where(Payment.escrow_state != EscrowState.created)) or 0) / 100,
        "platform_revenue_inr": (db.scalar(select(func.coalesce(func.sum(Payment.platform_fee_paise), 0))
                                           .where(Payment.escrow_state.in_(released))) or 0) / 100,
        "open_disputes": db.scalar(select(func.count()).select_from(Dispute).where(Dispute.status != DisputeStatus.resolved)),
        "pending_bids": db.scalar(select(func.count()).select_from(Bid).where(Bid.status == BidStatus.pending)),
    }


# ------------------------------------------------------------------ dev only
dev = APIRouter(prefix="/dev", tags=["dev"])


@dev.get("/sms-outbox")
def sms_outbox():
    if not get_settings().is_dev:
        raise AppError("err.not_found", 404)
    return list(getattr(services.sms(), "outbox", []))
