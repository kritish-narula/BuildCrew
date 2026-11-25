"""Auth: phone + OTP → short JWT. Role-based guards for /worker, /customer, /admin routers."""
import hashlib
import hmac
import secrets
import time
import uuid
from collections import defaultdict, deque
from datetime import datetime, timedelta, timezone

import jwt
from fastapi import Depends, Header, Request
from sqlalchemy.orm import Session

from .config import get_settings
from .db import get_db
from .enums import Role
from .errors import AppError
from .models import User


def hash_otp(phone: str, code: str) -> str:
    # Peppered HMAC: a DB leak of otp_codes reveals nothing usable.
    return hmac.new(get_settings().jwt_secret.encode(), f"{phone}:{code}".encode(), hashlib.sha256).hexdigest()


def new_otp() -> str:
    s = get_settings()
    return s.dev_fixed_otp if s.is_dev else f"{secrets.randbelow(10**6):06d}"


def issue_token(user: User) -> str:
    s = get_settings()
    now = datetime.now(timezone.utc)
    return jwt.encode({"sub": str(user.id), "role": user.role.value, "iat": now,
                       "exp": now + timedelta(hours=s.jwt_ttl_hours)}, s.jwt_secret, algorithm="HS256")


def current_user(request: Request, authorization: str | None = Header(default=None),
                 db: Session = Depends(get_db)) -> User:
    if not authorization or not authorization.lower().startswith("bearer "):
        raise AppError("err.unauthorized", 401)
    try:
        claims = jwt.decode(authorization[7:], get_settings().jwt_secret, algorithms=["HS256"])
        user = db.get(User, uuid.UUID(claims["sub"]))
    except (jwt.PyJWTError, KeyError, ValueError):
        raise AppError("err.unauthorized", 401)
    if not user:
        raise AppError("err.unauthorized", 401)
    request.state.lang = user.language_code  # every later error is localised to this user
    if user.role == Role.worker and user.worker_profile and user.worker_profile.is_suspended:
        raise AppError("err.account_suspended", 403)
    return user


def require(*roles: Role):
    def guard(user: User = Depends(current_user)) -> User:
        if user.role not in roles:
            raise AppError("err.forbidden", 403)
        return user
    return guard


# ------------------------------------------------------------------ simple rate limiter
# Per-process sliding window. Good enough for one instance; swap for Redis when scaling out.
_hits: dict[str, deque] = defaultdict(deque)


def rate_limit(key: str, limit: int, window_s: int) -> None:
    now = time.monotonic()
    q = _hits[key]
    while q and now - q[0] > window_s:
        q.popleft()
    if len(q) >= limit:
        raise AppError("err.rate_limited", 429)
    q.append(now)


def client_ip(request: Request) -> str:
    return request.client.host if request.client else "unknown"
