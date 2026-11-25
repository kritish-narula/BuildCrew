import uuid

from pydantic import BaseModel

from ..crypto import mask_phone, mask_upi
from ..models import User


class UserOut(BaseModel):
    id: uuid.UUID
    phone: str
    role: str
    name: str | None
    language_code: str
    kyc_level: int
    trades: list[str] | None = None
    upi_id: str | None = None
    overall_rating: float | None = None
    rating_count: int | None = None
    customer_type: str | None = None  # customers only: homeowner | contractor
    org_name: str | None = None


def user_out(user: User, self_view: bool = False) -> UserOut:
    """Data minimisation: other parties get masked phone/UPI; only the owner sees their own."""
    wp = user.worker_profile
    rating = wp or user.customer_profile
    return UserOut(
        id=user.id, phone=user.phone if self_view else mask_phone(user.phone), role=user.role.value,
        name=user.name, language_code=user.language_code, kyc_level=user.kyc_level,
        trades=list(wp.trades) if wp else None,
        upi_id=(wp.upi_id if self_view else mask_upi(wp.upi_id)) if wp else None,
        overall_rating=rating.overall_rating if rating else None,
        rating_count=rating.rating_count if rating else None,
        customer_type=user.customer_profile.type.value if user.customer_profile else None,
        org_name=user.customer_profile.org_name if user.customer_profile else None,
    )
