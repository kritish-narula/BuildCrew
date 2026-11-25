from datetime import datetime, timedelta, timezone
import hmac

from fastapi import APIRouter, Depends, Request
from pydantic import BaseModel, Field
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from .. import services
from ..audit import audit
from ..config import get_settings
from ..db import get_db
from ..enums import LANGUAGE_CODES, Role
from ..errors import AppError
from ..i18n import pick_lang, t
from ..models import CustomerProfile, OtpCode, User, WorkerProfile
from ..security import client_ip, current_user, hash_otp, issue_token, new_otp, rate_limit
from .schemas import UserOut, user_out

router = APIRouter(prefix="/auth", tags=["auth"])
PHONE = r"^[6-9]\d{9}$"  # Indian mobile, without +91

# Role routing: the client navigates to this after login. Single source of truth on the server.
HOME_ROUTE = {Role.worker: "/worker/jobs", Role.customer: "/customer/home", Role.admin: "/admin"}


class OtpRequest(BaseModel):
    phone: str = Field(pattern=PHONE)
    language_code: str | None = None


class OtpVerify(BaseModel):
    phone: str = Field(pattern=PHONE)
    code: str = Field(pattern=r"^\d{6}$")
    role: Role | None = None          # only used when the number is new
    language_code: str | None = None


class AuthOut(BaseModel):
    token: str
    user: UserOut
    home_route: str
    is_new: bool


@router.post("/otp/request")
def request_otp(body: OtpRequest, request: Request, db: Session = Depends(get_db)):
    s = get_settings()
    request.state.lang = body.language_code  # localise errors before we know the user
    rate_limit(f"otp-ip:{client_ip(request)}", 30, 3600)
    since = datetime.now(timezone.utc) - timedelta(hours=1)
    recent = db.scalar(select(func.count()).select_from(OtpCode)
                       .where(OtpCode.phone == body.phone, OtpCode.created_at > since))
    if recent >= s.otp_requests_per_hour:
        raise AppError("err.otp_rate_limited", 429)

    # Invalidate older codes so only the newest SMS works.
    for old in db.scalars(select(OtpCode).where(OtpCode.phone == body.phone, OtpCode.consumed.is_(False))):
        old.consumed = True
    code = new_otp()
    db.add(OtpCode(phone=body.phone, code_hash=hash_otp(body.phone, code),
                   expires_at=datetime.now(timezone.utc) + timedelta(seconds=s.otp_ttl_seconds)))
    db.commit()

    existing = db.scalar(select(User).where(User.phone == body.phone))
    lang = pick_lang(existing.language_code if existing else body.language_code,
                     request.headers.get("accept-language"))
    services.sms().send(body.phone, t("sms.otp", lang, code=code, minutes=s.otp_ttl_seconds // 60))
    out = {"resend_after_seconds": s.otp_resend_after_seconds, "expires_in_seconds": s.otp_ttl_seconds,
           "is_registered": existing is not None}
    if s.is_dev:
        out["dev_hint"] = "OTP is always " + s.dev_fixed_otp + " in dev"
    return out


@router.post("/otp/verify", response_model=AuthOut)
def verify_otp(body: OtpVerify, request: Request, db: Session = Depends(get_db)):
    request.state.lang = body.language_code
    rate_limit(f"verify-ip:{client_ip(request)}", 60, 3600)
    otp = db.scalar(select(OtpCode).where(OtpCode.phone == body.phone, OtpCode.consumed.is_(False))
                    .order_by(OtpCode.created_at.desc()))
    if not otp:
        raise AppError("err.otp_expired", 400)
    if otp.expires_at < datetime.now(timezone.utc):
        otp.consumed = True
        db.commit()
        raise AppError("err.otp_expired", 400)
    if otp.attempts >= get_settings().otp_max_attempts:
        raise AppError("err.otp_too_many_attempts", 429)
    if not hmac.compare_digest(otp.code_hash, hash_otp(body.phone, body.code)):
        otp.attempts += 1
        db.commit()
        raise AppError("err.otp_invalid", 400)
    otp.consumed = True

    user = db.scalar(select(User).where(User.phone == body.phone))
    is_new = user is None
    if is_new:
        role = body.role or Role.worker
        if role == Role.admin:
            raise AppError("err.admin_signup_forbidden", 403)
        lang = body.language_code if body.language_code in LANGUAGE_CODES else "hi"
        user = User(phone=body.phone, role=role, language_code=lang, kyc_level=0)
        db.add(user)
        db.flush()
        if role == Role.worker:
            db.add(WorkerProfile(user_id=user.id, trades=[], badges=[]))
        else:
            db.add(CustomerProfile(user_id=user.id))
        audit(db, actor_id=user.id, action="user.registered", entity="user", entity_id=user.id, role=role.value)
    audit(db, actor_id=user.id, action="user.login", entity="user", entity_id=user.id)
    db.commit()
    db.refresh(user)
    request.state.lang = user.language_code
    return AuthOut(token=issue_token(user), user=user_out(user, self_view=True), home_route=HOME_ROUTE[user.role], is_new=is_new)


class MePatch(BaseModel):
    language_code: str | None = None
    name: str | None = Field(default=None, max_length=120)


me_router = APIRouter(prefix="/me", tags=["me"])


@me_router.get("", response_model=UserOut)
def me(user: User = Depends(current_user)):
    return user_out(user, self_view=True)


@me_router.patch("", response_model=UserOut)
def patch_me(body: MePatch, user: User = Depends(current_user), db: Session = Depends(get_db)):
    if body.language_code is not None:
        if body.language_code not in LANGUAGE_CODES:
            raise AppError("err.language_unsupported", 422)
        audit(db, actor_id=user.id, action="user.language_changed", entity="user", entity_id=user.id,
              frm=user.language_code, to=body.language_code)
        user.language_code = body.language_code
    if body.name is not None:
        user.name = body.name.strip()
    db.add(user)
    db.commit()
    return user_out(user, self_view=True)
