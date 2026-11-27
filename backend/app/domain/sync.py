"""Change feed behind GET /sync.

A SQLAlchemy `after_flush` hook appends one SyncEvent row per (user, entity, id) that a write touched, so EVERY code path
(present and future) is covered without remembering to call a helper. The client keeps a cursor (`seq`) and asks only
"what changed for me since?" instead of re-downloading lists.

Known limit: seq is assigned at INSERT, visibility at COMMIT; a long transaction could commit a lower seq after a higher
one was already served. Events are tiny and the app also does a full refresh on resume/pull-to-refresh, so this is accepted.
"""
import uuid
from datetime import datetime, timedelta, timezone

from sqlalchemy import delete, event, func, insert, select
from sqlalchemy.orm import Session

from ..models import (
    Assignment, AssignmentEvent, Attendance, Bid, ChatMessage, Dispute, Job, Notification, Payment, Payout, Rating,
    SyncEvent,
)

RETENTION_DAYS = 14
MAX_ROWS = 500


def _asg_users(s: Session, assignment_id) -> tuple[Assignment | None, list]:
    a = s.get(Assignment, assignment_id) if assignment_id else None
    if not a:
        return None, []
    cust = s.scalar(select(Job.customer_id).where(Job.id == a.job_id))
    return a, [a.worker_id, cust]


def _rows_for(s: Session, obj) -> list[tuple]:
    """-> [(user_id, entity, entity_id)]"""
    out: list[tuple] = []
    if isinstance(obj, Job):
        users = {obj.customer_id, obj.direct_worker_id}
        users |= set(s.scalars(select(Bid.worker_id).where(Bid.job_id == obj.id)))
        users |= set(s.scalars(select(Assignment.worker_id).where(Assignment.job_id == obj.id)))
        out += [(u, "job", obj.id) for u in users if u]
    elif isinstance(obj, Bid):
        cust = s.scalar(select(Job.customer_id).where(Job.id == obj.job_id))
        out += [(u, "job", obj.job_id) for u in (obj.worker_id, cust) if u]
    elif isinstance(obj, Assignment):
        cust = s.scalar(select(Job.customer_id).where(Job.id == obj.job_id))
        for u in (obj.worker_id, cust):
            if u:
                out += [(u, "assignment", obj.id), (u, "job", obj.job_id)]
    elif isinstance(obj, (Payment, AssignmentEvent, Attendance, Dispute, Rating)):
        a, users = _asg_users(s, obj.assignment_id)
        if a:
            for u in users:
                out += [(u, "assignment", a.id), (u, "job", a.job_id)]
            if isinstance(obj, (Payment, Rating)):
                out.append((a.worker_id, "earnings", None))
    elif isinstance(obj, Payout):
        out.append((obj.worker_id, "earnings", None))
    elif isinstance(obj, ChatMessage):
        out += [(obj.sender_id, "chat", obj.job_id), (obj.recipient_id, "chat", obj.job_id)]
    elif isinstance(obj, Notification):
        out.append((obj.user_id, "notification", obj.id))
        if obj.kind == "new_job" and obj.job_id:  # the job appeared in this worker's feed
            out.append((obj.user_id, "job", obj.job_id))
    return out


@event.listens_for(Session, "after_flush")
def _track_changes(session: Session, ctx) -> None:
    if session.info.get("no_sync"):
        return
    seen: set[tuple] = set()
    objs = list(session.new) + [o for o in session.dirty if session.is_modified(o)]
    for obj in objs:
        if isinstance(obj, SyncEvent):
            continue
        try:
            for u, ent, eid in _rows_for(session, obj):
                seen.add((u, ent, str(eid) if eid else None))
        except Exception:  # the feed is best-effort; it must never break a write
            continue
    if seen:
        session.connection().execute(insert(SyncEvent.__table__),
                                     [{"user_id": u, "entity": e, "entity_id": i} for u, e, i in seen])


def baseline(db: Session, user_id: uuid.UUID) -> int:
    cur = db.scalar(select(func.max(SyncEvent.seq)).where(SyncEvent.user_id == user_id)) or 0
    return int(cur)


def changes(db: Session, user_id: uuid.UUID, since: int | None) -> dict:
    """since=None/0 -> baseline (nothing 'changed', `full` tells the client to load everything once)."""
    unread = unread_count(db, user_id)
    if not since or since < 0:
        if db.scalar(select(func.random())) < 0.02:  # opportunistic retention
            db.execute(delete(SyncEvent).where(SyncEvent.created_at < datetime.now(timezone.utc) - timedelta(days=RETENTION_DAYS)))
            db.commit()
        return {"cursor": baseline(db, user_id), "full": True, "unread": unread,
                "changed": {"jobs": [], "assignments": [], "chats": [], "earnings": False, "notifications": 0}}
    rows = db.execute(select(SyncEvent.seq, SyncEvent.entity, SyncEvent.entity_id)
                      .where(SyncEvent.user_id == user_id, SyncEvent.seq > since)
                      .order_by(SyncEvent.seq).limit(MAX_ROWS + 1)).all()
    full = len(rows) > MAX_ROWS
    rows = rows[:MAX_ROWS]
    cursor = rows[-1].seq if rows else since
    ch = {"jobs": [], "assignments": [], "chats": [], "earnings": False, "notifications": 0}
    key = {"job": "jobs", "assignment": "assignments", "chat": "chats"}
    for r in rows:
        if r.entity in key:
            if r.entity_id not in ch[key[r.entity]]:
                ch[key[r.entity]].append(r.entity_id)
        elif r.entity == "earnings":
            ch["earnings"] = True
        elif r.entity == "notification":
            ch["notifications"] += 1
    return {"cursor": int(cursor), "full": full, "unread": unread, "changed": ch}


def unread_count(db: Session, user_id) -> int:
    return int(db.scalar(select(func.count()).select_from(Notification)
                         .where(Notification.user_id == user_id, Notification.read_at.is_(None))) or 0)
