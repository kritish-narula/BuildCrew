"""Notifications: one row per important event, rendered in the READER's language; push is sent after the commit."""
import logging
import uuid
from datetime import datetime, timezone

from sqlalchemy import event, select, update
from sqlalchemy.orm import Session

from .. import services
from ..config import get_settings
from ..i18n import t
from ..models import Notification, PushToken, User

log = logging.getLogger("app.notify")
KINDS = ("new_job", "new_quote", "quote_accepted", "payment_held", "worker_on_way", "worker_arrived", "work_finished",
         "work_confirmed", "sent_back", "dispute_opened", "dispute_resolved", "payment_released", "payout_paid",
         "chat_message", "direct_request", "refix_requested", "payment_failed", "refund_done")


def notify(db: Session, user_id, kind: str, *, job_id=None, assignment_id=None, other_user_id=None, **params) -> Notification | None:
    if not user_id:
        return None
    assert kind in KINDS, kind
    params = {k: (str(v) if isinstance(v, uuid.UUID) else v) for k, v in params.items()}
    n = Notification(user_id=user_id, kind=kind, params=params, job_id=job_id, assignment_id=assignment_id,
                     other_user_id=other_user_id)
    db.add(n)
    db.info.setdefault("push", []).append(n)
    return n


def _p(params: dict, lang: str | None = None) -> dict:
    p = {**params, "phone": get_settings().support_phone}
    if "trades" in p:  # stored as codes, shown in the reader's language
        p["trades"] = ", ".join(t(f"trade.{c}", lang) for c in str(p["trades"]).split(",") if c)
    return p


def notify_nearby_workers(db: Session, job, limit: int = 60) -> int:
    """New job -> workers who can do one of its trades and are inside the feed radius (or have no home set yet)."""
    from ..models import WorkerProfile
    if job.direct_worker_id:  # exclusive offer: only that worker hears (direct_request)
        return 0
    trades = {wi.trade.value for wi in job.work_items}
    n = 0
    for wp in db.scalars(select(WorkerProfile).where(WorkerProfile.is_suspended.is_(False))):
        if wp.trades and not trades & set(wp.trades):
            continue
        if wp.home_lat is not None:
            d = services.maps().distance_km((wp.home_lat, wp.home_lng), (job.location_lat, job.location_lng))
            if d is not None and d > get_settings().worker_feed_radius_km:
                continue
        elif wp.city and wp.city != job.city:
            continue
        notify(db, wp.user_id, "new_job", job_id=job.id, other_user_id=job.customer_id, locality=job.locality,
               trades=",".join(sorted(trades)))
        n += 1
        if n >= limit:
            break
    return n


def render(n: Notification, lang: str | None) -> dict:
    p = _p(n.params or {}, lang)
    return {"id": str(n.id), "kind": n.kind, "title": t(f"notif.{n.kind}.title", lang, **p),
            "body": t(f"notif.{n.kind}.body", lang, **p), "job_id": str(n.job_id) if n.job_id else None,
            "assignment_id": str(n.assignment_id) if n.assignment_id else None,
            "with_user": str(n.other_user_id) if n.other_user_id else None,
            "read": n.read_at is not None, "at": n.created_at.isoformat() if n.created_at else None}


def deep_link(n: Notification) -> str:
    """Route the app opens when a notification is tapped (go_router)."""
    if n.kind == "chat_message" and n.job_id and n.other_user_id:
        return f"/chat/{n.job_id}/{n.other_user_id}"
    if n.assignment_id and n.kind not in ("new_job", "direct_request"):
        return f"/assignment/{n.assignment_id}" + (f"?job={n.job_id}" if n.job_id else "")  # customers open by job id
    if n.job_id:
        return f"/job/{n.job_id}"
    return "/notifications"


def mark_read(db: Session, user_id, ids: list[uuid.UUID] | None) -> int:
    q = update(Notification).where(Notification.user_id == user_id, Notification.read_at.is_(None))
    if ids:
        q = q.where(Notification.id.in_(ids))
    r = db.execute(q.values(read_at=datetime.now(timezone.utc)))
    return r.rowcount or 0


def _deliver(pending: list[Notification]) -> None:
    """Runs after the commit, on its OWN session (the committed one cannot emit SQL). Never raises."""
    from ..db import SessionLocal
    try:
        with SessionLocal() as db:
            for n in pending:
                user = db.get(User, n.user_id)
                tokens = list(db.scalars(select(PushToken.token).where(PushToken.user_id == n.user_id)))
                if not user or not tokens:
                    continue
                r = render(n, user.language_code)
                data = {"kind": n.kind, "link": deep_link(n), "id": r["id"]}
                dead = services.push().send(tokens, r["title"], r["body"], data)
                if dead:
                    db.execute(PushToken.__table__.delete().where(PushToken.token.in_(dead)))
                    db.commit()
    except Exception:
        log.exception("push delivery failed")


@event.listens_for(Session, "after_commit")
def _after_commit(session: Session) -> None:
    pending = session.info.pop("push", None)
    if pending:
        _deliver(pending)


@event.listens_for(Session, "after_rollback")
def _after_rollback(session: Session) -> None:
    session.info.pop("push", None)
