"""Shared serializers. Media keys are turned into short-lived signed URLs only here, and only
after the caller's access has been checked by the router."""
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from .. import services
from ..config import get_settings
from ..crypto import mask_phone
from ..enums import RatingDirection
from ..i18n import t
from ..models import Assignment, Attendance, Bid, Job, Payment, Rating, User, WorkerProfile, WorkItem


def signed(key: str | None) -> str | None:
    if not key:
        return None
    if key.startswith("http"):  # seed placeholder photos
        return key
    return services.storage().signed_url(key, get_settings().signed_url_ttl_seconds)


def localized_item(db: Session, wi: WorkItem, lang: str) -> dict:
    """Text + transcript in the viewer's language. Translations are cached on the row so each
    (item, language) pair is machine-translated once."""
    src = wi.description_language
    text, transcript, translated = wi.text_description, wi.transcript, False
    if lang != src:
        cache = dict(wi.translations or {})
        hit = cache.get(lang)
        if not hit:
            tr = services.translation()
            hit = {"text": tr.translate(text, src, lang) if text else None,
                   "transcript": tr.translate(transcript, src, lang) if transcript else None}
            cache[lang] = hit
            wi.translations = cache  # reassign so SQLAlchemy sees the JSONB change
        text, transcript, translated = hit["text"], hit["transcript"], True
    return {"text": text, "transcript": transcript, "translated": translated, "original_language": src}


def work_item_view(db: Session, wi: WorkItem, lang: str, *, include_audio: bool, admin: bool = False) -> dict:
    loc = localized_item(db, wi, lang)
    audio_visible = wi.audio_url and (admin or not wi.audio_muted) and include_audio
    return {
        "id": str(wi.id), "index": wi.sort_order + 1, "trade": wi.trade.value,
        "trade_label": t(f"trade.{wi.trade.value}", lang),
        "photos": [signed(p.photo_url) for p in wi.photos], **loc,
        "audio": {"url": signed(wi.audio_url), "duration_sec": wi.audio_duration_sec,
                  "size_kb": round((wi.audio_size_bytes or 0) / 1024), "flagged": wi.audio_flagged,
                  "muted": wi.audio_muted} if audio_visible else None,
    }


def worker_summary(db: Session, user: User) -> dict:
    wp: WorkerProfile = user.worker_profile
    return {"id": str(user.id), "name": user.name or mask_phone(user.phone), "trades": list(wp.trades or []),
            "rating": round(wp.overall_rating, 1), "rating_count": wp.rating_count,
            "completed_jobs": wp.completed_jobs, "badges": list(wp.badges or []), "kyc_level": user.kyc_level,
            "selfie": signed(wp.selfie_url), "verified": user.kyc_level >= 1}


def rating_breakdown(db: Session, worker_id) -> dict:
    row = db.execute(select(func.avg(Rating.quality), func.avg(Rating.timeliness), func.avg(Rating.behaviour),
                            func.avg(Rating.value_for_money), func.avg(Rating.overall), func.count())
                     .where(Rating.ratee_id == worker_id, Rating.direction == RatingDirection.customer_to_worker)).one()
    wp = db.get(WorkerProfile, worker_id)
    fallback = round(wp.overall_rating, 1) if wp else 0
    r = lambda v: round(float(v), 1) if v is not None else fallback  # noqa: E731
    return {"quality": r(row[0]), "timeliness": r(row[1]), "behaviour": r(row[2]), "value_for_money": r(row[3]),
            "overall": round(wp.overall_rating, 1) if wp else r(row[4]), "count": wp.rating_count if wp else row[5]}


def worker_history(db: Session, worker_id, limit: int = 10) -> list[dict]:
    rows = db.execute(select(Assignment, Rating).join(Rating, (Rating.assignment_id == Assignment.id) &
                                                      (Rating.direction == RatingDirection.customer_to_worker))
                      .where(Assignment.worker_id == worker_id).order_by(Rating.created_at.desc()).limit(limit)).all()
    out = []
    for a, r in rows:
        job = a.job
        photo = next((signed(p.photo_url) for wi in job.work_items for p in wi.photos), None)
        out.append({"job_id": str(job.id), "locality": job.locality, "trades": sorted({wi.trade.value for wi in job.work_items}),
                    "photo": photo, "rating": r.overall, "comment": r.comment, "date": r.created_at.date().isoformat()})
    return out


def payment_view(p: Payment | None) -> dict | None:
    if not p:
        return None
    return {"id": str(p.id), "amount_inr": p.amount_paise / 100, "platform_fee_inr": p.platform_fee_paise / 100,
            "worker_payout_inr": p.worker_payout_paise / 100, "refund_inr": p.refund_paise / 100,
            "escrow_state": p.escrow_state.value, "released_at": p.released_at.isoformat() if p.released_at else None,
            "ref": p.razorpay_ref, "method": p.method, "paid_at": p.paid_at.isoformat() if p.paid_at else None}


def assignment_view(db: Session, a: Assignment | None, lang: str) -> dict | None:
    if not a:
        return None
    p = db.scalar(select(Payment).where(Payment.assignment_id == a.id))
    ratings = {r.direction.value: {"overall": r.overall, "quality": r.quality, "timeliness": r.timeliness,
                                   "behaviour": r.behaviour, "value_for_money": r.value_for_money,
                                   "clarity": r.clarity, "timely_payment": r.timely_payment, "comment": r.comment}
               for r in db.scalars(select(Rating).where(Rating.assignment_id == a.id))}
    att = db.scalars(select(Attendance).where(Attendance.assignment_id == a.id).order_by(Attendance.checkin_at)).all()
    bid = db.get(Bid, a.accepted_bid_id)
    from ..domain.flows import tracking
    team_part = {}
    if a.work_item_id:  # team member: price = wage x planned days; attendance gives days worked
        from ..domain import team
        wi = db.get(WorkItem, a.work_item_id)
        team_part = {"team_member": True, "trade": wi.trade.value, "daily_wage_inr": bid.quoted_price_paise / 100,
                     "days_planned": a.days_planned, "days_worked": team.days_worked(db, a)}
    return {**team_part, "id": str(a.id), "worker": worker_summary(db, a.worker),
            "price_inr": bid.quoted_price_paise * (a.days_planned if a.work_item_id else 1) / 100,
            "tracking": tracking(a), "worker_done_at": a.worker_done_at.isoformat() if a.worker_done_at else None,
            "started_at": a.started_at.isoformat() if a.started_at else None,
            "completed_at": a.completed_at.isoformat() if a.completed_at else None,
            "payment": payment_view(p), "ratings": ratings,
            "attendance": [{"in": x.checkin_at.isoformat(), "out": x.checkout_at.isoformat() if x.checkout_at else None,
                            "offline": x.offline_synced, "geofence_ok": x.geofence_ok,
                            "selfie": signed(x.checkin_selfie_url)} for x in att]}


def job_card(db: Session, job: Job, lang: str) -> dict:
    from ..domain import team
    return {"kind": job.kind, "scheduled_for": job.scheduled_for.isoformat() if job.scheduled_for else None,
            "time_slot": job.time_slot, "team": team.summary(db, job),
            "id": str(job.id), "customer_id": str(job.customer_id), "status": job.status.value, "locality": job.locality, "city": job.city,
            "address": job.address_text, "lat": job.location_lat, "lng": job.location_lng,
            "start_date": job.start_date.isoformat(), "created_at": job.created_at.isoformat(),
            "trades": [wi.trade.value for wi in job.work_items],
            "thumbnail": next((signed(p.photo_url) for wi in job.work_items for p in wi.photos), None)}
