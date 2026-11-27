"""Meta, media, role-scoped read endpoints (Phase 1 proves role routing against seed data;
Phases 2–5 add the write flows), and dev-only helpers."""
import hashlib
import uuid
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, File, Form, Query, Request, UploadFile
from fastapi.responses import Response
from pydantic import BaseModel, Field
from sqlalchemy import func, or_, select
from sqlalchemy.orm import Session

from .. import services
from ..config import get_settings
from ..crypto import mask_phone
from ..db import get_db
from ..enums import LANGUAGE_CODES, LANGUAGES, EscrowState, Role, SupportChannel, Trade
from ..errors import AppError
from ..i18n import t
from ..models import SupportTicket, User
from ..security import client_ip, current_user, rate_limit, require
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
            "audio_target_kbps": s.audio_target_kbps, "kyc_l2_earnings_cap_inr": s.kyc_l2_earnings_cap_inr,
            "support_phone": s.support_phone}


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


# ------------------------------------------------------------------ uploads / speech / support
files = APIRouter(tags=["files"])
LIMITS = {  # kind → (max bytes, allowed extensions)
    "photo": (6 * 1024 * 1024, {"jpg", "jpeg", "png", "webp"}),
    "selfie": (4 * 1024 * 1024, {"jpg", "jpeg", "png", "webp"}),
    "kyc": (6 * 1024 * 1024, {"jpg", "jpeg", "png", "webp", "pdf"}),
    # Voice notes: AAC/Opus @ ~24 kbps → 2 min ≈ 360 KB. 1.5 MB cap rejects un-compressed audio.
    "audio": (1_500_000, {"m4a", "aac", "ogg", "opus", "webm", "mp3"}),
}


@files.post("/media/upload")
async def upload(kind: str = Form(...), file: UploadFile = File(...), user: User = Depends(current_user)):
    if kind not in LIMITS:
        raise AppError("err.file_type", 422)
    max_bytes, exts = LIMITS[kind]
    ext = (file.filename or "").rsplit(".", 1)[-1].lower()
    if ext not in exts:
        raise AppError("err.file_type", 422)
    data = await file.read(max_bytes + 1)
    if len(data) > max_bytes:
        raise AppError("err.file_too_large", 413)
    key = services.storage().put(data, prefix=f"{kind}/{user.id.hex[:8]}", ext=ext,
                                 content_type=file.content_type or "application/octet-stream")
    return {"key": key, "url": services.storage().signed_url(key, get_settings().signed_url_ttl_seconds), "size": len(data)}


class TranscribeIn(BaseModel):
    key: str
    lang: str


@files.post("/media/transcribe")
def transcribe(body: TranscribeIn, user: User = Depends(require(Role.customer, Role.worker))):
    """Auto-transcript for review/edit before posting (C2). Only the uploader's own keys."""
    if f"/{user.id.hex[:8]}/" not in f"/{body.key}":
        raise AppError("err.media_forbidden", 403)
    if body.lang not in LANGUAGE_CODES:
        raise AppError("err.language_unsupported", 422)
    return {"transcript": services.speech().transcribe(services.storage().get(body.key), body.lang)}


class VoiceQueryIn(BaseModel):
    text: str = Field(max_length=300)


