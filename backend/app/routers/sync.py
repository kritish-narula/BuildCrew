"""GET /sync (change feed), notification centre, push-token registration."""
import uuid

from fastapi import APIRouter, Depends, Query
from pydantic import BaseModel, Field
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from ..db import get_db
from ..domain import notify as nf
from ..domain import sync as sy
from ..models import Notification, PushToken, User
from ..security import current_user

router = APIRouter(tags=["sync"])


@router.get("/sync")
def sync(since: int | None = Query(None, ge=0), user: User = Depends(current_user), db: Session = Depends(get_db)):
    """Compact change feed for the signed-in user. First call (no `since`) returns the cursor + `full: true`.
    Later calls return only ids that changed: {cursor, full, unread, changed: {jobs, assignments, chats, earnings, notifications}}."""
    return sy.changes(db, user.id, since)


@router.get("/notifications")
def notifications(limit: int = Query(40, ge=1, le=100), before: str | None = None, user: User = Depends(current_user),
                  db: Session = Depends(get_db)):
    q = select(Notification).where(Notification.user_id == user.id)
    if before:
        from datetime import datetime
        q = q.where(Notification.created_at < datetime.fromisoformat(before))
    rows = db.scalars(q.order_by(Notification.created_at.desc(), Notification.id).limit(limit)).all()
    return {"unread": sy.unread_count(db, user.id), "items": [nf.render(n, user.language_code) | {"link": nf.deep_link(n)} for n in rows]}


@router.get("/notifications/unread-count")
def unread(user: User = Depends(current_user), db: Session = Depends(get_db)):
    return {"unread": sy.unread_count(db, user.id)}


class ReadIn(BaseModel):
    ids: list[uuid.UUID] | None = None  # None / empty = mark everything read


@router.post("/notifications/read")
def read(body: ReadIn | None = None, user: User = Depends(current_user), db: Session = Depends(get_db)):
    n = nf.mark_read(db, user.id, body.ids if body else None)
    db.commit()
    return {"marked": n, "unread": sy.unread_count(db, user.id)}


class PushTokenIn(BaseModel):
    token: str = Field(min_length=10, max_length=300)
    platform: str = Field("android", pattern="^(android|ios|web)$")


@router.post("/me/push-token")
def register_push_token(body: PushTokenIn, user: User = Depends(current_user), db: Session = Depends(get_db)):
    """Register / refresh this device's FCM token. A token belongs to ONE user (re-login on a shared phone moves it)."""
    row = db.scalar(select(PushToken).where(PushToken.token == body.token))
    if row:
        row.user_id, row.platform = user.id, body.platform
        row.last_seen_at = func.now()
    else:
        db.add(PushToken(user_id=user.id, token=body.token, platform=body.platform))
    db.commit()
    return {"ok": True}


@router.delete("/me/push-token")
def delete_push_token(token: str = Query(min_length=10), user: User = Depends(current_user), db: Session = Depends(get_db)):
    db.execute(PushToken.__table__.delete().where(PushToken.token == token, PushToken.user_id == user.id))
    db.commit()
    return {"ok": True}