@files.post("/voice/query")
def voice_query(body: VoiceQueryIn, user: User = Depends(current_user), db: Session = Depends(get_db)):
    """Stub intent matcher for 'mera paisa kab aayega?', 'kaam kaise milega?' etc. Answers in
    the user's language; the app reads the answer aloud."""
    q = body.text.lower()
    lang = user.language_code
    if any(w in q for w in ("paisa", "payment", "पैसा", "पैसे", "money", "kab")):
        key = "voice.when_payment"
    elif any(w in q for w in ("kaam", "काम", "work", "job")):
        key = "voice.how_get_work"
    elif any(w in q for w in ("balance", "बैलेंस", "kitna")) and user.role == Role.worker:
        from ..domain.flows import worker_balance
        return {"answer": t("voice.balance", lang, amount=worker_balance(db, user.id)["available_paise"] // 100)}
    else:
        key = "voice.not_understood"
    return {"answer": t(key, lang)}


class TicketIn(BaseModel):
    channel: SupportChannel = SupportChannel.app
    subject: str = Field(min_length=2, max_length=200)
    transcript: str | None = Field(default=None, max_length=4000)


@files.post("/support/tickets")
def support_ticket(body: TicketIn, user: User = Depends(current_user), db: Session = Depends(get_db)):
    tk = SupportTicket(user_id=user.id, channel=body.channel, subject=body.subject, transcript=body.transcript)
    db.add(tk)
    db.commit()
    return {"id": str(tk.id), "reply": t("support.auto_reply", user.language_code)}


class ChatIn(BaseModel):
    to: uuid.UUID
    body: str = Field(min_length=1, max_length=1000)


def _chat_peers(db: Session, user: User, job_id: uuid.UUID, other: uuid.UUID):
    """Chat is only between a job's customer and a worker who quoted on it (or admin reading)."""
    from ..models import Bid, Job
    job = db.get(Job, job_id)
    if not job:
        raise AppError("err.not_found", 404)
    worker_id = other if user.id == job.customer_id else user.id
    customer_id = job.customer_id
    if user.id not in (customer_id, worker_id) or not db.scalar(
            select(Bid.id).where(Bid.job_id == job.id, Bid.worker_id == worker_id)):
        raise AppError("err.forbidden", 403)
    return job, customer_id, worker_id


@files.get("/jobs/{job_id}/chat")
def chat_list(job_id: uuid.UUID, with_user: uuid.UUID = Query(alias="with"), user: User = Depends(current_user),
              db: Session = Depends(get_db)):
    """Both directions of one customer<->worker thread, oldest first. Opening it marks the
    messages addressed to the caller as read."""
    from ..models import ChatMessage
    job, c, w = _chat_peers(db, user, job_id, with_user)
    rows = db.scalars(select(ChatMessage).where(ChatMessage.job_id == job.id,
                                                ChatMessage.sender_id.in_([c, w]), ChatMessage.recipient_id.in_([c, w]))
                      .order_by(ChatMessage.created_at, ChatMessage.id)).all()
    unread = [m for m in rows if m.recipient_id == user.id and m.read_at is None]
    for m in unread:
        m.read_at = func.now()
    if unread:
        db.commit()
    return [{"mine": m.sender_id == user.id, "body": m.body, "at": m.created_at.isoformat()} for m in rows]


@files.post("/jobs/{job_id}/chat")
def chat_send(job_id: uuid.UUID, body: ChatIn, user: User = Depends(current_user), db: Session = Depends(get_db)):
    from ..models import ChatMessage
    job, c, w = _chat_peers(db, user, job_id, body.to)
    from ..domain.flows import active_assignment
    from ..enums import JobStatus
    hired = active_assignment(db, job.id)
    if (hired and hired.worker_id != w) or job.status == JobStatus.cancelled:
        raise AppError("err.chat_closed", 409)  # not hired (or job cancelled): the old thread stays readable, read-only
    m = ChatMessage(job_id=job.id, sender_id=user.id, recipient_id=w if user.id == c else c, body=body.body.strip())
    db.add(m)
    from ..domain.notify import notify
    notify(db, m.recipient_id, "chat_message", job_id=job.id, other_user_id=user.id, name=user.name or mask_phone(user.phone),
           text=m.body[:120])
    db.commit()
    services.realtime().publish(f"chat:{job.id}", "message", {"id": str(m.id)})
    return {"ok": True}


@files.get("/chats")
def chat_threads(user: User = Depends(current_user), db: Session = Depends(get_db)):
    """Inbox: one row per (job, other person), newest first, with unread count."""
    from ..models import ChatMessage, Job
    rows = db.scalars(select(ChatMessage).where(or_(ChatMessage.sender_id == user.id, ChatMessage.recipient_id == user.id))
                      .order_by(ChatMessage.created_at.desc(), ChatMessage.id)).all()
    threads: dict[tuple, dict] = {}
    for m in rows:  # newest first → the first row seen for a thread is its last message
        other = m.recipient_id if m.sender_id == user.id else m.sender_id
        th = threads.setdefault((m.job_id, other), {"last": m, "unread": 0})
        if m.recipient_id == user.id and m.read_at is None:
            th["unread"] += 1
    out = []
    for (job_id, other), th in threads.items():
        job, ou = db.get(Job, job_id), db.get(User, other)
        if not job or not ou:
            continue
        out.append({"job_id": str(job_id), "with_user": str(other), "with_name": ou.name or mask_phone(ou.phone),
                    "trades": sorted({wi.trade.value for wi in job.work_items}), "locality": job.locality,
                    "last_body": th["last"].body, "last_at": th["last"].created_at.isoformat(), "unread": th["unread"]})
    out.sort(key=lambda x: x["last_at"], reverse=True)
    return out


@files.post("/payments/webhook")
async def razorpay_webhook(request: Request, db: Session = Depends(get_db)):
    """Razorpay -> us (configure the URL `<public_base_url>/payments/webhook` in the Razorpay dashboard with events
    payment.captured, payment.failed, refund.processed). Signature (X-Razorpay-Signature, HMAC-SHA256 of the RAW body with the
    webhook secret) is verified BEFORE parsing. Delivery is at-least-once: `X-Razorpay-Event-Id` (or a body hash) is stored,
    so a replay is acknowledged and ignored; the state machine is idempotent as a second line of defence."""
    raw = await request.body()
    if not services.payment().verify_webhook(raw, request.headers.get("x-razorpay-signature", "")):
        raise AppError("err.forbidden", 403)
    import json
    from sqlalchemy.exc import IntegrityError
    from ..audit import audit
    from ..domain.flows import mark_held
    from ..domain.notify import notify
    from ..models import Assignment, Payment, WebhookEvent
    event = json.loads(raw)
    name = event.get("event", "")
    eid = request.headers.get("x-razorpay-event-id") or hashlib.sha256(raw).hexdigest()
    try:
        db.add(WebhookEvent(id=eid[:80], event=name[:40]))
        db.flush()
    except IntegrityError:
        db.rollback()
        return {"ok": True, "duplicate": True}
    pay = ((event.get("payload") or {}).get("payment") or {}).get("entity") or {}
    ref = ((event.get("payload") or {}).get("refund") or {}).get("entity") or {}
    if name == "payment.captured":
        p = db.scalar(select(Payment).where(Payment.razorpay_ref == pay.get("order_id")))
        if p:
            p.razorpay_payment_id = p.razorpay_payment_id or pay.get("id")
            if p.escrow_state == EscrowState.created:
                p.method = p.method or pay.get("method")
                mark_held(db, p, db.get(Assignment, p.assignment_id), actor_id=None)
                p.paid_at = p.paid_at or datetime.now(timezone.utc)
    elif name == "payment.failed":
        p = db.scalar(select(Payment).where(Payment.razorpay_ref == pay.get("order_id")))
        if p and p.escrow_state == EscrowState.created:
            a = db.get(Assignment, p.assignment_id)
            audit(db, actor_id=None, action="payment.failed", entity="payment", entity_id=p.id, reason=pay.get("error_code"))
            notify(db, a.job.customer_id, "payment_failed", job_id=a.job_id, assignment_id=a.id, amount=round(p.amount_paise / 100))
    elif name == "refund.processed":
        p = db.scalar(select(Payment).where(Payment.razorpay_payment_id == ref.get("payment_id")))
        if p:
            p.refund_ref = p.refund_ref or ref.get("id")
            audit(db, actor_id=None, action="payment.refund_processed", entity="payment", entity_id=p.id, amount=ref.get("amount"))
    db.commit()
    return {"ok": True}


# ------------------------------------------------------------------ dev only
dev = APIRouter(prefix="/dev", tags=["dev"])


@dev.get("/sms-outbox")
def sms_outbox():
    if not get_settings().is_dev:
        raise AppError("err.not_found", 404)
    return list(getattr(services.sms(), "outbox", []))
